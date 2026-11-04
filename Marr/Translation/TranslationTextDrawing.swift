import MarrText
import AppKit
import CoreText
import Foundation

extension ImageTranslationRenderer {
    static func drawTextLayout(_ layout: TextHighlightLayout) {
        if let baseline = layout.baseline, let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            context.clip(to: layout.drawRect)
            context.textMatrix = .identity
            context.textPosition = baseline
            CTLineDraw(CTLineCreateWithAttributedString(layout.attributed), context)
            context.restoreGState()
        } else {
            layout.attributed.draw(with: layout.drawRect,
                options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        }
    }

    private struct NormalizedTextUnit {
        let layoutIndex: Int
        let characterRange: NSRange
        let normalizedRange: NSRange
    }

    static func exactHighlightRects(
        for pairs: [ImageTranslationHighlightPair],
        layouts: [TextHighlightLayout],
        imageSize: CGSize
    ) -> [String: [CGRect]] {
        guard !pairs.isEmpty, !layouts.isEmpty,
              imageSize.width > 0, imageSize.height > 0
        else { return [:] }

        let normalized = NSMutableString()
        var units: [NormalizedTextUnit] = []
        for (layoutIndex, layout) in layouts.enumerated() {
            let string = layout.attributed.string
            string.enumerateSubstrings(
                in: string.startIndex..<string.endIndex,
                options: .byComposedCharacterSequences
            ) { substring, substringRange, _, _ in
                guard let substring else { return }
                let folded = normalizedHighlightText(substring)
                guard !folded.isEmpty else { return }
                let normalizedRange = NSRange(
                    location: normalized.length,
                    length: (folded as NSString).length
                )
                normalized.append(folded)
                units.append(NormalizedTextUnit(
                    layoutIndex: layoutIndex,
                    characterRange: NSRange(substringRange, in: string),
                    normalizedRange: normalizedRange
                ))
            }
        }
        guard normalized.length > 0 else { return [:] }

        var result: [String: [CGRect]] = [:]
        var searchLocation = 0
        for pair in pairs {
            guard let targetText = pair.targetText else { continue }
            let target = normalizedHighlightText(targetText)
            guard !target.isEmpty else { continue }
            let targetLength = (target as NSString).length
            var found = normalized.range(
                of: target,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: NSRange(
                    location: min(searchLocation, normalized.length),
                    length: max(0, normalized.length - min(searchLocation, normalized.length))
                )
            )
            if found.location == NSNotFound {
                found = normalized.range(
                    of: target,
                    options: [.caseInsensitive, .diacriticInsensitive]
                )
            }
            guard found.location != NSNotFound, found.length == targetLength else { continue }
            searchLocation = NSMaxRange(found)

            let matchingUnits = units.filter {
                NSIntersectionRange($0.normalizedRange, found).length > 0
            }
            let byLayout = Dictionary(grouping: matchingUnits, by: \.layoutIndex)
            let rects = byLayout.keys.sorted().flatMap { layoutIndex -> [CGRect] in
                guard let selectedUnits = byLayout[layoutIndex],
                      let lower = selectedUnits.map(\.characterRange.location).min(),
                      let upper = selectedUnits.map({ NSMaxRange($0.characterRange) }).max()
                else { return [] }
                return enclosingTextRects(
                    characterRange: NSRange(location: lower, length: upper - lower),
                    layout: layouts[layoutIndex]
                ).map { appKitRect in
                    CGRect(
                        x: appKitRect.minX / imageSize.width,
                        y: (imageSize.height - appKitRect.maxY) / imageSize.height,
                        width: appKitRect.width / imageSize.width,
                        height: appKitRect.height / imageSize.height
                    )
                    .insetBy(dx: -0.002, dy: -0.001)
                }
            }
            if !rects.isEmpty {
                result[pair.id] = rects
            }
        }
        return result
    }

    static func enclosingTextRects(
        characterRange: NSRange,
        layout: TextHighlightLayout
    ) -> [CGRect] {
        guard characterRange.length > 0, layout.attributed.length > 0 else { return [] }
        if let baseline = layout.baseline {
            let line = CTLineCreateWithAttributedString(layout.attributed)
            let start = CTLineGetOffsetForStringIndex(line, characterRange.location, nil)
            let end = CTLineGetOffsetForStringIndex(line, NSMaxRange(characterRange), nil)
            return [CGRect(x: baseline.x + min(start, end), y: layout.drawRect.minY,
                           width: abs(end - start), height: layout.drawRect.height)]
        }
        let textStorage = NSTextStorage(attributedString: layout.attributed)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: layout.drawRect.size)
        textContainer.lineFragmentPadding = 0
        textContainer.maximumNumberOfLines = 0
        if let paragraph = layout.attributed.attribute(
            .paragraphStyle,
            at: 0,
            effectiveRange: nil
        ) as? NSParagraphStyle {
            textContainer.lineBreakMode = paragraph.lineBreakMode
        }
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)

        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: characterRange,
            actualCharacterRange: nil
        )
        var rects: [CGRect] = []
        layoutManager.enumerateEnclosingRects(
            forGlyphRange: glyphRange,
            withinSelectedGlyphRange: glyphRange,
            in: textContainer
        ) { enclosingRect, _ in
            let appKitRect = CGRect(
                x: layout.drawRect.minX + enclosingRect.minX,
                y: layout.drawRect.maxY - enclosingRect.maxY,
                width: enclosingRect.width,
                height: enclosingRect.height
            )
            if appKitRect.width > 0, appKitRect.height > 0 {
                rects.append(appKitRect)
            }
        }
        return rects
    }

    static func normalizedHighlightText(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { !$0.isWhitespace && $0 != "`" }
    }

    static func automaticMarkdownLines(
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

        return MarkdownLineLayout.lines(
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
                paragraph.lineBreakMode = .byClipping
                paragraph.lineSpacing = 0
                let fontSize = TranslationTypography.typographicBaseFontSize(
                    for: block,
                    imageHeight: imageHeight,
                    rect: lineRect
                )
                TranslationTypography.configureParagraphStyle(paragraph, for: block, fontSize: fontSize)
                return measuredMarkdownLineWidth(
                    candidateText,
                    fontSize: fontSize,
                    weight: weight,
                    paragraph: paragraph
                )
            }
        )
    }

    static func measuredMarkdownLineWidth(
        _ markdown: String,
        fontSize: CGFloat,
        weight: NSFont.Weight,
        paragraph: NSParagraphStyle
    ) -> CGFloat {
        let attributed = TranslationTypography.attributedMarkdown(
            markdown,
            fontSize: fontSize,
            weight: weight,
            foregroundColor: .labelColor,
            paragraph: paragraph,
            codeBackgroundColor: .clear
        )
        return TranslationTypography.measuredAttributedTextSize(attributed, constrainedTo: 10_000).width
    }

    static func drawMarkdownLineAroundSourceCode(
        _ markdown: String,
        in lineRect: CGRect,
        codeRects: [CGRect],
        imageHeight: CGFloat,
        foregroundColor: NSColor,
        weight: NSFont.Weight,
        paragraph: NSMutableParagraphStyle,
        block: ImageTranslationBlock
    ) -> Bool {
        let spans = TranslationTypography.inlineMarkdownSpans(markdown)
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

            let baseFontSize = TranslationTypography.typographicBaseFontSize(
                for: block,
                imageHeight: imageHeight,
                rect: segmentRect
            )
            TranslationTypography.configureParagraphStyle(paragraph, for: block, fontSize: baseFontSize)
            let fontSize = TranslationTypography.fittingFontSize(
                for: text,
                baseFontSize: baseFontSize,
                rect: segmentRect,
                weight: weight,
                paragraph: paragraph,
                minimumFontSize: TranslationTypography.minimumReadableFontSize(baseFontSize)
            )
            TranslationTypography.configureParagraphStyle(paragraph, for: block, fontSize: fontSize)
            let attributed = NSAttributedString(
                string: text,
                attributes: [
                    .font: TranslationTypography.proseFont(ofSize: fontSize, weight: weight),
                    .foregroundColor: foregroundColor,
                    .paragraphStyle: paragraph
                ]
            )
            let measured = TranslationTypography.measuredAttributedTextSize(attributed, constrainedTo: segmentRect.width)
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

    static func trimmedSegmentText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func blockRect(_ block: ImageTranslationBlock, imageSize: CGSize) -> CGRect {
        let width = CGFloat(block.width) * imageSize.width
        let height = CGFloat(block.height) * imageSize.height
        let x = CGFloat(block.x) * imageSize.width
        let y = imageSize.height - (CGFloat(block.y) * imageSize.height) - height

        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func textAlignment(from value: String?) -> NSTextAlignment {
        switch value?.lowercased() {
        case "left", "leading":
            return .left
        case "right", "trailing":
            return .right
        default:
            return .center
        }
    }
}
