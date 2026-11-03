import MarrText
import AppKit
import CoreText
import Foundation

struct ImageTranslationRenderResult: Sendable {
    let data: Data
    let translatedHighlightRects: [String: [CGRect]]
    let formulaPlacements: [ImageTranslationFormulaPlacement]
}

struct ImageTranslationFormulaPlacement: Sendable {
    let sourceRect: CGRect
    let targetRect: CGRect
}

enum ImageTranslationRenderer {
    static func renderData(sourceData: Data, blocks: [ImageTranslationBlock]) -> Data? {
        guard !Task.isCancelled else { return nil }
        guard let sourceImage = NSImage(data: sourceData) else { return nil }
        let pickedImage = PickedImage(
            data: sourceData,
            mimeType: "application/octet-stream",
            fileName: "translation-source",
            image: sourceImage
        )
        return render(source: pickedImage, blocks: blocks)?.tiffRepresentation
    }

    static func renderDataWithHighlights(
        sourceData: Data,
        blocks: [ImageTranslationBlock],
        highlightPairs: [ImageTranslationHighlightPair]
    ) -> ImageTranslationRenderResult? {
        guard !Task.isCancelled, let sourceImage = NSImage(data: sourceData) else { return nil }
        let pickedImage = PickedImage(
            data: sourceData,
            mimeType: "application/octet-stream",
            fileName: "translation-source",
            image: sourceImage
        )
        guard let output = renderOutput(
            source: pickedImage,
            blocks: blocks,
            highlightPairs: highlightPairs
        ), let data = output.image.tiffRepresentation else {
            return nil
        }
        return ImageTranslationRenderResult(
            data: data,
            translatedHighlightRects: output.translatedHighlightRects,
            formulaPlacements: output.formulaPlacements
        )
    }

    static func render(source pickedImage: PickedImage, blocks: [ImageTranslationBlock]) -> NSImage? {
        renderOutput(source: pickedImage, blocks: blocks, highlightPairs: [])?.image
    }

    private struct RenderOutput {
        let image: NSImage
        let translatedHighlightRects: [String: [CGRect]]
        var formulaPlacements: [ImageTranslationFormulaPlacement] = []
    }

    private static func renderOutput(
        source pickedImage: PickedImage,
        blocks: [ImageTranslationBlock],
        highlightPairs: [ImageTranslationHighlightPair]
    ) -> RenderOutput? {
        guard !Task.isCancelled else { return nil }
        guard let cgImage = sourceCGImage(from: pickedImage) else {
            return nil
        }

        let imageSize = pickedImage.image.size
        guard imageSize.width > 0, imageSize.height > 0 else {
            return nil
        }
        let bounds = CGRect(origin: .zero, size: imageSize)
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let backgroundSourceImage = NSImage(cgImage: cgImage, size: imageSize)
        let translatedBlocks = blocks.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !translatedBlocks.isEmpty else {
            return RenderOutput(image: backgroundSourceImage, translatedHighlightRects: [:])
        }
        let backgroundRaster = TranslationBackgroundRestoration.BackgroundRaster(image: cgImage)

        // lockFocus creates a screen-resolution backing store. An explicit
        // bitmap keeps both the source pixels and its logical coordinate space,
        // including images whose scale differs from the current display.
        guard let (outputBitmap, context) = sourceCanvas(for: cgImage) else {
            return nil
        }
        outputBitmap.size = imageSize
        let output = NSImage(size: imageSize)
        output.addRepresentation(outputBitmap)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        context.cgContext.scaleBy(
            x: CGFloat(cgImage.width) / imageSize.width,
            y: CGFloat(cgImage.height) / imageSize.height
        )

        let drawableBlocks = layoutDrawableBlocks(
            blocks: translatedBlocks,
            imageSize: imageSize,
            bounds: bounds,
        )
        let canvasBackgroundColor = semanticCanvasBackground(
            bitmap: bitmap,
            bounds: bounds
        )
        let graphicStrokes = immutableGraphicStrokes(in: cgImage, background: canvasBackgroundColor,
            textRects: drawableBlocks.flatMap(\.sourceTextRects), logicalSize: imageSize)
        let preparedBlocks = drawableBlocks.compactMap {
            prepareDrawing(
                $0,
                imageSize: imageSize,
                bounds: bounds,
                bitmap: bitmap
            )
        }
        let inlineFlows = inlineSentenceFlows(preparedBlocks, imageSize: imageSize, bounds: bounds,
                                              pixelScale: CGFloat(cgImage.width) / imageSize.width,
                                              backgroundRaster: backgroundRaster, bitmap: bitmap)
        let flowingIndexes = Set(inlineFlows.flatMap(\.blockIndexes))
        let formulaPlacements = inlineFlows.flatMap(\.formulas)
        let protectedRects = drawableBlocks
            .flatMap { drawableBlock in
                let mathRects = drawableBlock.block.mathRects.map { rect in
                    CGRect(
                        x: rect.x * imageSize.width,
                        y: (1 - rect.y - rect.height) * imageSize.height,
                        width: rect.width * imageSize.width,
                        height: rect.height * imageSize.height
                    ).integral.intersection(bounds)
                }
                let codeRects = drawableBlock.block.translationStrategy == .selective
                    ? drawableBlock.sourceCodeRects : []
                let listMarkerRects = drawableBlock.block.listMarkerRects.map { rect in
                    CGRect(x: rect.x * imageSize.width, y: (1 - rect.y - rect.height) * imageSize.height,
                           width: rect.width * imageSize.width, height: rect.height * imageSize.height)
                        .integral.intersection(bounds)
                }
                // Other protectedRects can be prose owned by another segment;
                // structural markers, math and code are always immutable.
                return mathRects + codeRects + listMarkerRects
            }
            .reduce(into: [CGRect]()) { rects, rect in
                if !rects.contains(rect) { rects.append(rect) }
            }
        // OCR erase padding can overlap the next row. Finish clearing every
        // source region before drawing any translation, so a later row cannot
        // erase the glyphs we have just drawn above it.
        for preparedBlock in preparedBlocks {
            guard !Task.isCancelled else { return nil }
            eraseSource(
                for: preparedBlock,
                backgroundSourceImage: backgroundSourceImage,
                backgroundRaster: backgroundRaster,
                protectedRects: protectedRects,
                bounds: bounds
            )
        }
        for flow in inlineFlows {
            let style = preparedBlocks[flow.blockIndexes[0]]
            for rect in flow.formulas.map(\.sourceRect) + flow.sourceGapRects {
                TranslationBackgroundRestoration.restoreLocalBackground(in: rect, samplingRect: rect, raster: backgroundRaster, bounds: bounds,
                    sourceImage: backgroundSourceImage, fallbackSourceRect: style.backgroundPatchSourceRect,
                    fallbackColor: style.backgroundColor)
            }
        }
        // A neighboring translated row must not paint over preserved formulas
        // or code either. Intersect individual exclusions so overlapping
        // protected rectangles remain protected rather than cancelling out.
        context.cgContext.saveGState()
        let textExclusions = protectedRects.filter { sourceRect in
            !formulaPlacements.contains { $0.sourceRect == sourceRect }
        } + formulaPlacements.map(\.targetRect)
        for protectedRect in textExclusions {
            let path = CGMutablePath()
            path.addRect(bounds)
            path.addRect(protectedRect)
            context.cgContext.addPath(path)
            context.cgContext.clip(using: .evenOdd)
        }
        var translatedHighlightRects: [String: [CGRect]] = [:]
        for (index, preparedBlock) in preparedBlocks.enumerated() where !flowingIndexes.contains(index) {
            guard !Task.isCancelled else {
                context.cgContext.restoreGState()
                return nil
            }
            let blockPairs = highlightPairs.filter { pair in
                pair.sourceID != nil && pair.sourceID == preparedBlock.drawableBlock.block.sourceID
            }
            let blockHighlightRects = draw(
                preparedBlock,
                imageSize: imageSize,
                bounds: bounds,
                bitmap: bitmap,
                highlightPairs: blockPairs
            )
            translatedHighlightRects.merge(blockHighlightRects) { _, latest in latest }
        }
        for flow in inlineFlows {
            for layout in flow.textLayouts {
                drawTextLayout(layout)
            }
            let pairs = highlightPairs.filter { $0.sourceID == flow.sourceID }
            translatedHighlightRects.merge(exactHighlightRects(for: pairs,
                layouts: flow.textLayouts, imageSize: imageSize)) { _, latest in latest }
        }
        context.cgContext.restoreGState()
        // OCR label boxes can include a chart axis or a curve passing behind
        // the label. Restore those connected strokes from the source after
        // replacement, instead of turning the whole label box into a hole.
        if let graphicStrokes {
            context.cgContext.saveGState()
            // A formula's long fraction bar may also be detected as a graphic.
            // Never restore that stroke at its old position after reflow.
            for rect in formulaPlacements.flatMap({ [$0.sourceRect, $0.targetRect] }) {
                let path = CGMutablePath()
                path.addRect(bounds)
                path.addRect(rect)
                context.cgContext.addPath(path)
                context.cgContext.clip(using: .evenOdd)
            }
            context.cgContext.draw(graphicStrokes, in: bounds)
            context.cgContext.restoreGState()
        }
        for formula in formulaPlacements {
            backgroundSourceImage.draw(in: formula.targetRect, from: formula.sourceRect,
                operation: .copy, fraction: 1, respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.none])
        }

        return RenderOutput(
            image: output,
            translatedHighlightRects: translatedHighlightRects,
            formulaPlacements: formulaPlacements
        )
    }

    private struct InlineSentenceFlow {
        let sourceID: String
        let blockIndexes: [Int]
        let textLayouts: [TextHighlightLayout]
        let formulas: [ImageTranslationFormulaPlacement]
        let sourceGapRects: [CGRect]
    }

    private struct RowAlignment {
        var fontSize: CGFloat
        var leading: CGFloat
        var baseline: CGFloat
        let sourceBaseline: CGFloat
        var foregroundColors: [Int: NSColor] = [:]
    }

    /// Infer paragraph rhythm from the source prose, rather than letting each
    /// translated fragment's OCR padding select its own font and top edge.
    private static func paragraphRowAlignments(
        _ prepared: [PreparedBlock], groups: [String: [Int]], imageSize: CGSize,
        bounds: CGRect, bitmap: NSBitmapImageRep, pixelScale: CGFloat
    ) -> [String: RowAlignment] {
        struct Row {
            let id: String
            let indexes: [Int]
            let span: CGRect
            let inkHeight: CGFloat
            let alignment: RowAlignment
            let canJoin: Bool
        }
        func median(_ values: [CGFloat]) -> CGFloat { values.sorted()[values.count / 2] }
        let rows: [Row] = groups.compactMap { id, indexes in
            let first = prepared[indexes[0]].drawableBlock
            let math = first.block.inlineMathRects
            guard indexes.allSatisfy({ index in
                let item = prepared[index].drawableBlock
                return item.layoutLineRects.count == 1 && item.hasMeasuredSourceInk
                    && item.sourceCodeRects.isEmpty && item.sourceTrailingAttachmentRects.isEmpty
                    && item.block.inlineMathRects == math
                    && (item.block.translationStrategy == .block || !math.isEmpty)
                    && textAlignment(from: item.block.alignment) == .left
                    && !item.block.text.contains("\n") && !item.block.text.contains("`")
                    && verticalOverlapRatio(item.sourceRect, first.sourceRect) > 0.5
            }) else { return nil }
            let ordered = indexes.sorted { prepared[$0].drawableBlock.sourceRect.minX < prepared[$1].drawableBlock.sourceRect.minX }
            let ink = ordered.flatMap { prepared[$0].drawableBlock.sourceInkLineRects }
            // A tiny connector such as "for" has no descenders and must not
            // redefine the baseline or font of a complete sentence.
            let widestInk = ink.map(\.width).max() ?? 0
            let substantial = ink.filter { $0.width >= widestInk * 0.35 }
            let height = median(substantial.map(\.height))
            let baseline = sourceProseBaseline(in: substantial, bitmap: bitmap,
                backgroundColor: prepared[indexes[0]].backgroundColor, bounds: bounds)
            let sample = NSAttributedString(string: "国Ag", attributes: [
                .font: TranslationTypography.proseFont(ofSize: 32, weight: TranslationTypography.effectiveFontWeight(for: first.block))
            ])
            let sampleInk = CTLineGetImageBounds(CTLineCreateWithAttributedString(sample), nil)
            let fontSize = height * 0.96 * 32 / max(1, sampleInk.height)
            let formulas = math.map {
                CGRect(x: $0.x * imageSize.width, y: (1 - $0.y - $0.height) * imageSize.height,
                       width: $0.width * imageSize.width, height: $0.height * imageSize.height)
            }
            let span = (ordered.map { prepared[$0].drawableBlock.sourceRect } + formulas)
                .reduce(CGRect.null) { $0.union($1) }
            let proseLeading = prepared[ordered[0]].drawableBlock.sourceInkLineRects.map(\.minX).min() ?? span.minX
            let leading = min(proseLeading, formulas.map(\.minX).min() ?? proseLeading)
            let kind = TranslationTypography.normalizedKind(first.block.kind)
            return Row(id: id, indexes: indexes, span: span, inkHeight: height,
                alignment: RowAlignment(fontSize: fontSize, leading: leading,
                    baseline: baseline, sourceBaseline: baseline),
                canJoin: !first.block.preservesListMarker && first.block.listMarkerRects.isEmpty
                    && !["title", "heading", "caption", "list_item"].contains(kind))
        }.sorted { $0.span.midY == $1.span.midY ? $0.span.minX < $1.span.minX : $0.span.midY > $1.span.midY }
        var paragraphs: [[Row]] = []
        for row in rows {
            let match = paragraphs.indices.last { index in
                guard let previous = paragraphs[index].last, row.canJoin, previous.canJoin else { return false }
                let height = max(row.inkHeight, previous.inkHeight)
                let step = previous.alignment.baseline - row.alignment.baseline
                let lhs = prepared[previous.indexes[0]], rhs = prepared[row.indexes[0]]
                guard step >= height * 0.95 && step <= height * 2.2,
                      min(row.inkHeight, previous.inkHeight) / height >= 0.80,
                      abs(row.alignment.leading - previous.alignment.leading) <= height * 0.35,
                      TranslationTypography.normalizedKind(lhs.drawableBlock.block.kind)
                        == TranslationTypography.normalizedKind(rhs.drawableBlock.block.kind),
                      TranslationTypography.effectiveFontWeight(for: lhs.drawableBlock.block)
                        == TranslationTypography.effectiveFontWeight(for: rhs.drawableBlock.block),
                      TranslationColorSampling.rgbDistance(lhs.backgroundColor, rhs.backgroundColor) < 0.03,
                      // Antialiased digits and letters can yield slightly
                      // different sampled grays on the same printed line.
                      TranslationColorSampling.rgbDistance(lhs.foregroundColor, rhs.foregroundColor) < 0.15
                else { return false }
                // A heading, list marker, other column or untranslated item
                // between these rows is a structural boundary.
                let corridor = CGRect(x: max(row.span.minX, previous.span.minX), y: row.span.maxY,
                    width: max(0, min(row.span.maxX, previous.span.maxX) - max(row.span.minX, previous.span.minX)),
                    height: max(0, previous.span.minY - row.span.maxY))
                let owners = Set(previous.indexes + row.indexes)
                return !prepared.indices.contains { !owners.contains($0) && prepared[$0].drawableBlock.sourceRect.intersects(corridor) }
            }
            if let match { paragraphs[match].append(row) } else { paragraphs.append([row]) }
        }
        var result: [String: RowAlignment] = [:]
        for paragraph in paragraphs {
            // Isolated normal labels retain their original sizing/alignment.
            guard paragraph.count > 1 || !prepared[paragraph[0].indexes[0]].drawableBlock.block.inlineMathRects.isEmpty else { continue }
            let size = median(paragraph.map { $0.alignment.fontSize })
            let left = median(paragraph.map { $0.alignment.leading })
            let steps = zip(paragraph, paragraph.dropFirst()).map { $0.alignment.baseline - $1.alignment.baseline }
            let step = steps.isEmpty ? 0 : median(steps)
            let origin = median(paragraph.enumerated().map { $0.element.alignment.baseline + CGFloat($0.offset) * step })
            let regular = paragraph.enumerated().allSatisfy {
                abs(origin - CGFloat($0.offset) * step - $0.element.alignment.baseline) <= 2 / pixelScale
            }
            // Pool only compatible, inferred ink colors. Explicit colors and
            // distinct emphasis hues are semantic styles, not sampling noise.
            var colorGroups: [[Int]] = []
            for index in paragraph.flatMap(\.indexes) where prepared[index].drawableBlock.block.textColor == nil {
                if let group = colorGroups.firstIndex(where: {
                    let reference = prepared[$0[0]]
                    return TranslationColorSampling.rgbDistance(reference.foregroundColor, prepared[index].foregroundColor) < 0.15
                        && TranslationColorSampling.rgbDistance(reference.backgroundColor, prepared[index].backgroundColor) < 0.03
                }) { colorGroups[group].append(index) } else { colorGroups.append([index]) }
            }
            var colors: [Int: NSColor] = [:]
            for group in colorGroups where group.count > 1 {
                if let color = TranslationColorSampling.sampledForegroundColor(
                    in: group.flatMap { prepared[$0].drawableBlock.sourceInkLineRects }, bitmap: bitmap,
                    backgroundColor: prepared[group[0]].backgroundColor, bounds: bounds) {
                    for index in group { colors[index] = color }
                }
            }
            for (offset, row) in paragraph.enumerated() {
                var alignment = row.alignment
                alignment.fontSize = size
                alignment.leading = (left * pixelScale).rounded() / pixelScale
                alignment.foregroundColors = colors
                if regular { alignment.baseline = origin - CGFloat(offset) * step }
                // Integer pixel translation keeps formula crops exact at 1x/2x.
                alignment.baseline = alignment.sourceBaseline
                    + ((alignment.baseline - alignment.sourceBaseline) * pixelScale).rounded() / pixelScale
                result[row.id] = alignment
            }
        }
        return result
    }

    private static func sourceProseBaseline(
        in rects: [CGRect], bitmap: NSBitmapImageRep, backgroundColor: NSColor, bounds: CGRect
    ) -> CGFloat {
        let ink = rects.reduce(CGRect.null) { $0.union($1) }
        let scale = CGFloat(bitmap.pixelsHigh) / bounds.height
        let step = 1 / scale
        let count = max(1, Int(ceil(ink.height * scale)))
        var density = [Int](repeating: 0, count: count)
        for row in 0..<count {
            let y = ink.minY + (CGFloat(row) + 0.5) * step
            for rect in rects where y >= rect.minY && y <= rect.maxY {
                let columns = min(256, max(1, Int(rect.width * scale)))
                for column in 0..<columns {
                    let x = rect.minX + (CGFloat(column) + 0.5) / CGFloat(columns) * rect.width
                    if let color = TranslationColorSampling.sampledColor(appKitX: x, appKitY: y, bitmap: bitmap, bounds: bounds),
                       TranslationColorSampling.rgbDistance(color, backgroundColor) > 0.30 { density[row] += 1 }
                }
            }
        }
        // Sparse descenders fall below the dense bottom of the letter bodies.
        let threshold = max(2, Int(CGFloat(density.max() ?? 0) * 0.28))
        let lowerBody = (0..<max(1, count / 3)).first { density[$0] >= threshold } ?? 0
        return ink.minY + CGFloat(lowerBody) * step
    }

    /// Compact an entire translated row at its natural text width. Ownership
    /// comes from the parser, not proximity: a nearby displayed equation or an
    /// untranslated suffix must never be pulled into this sentence.
    private static func inlineSentenceFlows(
        _ prepared: [PreparedBlock], imageSize: CGSize, bounds: CGRect, pixelScale: CGFloat,
        backgroundRaster: TranslationBackgroundRestoration.BackgroundRaster?, bitmap: NSBitmapImageRep
    ) -> [InlineSentenceFlow] {
        let groups = Dictionary(grouping: prepared.indices.filter {
            prepared[$0].drawableBlock.block.sourceID != nil
        }) { prepared[$0].drawableBlock.block.sourceID! }
        let alignments = paragraphRowAlignments(prepared, groups: groups, imageSize: imageSize,
            bounds: bounds, bitmap: bitmap, pixelScale: pixelScale)
        return groups.keys.sorted().compactMap { sourceID in
            let indexes = groups[sourceID]!
            guard let firstIndex = indexes.first else { return nil }
            let first = prepared[firstIndex]
            let ownedMath = first.drawableBlock.block.inlineMathRects
            let alignment = alignments[sourceID]
            guard !ownedMath.isEmpty || alignment != nil else { return nil }
            guard indexes.allSatisfy({ index in
                let item = prepared[index].drawableBlock
                return item.block.inlineMathRects == ownedMath
                    && (item.block.translationStrategy == .selective || (ownedMath.isEmpty && indexes.count == 1))
                    && item.layoutLineRects.count == 1
                    && item.sourceCodeRects.isEmpty && item.sourceTrailingAttachmentRects.isEmpty
                    && textAlignment(from: item.block.alignment) == .left
                    && !item.block.text.contains("\n")
                    && verticalOverlapRatio(item.sourceRect, first.drawableBlock.sourceRect) > 0.5
            }) else { return nil }
            let formulas = ownedMath.map {
                CGRect(x: $0.x * imageSize.width, y: (1 - $0.y - $0.height) * imageSize.height,
                       width: $0.width * imageSize.width, height: $0.height * imageSize.height)
                    .integral.intersection(bounds)
            }
            guard formulas.allSatisfy({ formula in
                formula.width > 1 && formula.height > 1
                    && indexes.contains { verticalOverlapRatio(formula, prepared[$0].drawableBlock.sourceRect) > 0.5 }
            }) else { return nil }
            let sizes = indexes.map { index in
                let item = prepared[index].drawableBlock
                return TranslationTypography.typographicBaseFontSize(for: item.block, imageHeight: imageSize.height,
                                               rect: item.layoutLineRects[0])
            }.sorted()
            let fontSize = alignment?.fontSize ?? sizes[sizes.count / 2]
            let referenceText = NSAttributedString(string: "国Ag", attributes: [
                .font: TranslationTypography.proseFont(ofSize: fontSize,
                    weight: TranslationTypography.effectiveFontWeight(for: first.drawableBlock.block))
            ])
            var rowAscent: CGFloat = 0, rowDescent: CGFloat = 0
            CTLineGetTypographicBounds(CTLineCreateWithAttributedString(referenceText), &rowAscent, &rowDescent, nil)
            let gap = max(3, min(8, fontSize * 0.2))
            let sourceSpan = (indexes.map { prepared[$0].drawableBlock.sourceRect } + formulas)
                .reduce(CGRect.null) { $0.union($1) }
            // A formula crop carries its original background pixels. Moving
            // it over a gradient or texture would paste a mismatched tile;
            // keep its original anchor unless the whole row shares one surface.
            let sourceInk = indexes.flatMap { prepared[$0].drawableBlock.sourceInkLineRects } + formulas
            let baselineShift = alignment.map { $0.baseline - $0.sourceBaseline } ?? 0
            let movingSpan = sourceSpan.union(sourceSpan.offsetBy(dx: 0, dy: baselineShift))
            guard formulas.isEmpty || TranslationBackgroundRestoration.hasUniformFormulaBackground(
                in: movingSpan, raster: backgroundRaster, bounds: bounds
            ) || TranslationBackgroundRestoration.hasUniformFormulaBackground(
                in: movingSpan, raster: backgroundRaster, bounds: bounds, excludingInk: sourceInk
            ) else { return nil }
            // Each run keeps its source order, including leading/trailing math.
            let runs: [(rect: CGRect, index: Int?)] = (indexes.map {
                (rect: prepared[$0].drawableBlock.sourceRect, index: Optional($0))
            } + formulas.map { (rect: $0, index: Optional<Int>.none) })
                .sorted { $0.rect.minX < $1.rect.minX }
            var cursor = sourceSpan.minX
            if let index = runs.first?.index {
                cursor = prepared[index].drawableBlock.layoutLineRects[0].minX
            }
            if let alignment { cursor = alignment.leading }
            var layouts: [TextHighlightLayout] = []
            var placements: [ImageTranslationFormulaPlacement] = []
            for run in runs {
                if let index = run.index {
                    if alignment == nil && layouts.isEmpty && placements.isEmpty { cursor += 1 }
                    let item = prepared[index]
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.alignment = .left
                    paragraph.lineBreakMode = .byClipping
                    let attributed = TranslationTypography.attributedMarkdownLayout(TranslationTypography.layoutMarkdown(for: item.drawableBlock.block),
                        fontSize: fontSize, weight: TranslationTypography.effectiveFontWeight(for: item.drawableBlock.block),
                        foregroundColor: alignment?.foregroundColors[index] ?? item.foregroundColor, paragraph: paragraph).attributed
                    let line = CTLineCreateWithAttributedString(attributed)
                    let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                    let baseline = alignment?.baseline ?? (first.drawableBlock.layoutLineRects[0].maxY - rowAscent)
                    let rect = CGRect(x: cursor, y: baseline - rowDescent, width: ceil(width) + 1, height: rowAscent + rowDescent)
                    layouts.append(TextHighlightLayout(attributed: attributed, drawRect: rect,
                        baseline: CGPoint(x: cursor, y: baseline)))
                    cursor += width + gap
                } else {
                    let x = (cursor * pixelScale).rounded() / pixelScale
                    let target = run.rect.offsetBy(dx: x - run.rect.minX, dy: baselineShift)
                    placements.append(ImageTranslationFormulaPlacement(sourceRect: run.rect, targetRect: target))
                    cursor = target.maxX + gap
                }
            }
            // Keep a readable size; fall back when a complete sentence cannot
            // fit safely. Never shrink it just to recreate the English spacing.
            guard cursor - gap <= sourceSpan.maxX,
                  sourceSpan.maxX - (cursor - gap) > gap,
                  alignment != nil || placements.contains(where: { abs($0.targetRect.minX - $0.sourceRect.minX) > gap })
            else { return nil }
            let targets = layouts.map { inlineTextInkBounds($0) } + placements.map(\.targetRect)
            let otherText = prepared.indices.filter { !indexes.contains($0) }
                .flatMap {
                    let other = prepared[$0].drawableBlock
                    // Calibrated ink is the occupied area. The font's leading
                    // and OCR padding can overlap adjacent rows even when no
                    // visible glyphs do, and must not pin the whole sentence.
                    return other.sourceInkLineRects + other.sourceCodeRects
                }
            let fixedMath = (first.drawableBlock.block.mathRects + first.drawableBlock.block.listMarkerRects).map {
                CGRect(x: $0.x * imageSize.width, y: (1 - $0.y - $0.height) * imageSize.height,
                       width: $0.width * imageSize.width, height: $0.height * imageSize.height).integral.intersection(bounds)
            }.filter { !formulas.contains($0) }
            guard targets.allSatisfy({ target in
                bounds.contains(target) && !(otherText + fixedMath).contains { $0.intersects(target) }
            }) else { return nil }
            // OCR occasionally leaves the edge of a letter in the narrow gap
            // next to an equation. It becomes visible once that equation moves.
            let gaps = zip(runs, runs.dropFirst()).compactMap { left, right -> CGRect? in
                let width = right.rect.minX - left.rect.maxX
                let bottom = max(left.rect.minY, right.rect.minY)
                let top = min(left.rect.maxY, right.rect.maxY)
                guard width > 0, width < fontSize * 0.5, top > bottom else { return nil }
                let rect = CGRect(x: left.rect.maxX, y: bottom, width: width, height: top - bottom)
                return (otherText + fixedMath).contains { $0.intersects(rect) } ? nil : rect
            }
            return InlineSentenceFlow(sourceID: sourceID, blockIndexes: indexes,
                                      textLayouts: layouts, formulas: placements, sourceGapRects: gaps)
        }
    }

    private static func inlineTextInkBounds(_ layout: TextHighlightLayout) -> CGRect {
        let line = CTLineCreateWithAttributedString(layout.attributed)
        var ascent: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, nil, nil)
        let ink = CTLineGetImageBounds(line, nil)
        guard !ink.isNull, !ink.isEmpty else { return layout.drawRect }
        return ink.offsetBy(dx: layout.baseline?.x ?? layout.drawRect.minX,
                            dy: layout.baseline?.y ?? (layout.drawRect.maxY - ascent))
    }

    private static func immutableGraphicStrokes(
        in image: CGImage, background: NSColor, textRects: [CGRect], logicalSize: CGSize
    ) -> CGImage? {
        let width = image.width, height = image.height
        let colorSpace = image.colorSpace?.model == .rgb ? image.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
        guard width > 0, height > 0, let nsColorSpace = NSColorSpace(cgColorSpace: colorSpace),
              let color = background.usingColorSpace(nsColorSpace) else { return nil }
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let bg = [color.redComponent, color.greenComponent, color.blueComponent].map { Int($0 * 255) }
        var occupied = [UInt8](repeating: 0, count: width * height)
        for index in occupied.indices {
            let p = index * 4
            if max(abs(Int(pixels[p]) - bg[0]), abs(Int(pixels[p + 1]) - bg[1]),
                   abs(Int(pixels[p + 2]) - bg[2])) > 70 { occupied[index] = 1 }
        }
        var preserved = [UInt8](repeating: 0, count: pixels.count)
        let sourceInk = occupied
        var textMask = [UInt8](repeating: 0, count: width * height)
        for rect in textRects {
            let x0 = max(0, min(width - 1, Int(floor(rect.minX / logicalSize.width * CGFloat(width)))))
            let x1 = max(x0, min(width - 1, Int(ceil(rect.maxX / logicalSize.width * CGFloat(width)))))
            let y0 = max(0, min(height - 1, Int(floor((1 - rect.maxY / logicalSize.height) * CGFloat(height)))))
            let y1 = max(y0, min(height - 1, Int(ceil((1 - rect.minY / logicalSize.height) * CGFloat(height)))))
            for y in y0...y1 { for x in x0...x1 { textMask[y * width + x] = 1 } }
        }
        let directions = (0..<16).map { index -> (CGFloat, CGFloat) in
            let angle = CGFloat(index) * .pi / 16
            return (cos(angle), sin(angle))
        }
        func inkDirection(at index: Int) -> SIMD3<Double>? {
            let p = index * 4
            let delta = SIMD3(Double(Int(pixels[p]) - bg[0]),
                              Double(Int(pixels[p + 1]) - bg[1]),
                              Double(Int(pixels[p + 2]) - bg[2]))
            let magnitude = max(abs(delta.x), abs(delta.y), abs(delta.z))
            guard magnitude > 2 else { return nil }
            return delta / magnitude
        }
        func matchesStrokeColor(_ candidate: SIMD3<Double>, anchor: SIMD3<Double>) -> Bool {
            let distance = TranslationBackgroundRestoration.channelDistance(candidate, anchor)
            if distance < 0.18 { return true }
            // Resampling a colored curve beneath lettering can darken its
            // pixels unevenly. Retain that curve's dominant channel while
            // keeping neutral strokes strict, so nearby red glyphs cannot
            // become part of a black line.
            let dominant: Int
            if anchor.x >= anchor.y && anchor.x >= anchor.z { dominant = 0 }
            else if anchor.y >= anchor.z { dominant = 1 }
            else { dominant = 2 }
            let other = max(candidate[(dominant + 1) % 3], candidate[(dominant + 2) % 3])
            return anchor[dominant] - min(anchor.x, anchor.y, anchor.z) > 0.30
                && candidate[dominant] - other > 0.06 && distance < 0.55
        }
        func outsideStrokeAnchor(x: Int, y: Int, dx: CGFloat, dy: CGFloat,
                                 direction: SIMD3<Double>) -> SIMD3<Double>? {
            // Continue through a wide OCR box to the first real exterior ink.
            // Do not jump across blank space or a differently colored endpoint.
            for offset in stride(from: 24, through: max(width, height) * 2, by: 3) {
                let xx = x + Int((CGFloat(offset) * dx).rounded())
                let yy = y + Int((CGFloat(offset) * dy).rounded())
                var hasInteriorInk = false
                var hasExteriorInk = false
                for perpendicular in -2...2 {
                    let sx = xx + Int((CGFloat(perpendicular) * -dy).rounded())
                    let sy = yy + Int((CGFloat(perpendicular) * dx).rounded())
                    guard sx >= 0, sx < width, sy >= 0, sy < height else { continue }
                    let index = sy * width + sx
                    guard sourceInk[index] != 0 else { continue }
                    if textMask[index] != 0 { hasInteriorInk = true; continue }
                    hasExteriorInk = true
                    if let anchor = inkDirection(at: index), TranslationBackgroundRestoration.channelDistance(anchor, direction) < 0.18 {
                        return anchor
                    }
                }
                if hasExteriorInk || !hasInteriorInk { return nil }
            }
            return nil
        }
        func trackedStrokeAnchor(x: Int, y: Int, dx: CGFloat, dy: CGFloat,
                                 direction: SIMD3<Double>) -> SIMD3<Double>? {
            // A curve endpoint cannot fill a symmetric straight-line window.
            // Follow connected ink one pixel at a time instead, requiring a
            // long path to matching ink outside the OCR box. Short differently
            // colored crossings are allowed, but blank gaps stop the trace.
            var currentX = x, currentY = y, foreignSteps = 0
            var visited: Set<Int> = [y * width + x]
            for step in 1...(max(width, height) * 2) {
                let xx = currentX + Int(dx.rounded())
                let yy = currentY + Int(dy.rounded())
                var matching: Int?
                var crossing: Int?
                for perpendicular in [0, -1, 1] {
                    let sx = xx + Int((CGFloat(perpendicular) * -dy).rounded())
                    let sy = yy + Int((CGFloat(perpendicular) * dx).rounded())
                    guard sx >= 0, sx < width, sy >= 0, sy < height else { continue }
                    let index = sy * width + sx
                    guard sourceInk[index] != 0, !visited.contains(index) else { continue }
                    if crossing == nil { crossing = index }
                    if let color = inkDirection(at: index), matchesStrokeColor(color, anchor: direction) {
                        matching = index
                        break
                    }
                }
                let next: Int
                if let matching {
                    foreignSteps = 0
                    next = matching
                    if textMask[next] == 0, step >= 48 { return inkDirection(at: next) }
                } else if let crossing, foreignSteps < 3 {
                    foreignSteps += 1
                    next = crossing
                } else { return nil }
                visited.insert(next)
                currentX = next % width
                currentY = next / width
            }
            return nil
        }
        func longStrokeAnchor(x: Int, y: Int, direction: SIMD3<Double>) -> SIMD3<Double>? {
            // Text touching a curve belongs to the same connected component.
            // Inside OCR glyph boxes retain only locally continuous strokes,
            // so restoring the curve does not restore the English label too.
            for (dx, dy) in directions {
                var continuous = true
                for offset in stride(from: -24, through: 24, by: 3) {
                    let xx = x + Int((CGFloat(offset) * dx).rounded())
                    let yy = y + Int((CGFloat(offset) * dy).rounded())
                    var found = false
                    // A resampled curve can bend by three pixels across this
                    // 48-pixel window. Only geometric support widens; exterior
                    // color anchors and the restored pixel neighborhood do not.
                    for perpendicular in -3...3 {
                        let sx = xx + Int((CGFloat(perpendicular) * -dy).rounded())
                        let sy = yy + Int((CGFloat(perpendicular) * dx).rounded())
                        if sx >= 0, sx < width, sy >= 0, sy < height, sourceInk[sy * width + sx] != 0 {
                            found = true; break
                        }
                    }
                    if !found { continuous = false; break }
                }
                guard continuous else { continue }
                // Geometry may cross a colored label. Anchor its color outside
                // the OCR box, instead of treating the label as part of the line.
                if let anchor = outsideStrokeAnchor(x: x, y: y, dx: dx, dy: dy, direction: direction)
                    ?? outsideStrokeAnchor(x: x, y: y, dx: -dx, dy: -dy, direction: direction) {
                    return anchor
                }
            }
            for (dx, dy) in directions {
                if let anchor = trackedStrokeAnchor(x: x, y: y, dx: dx, dy: dy, direction: direction)
                    ?? trackedStrokeAnchor(x: x, y: y, dx: -dx, dy: -dy, direction: direction) {
                    return anchor
                }
            }
            return nil
        }
        var found = false
        // Dotted horizontal rules are disconnected components. Preserve only
        // very thin rows separated vertically from text, so a title's erase
        // padding cannot remove the divider below it.
        let rowInk = (0..<height).map { y in
            sourceInk[(y * width)..<((y + 1) * width)].reduce(0) { $0 + Int($1) }
        }
        for y in 3..<max(3, height - 3) where rowInk[y] > width / 8
            && rowInk[y - 3] == 0 && rowInk[y + 3] == 0 {
            found = true
            for yy in (y - 1)...(y + 1) {
                for x in 0..<width where sourceInk[yy * width + x] != 0 {
                    let p = (yy * width + x) * 4
                    preserved[p] = pixels[p]; preserved[p + 1] = pixels[p + 1]
                    preserved[p + 2] = pixels[p + 2]; preserved[p + 3] = pixels[p + 3]
                }
            }
        }
        let minimumSpan = max(120, min(width, height) / 5)
        var queue: [Int] = []
        for start in occupied.indices where occupied[start] == 1 {
            queue.removeAll(keepingCapacity: true)
            queue.append(start)
            occupied[start] = 0
            var cursor = 0
            var minX = start % width, maxX = minX, minY = start / width, maxY = minY
            while cursor < queue.count {
                let current = queue[cursor]
                cursor += 1
                let x = current % width, y = current / width
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                for yy in max(0, y - 1)...min(height - 1, y + 1) {
                    for xx in max(0, x - 1)...min(width - 1, x + 1) {
                        let neighbor = yy * width + xx
                        if occupied[neighbor] == 1 { occupied[neighbor] = 0; queue.append(neighbor) }
                    }
                }
            }
            let spanX = maxX - minX + 1, spanY = maxY - minY + 1
            guard max(spanX, spanY) >= minimumSpan,
                  min(spanX, spanY) <= 4 || Double(queue.count) / Double(spanX * spanY) < 0.20 else { continue }
            found = true
            for index in queue {
                // Include the antialiased edge of each connected stroke.
                let x = index % width, y = index / width
                guard let direction = inkDirection(at: index) else { continue }
                let anchor: SIMD3<Double>
                if textMask[index] != 0 {
                    guard let exterior = longStrokeAnchor(x: x, y: y, direction: direction) else { continue }
                    anchor = exterior
                } else { anchor = direction }
                for yy in max(0, y - 1)...min(height - 1, y + 1) {
                    for xx in max(0, x - 1)...min(width - 1, x + 1) {
                        let neighbor = yy * width + xx
                        if textMask[neighbor] != 0 {
                            guard let color = inkDirection(at: neighbor), matchesStrokeColor(color, anchor: anchor) else { continue }
                        }
                        let p = (yy * width + xx) * 4
                        preserved[p] = pixels[p]; preserved[p + 1] = pixels[p + 1]
                        preserved[p + 2] = pixels[p + 2]; preserved[p + 3] = pixels[p + 3]
                    }
                }
            }
        }
        guard found, let provider = CGDataProvider(data: Data(preserved) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow, space: colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private static func sourceCanvas(for cgImage: CGImage) -> (NSBitmapImageRep, NSGraphicsContext)? {
        let copiedBitmap = NSBitmapImageRep(cgImage: cgImage)
        if let context = NSGraphicsContext(bitmapImageRep: copiedBitmap) {
            return (copiedBitmap, context)
        }

        // Some decoded images have a bitmap format AppKit cannot draw into.
        // Convert those to RGBA while retaining their RGB color profile; using
        // device RGB here alters untouched Display P3 screenshot pixels.
        guard let rgbaBitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: cgImage.width,
            pixelsHigh: cgImage.height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        let sourceColorSpace = cgImage.colorSpace.flatMap { colorSpace in
            colorSpace.model == .rgb ? NSColorSpace(cgColorSpace: colorSpace) : nil
        } ?? .sRGB
        guard let outputBitmap = rgbaBitmap.retagging(with: sourceColorSpace),
              let context = NSGraphicsContext(bitmapImageRep: outputBitmap)
        else { return nil }
        context.cgContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        return (outputBitmap, context)
    }

    private static func sourceCGImage(from pickedImage: PickedImage) -> CGImage? {
        var sourceRect = CGRect(origin: .zero, size: pickedImage.image.size)
        return pickedImage.image.cgImage(
            forProposedRect: &sourceRect,
            context: nil,
            hints: nil
        )
    }

    private static func semanticCanvasBackground(bitmap: NSBitmapImageRep, bounds: CGRect) -> NSColor {
        let insetX = max(2, bounds.width * 0.025)
        let insetY = max(2, bounds.height * 0.025)
        let xValues = [bounds.minX + insetX, bounds.midX, bounds.maxX - insetX]
        let yValues = [bounds.minY + insetY, bounds.midY, bounds.maxY - insetY]
        let edgePoints = xValues.flatMap { x in
            [
                CGPoint(x: x, y: bounds.minY + insetY),
                CGPoint(x: x, y: bounds.maxY - insetY)
            ]
        } + yValues.flatMap { y in
            [
                CGPoint(x: bounds.minX + insetX, y: y),
                CGPoint(x: bounds.maxX - insetX, y: y)
            ]
        }
        let colors = edgePoints.compactMap { point in
            TranslationColorSampling.sampledColor(appKitX: point.x, appKitY: point.y, bitmap: bitmap, bounds: bounds)
        }

        return TranslationColorSampling.dominantBackgroundColor(colors)
            ?? TranslationColorSampling.averageColor(colors)
            ?? .windowBackgroundColor
    }

    struct DrawableBlock {
        var block: ImageTranslationBlock
        let sourceRect: CGRect
        let sourceLineRects: [CGRect]
        let sourceTextRects: [CGRect]
        let sourceProtectedRects: [CGRect]
        let sourceTrailingAttachmentRects: [CGRect]
        let sourceCodeRects: [CGRect]
        var sourceInkLineRects: [CGRect]
        var hasMeasuredSourceInk = false
        var layoutLineRects: [CGRect]
        var layoutRect: CGRect
    }

    private static func layoutDrawableBlocks(
        blocks: [ImageTranslationBlock],
        imageSize: CGSize,
        bounds: CGRect
    ) -> [DrawableBlock] {
        let sourceRects = blocks
            .filter { !$0.text.isEmpty }
            .map { block in
                (
                    block: block,
                    rect: blockRect(block, imageSize: imageSize)
                        .intersection(bounds)
                        .integral
                )
            }
            .filter { $0.rect.width > 1 && $0.rect.height > 1 }
            .sorted { lhs, rhs in
                if abs(lhs.rect.midY - rhs.rect.midY) > 2 {
                    return lhs.rect.midY > rhs.rect.midY
                }
                return lhs.rect.minX < rhs.rect.minX
            }

        return sourceRects.map { item in
            let lineRects = sourceLineRects(
                for: item.block,
                imageSize: imageSize,
                bounds: bounds
            )
            let textRects = sourceTextRects(
                for: item.block,
                imageSize: imageSize,
                bounds: bounds
            )
            let protectedRects = sourceProtectedRects(
                for: item.block,
                imageSize: imageSize,
                bounds: bounds
            )
            let trailingAttachmentRects = sourceTrailingAttachmentRects(
                for: item.block,
                imageSize: imageSize,
                bounds: bounds
            )
            let codeRects = sourceCodeRects(
                for: item.block,
                imageSize: imageSize,
                bounds: bounds,
                textRects: textRects
            )
            let layoutLineRects = ImageTranslationLayoutGeometry.expandedLineRects(
                lineRects,
                sourceRect: item.rect,
                bounds: bounds,
                alignment: textAlignment(from: item.block.alignment)
            )
            let layoutRect = sourceLayoutRect(
                sourceRect: item.rect,
                lineRects: layoutLineRects,
                bounds: bounds
            )

            return DrawableBlock(
                block: item.block,
                sourceRect: item.rect,
                sourceLineRects: lineRects,
                sourceTextRects: textRects,
                sourceProtectedRects: protectedRects,
                sourceTrailingAttachmentRects: trailingAttachmentRects,
                sourceCodeRects: codeRects,
                sourceInkLineRects: lineRects.isEmpty ? textRects : lineRects,
                layoutLineRects: layoutLineRects,
                layoutRect: layoutRect.intersection(bounds).integral
            )
        }
    }

    private static func sourceLineRects(
        for block: ImageTranslationBlock,
        imageSize: CGSize,
        bounds: CGRect
    ) -> [CGRect] {
        block.lineRects
            .map { lineRect in
                CGRect(
                    x: CGFloat(lineRect.x) * imageSize.width,
                    y: imageSize.height - (CGFloat(lineRect.y) * imageSize.height) - CGFloat(lineRect.height) * imageSize.height,
                    width: CGFloat(lineRect.width) * imageSize.width,
                    height: CGFloat(lineRect.height) * imageSize.height
                )
                .intersection(bounds)
                .integral
            }
            .filter { (rect: CGRect) in rect.width > 1 && rect.height > 1 }
    }

    private static func sourceTextRects(
        for block: ImageTranslationBlock,
        imageSize: CGSize,
        bounds: CGRect
    ) -> [CGRect] {
        block.textRects
            .map { textRect in
                CGRect(
                    x: CGFloat(textRect.x) * imageSize.width,
                    y: imageSize.height - (CGFloat(textRect.y) * imageSize.height) - CGFloat(textRect.height) * imageSize.height,
                    width: CGFloat(textRect.width) * imageSize.width,
                    height: CGFloat(textRect.height) * imageSize.height
                )
                .intersection(bounds)
                .integral
            }
            .filter { $0.width > 1 && $0.height > 1 }
    }

    private static func sourceCodeRects(
        for block: ImageTranslationBlock,
        imageSize: CGSize,
        bounds: CGRect,
        textRects: [CGRect]
    ) -> [CGRect] {
        let translatedCodeTexts = TranslationTypography.inlineMarkdownSpans(block.text)
            .filter(\.isCode)
            .map(\.text)

        return block.codeRects
            .enumerated()
            .map { index, tokenRect in
                let rect = CGRect(
                    x: CGFloat(tokenRect.x) * imageSize.width,
                    y: imageSize.height - (CGFloat(tokenRect.y) * imageSize.height) - CGFloat(tokenRect.height) * imageSize.height,
                    width: CGFloat(tokenRect.width) * imageSize.width,
                    height: CGFloat(tokenRect.height) * imageSize.height
                )
                .intersection(bounds)
                .integral

                let expandedRect = ImageTranslationLayoutGeometry.expandedCodeRect(
                    rect,
                    text: index < translatedCodeTexts.count
                        ? (translatedCodeTexts[index].count > tokenRect.text.count
                            ? translatedCodeTexts[index]
                            : tokenRect.text)
                        : tokenRect.text,
                    bounds: bounds
                )
                let nextTextRect = textRects
                    .filter { candidate in
                        verticalOverlapRatio(candidate, rect) > 0.30
                            && candidate.minX >= rect.maxX - max(2, rect.height * 0.18)
                    }
                    .min { $0.minX < $1.minX }
                guard let nextTextRect else {
                    return expandedRect
                }

                let neighborGap = max(1, rect.height * 0.06)
                let cappedMaxX = min(expandedRect.maxX, nextTextRect.minX - neighborGap)
                guard cappedMaxX > expandedRect.minX + 1 else {
                    return expandedRect
                }
                return CGRect(
                    x: expandedRect.minX,
                    y: expandedRect.minY,
                    width: cappedMaxX - expandedRect.minX,
                    height: expandedRect.height
                ).integral
            }
            .filter { (rect: CGRect) in rect.width > 1 && rect.height > 1 }
    }

    private static func sourceTrailingAttachmentRects(
        for block: ImageTranslationBlock,
        imageSize: CGSize,
        bounds: CGRect
    ) -> [CGRect] {
        block.trailingAttachments
            .map { attachmentRect in
                CGRect(
                    x: CGFloat(attachmentRect.x) * imageSize.width,
                    y: imageSize.height
                        - CGFloat(attachmentRect.y) * imageSize.height
                        - CGFloat(attachmentRect.height) * imageSize.height,
                    width: CGFloat(attachmentRect.width) * imageSize.width,
                    height: CGFloat(attachmentRect.height) * imageSize.height
                )
                .intersection(bounds)
                .integral
            }
            .filter { $0.width > 1 && $0.height > 1 }
    }

    private static func sourceProtectedRects(
        for block: ImageTranslationBlock,
        imageSize: CGSize,
        bounds: CGRect
    ) -> [CGRect] {
        block.protectedRects
            .map { protectedRect in
                CGRect(
                    x: CGFloat(protectedRect.x) * imageSize.width,
                    y: imageSize.height
                        - CGFloat(protectedRect.y) * imageSize.height
                        - CGFloat(protectedRect.height) * imageSize.height,
                    width: CGFloat(protectedRect.width) * imageSize.width,
                    height: CGFloat(protectedRect.height) * imageSize.height
                )
                .intersection(bounds)
                .integral
            }
            .filter { $0.width > 1 && $0.height > 1 }
    }

    private static func sourceLayoutRect(
        sourceRect: CGRect,
        lineRects: [CGRect],
        bounds: CGRect
    ) -> CGRect {
        guard let firstLineRect = lineRects.first else {
            return sourceRect.intersection(bounds).integral
        }

        let rect = lineRects
            .dropFirst()
            .reduce(firstLineRect) { partial, lineRect in
                partial.union(lineRect)
            }

        return rect.intersection(sourceRect.union(rect)).intersection(bounds).integral
    }

    private static func verticalOverlapRatio(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let overlap = min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY)
        return max(0, overlap) / max(min(lhs.height, rhs.height), 1)
    }

    struct PreparedBlock {
        let drawableBlock: DrawableBlock
        let rect: CGRect
        let eraseRects: [CGRect]
        let backgroundPatchSourceRect: CGRect?
        let backgroundColor: NSColor
        let foregroundColor: NSColor
        let inlineCodeBackgroundColor: NSColor
    }

    private static func prepareDrawing(
        _ originalDrawableBlock: DrawableBlock,
        imageSize: CGSize,
        bounds: CGRect,
        bitmap: NSBitmapImageRep
    ) -> PreparedBlock? {
        var drawableBlock = originalDrawableBlock
        let block = drawableBlock.block
        var rect = drawableBlock.layoutRect.intersection(bounds).integral
        guard rect.width > 1, rect.height > 1 else {
            return nil
        }

        let backgroundSampleRect = drawableBlock.sourceRect
            .insetBy(dx: -max(1, drawableBlock.sourceRect.height * 0.05), dy: -max(1, drawableBlock.sourceRect.height * 0.08))
            .intersection(bounds)
            .integral
        let eraseRects = sourceEraseRects(
            for: drawableBlock,
            imageHeight: imageSize.height,
            bounds: bounds
        )
        // The text's own surface is authoritative. Exterior samples may be
        // on the page outside a card, and even a tiny local tint is intentional.
        let backgroundColor = TranslationColorSampling.dominantInteriorBackgroundColor(
                in: drawableBlock.sourceLineRects.isEmpty
                    ? [drawableBlock.sourceRect] : drawableBlock.sourceLineRects,
                bitmap: bitmap,
                bounds: bounds
            )
            ?? TranslationColorSampling.sampledBackgroundColor(
                in: backgroundSampleRect,
                bitmap: bitmap,
                bounds: bounds
            )
            ?? TranslationColorSampling.dominantInteriorBackgroundColor(
                in: eraseRects,
                bitmap: bitmap,
                bounds: bounds
            )
            ?? TranslationColorSampling.color(from: block.backgroundColor)
            ?? .windowBackgroundColor
        calibrateSourceTextLine(
            &drawableBlock,
            bitmap: bitmap,
            backgroundColor: backgroundColor,
            imageSize: imageSize,
            bounds: bounds
        )
        expandShortInlineSlot(&drawableBlock, imageSize: imageSize, bounds: bounds)
        rect = drawableBlock.layoutRect.intersection(bounds)
        let foregroundColor = TranslationColorSampling.color(from: block.textColor)
            ?? TranslationColorSampling.sampledForegroundColor(
                in: drawableBlock.sourceTextRects.isEmpty
                    ? drawableBlock.sourceLineRects
                    : drawableBlock.sourceTextRects,
                bitmap: bitmap,
                backgroundColor: backgroundColor,
                bounds: bounds
            )
            ?? TranslationColorSampling.readableTextColor(on: backgroundColor)
        let inlineCodeBackgroundColor = TranslationColorSampling.dominantInteriorBackgroundColor(
            in: drawableBlock.sourceCodeRects,
            bitmap: bitmap,
            bounds: bounds
        ) ?? TranslationTypography.codeChipColor(on: backgroundColor)
        let backgroundPatchSourceRect = TranslationBackgroundRestoration.backgroundPatchSourceRect(
            around: backgroundSampleRect,
            matching: backgroundColor,
            bitmap: bitmap,
            bounds: bounds
        )

        let resolvedEraseRects = mergedEraseRects(eraseRects).map { rawEraseRect in
            if block.sourceID != nil,
               ["title", "heading"].contains(TranslationTypography.normalizedKind(block.kind)),
               drawableBlock.sourceLineRects.count == 1 {
                return headingInkEraseRect(
                    in: rawEraseRect,
                    bitmap: bitmap,
                    backgroundColor: backgroundColor,
                    bounds: bounds
                )
            }
            return rawEraseRect
        }
        return PreparedBlock(
            drawableBlock: drawableBlock,
            rect: rect,
            eraseRects: resolvedEraseRects,
            backgroundPatchSourceRect: backgroundPatchSourceRect,
            backgroundColor: backgroundColor,
            foregroundColor: foregroundColor,
            inlineCodeBackgroundColor: inlineCodeBackgroundColor
        )
    }

    private static func isShortInlineConnector(_ block: ImageTranslationBlock) -> Bool {
        let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return block.translationStrategy == .selective && !block.mathRects.isEmpty
            && (1...4).contains(text.count) && text.allSatisfy(TextCharacterRules.isCJKCharacter)
    }

    private static func expandShortInlineSlot(
        _ drawableBlock: inout DrawableBlock,
        imageSize: CGSize,
        bounds: CGRect
    ) {
        guard isShortInlineConnector(drawableBlock.block),
              drawableBlock.layoutLineRects.count == 1,
              let row = drawableBlock.layoutLineRects.first else { return }
        let math = drawableBlock.block.mathRects.map {
            CGRect(x: $0.x * imageSize.width, y: (1 - $0.y - $0.height) * imageSize.height,
                   width: $0.width * imageSize.width, height: $0.height * imageSize.height)
        }.filter { verticalOverlapRatio($0, row) > 0.4 }
        guard let left = math.filter({ $0.maxX <= row.midX }).map(\.maxX).max(),
              let right = math.filter({ $0.minX >= row.midX }).map(\.minX).min(),
              right > left else { return }
        // Use only the small margins already separating source text from its
        // neighboring formulas. This makes short connectors readable without
        // moving an equation or borrowing another prose segment's space.
        let margin = max(2, row.height * 0.35)
        let minX = max(bounds.minX, left + 1.5, row.minX - margin)
        let maxX = min(bounds.maxX, right - 1.5, row.maxX + margin)
        guard maxX > minX, maxX - minX > row.width else { return }
        let expanded = CGRect(x: minX, y: row.minY, width: maxX - minX, height: row.height)
        drawableBlock.layoutLineRects = [expanded]
        drawableBlock.layoutRect = expanded
    }

    private static func calibrateSourceTextLine(
        _ drawableBlock: inout DrawableBlock,
        bitmap: NSBitmapImageRep,
        backgroundColor: NSColor,
        imageSize: CGSize,
        bounds: CGRect
    ) {
        let block = drawableBlock.block
        guard block.sourceID != nil, block.fontSize != nil,
              !drawableBlock.sourceTextRects.isEmpty,
              !drawableBlock.layoutLineRects.isEmpty else { return }
        let immutableRects = block.mathRects.map {
            CGRect(x: $0.x * imageSize.width, y: (1 - $0.y - $0.height) * imageSize.height,
                   width: $0.width * imageSize.width, height: $0.height * imageSize.height)
        } + drawableBlock.sourceCodeRects
        let rows = drawableBlock.layoutLineRects
        let inkBands = rows.map { row -> CGRect? in
            let proseRects = drawableBlock.sourceTextRects.filter {
                verticalOverlapRatio($0, row) > 0.35
            }.flatMap { subtractingProtectedRects(immutableRects, from: $0.intersection(row)) }
                .filter { $0.width > 3 && $0.height > 4 }
            return sourceInkBand(in: proseRects, bitmap: bitmap,
                                 backgroundColor: backgroundColor, bounds: bounds)
        }
        let measuredHeights = inkBands.compactMap { $0?.height }.sorted()
        guard !measuredHeights.isEmpty else { return }
        drawableBlock.sourceInkLineRects = zip(rows, inkBands).map { row, ink in ink ?? row }
        drawableBlock.hasMeasuredSourceInk = true
        // Fractions enlarge OCR's line boxes. Measure only the source prose,
        // using a common cap for all rows so one tall expression cannot make
        // the surrounding paragraph larger than adjacent body text.
        let referenceInkHeight = measuredHeights[(measuredHeights.count - 1) / 2]
        let referenceRow = rows.sorted { $0.height < $1.height }[(rows.count - 1) / 2]
        let weight = TranslationTypography.effectiveFontWeight(for: block)
        let originalSize = TranslationTypography.typographicBaseFontSize(for: block, imageHeight: imageSize.height, rect: referenceRow)
        func metrics(at size: CGFloat) -> (ink: CGRect, ascent: CGFloat, height: CGFloat) {
            let text = NSAttributedString(string: TranslationTypography.layoutMarkdown(for: block).replacingOccurrences(of: "\n", with: " "), attributes: [
                .font: TranslationTypography.proseFont(ofSize: size, weight: weight)
            ])
            let line = CTLineCreateWithAttributedString(text)
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            return (CTLineGetImageBounds(line, nil), ascent, ceil(ascent + descent + leading))
        }
        let originalMetrics = metrics(at: originalSize)
        guard originalMetrics.ink.height > 0 else { return }
        let scale = originalMetrics.ink.height > referenceInkHeight * 1.20
            ? min(1, referenceInkHeight * 1.12 / originalMetrics.ink.height) : 1
        let calibratedSize = originalSize * scale
        let lineMetrics = scale < 1 ? metrics(at: calibratedSize) : originalMetrics
        let topInset = max(0, lineMetrics.ascent - lineMetrics.ink.maxY)
        let calibratedRows = zip(rows, inkBands).map { row, ink -> CGRect in
            guard let ink else { return row }
            let top = min(row.maxY, ink.maxY + topInset)
            let height = min(row.height, lineMetrics.height, max(1, top - row.minY))
            guard height > 1 else { return row }
            // Tighten only leading-aligned text to its source ink. Changing
            // one side of a centered box shifts its center; changing a
            // right-aligned box also changes the room available for fitting.
            let alignment = textAlignment(from: block.alignment)
            let left = alignment == .center || alignment == .right
                ? row.minX : max(row.minX, ink.minX - 1)
            return CGRect(x: left, y: top - height, width: max(1, row.maxX - left), height: height)
        }
        drawableBlock.layoutLineRects = calibratedRows
        drawableBlock.layoutRect = calibratedRows.reduce(CGRect.null) { $0.union($1) }
        // Store the measured size cap, not just a multiplier of a possibly
        // inflated OCR request. Paragraph fallback has a taller layout rect.
        let unconstrainedSize = TranslationTypography.typographicBaseFontSize(for: block, imageHeight: imageSize.height, rect: bounds)
        let fontScale = min(1, calibratedSize / max(unconstrainedSize, 1))
        if fontScale < 1, let fontSize = block.fontSize {
            drawableBlock.block = ImageTranslationBlock(
                sourceID: block.sourceID, text: block.text,
                x: block.x, y: block.y, width: block.width, height: block.height,
                lineRects: block.lineRects, preservesListMarker: block.preservesListMarker, listMarkerRects: block.listMarkerRects,
                textRects: block.textRects, protectedRects: block.protectedRects, mathRects: block.mathRects,
                inlineMathRects: block.inlineMathRects,
                trailingAttachments: block.trailingAttachments, translationStrategy: block.translationStrategy,
                codeRects: block.codeRects, kind: block.kind, textColor: block.textColor,
                backgroundColor: block.backgroundColor, alignment: block.alignment,
                weight: block.weight, fontSize: fontSize * fontScale
            )
        }
    }

    private static func sourceInkBand(
        in textRects: [CGRect],
        bitmap: NSBitmapImageRep,
        backgroundColor: NSColor,
        bounds: CGRect
    ) -> CGRect? {
        let rect = textRects.reduce(CGRect.null) { $0.union($1) }.intersection(bounds)
        guard !rect.isNull, rect.width > 3, rect.height > 4 else { return nil }
        let pixelScale = CGFloat(bitmap.pixelsHigh) / max(bounds.height, 1)
        let rows = min(160, max(4, Int(ceil(rect.height * pixelScale))))
        let rowHeight = rect.height / CGFloat(rows)
        var bands: [ClosedRange<Int>] = []
        var horizontalInk = [(lower: CGFloat, upper: CGFloat)?](repeating: nil, count: rows)
        var start: Int?
        var last = 0
        for row in 0..<rows {
            let y = rect.minY + (CGFloat(row) + 0.5) * rowHeight
            var spans: [(lower: CGFloat, upper: CGFloat)] = []
            for textRect in textRects.filter({ $0.minY <= y && $0.maxY >= y }).sorted(by: { $0.minX < $1.minX }) {
                let lower = max(rect.minX, textRect.minX)
                let upper = min(rect.maxX, textRect.maxX)
                guard upper > lower else { continue }
                if let last = spans.last, lower <= last.upper {
                    spans[spans.count - 1].upper = max(last.upper, upper)
                } else { spans.append((lower, upper)) }
            }
            let width = spans.reduce(CGFloat.zero) { $0 + $1.upper - $1.lower }
            guard width > 0 else { continue }
            let columns = min(192, max(4, Int(ceil(width * pixelScale))))
            var inkSamples = 0
            var firstInk: CGFloat?
            var lastInk: CGFloat?
            var spanIndex = 0
            var consumedWidth: CGFloat = 0
            for column in 0..<columns {
                // Distribute samples over prose itself. A wide formula between
                // two short words must not consume the sampling budget.
                let offset = (CGFloat(column) + 0.5) / CGFloat(columns) * width
                while spanIndex < spans.count - 1,
                      offset >= consumedWidth + spans[spanIndex].upper - spans[spanIndex].lower {
                    consumedWidth += spans[spanIndex].upper - spans[spanIndex].lower
                    spanIndex += 1
                }
                let x = spans[spanIndex].lower + offset - consumedWidth
                if let color = TranslationColorSampling.sampledColor(appKitX: x, appKitY: y, bitmap: bitmap, bounds: bounds),
                   TranslationColorSampling.rgbDistance(color, backgroundColor) > 0.30 {
                    inkSamples += 1
                    if firstInk == nil { firstInk = x }
                    lastInk = x
                }
            }
            guard inkSamples >= 2 else { continue }
            if let firstInk, let lastInk { horizontalInk[row] = (firstInk, lastInk) }
            if let lower = start, CGFloat(row - last) * rowHeight > 3 / pixelScale {
                bands.append(lower...last)
                start = nil
            }
            if start == nil { start = row }
            last = row
        }
        if let start { bands.append(start...last) }
        guard let band = bands.max(by: { $0.count < $1.count }), CGFloat(band.count) * rowHeight >= 4 else { return nil }
        let horizontal = band.compactMap { horizontalInk[$0] }
        let left = horizontal.map(\.lower).min() ?? rect.minX
        let right = horizontal.map(\.upper).max() ?? rect.maxX
        return CGRect(x: left, y: rect.minY + CGFloat(band.lowerBound) * rowHeight,
                      width: max(1, right - left), height: CGFloat(band.count) * rowHeight)
    }

    private static func eraseSource(
        for preparedBlock: PreparedBlock,
        backgroundSourceImage: NSImage,
        backgroundRaster: TranslationBackgroundRestoration.BackgroundRaster?,
        protectedRects: [CGRect],
        bounds: CGRect
    ) {
        var eraseRects = preparedBlock.eraseRects
        eraseRects += preparedBlock.drawableBlock.sourceTrailingAttachmentRects.map { attachmentRect in
            let padding = max(1, min(attachmentRect.height * 0.08, 3))
            return attachmentRect.insetBy(dx: -padding, dy: -padding).intersection(bounds).integral
        }
        for eraseRect in eraseRects {
            guard let context = NSGraphicsContext.current?.cgContext else { continue }
            context.saveGState()
            for protectedRect in protectedRects where protectedRect.intersects(eraseRect) {
                let path = CGMutablePath()
                path.addRect(bounds)
                path.addRect(protectedRect)
                context.addPath(path)
                context.clip(using: .evenOdd)
            }
            let core = eraseRect.intersection(preparedBlock.drawableBlock.sourceRect)
            TranslationBackgroundRestoration.restoreLocalBackground(
                in: eraseRect,
                samplingRect: core.width > 1 && core.height > 1 ? core : eraseRect,
                raster: backgroundRaster,
                bounds: bounds,
                sourceImage: backgroundSourceImage,
                fallbackSourceRect: preparedBlock.backgroundPatchSourceRect,
                fallbackColor: preparedBlock.backgroundColor,
                modelBackgroundHint: preparedBlock.drawableBlock.block.sourceID == nil
                    && preparedBlock.drawableBlock.sourceTextRects.isEmpty
                    ? TranslationColorSampling.color(from: preparedBlock.drawableBlock.block.backgroundColor) : nil
            )
            context.restoreGState()
        }
    }

    private static func subtractingProtectedRects(_ protectedRects: [CGRect], from rect: CGRect) -> [CGRect] {
        // Subtract the actual two-dimensional intersections. Excluding an
        // entire x column here would leave the next row's source text behind.
        protectedRects.reduce([rect]) { segments, protectedRect in
            segments.flatMap { segment -> [CGRect] in
                let overlap = segment.intersection(protectedRect)
                guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { return [segment] }
                return [
                    CGRect(x: segment.minX, y: segment.minY, width: segment.width, height: overlap.minY - segment.minY),
                    CGRect(x: segment.minX, y: overlap.maxY, width: segment.width, height: segment.maxY - overlap.maxY),
                    CGRect(x: segment.minX, y: overlap.minY, width: overlap.minX - segment.minX, height: overlap.height),
                    CGRect(x: overlap.maxX, y: overlap.minY, width: segment.maxX - overlap.maxX, height: overlap.height)
                ].filter { $0.width > 0 && $0.height > 0 }
            }
        }
    }

    static func draw(
        _ preparedBlock: PreparedBlock,
        imageSize: CGSize,
        bounds: CGRect,
        bitmap: NSBitmapImageRep,
        highlightPairs: [ImageTranslationHighlightPair]
    ) -> [String: [CGRect]] {
        let drawableBlock = preparedBlock.drawableBlock
        let block = drawableBlock.block
        let preservesSourceCode = block.translationStrategy == .selective
            && !drawableBlock.sourceCodeRects.isEmpty
        let translatedHighlightRects = drawText(
            block,
            in: preparedBlock.rect,
            lineRects: drawableBlock.layoutLineRects,
            codeRects: preservesSourceCode ? drawableBlock.sourceCodeRects : [],
            imageHeight: imageSize.height,
            foregroundColor: preparedBlock.foregroundColor,
            backgroundColor: preparedBlock.backgroundColor,
            inlineCodeBackgroundColor: preparedBlock.inlineCodeBackgroundColor,
            alignment: textAlignment(from: block.alignment),
            sourceHeight: drawableBlock.sourceRect.height,
            preserveSourceCode: preservesSourceCode,
            highlightPairs: highlightPairs,
            imageSize: imageSize
        )

        drawTrailingAttachments(
            drawableBlock,
            imageHeight: imageSize.height,
            bounds: bounds,
            bitmap: bitmap
        )
        return translatedHighlightRects
    }

    private static func headingInkEraseRect(
        in rect: CGRect,
        bitmap: NSBitmapImageRep,
        backgroundColor: NSColor,
        bounds: CGRect
    ) -> CGRect {
        // OCR boxes include vertical leading. On slides that leading can also
        // contain a thin separator below a heading. Find the actual text's ink
        // band so clearing the heading does not remove an unrelated rule.
        let rows = max(1, min(160, Int(ceil(rect.height * CGFloat(bitmap.pixelsHigh) / bounds.height))))
        let columns = max(1, min(192, Int(ceil(rect.width))))
        let rowHeight = rect.height / CGFloat(rows)
        var occupiedRows: [Int] = []
        for row in 0..<rows {
            let y = rect.minY + (CGFloat(row) + 0.5) * rowHeight
            for column in 0..<columns {
                let x = rect.minX + (CGFloat(column) + 0.5) / CGFloat(columns) * rect.width
                if let color = TranslationColorSampling.sampledColor(appKitX: x, appKitY: y, bitmap: bitmap, bounds: bounds),
                   TranslationColorSampling.rgbDistance(color, backgroundColor) > 0.16 {
                    occupiedRows.append(row)
                    break
                }
            }
        }
        guard let first = occupiedRows.first else { return rect }
        let maximumGap = max(1, Int(ceil(min(3, rect.height * 0.04) / rowHeight)))
        var bands: [ClosedRange<Int>] = []
        var start = first
        var last = first
        for row in occupiedRows.dropFirst() {
            if row - last > maximumGap + 1 {
                bands.append(start...last)
                start = row
            }
            last = row
        }
        bands.append(start...last)
        guard bands.count > 1,
              let textBand = bands.max(by: { $0.count < $1.count }),
              CGFloat(textBand.count) * rowHeight >= rect.height * 0.25,
              bands.filter({ $0 != textBand }).allSatisfy({ band in
                  let gap = max(textBand.lowerBound - band.upperBound, band.lowerBound - textBand.upperBound) - 1
                  return CGFloat(band.count) * rowHeight <= max(3, rowHeight * 2)
                      && CGFloat(gap) * rowHeight >= max(4, CGFloat(textBand.count) * rowHeight * 0.1)
              })
        else { return rect }
        let margin = max(1, rowHeight)
        return CGRect(
            x: rect.minX,
            y: rect.minY + CGFloat(textBand.lowerBound) * rowHeight - margin,
            width: rect.width,
            height: CGFloat(textBand.count) * rowHeight + margin * 2
        ).intersection(rect)
    }

    private static func mergedEraseRects(_ rects: [CGRect]) -> [CGRect] {
        var merged = rects
            .filter { $0.width > 1 && $0.height > 1 }
            .map(\.integral)
            .sorted { lhs, rhs in
                if abs(lhs.minY - rhs.minY) > 1 {
                    return lhs.minY < rhs.minY
                }
                return lhs.minX < rhs.minX
            }

        var didMerge = true
        while didMerge {
            didMerge = false
            outer: for firstIndex in merged.indices {
                for secondIndex in merged.indices where secondIndex > firstIndex {
                    let lhs = merged[firstIndex]
                    let rhs = merged[secondIndex]
                    let horizontalOverlap = min(lhs.maxX, rhs.maxX) - max(lhs.minX, rhs.minX)
                    let verticalOverlap = min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY)
                    let horizontalGap = max(0, max(lhs.minX, rhs.minX) - min(lhs.maxX, rhs.maxX))
                    let verticalGap = max(0, max(lhs.minY, rhs.minY) - min(lhs.maxY, rhs.maxY))
                    let sharesVisualRow = verticalOverlap >= min(lhs.height, rhs.height) * 0.45
                        && horizontalGap <= 2
                    let sharesVisualColumn = horizontalOverlap >= min(lhs.width, rhs.width) * 0.45
                        && verticalGap <= 2

                    guard sharesVisualRow || sharesVisualColumn else {
                        continue
                    }

                    merged[firstIndex] = lhs.union(rhs).integral
                    merged.remove(at: secondIndex)
                    didMerge = true
                    break outer
                }
            }
        }

        return merged
    }

    private static func sourceEraseRects(
        for drawableBlock: DrawableBlock,
        imageHeight: CGFloat,
        bounds: CGRect
    ) -> [CGRect] {
        if drawableBlock.block.translationStrategy == .block {
            let blockEraseBases = drawableBlock.sourceLineRects.isEmpty
                ? [drawableBlock.sourceRect]
                : drawableBlock.sourceLineRects
            return blockEraseBases.compactMap { sourceLineRect in
                let horizontalPadding = max(2, min(sourceLineRect.height * 0.12, 6))
                let verticalPadding = max(2, min(sourceLineRect.height * 0.16, 8))
                let rect = sourceLineRect
                    .insetBy(dx: -horizontalPadding, dy: -verticalPadding)
                    .intersection(bounds)
                    .integral
                return rect.width > 1 && rect.height > 1 ? rect : nil
            }
        }

        let preservedRects = drawableBlock.sourceCodeRects + drawableBlock.sourceProtectedRects
        if !drawableBlock.sourceTrailingAttachmentRects.isEmpty,
           !drawableBlock.sourceTextRects.isEmpty {
            let cleanupRects = continuousSelectiveCleanupRects(
                textRects: drawableBlock.sourceTextRects,
                attachmentRects: drawableBlock.sourceTrailingAttachmentRects,
                bounds: bounds
            )
            if !cleanupRects.isEmpty {
                return cleanupRects
            }
        }

        if hasReliableTextRects(drawableBlock) {
            var preciseEraseRects: [CGRect] = []
            for sourceTextRect in drawableBlock.sourceTextRects {
                let horizontalPadding = max(1, min(sourceTextRect.height * 0.08, 4))
                let verticalPadding = max(1, min(sourceTextRect.height * 0.12, 5))
                let eraseRect = sourceTextRect
                    .insetBy(dx: -horizontalPadding, dy: -verticalPadding)
                    .intersection(bounds)
                    .integral
                let segments = eraseRectsExcludingCode(
                    eraseRect,
                    codeRects: preservedRects,
                    bounds: bounds
                )
                preciseEraseRects.append(contentsOf: segments)
            }
            return preciseEraseRects.filter { $0.width > 1 && $0.height > 1 }
        }

        if !drawableBlock.sourceLineRects.isEmpty {
            var eraseRects: [CGRect] = []
            for sourceLineRect in drawableBlock.sourceLineRects {
                let horizontalPadding = max(2, min(sourceLineRect.height * 0.12, 6))
                let verticalPadding = max(2, min(sourceLineRect.height * 0.16, 8))
                let eraseRect = sourceLineRect
                    .insetBy(dx: -horizontalPadding, dy: -verticalPadding)
                    .intersection(bounds)
                    .integral
                eraseRects.append(contentsOf: eraseRectsExcludingCode(
                    eraseRect,
                    codeRects: preservedRects,
                    bounds: bounds
                ))
            }
            return eraseRects.filter { $0.width > 1 && $0.height > 1 }
        }

        if !drawableBlock.sourceTextRects.isEmpty {
            var eraseRects: [CGRect] = []
            for sourceTextRect in drawableBlock.sourceTextRects {
                let horizontalPadding = max(2, min(sourceTextRect.height * 0.12, 6))
                let verticalPadding = max(2, min(sourceTextRect.height * 0.16, 8))
                let eraseRect = sourceTextRect
                    .insetBy(dx: -horizontalPadding, dy: -verticalPadding)
                    .intersection(bounds)
                    .integral
                eraseRects.append(contentsOf: eraseRectsExcludingCode(
                    eraseRect,
                    codeRects: preservedRects,
                    bounds: bounds
                ))
            }
            return eraseRects.filter { $0.width > 1 && $0.height > 1 }
        }

        let sourceRect = drawableBlock.sourceRect.intersection(bounds)
        guard sourceRect.width > 1, sourceRect.height > 1 else {
            return []
        }

        let baseSize = TranslationTypography.baseFontSize(
            drawableBlock.block.fontSize,
            imageHeight: imageHeight,
            rect: sourceRect
        )
        let estimatedLineHeight = max(baseSize * 1.28, 2)
        let estimatedLineCount = max(
            1,
            min(10, Int((sourceRect.height / max(estimatedLineHeight * 0.92, 1)).rounded()))
        )
        let horizontalPadding = max(1, min(sourceRect.height * 0.08, 4))
        let verticalPadding = max(1, min(sourceRect.height * 0.06, 3))

        guard estimatedLineCount > 1 else {
            let eraseRect = sourceRect
                    .insetBy(dx: -horizontalPadding, dy: -verticalPadding)
                    .intersection(bounds)
                    .integral
            return eraseRectsExcludingCode(
                eraseRect,
                codeRects: preservedRects,
                bounds: bounds
            )
        }

        let step = sourceRect.height / CGFloat(estimatedLineCount)
        let patchHeight = min(step * 0.84, estimatedLineHeight * 1.10)

        var eraseRects: [CGRect] = []
        for index in 0..<estimatedLineCount {
            let y = sourceRect.maxY
                - CGFloat(index + 1) * step
                + max(0, (step - patchHeight) / 2)
            let eraseRect = CGRect(
                x: sourceRect.minX,
                y: y,
                width: sourceRect.width,
                height: patchHeight
            )
            .insetBy(dx: -horizontalPadding, dy: -verticalPadding)
            .intersection(bounds)
            .integral

            eraseRects.append(contentsOf: eraseRectsExcludingCode(
                eraseRect,
                codeRects: preservedRects,
                bounds: bounds
            ))
        }

        return eraseRects.filter { $0.width > 1 && $0.height > 1 }
    }

    private static func continuousSelectiveCleanupRects(
        textRects: [CGRect],
        attachmentRects: [CGRect],
        bounds: CGRect
    ) -> [CGRect] {
        attachmentRects.compactMap { attachmentRect in
            let matchingTextRects = textRects.filter { textRect in
                verticalOverlapRatio(textRect, attachmentRect) > 0.24
            }
            guard let leadingTextRect = matchingTextRects.min(by: { lhs, rhs in
                lhs.minX < rhs.minX
            }) else {
                return nil
            }

            let textLineRect = matchingTextRects.reduce(leadingTextRect) { partial, rect in
                partial.union(rect)
            }
            let union = textLineRect.union(attachmentRect)
            let horizontalPadding = max(2, min(union.height * 0.14, 7))
            let verticalPadding = max(1, min(union.height * 0.14, 6))
            var cleanupRect = union
                .insetBy(dx: -horizontalPadding, dy: -verticalPadding)
                .intersection(bounds)
                .integral
            cleanupRect.size.width = min(
                bounds.maxX - cleanupRect.minX,
                cleanupRect.width + max(2, attachmentRect.height * 0.10)
            )
            return cleanupRect.width > 1 && cleanupRect.height > 1
                ? cleanupRect
                : nil
        }
    }

    private static func hasReliableTextRects(_ drawableBlock: DrawableBlock) -> Bool {
        guard !drawableBlock.sourceTextRects.isEmpty else {
            return false
        }
        guard !drawableBlock.sourceLineRects.isEmpty else {
            return true
        }

        return drawableBlock.sourceLineRects.allSatisfy { lineRect in
            horizontalCoverage(
                of: drawableBlock.sourceTextRects.filter {
                    verticalOverlapRatio($0, lineRect) > 0.32
                },
                within: lineRect
            ) >= 0.42
        }
    }

    private static func horizontalCoverage(of rects: [CGRect], within lineRect: CGRect) -> CGFloat {
        let intervals = rects
            .compactMap { rect -> ClosedRange<CGFloat>? in
                let intersection = rect.intersection(lineRect)
                guard !intersection.isNull, intersection.width > 0 else {
                    return nil
                }
                return intersection.minX...intersection.maxX
            }
            .sorted { $0.lowerBound < $1.lowerBound }
        guard let first = intervals.first, lineRect.width > 0 else {
            return 0
        }

        var coveredWidth: CGFloat = 0
        var currentStart = first.lowerBound
        var currentEnd = first.upperBound
        for interval in intervals.dropFirst() {
            if interval.lowerBound <= currentEnd {
                currentEnd = max(currentEnd, interval.upperBound)
            } else {
                coveredWidth += currentEnd - currentStart
                currentStart = interval.lowerBound
                currentEnd = interval.upperBound
            }
        }
        coveredWidth += currentEnd - currentStart

        return min(max(coveredWidth / lineRect.width, 0), 1)
    }

    private static func eraseRectsExcludingCode(
        _ rect: CGRect,
        codeRects: [CGRect],
        bounds: CGRect
    ) -> [CGRect] {
        let blockers = codeRects
            .map { codeRect in
                let padding = max(1, min(codeRect.height * 0.10, 3))
                return codeRect.insetBy(dx: -padding, dy: -padding)
            }
            .filter { $0.intersects(rect) }
            .sorted { $0.minX < $1.minX }

        guard !blockers.isEmpty else {
            return [rect]
        }

        var segments: [CGRect] = []
        var cursorX = rect.minX

        for blocker in blockers {
            let clippedBlocker = blocker.intersection(rect)
            if clippedBlocker.minX > cursorX + 1 {
                segments.append(CGRect(
                    x: cursorX,
                    y: rect.minY,
                    width: clippedBlocker.minX - cursorX,
                    height: rect.height
                ))
            }
            cursorX = max(cursorX, clippedBlocker.maxX)
        }

        if cursorX < rect.maxX - 1 {
            segments.append(CGRect(
                x: cursorX,
                y: rect.minY,
                width: rect.maxX - cursorX,
                height: rect.height
            ))
        }

        return segments
            .map { $0.intersection(bounds).integral }
            .filter { $0.width > 1 && $0.height > 1 }
    }

    private static func drawTrailingAttachments(
        _ drawableBlock: DrawableBlock,
        imageHeight: CGFloat,
        bounds: CGRect,
        bitmap: NSBitmapImageRep
    ) {
        guard
            !drawableBlock.sourceTrailingAttachmentRects.isEmpty,
            let renderedTextRect = renderedInlineTextRect(
                for: drawableBlock,
                imageHeight: imageHeight
            ),
            let cgImage = bitmap.cgImage
        else {
            return
        }

        let sourceImage = NSImage(
            cgImage: cgImage,
            size: bounds.size
        )
        var cursorX = renderedTextRect.maxX
        for sourceRect in drawableBlock.sourceTrailingAttachmentRects {
            let gap = max(3, min(7, renderedTextRect.height * 0.22))
            let targetX = min(bounds.maxX - sourceRect.width, cursorX + gap)
            let targetY = min(
                bounds.maxY - sourceRect.height,
                max(bounds.minY, renderedTextRect.midY - sourceRect.height / 2)
            ).rounded()
            let targetRect = CGRect(
                x: max(bounds.minX, targetX).rounded(),
                y: targetY,
                width: sourceRect.width,
                height: sourceRect.height
            ).integral
            sourceImage.draw(
                in: targetRect,
                from: sourceRect,
                operation: .copy,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
            cursorX = targetRect.maxX
        }
    }

    private static func renderedInlineTextRect(
        for drawableBlock: DrawableBlock,
        imageHeight: CGFloat
    ) -> CGRect? {
        let block = drawableBlock.block
        guard block.translationStrategy == .selective else {
            return nil
        }
        let rect = drawableBlock.layoutRect
        let sourceHeight = drawableBlock.sourceRect.height
        let horizontalInset = min(max(1, sourceHeight * 0.05), max(1, rect.width * 0.035))
        let textRect = rect.insetBy(dx: horizontalInset, dy: 0)
        guard textRect.width > 1, textRect.height > 1 else {
            return nil
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = textAlignment(from: block.alignment)
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = TranslationTypography.lineSpacing(for: block, sourceHeight: sourceHeight)
        let layoutText = TranslationTypography.layoutMarkdown(for: block)
        let baseSize = TranslationTypography.typographicBaseFontSize(
            for: block,
            imageHeight: imageHeight,
            rect: CGRect(x: textRect.minX, y: textRect.minY, width: textRect.width, height: sourceHeight)
        )
        TranslationTypography.configureParagraphStyle(paragraph, for: block, fontSize: baseSize)
        let fontSize = TranslationTypography.fittingFontSize(
            for: layoutText,
            baseFontSize: baseSize,
            rect: textRect,
            weight: TranslationTypography.effectiveFontWeight(for: block),
            paragraph: paragraph,
            minimumFontSize: TranslationTypography.minimumReadableFontSize(baseSize)
        )
        TranslationTypography.configureParagraphStyle(paragraph, for: block, fontSize: fontSize)
        let rendered = TranslationTypography.attributedMarkdownLayout(
            layoutText,
            fontSize: fontSize,
            weight: TranslationTypography.effectiveFontWeight(for: block),
            foregroundColor: .labelColor,
            paragraph: paragraph
        )
        let measured = TranslationTypography.measuredAttributedTextSize(rendered.attributed, constrainedTo: textRect.width)
        let drawHeight = min(max(measured.height, fontSize), textRect.height)
        return CGRect(
            x: textRect.minX,
            y: min(max(textRect.minY, textRect.maxY - measured.height), textRect.maxY - drawHeight),
            width: min(measured.width, textRect.width),
            height: drawHeight
        )
    }

    private static func drawText(
        _ block: ImageTranslationBlock,
        in rect: CGRect,
        lineRects: [CGRect],
        codeRects: [CGRect],
        imageHeight: CGFloat,
        foregroundColor: NSColor,
        backgroundColor: NSColor,
        inlineCodeBackgroundColor: NSColor,
        alignment: NSTextAlignment,
        sourceHeight: CGFloat,
        preserveSourceCode: Bool,
        highlightPairs: [ImageTranslationHighlightPair],
        imageSize: CGSize
    ) -> [String: [CGRect]] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        // A two-character connector between fixed formulas must stay on one
        // baseline. Word wrapping otherwise chooses two tiny vertical glyphs.
        paragraph.lineBreakMode = isShortInlineConnector(block) ? .byClipping : .byWordWrapping
        paragraph.lineSpacing = TranslationTypography.lineSpacing(for: block, sourceHeight: sourceHeight)
        let horizontalInset = min(max(1, sourceHeight * 0.05), max(1, rect.width * 0.035))
        let textRect = rect.insetBy(dx: horizontalInset, dy: 0)
        let layoutText = TranslationTypography.layoutMarkdown(for: block)

        if let explicitHighlightRects = drawExplicitMarkdownLines(
            block,
            lineRects: lineRects,
            codeRects: codeRects,
            imageHeight: imageHeight,
            foregroundColor: foregroundColor,
            backgroundColor: backgroundColor,
            inlineCodeBackgroundColor: inlineCodeBackgroundColor,
            alignment: alignment,
            preserveSourceCode: preserveSourceCode,
            highlightPairs: highlightPairs,
            imageSize: imageSize
        ) {
            return explicitHighlightRects
        }

        let baseFontSize = TranslationTypography.typographicBaseFontSize(
            for: block,
            imageHeight: imageHeight,
            rect: CGRect(x: textRect.minX, y: textRect.minY, width: textRect.width, height: sourceHeight)
        )
        TranslationTypography.configureParagraphStyle(paragraph, for: block, fontSize: baseFontSize)
        let weight = TranslationTypography.effectiveFontWeight(for: block)
        let fontSize = TranslationTypography.fittingFontSize(
            for: layoutText,
            baseFontSize: baseFontSize,
            rect: textRect,
            weight: weight,
            paragraph: paragraph,
            minimumFontSize: TranslationTypography.minimumReadableFontSize(baseFontSize)
        )
        TranslationTypography.configureParagraphStyle(paragraph, for: block, fontSize: fontSize)
        let renderedText = TranslationTypography.attributedMarkdownLayout(
            layoutText,
            fontSize: fontSize,
            weight: weight,
            foregroundColor: foregroundColor,
            paragraph: paragraph,
            preserveCodeSpans: preserveSourceCode
        )
        let measured = TranslationTypography.measuredAttributedTextSize(renderedText.attributed, constrainedTo: textRect.width)
        let drawHeight = min(max(measured.height, fontSize), textRect.height)
        let topAlignedY = min(
            max(textRect.minY, textRect.maxY - measured.height),
            textRect.maxY - drawHeight
        )
        let verticallyCenteredY = min(
            max(textRect.minY, textRect.midY - drawHeight / 2),
            textRect.maxY - drawHeight
        )
        // A shorter paragraph still starts on the source's first row. Moving
        // it to the middle of the original paragraph separates list text from
        // its bullet and changes the vertical rhythm of surrounding content.
        let shouldCenterShortTranslation = alignment == .center
            && lineRects.count > 1
            && !layoutText.contains("\n")
            && drawHeight <= textRect.height * 0.68
        let drawRect = CGRect(
            x: textRect.minX,
            y: shouldCenterShortTranslation ? verticallyCenteredY : topAlignedY,
            width: textRect.width,
            height: drawHeight
        )

        if !preserveSourceCode {
            TranslationTypography.drawCodeChipBackgrounds(
                for: renderedText,
                in: drawRect,
                color: inlineCodeBackgroundColor,
                fontSize: fontSize
            )
        }

        renderedText.attributed.draw(
            with: drawRect,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        return exactHighlightRects(
            for: highlightPairs,
            layouts: [TextHighlightLayout(attributed: renderedText.attributed, drawRect: drawRect)],
            imageSize: imageSize
        )
    }

    private static func drawExplicitMarkdownLines(
        _ block: ImageTranslationBlock,
        lineRects: [CGRect],
        codeRects: [CGRect],
        imageHeight: CGFloat,
        foregroundColor: NSColor,
        backgroundColor: NSColor,
        inlineCodeBackgroundColor: NSColor,
        alignment: NSTextAlignment,
        preserveSourceCode: Bool,
        highlightPairs: [ImageTranslationHighlightPair],
        imageSize: CGSize
    ) -> [String: [CGRect]]? {
        let layoutText = TranslationTypography.layoutMarkdown(for: block)
        let explicitLines = layoutText.components(separatedBy: .newlines)
        let lines: [String]
        if explicitLines.count > 1 {
            guard explicitLines.count == lineRects.count else {
                return nil
            }
            lines = explicitLines
        } else if let wrappedLines = automaticMarkdownLines(
                    for: layoutText,
                    lineRects: lineRects,
                    codeRects: codeRects,
                    imageHeight: imageHeight,
                    block: block,
                    weight: TranslationTypography.effectiveFontWeight(for: block),
                    alignment: alignment
                  ) {
            lines = wrappedLines
        } else {
            return nil
        }

        if explicitLines.count > 1,
           block.translationStrategy == .block,
           block.protectedRects.isEmpty,
           block.codeRects.isEmpty,
           block.trailingAttachments.isEmpty {
            // An OCR line is a preferred anchor, not permission to discard the
            // translated suffix. If a supplied line cannot fit at a readable
            // size, let the normal paragraph path wrap inside this same block.
            for (line, lineRect) in zip(lines, lineRects) {
                let inset = min(max(1, lineRect.height * 0.08), max(1, lineRect.width * 0.035))
                let textRect = lineRect.insetBy(dx: inset, dy: 0)
                let minimumSize = TranslationTypography.minimumReadableFontSize(TranslationTypography.typographicBaseFontSize(
                    for: block,
                    imageHeight: imageHeight,
                    rect: textRect
                ))
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineBreakMode = .byClipping
                TranslationTypography.configureParagraphStyle(paragraph, for: block, fontSize: minimumSize)
                if measuredMarkdownLineWidth(
                    line,
                    fontSize: minimumSize,
                    weight: TranslationTypography.effectiveFontWeight(for: block),
                    paragraph: paragraph
                ) > textRect.width {
                    return nil
                }
            }
        }

        // Wrapped/explicit rows of one paragraph share a font too. Fitting
        // every line independently makes the longest line visibly smaller.
        let sharedFontSize: CGFloat? = codeRects.isEmpty && block.translationStrategy == .block
            ? zip(lines, lineRects).map { line, lineRect in
                let inset = min(max(1, lineRect.height * 0.08), max(1, lineRect.width * 0.035))
                let textRect = lineRect.insetBy(dx: inset, dy: 0)
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = alignment
                paragraph.lineBreakMode = .byClipping
                let base = TranslationTypography.typographicBaseFontSize(for: block, imageHeight: imageHeight, rect: textRect)
                TranslationTypography.configureParagraphStyle(paragraph, for: block, fontSize: base)
                return TranslationTypography.fittingFontSize(for: line, baseFontSize: base, rect: textRect,
                    weight: TranslationTypography.effectiveFontWeight(for: block), paragraph: paragraph,
                    minimumFontSize: TranslationTypography.minimumReadableFontSize(base))
            }.min() : nil
        let lefts = lineRects.map(\.minX).sorted()
        let commonLeft = lefts[lefts.count / 2]
        var highlightLayouts: [TextHighlightLayout] = []
        for (line, rawLineRect) in zip(lines, lineRects) {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                continue
            }

            var lineRect = rawLineRect.integral
            if alignment == .left, abs(lineRect.minX - commonLeft) <= min(3, lineRect.height * 0.12) {
                // Smooth only OCR jitter; retain first-line and hanging indents.
                lineRect = CGRect(x: commonLeft, y: lineRect.minY,
                    width: lineRect.maxX - commonLeft, height: lineRect.height)
            }
            let horizontalInset = min(max(1, lineRect.height * 0.08), max(1, lineRect.width * 0.035))
            let textRect = lineRect.insetBy(dx: horizontalInset, dy: 0)
            guard textRect.width > 1, textRect.height > 1 else {
                continue
            }

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = alignment
            paragraph.lineBreakMode = .byClipping
            paragraph.lineSpacing = 0

            let baseFontSize = TranslationTypography.typographicBaseFontSize(
                for: block,
                imageHeight: imageHeight,
                rect: textRect
            )
            TranslationTypography.configureParagraphStyle(paragraph, for: block, fontSize: baseFontSize)

            let lineCodeRects = codeRects
                .filter { verticalOverlapRatio($0, lineRect) > 0.22 }
                .sorted { $0.minX < $1.minX }
            if !lineCodeRects.isEmpty,
               drawMarkdownLineAroundSourceCode(
                text,
                in: textRect,
                codeRects: lineCodeRects,
                imageHeight: imageHeight,
                foregroundColor: foregroundColor,
                weight: TranslationTypography.effectiveFontWeight(for: block),
                paragraph: paragraph,
                block: block
               ) {
                continue
            }

            let weight = TranslationTypography.effectiveFontWeight(for: block)
            let fontSize = sharedFontSize ?? TranslationTypography.fittingFontSize(
                for: text,
                baseFontSize: baseFontSize,
                rect: textRect,
                weight: weight,
                paragraph: paragraph,
                minimumFontSize: TranslationTypography.minimumReadableFontSize(baseFontSize)
            )
            TranslationTypography.configureParagraphStyle(paragraph, for: block, fontSize: fontSize)
            let renderedText = TranslationTypography.attributedMarkdownLayout(
                text,
                fontSize: fontSize,
                weight: weight,
                foregroundColor: foregroundColor,
                paragraph: paragraph,
                preserveCodeSpans: preserveSourceCode
            )
            if sharedFontSize != nil, alignment == .left, !text.contains("`"),
               TranslationTypography.normalizedKind(block.kind) != "list_item" {
                let reference = NSAttributedString(string: "国Ag", attributes: [
                    .font: TranslationTypography.proseFont(ofSize: fontSize, weight: weight)
                ])
                var ascent: CGFloat = 0, descent: CGFloat = 0
                CTLineGetTypographicBounds(CTLineCreateWithAttributedString(reference), &ascent, &descent, nil)
                let baseline = CGPoint(x: textRect.minX, y: textRect.maxY - ascent)
                let layout = TextHighlightLayout(attributed: renderedText.attributed,
                    drawRect: CGRect(x: textRect.minX, y: baseline.y - descent,
                        width: textRect.width, height: ascent + descent), baseline: baseline)
                drawTextLayout(layout)
                highlightLayouts.append(layout)
                continue
            }
            let measured = TranslationTypography.measuredAttributedTextSize(renderedText.attributed, constrainedTo: textRect.width)
            let drawHeight = min(max(measured.height, fontSize), textRect.height)
            let drawRect = CGRect(
                x: textRect.minX,
                y: min(max(textRect.minY, textRect.midY - drawHeight / 2), textRect.maxY - drawHeight),
                width: textRect.width,
                height: drawHeight
            )

            if !preserveSourceCode {
                TranslationTypography.drawCodeChipBackgrounds(
                    for: renderedText,
                    in: drawRect,
                    color: inlineCodeBackgroundColor,
                    fontSize: fontSize
                )
            }

            renderedText.attributed.draw(
                with: drawRect,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )
            highlightLayouts.append(TextHighlightLayout(
                attributed: renderedText.attributed,
                drawRect: drawRect
            ))
        }

        return exactHighlightRects(
            for: highlightPairs,
            layouts: highlightLayouts,
            imageSize: imageSize
        )
    }

    struct TextHighlightLayout {
        let attributed: NSAttributedString
        let drawRect: CGRect
        /// Single-row layouts use the same baseline for drawing, collision
        /// checks and selection. Other layouts retain TextKit wrapping.
        var baseline: CGPoint? = nil
    }



}
