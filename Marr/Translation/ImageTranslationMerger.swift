import Foundation

/// Projects translated text onto source regions without parsing or networking.
enum ImageTranslationMerger {
    static func merge(
        replacements: [ImageTranslationReplacement],
        regions: [ImageTranslationSourceRegion]
    ) -> [ImageTranslationBlock] {
        let replacementByID = Dictionary(
            replacements.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // Even an untranslated formula must survive erasing an adjacent line.
        let mathRects = regions.flatMap { region in
            region.tokens.filter(\.isMathematical).map { imageLineRect(tokenRect($0)) }
        }

        return regions.flatMap { region -> [ImageTranslationBlock] in
            guard region.requiresTranslation,
                  let replacement = replacementByID[region.id] else {
                return []
            }

            if region.translationStrategy == .selective, !region.tokens.isEmpty {
                return segmentBlocks(replacement: replacement, region: region, mathRects: mathRects)
            }

            guard !replacement.text.isEmpty else {
                return []
            }
            let text = removingUnexpectedNumericBadges(
                from: sanitizedMarkdown(
                    replacement.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    allowedCodeTokens: region.codeRects
                ),
                sourceText: region.sourceText
            )
            guard
                !text.isEmpty,
                normalizedComparisonText(text) != normalizedComparisonText(region.sourceText)
            else {
                return []
            }
            return [region.translationBlock(
                text: text,
                kind: resolvedKind(sourceKind: region.kind, replacementKind: replacement.kind),
                mathRects: mathRects
            )]
        }
    }

    // The prompt and validator must agree on boundaries. Each physical line
    // owns its formula order; the renderer may compact that line as a unit.
    static func selectiveProseRanges(in region: ImageTranslationSourceRegion) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var index = 0
        while index < region.tokens.count {
            if region.tokens[index].isProtected { index += 1; continue }
            let start = index
            index += 1
            while index < region.tokens.count, !region.tokens[index].isProtected,
                  !region.preservesInlineMath || belongsToSameTokenLine(tokenRect(region.tokens[start]), tokenRect(region.tokens[index])) {
                index += 1
            }
            ranges.append(start..<index)
        }
        return ranges
    }

    static func validSelectiveSegments(
        replacement: ImageTranslationReplacement,
        region: ImageTranslationSourceRegion
    ) -> [ImageTranslationReplacementSegment] {
        var previousEnd = 0
        return replacement.segments.sorted {
            ($0.tokenStart, $0.tokenEnd) < ($1.tokenStart, $1.tokenEnd)
        }.filter { segment in
            guard segment.tokenStart >= previousEnd,
                  segment.tokenStart >= 0,
                  segment.tokenEnd <= region.tokens.count,
                  segment.tokenEnd > segment.tokenStart,
                  !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return false }
            let tokens = Array(region.tokens[segment.tokenStart..<segment.tokenEnd])
            guard !tokens.contains(where: \.isProtected) else { return false }
            if region.preservesInlineMath, let first = tokens.first {
                guard tokens.allSatisfy({ belongsToSameTokenLine(tokenRect(first), tokenRect($0)) }),
                      !segment.text.contains("⟦math_")
                else { return false }
            }
            previousEnd = segment.tokenEnd
            return true
        }
    }

    static func missingSelectiveProseIndexes(
        replacement: ImageTranslationReplacement,
        region: ImageTranslationSourceRegion
    ) -> Set<Int> {
        let translated = Set(translatedSelectiveSegments(replacement: replacement, region: region)
            .flatMap { Array($0.tokenStart..<$0.tokenEnd) })
        return Set(region.tokens.indices.filter { index in
            let token = region.tokens[index]
            return !token.isProtected && !translated.contains(index)
                && token.text.unicodeScalars.contains { (65...90).contains($0.value) || (97...122).contains($0.value) }
        })
    }

    static func translatedSelectiveSegments(
        replacement: ImageTranslationReplacement,
        region: ImageTranslationSourceRegion
    ) -> [ImageTranslationReplacementSegment] {
        validSelectiveSegments(replacement: replacement, region: region).compactMap { segment in
            let source = region.tokens[segment.tokenStart..<segment.tokenEnd].map(\.text).joined(separator: " ")
            guard let text = renderedSelectiveText(segment.text, sourceText: source) else { return nil }
            return ImageTranslationReplacementSegment(
                tokenStart: segment.tokenStart, tokenEnd: segment.tokenEnd, text: text)
        }
    }

    /// Coverage, retry merging and drawing must agree on the text that survives
    /// sanitization. A model's "Open 7" is still an echo after removing its
    /// invented badge; it cannot claim the slot or replace an existing translation.
    private static func renderedSelectiveText(_ text: String, sourceText: String) -> String? {
        let rendered = removingUnexpectedNumericBadges(
            from: sanitizedMarkdown(text, allowedCodeTokens: []), sourceText: sourceText)
        guard !rendered.isEmpty,
              normalizedComparisonText(rendered) != normalizedComparisonText(sourceText) else { return nil }
        return rendered
    }

    private static func segmentBlocks(
        replacement: ImageTranslationReplacement,
        region: ImageTranslationSourceRegion,
        mathRects: [ImageTranslationLineRect]
    ) -> [ImageTranslationBlock] {
        let sortedSegments = validSelectiveSegments(replacement: replacement, region: region)
        let translatedIndexes = Set(translatedSelectiveSegments(replacement: replacement, region: region)
            .flatMap { Array($0.tokenStart..<$0.tokenEnd) })
        // Do not move a formula away from untranslated words or other fixed
        // attachments while streaming or after an incomplete model response.
        let canFlow = region.tokens.indices.allSatisfy {
            region.tokens[$0].isMathematical || translatedIndexes.contains($0)
        }
        let inlineMathRects = canFlow
            ? region.tokens.filter(\.isMathematical).map { imageLineRect(tokenRect($0)) } : []
        let claimedIndexes = Set(sortedSegments.flatMap { segment -> [Int] in
            let lowerBound = max(0, segment.tokenStart)
            let upperBound = min(region.tokens.count, segment.tokenEnd)
            guard lowerBound < upperBound else {
                return []
            }
            return Array(lowerBound..<upperBound)
        })
        var previousEnd = 0
        var blocks: [ImageTranslationBlock] = []

        for segment in sortedSegments {
            guard
                segment.tokenStart >= previousEnd,
                segment.tokenStart >= 0,
                segment.tokenEnd <= region.tokens.count,
                segment.tokenEnd > segment.tokenStart
            else {
                continue
            }
            previousEnd = segment.tokenEnd

            let requestedIndexes = segment.tokenStart..<segment.tokenEnd
            let selectedIndexes = expandedSelectiveTokenRange(
                requestedIndexes,
                tokens: region.tokens,
                claimedIndexes: claimedIndexes,
                imageAspectRatio: region.imageAspectRatio
            )
            let selectedTokens = Array(region.tokens[selectedIndexes])
            guard !selectedTokens.contains(where: { $0.isProtected }) else {
                continue
            }

            let sourceText = selectedTokens.map(\.text).joined(separator: " ")
            guard let text = renderedSelectiveText(segment.text, sourceText: sourceText) else {
                continue
            }

            let selectedRects = selectedTokens.map(tokenRect)
            let geometry = selectiveTextGeometry(
                selectedRects: selectedRects,
                allTokens: region.tokens,
                selectedIndexes: selectedIndexes,
                imageAspectRatio: region.imageAspectRatio
            )
            guard let sourceRect = unionRect(geometry.layoutRects) else {
                continue
            }
            let lineRects = geometry.layoutRects.map(imageLineRect)
            let textRects = geometry.eraseRects.map(imageLineRect)
            let outsideRects = region.tokens.enumerated().compactMap { index, token in
                selectedIndexes.contains(index) ? nil : protectedTokenBoundaryRect(token, imageAspectRatio: region.imageAspectRatio)
            }
            let outsideTokenRects = outsideRects.map(imageLineRect)
            let inheritedProtectedRects = region.protectedRects.filter { inheritedRect in
                let inherited = rect(from: inheritedRect)
                return !outsideRects.contains { outsideRect in
                    overlapRatio(inherited, outsideRect) > 0.28
                }
            }

            blocks.append(ImageTranslationBlock(
                sourceID: region.id,
                text: text,
                x: sourceRect.minX,
                y: sourceRect.minY,
                width: sourceRect.width,
                height: sourceRect.height,
                lineRects: lineRects,
                preservesListMarker: region.preservesListMarker, listMarkerRects: region.listMarkerRects,
                textRects: textRects,
                protectedRects: inheritedProtectedRects + outsideTokenRects,
                mathRects: mathRects,
                inlineMathRects: inlineMathRects,
                trailingAttachments: trailingNumericAttachmentRects(
                    tokens: region.tokens,
                    selectedIndexes: selectedIndexes,
                    imageAspectRatio: region.imageAspectRatio
                ),
                translationStrategy: .selective,
                codeRects: [],
                kind: resolvedKind(sourceKind: region.kind, replacementKind: replacement.kind),
                textColor: region.textColor,
                backgroundColor: region.backgroundColor,
                alignment: region.alignment,
                weight: region.weight,
                fontSize: region.fontSize
            ))
        }

        return blocks
    }

    private static func trailingNumericAttachmentRects(
        tokens: [ImageTranslationSourceToken],
        selectedIndexes: Range<Int>,
        imageAspectRatio: Double
    ) -> [ImageTranslationLineRect] {
        guard selectedIndexes.upperBound < tokens.count else {
            return []
        }
        let selectedRect = tokenRect(tokens[selectedIndexes.upperBound - 1])
        let candidate = tokens[selectedIndexes.upperBound]
        let candidateRect = tokenRect(candidate)
        guard
            candidate.isProtected,
            !candidate.isMathematical,
            isNumericBadgeToken(candidate.text),
            belongsToSameTokenLine(selectedRect, candidateRect),
            max(0, candidateRect.minX - selectedRect.maxX)
                <= max(0.018, max(selectedRect.height, candidateRect.height) * 0.85 / imageAspectRatio)
        else {
            return []
        }

        let horizontalPadding = max(0.002, candidateRect.height * 0.28 / imageAspectRatio)
        let verticalPadding = max(0.001, candidateRect.height * 0.16)
        let leftBoundary = max(
            0,
            max(
                candidateRect.minX - horizontalPadding,
                (selectedRect.maxX + candidateRect.minX) / 2
            )
        )
        let attachmentRect = CGRect(
            x: leftBoundary,
            y: max(0, candidateRect.minY - verticalPadding),
            width: min(1, candidateRect.maxX + horizontalPadding)
                - leftBoundary,
            height: min(1, candidateRect.maxY + verticalPadding)
                - max(0, candidateRect.minY - verticalPadding)
        )
        return [imageLineRect(attachmentRect)]
    }

    private static func isNumericBadgeToken(_ text: String) -> Bool {
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, token.count <= 6 else {
            return false
        }
        return token.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
    }

    /// Vision occasionally emits a one- or two-character token for the edge of
    /// a word. If the model selects the main word but misses that tiny adjacent
    /// token, preserving it produces a visible source-language fragment. Fold
    /// only nearby, unprotected ASCII letter fragments into the erase range.
    private static func expandedSelectiveTokenRange(
        _ requestedRange: Range<Int>,
        tokens: [ImageTranslationSourceToken],
        claimedIndexes: Set<Int>,
        imageAspectRatio: Double
    ) -> Range<Int> {
        var lowerBound = requestedRange.lowerBound
        var upperBound = requestedRange.upperBound

        while lowerBound > 0 {
            let candidateIndex = lowerBound - 1
            guard
                !claimedIndexes.contains(candidateIndex),
                isShortOCRBoundaryFragment(tokens[candidateIndex]),
                areAdjacentTokenFragments(tokens[candidateIndex], tokens[lowerBound], imageAspectRatio: imageAspectRatio)
            else {
                break
            }
            lowerBound = candidateIndex
        }

        while upperBound < tokens.count {
            let candidateIndex = upperBound
            guard
                !claimedIndexes.contains(candidateIndex),
                isShortOCRBoundaryFragment(tokens[candidateIndex]),
                areAdjacentTokenFragments(tokens[upperBound - 1], tokens[candidateIndex], imageAspectRatio: imageAspectRatio)
            else {
                break
            }
            upperBound += 1
        }

        return lowerBound..<upperBound
    }

    private static func isShortOCRBoundaryFragment(_ token: ImageTranslationSourceToken) -> Bool {
        guard !token.isProtected else {
            return false
        }
        let scalars = token.text.unicodeScalars
        guard !scalars.isEmpty, scalars.count <= 2 else {
            return false
        }
        return scalars.allSatisfy { scalar in
            scalar.isASCII && CharacterSet.letters.contains(scalar)
        }
    }

    private static func areAdjacentTokenFragments(
        _ lhs: ImageTranslationSourceToken,
        _ rhs: ImageTranslationSourceToken,
        imageAspectRatio: Double
    ) -> Bool {
        let lhsRect = tokenRect(lhs)
        let rhsRect = tokenRect(rhs)
        guard belongsToSameTokenLine(lhsRect, rhsRect) else {
            return false
        }
        let gap = max(0, max(lhsRect.minX, rhsRect.minX) - min(lhsRect.maxX, rhsRect.maxX))
        return gap <= max(0.003, max(lhsRect.height, rhsRect.height) * 0.30 / imageAspectRatio)
    }

    private struct SelectiveTextGeometry {
        let layoutRects: [CGRect]
        let eraseRects: [CGRect]
    }

    /// Selective replacements have two different geometric requirements:
    /// the source pixels must be erased through the end of the replaced token
    /// run, while the translated text must start after any preserved prefix.
    /// Keeping those slots separate prevents both clipped source glyphs and
    /// translated text that visually collides with an adjacent identity token.
    private static func selectiveTextGeometry(
        selectedRects: [CGRect],
        allTokens: [ImageTranslationSourceToken],
        selectedIndexes: Range<Int>,
        imageAspectRatio: Double
    ) -> SelectiveTextGeometry {
        let selectedLines = mergedTokenLineRects(selectedRects)
        let outsideRects = allTokens.enumerated().compactMap { index, token in
            selectedIndexes.contains(index) ? nil : protectedTokenBoundaryRect(token, imageAspectRatio: imageAspectRatio)
        }

        var layoutRects: [CGRect] = []
        var eraseRects: [CGRect] = []

        for line in selectedLines {
            let neighbors = outsideRects.filter { belongsToSameTokenLine($0, line) }
            let previous = neighbors
                .filter { $0.midX < line.midX }
                .max { $0.maxX < $1.maxX }
            let next = neighbors
                .filter { $0.midX > line.midX }
                .min { $0.minX < $1.minX }

            let leadingGap = max(0.0015, line.height * 0.12 / imageAspectRatio)
            let layoutMinX = previous.map {
                max(line.minX, $0.maxX + leadingGap)
            } ?? line.minX

            // OCR boxes can finish just before the antialiased edge of the last
            // glyph. Extend the erase slot to the next token boundary (which is
            // separately protected), or by a small bounded tail at line end.
            let trailingTail = max(0.002, line.height * 0.22 / imageAspectRatio)
            let eraseMaxX = min(
                1,
                max(line.maxX + trailingTail, next?.minX ?? line.maxX)
            )
            let trailingGap = max(0.0015, line.height * 0.10 / imageAspectRatio)
            let layoutMaxX = next.map {
                max(layoutMinX + 0.004, $0.minX - trailingGap)
            } ?? eraseMaxX

            layoutRects.append(CGRect(
                x: layoutMinX,
                y: line.minY,
                width: layoutMaxX - layoutMinX,
                height: line.height
            ))
            eraseRects.append(CGRect(
                x: line.minX,
                y: line.minY,
                width: max(0.004, eraseMaxX - line.minX),
                height: line.height
            ))
        }

        return SelectiveTextGeometry(
            layoutRects: layoutRects,
            eraseRects: eraseRects
        )
    }

    private static func belongsToSameTokenLine(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let overlap = min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY)
        let overlapRatio = overlap / max(min(lhs.height, rhs.height), 0.001)
        let midlineDistance = abs(lhs.midY - rhs.midY)
        return overlapRatio > 0.32
            || midlineDistance < max(lhs.height, rhs.height) * 0.45
    }

    private static func tokenRect(_ token: ImageTranslationSourceToken) -> CGRect {
        CGRect(x: token.x, y: token.y, width: token.width, height: token.height)
    }

    private static func protectedTokenBoundaryRect(_ token: ImageTranslationSourceToken, imageAspectRatio: Double) -> CGRect {
        let rect = tokenRect(token)
        if token.isMathematical || isNumericBadgeToken(token.text) {
            return rect
        }
        let horizontalInset = min(
            max(0.0008, rect.height * 0.08 / imageAspectRatio),
            rect.width * 0.20
        )
        return rect.insetBy(dx: horizontalInset, dy: 0)
    }

    private static func rect(from lineRect: ImageTranslationLineRect) -> CGRect {
        CGRect(x: lineRect.x, y: lineRect.y, width: lineRect.width, height: lineRect.height)
    }

    private static func overlapRatio(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
            return 0
        }
        let intersectionArea = intersection.width * intersection.height
        let smallerArea = min(lhs.width * lhs.height, rhs.width * rhs.height)
        return intersectionArea / max(smallerArea, 0.000_001)
    }

    private static func imageLineRect(_ rect: CGRect) -> ImageTranslationLineRect {
        ImageTranslationLineRect(
            x: rect.minX,
            y: rect.minY,
            width: rect.width,
            height: rect.height
        )
    }

    private static func unionRect(_ rects: [CGRect]) -> CGRect? {
        guard let first = rects.first else {
            return nil
        }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    private static func mergedTokenLineRects(_ rects: [CGRect]) -> [CGRect] {
        let sorted = rects.sorted { lhs, rhs in
            if abs(lhs.midY - rhs.midY) > max(lhs.height, rhs.height) * 0.45 {
                return lhs.minY < rhs.minY
            }
            return lhs.minX < rhs.minX
        }
        var lines: [CGRect] = []
        for rect in sorted {
            if let index = lines.firstIndex(where: { line in
                let overlap = min(line.maxY, rect.maxY) - max(line.minY, rect.minY)
                let overlapRatio = overlap / max(min(line.height, rect.height), 0.001)
                let midlineDistance = abs(line.midY - rect.midY)
                return overlapRatio > 0.35
                    || midlineDistance < max(line.height, rect.height) * 0.45
            }) {
                lines[index] = lines[index].union(rect)
            } else {
                lines.append(rect)
            }
        }
        return lines.sorted { lhs, rhs in
            if abs(lhs.midY - rhs.midY) > max(lhs.height, rhs.height) * 0.45 {
                return lhs.minY < rhs.minY
            }
            return lhs.minX < rhs.minX
        }
    }

    private static func normalizedComparisonText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func resolvedKind(sourceKind: String?, replacementKind: String?) -> String? {
        let source = sourceKind?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let source, !source.isEmpty else {
            return replacementKind
        }
        return source
    }

    private static func removingUnexpectedNumericBadges(
        from text: String,
        sourceText: String
    ) -> String {
        // Spelled-out quantities can legitimately become digits in Chinese.
        // This filter only removes unexplained UI badges; it must not delete
        // a translation such as "all zeros" -> "全为 0" or "half" -> "0.5".
        let spelledNumber = #"(?i)\b(?:zeros?|ones?|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundreds?|thousands?|millions?|billions?|trillions?|first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|half|halves|quarters?)\b"#
        guard sourceText.rangeOfCharacter(from: .decimalDigits) == nil,
              sourceText.range(of: spelledNumber, options: .regularExpression) == nil else {
            return text
        }

        return text
            .replacingOccurrences(
                of: #"(?<![A-Za-z0-9])[(\[]?\d+(?:[.,]\d+)*[)\]]?(?![A-Za-z0-9])"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sanitizedMarkdown(
        _ markdown: String,
        allowedCodeTokens: [ImageTranslationTokenRect]
    ) -> String {
        let plainText = markdown.replacingOccurrences(of: "`", with: "")
        let allowedTokens = allowedCodeTokens
            .map { normalizedInlineCodeToken($0.text) }
            .filter { !$0.isEmpty }
        guard !allowedTokens.isEmpty,
              let expression = try? NSRegularExpression(pattern: #"[A-Za-z_][A-Za-z0-9_./:-]*"#)
        else {
            return plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let output = NSMutableString(string: plainText)
        let fullRange = NSRange(location: 0, length: output.length)
        let matches = expression.matches(in: plainText, range: fullRange)

        for match in matches.reversed() {
            let candidate = output.substring(with: match.range)
            let normalized = normalizedInlineCodeToken(candidate)
            guard allowedTokens.contains(where: { codeTokensMatch(normalized, $0) }) else {
                continue
            }
            output.replaceCharacters(in: match.range, with: "`\(candidate)`")
        }

        return String(output).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedInlineCodeToken(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: inlineCodeTrimCharacters)
    }

    private static func codeTokensMatch(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs {
            return true
        }

        let left = lhs.lowercased()
        let right = rhs.lowercased()
        let shorterCount = min(left.count, right.count)
        let longerCount = max(left.count, right.count)
        guard shorterCount >= 6 else {
            return false
        }

        if (left.hasPrefix(right) || right.hasPrefix(left)),
           Double(shorterCount) / Double(longerCount) >= 0.72 {
            return true
        }

        return editDistance(left, right) <= max(1, longerCount / 8)
    }

    private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        var previous = Array(0...right.count)

        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = Array(repeating: 0, count: right.count + 1)
            current[0] = leftIndex + 1

            for (rightIndex, rightCharacter) in right.enumerated() {
                let substitutionCost = leftCharacter == rightCharacter ? 0 : 1
                current[rightIndex + 1] = min(
                    previous[rightIndex + 1] + 1,
                    current[rightIndex] + 1,
                    previous[rightIndex] + substitutionCost
                )
            }
            previous = current
        }

        return previous[right.count]
    }

    private static let inlineCodeTrimCharacters = CharacterSet(charactersIn: ".,;:!?()[]{}<>`\"'“”‘’")

}
