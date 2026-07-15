import AppKit
import Foundation

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

    static func render(source pickedImage: PickedImage, blocks: [ImageTranslationBlock]) -> NSImage? {
        guard !Task.isCancelled else { return nil }
        guard let cgImage = sourceCGImage(from: pickedImage) else {
            return nil
        }

        let imageSize = NSSize(width: cgImage.width, height: cgImage.height)
        let bounds = CGRect(origin: .zero, size: imageSize)
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let backgroundSourceImage = NSImage(cgImage: cgImage, size: imageSize)
        let output = (pickedImage.image.copy() as? NSImage) ?? NSImage(cgImage: cgImage, size: imageSize)
        output.size = imageSize

        output.lockFocus()
        defer {
            output.unlockFocus()
        }

        let translatedBlocks = blocks.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !translatedBlocks.isEmpty else {
            return output
        }

        let drawableBlocks = layoutDrawableBlocks(
            blocks: translatedBlocks,
            imageSize: imageSize,
            bounds: bounds,
        )
        let canvasBackgroundColor = semanticCanvasBackground(
            bitmap: bitmap,
            bounds: bounds
        )
        for drawableBlock in drawableBlocks {
            guard !Task.isCancelled else { return nil }
            draw(
                drawableBlock,
                imageSize: imageSize,
                bounds: bounds,
                bitmap: bitmap,
                backgroundSourceImage: backgroundSourceImage,
                canvasBackgroundColor: canvasBackgroundColor
            )
        }

        return output
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
            sampledColor(appKitX: point.x, appKitY: point.y, bitmap: bitmap, bounds: bounds)
        }

        return dominantBackgroundColor(colors)
            ?? averageColor(colors)
            ?? .windowBackgroundColor
    }

    private struct DrawableBlock {
        let block: ImageTranslationBlock
        let sourceRect: CGRect
        let sourceLineRects: [CGRect]
        let sourceTextRects: [CGRect]
        let sourceProtectedRects: [CGRect]
        let sourceTrailingAttachmentRects: [CGRect]
        let sourceCodeRects: [CGRect]
        let layoutLineRects: [CGRect]
        let layoutRect: CGRect
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
                bounds: bounds
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
        let translatedCodeTexts = inlineMarkdownSpans(block.text)
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

    private static func draw(
        _ drawableBlock: DrawableBlock,
        imageSize: CGSize,
        bounds: CGRect,
        bitmap: NSBitmapImageRep,
        backgroundSourceImage: NSImage,
        canvasBackgroundColor: NSColor
    ) {
        let block = drawableBlock.block
        let rect = drawableBlock.layoutRect.intersection(bounds).integral
        guard rect.width > 1, rect.height > 1 else {
            return
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
        let sampledLocalBackgroundColor = sampledBackgroundColor(
                in: backgroundSampleRect,
                bitmap: bitmap
            )
            ?? dominantInteriorBackgroundColor(
                in: eraseRects,
                bitmap: bitmap,
                bounds: bounds
            )
            ?? color(from: block.backgroundColor)
            ?? .windowBackgroundColor
        let backgroundColor = harmonizedBackgroundColor(
            sampledLocalBackgroundColor,
            canvasBackgroundColor: canvasBackgroundColor
        )
        let foregroundColor = color(from: block.textColor)
            ?? sampledForegroundColor(
                in: drawableBlock.sourceTextRects.isEmpty
                    ? drawableBlock.sourceLineRects
                    : drawableBlock.sourceTextRects,
                bitmap: bitmap,
                backgroundColor: backgroundColor,
                bounds: bounds
            )
            ?? readableTextColor(on: backgroundColor)
        let inlineCodeBackgroundColor = dominantInteriorBackgroundColor(
            in: drawableBlock.sourceCodeRects,
            bitmap: bitmap,
            bounds: bounds
        ) ?? codeChipColor(on: backgroundColor)
        let backgroundPatchSourceRect = backgroundPatchSourceRect(
            around: backgroundSampleRect,
            matching: backgroundColor,
            bitmap: bitmap,
            bounds: bounds
        )

        for eraseRect in mergedEraseRects(eraseRects) {
            paintBackgroundPatch(
                in: eraseRect,
                sourceImage: backgroundSourceImage,
                sourceRect: backgroundPatchSourceRect,
                color: backgroundColor
            )
        }

        for attachmentRect in drawableBlock.sourceTrailingAttachmentRects {
            let padding = max(1, min(attachmentRect.height * 0.08, 3))
            paintBackgroundPatch(
                in: attachmentRect.insetBy(dx: -padding, dy: -padding).intersection(bounds).integral,
                sourceImage: backgroundSourceImage,
                sourceRect: backgroundPatchSourceRect,
                color: backgroundColor
            )
        }

        let preservesSourceCode = block.translationStrategy == .selective
            && !drawableBlock.sourceCodeRects.isEmpty
        drawText(
            block,
            in: rect,
            lineRects: drawableBlock.layoutLineRects,
            codeRects: preservesSourceCode ? drawableBlock.sourceCodeRects : [],
            imageHeight: imageSize.height,
            foregroundColor: foregroundColor,
            backgroundColor: backgroundColor,
            inlineCodeBackgroundColor: inlineCodeBackgroundColor,
            alignment: textAlignment(from: block.alignment),
            sourceHeight: drawableBlock.sourceRect.height,
            preserveSourceCode: preservesSourceCode
        )

        drawTrailingAttachments(
            drawableBlock,
            imageHeight: imageSize.height,
            bounds: bounds,
            bitmap: bitmap
        )
    }

    private static func paintBackgroundPatch(
        in rect: CGRect,
        sourceImage: NSImage,
        sourceRect: CGRect?,
        color: NSColor
    ) {
        if let sourceRect, sourceRect.width > 0, sourceRect.height > 0 {
            sourceImage.draw(
                in: rect,
                from: sourceRect,
                operation: .copy,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.none]
            )
            return
        }

        let fillColor: NSColor
        if let sourceColor = color.usingColorSpace(.sRGB) {
            fillColor = NSColor(
                deviceRed: sourceColor.redComponent,
                green: sourceColor.greenComponent,
                blue: sourceColor.blueComponent,
                alpha: 1
            )
        } else {
            fillColor = color
        }
        fillColor.setFill()
        NSBezierPath(rect: rect).fill()
    }

    /// Selects an untouched source pixel near the text block so erasing old text
    /// preserves the screenshot's exact color profile instead of repainting an
    /// approximately matching `NSColor` that can shift after ColorSync conversion.
    private static func backgroundPatchSourceRect(
        around rect: CGRect,
        matching backgroundColor: NSColor,
        bitmap: NSBitmapImageRep,
        bounds: CGRect
    ) -> CGRect? {
        let sampleOffset = max(2, min(10, rect.height * 0.20))
        let fractions: [CGFloat] = [0.08, 0.22, 0.38, 0.5, 0.62, 0.78, 0.92]
        var points: [CGPoint] = []

        for fraction in fractions {
            points.append(CGPoint(x: rect.minX + rect.width * fraction, y: rect.minY - sampleOffset))
            points.append(CGPoint(x: rect.minX + rect.width * fraction, y: rect.maxY + sampleOffset))
            points.append(CGPoint(x: rect.minX - sampleOffset, y: rect.minY + rect.height * fraction))
            points.append(CGPoint(x: rect.maxX + sampleOffset, y: rect.minY + rect.height * fraction))
        }

        let candidates = points.compactMap { point -> (point: CGPoint, distance: CGFloat)? in
            guard bounds.contains(point), let color = sampledColor(
                appKitX: point.x,
                appKitY: point.y,
                bitmap: bitmap,
                bounds: bounds
            ) else {
                return nil
            }
            return (point, rgbDistance(color, backgroundColor))
        }
        guard let candidate = candidates.min(by: { $0.distance < $1.distance }) else {
            return nil
        }

        let pixelWidth = max(1, bounds.width / CGFloat(max(bitmap.pixelsWide, 1)))
        let pixelHeight = max(1, bounds.height / CGFloat(max(bitmap.pixelsHigh, 1)))
        return CGRect(
            x: floor(candidate.point.x),
            y: floor(candidate.point.y),
            width: pixelWidth,
            height: pixelHeight
        ).intersection(bounds)
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

        let baseSize = baseFontSize(
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
            size: NSSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
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
        paragraph.lineSpacing = lineSpacing(for: block, sourceHeight: sourceHeight)
        let layoutText = layoutMarkdown(for: block)
        let baseSize = typographicBaseFontSize(
            for: block,
            imageHeight: imageHeight,
            rect: CGRect(x: textRect.minX, y: textRect.minY, width: textRect.width, height: sourceHeight)
        )
        configureParagraphStyle(paragraph, for: block, fontSize: baseSize)
        let fontSize = fittingFontSize(
            for: layoutText,
            baseFontSize: baseSize,
            rect: textRect,
            weight: effectiveFontWeight(for: block),
            paragraph: paragraph,
            minimumFontSize: max(6, baseSize * 0.50)
        )
        configureParagraphStyle(paragraph, for: block, fontSize: fontSize)
        let rendered = attributedMarkdownLayout(
            layoutText,
            fontSize: fontSize,
            weight: effectiveFontWeight(for: block),
            foregroundColor: .labelColor,
            paragraph: paragraph
        )
        let measured = measuredAttributedTextSize(rendered.attributed, constrainedTo: textRect.width)
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
        preserveSourceCode: Bool
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = lineSpacing(for: block, sourceHeight: sourceHeight)
        let horizontalInset = min(max(1, sourceHeight * 0.05), max(1, rect.width * 0.035))
        let textRect = rect.insetBy(dx: horizontalInset, dy: 0)
        let layoutText = layoutMarkdown(for: block)

        if drawExplicitMarkdownLines(
            block,
            lineRects: lineRects,
            codeRects: codeRects,
            imageHeight: imageHeight,
            foregroundColor: foregroundColor,
            backgroundColor: backgroundColor,
            inlineCodeBackgroundColor: inlineCodeBackgroundColor,
            alignment: alignment,
            preserveSourceCode: preserveSourceCode
        ) {
            return
        }

        let baseFontSize = typographicBaseFontSize(
            for: block,
            imageHeight: imageHeight,
            rect: CGRect(x: textRect.minX, y: textRect.minY, width: textRect.width, height: sourceHeight)
        )
        configureParagraphStyle(paragraph, for: block, fontSize: baseFontSize)
        let weight = effectiveFontWeight(for: block)
        let fontSize = fittingFontSize(
            for: layoutText,
            baseFontSize: baseFontSize,
            rect: textRect,
            weight: weight,
            paragraph: paragraph,
            minimumFontSize: max(6, baseFontSize * 0.50)
        )
        configureParagraphStyle(paragraph, for: block, fontSize: fontSize)
        let renderedText = attributedMarkdownLayout(
            layoutText,
            fontSize: fontSize,
            weight: weight,
            foregroundColor: foregroundColor,
            paragraph: paragraph,
            preserveCodeSpans: preserveSourceCode
        )
        let measured = measuredAttributedTextSize(renderedText.attributed, constrainedTo: textRect.width)
        let drawHeight = min(max(measured.height, fontSize), textRect.height)
        let topAlignedY = min(
            max(textRect.minY, textRect.maxY - measured.height),
            textRect.maxY - drawHeight
        )
        let verticallyCenteredY = min(
            max(textRect.minY, textRect.midY - drawHeight / 2),
            textRect.maxY - drawHeight
        )
        let shouldCenterShortTranslation = lineRects.count > 1
            && !layoutText.contains("\n")
            && drawHeight <= textRect.height * 0.68
        let drawRect = CGRect(
            x: textRect.minX,
            y: shouldCenterShortTranslation ? verticallyCenteredY : topAlignedY,
            width: textRect.width,
            height: drawHeight
        )

        if !preserveSourceCode {
            drawCodeChipBackgrounds(
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
    }

    @discardableResult
    private static func drawExplicitMarkdownLines(
        _ block: ImageTranslationBlock,
        lineRects: [CGRect],
        codeRects: [CGRect],
        imageHeight: CGFloat,
        foregroundColor: NSColor,
        backgroundColor: NSColor,
        inlineCodeBackgroundColor: NSColor,
        alignment: NSTextAlignment,
        preserveSourceCode: Bool
    ) -> Bool {
        let layoutText = layoutMarkdown(for: block)
        let explicitLines = layoutText.components(separatedBy: .newlines)
        let lines: [String]
        if explicitLines.count > 1 {
            guard explicitLines.count == lineRects.count else {
                return false
            }
            lines = explicitLines
        } else if let wrappedLines = automaticMarkdownLines(
                    for: layoutText,
                    lineRects: lineRects,
                    codeRects: codeRects,
                    imageHeight: imageHeight,
                    block: block,
                    weight: effectiveFontWeight(for: block),
                    alignment: alignment
                  ) {
            lines = wrappedLines
        } else {
            return false
        }

        for (line, rawLineRect) in zip(lines, lineRects) {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                continue
            }

            let lineRect = rawLineRect.integral
            let horizontalInset = min(max(1, lineRect.height * 0.08), max(1, lineRect.width * 0.035))
            let textRect = lineRect.insetBy(dx: horizontalInset, dy: 0)
            guard textRect.width > 1, textRect.height > 1 else {
                continue
            }

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = alignment
            paragraph.lineBreakMode = .byTruncatingTail
            paragraph.lineSpacing = 0

            let baseFontSize = typographicBaseFontSize(
                for: block,
                imageHeight: imageHeight,
                rect: textRect
            )
            configureParagraphStyle(paragraph, for: block, fontSize: baseFontSize)

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
                weight: effectiveFontWeight(for: block),
                paragraph: paragraph,
                block: block
               ) {
                continue
            }

            let weight = effectiveFontWeight(for: block)
            let fontSize = fittingFontSize(
                for: text,
                baseFontSize: baseFontSize,
                rect: textRect,
                weight: weight,
                paragraph: paragraph,
                minimumFontSize: max(6, baseFontSize * 0.56)
            )
            configureParagraphStyle(paragraph, for: block, fontSize: fontSize)
            let renderedText = attributedMarkdownLayout(
                text,
                fontSize: fontSize,
                weight: weight,
                foregroundColor: foregroundColor,
                paragraph: paragraph,
                preserveCodeSpans: preserveSourceCode
            )
            let measured = measuredAttributedTextSize(renderedText.attributed, constrainedTo: textRect.width)
            let drawHeight = min(max(measured.height, fontSize), textRect.height)
            let drawRect = CGRect(
                x: textRect.minX,
                y: min(max(textRect.minY, textRect.midY - drawHeight / 2), textRect.maxY - drawHeight),
                width: textRect.width,
                height: drawHeight
            )

            if !preserveSourceCode {
                drawCodeChipBackgrounds(
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
        }

        return true
    }

    private struct MarkdownLineToken {
        let markdown: String
        let plainText: String
        let isCode: Bool
    }

    private static func automaticMarkdownLines(
        for markdown: String,
        lineRects: [CGRect],
        codeRects: [CGRect],
        imageHeight: CGFloat,
        block: ImageTranslationBlock,
        weight: NSFont.Weight,
        alignment: NSTextAlignment
    ) -> [String]? {
        guard lineRects.count > 1, !markdown.contains("\n") else {
            return nil
        }

        return ImageTranslationMarkdownLineLayout.lines(
            for: markdown,
            lineRects: lineRects,
            codeRects: codeRects,
            availableWidth: { lineRect in
                let horizontalInset = min(max(1, lineRect.height * 0.08), max(1, lineRect.width * 0.035))
                return max(1, lineRect.width - horizontalInset * 2)
            },
            measuredWidth: { candidateText, lineRect in
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = alignment
                paragraph.lineBreakMode = .byTruncatingTail
                paragraph.lineSpacing = 0
                let fontSize = typographicBaseFontSize(
                    for: block,
                    imageHeight: imageHeight,
                    rect: lineRect
                )
                configureParagraphStyle(paragraph, for: block, fontSize: fontSize)
                return measuredMarkdownLineWidth(
                    candidateText,
                    fontSize: fontSize,
                    weight: weight,
                    paragraph: paragraph
                )
            }
        )
    }

    private static func codeLineIndices(
        for codeRects: [CGRect],
        lineRects: [CGRect],
        expectedCodeCount: Int
    ) -> [Int]? {
        guard !codeRects.isEmpty else {
            return []
        }
        guard expectedCodeCount == codeRects.count else {
            return nil
        }

        let indexedCodeRects = codeRects.compactMap { codeRect -> (rect: CGRect, lineIndex: Int)? in
            guard let lineIndex = bestLineIndex(for: codeRect, in: lineRects) else {
                return nil
            }
            return (codeRect, lineIndex)
        }
        guard indexedCodeRects.count == codeRects.count else {
            return nil
        }

        return indexedCodeRects
            .sorted { lhs, rhs in
                if lhs.lineIndex != rhs.lineIndex {
                    return lhs.lineIndex < rhs.lineIndex
                }
                return lhs.rect.minX < rhs.rect.minX
            }
            .map(\.lineIndex)
    }

    private static func bestLineIndex(for rect: CGRect, in lineRects: [CGRect]) -> Int? {
        lineRects.indices
            .map { index in
                (
                    index: index,
                    overlap: verticalOverlapRatio(rect, lineRects[index])
                )
            }
            .filter { $0.overlap > 0.22 }
            .max { lhs, rhs in lhs.overlap < rhs.overlap }?
            .index
    }

    private static func markdownLineTokens(_ markdown: String) -> [MarkdownLineToken] {
        inlineMarkdownSpans(markdown).flatMap { span -> [MarkdownLineToken] in
            if span.isCode {
                return [
                    MarkdownLineToken(
                        markdown: "`\(span.text)`",
                        plainText: span.text,
                        isCode: true
                    )
                ]
            }

            return naturalTextTokens(span.text).map { token in
                MarkdownLineToken(markdown: token, plainText: token, isCode: false)
            }
        }
    }

    private static func naturalTextTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""

        func flushCurrent() {
            if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }

        for character in text {
            if character.isWhitespace {
                flushCurrent()
            } else if isCJKCharacter(character) {
                flushCurrent()
                tokens.append(String(character))
            } else if isCJKPunctuation(character) {
                if current.isEmpty {
                    tokens.append(String(character))
                } else {
                    current.append(character)
                    flushCurrent()
                }
            } else {
                current.append(character)
            }
        }
        flushCurrent()

        return tokens
    }

    private static func markdownLine(from tokens: [MarkdownLineToken]) -> String {
        var result = ""
        var previous: MarkdownLineToken?

        for token in tokens {
            if result.isEmpty {
                result = token.markdown
            } else {
                if let previous {
                    if isListMarker(previous.plainText) {
                        result += "\t"
                    } else if shouldInsertSpace(between: previous.plainText, and: token.plainText) {
                        result += " "
                    }
                }
                result += token.markdown
            }
            previous = token
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isListMarker(_ text: String) -> Bool {
        ["•", "·", "▪", "◦", "-", "*"].contains(text)
    }

    private static func shouldInsertSpace(between lhs: String, and rhs: String) -> Bool {
        guard let lhsLast = lhs.last, let rhsFirst = rhs.first else {
            return false
        }

        if isClosingPunctuation(rhsFirst) || isOpeningPunctuation(lhsLast) {
            return false
        }

        if isCJKCharacter(lhsLast), isCJKCharacter(rhsFirst) {
            return false
        }

        return isASCIIAlphanumeric(lhsLast)
            || isASCIIAlphanumeric(rhsFirst)
            || lhsLast == "•"
            || lhsLast == "-"
    }

    private static func measuredMarkdownLineWidth(
        _ markdown: String,
        fontSize: CGFloat,
        weight: NSFont.Weight,
        paragraph: NSParagraphStyle
    ) -> CGFloat {
        let attributed = attributedMarkdown(
            markdown,
            fontSize: fontSize,
            weight: weight,
            foregroundColor: .labelColor,
            paragraph: paragraph,
            codeBackgroundColor: .clear
        )
        return measuredAttributedTextSize(attributed, constrainedTo: 10_000).width
    }

    private static func drawMarkdownLineAroundSourceCode(
        _ markdown: String,
        in lineRect: CGRect,
        codeRects: [CGRect],
        imageHeight: CGFloat,
        foregroundColor: NSColor,
        weight: NSFont.Weight,
        paragraph: NSMutableParagraphStyle,
        block: ImageTranslationBlock
    ) -> Bool {
        let spans = inlineMarkdownSpans(markdown)
        let codeSpans = spans.filter(\.isCode)
        guard !codeSpans.isEmpty, codeSpans.count == codeRects.count else {
            return false
        }

        var codeIndex = 0
        var cursorX = lineRect.minX
        for span in spans {
            if span.isCode {
                cursorX = max(cursorX, codeRects[codeIndex].maxX + max(2, lineRect.height * 0.16))
                codeIndex += 1
                continue
            }

            let text = trimmedSegmentText(span.text)
            guard !text.isEmpty else {
                continue
            }

            let nextCodeMinX = codeIndex < codeRects.count ? codeRects[codeIndex].minX : lineRect.maxX
            let segmentRect = CGRect(
                x: cursorX,
                y: lineRect.minY,
                width: max(0, nextCodeMinX - cursorX - max(1, lineRect.height * 0.10)),
                height: lineRect.height
            )
            guard segmentRect.width > 1, segmentRect.height > 1 else {
                continue
            }

            let baseFontSize = typographicBaseFontSize(
                for: block,
                imageHeight: imageHeight,
                rect: segmentRect
            )
            configureParagraphStyle(paragraph, for: block, fontSize: baseFontSize)
            let fontSize = fittingFontSize(
                for: text,
                baseFontSize: baseFontSize,
                rect: segmentRect,
                weight: weight,
                paragraph: paragraph,
                minimumFontSize: max(6, baseFontSize * 0.56)
            )
            configureParagraphStyle(paragraph, for: block, fontSize: fontSize)
            let attributed = NSAttributedString(
                string: text,
                attributes: [
                    .font: NSFont.systemFont(ofSize: fontSize, weight: weight),
                    .foregroundColor: foregroundColor,
                    .paragraphStyle: paragraph
                ]
            )
            let measured = measuredAttributedTextSize(attributed, constrainedTo: segmentRect.width)
            let drawHeight = min(max(measured.height, fontSize), segmentRect.height)
            let drawRect = CGRect(
                x: segmentRect.minX,
                y: min(max(segmentRect.minY, segmentRect.midY - drawHeight / 2), segmentRect.maxY - drawHeight),
                width: segmentRect.width,
                height: drawHeight
            )
            attributed.draw(
                with: drawRect,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )
        }

        return true
    }

    private static func trimmedSegmentText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isCJKCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(Int(scalar.value))
                || (0x3400...0x4DBF).contains(Int(scalar.value))
                || (0x3040...0x30FF).contains(Int(scalar.value))
                || (0xAC00...0xD7AF).contains(Int(scalar.value))
        }
    }

    private static func isCJKPunctuation(_ character: Character) -> Bool {
        "，。！？；：、（）《》“”‘’".contains(character)
    }

    private static func isOpeningPunctuation(_ character: Character) -> Bool {
        "([{（《“‘".contains(character)
    }

    private static func isClosingPunctuation(_ character: Character) -> Bool {
        ".,;:!?)]}，。！？；：、）》”’".contains(character)
    }

    private static func isASCIIAlphanumeric(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII
        }
    }

    private static func blockRect(_ block: ImageTranslationBlock, imageSize: CGSize) -> CGRect {
        let width = CGFloat(block.width) * imageSize.width
        let height = CGFloat(block.height) * imageSize.height
        let x = CGFloat(block.x) * imageSize.width
        let y = imageSize.height - (CGFloat(block.y) * imageSize.height) - height

        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func baseFontSize(_ requested: Double?, imageHeight: CGFloat, rect: CGRect) -> CGFloat {
        if let requested, requested > 0 {
            if requested <= 1 {
                return min(CGFloat(requested) * imageHeight, rect.height * 0.92)
            }
            return min(CGFloat(requested), rect.height * 0.92)
        }

        return min(max(rect.height * 0.68, 8), 48)
    }

    private static func typographicBaseFontSize(
        for block: ImageTranslationBlock,
        imageHeight: CGFloat,
        rect: CGRect
    ) -> CGFloat {
        let inferred = baseFontSize(
            block.fontSize,
            imageHeight: imageHeight,
            rect: rect
        )

        switch normalizedKind(block.kind) {
        case "title":
            return min(rect.height * 0.92, inferred * 1.05)
        case "heading":
            return min(rect.height * 0.92, inferred * 1.10)
        case "caption":
            return min(rect.height * 0.88, inferred * 0.96)
        default:
            return min(rect.height * 0.90, inferred)
        }
    }

    private static func layoutMarkdown(for block: ImageTranslationBlock) -> String {
        let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedKind(block.kind) == "list_item" else {
            return text
        }

        let content: String
        if text.hasPrefix("•") || text.hasPrefix("·") || text.hasPrefix("▪") || text.hasPrefix("◦") {
            content = String(text.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if text.hasPrefix("- ") || text.hasPrefix("* ") {
            content = String(text.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            content = text
        }

        return content.isEmpty ? "•" : "•\t\(content)"
    }

    private static func configureParagraphStyle(
        _ paragraph: NSMutableParagraphStyle,
        for block: ImageTranslationBlock,
        fontSize: CGFloat
    ) {
        guard normalizedKind(block.kind) == "list_item" else {
            paragraph.firstLineHeadIndent = 0
            paragraph.headIndent = 0
            paragraph.tabStops = []
            paragraph.paragraphSpacing = 0
            return
        }

        let contentIndent = max(8, fontSize * 1.05)
        paragraph.firstLineHeadIndent = 0
        paragraph.headIndent = contentIndent
        paragraph.defaultTabInterval = contentIndent
        paragraph.tabStops = [
            NSTextTab(
                textAlignment: .left,
                location: contentIndent,
                options: [:]
            )
        ]
        paragraph.paragraphSpacing = max(1, fontSize * 0.16)
    }

    private static func effectiveFontWeight(for block: ImageTranslationBlock) -> NSFont.Weight {
        let explicitWeight = fontWeight(from: block.weight)
        if block.weight != nil {
            return explicitWeight
        }

        switch normalizedKind(block.kind) {
        case "title", "heading":
            return .semibold
        default:
            return explicitWeight
        }
    }

    private static func lineSpacing(for block: ImageTranslationBlock, sourceHeight: CGFloat) -> CGFloat {
        switch normalizedKind(block.kind) {
        case "title", "heading":
            return max(0, sourceHeight * 0.02)
        case "caption", "code":
            return 0
        default:
            return max(0, sourceHeight * 0.04)
        }
    }

    private static func normalizedKind(_ kind: String?) -> String {
        kind?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_") ?? "paragraph"
    }

    private static func fittingFontSize(
        for text: String,
        baseFontSize: CGFloat,
        rect: CGRect,
        weight: NSFont.Weight,
        paragraph: NSParagraphStyle,
        minimumFontSize: CGFloat = 7
    ) -> CGFloat {
        var fontSize = max(minimumFontSize, min(baseFontSize, rect.height * 0.92))

        while fontSize > minimumFontSize {
            let attributed = attributedMarkdown(
                text,
                fontSize: fontSize,
                weight: weight,
                foregroundColor: .labelColor,
                paragraph: paragraph,
                codeBackgroundColor: .clear
            )
            let measured = measuredAttributedTextSize(attributed, constrainedTo: rect.width)

            if measured.height <= rect.height * 0.98, measured.width <= rect.width * 1.02 {
                return fontSize
            }

            fontSize -= 0.5
        }

        return max(minimumFontSize, fontSize)
    }

    private static func textAttributes(
        fontSize: CGFloat,
        weight: NSFont.Weight,
        foregroundColor: NSColor,
        paragraph: NSParagraphStyle
    ) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: fontSize, weight: weight),
            .foregroundColor: foregroundColor,
            .paragraphStyle: paragraph
        ]
    }

    private static func attributedMarkdown(
        _ markdown: String,
        fontSize: CGFloat,
        weight: NSFont.Weight,
        foregroundColor: NSColor,
        paragraph: NSParagraphStyle,
        codeBackgroundColor: NSColor
    ) -> NSAttributedString {
        attributedMarkdownLayout(
            markdown,
            fontSize: fontSize,
            weight: weight,
            foregroundColor: foregroundColor,
            paragraph: paragraph
        ).attributed
    }

    private struct AttributedMarkdownLayout {
        let attributed: NSAttributedString
        let codeRanges: [NSRange]
    }

    private static func attributedMarkdownLayout(
        _ markdown: String,
        fontSize: CGFloat,
        weight: NSFont.Weight,
        foregroundColor: NSColor,
        paragraph: NSParagraphStyle,
        preserveCodeSpans: Bool = false
    ) -> AttributedMarkdownLayout {
        let attributed = NSMutableAttributedString(string: "")
        let spans = inlineMarkdownSpans(markdown)
        var codeRanges: [NSRange] = []
        var location = 0

        for span in spans where !span.text.isEmpty {
            var attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: foregroundColor,
                .paragraphStyle: paragraph
            ]

            if span.isCode {
                let codeFontSize = max(fontSize * 0.85, fontSize - 2)
                attributes[.font] = NSFont.monospacedSystemFont(
                    ofSize: codeFontSize,
                    weight: .regular
                )
                attributes[.baselineOffset] = -max(0.35, fontSize * 0.025)
                if preserveCodeSpans {
                    attributes[.foregroundColor] = NSColor.clear
                }
            } else {
                attributes[.font] = NSFont.systemFont(ofSize: fontSize, weight: weight)
            }

            let range = NSRange(location: location, length: (span.text as NSString).length)
            if span.isCode {
                codeRanges.append(range)
            }
            attributed.append(NSAttributedString(string: span.text, attributes: attributes))
            location += range.length
        }

        return AttributedMarkdownLayout(attributed: attributed, codeRanges: codeRanges)
    }

    private static func drawCodeChipBackgrounds(
        for layout: AttributedMarkdownLayout,
        in rect: CGRect,
        color: NSColor,
        fontSize: CGFloat
    ) {
        guard !layout.codeRanges.isEmpty, layout.attributed.length > 0 else {
            return
        }

        let textStorage = NSTextStorage(attributedString: layout.attributed)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: rect.size)
        textContainer.lineFragmentPadding = 0
        textContainer.maximumNumberOfLines = 0
        textContainer.lineBreakMode = .byWordWrapping
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)

        color.setFill()
        for characterRange in layout.codeRanges {
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: characterRange,
                actualCharacterRange: nil
            )
            layoutManager.enumerateEnclosingRects(
                forGlyphRange: glyphRange,
                withinSelectedGlyphRange: glyphRange,
                in: textContainer
            ) { enclosingRect, _ in
                let horizontalPadding = max(2, fontSize * 0.18)
                let verticalPadding = max(1, fontSize * 0.07)
                let chipRect = CGRect(
                    x: rect.minX + enclosingRect.minX,
                    y: rect.maxY - enclosingRect.maxY,
                    width: enclosingRect.width,
                    height: enclosingRect.height
                )
                    .insetBy(dx: -horizontalPadding, dy: -verticalPadding)
                    .integral
                NSBezierPath(
                    roundedRect: chipRect,
                    xRadius: max(2, fontSize * 0.24),
                    yRadius: max(2, fontSize * 0.24)
                ).fill()
            }
        }
    }

    private struct InlineMarkdownSpan {
        let text: String
        let isCode: Bool
    }

    private static func inlineMarkdownSpans(_ markdown: String) -> [InlineMarkdownSpan] {
        var spans: [InlineMarkdownSpan] = []
        var current = ""
        var isCode = false

        for character in markdown {
            if character == "`" {
                if !current.isEmpty {
                    spans.append(InlineMarkdownSpan(text: cleanedMarkdownText(current, isCode: isCode), isCode: isCode))
                    current = ""
                }
                isCode.toggle()
            } else {
                current.append(character)
            }
        }

        if !current.isEmpty {
            spans.append(InlineMarkdownSpan(text: cleanedMarkdownText(current, isCode: isCode), isCode: isCode))
        }

        return spans
    }

    private static func cleanedMarkdownText(_ text: String, isCode: Bool) -> String {
        guard !isCode else {
            return text
        }

        return text
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
    }

    private static func measuredAttributedTextSize(
        _ attributed: NSAttributedString,
        constrainedTo width: CGFloat
    ) -> CGSize {
        let rect = attributed.boundingRect(
            with: CGSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return CGSize(width: ceil(rect.width), height: ceil(rect.height))
    }

    private static func codeChipColor(on backgroundColor: NSColor) -> NSColor {
        guard let color = backgroundColor.usingColorSpace(.sRGB) else {
            return NSColor.controlBackgroundColor.withAlphaComponent(0.90)
        }

        if luminance(color) < 0.5 {
            return blendedColor(from: color, to: .white, progress: 0.18).withAlphaComponent(0.94)
        }

        return blendedColor(from: color, to: .black, progress: 0.11).withAlphaComponent(0.90)
    }

    private static func harmonizedBackgroundColor(
        _ localBackgroundColor: NSColor,
        canvasBackgroundColor: NSColor
    ) -> NSColor {
        guard
            let local = localBackgroundColor.usingColorSpace(.sRGB),
            let canvas = canvasBackgroundColor.usingColorSpace(.sRGB)
        else {
            return localBackgroundColor
        }

        let channelDistance = max(
            abs(local.redComponent - canvas.redComponent),
            abs(local.greenComponent - canvas.greenComponent),
            abs(local.blueComponent - canvas.blueComponent)
        )
        let localLuminance = luminance(local)
        let canvasLuminance = luminance(canvas)
        let tolerance: CGFloat
        if localLuminance > 0.84, canvasLuminance > 0.84 {
            tolerance = 0.022
        } else if localLuminance < 0.24, canvasLuminance < 0.24 {
            tolerance = 0.028
        } else {
            tolerance = 0.018
        }

        guard channelDistance <= tolerance else {
            return localBackgroundColor
        }
        return canvas.withAlphaComponent(1)
    }

    private static func dominantInteriorBackgroundColor(
        in rects: [CGRect],
        bitmap: NSBitmapImageRep,
        bounds: CGRect
    ) -> NSColor? {
        var counts: [Int: Int] = [:]
        var redSums: [Int: CGFloat] = [:]
        var greenSums: [Int: CGFloat] = [:]
        var blueSums: [Int: CGFloat] = [:]

        for rect in rects where rect.width > 1 && rect.height > 1 {
            let columns = max(3, min(36, Int(ceil(rect.width / 2))))
            let rows = max(3, min(18, Int(ceil(rect.height / 2))))
            for row in 0..<rows {
                let y = rect.minY + (CGFloat(row) + 0.5) / CGFloat(rows) * rect.height
                for column in 0..<columns {
                    let x = rect.minX + (CGFloat(column) + 0.5) / CGFloat(columns) * rect.width
                    guard let color = sampledColor(
                        appKitX: x,
                        appKitY: y,
                        bitmap: bitmap,
                        bounds: bounds
                    )?.usingColorSpace(.sRGB) else {
                        continue
                    }

                    let redBin = Int((color.redComponent * 255).rounded()) / 16
                    let greenBin = Int((color.greenComponent * 255).rounded()) / 16
                    let blueBin = Int((color.blueComponent * 255).rounded()) / 16
                    let key = (redBin << 16) | (greenBin << 8) | blueBin
                    counts[key, default: 0] += 1
                    redSums[key, default: 0] += color.redComponent
                    greenSums[key, default: 0] += color.greenComponent
                    blueSums[key, default: 0] += color.blueComponent
                }
            }
        }

        guard
            let dominant = counts.max(by: { $0.value < $1.value }),
            dominant.value >= 2
        else {
            return nil
        }

        let count = CGFloat(dominant.value)
        return NSColor(
            srgbRed: redSums[dominant.key, default: 0] / count,
            green: greenSums[dominant.key, default: 0] / count,
            blue: blueSums[dominant.key, default: 0] / count,
            alpha: 1
        )
    }

    private static func sampledForegroundColor(
        in rects: [CGRect],
        bitmap: NSBitmapImageRep,
        backgroundColor: NSColor,
        bounds: CGRect
    ) -> NSColor? {
        var candidates: [(color: NSColor, distance: CGFloat)] = []

        for rect in rects where rect.width > 1 && rect.height > 1 {
            let columns = max(3, min(28, Int(ceil(rect.width / 2))))
            let rows = max(3, min(14, Int(ceil(rect.height / 2))))

            for row in 0..<rows {
                let y = rect.minY + (CGFloat(row) + 0.5) / CGFloat(rows) * rect.height
                for column in 0..<columns {
                    let x = rect.minX + (CGFloat(column) + 0.5) / CGFloat(columns) * rect.width
                    guard let sampled = sampledColor(
                        appKitX: x,
                        appKitY: y,
                        bitmap: bitmap,
                        bounds: bounds
                    ) else {
                        continue
                    }

                    let distance = rgbDistance(sampled, backgroundColor)
                    if distance >= 0.10 {
                        candidates.append((sampled, distance))
                    }
                }
            }
        }

        guard !candidates.isEmpty else {
            return nil
        }

        let sorted = candidates.sorted { $0.distance > $1.distance }
        let selectedCount = max(1, Int(ceil(Double(sorted.count) * 0.36)))
        return averageColor(sorted.prefix(selectedCount).map(\.color))
    }

    private static func rgbDistance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        guard
            let lhs = lhs.usingColorSpace(.sRGB),
            let rhs = rhs.usingColorSpace(.sRGB)
        else {
            return 0
        }

        let red = lhs.redComponent - rhs.redComponent
        let green = lhs.greenComponent - rhs.greenComponent
        let blue = lhs.blueComponent - rhs.blueComponent
        return sqrt(red * red + green * green + blue * blue)
    }

    private static func sampledBackgroundColor(in rect: CGRect, bitmap: NSBitmapImageRep) -> NSColor? {
        let bounds = CGRect(
            x: 0,
            y: 0,
            width: bitmap.pixelsWide,
            height: bitmap.pixelsHigh
        )
        let sampleOffset = max(2, min(10, rect.height * 0.20))
        let fractions: [CGFloat] = [0.08, 0.22, 0.38, 0.5, 0.62, 0.78, 0.92]
        var points: [CGPoint] = []

        for fraction in fractions {
            points.append(CGPoint(x: rect.minX + rect.width * fraction, y: rect.minY - sampleOffset))
            points.append(CGPoint(x: rect.minX + rect.width * fraction, y: rect.maxY + sampleOffset))
            points.append(CGPoint(x: rect.minX - sampleOffset, y: rect.minY + rect.height * fraction))
            points.append(CGPoint(x: rect.maxX + sampleOffset, y: rect.minY + rect.height * fraction))
        }

        let colors = points.compactMap { point in
            sampledColor(appKitX: point.x, appKitY: point.y, bitmap: bitmap, bounds: bounds)
        }

        return dominantBackgroundColor(colors) ?? averageColor(colors)
    }

    private static func averageColor(_ colors: [NSColor]) -> NSColor? {
        guard !colors.isEmpty else {
            return nil
        }

        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        var count: CGFloat = 0

        for rawColor in colors {
            guard let color = rawColor.usingColorSpace(.sRGB) else {
                continue
            }

            red += color.redComponent
            green += color.greenComponent
            blue += color.blueComponent
            alpha += color.alphaComponent
            count += 1
        }

        guard count > 0 else {
            return nil
        }

        return NSColor(
            srgbRed: red / count,
            green: green / count,
            blue: blue / count,
            alpha: alpha / count
        )
    }

    private static func dominantBackgroundColor(_ colors: [NSColor]) -> NSColor? {
        let converted = colors.compactMap { color -> NSColor? in
            color.usingColorSpace(.sRGB)
        }
        guard !converted.isEmpty else {
            return nil
        }

        let sorted = converted.sorted { lhs, rhs in
            luminance(lhs) < luminance(rhs)
        }
        let median = luminance(sorted[sorted.count / 2])
        let selected: [NSColor]

        if median < 0.5 {
            let count = max(1, Int(ceil(Double(sorted.count) * 0.68)))
            selected = Array(sorted.prefix(count))
        } else {
            let count = max(1, Int(ceil(Double(sorted.count) * 0.68)))
            selected = Array(sorted.suffix(count))
        }

        return averageColor(selected)
    }

    private static func luminance(_ color: NSColor) -> CGFloat {
        0.2126 * color.redComponent
            + 0.7152 * color.greenComponent
            + 0.0722 * color.blueComponent
    }

    private static func blendedColor(from start: NSColor, to end: NSColor, progress: CGFloat) -> NSColor {
        guard
            let start = start.usingColorSpace(.sRGB),
            let end = end.usingColorSpace(.sRGB)
        else {
            return start
        }

        let clampedProgress = min(max(progress, 0), 1)
        return NSColor(
            srgbRed: start.redComponent + (end.redComponent - start.redComponent) * clampedProgress,
            green: start.greenComponent + (end.greenComponent - start.greenComponent) * clampedProgress,
            blue: start.blueComponent + (end.blueComponent - start.blueComponent) * clampedProgress,
            alpha: start.alphaComponent + (end.alphaComponent - start.alphaComponent) * clampedProgress
        )
    }

    private static func sampledColor(
        appKitX: CGFloat,
        appKitY: CGFloat,
        bitmap: NSBitmapImageRep,
        bounds: CGRect
    ) -> NSColor? {
        let clampedX = min(max(bounds.minX, appKitX), bounds.maxX - 1)
        let clampedY = min(max(bounds.minY, appKitY), bounds.maxY - 1)
        let x = min(max(0, Int(clampedX.rounded())), bitmap.pixelsWide - 1)
        let y = min(max(0, bitmap.pixelsHigh - 1 - Int(clampedY.rounded())), bitmap.pixelsHigh - 1)
        return bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
    }

    private static func color(from hex: String?) -> NSColor? {
        guard let hex else {
            return nil
        }

        let cleaned = hex
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let expanded: String

        if cleaned.count == 3 {
            expanded = cleaned.map { "\($0)\($0)" }.joined()
        } else {
            expanded = cleaned
        }

        guard expanded.count == 6, let value = Int(expanded, radix: 16) else {
            return nil
        }

        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1
        )
    }

    private static func readableTextColor(on backgroundColor: NSColor) -> NSColor {
        guard let color = backgroundColor.usingColorSpace(.sRGB) else {
            return .labelColor
        }

        let luminance = 0.2126 * color.redComponent
            + 0.7152 * color.greenComponent
            + 0.0722 * color.blueComponent
        return luminance > 0.55 ? .black : .white
    }

    private static func textAlignment(from value: String?) -> NSTextAlignment {
        switch value?.lowercased() {
        case "left", "leading":
            return .left
        case "right", "trailing":
            return .right
        default:
            return .center
        }
    }

    private static func fontWeight(from value: String?) -> NSFont.Weight {
        let normalized = value?.lowercased() ?? ""

        if normalized.contains("bold") || normalized.contains("heavy") || normalized.contains("black") {
            return .bold
        }

        if normalized.contains("semi") || normalized.contains("medium") {
            return .semibold
        }

        if normalized.contains("light") || normalized.contains("thin") {
            return .light
        }

        return .regular
    }
}
