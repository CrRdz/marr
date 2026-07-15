import AppKit
import Foundation

enum ImageTranslationMarkdownLineLayout {
    struct Token {
        let markdown: String
        let plainText: String
        let isCode: Bool
    }

    static func lines(
        for markdown: String,
        lineRects: [CGRect],
        codeRects: [CGRect],
        availableWidth: (CGRect) -> CGFloat,
        measuredWidth: (String, CGRect) -> CGFloat
    ) -> [String]? {
        guard lineRects.count > 1, !markdown.contains("\n") else {
            return nil
        }

        let tokens = markdownLineTokens(markdown)
        guard tokens.count >= lineRects.count else {
            return nil
        }

        let codeLineIndices = codeLineIndices(
            for: codeRects,
            lineRects: lineRects,
            expectedCodeCount: tokens.filter(\.isCode).count
        )
        if !codeRects.isEmpty, codeLineIndices == nil {
            return nil
        }

        var lineTokens = Array(repeating: [Token](), count: lineRects.count)
        var lineIndex = 0
        var codeTokenIndex = 0

        for tokenIndex in tokens.indices {
            let token = tokens[tokenIndex]
            if token.isCode, let codeLineIndices {
                let targetLineIndex = codeLineIndices[codeTokenIndex]
                guard targetLineIndex >= lineIndex else {
                    return nil
                }
                lineIndex = targetLineIndex
                lineTokens[lineIndex].append(token)
                codeTokenIndex += 1
                continue
            }

            if lineIndex < lineRects.count - 1, !lineTokens[lineIndex].isEmpty {
                let remainingTokensAfterThis = tokens.count - tokenIndex - 1
                let remainingLinesAfterThis = lineRects.count - lineIndex - 1
                let nextCodeLineIndex: Int
                if let codeLineIndices, codeTokenIndex < codeLineIndices.count {
                    nextCodeLineIndex = codeLineIndices[codeTokenIndex]
                } else {
                    nextCodeLineIndex = lineRects.count - 1
                }
                let canAdvanceBeforeNextCode = lineIndex < min(lineRects.count - 1, nextCodeLineIndex)
                let candidateText = markdownLine(from: lineTokens[lineIndex] + [token])
                let lineRect = lineRects[lineIndex]

                if measuredWidth(candidateText, lineRect) > availableWidth(lineRect) * 0.98,
                   remainingTokensAfterThis >= remainingLinesAfterThis,
                   canAdvanceBeforeNextCode {
                    lineIndex += 1
                }
            }

            lineTokens[lineIndex].append(token)
        }

        if let codeLineIndices, codeTokenIndex != codeLineIndices.count {
            return nil
        }

        let lines = lineTokens.map(markdownLine)
        guard lines.allSatisfy({ !$0.isEmpty }) else {
            return nil
        }
        return lines
    }

    private static func codeLineIndices(
        for codeRects: [CGRect],
        lineRects: [CGRect],
        expectedCodeCount: Int
    ) -> [Int]? {
        guard !codeRects.isEmpty else {
            return nil
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

    private static func markdownLineTokens(_ markdown: String) -> [Token] {
        inlineMarkdownSpans(markdown).flatMap { span -> [Token] in
            if span.isCode {
                return [
                    Token(
                        markdown: "`\(span.text)`",
                        plainText: span.text,
                        isCode: true
                    )
                ]
            }

            return naturalTextTokens(span.text).map { token in
                Token(markdown: token, plainText: token, isCode: false)
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
                    spans.append(InlineMarkdownSpan(text: current, isCode: isCode))
                    current = ""
                }
                isCode.toggle()
            } else {
                current.append(character)
            }
        }

        if !current.isEmpty {
            spans.append(InlineMarkdownSpan(text: current, isCode: isCode))
        }

        return spans
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

    private static func markdownLine(from tokens: [Token]) -> String {
        var result = ""
        var previous: Token?

        for token in tokens {
            if result.isEmpty {
                result = token.markdown
            } else {
                if let previous {
                    if isBulletMarker(previous.plainText) {
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

    private static func isBulletMarker(_ text: String) -> Bool {
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

    private static func verticalOverlapRatio(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let overlap = min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY)
        return max(0, overlap) / max(min(lhs.height, rhs.height), 1)
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
}


enum ImageTranslationLayoutGeometry {
    static func expandedLineRects(
        _ lineRects: [CGRect],
        sourceRect: CGRect,
        bounds: CGRect
    ) -> [CGRect] {
        guard lineRects.count > 1 else {
            return lineRects
        }

        let originalRightEdge = lineRects.map(\.maxX).max() ?? sourceRect.maxX
        let rightEdge = min(bounds.maxX, max(sourceRect.maxX, originalRightEdge))

        return lineRects.map { lineRect in
            guard rightEdge > lineRect.minX + 1 else {
                return lineRect
            }

            return CGRect(
                x: lineRect.minX,
                y: lineRect.minY,
                width: rightEdge - lineRect.minX,
                height: lineRect.height
            )
            .intersection(bounds)
            .integral
        }
    }

    static func expandedCodeRect(_ rect: CGRect, text: String, bounds: CGRect) -> CGRect {
        guard rect.width > 1, rect.height > 1, !text.isEmpty else {
            return rect.intersection(bounds).integral
        }

        // The OCR box already includes the code-chip padding. Expanding with a
        // normal proportional-font coefficient made the protected rectangle
        // consume the first letters of the following prose ("owns", "compiles",
        // etc.). Monospaced glyphs inside these chips average about 0.39 of the
        // expanded chip height; the renderer adds its own antialiasing margin.
        let expectedTextWidth = rect.height * 0.39 * CGFloat(text.count)
        let rightEdge = min(
            bounds.maxX,
            rect.minX + max(rect.width, expectedTextWidth)
        )

        return CGRect(
            x: rect.minX,
            y: rect.minY,
            width: max(0, rightEdge - rect.minX),
            height: rect.height
        )
        .intersection(bounds)
        .integral
    }
}

enum ImageTranslationCodeHeuristics {
    static func isStrongIdentifier(_ text: String) -> Bool {
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count >= 4,
              token.range(of: #"^[A-Za-z_][A-Za-z0-9_./:-]*$"#, options: .regularExpression) != nil
        else {
            return false
        }

        if token.contains("_")
            || token.contains(".")
            || token.contains("/")
            || token.contains(":") {
            return true
        }

        let letters = token.filter(\.isLetter)
        guard letters.count >= 3 else {
            return false
        }
        if letters.allSatisfy({ $0.isUppercase }) {
            return true
        }

        // Strong standalone type/API identifiers normally begin with an
        // uppercase component. Lowercase-leading brand spellings such as
        // "macOS" are product names, not code tokens; visual chip detection
        // still handles genuine lowerCamelCase identifiers inside code UI.
        guard letters.first?.isUppercase == true else {
            return false
        }
        return letters.dropFirst().contains(where: { $0.isUppercase })
            && letters.contains(where: { $0.isLowercase })
    }
}

enum ImageTranslationSemanticNormalizer {
    static func normalize(_ blocks: [ImageTranslationBlock]) -> [ImageTranslationBlock] {
        blocks.flatMap { block in
            guard normalizedKind(block.kind) == "list_item" else {
                return [block]
            }

            let items = splitListItems(block.text)
            guard items.count > 1 else {
                return [block]
            }

            return items.enumerated().map { index, text in
                let fraction = Double(index) / Double(items.count)
                return ImageTranslationBlock(
                    text: text,
                    x: block.x,
                    y: min(1, block.y + block.height * fraction),
                    width: block.width,
                    height: max(0.006, block.height / Double(items.count)),
                    lineRects: [],
                    textRects: [],
                    trailingAttachments: block.trailingAttachments,
                    translationStrategy: block.translationStrategy,
                    codeRects: block.codeRects,
                    kind: block.kind,
                    textColor: block.textColor,
                    backgroundColor: block.backgroundColor,
                    alignment: block.alignment,
                    weight: block.weight,
                    fontSize: block.fontSize
                )
            }
        }
    }

    static func splitListItems(_ markdown: String) -> [String] {
        let text = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let expression = try? NSRegularExpression(
                pattern: #"(?:^|\s)[•·]\s+|(?:^|\n)\s*[-*]\s+"#
              )
        else {
            return []
        }

        let nsText = text as NSString
        let matches = expression.matches(
            in: text,
            range: NSRange(location: 0, length: nsText.length)
        )
        guard !matches.isEmpty else {
            return [text]
        }

        var items: [String] = []
        var start = matches[0].range.location + matches[0].range.length
        for match in matches.dropFirst() {
            let range = NSRange(location: start, length: max(0, match.range.location - start))
            let item = nsText.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            if !item.isEmpty {
                items.append(item)
            }
            start = match.range.location + match.range.length
        }

        let tail = nsText.substring(from: start).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            items.append(tail)
        }

        return items.isEmpty ? [text] : items
    }

    private static func normalizedKind(_ kind: String?) -> String {
        kind?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_") ?? "paragraph"
    }
}

enum ImageTranslationElasticSpacing {
    static func distributedGaps(
        baseGaps: [CGFloat],
        minimumGaps: [CGFloat],
        maximumGaps: [CGFloat],
        itemHeights: [CGFloat],
        availableHeight: CGFloat
    ) -> [CGFloat] {
        guard baseGaps.count == minimumGaps.count,
              baseGaps.count == maximumGaps.count,
              baseGaps.count == itemHeights.count,
              !baseGaps.isEmpty
        else {
            return baseGaps
        }

        let availableForGaps = max(0, availableHeight - itemHeights.reduce(0, +))
        let minimumTotal = minimumGaps.reduce(0, +)
        let baseTotal = baseGaps.reduce(0, +)

        if availableForGaps <= baseTotal {
            guard minimumTotal > 0 else {
                return Array(repeating: 0, count: baseGaps.count)
            }
            if availableForGaps <= minimumTotal {
                let scale = availableForGaps / minimumTotal
                return minimumGaps.map { $0 * scale }
            }

            let flexibleTotal = max(1, baseTotal - minimumTotal)
            let progress = (availableForGaps - minimumTotal) / flexibleTotal
            return zip(minimumGaps, baseGaps).map { minimum, base in
                minimum + (base - minimum) * progress
            }
        }

        var gaps = baseGaps
        var remaining = availableForGaps - baseTotal
        for _ in 0..<baseGaps.count where remaining > 0.5 {
            let expandable = gaps.indices.filter { gaps[$0] < maximumGaps[$0] - 0.5 }
            guard !expandable.isEmpty else {
                break
            }
            let share = remaining / CGFloat(expandable.count)
            var consumed: CGFloat = 0
            for index in expandable {
                let addition = min(share, maximumGaps[index] - gaps[index])
                gaps[index] += addition
                consumed += addition
            }
            remaining -= consumed
        }

        return gaps
    }
}

