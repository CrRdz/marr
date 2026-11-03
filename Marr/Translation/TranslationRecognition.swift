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

        if index == 0, totalCount > 1, trimmed.count == 1,
           !["A", "a", "I"].contains(trimmed) {
            return true
        }

        if isStructuralSeparator(trimmed) || isIntrinsicIdentifier(trimmed) {
            return true
        }

        return totalCount == 1 && isDecorativeFragment(trimmed)
    }

    static func isLeadingDecorativeCharacter(_ character: Character) -> Bool {
        "•·●○◦▪▫‣⁃➢➤▶▷►▸›»→↗↘↙↖⇱⇲⤴①②③④⑤⑥⑦⑧⑨⑩".contains(character)
    }

    static func startsListItem(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return false }
        return "•·●○◦▪▫‣⁃➢➤▶▷►▸›»".contains(first)
            || trimmed.hasPrefix("> ")
            || trimmed.hasPrefix("- ")
            || trimmed.hasPrefix("* ")
            || numberedListMarkerRange(in: trimmed) != nil
    }

    static func numberedListMarkerRange(in text: String) -> Range<String.Index>? {
        // Hierarchical question/section numbers establish a block boundary;
        // they are not decimal values embedded in the translated sentence.
        // Require a sentence opening after a bare dotted number so ordinary
        // quantities such as "1.5 times faster" keep flowing as prose.
        text.range(of: #"^\s*(?:\d{1,3}[.)-]\s+|\d{1,3}(?:\.\d{1,3})+[.)]?\s+(?=[\"“‘']?[A-Z]))"#,
                   options: .regularExpression)
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

        // NLTagger can mistake title-case technical phrases for a person's
        // name. A protected prefix alone must not freeze most of a heading.
        // Without an explicit identity separator, require an actual account,
        // acronym or code identifier before choosing selective translation.
        let prefix = tokenTexts.prefix(firstTranslatableIndex)
        let hasProtectedPrefix = firstTranslatableIndex >= 2
            && (0..<firstTranslatableIndex).allSatisfy { protectedIndexes.contains($0) }
            && prefix.contains(where: isIntrinsicIdentifier)
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

    /// A bilingual organization lockup is artwork. Require both an identity
    /// phrase and a nearby target-language counterpart, rather than freezing
    /// arbitrary title-case headings identified as organizations by NLTagger.
    static func isBilingualOrganizationIdentity(
        _ text: String,
        rect: CGRect,
        targetLanguageRects: [CGRect]
    ) -> Bool {
        guard isOrganizationIdentityCandidate(text, rect: rect) else { return false }
        return targetLanguageRects.contains { counterpart in
            let overlap = min(rect.maxX, counterpart.maxX) - max(rect.minX, counterpart.minX)
            let minimumWidth = min(rect.width, counterpart.width)
            let gap = counterpart.minY - rect.maxY
            return minimumWidth > 0 && overlap / minimumWidth >= 0.70
                && counterpart.width >= rect.width * 0.45
                && counterpart.width <= rect.width * 2.0
                && gap >= -rect.height * 0.3
                && gap <= max(0.035, rect.height * 1.5)
        }
    }

    static func isOrganizationIdentityCandidate(_ text: String, rect: CGRect) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace).map {
            $0.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
        }.filter { !$0.isEmpty }
        let organizationWords: Set<String> = [
            "university", "institute", "college", "school", "foundation",
            "association", "corporation", "company", "laboratory", "laboratories",
            "centre", "center", "inc", "ltd"
        ]
        let connectors: Set<String> = ["of", "the", "and", "for", "de", "van", "von"]
        return (2...12).contains(words.count)
            && words.contains(where: { organizationWords.contains($0.lowercased()) })
            && words.allSatisfy({ connectors.contains($0.lowercased()) || $0.first?.isUppercase == true })
            && rect.minY < 0.30 && rect.height < 0.10 && rect.width >= 0.10
            && !startsListItem(text)
    }

    private static func isIntrinsicIdentifier(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
        guard trimmed.count >= 2, !isOrdinaryProseToken(trimmed) else {
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

    static func isOrdinaryProseToken(_ token: String) -> Bool {
        let normalized = token.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
        // OCR often joins a document reference to its number. A dotted
        // section range is prose, not a member access or a code identifier.
        if normalized.range(of: #"^(?:subtasks?|tasks?|sections?|chapters?|figures?|tables?|equations?|problems?|questions?|exercises?|lectures?)\d+(?:\.\d+)*(?:[-–—]\d+(?:\.\d+)*)?$"#,
                            options: [.regularExpression, .caseInsensitive]) != nil { return true }
        if ["e.g", "i.e", "w.r.t", "etc", "vs", "viz", "cf"].contains(normalized.lowercased()) {
            return true
        }
        // A slash between two ordinary words is prose, even in title case.
        // Acronyms, file extensions, underscores and multi-level paths still
        // retain the stronger identifier evidence used below.
        return normalized.range(
            of: #"^(?:[a-z]{2,}|[A-Z][a-z]+)/(?:(?:[a-z]{2,})|(?:[A-Z][a-z]+))$"#,
            options: .regularExpression
        ) != nil
    }

    static func isSupplementaryMathObservation(_ text: String) -> Bool {
        guard text.count <= 160,
              text.contains(where: { "<>=≤≥≠≈→←↔⇒⇔+−-×÷∑∏∫∂∇".contains($0) }) else { return false }
        let operands = text.components(separatedBy: CharacterSet.letters.union(.decimalDigits).inverted)
            .filter { !$0.isEmpty }
        guard operands.count >= 2 else { return false }
        // Fast OCR commonly reads an arrow as '&', or loses a summation sign.
        // Require variable/numeric operands as well as a real relation/operator;
        // ordinary hyphenated words, sentences and decorative rules cannot seed.
        let proseWords: Set<String> = [
            "am", "an", "as", "at", "be", "by", "do", "go", "he", "if", "in", "is",
            "it", "me", "my", "no", "of", "on", "or", "so", "to", "up", "us", "we"
        ]
        return operands.allSatisfy { operand in
            !proseWords.contains(operand.lowercased()) && operand.range(
                of: #"^(?:[A-Za-zα-ωΑ-Ω]|[dD][A-Za-z]|[wxyzvtbα-ω]{2,3}|[A-Za-z][0-9]{1,2}|[0-9]+)$"#,
                options: .regularExpression
            ) != nil
        }
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
        // Token bounding boxes and named-entity tagging are needed both for
        // global phrase preservation and for fragments. Compute them once.
        var rawObservations = request.results ?? []
        // The accurate recognizer can omit an entire prose row when it shares
        // a baseline with a large formula. A cheap second detector supplements
        // only uncovered English prose; it never replaces accurate text.
        let supplementary = VNRecognizeTextRequest()
        supplementary.recognitionLevel = .fast
        supplementary.usesLanguageCorrection = false
        supplementary.recognitionLanguages = ["en-US"]
        supplementary.minimumTextHeight = request.minimumTextHeight
        var supplementaryMath: [VNRecognizedTextObservation] = []
        if (try? handler.perform([supplementary])) != nil {
            let uncovered = (supplementary.results ?? []).filter { candidate in
                let box = candidate.boundingBox
                return !rawObservations.contains { existing in
                    let intersection = box.intersection(existing.boundingBox)
                    return !intersection.isNull
                        && intersection.width * intersection.height / max(0.000001, box.width * box.height) > 0.30
                }
            }
            rawObservations += uncovered.filter { candidate in
                guard let text = candidate.topCandidates(1).first?.string else { return false }
                return text.split(whereSeparator: \.isWhitespace).filter { word in
                    word.count >= 3 && word.allSatisfy(\.isLetter)
                }.count >= 3
            }
            supplementaryMath = uncovered.filter { candidate in
                guard let text = candidate.topCandidates(1).first?.string else { return false }
                return ImageTranslationSourcePolicy.isSupplementaryMathObservation(text)
            }
        }
        let observations = rawObservations.compactMap(prepareObservation)
        let preservedPhrases = dynamicallyPreservedPhrases(from: observations)
        var targetLanguageRects = observations.compactMap { observation -> CGRect? in
            containsHan(observation.recognizedText.string)
                ? topLeftRect(fromVisionBox: observation.boundingBox) : nil
        }
        // English-first recognition can omit stylized Chinese logo text on an
        // otherwise English page. Verify only plausible organization lockups
        // with a small Chinese-first crop; do not run another full-page OCR or
        // add its observations to the translatable text stream.
        let identityCandidates = observations.filter { observation in
            ImageTranslationSourcePolicy.isOrganizationIdentityCandidate(
                observation.recognizedText.string,
                rect: topLeftRect(fromVisionBox: observation.boundingBox)
            )
        }
        for observation in identityCandidates.prefix(4) {
            let text = observation.recognizedText.string
            let rect = topLeftRect(fromVisionBox: observation.boundingBox)
            guard !ImageTranslationSourcePolicy.isBilingualOrganizationIdentity(
                    text, rect: rect, targetLanguageRects: targetLanguageRects
                  ) else { continue }
            try Task.checkCancellation()
            let inset = max(0.015, rect.width * 0.10)
            let top = max(0, rect.maxY - rect.height * 0.2)
            let roi = clampedUnitRect(CGRect(
                x: rect.minX - inset, y: top, width: rect.width + inset * 2,
                height: max(0.08, rect.height * 4)
            ))
            let local = VNRecognizeTextRequest()
            local.recognitionLevel = .accurate
            local.usesLanguageCorrection = true
            local.recognitionLanguages = ["zh-Hans", "en-US"]
            local.minimumTextHeight = 0.006
            local.regionOfInterest = CGRect(x: roi.minX, y: 1 - roi.maxY, width: roi.width, height: roi.height)
            if (try? handler.perform([local])) != nil {
                targetLanguageRects += (local.results ?? []).compactMap { result in
                    guard let candidate = result.topCandidates(1).first,
                          containsHan(candidate.string) else { return nil }
                    return fullImageRect(fromVisionBox: result.boundingBox, withinTopLeftROI: roi)
                }
            }
        }
        let fragments = observations.compactMap { observation -> Fragment? in
            if ImageTranslationSourcePolicy.isBilingualOrganizationIdentity(
                observation.recognizedText.string,
                rect: topLeftRect(fromVisionBox: observation.boundingBox),
                targetLanguageRects: targetLanguageRects
            ) { return nil }
            if observation.recognizedText.string.trimmingCharacters(in: .whitespaces) == "for",
               observations.contains(where: { other in
                   let a = observation.boundingBox, b = other.boundingBox
                   return other.recognizedText.string.hasPrefix("in range")
                       && abs(a.midY - b.midY) < max(a.height, b.height) * 0.4
                       && b.minX >= a.maxX && b.minX - a.maxX < a.height * 2
               }) { return nil }
            return fragment(
                from: observation,
                bitmap: bitmap,
                preservedPhrases: preservedPhrases
            )
        }
        let imageAspectRatio = CGFloat(cgImage.width) / CGFloat(cgImage.height)
        let protectedRects = fragments
            .flatMap(\.protectedBoxes)
            .map {
                expandedProtectedTokenRect(topLeftRect(fromVisionBox: $0), imageAspectRatio: imageAspectRatio)
            }
        let lines = mergedVisualLines(from: fragments, imageAspectRatio: imageAspectRatio)
        let textBlocks = mergedTextBlocks(from: lines, imageAspectRatio: imageAspectRatio, bitmap: bitmap)
        let regions = expandedSourceRegions(
            from: textBlocks,
            globalProtectedRects: protectedRects,
            imageAspectRatio: imageAspectRatio,
            imageSize: CGSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        )

        let sourceRegions = regions.enumerated().map { index, region in
            ImageTranslationSourceRegion(
                id: String(format: "r%03d", index + 1),
                sourceText: region.text,
                x: region.rect.minX,
                y: region.rect.minY,
                width: region.rect.width,
                height: region.rect.height,
                imageAspectRatio: Double(imageAspectRatio),
                lineRects: region.lineRects.map { lineRect in
                    ImageTranslationLineRect(
                        x: lineRect.minX,
                        y: lineRect.minY,
                        width: lineRect.width,
                        height: lineRect.height
                    )
                },
                preservesListMarker: region.preservesListMarker,
                listMarkerRects: region.listMarkerRects.map {
                    ImageTranslationLineRect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height)
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
                alignment: region.alignment,
                weight: region.kind.prefersBoldText ? "semibold" : nil,
                fontSize: region.fontSize
            )
        }
        let mathObservations = observations.map { observation in
            mathObservation(text: observation.recognizedText.string,
                            boundingBox: observation.boundingBox, tokens: observation.rawTokens)
        } + supplementaryMath.compactMap { observation -> ImageTranslationMathObservation? in
            guard let text = observation.topCandidates(1).first else { return nil }
            // These observations supply protection geometry only. They never
            // enter fragments, source region IDs or the translation request.
            return mathObservation(
                text: text.string, boundingBox: observation.boundingBox,
                tokens: recognizedTokens(in: text).rawTokens
            )
        }
        let protectedRegions = ImageTranslationMathProtection.protect(
            sourceRegions,
            observations: mathObservations,
            imageSize: CGSize(width: cgImage.width, height: cgImage.height),
            cgImage: cgImage
        )
        return protectedRegions.map { region in
            // Formula protection can convert an ordinary paragraph into fixed
            // selective slots after alignment inference. Those slots must
            // retain their leading anchors around the preserved source pixels.
            guard region.translationStrategy == .selective, region.alignment != "left" else { return region }
            return ImageTranslationSourceRegion(
                id: region.id, sourceText: region.sourceText,
                x: region.x, y: region.y, width: region.width, height: region.height,
                imageAspectRatio: region.imageAspectRatio, lineRects: region.lineRects,
                preservesListMarker: region.preservesListMarker, listMarkerRects: region.listMarkerRects, textRects: region.textRects,
                protectedRects: region.protectedRects, tokens: region.tokens,
                translationStrategy: region.translationStrategy, codeRects: region.codeRects,
                kind: region.kind, textColor: region.textColor, backgroundColor: region.backgroundColor,
                alignment: "left", weight: region.weight, fontSize: region.fontSize)
        }
    }

    private static func mathObservation(
        text: String, boundingBox: CGRect, tokens: [RecognizedToken]
    ) -> ImageTranslationMathObservation {
        let box = topLeftRect(fromVisionBox: boundingBox)
        return ImageTranslationMathObservation(
            text: text,
            rect: ImageTranslationLineRect(x: box.minX, y: box.minY, width: box.width, height: box.height),
            tokens: tokens.map { token in
                let box = topLeftRect(fromVisionBox: token.boundingBox)
                return ImageTranslationTokenRect(
                    text: token.text, x: box.minX, y: box.minY, width: box.width, height: box.height
                )
            }
        )
    }

    private struct Fragment {
        let text: String
        let isListItemStart: Bool
        let hasNumberedListMarker: Bool
        let listMarkerBoxes: [CGRect]
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

    private struct PreparedObservation {
        let recognizedText: VNRecognizedText
        let boundingBox: CGRect
        let tokens: [RecognizedToken]
        let rawTokens: [RecognizedToken]
        let protectedBoxes: [CGRect]
        let namedEntityIndexes: Set<Int>
    }

    private struct VisualLine {
        var fragments: [Fragment]

        var isListItemStart: Bool {
            fragments.contains(where: \.isListItemStart)
        }

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
                    ImageTranslationReadingOrderLayout.precedesInReadingOrder(
                        lhs.boundingBox, rhs.boundingBox
                    )
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
        let preservesListMarker: Bool
        let listMarkerRects: [CGRect]
        let textRects: [CGRect]
        let protectedRects: [CGRect]
        let tokens: [SourceOCRTokenCandidate]
        let translationStrategy: ImageTranslationStrategy
        let codeRects: [SourceTokenCandidate]
        let kind: TextBlockKind
        let alignment: String
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

    private static func prepareObservation(
        _ observation: VNRecognizedTextObservation
    ) -> PreparedObservation? {
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
        return PreparedObservation(
            recognizedText: recognizedText,
            boundingBox: observation.boundingBox,
            tokens: fallbackTokens,
            rawTokens: tokenization.rawTokens.isEmpty ? fallbackTokens : tokenization.rawTokens,
            protectedBoxes: tokenization.protectedBoxes,
            namedEntityIndexes: namedEntityTokenIndexes(
                in: recognizedText.string,
                tokens: fallbackTokens
            )
        )
    }

    private static func fragment(
        from observation: PreparedObservation,
        bitmap: NSBitmapImageRep,
        preservedPhrases: [[String]]
    ) -> Fragment? {
        let fallbackTokens = observation.tokens
        let codeTokens = codeTokenFragments(
            in: observation.recognizedText,
            lineBox: observation.boundingBox,
            bitmap: bitmap
        )
        var protectedIndexes = ImageTranslationSourcePolicy.protectedTokenIndexes(
            fallbackTokens.map(\.text),
            preservedPhrases: preservedPhrases,
            namedEntityIndexes: observation.namedEntityIndexes
        )
        for (index, token) in fallbackTokens.enumerated() where codeTokens.contains(where: {
            $0.boundingBox.intersects(token.boundingBox)
        }) {
            protectedIndexes.insert(index)
        }

        // Keep the recognized spacing and punctuation. Joining translation
        // tokens with spaces turns contractions into "we ' re" and inserts
        // gaps before every comma/period. Only the leading marker is omitted.
        let recognizedString = observation.recognizedText.string
        let textStart = fallbackTokens.first?.range?.lowerBound ?? recognizedString.startIndex
        let textEnd = fallbackTokens.last?.range?.upperBound ?? recognizedString.endIndex
        let text = normalizedSourceText(String(recognizedString[textStart..<textEnd]))
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
            isListItemStart: ImageTranslationSourcePolicy.startsListItem(observation.recognizedText.string),
            hasNumberedListMarker: ImageTranslationSourcePolicy.numberedListMarkerRange(
                in: observation.recognizedText.string) != nil,
            listMarkerBoxes: ImageTranslationSourcePolicy.startsListItem(observation.recognizedText.string)
                ? observation.protectedBoxes : [],
            boundingBox: boundingBox,
            textBoxes: fallbackTokens.map(\.boundingBox),
            protectedBoxes: observation.protectedBoxes
                + fragmentTokens.filter { $0.isProtected }.map(\.boundingBox),
            tokens: fragmentTokens,
            codeTokens: codeTokens
        )
    }

    private static func recognizedTokens(
        in recognizedText: VNRecognizedText
    ) -> (tokens: [RecognizedToken], protectedBoxes: [CGRect], rawTokens: [RecognizedToken]) {
        var tokens: [RecognizedToken] = []
        var protectedBoxes: [CGRect] = []
        var rawTokens: [RecognizedToken] = []

        let hasLeadingListMarker = ImageTranslationSourcePolicy.startsListItem(recognizedText.string)
        let numberedMarkerEnd = ImageTranslationSourcePolicy.numberedListMarkerRange(
            in: recognizedText.string)?.upperBound
        for (tokenIndex, rawRange) in recognizedText.string.translationTokenRanges().enumerated() {
            guard let rawObservation = try? recognizedText.boundingBox(for: rawRange) else { continue }
            let rawBox = rawObservation.boundingBox
            guard rawBox.width > 0, rawBox.height > 0 else { continue }
            rawTokens.append(RecognizedToken(
                text: String(recognizedText.string[rawRange]), boundingBox: rawBox, range: rawRange
            ))
            if let numberedMarkerEnd, rawRange.upperBound <= numberedMarkerEnd {
                protectedBoxes.append(rawBox)
                continue
            }
            var range = rawRange
            while range.lowerBound < range.upperBound,
                  (ImageTranslationSourcePolicy.isLeadingDecorativeCharacter(
                    recognizedText.string[range.lowerBound]
                  ) || (tokenIndex == 0 && hasLeadingListMarker && recognizedText.string[range.lowerBound] == ">")) {
                range = recognizedText.string.index(after: range.lowerBound)..<range.upperBound
            }

            if rawRange.lowerBound < range.lowerBound {
                let protectedRange = rawRange.lowerBound..<range.lowerBound
                if let box = protectedRange == rawRange
                    ? rawBox : (try? recognizedText.boundingBox(for: protectedRange))?.boundingBox {
                    if box.width > 0, box.height > 0 {
                        protectedBoxes.append(box)
                    }
                }
            }
            guard range.lowerBound < range.upperBound,
                  let box = range == rawRange
                    ? rawBox : (try? recognizedText.boundingBox(for: range))?.boundingBox
            else {
                continue
            }

            guard box.width > 0, box.height > 0 else {
                continue
            }
            tokens.append(RecognizedToken(
                text: String(recognizedText.string[range]),
                boundingBox: box,
                range: range
            ))
        }

        return (tokens, protectedBoxes, rawTokens)
    }

    private static func dynamicallyPreservedPhrases(
        from observations: [PreparedObservation]
    ) -> [[String]] {
        var phrases: [[String]] = []

        for observation in observations {
            let tokens = observation.tokens
            guard !tokens.isEmpty else {
                continue
            }

            if let prefix = ImageTranslationSourcePolicy.identityPhraseBeforeSeparator(
                tokens.map(\.text)
            ) {
                phrases.append(prefix)
            }

            let entityIndexes = observation.namedEntityIndexes
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
               tag == .personalName {
                // Name tagging frequently labels title-case technical headings
                // ("Linear Regression - Loss") as organizations. Freeze only
                // personal names; organizations/places can have valid Chinese
                // translations and remain visible in the model's source text.
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

    private static func mergedVisualLines(
        from fragments: [Fragment],
        imageAspectRatio: CGFloat
    ) -> [VisualLine] {
        ImageTranslationReadingOrderLayout.visualLineGroups(
            for: fragments.map(\.boundingBox),
            imageAspectRatio: imageAspectRatio,
            listItemStarts: Set(fragments.indices.filter { fragments[$0].isListItemStart })
        ).map { indexes in
            VisualLine(fragments: indexes.map { fragments[$0] })
        }
    }

    private static func mergedTextBlocks(
        from lines: [VisualLine],
        imageAspectRatio: CGFloat,
        bitmap: NSBitmapImageRep
    ) -> [TextBlock] {
        let sorted = lines.sorted { lhs, rhs in
            ImageTranslationReadingOrderLayout.precedesInReadingOrder(
                lhs.boundingBox, rhs.boundingBox
            )
        }

        var blocks: [TextBlock] = []
        for line in sorted where shouldUseSourceText(line.text) {
            let lastLineRects = blocks.compactMap { $0.lines.last?.boundingBox }
            if let blockIndex = ImageTranslationReadingOrderLayout.closestCompatibleBlockIndex(
                for: line.boundingBox,
                lastLineRects: lastLineRects,
                isCompatible: {
                    belongsToSameTextBlock(
                        line, block: blocks[$0], imageAspectRatio: imageAspectRatio,
                        bitmap: bitmap
                    )
                }
            ) {
                blocks[blockIndex].append(line)
            } else {
                blocks.append(TextBlock(lines: [line]))
            }
        }

        return blocks
    }

    private static func belongsToSameTextBlock(
        _ line: VisualLine,
        block: TextBlock,
        imageAspectRatio: CGFloat,
        bitmap: NSBitmapImageRep
    ) -> Bool {
        guard let previousLine = block.lines.last else {
            return false
        }

        let previousBox = previousLine.boundingBox
        let currentBox = line.boundingBox
        guard ImageTranslationReadingOrderLayout.canContinueTextColumn(
            previousRect: previousBox, candidateRect: currentBox
        ) else {
            return false
        }
        let maxLineHeight = max(previousBox.height, currentBox.height)
        let verticalGap = previousBox.minY - currentBox.maxY
        guard verticalGap > -maxLineHeight * 0.45, verticalGap < maxLineHeight * 1.85 else {
            return false
        }
        if hasHorizontalSeparator(between: previousBox, and: currentBox, bitmap: bitmap) {
            return false
        }

        // Marker glyphs are excluded from replacement tokens so the original
        // bullet stays visible. Keep their structural role as OCR metadata.
        let currentIsBullet = line.isListItemStart
        let blockIsBullet = block.lines.first?.isListItemStart == true
        if currentIsBullet {
            return false
        }

        if blockIsBullet {
            let firstLineBox = block.lines.first?.boundingBox ?? block.boundingBox
            let continuationIndent = firstLineBox.minX
                + max(0.012, maxLineHeight * 0.28 / imageAspectRatio)
            let indent = currentBox.minX - firstLineBox.minX
            // A caption far inside a diagram is not a wrapped bullet row.
            guard indent <= maxLineHeight * 1.8 / imageAspectRatio else { return false }
            let isIndentedContinuation = currentBox.minX >= continuationIndent
            let hasSameTextIndent = abs(currentBox.minX - firstLineBox.minX)
                <= maxLineHeight * 0.4 / imageAspectRatio
            // Numbered questions often contain several sentences with the
            // same hanging indent. A full stop ends a sentence, not the item;
            // the next numbered row (handled above) establishes that boundary.
            let continuesNumberedItem = hasSameTextIndent
                && block.lines.first?.fragments.contains(where: \.hasNumberedListMarker) == true
            let isWrappedContinuation = isIndentedContinuation
                || hasSameTextIndent
                || lineSuggestsContinuation(previousLine.text)
            return isWrappedContinuation
                && (isIndentedContinuation || continuesNumberedItem || !endsTextBlock(previousLine.text))
                && currentBox.minX <= block.boundingBox.maxX + 0.025
                && verticalGap < maxLineHeight * 1.35
        }

        if ImageTranslationReadingOrderLayout.isWrappedHeadingContinuation(
            previousRect: previousBox,
            candidateRect: currentBox,
            previousLooksLikeHeading: looksLikeStandaloneHeading(previousLine.text),
            candidateLooksLikeHeading: looksLikeStandaloneHeading(line.text),
            imageAspectRatio: imageAspectRatio
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
                blockRect: block.boundingBox,
                imageAspectRatio: imageAspectRatio
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

    private static func hasHorizontalSeparator(
        between upper: CGRect, and lower: CGRect, bitmap: NSBitmapImageRep
    ) -> Bool {
        let top = Int(ceil((1 - upper.minY) * CGFloat(bitmap.pixelsHigh)))
        let bottom = Int(floor((1 - lower.maxY) * CGFloat(bitmap.pixelsHigh)))
        let left = max(0, Int(min(upper.minX, lower.minX) * CGFloat(bitmap.pixelsWide)))
        let right = min(bitmap.pixelsWide, Int(max(upper.maxX, lower.maxX) * CGFloat(bitmap.pixelsWide)))
        guard top >= 0, bottom <= bitmap.pixelsHigh, bottom > top, right - left >= 100 else { return false }
        // A sparse dotted rule still occupies many columns on a single row.
        // Inspect only the gap, never the title or prose glyphs themselves.
        for y in top..<bottom {
            var ink = 0
            var samples = 0
            for x in stride(from: left, to: right, by: 2) {
                samples += 1
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if max(color.redComponent, color.greenComponent, color.blueComponent) < 0.7 { ink += 1 }
            }
            if ink > max(12, samples / 8) { return true }
        }
        return false
    }

    private static func expandedSourceRegions(
        from blocks: [TextBlock],
        globalProtectedRects: [CGRect],
        imageAspectRatio: CGFloat,
        imageSize: CGSize
    ) -> [SourceRegionCandidate] {
        let allLineHeights = blocks
            .flatMap(\.lines)
            .map { topLeftRect(fromVisionBox: $0.boundingBox).height }
            .filter { $0 > 0 }
        let medianLineHeight = median(allLineHeights) ?? 0.018
        let sourceLineHeights = blocks.map { block in
            median(block.lines.map(\.boundingBox.height).filter { $0 > 0 }) ?? medianLineHeight
        }
        let baseRects = blocks.enumerated().map { index, block in
            expandedTextBlockRect(
                topLeftRect(fromVisionBox: block.boundingBox),
                kind: blockKind(for: block, index: index, medianLineHeight: medianLineHeight),
                sourceLineHeight: sourceLineHeights[index],
                imageAspectRatio: imageAspectRatio
            )
        }
        let centeredIndexes = centeredTextBlockIndexes(
            rects: blocks.map { topLeftRect(fromVisionBox: $0.boundingBox) },
            lineCounts: blocks.map { $0.lines.count },
            excludedIndexes: Set(blocks.indices.filter {
                blocks[$0].lines.first?.isListItemStart == true || isCodeOnlyLine(blocks[$0].text)
            })
        )

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

            let sourceLineHeight = sourceLineHeights[index]
            let lineRects = block.lines.map { line in
                expandedTextLineRect(
                    topLeftRect(fromVisionBox: line.boundingBox),
                    kind: kind,
                    imageAspectRatio: imageAspectRatio
                )
            }
            let localProtectedRects = block.lines.flatMap { line in
                line.fragments.flatMap(\.protectedBoxes).map { protectedBox in
                    expandedProtectedTokenRect(
                        topLeftRect(fromVisionBox: protectedBox), imageAspectRatio: imageAspectRatio
                    )
                }
            }
            let nearbyProtectedRects = globalProtectedRects.filter { protectedRect in
                isProtectedRect(protectedRect, adjacentTo: lineRects, imageAspectRatio: imageAspectRatio)
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
            let supportsAlignmentInference = translationStrategy == .block
                && !block.lines.contains(where: \.isListItemStart)
                && !block.lines.flatMap(\.fragments).contains(where: { !$0.codeTokens.isEmpty })
                && !isCodeOnlyLine(block.text)
            let alignment = supportsAlignmentInference
                ? (centeredIndexes.contains(index) ? "center" : multilineTextAlignment(
                    lineRects: block.lines.map { topLeftRect(fromVisionBox: $0.boundingBox) },
                    imageAspectRatio: imageAspectRatio))
                : "left"
            return SourceRegionCandidate(
                text: text,
                rect: rect,
                lineRects: lineRects,
                preservesListMarker: block.lines.first?.isListItemStart == true,
                listMarkerRects: block.lines.flatMap(\.fragments).flatMap { fragment in
                    fragment.listMarkerBoxes.map { box in
                        // Keep just the marker and its antialiasing fringe;
                        // the larger prose padding must never erase its tail.
                        let marker = topLeftRect(fromVisionBox: box)
                        let textStart = topLeftRect(fromVisionBox: fragment.boundingBox).minX
                        let padX = 1.5 / imageSize.width
                        let padY = 1.5 / imageSize.height
                        let left = max(0, marker.minX - padX)
                        let right = min(textStart - 0.5 / imageSize.width, marker.maxX + padX)
                        return CGRect(x: left, y: max(0, marker.minY - padY),
                                      width: max(0, right - left), height: marker.height + padY * 2)
                    }.filter { $0.width > 0 }
                },
                textRects: block.lines.flatMap { line in
                    line.fragments.flatMap { fragment in
                        let textBoxes = fragment.textBoxes.isEmpty
                            ? [fragment.boundingBox]
                            : fragment.textBoxes
                        return textBoxes.map { textBox in
                            expandedTextFragmentRect(
                                topLeftRect(fromVisionBox: textBox), imageAspectRatio: imageAspectRatio
                            )
                        }
                    }
                },
                protectedRects: deduplicatedRects(localProtectedRects + nearbyProtectedRects),
                tokens: orderedTokens.map { token in
                    SourceOCRTokenCandidate(
                        text: token.text,
                        rect: expandedTextFragmentRect(
                            topLeftRect(fromVisionBox: token.boundingBox), imageAspectRatio: imageAspectRatio
                        ),
                        isProtected: token.isProtected
                    )
                },
                translationStrategy: translationStrategy,
                codeRects: block.lines.flatMap { line in
                    line.fragments.flatMap { fragment in
                        fragment.codeTokens.map { token in
                            SourceTokenCandidate(
                                text: token.text,
                                rect: expandedCodeTokenRect(
                                    topLeftRect(fromVisionBox: token.boundingBox), imageAspectRatio: imageAspectRatio
                                )
                            )
                        }
                    }
                },
                kind: kind,
                alignment: alignment,
                fontSize: fontSize(for: kind, sourceLineHeight: sourceLineHeight)
            )
        }
    }

    /// Infer alignment only from repeated evidence within one OCR paragraph.
    /// Similar-width body rows cannot distinguish left, center and right;
    /// preserve the existing leading alignment unless one anchor clearly wins.
    static func multilineTextAlignment(
        lineRects: [CGRect],
        imageAspectRatio: CGFloat = 1
    ) -> String {
        guard lineRects.count >= 3, imageAspectRatio.isFinite, imageAspectRatio > 0,
              lineRects.allSatisfy({
                  $0.minX.isFinite && $0.minY.isFinite && $0.width.isFinite && $0.height.isFinite
                      && $0.width > 0 && $0.height > 0
              }) else { return "left" }
        let heights = lineRects.map(\.height).sorted()
        let height = heights[heights.count / 2]
        guard heights.last! / heights.first! <= 1.5 else { return "left" }
        let rows = lineRects.sorted { $0.minY < $1.minY }
        for (previous, current) in zip(rows, rows.dropFirst()) {
            let gap = current.minY - previous.maxY
            guard gap >= -height * 0.25, gap <= height * 1.5 else { return "left" }
        }
        let glyphWidth = height / imageAspectRatio
        let widths = lineRects.map(\.width)
        let maximumWidth = widths.max()!
        guard widths.min()! >= glyphWidth * 3,
              maximumWidth - widths.min()! >= max(maximumWidth * 0.16, glyphWidth * 1.6)
        else { return "left" }
        var distinctWidths: [CGFloat] = []
        let widthTolerance = max(glyphWidth * 0.4, maximumWidth * 0.035)
        for width in widths.sorted() {
            if distinctWidths.last.map({ width - $0 > widthTolerance }) ?? true { distinctWidths.append(width) }
        }
        // A lone indented first row or short final row is not sufficient
        // evidence to relabel an otherwise uniform body paragraph.
        guard distinctWidths.count >= 3 else { return "left" }

        func deviation(_ values: [CGFloat]) -> CGFloat {
            let mean = values.reduce(0, +) / CGFloat(values.count)
            return sqrt(values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / CGFloat(values.count))
        }
        let lefts = lineRects.map(\.minX)
        let centers = lineRects.map(\.midX)
        let rights = lineRects.map(\.maxX)
        let leftDeviation = deviation(lefts)
        let centerDeviation = deviation(centers)
        let rightDeviation = deviation(rights)
        // Normalize pixel-scale OCR jitter by glyph height, converting the
        // vertical measurement to horizontal image coordinates first.
        let tolerance = max(0.0008, glyphWidth * 0.20)
        func isStable(_ values: [CGFloat], _ candidate: CGFloat, alternatives: CGFloat) -> Bool {
            candidate <= tolerance && values.max()! - values.min()! <= tolerance * 2
                && candidate < alternatives * 0.25
        }
        if isStable(centers, centerDeviation, alternatives: min(leftDeviation, rightDeviation)) {
            return "center"
        }
        if isStable(rights, rightDeviation, alternatives: min(leftDeviation, centerDeviation)) {
            return "right"
        }
        return "left"
    }

    /// Centered cover/title groups have a shared center and visibly different
    /// left edges. One approximately centered long paragraph is insufficient.
    static func centeredTextBlockIndexes(
        rects: [CGRect],
        lineCounts: [Int],
        excludedIndexes: Set<Int> = []
    ) -> Set<Int> {
        guard rects.count == lineCounts.count else { return [] }
        let candidates = rects.indices.filter { index in
            let rect = rects[index]
            return !excludedIndexes.contains(index) && lineCounts[index] == 1
                && rect.width >= 0.06 && rect.width <= 0.78
                && abs(rect.midX - 0.5) <= 0.035
        }
        guard candidates.count >= 3 else { return [] }
        let widths = candidates.map { rects[$0].width }
        let lefts = candidates.map { rects[$0].minX }
        let centersY = candidates.map { rects[$0].midY }
        guard (widths.max()! - widths.min()!) >= 0.15,
              (lefts.max()! - lefts.min()!) >= 0.075,
              (centersY.max()! - centersY.min()!) >= 0.12 else { return [] }
        return Set(candidates)
    }

    private static func orderedFragmentTokens(in block: TextBlock) -> [FragmentToken] {
        block.lines
            .sorted { lhs, rhs in
                ImageTranslationReadingOrderLayout.precedesInReadingOrder(
                    lhs.boundingBox, rhs.boundingBox
                )
            }
            .flatMap { line in
                line.fragments
                    .sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                    .flatMap(\.tokens)
            }
    }

    private static func isProtectedRect(
        _ protectedRect: CGRect,
        adjacentTo lineRects: [CGRect],
        imageAspectRatio: CGFloat
    ) -> Bool {
        lineRects.contains { lineRect in
            let verticalOverlap = min(protectedRect.maxY, lineRect.maxY) - max(protectedRect.minY, lineRect.minY)
            let overlapRatio = max(0, verticalOverlap) / max(min(protectedRect.height, lineRect.height), 0.001)
            let horizontalGap = max(
                0,
                max(protectedRect.minX - lineRect.maxX, lineRect.minX - protectedRect.maxX)
            )
            return overlapRatio > 0.32
                && horizontalGap <= max(protectedRect.height, lineRect.height) * 1.8 / imageAspectRatio
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
        let imageAspectRatio = CGFloat(bitmap.pixelsWide) / CGFloat(bitmap.pixelsHigh)
        let horizontalPadding = max(0.002, tokenBox.height * 0.24) / imageAspectRatio
        let verticalPadding = max(0.0012, tokenBox.height * 0.14)
        let chipBox = clampedUnitRect(
            tokenBox.insetBy(dx: -horizontalPadding, dy: -verticalPadding)
        )
        let backgroundGap = max(0.002, tokenBox.height * 0.30)
        let horizontalBackgroundGap = backgroundGap / imageAspectRatio
        let midY = tokenBox.midY
        let midX = tokenBox.midX

        let chipPoints = [
            CGPoint(x: max(chipBox.minX, tokenBox.minX - horizontalPadding * 0.55), y: midY),
            CGPoint(x: min(chipBox.maxX, tokenBox.maxX + horizontalPadding * 0.55), y: midY),
            CGPoint(x: midX, y: max(chipBox.minY, tokenBox.minY - verticalPadding * 0.55)),
            CGPoint(x: midX, y: min(chipBox.maxY, tokenBox.maxY + verticalPadding * 0.55))
        ]
        let backgroundPoints = [
            CGPoint(x: chipBox.minX - horizontalBackgroundGap, y: midY),
            CGPoint(x: chipBox.maxX + horizontalBackgroundGap, y: midY),
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
        if block.lines.first?.isListItemStart == true || isBulletLine(firstText) {
            return .listItem
        }

        if isCodeOnlyLine(text) {
            return .code
        }

        let blockLineHeight = median(
            block.lines.map { topLeftRect(fromVisionBox: $0.boundingBox).height }.filter { $0 > 0 }
        ) ?? medianLineHeight
        // A title can be longer than the old 36-character heading heuristic.
        // Conversely a short UI label does not imply semibold typography.
        if block.lines.count == 1,
           blockLineHeight > medianLineHeight * 1.28,
           !endsTextBlock(text) {
            return index == 0 ? .title : .heading
        }
        if looksLikeStandaloneHeading(text), blockLineHeight > medianLineHeight * 1.15 {
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
            return Double(min(1, max(baseSize, 0.010)))
        case .caption:
            let baseSize = sourceLineHeight * 1.06
            return Double(min(1, max(baseSize, 0.008)))
        case .code:
            let baseSize = sourceLineHeight * 0.82
            return Double(max(baseSize, 0.009))
        }
    }

    private static func isBulletLine(_ text: String) -> Bool {
        ImageTranslationSourcePolicy.startsListItem(text)
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

    static func isCodeOnlyLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        // OCR inserts spaces inside operators and index expressions. Detect
        // the full statement before token heuristics; translating individual
        // words such as "for"/"range" would redraw and corrupt the code image.
        if [codeAssignmentExpression, codeLoopExpression].contains(where: {
            guard let expression = capturedExpression(in: trimmed, matching: $0) else { return false }
            return isSymbolicExpression(expression)
        }) {
            return true
        }
        if let condition = capturedExpression(in: trimmed, matching: codeConditionalExpression),
           isSymbolicExpression(condition),
           condition.range(of: #"[=<>!]|\w\s*[\[(]"#, options: .regularExpression) != nil {
            return true
        }
        // A short partial loop can be a separate OCR observation. Limit this
        // fallback to a single-letter variable, not prose such as "for example".
        if trimmed.range(of: #"^for\s+[A-Za-z_]\s+in\s*$"#, options: .regularExpression) != nil
            || trimmed.range(of: #"^(?:for\s+)?(?:[A-Za-z_]\s+)?in\s+range\s*\([^)]*\)\s*:\s*$"#, options: .regularExpression) != nil {
            return true
        }
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
                    || token.filter { $0 == "/" }.count >= 2
                )
        }
    }

    private static let codeAssignmentExpression = try? NSRegularExpression(
        pattern: #"^(?:[A-Za-z_][\w.]*\s*(?:\[[^\]]+\]\s*)*|\d+)?\s*(?:[+\-*/@]\s*)?=\s*(.+)$"#
    )
    private static let codeLoopExpression = try? NSRegularExpression(
        pattern: #"^for\s+\w+\s+in\s+(.+)\s*:\s*$"#
    )
    private static let codeConditionalExpression = try? NSRegularExpression(
        pattern: #"^(?:if|elif|while)\s+(.+)\s*:\s*$"#
    )

    private static func capturedExpression(
        in text: String,
        matching expression: NSRegularExpression?
    ) -> String? {
        guard let match = expression?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    private static func isSymbolicExpression(_ expression: String) -> Bool {
        // Quoted literals may contain natural words, but unquoted prose after
        // an equals sign is a definition to translate ("Loss = prediction
        // error ..."), not an assignment to remove from the source regions.
        let withoutStringLiterals = expression.replacingOccurrences(
            of: #"\"(?:[^\"\\]|\\.)*\"|'(?:[^'\\]|\\.)*'"#,
            with: "0", options: .regularExpression
        )
        return withoutStringLiterals.range(
            of: #"^[A-Za-z0-9_\s.\[\](){},:+\-*/@%^=<>!&|~×÷·]+$"#,
            options: .regularExpression
        ) != nil && withoutStringLiterals.range(
            of: #"\b[A-Za-z_][A-Za-z0-9_]*\s+[A-Za-z_][A-Za-z0-9_]*\b"#,
            options: .regularExpression
        ) == nil
    }

    static func shouldPreserveCodeToken(_ text: String) -> Bool {
        let token = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: codeTrimCharacters)
        guard token.count >= 3, !ImageTranslationSourcePolicy.isOrdinaryProseToken(token),
              token.range(of: #"^[A-Za-z_][A-Za-z0-9_./:-]*$"#, options: .regularExpression) != nil else {
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

    private static func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            (0x3400...0x4DBF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value)
                || (0xF900...0xFAFF).contains($0.value)
        }
    }

    static func fullImageRect(fromVisionBox box: CGRect, withinTopLeftROI roi: CGRect) -> CGRect {
        // Vision observations are normalized to the request ROI, not the image.
        let local = topLeftRect(fromVisionBox: box)
        return CGRect(x: roi.minX + local.minX * roi.width, y: roi.minY + local.minY * roi.height,
                      width: local.width * roi.width, height: local.height * roi.height)
    }

    private static func expandedTextBlockRect(
        _ rect: CGRect,
        kind: TextBlockKind,
        sourceLineHeight: CGFloat,
        imageAspectRatio: CGFloat
    ) -> CGRect {
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

        // Padding follows the glyph size, not the full paragraph height. x/y
        // use different normalization axes, especially in a shallow crop.
        let horizontalPadding = max(0.002, sourceLineHeight * horizontalMultiplier) / imageAspectRatio
        let verticalPadding = max(0.0015, sourceLineHeight * verticalMultiplier)
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

    private static func expandedTextLineRect(
        _ rect: CGRect,
        kind: TextBlockKind,
        imageAspectRatio: CGFloat
    ) -> CGRect {
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

        let horizontalPadding = max(0.0015, rect.height * horizontalMultiplier) / imageAspectRatio
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

    private static func expandedTextFragmentRect(_ rect: CGRect, imageAspectRatio: CGFloat) -> CGRect {
        let horizontalPadding = max(0.001, rect.height * 0.08) / imageAspectRatio
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

    private static func expandedCodeTokenRect(_ rect: CGRect, imageAspectRatio: CGFloat) -> CGRect {
        let horizontalPadding = max(0.0015, rect.height * 0.18) / imageAspectRatio
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

    private static func expandedProtectedTokenRect(_ rect: CGRect, imageAspectRatio: CGFloat) -> CGRect {
        let horizontalPadding = max(0.0015, rect.height * 0.20) / imageAspectRatio
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
