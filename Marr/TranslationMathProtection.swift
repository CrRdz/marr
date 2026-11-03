import Foundation
import CoreGraphics

/// Unfiltered OCR geometry, in normalized coordinates with a top-left origin.
struct ImageTranslationMathObservation {
    let text: String
    let rect: ImageTranslationLineRect
    let tokens: [ImageTranslationTokenRect]
}

/// Keeps mathematical typography as source pixels. OCR is used to locate an
/// expression, never to reconstruct its fraction bars, radicals or scripts.
enum ImageTranslationMathProtection {
    private struct Anchor {
        var rect: CGRect
        var text: String
        var isDisplay = false
        var fixedBounds = false
    }

    static func protect(
        _ regions: [ImageTranslationSourceRegion],
        observations: [ImageTranslationMathObservation],
        imageSize: CGSize,
        cgImage: CGImage? = nil
    ) -> [ImageTranslationSourceRegion] {
        guard imageSize.width.isFinite, imageSize.height.isFinite,
              imageSize.width > 0, imageSize.height > 0 else { return regions }
        let aspect = imageSize.width / imageSize.height
        var sourceRegions = regions
        var anchors = observations.flatMap { expressionAnchors(in: $0, aspect: aspect) }
        anchors += observations.flatMap { annotatedFunctionAnchors(in: $0, aspect: aspect) }
        anchors += wrappedMembershipAnchors(observations, aspect: aspect)
        anchors += detachedAnnotationAnchors(observations)
        anchors += observations.flatMap { predicateSymbolAnchors(in: $0, aspect: aspect) }
        anchors += observations.compactMap { observation in
            // A lone "a" before "too small/large" is a variable in a complete
            // short caption, not an English article. Keep the source glyph
            // (often Greek alpha read as a), and translate only its qualifier.
            guard observation.text.range(of: #"^[a-zα-ω]\s+(?:much\s+)?too\s+(?:small|large)\s*:?[.!]?\s*$"#,
                      options: .regularExpression) != nil,
                  let variable = observation.tokens.first else { return nil }
            return Anchor(rect: rect(variable), text: variable.text)
        }
        anchors += displayAnchors(observations: observations, imageSize: imageSize, cgImage: cgImage)
        anchors += continuedDisplayAnchors(observations: observations, imageSize: imageSize, cgImage: cgImage)

        // A fraction's denominator may be its own observation and the numerator
        // may be absent from OCR altogether. Recover its full vertical extent
        // from the neighboring relation's baseline and the lower operand.
        for index in anchors.indices {
            guard !anchors[index].isDisplay else { continue }
            let original = anchors[index].rect
            for observation in observations where isSingleVariable(observation.text) {
                let operand = rect(observation.rect)
                let gap = original.minX - operand.maxX
                guard operand.midX < original.minX,
                      gap >= -original.height * 0.12 / aspect,
                      gap < original.height * 0.9 / aspect,
                      abs(operand.midY - original.midY) < original.height * 1.25
                else { continue }
                anchors[index].rect = anchors[index].rect.union(operand)
                anchors[index].text = observation.text + " " + anchors[index].text
                if operand.midY > original.midY + original.height * 0.15 {
                    let upper = original.midY - (operand.maxY - original.midY) * 1.15
                    anchors[index].rect = anchors[index].rect.union(CGRect(
                        x: operand.minX, y: upper,
                        width: operand.width, height: operand.maxY - upper
                    ))
                }
            }
        }

        if let cgImage, let ink = MathInkMap(cgImage: cgImage) {
            let prose = observations.flatMap(\.tokens).filter {
                $0.text.filter(\.isLetter).count >= 2 && !isMathAtom($0.text, allowsOCRRoot: true)
            }.map { rect($0) }
            // Inline equations can be fragmented across observations, with
            // some operands omitted altogether. Search only this line's ink;
            // display recovery's tall band would swallow the neighboring row.
            anchors = anchors.map { anchor in
                guard !anchor.isDisplay, !anchor.fixedBounds else { return anchor }
                var copy = anchor
                copy.rect = ink.recover(anchor.rect, prose: prose,
                    lineHeight: anchor.rect.height * imageSize.height, inline: true)
                return copy
            }
            // Tiny stacked fractions may be entirely absent from OCR, even
            // when the surrounding sentence is recognized. Keep only the
            // tightly confirmed source geometry; ordinary ink expansion would
            // absorb an adjacent word whose OCR box spans the missing glyph.
            var omittedFractions: [CGRect] = []
            for observation in observations {
                let words = observation.tokens.filter {
                    $0.text.filter(\.isLetter).count >= 3 && !isMathAtom($0.text, allowsOCRRoot: true)
                }
                guard words.count >= 3 else { continue }
                let fractions = ink.inlineFractionRects(in: rect(observation.rect))
                omittedFractions += fractions
                anchors += fractions.map {
                    Anchor(rect: $0, text: "∂")
                }
            }
            sourceRegions = refinedFractionProseGeometry(regions, fractions: omittedFractions,
                anchors: anchors, ink: ink)
        }
        guard !anchors.isEmpty else { return regions }
        // A lone variable can move naturally within a translated sentence.
        // Only complete expressions need fixed source-pixel geometry.
        let padX = 1.5 / imageSize.width
        let padY = 1.5 / imageSize.height
        anchors = merged(anchors).map { anchor in
            Anchor(rect: anchor.rect.insetBy(dx: -padX, dy: -padY)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1)), text: anchor.text,
                   isDisplay: anchor.isDisplay)
        }

        // Assign every expression to exactly one visual line. An orphan "→ 0"
        // can extend the preceding prose line without being merged into the
        // next bullet or into the list's parent heading.
        var assigned: [Int: [Int: [Anchor]]] = [:]
        var carriers = anchors.filter(\.isDisplay)
        for anchor in anchors where !anchor.isDisplay {
            var best: (region: Int, line: Int, score: CGFloat)?
            for (regionIndex, region) in sourceRegions.enumerated() {
                for (lineIndex, line) in lines(in: region).enumerated() {
                    let height = max(line.height, 0.001)
                    let horizontalGap = max(0, max(line.minX, anchor.rect.minX) - min(line.maxX, anchor.rect.maxX))
                    guard sameLine(anchor.rect, line), horizontalGap < height * 1.8 / aspect else { continue }
                    let score = abs(anchor.rect.midY - line.midY) / height
                        + horizontalGap * aspect / height * 0.4
                    if best == nil || score < best!.score {
                        best = (regionIndex, lineIndex, score)
                    }
                }
            }
            if let best { assigned[best.region, default: [:]][best.line, default: []].append(anchor) }
            else { carriers.append(anchor) }
        }

        let protected = sourceRegions.enumerated().flatMap { index, region -> [ImageTranslationSourceRegion] in
            let perLine = assigned[index] ?? [:]
            let display = carriers.filter { anchor in
                region.tokens.contains { covers(anchor.rect, rect($0)) }
            }
            guard !perLine.isEmpty || !display.isEmpty else { return [region] }
            let regionLines = lines(in: region)
            // Tall fraction and matrix observations overlap several line bands.
            // Give each OCR token one closest baseline, rather than copying it
            // into every overlapping line and translating it more than once.
            let tokensByLine = Dictionary(grouping: region.tokens.filter { token in
                !display.contains { covers($0.rect, rect(token)) }
            }) { token in
                regionLines.indices.min {
                    abs(regionLines[$0].midY - rect(token).midY) < abs(regionLines[$1].midY - rect(token).midY)
                } ?? 0
            }
            return regionLines.enumerated().compactMap { lineIndex, line in
                let lineTokens = tokensByLine[lineIndex] ?? []
                guard !lineTokens.isEmpty else { return nil }
                let math = (perLine[lineIndex] ?? []).sorted { $0.rect.minX < $1.rect.minX }
                let id = regionLines.count == 1 ? region.id : "\(region.id)-line\(lineIndex + 1)"
                let remainingLine = !display.isEmpty && math.isEmpty
                    ? lineTokens.dropFirst().reduce(rect(lineTokens[0])) { $0.union(rect($1)) }
                    : line
                return protectedRegion(region, id: id, line: remainingLine, tokens: lineTokens,
                                       anchors: math, aspect: aspect)
            }
        }
        // Formula-only OCR lines can be filtered out before source-region
        // creation. Keep independent carriers so their pixels still protect
        // against erasing neighboring prose, without asking the model to read
        // or reconstruct the expression.
        return protected + carriers.enumerated().map { index, anchor in
            ImageTranslationSourceRegion(
                id: "math-preserved-\(index + 1)", sourceText: "⟦math_1⟧",
                x: anchor.rect.minX, y: anchor.rect.minY, width: anchor.rect.width, height: anchor.rect.height,
                imageAspectRatio: Double(aspect), protectedRects: [lineRect(anchor.rect)],
                tokens: [sourceToken("⟦math_1⟧", box: anchor.rect, mathematical: true)],
                translationStrategy: .selective
            )
        }
    }

    private static func refinedFractionProseGeometry(
        _ regions: [ImageTranslationSourceRegion], fractions: [CGRect],
        anchors: [Anchor], ink: MathInkMap
    ) -> [ImageTranslationSourceRegion] {
        guard !fractions.isEmpty else { return regions }
        return regions.enumerated().map { index, region in
            let regionLines = lines(in: region)
            guard regionLines.count == 1, let line = regionLines.first,
                  region.tokens.count >= 3 else { return region }
            let heights = region.tokens.map(\.height).sorted()
            let tokenHeight = heights[heights.count / 2]
            guard let fraction = fractions.filter({ line.intersects($0)
                && line.height > $0.height * 1.3 && tokenHeight > $0.height * 1.15
            }).min(by: { abs($0.midY - line.midY) < abs($1.midY - line.midY) }) else { return region }
            // A missing fraction can make Vision give every word a tall,
            // sloping box that includes the next bullet. Its source ink is
            // still on one baseline. Exclude known neighboring rows before
            // measuring that baseline, rather than choosing their taller ink.
            let neighbors = regions.enumerated().flatMap { other, candidate -> [CGRect] in
                guard other != index else { return [] }
                return lines(in: candidate).filter { $0.height < line.height * 0.7 }
            }
            let exclusions = anchors.map(\.rect) + neighbors
            guard let geometry = ink.tightenedFractionProse(line: line, words: region.tokens.map(rect),
                fraction: fraction, exclusions: exclusions) else { return region }
            let tokens = zip(region.tokens, geometry.words).map { token, box in
                sourceToken(token.text, box: box, protected: token.isProtected, mathematical: token.isMathematical)
            }
            let box = geometry.words.reduce(CGRect.null) { $0.union($1) }
            return ImageTranslationSourceRegion(
                id: region.id, sourceText: region.sourceText,
                x: box.minX, y: box.minY, width: box.width, height: box.height,
                imageAspectRatio: region.imageAspectRatio, lineRects: [lineRect(box)],
                preservesListMarker: region.preservesListMarker, textRects: geometry.words.map(lineRect),
                protectedRects: region.protectedRects, tokens: tokens, translationStrategy: region.translationStrategy,
                codeRects: region.codeRects, kind: region.kind, textColor: region.textColor,
                backgroundColor: region.backgroundColor, alignment: region.alignment, weight: region.weight,
                fontSize: region.fontSize.map { min($0, Double(geometry.band.height * 1.25)) }
            )
        }
    }

    private static func expressionAnchors(
        in observation: ImageTranslationMathObservation,
        aspect: CGFloat
    ) -> [Anchor] {
        let tokens = observation.tokens
        guard !tokens.isEmpty else { return [] }
        var result: [Anchor] = []
        var consumed = Set<Int>()
        for index in tokens.indices where !consumed.contains(index)
            && (hasMathSymbol(tokens[index].text) || isMathFunction(tokens[index].text)
                || isContextualMathSeed(at: index, tokens: tokens)
                || (["(", "{"].contains(tokens[index].text) && index + 1 < tokens.count
                    && isMathAtom(tokens[index + 1].text, allowsOCRRoot: false))) {
            // A leading OCR '>' may be a triangular list marker. A comparison
            // requires an operand on both sides; arrows/radicals can be an OCR
            // fragment whose missing left operand is recovered geometrically.
            let isComparison = tokens[index].text.trimmingCharacters(in: .whitespaces).allSatisfy { "<>=≤≥≠≈~+−-—–#»".contains($0) }
            if isComparison {
                guard index > 0, index + 1 < tokens.count,
                      isMathAtom(tokens[index - 1].text, allowsOCRRoot: false),
                      isMathAtom(tokens[index + 1].text, allowsOCRRoot: true)
                else { continue }
            }
            var lower = index
            var upper = index + 1
            while lower > 0, (isMathAtom(tokens[lower - 1].text, allowsOCRRoot: false)
                    || isContextualMathSeed(at: lower - 1, tokens: tokens)),
                  adjacent(tokens[lower - 1], tokens[lower], aspect: aspect) { lower -= 1 }
            while upper < tokens.count, (isMathAtom(tokens[upper].text, allowsOCRRoot: isComparison)
                    || isContextualMathSeed(at: upper, tokens: tokens)),
                  adjacent(tokens[upper - 1], tokens[upper], aspect: aspect) { upper += 1 }
            let selected = tokens[lower..<upper].filter { token in
                // OCR may assign '(with' one shared rectangle. Keeping the
                // parenthesis must not freeze the adjacent natural word too.
                guard !hasOperand(token.text) else { return true }
                return !tokens.contains { other in
                    other.text.filter(\.isLetter).count >= 2
                        && !isMathAtom(other.text, allowsOCRRoot: true)
                        && overlap(rect(token), rect(other)) > 0.6
                }
            }
            guard selected.contains(where: { hasOperand($0.text) }) else { continue }
            let box = selected.dropFirst().reduce(rect(selected[0])) { $0.union(rect($1)) }
            result.append(Anchor(rect: box, text: selected.map(\.text).joined(separator: " ")))
            consumed.formUnion(lower..<upper)
        }
        return result
    }

    private static func isVectorSpace(_ text: String) -> Bool {
        text.range(of: #"^(?:[RXJTℝℂℤ]|R[PNDXOndkm0-9ªºᵈᵏⁿ⁰¹²³⁴⁵⁶⁷⁸⁹]{1,5})$"#, options: .regularExpression) != nil
    }

    private static func annotatedFunctionAnchors(
        in observation: ImageTranslationMathObservation, aspect: CGFloat
    ) -> [Anchor] {
        let tokens = observation.tokens
        guard tokens.count >= 5 else { return [] }
        return tokens.indices.compactMap { index in
            guard index > 0, index + 3 < tokens.count,
                  tokens[index].text.range(of: #"^(?:[A-Z][a-z]{2,8}|[a-z][A-Z][a-z]{1,8}|[A-Za-z]_[A-Za-z0-9]+)$"#,
                    options: .regularExpression) != nil,
                  isMathFunction(tokens[index - 1].text) || hasMathSymbol(tokens[index - 1].text),
                  tokens[index + 1].text == "(",
                  adjacent(tokens[index - 1], tokens[index], aspect: aspect) else { return nil }
            let name = rect(tokens[index]), opening = rect(tokens[index + 1])
            guard sameLine(name, opening), opening.minX - name.maxX < name.height * 0.35 / aspect else { return nil }
            var box = name.union(opening)
            var hasArgument = false
            for end in (index + 2)..<min(tokens.count, index + 10) {
                let token = tokens[end]
                guard sameLine(name, rect(token)),
                      adjacent(tokens[end - 1], token, aspect: aspect) else { return nil }
                if token.text == ")" {
                    guard hasArgument else { return nil }
                    // A flattened subscript name such as Jreg remains source
                    // pixels only in an explicit mathematical function call.
                    return Anchor(rect: box.union(rect(token)), text: tokens[index...end].map(\.text).joined())
                }
                guard token.text.filter(\.isLetter).count <= 2,
                      isMathAtom(token.text, allowsOCRRoot: false) else { return nil }
                hasArgument = hasArgument || hasOperand(token.text)
                box = box.union(rect(token))
            }
            return nil
        }
    }

    private static func isFractionToken(_ text: String) -> Bool {
        // Vision often reads ∂ as d/a or drops it before the numerator.
        // Both operands must remain short symbolic names, not path words.
        text.range(of: #"^[da∂]?[A-Za-zα-ωΑ-Ω]/[da∂]?[A-Za-zα-ωΑ-Ω][A-Za-zα-ωΑ-Ω0-9]{0,2}$"#,
                   options: .regularExpression) != nil
    }

    private static func isContextualMathSeed(at index: Int, tokens: [ImageTranslationTokenRect]) -> Bool {
        let text = tokens[index].text
        if index > 0, index + 1 < tokens.count,
           text.range(of: #"^[A-Z][a-z]{1,11}$"#, options: .regularExpression) != nil,
           isMathAtom(tokens[index - 1].text, allowsOCRRoot: false),
           hasOperand(tokens[index - 1].text), hasMathSymbol(tokens[index + 1].text) {
            let annotation = rect(tokens[index]), base = rect(tokens[index - 1])
            if annotation.minX <= base.maxX + base.width * 0.3,
               abs(annotation.midY - base.midY) > min(annotation.height, base.height) * 0.15 {
                return true
            }
        }
        if isFractionToken(text) { return true }
        if text.count == 1, text.first?.isLetter == true,
           index + 2 < tokens.count, tokens[index + 1].text == "-",
           tokens[index + 2].text.lowercased() == "norm",
           overlap(rect(tokens[index]), rect(tokens[index + 1])) > 0.8 {
            // At small sizes Vision reads a superscript as a hyphen while
            // giving both tokens the exact same original glyph rectangle.
            return true
        }
        // A norm name may have no relation sign at all. OCR flattens its
        // superscript (L2), or reads the italic L as 1 at a wrapped line end.
        if text.range(of: #"^[A-Za-z1][0-9p²³]$"#, options: .regularExpression) != nil {
            let normMentioned = tokens.contains { $0.text.lowercased() == "norm" }
            if index + 1 < tokens.count, tokens[index + 1].text.lowercased() == "norm" { return true }
            if normMentioned, index > 0, tokens[index - 1].text.lowercased() == "squared" { return true }
        }
        let mathematicalContext = tokens.contains { hasMathSymbol($0.text) || isFractionToken($0.text) || $0.text == "(" }
        if mathematicalContext,
           text.range(of: #"^[A-Za-z][0-9]{1,3}$"#, options: .regularExpression) != nil { return true }
        if mathematicalContext, index + 1 < tokens.count, tokens[index + 1].text == ")",
           isMathAtom(text, allowsOCRRoot: false),
           text.range(of: #"^[A-Za-z][ij0-9]$"#, options: .regularExpression) != nil,
           overlap(rect(tokens[index]), rect(tokens[index + 1])) > 0.8 { return true }
        if text == "\"", index > 0, index + 1 < tokens.count,
           isSingleVariable(tokens[index - 1].text), tokens[index + 1].text == ")",
           overlap(rect(tokens[index]), rect(tokens[index - 1])) > 0.8 { return true }
        if text == "R", index + 1 < tokens.count,
           ["°", "′", "^"].contains(tokens[index + 1].text) { return true }
        if ["'", "′", "″"].contains(text), index > 0,
           isSingleVariable(tokens[index - 1].text) { return true }
        guard index + 1 < tokens.count, isVectorSpace(tokens[index + 1].text) else { return false }
        if ["e", "E"].contains(text), index > 0 {
            return isMathAtom(tokens[index - 1].text, allowsOCRRoot: false)
                && hasOperand(tokens[index - 1].text)
                || [")", "]"].contains(tokens[index - 1].text)
        }
        if text.range(of: #"^[a-z][eE]$"#, options: .regularExpression) != nil {
            // "be R" is ambiguous without a neighboring symbolic list.
            return text != "be" || (index > 0 && [",", ";"].contains(tokens[index - 1].text))
        }
        return false
    }

    private static func predicateSymbolAnchors(
        in observation: ImageTranslationMathObservation, aspect: CGFloat
    ) -> [Anchor] {
        let tokens = observation.tokens
        return tokens.indices.compactMap { index in
            let token = tokens[index]
            guard token.text.count == 1, token.text != "I",
                  token.text.first?.isLetter == true || token.text.first?.isNumber == true || ["«", "»"].contains(token.text),
                  index + 1 < tokens.count, adjacent(token, tokens[index + 1], aspect: aspect) else { return nil }
            let next = tokens[index + 1]
            if index >= 2, tokens[index - 1].text.lowercased() == "enough",
               ["small", "large", "positive", "negative"].contains(tokens[index - 2].text.lowercased()),
               ["(", ",", ";", ".", ":"].contains(next.text) {
                // A scalar after "small enough" is not the article in
                // "a small box". Preserve its OCR glyph (often α read as a).
                return Anchor(rect: rect(token), text: token.text, fixedBounds: true)
            }
            if [";", "?"].contains(next.text), isSingleVariable(token.text),
               overlap(rect(token), rect(next)) > 0.8,
               observation.tokens.contains(where: { hasMathSymbol($0.text) || isFractionToken($0.text) }) {
                // In mathematical prose Vision reads w_j as two tokens w ;
                // sharing one box. Preserve the complete source glyph instead
                // of rewriting w and dropping the lower script.
                return Anchor(rect: rect(token).union(rect(next)), text: token.text + next.text)
            }
            let predicate = next.text.lowercased()
            var symbolic = ["is", "denotes", "represents", "controls", "penalizes", "penalises"].contains(predicate)
            if predicate == "can", index + 2 < tokens.count,
               adjacent(tokens[index + 1], tokens[index + 2], aspect: aspect) {
                // "a can of beans" contains an article and a noun, while
                // "a can be a function" has a symbolic grammatical subject.
                symbolic = ["be", "denote", "represent", "take"].contains(tokens[index + 2].text.lowercased())
            }
            guard symbolic else { return nil }
            return Anchor(rect: rect(token), text: token.text,
                          fixedBounds: predicate == "penalizes" || predicate == "penalises")
        }
    }

    private static func detachedAnnotationAnchors(_ observations: [ImageTranslationMathObservation]) -> [Anchor] {
        let allTokens = observations.flatMap(\.tokens)
        return observations.compactMap { observation in
            guard observation.tokens.count >= 2 else { return nil }
            let annotation = observation.tokens[0], relation = observation.tokens[1]
            guard annotation.text.range(of: #"^[A-Z][a-z]{1,11}$"#, options: .regularExpression) != nil,
                  hasMathSymbol(relation.text) else { return nil }
            let box = rect(annotation)
            guard let base = allTokens.filter({ token in
                guard token.text.range(of: #"^[A-Za-z][A-Za-z0-9]{0,2}$"#, options: .regularExpression) != nil,
                      isMathAtom(token.text, allowsOCRRoot: false) else { return false }
                let operand = rect(token)
                let shift = abs(box.midY - operand.midY)
                return operand.minX < box.minX && box.minX <= operand.maxX + operand.width * 0.3
                    && shift > min(box.height, operand.height) * 0.15
                    && shift < max(box.height, operand.height) * 0.9
            }).min(by: { abs(rect($0).midY - box.midY) < abs(rect($1).midY - box.midY) }) else { return nil }
            let continuation = observation.tokens.dropFirst().prefix {
                isMathAtom($0.text, allowsOCRRoot: true)
            }
            let complete = continuation.reduce(rect(base).union(box)) { $0.union(rect($1)) }
            return Anchor(rect: complete,
                text: ([base.text, annotation.text] + continuation.map(\.text)).joined(separator: " "))
        }
    }

    private static func wrappedMembershipAnchors(
        _ observations: [ImageTranslationMathObservation], aspect: CGFloat
    ) -> [Anchor] {
        var anchors: [Anchor] = []
        for observation in observations {
            let tokens = observation.tokens
            guard tokens.count >= 2, ["e", "E"].contains(tokens.last!.text),
                  isMathAtom(tokens[tokens.count - 2].text, allowsOCRRoot: false) else { continue }
            let line = rect(observation.rect)
            guard let next = observations.first(where: { next in
                guard let first = next.tokens.first, isVectorSpace(first.text) else { return false }
                let nextLine = rect(next.rect)
                return nextLine.minY >= line.midY && nextLine.minY - line.maxY < line.height * 1.2
                    && nextLine.minX < line.midX
            }) else { continue }
            let suffix = Array(tokens.suffix(2))
            anchors.append(Anchor(rect: rect(suffix[0]).union(rect(suffix[1])),
                                  text: suffix.map(\.text).joined(separator: " ")))
            var prefix = [next.tokens[0]]
            for token in next.tokens.dropFirst() {
                guard isMathAtom(token.text, allowsOCRRoot: false),
                      adjacent(prefix.last!, token, aspect: aspect) else { break }
                prefix.append(token)
            }
            anchors.append(Anchor(rect: prefix.dropFirst().reduce(rect(prefix[0])) { $0.union(rect($1)) },
                                  text: prefix.map(\.text).joined(separator: " ")))
        }
        return anchors
    }

    private static func continuedDisplayAnchors(
        observations: [ImageTranslationMathObservation], imageSize: CGSize, cgImage: CGImage?
    ) -> [Anchor] {
        let aspect = imageSize.width / imageSize.height
        let prose = observations.flatMap(\.tokens).filter {
            $0.text.filter(\.isLetter).count >= 2 && !isMathAtom($0.text, allowsOCRRoot: true)
        }.map { rect($0) }
        let ink = cgImage.flatMap(MathInkMap.init)
        return observations.compactMap { observation in
            let tokens = observation.tokens
            guard tokens.count >= 2, tokens.last?.text == "=",
                  isMathAtom(tokens[tokens.count - 2].text, allowsOCRRoot: false) else { return nil }
            let suffix = Array(tokens.suffix(2))
            var box = rect(suffix[0]).union(rect(suffix[1]))
            let neighbors = observations.filter { next in
                let candidate = rect(next.rect)
                let gap = candidate.minX - box.maxX
                return candidate.minX > box.midX && gap >= -box.height * 0.15 / aspect
                    && gap < box.height * 1.2 / aspect && sameLine(box, candidate)
                    && !next.tokens.isEmpty && next.tokens.allSatisfy { isMathAtom($0.text, allowsOCRRoot: true) }
                    && next.tokens.contains { hasOperand($0.text) }
            }
            guard !neighbors.isEmpty else { return nil }
            for neighbor in neighbors { box = box.union(rect(neighbor.rect)) }
            if let ink { box = ink.recover(box, prose: prose, lineHeight: rect(observation.rect).height * imageSize.height) }
            return Anchor(rect: box, text: suffix.map(\.text).joined(separator: " "), isDisplay: true)
        }
    }

    private static func displayAnchors(
        observations: [ImageTranslationMathObservation],
        imageSize: CGSize,
        cgImage: CGImage?
    ) -> [Anchor] {
        let allTokens = observations.flatMap(\.tokens)
        let heights = allTokens.map { rect($0).height * imageSize.height }
            .filter { $0 >= 4 }.sorted()
        let lineHeight = heights.isEmpty ? 24 : heights[heights.count / 2]
        let prose = allTokens.filter {
            $0.text.filter(\.isLetter).count >= 2 && !isMathAtom($0.text, allowsOCRRoot: true)
        }.map { rect($0) }
        let ink = cgImage.flatMap(MathInkMap.init)
        var candidates: [Anchor] = []
        for observation in observations {
            // A lone connector between displayed equations remains prose.
            // Longer sentences are handled by the inline-expression pass.
            let words = observation.tokens.filter {
                $0.text.filter(\.isLetter).count >= 2 && !isMathAtom($0.text, allowsOCRRoot: true)
            }
            guard words.isEmpty || words.allSatisfy({ $0.text.lowercased() == "and" }) else { continue }
            let math = observation.tokens.filter { isMathAtom($0.text, allowsOCRRoot: true) }
            guard let first = math.first,
                  math.contains(where: { hasOperand($0.text) || hasMathSymbol($0.text) }) else { continue }
            let box = math.dropFirst().reduce(rect(first)) { $0.union(rect($1)) }
            let text = math.map(\.text).joined(separator: " ")
            candidates.append(Anchor(rect: box, text: text, isDisplay: true))
            let operands = math.filter { hasOperand($0.text) }
            let hasNeighboringEquation = observations.contains { other in
                guard other.tokens.contains(where: { hasMathSymbol($0.text) }),
                      other.tokens.contains(where: { hasOperand($0.text) }),
                      !other.tokens.contains(where: {
                          $0.text.filter(\.isLetter).count >= 2 && !isMathAtom($0.text, allowsOCRRoot: true)
                      }) else { return false }
                let neighbor = rect(other.rect)
                let gap = max(0, max(box.minX, neighbor.minX) - min(box.maxX, neighbor.maxX)) * imageSize.width
                return sameLine(box, neighbor) && gap < lineHeight
            }
            if operands.count == 1,
               !hasNeighboringEquation,
               operands[0].text.range(of: #"^[d∂a][LJlywxb]$"#, options: .regularExpression) != nil,
               let fraction = ink?.fractionSeed(denominator: box) {
                // Only orphan denominators need a new tall seed. A fraction
                // already attached to a relation is recovered with that row;
                // expanding it twice can bridge several derivation rows and
                // make one unrelated OCR fragment reject the entire display.
                candidates.append(Anchor(rect: fraction, text: "∂ " + text, isDisplay: true))
            }
        }
        // Join the OCR's independent numerator, denominator, matrix rows and
        // relation signs. Do not jump across a prose connector or paragraph.
        var changed = true
        while changed {
            changed = false
            outer: for first in candidates.indices {
                for second in candidates.indices where second > first {
                    let a = candidates[first].rect, b = candidates[second].rect
                    let gapX = max(0, max(a.minX, b.minX) - min(a.maxX, b.maxX)) * imageSize.width
                    let gapY = max(0, max(a.minY, b.minY) - min(a.maxY, b.maxY)) * imageSize.height
                    guard (gapY == 0 && gapX < lineHeight * 3)
                            || (gapX == 0 && gapY < min(a.height, b.height) * imageSize.height * 1.2) else { continue }
                    let union = a.union(b)
                    guard !prose.contains(where: { overlap(union, $0) > 0.25 }) else { continue }
                    candidates[first].rect = union
                    candidates[first].text += " " + candidates[second].text
                    candidates.remove(at: second)
                    changed = true
                    break outer
                }
            }
        }
        candidates = candidates.filter {
            hasOperand($0.text) && (hasMathSymbol($0.text) || isMathFunction($0.text)
                || $0.text.range(of: #"[A-Za-z]\s*\("#, options: .regularExpression) != nil
                || ($0.text.contains("[") && $0.text.contains(where: \.isNumber)))
        }
        candidates.removeAll { candidate in
            allTokens.contains { token in
                guard !(token.text.lowercased() == "and" && candidate.rect.height * imageSize.height >= lineHeight * 2),
                      token.text.filter(\.isLetter).count >= 2,
                      !isMathAtom(token.text, allowsOCRRoot: true),
                      sameLine(candidate.rect, rect(token)) else { return false }
                let gap = max(0, max(candidate.rect.minX, rect(token).minX) - min(candidate.rect.maxX, rect(token).maxX))
                return gap * imageSize.width < lineHeight * 3
            }
        }
        guard let ink else { return candidates }
        return candidates.map { anchor in
            var copy = anchor
            copy.rect = ink.recover(anchor.rect, prose: prose, lineHeight: lineHeight)
            return copy
        }
    }

    /// Vision often omits the entire right side of a fraction or the lower
    /// rows of a matrix. Recover nearby source ink once a displayed equation
    /// is established, bounded by actual prose and blank columns. This never
    /// attempts to OCR or redraw the mathematical notation.
    private struct MathInkMap {
        let width: Int
        let height: Int
        let ink: [UInt8]

        init?(cgImage: CGImage) {
            let pixelWidth = cgImage.width
            let pixelHeight = cgImage.height
            width = pixelWidth
            height = pixelHeight
            guard pixelWidth > 0, pixelHeight > 0 else { return nil }
            var pixels = [UInt8](repeating: 255, count: pixelWidth * pixelHeight)
            let success = pixels.withUnsafeMutableBytes { bytes -> Bool in
                guard let context = CGContext(data: bytes.baseAddress, width: pixelWidth, height: pixelHeight,
                    bitsPerComponent: 8, bytesPerRow: pixelWidth, space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
                return true
            }
            guard success else { return nil }
            // Use the dominant canvas tone so the same protection works on
            // dark slides. Ignore antialiasing and JPEG noise near the paper.
            var histogram = [Int](repeating: 0, count: 256)
            for value in pixels { histogram[Int(value)] += 1 }
            let background = histogram.indices.max { histogram[$0] < histogram[$1] } ?? 255
            ink = pixels.map { abs(Int($0) - background) > 65 ? 1 : 0 }
        }

        func tightenedFractionProse(
            line: CGRect, words: [CGRect], fraction: CGRect, exclusions: [CGRect]
        ) -> (band: CGRect, words: [CGRect])? {
            let sx = CGFloat(width), sy = CGFloat(height)
            func pixels(_ rect: CGRect) -> CGRect {
                CGRect(x: rect.minX * sx, y: rect.minY * sy, width: rect.width * sx, height: rect.height * sy)
            }
            func normalized(_ rect: CGRect) -> CGRect {
                CGRect(x: rect.minX / sx, y: rect.minY / sy, width: rect.width / sx, height: rect.height / sy)
            }
            let row = pixels(line).intersection(CGRect(x: 0, y: 0, width: width, height: height))
            guard !row.isNull, row.height >= 12 else { return nil }
            let excluded = exclusions.map { pixels($0).insetBy(dx: -1, dy: -1) }.filter { $0.intersects(row) }
            func isProseInk(_ x: Int, _ y: Int) -> Bool {
                ink[y * width + x] != 0 && !excluded.contains { $0.contains(CGPoint(x: x, y: y)) }
            }
            let x0 = max(0, Int(row.minX.rounded(.down))), x1 = min(width, Int(row.maxX.rounded(.up)))
            let y0 = max(0, Int(row.minY.rounded(.down))), y1 = min(height, Int(row.maxY.rounded(.up)))
            var bands: [(top: Int, bottom: Int, count: Int)] = []
            for y in y0..<y1 {
                var count = 0
                for x in x0..<x1 where isProseInk(x, y) { count += 1 }
                guard count >= 3 else { continue }
                if let last = bands.indices.last, y - bands[last].bottom <= 2 {
                    bands[last].bottom = y
                    bands[last].count += count
                } else { bands.append((y, y, count)) }
            }
            let fractionPixels = pixels(fraction)
            let candidates = bands.filter {
                let height = CGFloat($0.bottom - $0.top + 1)
                let center = CGFloat($0.top + $0.bottom) / 2
                return height >= 6 && height < row.height * 0.65
                    && abs(center - fractionPixels.midY) < fractionPixels.height * 0.4
            }
            guard let band = candidates.min(by: {
                abs(CGFloat($0.top + $0.bottom) / 2 - fractionPixels.midY)
                    < abs(CGFloat($1.top + $1.bottom) / 2 - fractionPixels.midY)
            }) else { return nil }
            let top = max(y0, band.top - 1), bottom = min(y1, band.bottom + 2)
            let bandRect = CGRect(x: row.minX, y: CGFloat(top), width: row.width, height: CGFloat(bottom - top))
            let gap = max(3, Int(bandRect.height * 0.3))
            let tightened = words.map { word -> CGRect in
                let original = pixels(word)
                let left = max(x0, Int(original.minX.rounded(.down)))
                let right = min(x1, Int(original.maxX.rounded(.up)))
                var groups: [(left: Int, right: Int, count: Int)] = []
                if right > left {
                    for x in left..<right {
                        var count = 0
                        for y in top..<bottom where isProseInk(x, y) { count += 1 }
                        guard count > 0 else { continue }
                        if let last = groups.indices.last, x - groups[last].right <= gap {
                            groups[last].right = x
                            groups[last].count += count
                        } else { groups.append((x, x, count)) }
                    }
                }
                // A word box straddling the omitted formula may also include
                // the preceding word's tail. The larger connected ink group
                // locates the actual word without estimating character widths.
                guard let group = groups.max(by: { $0.count < $1.count }) else {
                    return normalized(CGRect(x: original.minX, y: bandRect.minY,
                        width: original.width, height: bandRect.height))
                }
                return normalized(CGRect(x: CGFloat(group.left) - 1, y: bandRect.minY,
                    width: CGFloat(group.right - group.left + 3), height: bandRect.height))
            }
            return (normalized(bandRect), tightened)
        }

        /// A differential denominator can be the only OCR result for a
        /// fraction. Require a real short horizontal bar and numerator ink;
        /// an isolated "dw" word without this geometry is not a formula seed.
        func fractionSeed(denominator: CGRect) -> CGRect? {
            let sx = CGFloat(width), sy = CGFloat(height)
            let box = CGRect(x: denominator.minX * sx, y: denominator.minY * sy,
                             width: denominator.width * sx, height: denominator.height * sy)
            guard box.width >= 7, box.height >= 7 else { return nil }
            let x0 = max(0, Int((box.minX - box.width * 0.3).rounded(.down)))
            let x1 = min(width, Int((box.maxX + box.width * 0.3).rounded(.up)))
            let y0 = max(1, Int((box.minY - box.height).rounded(.down)))
            let y1 = min(height - 1, Int((box.minY + box.height * 0.12).rounded(.up)))
            guard x1 > x0, y1 >= y0 else { return nil }
            let minimumBar = max(8, Int(box.width * 0.6))
            for y in stride(from: y1, through: y0, by: -1) {
                var start: Int?
                for x in x0...x1 {
                    let marked = x < x1 && ink[y * width + x] != 0
                    if marked && start == nil { start = x }
                    guard !marked, let left = start else { continue }
                    start = nil
                    let length = x - left
                    guard length >= minimumBar, CGFloat(length) <= box.width * 1.5,
                          CGFloat(left) <= box.midX, CGFloat(x) >= box.midX else { continue }
                    // A glyph's broad top stroke can also span the denominator.
                    // A fraction bar must be a thin horizontal strip, not a
                    // solid part of the denominator itself.
                    let maximumThickness = max(2, Int(box.height * 0.14))
                    var thickness = 1
                    for direction in [-1, 1] {
                        for distance in 1...maximumThickness {
                            let row = y + direction * distance
                            guard row >= 0, row < height else { break }
                            var filled = 0
                            for column in left..<x where ink[row * width + column] != 0 { filled += 1 }
                            guard filled * 5 >= length * 4 else { break }
                            thickness += 1
                        }
                    }
                    guard thickness <= maximumThickness else { continue }
                    let upper = max(0, y - Int(box.height * 1.25))
                    let lower = max(upper, y - 3)
                    var numerator = CGRect.null
                    var numeratorPixels = 0
                    for row in upper..<lower {
                        for column in left..<x where ink[row * width + column] != 0 {
                            numerator = numerator.union(CGRect(x: column, y: row, width: 1, height: 1))
                            numeratorPixels += 1
                        }
                    }
                    guard numeratorPixels >= 8, !numerator.isNull,
                          numerator.height >= max(4, box.height * 0.2) else { continue }
                    let complete = box.union(numerator).union(CGRect(x: left, y: y, width: length, height: 1))
                    return CGRect(x: complete.minX / sx, y: complete.minY / sy,
                                  width: complete.width / sx, height: complete.height / sy)
                }
            }
            return nil
        }

        /// Finds an OCR-omitted stacked fraction in a prose row. A thin short
        /// bar must have separate, centered numerator and denominator glyphs;
        /// hyphens, underlines and the crossbars of letters do not qualify.
        func inlineFractionRects(in normalized: CGRect) -> [CGRect] {
            let row = CGRect(x: normalized.minX * CGFloat(width), y: normalized.minY * CGFloat(height),
                             width: normalized.width * CGFloat(width), height: normalized.height * CGFloat(height))
            let x0 = max(0, Int(row.minX.rounded(.down)))
            let x1 = min(width, Int(row.maxX.rounded(.up)))
            let y0 = max(0, Int(row.minY.rounded(.down)))
            let y1 = min(height, Int(row.maxY.rounded(.up)))
            guard x1 > x0, y1 > y0 else { return [] }
            let maxLength = max(8, min(40, Int(row.height * 0.55)))
            var found: [CGRect] = []
            for y in y0..<y1 {
                var start: Int?
                for x in x0...x1 {
                    let marked = x < x1 && ink[y * width + x] != 0
                    if marked && start == nil { start = x }
                    guard !marked, let left = start else { continue }
                    start = nil
                    let length = x - left
                    guard length >= 7, length <= maxLength else { continue }
                    let padding = max(1, length / 5)
                    let low = max(x0, left - padding), high = min(x1, x + padding)
                    func operand(direction: Int) -> CGRect? {
                        var bounds = CGRect.null
                        var pixels = 0, emptyRows = 0, firstDistance = 0
                        for distance in 1...(length * 3) {
                            let yy = y + direction * distance
                            guard yy >= y0, yy < y1 else { break }
                            var count = 0
                            for xx in low..<high where ink[yy * width + xx] != 0 {
                                // Ignore the other row of an antialiased bar.
                                count += 1
                            }
                            if bounds.isNull && distance <= 2 && count >= length * 4 / 5 { continue }
                            if count == 0 {
                                if !bounds.isNull { emptyRows += 1; if emptyRows >= 2 { break } }
                                continue
                            }
                            if bounds.isNull { firstDistance = distance }
                            emptyRows = 0
                            for xx in low..<high where ink[yy * width + xx] != 0 {
                                bounds = bounds.union(CGRect(x: xx, y: yy, width: 1, height: 1))
                                pixels += 1
                            }
                        }
                        guard firstDistance >= 4, firstDistance <= length + 3,
                              pixels >= 8, !bounds.isNull,
                              bounds.height >= max(4, CGFloat(length) * 0.4),
                              bounds.height <= CGFloat(length) * 2.2,
                              bounds.width <= CGFloat(length) * 1.2,
                              abs(bounds.midX - CGFloat(left + x) / 2) <= CGFloat(length) * 0.3
                        else { return nil }
                        return bounds
                    }
                    guard let numerator = operand(direction: -1), let denominator = operand(direction: 1) else { continue }
                    let complete = numerator.union(denominator).union(CGRect(x: left, y: y, width: length, height: 1))
                    guard complete.height >= CGFloat(length) * 2,
                          !found.contains(where: { $0.intersects(complete) }) else { continue }
                    found.append(complete)
                }
            }
            return found.map {
                CGRect(x: $0.minX / CGFloat(width), y: $0.minY / CGFloat(height),
                       width: $0.width / CGFloat(width), height: $0.height / CGFloat(height))
            }
        }

        func recover(_ anchor: CGRect, prose: [CGRect], lineHeight: CGFloat, inline: Bool = false) -> CGRect {
            let sx = CGFloat(width), sy = CGFloat(height)
            let seed = CGRect(x: anchor.minX * sx, y: anchor.minY * sy,
                              width: anchor.width * sx, height: anchor.height * sy)
            let words = prose.map {
                proseInkBounds(CGRect(x: $0.minX * sx, y: $0.minY * sy,
                                      width: $0.width * sx, height: $0.height * sy))
            }
            let edgeSearch = max(2, min(6, lineHeight * 0.18))
            var top = max(0, seed.minY - (inline ? edgeSearch : lineHeight * 1.8))
            var bottom = min(sy, seed.maxY + (inline ? edgeSearch : lineHeight * 2.2))
            for word in words where word.maxX > seed.minX && word.minX < seed.maxX {
                // Capitals and ascenders begin a few pixels above other words
                // on the same prose row. Use the whole row's ink edge, so a
                // lower word cannot become a horizontal barrier mid-equation.
                let row = words.filter { other in
                    abs(other.midY - word.midY) < max(other.height, word.height) * 0.4
                }
                if word.maxY <= seed.minY {
                    top = max(top, (row.map(\.maxY).max() ?? word.maxY) + 2)
                }
                if word.minY >= seed.maxY {
                    bottom = min(bottom, (row.map(\.minY).min() ?? word.minY) - 2)
                }
            }
            // A partly recognized equation can continue far past its first
            // fraction. Let real prose and blank columns stop expansion;
            // a fixed multiple of the font size cuts later summation limits.
            var left: CGFloat = 0
            var right = sx
            for word in words where word.maxY > top && word.minY < bottom {
                if word.maxX <= seed.minX { left = max(left, word.maxX + 2) }
                if word.minX >= seed.maxX { right = min(right, word.minX - 2) }
            }
            let y0 = max(0, min(height - 1, Int(top.rounded(.up))))
            let y1 = max(y0 + 1, min(height, Int(bottom.rounded(.down))))
            let x0 = max(0, min(width - 1, Int(left.rounded(.up))))
            let x1 = max(x0 + 1, min(width, Int(right.rounded(.down))))
            var columns = [Int](repeating: 0, count: width)
            for y in y0..<y1 {
                for x in x0..<x1 { columns[x] += Int(ink[y * width + x]) }
            }
            // Include the whole equation's separated symbols, but stop before
            // another illustration or column after a large empty interval.
            let gapLimit = max(12, Int(lineHeight * 1.25))
            var low = max(x0, min(x1 - 1, Int(seed.minX)))
            var high = max(low + 1, min(x1, Int(seed.maxX.rounded(.up))))
            var gap = 0
            if low > x0 {
                for x in stride(from: low - 1, through: x0, by: -1) {
                    gap = columns[x] > 0 ? 0 : gap + 1
                    if gap > gapLimit { break }
                    if columns[x] > 0 { low = x }
                }
            }
            gap = 0
            if high < x1 {
                for x in high..<x1 {
                    gap = columns[x] > 0 ? 0 : gap + 1
                    if gap > gapLimit { break }
                    if columns[x] > 0 { high = x + 1 }
                }
            }
            var bounds = CGRect.null
            for y in y0..<y1 {
                for x in low..<high where ink[y * width + x] != 0 {
                    bounds = bounds.union(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
            guard !bounds.isNull else { return anchor }
            let recovered = CGRect(x: bounds.minX / sx, y: bounds.minY / sy,
                width: bounds.width / sx, height: bounds.height / sy)
            return inline ? anchor.union(recovered) : recovered
        }

        private func proseInkBounds(_ word: CGRect) -> CGRect {
            let x0 = max(0, min(width - 1, Int(word.minX.rounded(.down))))
            let x1 = max(x0 + 1, min(width, Int(word.maxX.rounded(.up))))
            let y0 = max(0, min(height - 1, Int(word.minY.rounded(.down))))
            let y1 = max(y0 + 1, min(height, Int(word.maxY.rounded(.up))))
            // Vision gives every word the height of a nearby inline fraction.
            // Such a box may reach into the next equation's superscript. Use
            // the dominant ink band of the word, excluding that detached ink.
            var bands: [(top: Int, bottom: Int, count: Int)] = []
            for y in y0..<y1 {
                let count = (x0..<x1).reduce(0) { $0 + Int(ink[y * width + $1]) }
                guard count > 0 else { continue }
                if let last = bands.indices.last, y - bands[last].bottom <= 2 {
                    bands[last].bottom = y
                    bands[last].count += count
                } else {
                    bands.append((y, y, count))
                }
            }
            guard let band = bands.max(by: { $0.count < $1.count }) else { return word }
            return CGRect(x: word.minX, y: CGFloat(band.top), width: word.width,
                          height: CGFloat(band.bottom - band.top + 1))
        }
    }

    private static func protectedRegion(
        _ region: ImageTranslationSourceRegion,
        id: String,
        line: CGRect,
        tokens: [ImageTranslationSourceToken],
        anchors: [Anchor],
        aspect: CGFloat
    ) -> ImageTranslationSourceRegion {
        let prose = tokens.filter { token in !anchors.contains { covers($0.rect, rect(token)) } }
        var output: [ImageTranslationSourceToken] = []
        for token in prose {
            let punctuation = !token.text.unicodeScalars.contains { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }
            // Vision can give "thumb" and ":" the exact same rectangle. They
            // form one translatable unit, not a protected punctuation blocker.
            if punctuation, let previous = output.last,
               overlap(rect(previous), rect(token)) > 0.7 {
                output.removeLast()
                let box = rect(previous).union(rect(token))
                output.append(sourceToken(previous.text + token.text, box: box))
            } else {
                output.append(sourceToken(token.text, box: rect(token),
                    protected: !punctuation && token.isProtected))
            }
        }
        output += anchors.enumerated().map { index, anchor in
            sourceToken("⟦math_\(index + 1)⟧", box: anchor.rect, mathematical: true)
        }
        output.sort { $0.x < $1.x }
        let complete = anchors.reduce(line) { $0.union($1.rect) }
        let layoutLine = CGRect(x: min(line.minX, complete.minX), y: line.minY,
                                width: max(line.maxX, complete.maxX) - min(line.minX, complete.minX), height: line.height)
        let sourceText = joined(output.map(\.text))
        return ImageTranslationSourceRegion(
            id: id, sourceText: sourceText,
            x: complete.minX, y: complete.minY, width: complete.width, height: complete.height,
            imageAspectRatio: Double(aspect), lineRects: [lineRect(layoutLine)],
            preservesListMarker: region.preservesListMarker,
            textRects: output.filter { !$0.isMathematical }.map { lineRect(rect($0)) },
            protectedRects: region.protectedRects.filter { sameLine(rect($0), line) } + anchors.map { lineRect($0.rect) },
            tokens: output, translationStrategy: anchors.isEmpty ? region.translationStrategy : .selective,
            codeRects: region.codeRects.filter { sameLine(rect($0), line) },
            kind: region.kind, textColor: region.textColor, backgroundColor: region.backgroundColor,
            alignment: region.alignment, weight: region.weight, fontSize: region.fontSize
        )
    }

    private static func hasMathSymbol(_ text: String) -> Bool {
        text.contains { "<>=≤≥≠≈≃~→←↔⇒⇔∞√∑∏∫∂∇±×÷∝∈∉⊂⊆⊃⊇∥|ℝℂℤ€⊥∀≫≪+−-—–#»".contains($0) }
            || text.range(of: #"^(?:R[PNDXOndkm0-9ªºᵈᵏⁿ⁰¹²³⁴⁵⁶⁷⁸⁹]{1,5}|V2?[fJw])$"#, options: .regularExpression) != nil
    }

    private static func isMathFunction(_ text: String) -> Bool {
        ["lim", "argmin", "argmax", "argminw", "argmaxw"].contains(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func hasOperand(_ text: String) -> Bool {
        text.contains { $0.isNumber || $0.isLetter || "∞".contains($0) }
    }

    private static func isMathAtom(_ text: String, allowsOCRRoot: Bool) -> Bool {
        if !text.isEmpty, text.allSatisfy({ ".,;:…".contains($0) }) { return true }
        let value = text.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
            .replacingOccurrences(of: "д", with: "d")
            .replacingOccurrences(of: "у", with: "y")
            .replacingOccurrences(of: "х", with: "x")
            .replacingOccurrences(of: "і", with: "i")
        guard !value.isEmpty else { return false }
        if value.allSatisfy({ "<>=≤≥≠≈≃~→←↔⇒⇔∞√∑∏∫∂∇±×÷∝∈∉⊂⊆⊃⊇∥ℝℂℤ€⊥∀≫≪/()[]{}_^+−-|*'\"′″⊤°—–#»«@".contains($0) || $0.isNumber }) { return true }
        if isVectorSpace(value) { return true }
        if isMathFunction(value) || ["range", "sin", "cos", "tan", "log", "exp"].contains(value) || isFractionToken(value) { return true }
        // Some PDFs give "wherew," one indivisible OCR box. When an
        // established expression reaches it, preserve that mixed box rather
        // than erase the variable. The connector remains English until its
        // glyphs can be separated reliably; it is never a seed by itself.
        if value.range(of: #"^[A-Za-z]?(?:where|with|when)[A-Za-z][0-9]{0,2}$"#,
                       options: .regularExpression) != nil { return true }
        if value.count == 1, value.first?.isLetter == true { return true }
        // Juxtaposition and subscripts are usually emitted as one word by
        // Vision (Xw, b1, 2N, RD). Accept them only inside an expression; a
        // standalone acronym or a sentence's short words are not math seeds.
        let proseWords: Set<String> = ["a", "am", "an", "and", "as", "at", "be", "by", "can", "do", "for", "go", "he", "hi", "if", "in", "is", "it", "may", "me", "my", "no", "not", "of", "oh", "ok", "on", "or", "our", "so", "the", "to", "up", "us", "use", "we", "you", "will", "all", "add", "did", "data", "try"]
        if proseWords.contains(value.lowercased()) { return false }
        // Lowercase juxtaposition is equally common (wx, xy, dx). An atom is
        // not a seed: it becomes protected only beside a mathematical relation
        // or inside a geometrically established displayed expression.
        if value.range(of: #"^[EΣ][wxyz][wxyz0-9]{1,5}$"#, options: .regularExpression) != nil { return true }
        if value.range(of: #"^[a-z]{2}$"#, options: .regularExpression) != nil { return true }
        // OCR joins a variable to its letter annotation (wRidge), or reads a
        // derivative as a short mixed-case product (aL). These are operands,
        // not seeds: ordinary camel-case words alone never create protection.
        if value.range(of: #"^[a-z](?:[A-Z]{1,2}|[A-Z][a-z]{2,8})$"#, options: .regularExpression) != nil { return true }
        if value.range(of: #"^(?:[d∂][A-Za-z]/[d∂][A-Za-z]|[d∂][wyxjib][d∂]?[wyxjib]?|[wWxXyYzZtTbBdDNRIJVl][wWxXyYzZtTbBdDnNrRiIjJkKlLvVaAcC0-9]{1,6})$"#, options: .regularExpression) != nil { return true }
        if value.range(of: #"^(?:[\p{L}]{1,3}[\p{N}]+[\p{L}\p{N}]*|[\p{N}]+[\p{L}][\p{L}\p{N}]*|[A-Z][A-Za-z]{1,2})$"#, options: .regularExpression) != nil { return true }
        if value.range(of: #"^(?:[Il|]{2,}[a-z]|[a-z][Il|]{2,})$"#, options: .regularExpression) != nil { return true }
        if allowsOCRRoot, value.range(of: #"^V[\p{L}\p{N}]$"#, options: .regularExpression) != nil { return true }
        return value.range(of: #"^[\p{L}](?:[_^][\p{L}\p{N}]+|[₀-₉⁰-⁹])+?$"#, options: .regularExpression) != nil
            || (hasMathSymbol(value) && value.filter(\.isLetter).count <= 3)
    }

    private static func isSingleVariable(_ text: String) -> Bool {
        let value = variableName(text)
        return value.count == 1 && value.first?.isLetter == true && value != "a" && value != "A" && value != "I"
    }

    private static func variableName(_ text: String) -> String {
        text.trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
    }

    private static func adjacent(_ lhs: ImageTranslationTokenRect, _ rhs: ImageTranslationTokenRect, aspect: CGFloat) -> Bool {
        let left = rect(lhs), right = rect(rhs)
        return sameLine(left, right)
            && right.minX - left.maxX < max(left.height, right.height) * 1.0 / aspect
    }

    private static func sameLine(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let shared = min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY)
        return shared > min(lhs.height, rhs.height) * 0.28
            && abs(lhs.midY - rhs.midY) < max(lhs.height, rhs.height) * 0.72
    }

    private static func covers(_ outer: CGRect, _ inner: CGRect) -> Bool {
        outer.contains(CGPoint(x: inner.midX, y: inner.midY)) || overlap(outer, inner) > 0.62
    }

    private static func overlap(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height / max(0.000_000_1, rhs.width * rhs.height)
    }

    private static func merged(_ anchors: [Anchor]) -> [Anchor] {
        var result: [Anchor] = []
        for anchor in anchors.sorted(by: { $0.rect.minX < $1.rect.minX }) {
            if let index = result.firstIndex(where: { overlap($0.rect, anchor.rect) > 0.5 || overlap(anchor.rect, $0.rect) > 0.5 }) {
                result[index].rect = result[index].rect.union(anchor.rect)
                result[index].text += " " + anchor.text
                result[index].isDisplay = result[index].isDisplay || anchor.isDisplay
            } else { result.append(anchor) }
        }
        return result
    }

    private static func lines(in region: ImageTranslationSourceRegion) -> [CGRect] {
        region.lineRects.isEmpty ? [CGRect(x: region.x, y: region.y, width: region.width, height: region.height)] : region.lineRects.map(rect)
    }

    private static func joined(_ texts: [String]) -> String {
        texts.joined(separator: " ")
            .replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
    }

    private static func sourceToken(_ text: String, box: CGRect, protected: Bool = false, mathematical: Bool = false) -> ImageTranslationSourceToken {
        ImageTranslationSourceToken(text: text, x: box.minX, y: box.minY, width: box.width, height: box.height,
                                    isProtected: protected, isMathematical: mathematical)
    }

    private static func lineRect(_ rect: CGRect) -> ImageTranslationLineRect {
        ImageTranslationLineRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }

    private static func rect(_ value: ImageTranslationLineRect) -> CGRect {
        CGRect(x: value.x, y: value.y, width: value.width, height: value.height)
    }

    private static func rect(_ value: ImageTranslationTokenRect) -> CGRect {
        CGRect(x: value.x, y: value.y, width: value.width, height: value.height)
    }

    private static func rect(_ value: ImageTranslationSourceToken) -> CGRect {
        CGRect(x: value.x, y: value.y, width: value.width, height: value.height)
    }
}
