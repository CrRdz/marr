import CoreGraphics
import Foundation

public enum MarkdownLineLayout {
    private struct Token {
        let markdown: String
        let plainText: String
        let isCode: Bool
    }

    public static func lines(
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
        guard tokens.count > 1 else {
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
                   remainingTokensAfterThis > 0,
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
        guard let lastUsedLineIndex = lines.lastIndex(where: { !$0.isEmpty }) else {
            return nil
        }
        let usedLines = Array(lines[...lastUsedLineIndex])
        guard
            usedLines.count > 1,
            usedLines.allSatisfy({ !$0.isEmpty })
        else {
            return nil
        }
        return usedLines
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
            } else if TextCharacterRules.isCJKCharacter(character) {
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

        if TextCharacterRules.isCJKCharacter(lhsLast), TextCharacterRules.isCJKCharacter(rhsFirst) {
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
