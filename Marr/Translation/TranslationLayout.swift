import AppKit
import Foundation

struct ImageTranslationHighlightPair: Identifiable, Equatable, Sendable {
    let id: String
    let sourceID: String?
    let targetText: String?
    let sourceRects: [CGRect]
    let translatedRects: [CGRect]

    init(
        id: String,
        sourceID: String? = nil,
        targetText: String? = nil,
        sourceRects: [CGRect],
        translatedRects: [CGRect]
    ) {
        self.id = id
        self.sourceID = sourceID
        self.targetText = targetText
        self.sourceRects = sourceRects
        self.translatedRects = translatedRects
    }
}

enum ImageTranslationHighlightBuilder {
    static func regionsNeedingAlignmentRepair(
        regions: [ImageTranslationSourceRegion],
        replacements: [ImageTranslationReplacement]
    ) -> [ImageTranslationSourceRegion] {
        let replacementByID = Dictionary(
            replacements.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return regions.filter { region in
            guard region.translationStrategy == .block,
                  !region.tokens.isEmpty,
                  let replacement = replacementByID[region.id],
                  !replacement.text.isEmpty
            else { return false }

            return !hasReliableAlignments(replacement: replacement, region: region)
        }
    }

    static func hasReliableAlignments(
        replacement: ImageTranslationReplacement,
        region: ImageTranslationSourceRegion
    ) -> Bool {
        let alignments = validAlignments(replacement.alignments, for: region)
        guard !alignments.isEmpty, !region.tokens.isEmpty else { return false }

        var expectedTokenStart = 0
        var targetSearchStart = replacement.text.startIndex
        var coveredTargetCharacters = 0
        let totalTargetCharacters = visibleCharacterCount(replacement.text)

        for alignment in alignments {
            guard alignment.tokenStart == expectedTokenStart else { return false }
            expectedTokenStart = alignment.tokenEnd

            guard let range = replacement.text.range(
                of: alignment.targetText,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: targetSearchStart..<replacement.text.endIndex
            ) else { return false }
            targetSearchStart = range.upperBound
            coveredTargetCharacters += visibleCharacterCount(alignment.targetText)

            let sourceShare = CGFloat(alignment.tokenEnd - alignment.tokenStart)
                / CGFloat(max(region.tokens.count, 1))
            let targetShare = CGFloat(visibleCharacterCount(alignment.targetText))
                / CGFloat(max(totalTargetCharacters, 1))
            if sourceShare > 0.08, targetShare > 0, sourceShare / targetShare > 4.0 {
                return false
            }
        }

        return expectedTokenStart == region.tokens.count
            && CGFloat(coveredTargetCharacters) / CGFloat(max(totalTargetCharacters, 1)) >= 0.82
    }

    static func pairs(
        regions: [ImageTranslationSourceRegion],
        replacements: [ImageTranslationReplacement]
    ) -> [ImageTranslationHighlightPair] {
        let replacementByID = Dictionary(
            replacements.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return regions.flatMap { region -> [ImageTranslationHighlightPair] in
            guard let replacement = replacementByID[region.id] else {
                return []
            }

            if region.translationStrategy == .selective {
                return ImageTranslationMerger.translatedSelectiveSegments(
                    replacement: replacement, region: region
                ).enumerated().compactMap { index, segment in
                    let range = segment.tokenStart..<segment.tokenEnd
                    guard !range.isEmpty else { return nil }
                    let rects = sourceRects(for: range, tokens: region.tokens)
                    guard !rects.isEmpty else { return nil }
                    return ImageTranslationHighlightPair(
                        id: "\(region.id)-s\(index)",
                        sourceID: region.id,
                        sourceRects: rects,
                        translatedRects: rects
                    )
                }
            }

            let alignments = hasReliableAlignments(replacement: replacement, region: region)
                ? validAlignments(replacement.alignments, for: region)
                : []
            let resolvedAlignments = alignments.isEmpty
                ? fallbackAlignments(region: region, targetText: replacement.text)
                : alignments
            let placements = targetPlacements(
                text: replacement.text,
                targets: resolvedAlignments.map(\.targetText),
                lineRects: region.lineRects,
                fallbackRect: regionRect(region),
                fontSize: CGFloat(region.fontSize ?? 0),
                imageAspectRatio: CGFloat(region.imageAspectRatio)
            )

            return resolvedAlignments.enumerated().compactMap { index, alignment in
                let range = alignment.tokenStart..<alignment.tokenEnd
                let source = sourceRects(for: range, tokens: region.tokens)
                let translated = placements.indices.contains(index) ? placements[index] : []
                guard !source.isEmpty, !translated.isEmpty else { return nil }
                return ImageTranslationHighlightPair(
                    id: "\(region.id)-a\(index)",
                    sourceID: region.id,
                    targetText: alignment.targetText,
                    sourceRects: source,
                    translatedRects: translated
                )
            }
        }
    }

    private static func validAlignments(
        _ alignments: [ImageTranslationAlignment],
        for region: ImageTranslationSourceRegion
    ) -> [ImageTranslationAlignment] {
        alignments
            .filter {
                $0.tokenStart >= 0
                    && $0.tokenEnd <= region.tokens.count
                    && $0.tokenEnd > $0.tokenStart
                    && !$0.targetText.isEmpty
            }
            .sorted {
                if $0.tokenStart == $1.tokenStart { return $0.tokenEnd < $1.tokenEnd }
                return $0.tokenStart < $1.tokenStart
            }
    }

    private static func fallbackAlignments(
        region: ImageTranslationSourceRegion,
        targetText: String
    ) -> [ImageTranslationAlignment] {
        guard !region.tokens.isEmpty, !targetText.isEmpty else { return [] }
        var ranges: [Range<Int>] = []
        var start = 0
        for index in region.tokens.indices {
            let token = region.tokens[index].text
            let closesSentence = token.range(of: #"[.!?。！？][\"'”’)]?$"#, options: .regularExpression) != nil
            if closesSentence || index - start >= 11 {
                ranges.append(start..<(index + 1))
                start = index + 1
            }
        }
        if start < region.tokens.count {
            ranges.append(start..<region.tokens.count)
        }

        let phrases = targetPhrases(targetText, count: ranges.count)
        return zip(ranges, phrases).map { range, phrase in
            ImageTranslationAlignment(
                tokenStart: range.lowerBound,
                tokenEnd: range.upperBound,
                targetText: phrase
            )
        }
    }

    private static func targetPhrases(_ text: String, count: Int) -> [String] {
        guard count > 1 else { return [text] }
        var sentences: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if "。！？.!?".contains(character), !current.trimmingCharacters(in: .whitespaces).isEmpty {
                sentences.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            sentences.append(current.trimmingCharacters(in: .whitespaces))
        }
        if sentences.count == count {
            return sentences
        }

        let characters = Array(text)
        return (0..<count).map { index in
            let lower = characters.count * index / count
            let upper = characters.count * (index + 1) / count
            return String(characters[lower..<upper]).trimmingCharacters(in: .whitespaces)
        }
    }

    private struct GlyphPlacement {
        let range: Range<String.Index>
        let lineIndex: Int
        let rect: CGRect
    }

    private static func targetPlacements(
        text: String,
        targets: [String],
        lineRects: [ImageTranslationLineRect],
        fallbackRect: CGRect,
        fontSize: CGFloat,
        imageAspectRatio: CGFloat
    ) -> [[CGRect]] {
        let lines = (lineRects.isEmpty ? [fallbackRect] : lineRects.map(rect))
            .sorted { lhs, rhs in
                if lhs.minY != rhs.minY { return lhs.minY < rhs.minY }
                return lhs.minX < rhs.minX
            }
        guard !lines.isEmpty else { return Array(repeating: [], count: targets.count) }

        let resolvedFontSize = fontSize > 0
            ? fontSize
            : (lines.map(\.height).sorted().dropFirst(lines.count / 2).first ?? lines[0].height) * 0.82
        var placements: [GlyphPlacement] = []
        var lineIndex = 0
        var xOffset: CGFloat = 0

        for index in text.indices {
            let next = text.index(after: index)
            let character = text[index]
            let width = glyphWidth(character, fontSize: resolvedFontSize) / imageAspectRatio
            let line = lines[min(lineIndex, lines.count - 1)]
            let inset = min(line.height * 0.08 / imageAspectRatio, line.width * 0.035)
            let usableWidth = max(0.004, line.width - inset * 2)

            if xOffset > 0, xOffset + width > usableWidth, lineIndex < lines.count - 1 {
                lineIndex += 1
                xOffset = 0
            }

            let activeLine = lines[min(lineIndex, lines.count - 1)]
            let activeInset = min(activeLine.height * 0.08 / imageAspectRatio, activeLine.width * 0.035)
            placements.append(GlyphPlacement(
                range: index..<next,
                lineIndex: lineIndex,
                rect: CGRect(
                    x: activeLine.minX + activeInset + xOffset,
                    y: activeLine.minY,
                    width: max(width, 0.002 / imageAspectRatio),
                    height: activeLine.height
                )
            ))
            xOffset += width
        }

        var searchStart = text.startIndex
        return targets.map { target in
            let found = text.range(
                of: target,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchStart..<text.endIndex
            ) ?? text.range(of: target, options: [.caseInsensitive, .diacriticInsensitive])
            guard let found else { return [] }
            searchStart = found.upperBound

            let matching = placements.filter { $0.range.overlaps(found) }
            return Dictionary(grouping: matching, by: \.lineIndex)
                .keys
                .sorted()
                .compactMap { line in
                    let rects = matching.filter { $0.lineIndex == line }.map(\.rect)
                    return rects.reduce(nil as CGRect?) { partial, rect in
                        partial?.union(rect) ?? rect
                    }?.insetBy(dx: -0.002 / imageAspectRatio, dy: -0.001)
                }
        }
    }

    private static func glyphWidth(_ character: Character, fontSize: CGFloat) -> CGFloat {
        if character == "`" { return 0 }
        let layoutScale: CGFloat = 1_000
        let isCJK = character.unicodeScalars.contains { scalar in
            let value = Int(scalar.value)
            return (0x3400...0x4DBF).contains(value)
                || (0x4E00...0x9FFF).contains(value)
                || (0xF900...0xFAFF).contains(value)
        }
        let renderedFontSize = fontSize * (isCJK ? 0.88 : 1)
        let font = TranslationTypography.proseFont(ofSize: renderedFontSize * layoutScale)
        return ceil((String(character) as NSString).size(withAttributes: [.font: font]).width)
            / layoutScale
    }

    private static func visibleCharacterCount(_ text: String) -> Int {
        text.reduce(into: 0) { count, character in
            if !character.isWhitespace, character != "`" {
                count += 1
            }
        }
    }

    private static func sourceRects(
        for range: Range<Int>,
        tokens: [ImageTranslationSourceToken]
    ) -> [CGRect] {
        let valid = max(0, range.lowerBound)..<min(tokens.count, range.upperBound)
        guard !valid.isEmpty else { return [] }
        let grouped = Dictionary(grouping: valid.map { tokens[$0] }) { token in
            Int((token.y * 1_000).rounded())
        }
        return grouped.values.map { row in
            row.map { token in
                CGRect(x: token.x, y: token.y, width: token.width, height: token.height)
            }
            .reduce(CGRect.null) { $0.union($1) }
            .insetBy(dx: -0.002, dy: -0.001)
        }
    }

    private static func regionRect(_ region: ImageTranslationSourceRegion) -> CGRect {
        CGRect(x: region.x, y: region.y, width: region.width, height: region.height)
    }

    private static func rect(_ value: ImageTranslationLineRect) -> CGRect {
        CGRect(x: value.x, y: value.y, width: value.width, height: value.height)
    }
}

enum ImageTranslationReadingOrderLayout {
    /// Vision uses a bottom-left origin. Do not use a pairwise y tolerance in
    /// this comparator: it can reverse dense rows and make sorting nontransitive.
    /// Fragments on the same row are grouped separately before sorting by x.
    static func precedesInReadingOrder(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        if lhs.midY != rhs.midY {
            return lhs.midY > rhs.midY
        }
        return lhs.minX < rhs.minX
    }

    static func visualLineGroups(
        for rects: [CGRect],
        imageAspectRatio: CGFloat = 1,
        listItemStarts: Set<Int> = []
    ) -> [[Int]] {
        let orderedIndexes = rects.indices.sorted {
            precedesInReadingOrder(rects[$0], rects[$1])
        }
        var groups: [(indexes: [Int], rect: CGRect)] = []
        for index in orderedIndexes {
            let rect = rects[index]
            let matchingGroups = groups.indices.filter {
                let group = groups[$0]
                let existingMarkers = group.indexes.filter { listItemStarts.contains($0) }
                let isNewListItem = listItemStarts.contains(index)
                if isNewListItem, !existingMarkers.isEmpty { return false }
                // A marker establishes the left boundary of its list item.
                // A nearby badge/label to its left is a separate region, even
                // when baseline and inter-observation spacing happen to match.
                let leadingAllowance = min(rect.height, group.rect.height) * 0.1 / imageAspectRatio
                if isNewListItem, group.rect.minX < rect.minX - leadingAllowance { return false }
                if let marker = existingMarkers.first,
                   rect.minX < rects[marker].minX - leadingAllowance { return false }
                return belongsToSameVisualLine(
                    rect, lineRect: groups[$0].rect, imageAspectRatio: imageAspectRatio
                )
            }
            guard let firstMatch = matchingGroups.first else {
                groups.append(([index], rect))
                continue
            }

            groups[firstMatch].indexes.append(index)
            groups[firstMatch].rect = groups[firstMatch].rect.union(rect)
            // Baseline variation can put the left and right styled fragments
            // before the middle fragment. Join every group it bridges so the
            // resulting line does not depend on the OCR observation order.
            for otherMatch in matchingGroups.dropFirst().reversed() {
                groups[firstMatch].indexes.append(contentsOf: groups[otherMatch].indexes)
                groups[firstMatch].rect = groups[firstMatch].rect.union(groups[otherMatch].rect)
                groups.remove(at: otherMatch)
            }
        }

        return groups.sorted { precedesInReadingOrder($0.rect, $1.rect) }.map { group in
            group.indexes.sorted { rects[$0].minX < rects[$1].minX }
        }
    }

    static func belongsToSameVisualLine(
        _ candidate: CGRect,
        lineRect: CGRect,
        imageAspectRatio: CGFloat = 1
    ) -> Bool {
        guard imageAspectRatio.isFinite, imageAspectRatio > 0,
              candidate.height > 0, lineRect.height > 0
        else {
            return false
        }
        let smallerHeight = min(candidate.height, lineRect.height)
        let verticalOverlap = min(candidate.maxY, lineRect.maxY)
            - max(candidate.minY, lineRect.minY)
        let overlapRatio = verticalOverlap / max(smallerHeight, 0.001)
        let midlineDistance = abs(candidate.midY - lineRect.midY)
        let isVerticallyAligned = overlapRatio > 0.30
            && midlineDistance < max(candidate.height, lineRect.height) * 0.42
        guard isVerticallyAligned else {
            return false
        }

        // Vision can split a styled sentence into multiple observations, but
        // vertical alignment alone also joins unrelated columns. Require the
        // observations to be close enough to plausibly belong to one run.
        let horizontalGap = max(
            0,
            max(candidate.minX, lineRect.minX) - min(candidate.maxX, lineRect.maxX)
        )
        // x is normalized by image width and y by image height. Convert the
        // glyph-height allowance to x units before comparing horizontal gaps,
        // otherwise wide screenshot crops join separate columns and controls.
        let allowedGap = max(candidate.height, lineRect.height) / imageAspectRatio
        return horizontalGap <= allowedGap
    }

    static func canContinueTextColumn(previousRect: CGRect, candidateRect: CGRect) -> Bool {
        let horizontalOverlap = min(previousRect.maxX, candidateRect.maxX)
            - max(previousRect.minX, candidateRect.minX)
        return candidateRect.midY < previousRect.midY && horizontalOverlap > 0
    }

    static func closestCompatibleBlockIndex(
        for candidate: CGRect,
        lastLineRects: [CGRect],
        isCompatible: (Int) -> Bool
    ) -> Int? {
        lastLineRects.indices
            .filter(isCompatible)
            .min { lhsIndex, rhsIndex in
                let lhs = lastLineRects[lhsIndex]
                let rhs = lastLineRects[rhsIndex]
                let lhsVerticalDistance = axisGap(candidate.minY...candidate.maxY, lhs.minY...lhs.maxY)
                let rhsVerticalDistance = axisGap(candidate.minY...candidate.maxY, rhs.minY...rhs.maxY)

                if abs(lhsVerticalDistance - rhsVerticalDistance) > 0.000_1 {
                    return lhsVerticalDistance < rhsVerticalDistance
                }
                return abs(candidate.minX - lhs.minX) < abs(candidate.minX - rhs.minX)
            }
    }

    static func isWrappedHeadingContinuation(
        previousRect: CGRect,
        candidateRect: CGRect,
        previousLooksLikeHeading: Bool,
        candidateLooksLikeHeading: Bool,
        imageAspectRatio: CGFloat = 1
    ) -> Bool {
        guard previousLooksLikeHeading, candidateLooksLikeHeading,
              imageAspectRatio.isFinite, imageAspectRatio > 0,
              canContinueTextColumn(previousRect: previousRect, candidateRect: candidateRect)
        else {
            return false
        }

        let maximumHeight = max(previousRect.height, candidateRect.height)
        guard maximumHeight > 0 else {
            return false
        }

        let heightRatio = min(previousRect.height, candidateRect.height) / maximumHeight
        let verticalGap = previousRect.minY - candidateRect.maxY
        let indentationDelta = abs(previousRect.minX - candidateRect.minX)
        let previousWidthInLineHeights = previousRect.width * imageAspectRatio / maximumHeight

        // Large display headings often wrap into independently recognized rows.
        // A short settings/sidebar label is a separate control, even when the
        // next label is aligned. Require a sufficiently long preceding row and
        // tight leading before treating short text as a wrapped heading.
        return heightRatio >= 0.62
            && previousWidthInLineHeights >= 6
            && indentationDelta < 0.040
            && verticalGap > -maximumHeight * 0.25
            && verticalGap < maximumHeight * 0.65
    }

    static func isTightWrappedParagraphContinuation(
        previousRect: CGRect,
        candidateRect: CGRect,
        blockRect: CGRect,
        imageAspectRatio: CGFloat = 1
    ) -> Bool {
        let maximumHeight = max(previousRect.height, candidateRect.height)
        guard maximumHeight > 0, imageAspectRatio.isFinite, imageAspectRatio > 0,
              canContinueTextColumn(previousRect: previousRect, candidateRect: candidateRect)
        else {
            return false
        }

        let verticalGap = previousRect.minY - candidateRect.maxY
        let indentationDelta = abs(previousRect.minX - candidateRect.minX)
        let trailingSlack = max(0, blockRect.maxX - previousRect.maxX)

        // A sentence ending exactly at a visual line boundary is still part of
        // the same paragraph when the preceding row fills the text column and
        // the next row resumes immediately at the same leading edge.
        return indentationDelta < 0.035
            && verticalGap > -maximumHeight * 0.45
            && verticalGap < maximumHeight * 0.85
            && trailingSlack < max(0.045, maximumHeight * 2.2 / imageAspectRatio)
    }

    private static func axisGap(
        _ lhs: ClosedRange<CGFloat>,
        _ rhs: ClosedRange<CGFloat>
    ) -> CGFloat {
        max(0, max(lhs.lowerBound, rhs.lowerBound) - min(lhs.upperBound, rhs.upperBound))
    }
}

enum ImageTranslationLayoutGeometry {
    static func expandedLineRects(
        _ lineRects: [CGRect],
        sourceRect: CGRect,
        bounds: CGRect,
        alignment: NSTextAlignment = .left
    ) -> [CGRect] {
        guard lineRects.count > 1 else {
            return lineRects
        }

        let originalRightEdge = lineRects.map(\.maxX).max() ?? sourceRect.maxX
        let rightEdge = min(bounds.maxX, max(sourceRect.maxX, originalRightEdge))
        let leftEdge = max(bounds.minX, min(sourceRect.minX, lineRects.map(\.minX).min() ?? sourceRect.minX))

        return lineRects.map { lineRect in
            if alignment == .center {
                // Give shorter rows room to translate on both sides of their
                // original center. Extending only the right edge moves every
                // centered line by a different amount.
                let halfWidth = min(
                    max(sourceRect.width, rightEdge - leftEdge) / 2,
                    lineRect.midX - bounds.minX,
                    bounds.maxX - lineRect.midX
                )
                guard halfWidth > 0 else { return lineRect }
                return CGRect(x: lineRect.midX - halfWidth, y: lineRect.minY,
                              width: halfWidth * 2, height: lineRect.height)
            }
            if alignment == .right {
                // A right-aligned row can borrow leading space without
                // changing the source's trailing anchor.
                return CGRect(x: leftEdge, y: lineRect.minY,
                              width: max(1, lineRect.maxX - leftEdge), height: lineRect.height)
                    .intersection(bounds)
            }
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

        // A single slash also joins ordinary prose (constraint/penalty,
        // input/output). It is not enough evidence to freeze a word as code.
        // Explicit paths, members and visual code chips are still protected.
        let isPath = token.filter { $0 == "/" }.count >= 2
        let isAbbreviation = ["e.g", "i.e", "etc", "vs"].contains(token.lowercased())
        if token.contains("_")
            || (token.contains(".") && !isAbbreviation)
            || isPath
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
            guard normalizedKind(block.kind) == "list_item", !block.preservesListMarker else {
                return [block]
            }

            let items = splitListItems(block.text)
            guard items.count > 1 else {
                return [block]
            }

            return items.enumerated().map { index, text in
                let fraction = Double(index) / Double(items.count)
                return ImageTranslationBlock(
                    sourceID: block.sourceID,
                    text: text,
                    x: block.x,
                    y: min(1, block.y + block.height * fraction),
                    width: block.width,
                    height: max(0.006, block.height / Double(items.count)),
                    lineRects: [],
                    listMarkerRects: block.listMarkerRects,
                    textRects: [],
                    protectedRects: block.protectedRects,
                    mathRects: block.mathRects,
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
