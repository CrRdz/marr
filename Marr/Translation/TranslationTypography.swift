import AppKit
import CoreText
import Foundation

enum TranslationTypography {
    /// Use one prose family for Han, Latin and digits. Leaving Han to the
    /// system Latin font's cascade gives adjacent runs different proportions
    /// and weight. Real code spans continue to use the monospaced family.
    static func proseFont(ofSize size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        guard let base = NSFont(name: "PingFangSC-Regular", size: size), let family = base.familyName else {
            return NSFont.systemFont(ofSize: size, weight: weight)
        }
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: family, .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue]
        ])
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    static func baseFontSize(_ requested: Double?, imageHeight: CGFloat, rect: CGRect) -> CGFloat {
        if let requested, requested > 0 {
            if requested <= 1 {
                return min(CGFloat(requested) * imageHeight, rect.height * 0.92)
            }
            return min(CGFloat(requested), rect.height * 0.92)
        }

        return min(max(rect.height * 0.68, 8), 48)
    }

    static func typographicBaseFontSize(
        for block: ImageTranslationBlock,
        imageHeight: CGFloat,
        rect: CGRect
    ) -> CGFloat {
        let inferred = baseFontSize(
            block.fontSize,
            imageHeight: imageHeight,
            rect: rect
        ) * targetScriptFontScale(for: block.text)

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

    /// CJK glyphs occupy more of the em square than Latin body text. Rendering
    /// both scripts at the same point size therefore makes translated Chinese
    /// look heavier and leaves noticeably less whitespace between source rows.
    static func targetScriptFontScale(for text: String) -> CGFloat {
        let letterScalars = text.unicodeScalars.filter {
            CharacterSet.letters.contains($0)
        }
        guard !letterScalars.isEmpty else {
            return 1
        }

        let cjkCount = letterScalars.filter { scalar in
            let value = Int(scalar.value)
            return (0x3400...0x4DBF).contains(value)
                || (0x4E00...0x9FFF).contains(value)
                || (0xF900...0xFAFF).contains(value)
        }.count

        return cjkCount > 0 && cjkCount * 2 >= letterScalars.count
            ? 0.88
            : 1
    }

    static func layoutMarkdown(for block: ImageTranslationBlock) -> String {
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

        // OCR lists already have a raster marker outside the text boxes. Keep
        // that original bullet/arrow and its indentation instead of drawing a
        // second bullet at the translated text's origin.
        if preservesSourceListMarker(block) {
            return content
        }
        return content.isEmpty ? "•" : "•\t\(content)"
    }

    private static func preservesSourceListMarker(_ block: ImageTranslationBlock) -> Bool {
        block.preservesListMarker
    }

    static func configureParagraphStyle(
        _ paragraph: NSMutableParagraphStyle,
        for block: ImageTranslationBlock,
        fontSize: CGFloat
    ) {
        guard normalizedKind(block.kind) == "list_item", !preservesSourceListMarker(block) else {
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

    static func effectiveFontWeight(for block: ImageTranslationBlock) -> NSFont.Weight {
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

    static func lineSpacing(for block: ImageTranslationBlock, sourceHeight: CGFloat) -> CGFloat {
        switch normalizedKind(block.kind) {
        case "title", "heading":
            return max(0, sourceHeight * 0.02)
        case "caption", "code":
            return 0
        default:
            return max(0, sourceHeight * 0.04)
        }
    }

    static func normalizedKind(_ kind: String?) -> String {
        kind?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_") ?? "paragraph"
    }

    static func fittingFontSize(
        for text: String,
        baseFontSize: CGFloat,
        rect: CGRect,
        weight: NSFont.Weight,
        paragraph: NSParagraphStyle,
        minimumFontSize: CGFloat = 7
    ) -> CGFloat {
        let maximumFontSize = max(1, min(baseFontSize, rect.height * 0.92))
        let minimumFontSize = min(maximumFontSize, max(1, minimumFontSize))
        let isSingleLine = paragraph.lineBreakMode == .byClipping
            || paragraph.lineBreakMode == .byTruncatingHead
            || paragraph.lineBreakMode == .byTruncatingMiddle
            || paragraph.lineBreakMode == .byTruncatingTail

        func fits(_ fontSize: CGFloat) -> Bool {
            let attributed = attributedMarkdown(
                text,
                fontSize: fontSize,
                weight: weight,
                foregroundColor: .labelColor,
                paragraph: paragraph,
                codeBackgroundColor: .clear
            )
            // A truncated bounding rect only measures the visible prefix and
            // ellipsis. Measure a single line without a width limit so fitting
            // accounts for every translated word (including inline code).
            let measured = measuredAttributedTextSize(
                attributed,
                constrainedTo: isSingleLine ? CGFloat.greatestFiniteMagnitude : rect.width
            )
            return measured.height <= rect.height
                && measured.width <= rect.width
        }

        if fits(maximumFontSize) { return maximumFontSize }
        guard fits(minimumFontSize) else { return minimumFontSize }

        var lower = minimumFontSize
        var upper = maximumFontSize
        // Bounded binary search avoids repeated half-point layout passes on
        // large screenshots while keeping the largest size that really fits.
        for _ in 0..<12 {
            guard upper - lower > 0.125 else { break }
            let candidate = (lower + upper) / 2
            if fits(candidate) {
                lower = candidate
            } else {
                upper = candidate
            }
        }
        return lower
    }

    static func minimumReadableFontSize(_ baseFontSize: CGFloat) -> CGFloat {
        min(7, baseFontSize)
    }

    private static func textAttributes(
        fontSize: CGFloat,
        weight: NSFont.Weight,
        foregroundColor: NSColor,
        paragraph: NSParagraphStyle
    ) -> [NSAttributedString.Key: Any] {
        [
            .font: proseFont(ofSize: fontSize, weight: weight),
            .foregroundColor: foregroundColor,
            .paragraphStyle: paragraph
        ]
    }

    static func attributedMarkdown(
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

    struct AttributedMarkdownLayout {
        let attributed: NSAttributedString
        let codeRanges: [NSRange]
    }

    static func attributedMarkdownLayout(
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
                attributes[.font] = proseFont(ofSize: fontSize, weight: weight)
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

    static func drawCodeChipBackgrounds(
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

    struct InlineMarkdownSpan {
        let text: String
        let isCode: Bool
    }

    static func inlineMarkdownSpans(_ markdown: String) -> [InlineMarkdownSpan] {
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

    static func measuredAttributedTextSize(
        _ attributed: NSAttributedString,
        constrainedTo width: CGFloat
    ) -> CGSize {
        let rect = attributed.boundingRect(
            with: CGSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return CGSize(width: ceil(rect.width), height: ceil(rect.height))
    }

    static func codeChipColor(on backgroundColor: NSColor) -> NSColor {
        guard let color = backgroundColor.usingColorSpace(.sRGB) else {
            return NSColor.controlBackgroundColor.withAlphaComponent(0.90)
        }

        if TranslationColorSampling.luminance(color) < 0.5 {
            return TranslationColorSampling.blendedColor(from: color, to: .white, progress: 0.18).withAlphaComponent(0.94)
        }

        return TranslationColorSampling.blendedColor(from: color, to: .black, progress: 0.11).withAlphaComponent(0.90)
    }
    static func fontWeight(from value: String?) -> NSFont.Weight {
        let normalized = value?.lowercased() ?? ""

        if normalized.contains("semi") {
            return .semibold
        }
        if normalized.contains("medium") { return .medium }

        if normalized.contains("bold") || normalized.contains("heavy") || normalized.contains("black") {
            return .bold
        }

        if normalized.contains("light") || normalized.contains("thin") {
            return .light
        }

        return .regular
    }
}
