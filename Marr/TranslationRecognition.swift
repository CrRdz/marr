import AppKit
import Foundation
import NaturalLanguage
import Vision

enum ImageTranslationSourcePolicy {
    static func shouldTranslate(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, !containsTargetLanguageText(trimmed) else {
            return false
        }

        let latinLetterCount = trimmed.unicodeScalars.reduce(into: 0) { count, scalar in
            if scalar.isASCII,
               CharacterSet.letters.contains(scalar) {
                count += 1
            }
        }
        return latinLetterCount >= 2
    }

    static func isDecorativeFragment(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 1 else {
            return false
        }

        return trimmed.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || CharacterSet.punctuationCharacters.contains(scalar)
                || CharacterSet.symbols.contains(scalar)
        }
    }

    static func shouldIncludeRecognizedToken(
        _ text: String,
        index: Int,
        totalCount: Int
    ) -> Bool {
        !isProtectedRecognizedToken(text, index: index, totalCount: totalCount)
    }

    static func isProtectedRecognizedToken(
        _ text: String,
        index: Int,
        totalCount: Int
    ) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return true
        }

        let scalars = trimmed.unicodeScalars
        let containsDigit = scalars.contains { CharacterSet.decimalDigits.contains($0) }
        let containsLetter = scalars.contains { CharacterSet.letters.contains($0) }
        if containsDigit, !containsLetter {
            return true
        }
        if !containsDigit, !containsLetter {
            return true
        }

        if index == 0, trimmed.allSatisfy(isLeadingDecorativeCharacter) {
            return true
        }

        if index == 0, totalCount > 1, trimmed.count == 1 {
            return true
        }

        if isStructuralSeparator(trimmed) || isIntrinsicIdentifier(trimmed) {
            return true
        }

        return totalCount == 1 && isDecorativeFragment(trimmed)
    }

    static func isLeadingDecorativeCharacter(_ character: Character) -> Bool {
        "•·●○◦▪▫‣⁃→↗↘↙↖⇱⇲⤴①②③④⑤⑥⑦⑧⑨⑩".contains(character)
    }

    static func protectedTokenIndexes(
        _ tokens: [String],
        preservedPhrases: [[String]] = [],
        namedEntityIndexes: Set<Int> = []
    ) -> Set<Int> {
        var protected = namedEntityIndexes
        for (index, token) in tokens.enumerated() where isProtectedRecognizedToken(
            token,
            index: index,
            totalCount: tokens.count
        ) {
            protected.insert(index)
        }

        let normalizedTokens = tokens.map(normalizedComparableToken)
        for phrase in preservedPhrases {
            let normalizedPhrase = phrase.map(normalizedComparableToken).filter { !$0.isEmpty }
            guard !normalizedPhrase.isEmpty, normalizedPhrase.count <= normalizedTokens.count else {
                continue
            }
            for start in 0...(normalizedTokens.count - normalizedPhrase.count) where
                Array(normalizedTokens[start..<(start + normalizedPhrase.count)]) == normalizedPhrase {
                protected.formUnion(start..<(start + normalizedPhrase.count))
            }
        }
        return protected
    }

    static func identityPhraseBeforeSeparator(_ tokens: [String]) -> [String]? {
        guard
            let separatorIndex = tokens.firstIndex(where: isStructuralSeparator),
            separatorIndex > 0,
            separatorIndex <= 5
        else {
            return nil
        }
        var prefix = Array(tokens.prefix(separatorIndex))
        while prefix.count > 1,
              let first = prefix.first,
              first.trimmingCharacters(in: .whitespacesAndNewlines).count == 1 {
            prefix.removeFirst()
        }
        guard prefix.allSatisfy(isLikelyIdentityComponent) else {
            return nil
        }
        return prefix
    }

    static func translationStrategy(
        tokenTexts: [String],
        protectedIndexes: Set<Int>,
        lineCount: Int
    ) -> ImageTranslationStrategy {
        guard lineCount == 1, tokenTexts.count <= 8 else {
            return .block
        }

        let translatableIndexes = tokenTexts.indices.filter { index in
            !protectedIndexes.contains(index)
                && tokenTexts[index].unicodeScalars.contains {
                    CharacterSet.letters.contains($0)
                }
        }
        guard let firstTranslatableIndex = translatableIndexes.first else {
            return .block
        }

        let hasProtectedPrefix = firstTranslatableIndex >= 2
            && (0..<firstTranslatableIndex).allSatisfy { protectedIndexes.contains($0) }
        let hasStructuralSeparator = tokenTexts.contains(where: isStructuralSeparator)
        let hasSentenceTerminator = tokenTexts.contains { token in
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && trimmed.allSatisfy { ".!?。！？".contains($0) }
        }

        guard
            !hasSentenceTerminator,
            hasStructuralSeparator || hasProtectedPrefix
        else {
            return .block
        }
        return .selective
    }

    static func isStructuralSeparator(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.allSatisfy { "|｜¦".contains($0) }
    }

    private static func isIntrinsicIdentifier(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
        guard trimmed.count >= 2 else {
            return false
        }
        if ImageTranslationCodeHeuristics.isStrongIdentifier(trimmed) {
            return true
        }

        let letters = trimmed.filter(\.isLetter)
        guard letters.count >= 2 else {
            return false
        }
        if letters.allSatisfy({ $0.isUppercase }) {
            return true
        }
        let trailingLetters = letters.dropFirst()
        return trailingLetters.contains(where: { $0.isUppercase })
            && letters.contains(where: { $0.isLowercase })
    }

    private static func isLikelyIdentityComponent(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
        return trimmed.range(
            of: #"^[A-Z][A-Za-z0-9'’._-]*$"#,
            options: .regularExpression
        ) != nil
    }

    private static func normalizedComparableToken(_ token: String) -> String {
        token
            .trimmingCharacters(in: .punctuationCharacters.union(.symbols))
            .lowercased()
    }

    private static func containsTargetLanguageText(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let value = Int(scalar.value)
            return (0x3400...0x4DBF).contains(value)
                || (0x4E00...0x9FFF).contains(value)
                || (0xF900...0xFAFF).contains(value)
        }
    }
}

enum ImageTranslationTextRecognizer {
    static func regions(for pickedImage: PickedImage) throws -> [ImageTranslationSourceRegion] {
        try Task.checkCancellation()
        var sourceRect = CGRect(origin: .zero, size: pickedImage.image.size)
        guard let cgImage = pickedImage.image.cgImage(forProposedRect: &sourceRect, context: nil, hints: nil) else {
            return []
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US", "zh-Hans"]
        request.minimumTextHeight = 0.006

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        try Task.checkCancellation()

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let observations = request.results ?? []
        let preservedPhrases = dynamicallyPreservedPhrases(from: observations)
        let fragments = observations.compactMap { observation in
            fragment(
                from: observation,
                bitmap: bitmap,
                preservedPhrases: preservedPhrases
            )
        }
        let protectedRects = fragments
            .flatMap(\.protectedBoxes)
            .map { expandedProtectedTokenRect(topLeftRect(fromVisionBox: $0)) }
        let lines = mergedVisualLines(from: fragments)
        let textBlocks = mergedTextBlocks(from: lines)
        let regions = expandedSourceRegions(
            from: textBlocks,
            globalProtectedRects: protectedRects
        )

        return regions.enumerated().map { index, region in
            ImageTranslationSourceRegion(
                id: String(format: "r%03d", index + 1),
                sourceText: region.text,
                x: region.rect.minX,
                y: region.rect.minY,
                width: region.rect.width,
                height: region.rect.height,
                lineRects: region.lineRects.map { lineRect in
                    ImageTranslationLineRect(
                        x: lineRect.minX,
                        y: lineRect.minY,
                        width: lineRect.width,
                        height: lineRect.height
                    )
                },
                textRects: region.textRects.map { textRect in
                    ImageTranslationLineRect(
                        x: textRect.minX,
                        y: textRect.minY,
                        width: textRect.width,
                        height: textRect.height
                    )
                },
                protectedRects: (
                    region.translationStrategy == .selective
                        ? region.protectedRects
                        : []
                ).map { protectedRect in
                    ImageTranslationLineRect(
                        x: protectedRect.minX,
                        y: protectedRect.minY,
                        width: protectedRect.width,
                        height: protectedRect.height
                    )
                },
                tokens: region.tokens.map { token in
                    ImageTranslationSourceToken(
                        text: token.text,
                        x: token.rect.minX,
                        y: token.rect.minY,
                        width: token.rect.width,
                        height: token.rect.height,
                        isProtected: token.isProtected
                    )
                },
                translationStrategy: region.translationStrategy,
                codeRects: region.codeRects.map { tokenRect in
                    ImageTranslationTokenRect(
                        text: tokenRect.text,
                        x: tokenRect.rect.minX,
                        y: tokenRect.rect.minY,
                        width: tokenRect.rect.width,
                        height: tokenRect.rect.height
                    )
                },
                kind: region.kind.rawValue,
                alignment: "left",
                weight: region.kind.prefersBoldText ? "semibold" : nil,
                fontSize: region.fontSize
            )
        }
    }

    private struct Fragment {
        let text: String
        let boundingBox: CGRect
        let textBoxes: [CGRect]
        let protectedBoxes: [CGRect]
        let tokens: [FragmentToken]
        let codeTokens: [CodeTokenFragment]
    }

    private struct FragmentToken {
        let text: String
        let boundingBox: CGRect
        let isProtected: Bool
    }

    private struct CodeTokenFragment {
        let text: String
        let boundingBox: CGRect
    }

    private struct RecognizedToken {
        let text: String
        let boundingBox: CGRect
        let range: Range<String.Index>?
    }

    private struct VisualLine {
        var fragments: [Fragment]

        var boundingBox: CGRect {
            fragments
                .map(\.boundingBox)
                .reduce(fragments[0].boundingBox) { $0.union($1) }
        }

        var text: String {
            fragments
                .sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                .map(\.text)
                .joined(separator: " ")
                .replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        mutating func append(_ fragment: Fragment) {
            fragments.append(fragment)
        }
    }

    private struct TextBlock {
        var lines: [VisualLine]

        var boundingBox: CGRect {
            lines
                .map(\.boundingBox)
                .reduce(lines[0].boundingBox) { $0.union($1) }
        }

        var text: String {
            lines
                .sorted { lhs, rhs in
                    if abs(lhs.boundingBox.midY - rhs.boundingBox.midY) > 0.01 {
                        return lhs.boundingBox.midY > rhs.boundingBox.midY
                    }
                    return lhs.boundingBox.minX < rhs.boundingBox.minX
                }
                .map(\.text)
                .joined(separator: " ")
                .replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        mutating func append(_ line: VisualLine) {
            lines.append(line)
        }
    }

    private struct SourceRegionCandidate {
        let text: String
        let rect: CGRect
        let lineRects: [CGRect]
        let textRects: [CGRect]
        let protectedRects: [CGRect]
        let tokens: [SourceOCRTokenCandidate]
        let translationStrategy: ImageTranslationStrategy
        let codeRects: [SourceTokenCandidate]
        let kind: TextBlockKind
        let fontSize: Double
    }

    private struct SourceTokenCandidate {
        let text: String
        let rect: CGRect
    }

    private struct SourceOCRTokenCandidate {
        let text: String
        let rect: CGRect
        let isProtected: Bool
    }

    enum TextBlockKind: String {
        case title
        case heading
        case paragraph
        case listItem = "list_item"
        case caption
        case code

        var prefersBoldText: Bool {
            switch self {
            case .title, .heading:
                return true
            case .paragraph, .listItem, .caption, .code:
                return false
            }
        }
    }

    private static func fragment(
        from observation: VNRecognizedTextObservation,
        bitmap: NSBitmapImageRep,
        preservedPhrases: [[String]]
    ) -> Fragment? {
        guard let recognizedText = observation.topCandidates(1).first else {
            return nil
        }

        let tokenization = recognizedTokens(in: recognizedText)
        let fallbackTokens = tokenization.tokens.isEmpty
            ? [RecognizedToken(
                text: recognizedText.string,
                boundingBox: observation.boundingBox,
                range: nil
            )]
            : tokenization.tokens
        let codeTokens = codeTokenFragments(
            in: recognizedText,
            lineBox: observation.boundingBox,
            bitmap: bitmap
        )
        let namedEntityIndexes = namedEntityTokenIndexes(
            in: recognizedText.string,
            tokens: fallbackTokens
        )
        var protectedIndexes = ImageTranslationSourcePolicy.protectedTokenIndexes(
            fallbackTokens.map(\.text),
            preservedPhrases: preservedPhrases,
            namedEntityIndexes: namedEntityIndexes
        )
        for (index, token) in fallbackTokens.enumerated() where codeTokens.contains(where: {
            $0.boundingBox.intersects(token.boundingBox)
        }) {
            protectedIndexes.insert(index)
        }

        let text = normalizedSourceText(fallbackTokens.map(\.text).joined(separator: " "))
        guard
            !text.isEmpty,
            !ImageTranslationSourcePolicy.isDecorativeFragment(text)
        else {
            return nil
        }
        if !ImageTranslationSourcePolicy.shouldTranslate(text) {
            protectedIndexes.formUnion(fallbackTokens.indices)
        }

        let boundingBox = fallbackTokens
            .dropFirst()
            .reduce(fallbackTokens[0].boundingBox) { partial, token in
                partial.union(token.boundingBox)
            }
        let fragmentTokens = fallbackTokens.enumerated().map { index, token in
            FragmentToken(
                text: token.text,
                boundingBox: token.boundingBox,
                isProtected: protectedIndexes.contains(index)
            )
        }

        return Fragment(
            text: text,
            boundingBox: boundingBox,
            textBoxes: fallbackTokens.map(\.boundingBox),
            protectedBoxes: tokenization.protectedBoxes
                + fragmentTokens.filter { $0.isProtected }.map(\.boundingBox),
            tokens: fragmentTokens,
            codeTokens: codeTokens
        )
    }

    private static func recognizedTokens(
        in recognizedText: VNRecognizedText
    ) -> (tokens: [RecognizedToken], protectedBoxes: [CGRect]) {
        var tokens: [RecognizedToken] = []
        var protectedBoxes: [CGRect] = []

        for rawRange in recognizedText.string.translationTokenRanges() {
            var range = rawRange
            while range.lowerBound < range.upperBound,
                  ImageTranslationSourcePolicy.isLeadingDecorativeCharacter(
                    recognizedText.string[range.lowerBound]
                  ) {
                range = recognizedText.string.index(after: range.lowerBound)..<range.upperBound
            }

            if rawRange.lowerBound < range.lowerBound {
                let protectedRange = rawRange.lowerBound..<range.lowerBound
                if let observation = try? recognizedText.boundingBox(for: protectedRange) {
                    let box = observation.boundingBox
                    if box.width > 0, box.height > 0 {
                        protectedBoxes.append(box)
                    }
                }
            }
            guard range.lowerBound < range.upperBound,
                  let observation = try? recognizedText.boundingBox(for: range)
            else {
                continue
            }

            let box = observation.boundingBox
            guard box.width > 0, box.height > 0 else {
                continue
            }
            tokens.append(RecognizedToken(
                text: String(recognizedText.string[range]),
                boundingBox: box,
                range: range
            ))
        }

        return (tokens, protectedBoxes)
    }

    private static func dynamicallyPreservedPhrases(
        from observations: [VNRecognizedTextObservation]
    ) -> [[String]] {
        var phrases: [[String]] = []

        for observation in observations {
            guard let recognizedText = observation.topCandidates(1).first else {
                continue
            }
            let tokenization = recognizedTokens(in: recognizedText)
            let tokens = tokenization.tokens
            guard !tokens.isEmpty else {
                continue
            }

            if let prefix = ImageTranslationSourcePolicy.identityPhraseBeforeSeparator(
                tokens.map(\.text)
            ) {
                phrases.append(prefix)
            }

            let entityIndexes = namedEntityTokenIndexes(
                in: recognizedText.string,
                tokens: tokens
            )
            var currentPhrase: [String] = []
            for (index, token) in tokens.enumerated() {
                if entityIndexes.contains(index) {
                    currentPhrase.append(token.text)
                } else if !currentPhrase.isEmpty {
                    phrases.append(currentPhrase)
                    currentPhrase = []
                }
            }
            if !currentPhrase.isEmpty {
                phrases.append(currentPhrase)
            }
        }

        var seen: Set<String> = []
        return phrases.filter { phrase in
            let key = phrase
                .map {
                    $0.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
                        .lowercased()
                }
                .filter { !$0.isEmpty }
                .joined(separator: "\u{1F}")
            guard !key.isEmpty, seen.insert(key).inserted else {
                return false
            }
            return true
        }
    }

    private static func namedEntityTokenIndexes(
        in text: String,
        tokens: [RecognizedToken]
    ) -> Set<Int> {
        guard !text.isEmpty else {
            return []
        }

        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let fullRange = text.startIndex..<text.endIndex
        tagger.setLanguage(.english, range: fullRange)
        var entityRanges: [Range<String.Index>] = []
        tagger.enumerateTags(
            in: fullRange,
            unit: .word,
            scheme: .nameType,
            options: [.omitWhitespace, .omitPunctuation, .joinNames]
        ) { tag, range in
            if let tag,
               tag == .personalName || tag == .organizationName || tag == .placeName {
                entityRanges.append(range)
            }
            return true
        }

        return Set(tokens.enumerated().compactMap { index, token in
            guard let tokenRange = token.range,
                  entityRanges.contains(where: { $0.overlaps(tokenRange) })
            else {
                return nil
            }
            return index
        })
    }

    private static func mergedVisualLines(from fragments: [Fragment]) -> [VisualLine] {
        let sorted = fragments.sorted { lhs, rhs in
            if abs(lhs.boundingBox.midY - rhs.boundingBox.midY) > 0.01 {
                return lhs.boundingBox.midY > rhs.boundingBox.midY
            }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }

        var lines: [VisualLine] = []
        for fragment in sorted {
            if let index = lines.firstIndex(where: { belongsToSameVisualLine(fragment, line: $0) }) {
                lines[index].append(fragment)
            } else {
                lines.append(VisualLine(fragments: [fragment]))
            }
        }

        return lines.map { line in
            VisualLine(fragments: line.fragments.sorted { $0.boundingBox.minX < $1.boundingBox.minX })
        }
    }

    private static func mergedTextBlocks(from lines: [VisualLine]) -> [TextBlock] {
        let sorted = lines.sorted { lhs, rhs in
            if abs(lhs.boundingBox.midY - rhs.boundingBox.midY) > 0.01 {
                return lhs.boundingBox.midY > rhs.boundingBox.midY
            }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }

        var blocks: [TextBlock] = []
        for line in sorted where shouldUseSourceText(line.text) {
            let lastLineRects = blocks.compactMap { $0.lines.last?.boundingBox }
            if let blockIndex = ImageTranslationReadingOrderLayout.closestCompatibleBlockIndex(
                for: line.boundingBox,
                lastLineRects: lastLineRects,
                isCompatible: { belongsToSameTextBlock(line, block: blocks[$0]) }
            ) {
                blocks[blockIndex].append(line)
            } else {
                blocks.append(TextBlock(lines: [line]))
            }
        }

        return blocks
    }

    private static func belongsToSameTextBlock(_ line: VisualLine, block: TextBlock) -> Bool {
        guard let previousLine = block.lines.last else {
            return false
        }

        let previousBox = previousLine.boundingBox
        let currentBox = line.boundingBox
        let maxLineHeight = max(previousBox.height, currentBox.height)
        let verticalGap = previousBox.minY - currentBox.maxY
        guard verticalGap > -maxLineHeight * 0.45, verticalGap < maxLineHeight * 1.85 else {
            return false
        }

        let currentIsBullet = isBulletLine(line.text)
        let blockIsBullet = isBulletLine(block.lines.first?.text ?? "")
        if currentIsBullet {
            return false
        }

        if blockIsBullet {
            let firstLineBox = block.lines.first?.boundingBox ?? block.boundingBox
            let continuationIndent = firstLineBox.minX + max(0.012, maxLineHeight * 0.28)
            let isIndentedContinuation = currentBox.minX >= continuationIndent
            let isWrappedContinuation = isIndentedContinuation || lineSuggestsContinuation(previousLine.text)
            return isWrappedContinuation
                && (isIndentedContinuation || !endsTextBlock(previousLine.text))
                && currentBox.minX <= block.boundingBox.maxX + 0.025
                && verticalGap < maxLineHeight * 1.35
        }

        if ImageTranslationReadingOrderLayout.isWrappedHeadingContinuation(
            previousRect: previousBox,
            candidateRect: currentBox,
            previousLooksLikeHeading: looksLikeStandaloneHeading(previousLine.text),
            candidateLooksLikeHeading: looksLikeStandaloneHeading(line.text)
        ) {
            return true
        }

        if looksLikeStandaloneHeading(line.text) {
            return false
        }

        let indentationDelta = abs(currentBox.minX - previousBox.minX)
        let isTightWrappedParagraphContinuation = ImageTranslationReadingOrderLayout
            .isTightWrappedParagraphContinuation(
                previousRect: previousBox,
                candidateRect: currentBox,
                blockRect: block.boundingBox
            )
        if endsTextBlock(previousLine.text), !isTightWrappedParagraphContinuation {
            return false
        }

        return indentationDelta < 0.035
            && verticalGap < maxLineHeight * 1.25
            && (
                isTightWrappedParagraphContinuation
                    || lineSuggestsContinuation(previousLine.text)
                    || !startsLikeNewSentence(line.text)
            )
    }

    private static func expandedSourceRegions(
        from blocks: [TextBlock],
        globalProtectedRects: [CGRect]
    ) -> [SourceRegionCandidate] {
        let allLineHeights = blocks
            .flatMap(\.lines)
            .map { topLeftRect(fromVisionBox: $0.boundingBox).height }
            .filter { $0 > 0 }
        let medianLineHeight = median(allLineHeights) ?? 0.018
        let baseRects = blocks.enumerated().map { index, block in
            expandedTextBlockRect(
                topLeftRect(fromVisionBox: block.boundingBox),
                kind: blockKind(for: block, index: index, medianLineHeight: medianLineHeight)
            )
        }

        return blocks.enumerated().compactMap { index, block -> SourceRegionCandidate? in
            let text = block.text
            guard shouldUseSourceText(text) else {
                return nil
            }

            let kind = blockKind(for: block, index: index, medianLineHeight: medianLineHeight)
            let rect = baseRects[index]
            guard rect.width > 0.01, rect.height > 0.008 else {
                return nil
            }

            let sourceLineHeight = median(
                block.lines.map { topLeftRect(fromVisionBox: $0.boundingBox).height }.filter { $0 > 0 }
            ) ?? medianLineHeight
            let lineRects = block.lines.map { line in
                expandedTextLineRect(
                    topLeftRect(fromVisionBox: line.boundingBox),
                    kind: kind
                )
            }
            let localProtectedRects = block.lines.flatMap { line in
                line.fragments.flatMap(\.protectedBoxes).map { protectedBox in
                    expandedProtectedTokenRect(topLeftRect(fromVisionBox: protectedBox))
                }
            }
            let nearbyProtectedRects = globalProtectedRects.filter { protectedRect in
                isProtectedRect(protectedRect, adjacentTo: lineRects)
            }
            let orderedTokens = orderedFragmentTokens(in: block)
            let protectedTokenIndexes = Set(
                orderedTokens.enumerated().compactMap { index, token in
                    token.isProtected ? index : nil
                }
            )
            let translationStrategy = ImageTranslationSourcePolicy.translationStrategy(
                tokenTexts: orderedTokens.map(\.text),
                protectedIndexes: protectedTokenIndexes,
                lineCount: block.lines.count
            )
            return SourceRegionCandidate(
                text: text,
                rect: rect,
                lineRects: lineRects,
                textRects: block.lines.flatMap { line in
                    line.fragments.flatMap { fragment in
                        let textBoxes = fragment.textBoxes.isEmpty
                            ? [fragment.boundingBox]
                            : fragment.textBoxes
                        return textBoxes.map { textBox in
                            expandedTextFragmentRect(topLeftRect(fromVisionBox: textBox))
                        }
                    }
                },
                protectedRects: deduplicatedRects(localProtectedRects + nearbyProtectedRects),
                tokens: orderedTokens.map { token in
                    SourceOCRTokenCandidate(
                        text: token.text,
                        rect: expandedTextFragmentRect(topLeftRect(fromVisionBox: token.boundingBox)),
                        isProtected: token.isProtected
                    )
                },
                translationStrategy: translationStrategy,
                codeRects: block.lines.flatMap { line in
                    line.fragments.flatMap { fragment in
                        fragment.codeTokens.map { token in
                            SourceTokenCandidate(
                                text: token.text,
                                rect: expandedCodeTokenRect(topLeftRect(fromVisionBox: token.boundingBox))
                            )
                        }
                    }
                },
                kind: kind,
                fontSize: fontSize(for: kind, sourceLineHeight: sourceLineHeight)
            )
        }
    }

    private static func orderedFragmentTokens(in block: TextBlock) -> [FragmentToken] {
        block.lines
            .sorted { lhs, rhs in
                if abs(lhs.boundingBox.midY - rhs.boundingBox.midY) > 0.01 {
                    return lhs.boundingBox.midY > rhs.boundingBox.midY
                }
                return lhs.boundingBox.minX < rhs.boundingBox.minX
            }
            .flatMap { line in
                line.fragments
                    .sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                    .flatMap(\.tokens)
            }
    }

    private static func isProtectedRect(_ protectedRect: CGRect, adjacentTo lineRects: [CGRect]) -> Bool {
        lineRects.contains { lineRect in
            let verticalOverlap = min(protectedRect.maxY, lineRect.maxY) - max(protectedRect.minY, lineRect.minY)
            let overlapRatio = max(0, verticalOverlap) / max(min(protectedRect.height, lineRect.height), 0.001)
            let horizontalGap = max(
                0,
                max(protectedRect.minX - lineRect.maxX, lineRect.minX - protectedRect.maxX)
            )
            return overlapRatio > 0.32
                && horizontalGap <= max(protectedRect.height, lineRect.height) * 1.8
        }
    }

    private static func deduplicatedRects(_ rects: [CGRect]) -> [CGRect] {
        var result: [CGRect] = []
        for rect in rects where !result.contains(where: {
            abs($0.minX - rect.minX) < 0.001
                && abs($0.minY - rect.minY) < 0.001
                && abs($0.width - rect.width) < 0.001
                && abs($0.height - rect.height) < 0.001
        }) {
            result.append(rect)
        }
        return result
    }

    private static func codeTokenFragments(
        in recognizedText: VNRecognizedText,
        lineBox: CGRect,
        bitmap: NSBitmapImageRep
    ) -> [CodeTokenFragment] {
        recognizedText.string.sourceTokenRanges().compactMap { range in
            let token = String(recognizedText.string[range])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: codeTrimCharacters)
            guard shouldPreserveCodeToken(token),
                  let observation = try? recognizedText.boundingBox(for: range)
            else {
                return nil
            }

            let box = observation.boundingBox
            guard box.width > 0, box.height > 0 else {
                return nil
            }
            let hasVisualCodeBackground = hasCodeLikeBackground(
                tokenBox: box,
                lineBox: lineBox,
                bitmap: bitmap
            )
            guard hasVisualCodeBackground || ImageTranslationCodeHeuristics.isStrongIdentifier(token)
            else {
                return nil
            }

            return CodeTokenFragment(text: token, boundingBox: box)
        }
    }

    private static func hasCodeLikeBackground(
        tokenBox: CGRect,
        lineBox: CGRect,
        bitmap: NSBitmapImageRep
    ) -> Bool {
        let horizontalPadding = max(0.002, tokenBox.height * 0.24)
        let verticalPadding = max(0.0012, tokenBox.height * 0.14)
        let chipBox = clampedUnitRect(
            tokenBox.insetBy(dx: -horizontalPadding, dy: -verticalPadding)
        )
        let backgroundGap = max(0.002, tokenBox.height * 0.30)
        let midY = tokenBox.midY
        let midX = tokenBox.midX

        let chipPoints = [
            CGPoint(x: max(chipBox.minX, tokenBox.minX - horizontalPadding * 0.55), y: midY),
            CGPoint(x: min(chipBox.maxX, tokenBox.maxX + horizontalPadding * 0.55), y: midY),
            CGPoint(x: midX, y: max(chipBox.minY, tokenBox.minY - verticalPadding * 0.55)),
            CGPoint(x: midX, y: min(chipBox.maxY, tokenBox.maxY + verticalPadding * 0.55))
        ]
        let backgroundPoints = [
            CGPoint(x: chipBox.minX - backgroundGap, y: midY),
            CGPoint(x: chipBox.maxX + backgroundGap, y: midY),
            CGPoint(x: midX, y: min(lineBox.maxY + backgroundGap, 1)),
            CGPoint(x: midX, y: max(lineBox.minY - backgroundGap, 0))
        ]

        guard
            let chipColor = averageColor(
                chipPoints.compactMap { sampledVisionColor(at: $0, bitmap: bitmap) }
            ),
            let backgroundColor = averageColor(
                backgroundPoints.compactMap { point in
                    guard point.x >= 0, point.x <= 1, point.y >= 0, point.y <= 1 else {
                        return nil
                    }
                    return sampledVisionColor(at: point, bitmap: bitmap)
                }
            )
        else {
            return false
        }

        return colorDistance(chipColor, backgroundColor) >= 0.045
            || abs(luminance(chipColor) - luminance(backgroundColor)) >= 0.030
    }

    private static func clampedUnitRect(_ rect: CGRect) -> CGRect {
        let minX = min(max(rect.minX, 0), 1)
        let minY = min(max(rect.minY, 0), 1)
        let maxX = min(max(rect.maxX, 0), 1)
        let maxY = min(max(rect.maxY, 0), 1)

        return CGRect(
            x: minX,
            y: minY,
            width: max(0, maxX - minX),
            height: max(0, maxY - minY)
        )
    }

    private static func sampledVisionColor(at point: CGPoint, bitmap: NSBitmapImageRep) -> NSColor? {
        let clampedX = min(max(point.x, 0), 1)
        let clampedY = min(max(point.y, 0), 1)
        let x = min(
            max(0, Int((clampedX * CGFloat(bitmap.pixelsWide - 1)).rounded())),
            bitmap.pixelsWide - 1
        )
        let y = min(
            max(0, Int(((1 - clampedY) * CGFloat(bitmap.pixelsHigh - 1)).rounded())),
            bitmap.pixelsHigh - 1
        )

        return bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
    }

    private static func averageColor(_ colors: [NSColor]) -> NSColor? {
        guard !colors.isEmpty else {
            return nil
        }

        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var count: CGFloat = 0

        for rawColor in colors {
            guard let color = rawColor.usingColorSpace(.sRGB) else {
                continue
            }

            red += color.redComponent
            green += color.greenComponent
            blue += color.blueComponent
            count += 1
        }

        guard count > 0 else {
            return nil
        }

        return NSColor(
            srgbRed: red / count,
            green: green / count,
            blue: blue / count,
            alpha: 1
        )
    }

    private static func colorDistance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        guard
            let lhs = lhs.usingColorSpace(.sRGB),
            let rhs = rhs.usingColorSpace(.sRGB)
        else {
            return 0
        }

        let redDelta = lhs.redComponent - rhs.redComponent
        let greenDelta = lhs.greenComponent - rhs.greenComponent
        let blueDelta = lhs.blueComponent - rhs.blueComponent

        return sqrt(redDelta * redDelta + greenDelta * greenDelta + blueDelta * blueDelta)
    }

    private static func luminance(_ color: NSColor) -> CGFloat {
        guard let color = color.usingColorSpace(.sRGB) else {
            return 0
        }

        return 0.2126 * color.redComponent
            + 0.7152 * color.greenComponent
            + 0.0722 * color.blueComponent
    }

    private static func blockKind(
        for block: TextBlock,
        index: Int,
        medianLineHeight: CGFloat
    ) -> TextBlockKind {
        let text = block.text
        let firstText = block.lines.first?.text ?? text
        if isBulletLine(firstText) {
            return .listItem
        }

        if isCodeOnlyLine(text) {
            return .code
        }

        let blockLineHeight = median(
            block.lines.map { topLeftRect(fromVisionBox: $0.boundingBox).height }.filter { $0 > 0 }
        ) ?? medianLineHeight
        if looksLikeStandaloneHeading(text) {
            if index == 0 || blockLineHeight > medianLineHeight * 1.28 {
                return .title
            }
            return .heading
        }

        if block.lines.count == 1,
           text.count <= 60,
           blockLineHeight < medianLineHeight * 0.82 {
            return .caption
        }

        return .paragraph
    }

    /// This value is normalized against the image height. A fixed upper bound
    /// makes text in wide, shallow crops several times smaller than its source;
    /// the renderer already constrains the result to the recognized line rect.
    static func fontSize(for kind: TextBlockKind, sourceLineHeight: CGFloat) -> Double {
        switch kind {
        case .title:
            let baseSize = sourceLineHeight * 0.82
            return Double(max(baseSize, 0.018))
        case .heading:
            let baseSize = sourceLineHeight * 0.82
            return Double(max(baseSize, 0.014))
        case .paragraph, .listItem:
            let baseSize = sourceLineHeight * 1.08
            return Double(max(baseSize, 0.010))
        case .caption:
            let baseSize = sourceLineHeight * 1.06
            return Double(max(baseSize, 0.008))
        case .code:
            let baseSize = sourceLineHeight * 0.82
            return Double(max(baseSize, 0.009))
        }
    }

    private static func belongsToSameVisualLine(_ fragment: Fragment, line: VisualLine) -> Bool {
        ImageTranslationReadingOrderLayout.belongsToSameVisualLine(
            fragment.boundingBox,
            lineRect: line.boundingBox
        )
    }

    private static func isBulletLine(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("•")
            || trimmed.hasPrefix("·")
            || trimmed.hasPrefix("- ")
            || trimmed.hasPrefix("* ")
    }

    private static func looksLikeStandaloneHeading(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 36 else {
            return false
        }

        return !isBulletLine(trimmed)
            && trimmed.range(of: #"[.!?。！？:,，]"#, options: .regularExpression) == nil
    }

    private static func endsTextBlock(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }

        if lineSuggestsContinuation(trimmed) {
            return false
        }

        return trimmed.range(of: #"[.!?。！？]$"#, options: .regularExpression) != nil
    }

    private static func lineSuggestsContinuation(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }

        if trimmed.range(of: #"[-,;:，；：]$"#, options: .regularExpression) != nil {
            return true
        }

        return trimmed.range(
            of: #"\b(and|or|with|without|to|into|from|when|while|that|which|for|of|in|as)\s*$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func startsLikeNewSentence(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else {
            return false
        }

        return first.isUppercase || isBulletLine(trimmed)
    }

    private static func normalizedSourceText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func shouldUseSourceText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ImageTranslationSourcePolicy.shouldTranslate(trimmed) else {
            return false
        }

        return !isCodeOnlyLine(trimmed)
    }

    private static func isCodeOnlyLine(_ line: String) -> Bool {
        let tokens = line
            .split(whereSeparator: \.isWhitespace)
            .map { String($0).trimmingCharacters(in: codeTrimCharacters) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else {
            return false
        }

        return tokens.allSatisfy { token in
            token.range(of: #"^[A-Za-z0-9_./:-]+$"#, options: .regularExpression) != nil
                && (
                    token.range(of: #"[a-z][A-Z]"#, options: .regularExpression) != nil
                    || token.range(of: #"^[A-Z0-9_]{2,}$"#, options: .regularExpression) != nil
                    || token.contains("_")
                    || token.contains(".")
                    || token.contains("/")
                )
        }
    }

    private static func shouldPreserveCodeToken(_ text: String) -> Bool {
        let token = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: codeTrimCharacters)
        guard token.count >= 3, token.range(of: #"^[A-Za-z_][A-Za-z0-9_./:-]*$"#, options: .regularExpression) != nil else {
            return false
        }

        if ImageTranslationCodeHeuristics.isStrongIdentifier(token) {
            return true
        }

        if token.range(of: #"[a-z][A-Z]"#, options: .regularExpression) != nil, token.count >= 8 {
            return true
        }

        return token.contains("_")
            || token.contains(".")
            || token.contains("/")
            || token.range(of: #"^[A-Z0-9_]{3,}$"#, options: .regularExpression) != nil
    }

    private static let codeTrimCharacters = CharacterSet(charactersIn: ".,;:!?()[]{}<>`\"'“”‘’")

    private static func topLeftRect(fromVisionBox box: CGRect) -> CGRect {
        let x = min(max(box.minX, 0), 1)
        let y = min(max(1 - box.maxY, 0), 1)
        let maxX = min(max(box.maxX, 0), 1)
        let maxY = min(max(1 - box.minY, 0), 1)

        return CGRect(
            x: x,
            y: y,
            width: max(0, maxX - x),
            height: max(0, maxY - y)
        )
    }

    private static func expandedTextBlockRect(_ rect: CGRect, kind: TextBlockKind) -> CGRect {
        let horizontalMultiplier: CGFloat
        let verticalMultiplier: CGFloat
        switch kind {
        case .title, .heading:
            horizontalMultiplier = 0.18
            verticalMultiplier = 0.22
        case .listItem:
            horizontalMultiplier = 0.14
            verticalMultiplier = 0.16
        case .caption, .code:
            horizontalMultiplier = 0.10
            verticalMultiplier = 0.12
        case .paragraph:
            horizontalMultiplier = 0.16
            verticalMultiplier = 0.16
        }

        let horizontalPadding = max(0.002, rect.height * horizontalMultiplier)
        let verticalPadding = max(0.0015, rect.height * verticalMultiplier)
        let minX = max(0, rect.minX - horizontalPadding)
        let minY = max(0, rect.minY - verticalPadding)
        let maxX = min(1, rect.maxX + horizontalPadding)
        let maxY = min(1, rect.maxY + verticalPadding)

        return CGRect(
            x: minX,
            y: minY,
            width: max(0, maxX - minX),
            height: max(0, maxY - minY)
        )
    }

    private static func expandedTextLineRect(_ rect: CGRect, kind: TextBlockKind) -> CGRect {
        let horizontalMultiplier: CGFloat
        let verticalMultiplier: CGFloat
        switch kind {
        case .title, .heading:
            horizontalMultiplier = 0.14
            verticalMultiplier = 0.18
        case .listItem:
            horizontalMultiplier = 0.10
            verticalMultiplier = 0.12
        case .caption, .code:
            horizontalMultiplier = 0.08
            verticalMultiplier = 0.10
        case .paragraph:
            horizontalMultiplier = 0.10
            verticalMultiplier = 0.12
        }

        let horizontalPadding = max(0.0015, rect.height * horizontalMultiplier)
        let verticalPadding = max(0.001, rect.height * verticalMultiplier)
        let minX = max(0, rect.minX - horizontalPadding)
        let minY = max(0, rect.minY - verticalPadding)
        let maxX = min(1, rect.maxX + horizontalPadding)
        let maxY = min(1, rect.maxY + verticalPadding)

        return CGRect(
            x: minX,
            y: minY,
            width: max(0, maxX - minX),
            height: max(0, maxY - minY)
        )
    }

    private static func expandedTextFragmentRect(_ rect: CGRect) -> CGRect {
        let horizontalPadding = max(0.001, rect.height * 0.08)
        let verticalPadding = max(0.0008, rect.height * 0.10)
        let minX = max(0, rect.minX - horizontalPadding)
        let minY = max(0, rect.minY - verticalPadding)
        let maxX = min(1, rect.maxX + horizontalPadding)
        let maxY = min(1, rect.maxY + verticalPadding)

        return CGRect(
            x: minX,
            y: minY,
            width: max(0, maxX - minX),
            height: max(0, maxY - minY)
        )
    }

    private static func expandedCodeTokenRect(_ rect: CGRect) -> CGRect {
        let horizontalPadding = max(0.0015, rect.height * 0.18)
        let verticalPadding = max(0.001, rect.height * 0.12)
        let minX = max(0, rect.minX - horizontalPadding)
        let minY = max(0, rect.minY - verticalPadding)
        let maxX = min(1, rect.maxX + horizontalPadding)
        let maxY = min(1, rect.maxY + verticalPadding)

        return CGRect(
            x: minX,
            y: minY,
            width: max(0, maxX - minX),
            height: max(0, maxY - minY)
        )
    }

    private static func expandedProtectedTokenRect(_ rect: CGRect) -> CGRect {
        let horizontalPadding = max(0.0015, rect.height * 0.20)
        let verticalPadding = max(0.001, rect.height * 0.16)
        let minX = max(0, rect.minX - horizontalPadding)
        let minY = max(0, rect.minY - verticalPadding)
        let maxX = min(1, rect.maxX + horizontalPadding)
        let maxY = min(1, rect.maxY + verticalPadding)

        return CGRect(
            x: minX,
            y: minY,
            width: max(0, maxX - minX),
            height: max(0, maxY - minY)
        )
    }

    private static func median(_ values: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty else {
            return nil
        }

        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}

private extension String {
    func nonWhitespaceRanges() -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var tokenStart: String.Index?
        var index = startIndex

        while index < endIndex {
            if self[index].isWhitespace {
                if let start = tokenStart {
                    ranges.append(start..<index)
                    tokenStart = nil
                }
            } else if tokenStart == nil {
                tokenStart = index
            }

            index = self.index(after: index)
        }

        if let start = tokenStart {
            ranges.append(start..<endIndex)
        }

        return ranges
    }

    func sourceTokenRanges() -> [Range<String.Index>] {
        guard let expression = try? NSRegularExpression(pattern: #"[A-Za-z_][A-Za-z0-9_./:-]*"#) else {
            return []
        }

        let fullRange = NSRange(startIndex..<endIndex, in: self)
        return expression.matches(in: self, range: fullRange).compactMap { match in
            Range(match.range, in: self)
        }
    }

    func translationTokenRanges() -> [Range<String.Index>] {
        guard let expression = try? NSRegularExpression(
            pattern: #"[\p{L}\p{M}\p{N}_]+(?:[./:][\p{L}\p{M}\p{N}_]+)*|[^\s]"#
        ) else {
            return nonWhitespaceRanges()
        }

        let fullRange = NSRange(startIndex..<endIndex, in: self)
        return expression.matches(in: self, range: fullRange).compactMap { match in
            Range(match.range, in: self)
        }
    }
}
