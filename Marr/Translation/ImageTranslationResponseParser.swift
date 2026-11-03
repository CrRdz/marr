import Foundation

enum ImageTranslationResponseParser {
    static func parse(_ response: String) -> [ImageTranslationBlock] {
        let stripped = stripCodeFence(response.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !stripped.isEmpty else {
            return []
        }

        let extracted = extractedJSON(from: stripped)
        for json in extracted.candidates {
            if let data = json.data(using: .utf8), let decoded = decodeBlocks(from: data) {
                return decoded
            }
        }
        // A truncated structured response is not translated prose. Painting
        // its JSON over the screenshot would destroy the still-useful source.
        guard !extracted.hasStructuredContent else { return [] }

        return [
            ImageTranslationBlock(
                text: stripped,
                x: 0.04,
                y: 0.04,
                width: 0.92,
                height: 0.92,
                alignment: "center"
            )
        ]
        .filter { !$0.text.isEmpty }
    }

    static func parseReplacements(_ response: String) -> [ImageTranslationReplacement] {
        let stripped = stripCodeFence(response.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !stripped.isEmpty else { return [] }

        let decoder = JSONDecoder()
        for json in extractedJSON(from: stripped).candidates {
            guard let data = json.data(using: .utf8) else { continue }
            if let payload = try? decoder.decode(ImageTranslationReplacementPayload.self, from: data),
               payload.translations != nil || payload.replacements != nil || payload.items != nil {
                return uniqueReplacements(payload.translationReplacements)
            }
            if let array = try? decoder.decode(LossyTranslationArray<ImageTranslationReplacementDTO>.self, from: data) {
                let replacements = uniqueReplacements(array.elements.compactMap(\.replacement))
                if !replacements.isEmpty || json.filter({ !$0.isWhitespace }) == "[]" { return replacements }
            }
        }

        return []
    }

    private static func uniqueReplacements(_ replacements: [ImageTranslationReplacement]) -> [ImageTranslationReplacement] {
        var result: [ImageTranslationReplacement] = []
        var indexes: [String: Int] = [:]
        for replacement in replacements {
            guard let index = indexes[replacement.id] else {
                indexes[replacement.id] = result.count
                result.append(replacement)
                continue
            }
            let existing = result[index]
            // Some models emit an empty placeholder followed by the real item.
            // Keep stable source order and never let a later empty item replace
            // a usable translation. Conflicting nonempty items keep the first.
            if existing.text.isEmpty && existing.segments.isEmpty,
               !replacement.text.isEmpty || !replacement.segments.isEmpty {
                result[index] = replacement
            } else if existing.text == replacement.text,
                      existing.segments == replacement.segments,
                      existing.alignments.isEmpty, !replacement.alignments.isEmpty {
                result[index] = replacement
            }
        }
        return result
    }

    private static func decodeBlocks(from data: Data) -> [ImageTranslationBlock]? {
        let decoder = JSONDecoder()

        if let payload = try? decoder.decode(ImageTranslationPayload.self, from: data),
           payload.translations != nil || payload.blocks != nil {
            return payload.translationBlocks
        }

        if let array = try? decoder.decode(LossyTranslationArray<ImageTranslationBlockDTO>.self, from: data) {
            let blocks = array.elements.compactMap(\.translationBlock)
            if !blocks.isEmpty || String(data: data, encoding: .utf8)?.filter({ !$0.isWhitespace }) == "[]" { return blocks }
        }

        return nil
    }

    private static func extractedJSON(from response: String) -> (candidates: [String], hasStructuredContent: Bool) {
        var candidates: [String] = []
        var structured = false
        var cursor = response.startIndex
        while cursor < response.endIndex {
            let opener = response[cursor]
            guard opener == "{" || opener == "[" else {
                cursor = response.index(after: cursor)
                continue
            }
            let next = response[response.index(after: cursor)...].first { !$0.isWhitespace }
            // A translation payload is an object or an array of records.
            // Ordinary prose such as [API], [1, 2] or {x, y} stays prose.
            let looksStructured = opener == "{" && (next == "\"" || next == "}" || next == nil)
                || opener == "[" && (next == "{" || next == "[" || next == "]" || next == nil)
            guard looksStructured else {
                cursor = response.index(after: cursor)
                continue
            }
            structured = true
            var closers: [Character] = []
            var quoted = false, escaped = false
            var end: String.Index?
            for index in response.indices[cursor...] {
                let character = response[index]
                if quoted {
                    if escaped { escaped = false }
                    else if character == "\\" { escaped = true }
                    else if character == "\"" { quoted = false }
                    continue
                }
                switch character {
                case "\"": quoted = true
                case "{": closers.append("}")
                case "[": closers.append("]")
                case "}", "]":
                    guard closers.popLast() == character else { return (candidates, structured) }
                    if closers.isEmpty { end = index }
                default: break
                }
                if end != nil { break }
            }
            // Never salvage a nested array out of a truncated outer response.
            guard let end else { break }
            candidates.append(String(response[cursor...end]))
            cursor = response.index(after: end)
        }
        return (candidates, structured)
    }

    private static func stripCodeFence(_ response: String) -> String {
        guard response.hasPrefix("```") else {
            return response
        }

        var lines = response.components(separatedBy: .newlines)
        if !lines.isEmpty {
            lines.removeFirst()
        }
        if lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) == "```" {
            lines.removeLast()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A malformed sibling must not discard the valid translations in the same
/// model response. Invalid entries stay absent and can be requested again.
private struct LossyTranslationArray<Element: Decodable>: Decodable {
    let elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [Element] = []
        while !container.isAtEnd {
            let item = try container.superDecoder()
            if let value = try? Element(from: item) { result.append(value) }
        }
        elements = result
    }
}

private struct ImageTranslationPayload: Decodable {
    let translations: LossyTranslationArray<ImageTranslationBlockDTO>?
    let blocks: LossyTranslationArray<ImageTranslationBlockDTO>?

    var translationBlocks: [ImageTranslationBlock] {
        (translations?.elements ?? blocks?.elements ?? []).compactMap(\.translationBlock)
    }
}

private struct ImageTranslationReplacementPayload: Decodable {
    let translations: LossyTranslationArray<ImageTranslationReplacementDTO>?
    let replacements: LossyTranslationArray<ImageTranslationReplacementDTO>?
    let items: LossyTranslationArray<ImageTranslationReplacementDTO>?

    var translationReplacements: [ImageTranslationReplacement] {
        (translations?.elements ?? replacements?.elements ?? items?.elements ?? []).compactMap(\.replacement)
    }
}

private struct ImageTranslationReplacementDTO: Decodable {
    let id: String?
    let text: String?
    let translation: String?
    let content: String?
    let targetMarkdown: String?
    let markdown: String?
    let kind: String?
    let type: String?
    let segments: LossyTranslationArray<ImageTranslationReplacementSegmentDTO>?
    let alignments: LossyTranslationArray<ImageTranslationAlignmentDTO>?

    private enum CodingKeys: String, CodingKey {
        case id, text, translation, content, targetMarkdown, markdown, kind, type, segments, alignments
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id)
        text = try values.decodeIfPresent(String.self, forKey: .text)
        translation = try values.decodeIfPresent(String.self, forKey: .translation)
        content = try values.decodeIfPresent(String.self, forKey: .content)
        targetMarkdown = try values.decodeIfPresent(String.self, forKey: .targetMarkdown)
        markdown = try values.decodeIfPresent(String.self, forKey: .markdown)
        segments = try values.decodeIfPresent(LossyTranslationArray<ImageTranslationReplacementSegmentDTO>.self, forKey: .segments)
        // Style and optional highlight alignment cannot invalidate the actual
        // translated text or correctly indexed replacement segments.
        kind = try? values.decodeIfPresent(String.self, forKey: .kind)
        type = try? values.decodeIfPresent(String.self, forKey: .type)
        alignments = try? values.decodeIfPresent(LossyTranslationArray<ImageTranslationAlignmentDTO>.self, forKey: .alignments)
    }

    var replacement: ImageTranslationReplacement? {
        guard let id else {
            return nil
        }

        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedText = (targetMarkdown ?? markdown ?? text ?? translation ?? content ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedSegments = (segments?.elements ?? []).compactMap(\.replacementSegment)
        let resolvedAlignments = (alignments?.elements ?? []).compactMap(\.alignment)
        guard !trimmedID.isEmpty, !trimmedText.isEmpty || segments != nil else {
            return nil
        }

        return ImageTranslationReplacement(
            id: trimmedID,
            text: trimmedText,
            kind: kind ?? type,
            segments: resolvedSegments,
            alignments: resolvedAlignments
        )
    }
}

private struct ImageTranslationAlignmentDTO: Decodable {
    let tokenStart: Int?
    let tokenEnd: Int?
    let start: Int?
    let end: Int?
    let targetText: String?
    let text: String?

    var alignment: ImageTranslationAlignment? {
        guard
            let resolvedStart = tokenStart ?? start,
            let resolvedEnd = tokenEnd ?? end,
            let resolvedText = targetText ?? text
        else {
            return nil
        }

        let trimmedText = resolvedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard resolvedStart >= 0, resolvedEnd > resolvedStart, !trimmedText.isEmpty else {
            return nil
        }
        return ImageTranslationAlignment(
            tokenStart: resolvedStart,
            tokenEnd: resolvedEnd,
            targetText: trimmedText
        )
    }
}

private struct ImageTranslationReplacementSegmentDTO: Decodable {
    let tokenStart: Int?
    let tokenEnd: Int?
    let start: Int?
    let end: Int?
    let text: String?
    let translation: String?
    let targetMarkdown: String?
    let markdown: String?

    var replacementSegment: ImageTranslationReplacementSegment? {
        guard
            let resolvedStart = tokenStart ?? start,
            let resolvedEnd = tokenEnd ?? end,
            let rawText = targetMarkdown ?? markdown ?? text ?? translation
        else {
            return nil
        }

        let trimmedText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard resolvedStart >= 0, resolvedEnd > resolvedStart, !trimmedText.isEmpty else {
            return nil
        }
        return ImageTranslationReplacementSegment(
            tokenStart: resolvedStart,
            tokenEnd: resolvedEnd,
            text: trimmedText
        )
    }
}

private struct ImageTranslationBlockDTO: Decodable {
    let text: String?
    let translation: String?
    let content: String?
    let targetMarkdown: String?
    let markdown: String?
    let x: Double?
    let y: Double?
    let width: Double?
    let height: Double?
    let kind: String?
    let type: String?
    let x1: Double?
    let y1: Double?
    let x2: Double?
    let y2: Double?
    let bbox: [Double]?
    let box: [Double]?
    let rect: ImageTranslationRectDTO?
    let lineRects: [ImageTranslationRectDTO]?
    let lines: [ImageTranslationRectDTO]?
    let textRects: [ImageTranslationRectDTO]?
    let glyphRects: [ImageTranslationRectDTO]?
    let eraseRects: [ImageTranslationRectDTO]?
    let protectedRects: [ImageTranslationRectDTO]?
    let codeRects: [ImageTranslationTokenRectDTO]?
    let tokens: [ImageTranslationTokenRectDTO]?
    let textColor: String?
    let foregroundColor: String?
    let color: String?
    let backgroundColor: String?
    let bgColor: String?
    let alignment: String?
    let fontSize: Double?
    let weight: String?
    let fontWeight: String?

    private enum CodingKeys: String, CodingKey {
        case text, translation, content, targetMarkdown, markdown
        case x, y, width, height, x1, y1, x2, y2, bbox, box, rect
        case lineRects, lines, textRects, glyphRects, eraseRects, protectedRects, codeRects, tokens
        case kind, type, textColor, foregroundColor, color, backgroundColor, bgColor, alignment, fontSize, weight, fontWeight
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        text = try values.decodeIfPresent(String.self, forKey: .text)
        translation = try values.decodeIfPresent(String.self, forKey: .translation)
        content = try values.decodeIfPresent(String.self, forKey: .content)
        targetMarkdown = try values.decodeIfPresent(String.self, forKey: .targetMarkdown)
        markdown = try values.decodeIfPresent(String.self, forKey: .markdown)
        // Geometry controls which source pixels may be replaced. Keep its
        // existing type validation strict rather than guessing malformed values.
        x = try values.decodeIfPresent(Double.self, forKey: .x)
        y = try values.decodeIfPresent(Double.self, forKey: .y)
        width = try values.decodeIfPresent(Double.self, forKey: .width)
        height = try values.decodeIfPresent(Double.self, forKey: .height)
        x1 = try values.decodeIfPresent(Double.self, forKey: .x1)
        y1 = try values.decodeIfPresent(Double.self, forKey: .y1)
        x2 = try values.decodeIfPresent(Double.self, forKey: .x2)
        y2 = try values.decodeIfPresent(Double.self, forKey: .y2)
        bbox = try values.decodeIfPresent([Double].self, forKey: .bbox)
        box = try values.decodeIfPresent([Double].self, forKey: .box)
        rect = try values.decodeIfPresent(ImageTranslationRectDTO.self, forKey: .rect)
        lineRects = try values.decodeIfPresent([ImageTranslationRectDTO].self, forKey: .lineRects)
        lines = try values.decodeIfPresent([ImageTranslationRectDTO].self, forKey: .lines)
        textRects = try values.decodeIfPresent([ImageTranslationRectDTO].self, forKey: .textRects)
        glyphRects = try values.decodeIfPresent([ImageTranslationRectDTO].self, forKey: .glyphRects)
        eraseRects = try values.decodeIfPresent([ImageTranslationRectDTO].self, forKey: .eraseRects)
        protectedRects = try values.decodeIfPresent([ImageTranslationRectDTO].self, forKey: .protectedRects)
        codeRects = try values.decodeIfPresent([ImageTranslationTokenRectDTO].self, forKey: .codeRects)
        tokens = try values.decodeIfPresent([ImageTranslationTokenRectDTO].self, forKey: .tokens)
        kind = try? values.decodeIfPresent(String.self, forKey: .kind)
        type = try? values.decodeIfPresent(String.self, forKey: .type)
        textColor = try? values.decodeIfPresent(String.self, forKey: .textColor)
        foregroundColor = try? values.decodeIfPresent(String.self, forKey: .foregroundColor)
        color = try? values.decodeIfPresent(String.self, forKey: .color)
        backgroundColor = try? values.decodeIfPresent(String.self, forKey: .backgroundColor)
        bgColor = try? values.decodeIfPresent(String.self, forKey: .bgColor)
        alignment = try? values.decodeIfPresent(String.self, forKey: .alignment)
        fontSize = try? values.decodeIfPresent(Double.self, forKey: .fontSize)
        weight = try? values.decodeIfPresent(String.self, forKey: .weight)
        fontWeight = try? values.decodeIfPresent(String.self, forKey: .fontWeight)
    }

    var translationBlock: ImageTranslationBlock? {
        guard
            let rawText = targetMarkdown ?? markdown ?? text ?? translation ?? content,
            !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }

        let originX = x ?? x1 ?? rect?.x ?? valuesFromArray?.x ?? 0
        let originY = y ?? y1 ?? rect?.y ?? valuesFromArray?.y ?? 0
        let resolvedWidth = width ?? rect?.width ?? rect?.w ?? valuesFromArray?.width ?? resolvedExtent(from: x2, origin: originX)
        let resolvedHeight = height ?? rect?.height ?? rect?.h ?? valuesFromArray?.height ?? resolvedExtent(from: y2, origin: originY)

        return ImageTranslationBlock(
            text: rawText,
            x: originX,
            y: originY,
            width: resolvedWidth,
            height: resolvedHeight,
            lineRects: resolvedLineRects,
            textRects: resolvedTextRects,
            protectedRects: resolvedProtectedRects,
            codeRects: resolvedCodeRects,
            kind: kind ?? type,
            textColor: textColor ?? foregroundColor ?? color,
            backgroundColor: backgroundColor ?? bgColor,
            alignment: alignment,
            weight: weight ?? fontWeight,
            fontSize: fontSize
        )
    }

    private var resolvedLineRects: [ImageTranslationLineRect] {
        (lineRects ?? lines ?? []).compactMap(\.lineRect)
    }

    private var resolvedTextRects: [ImageTranslationLineRect] {
        (textRects ?? glyphRects ?? eraseRects ?? []).compactMap(\.lineRect)
    }

    private var resolvedProtectedRects: [ImageTranslationLineRect] {
        (protectedRects ?? []).compactMap(\.lineRect)
    }

    private var resolvedCodeRects: [ImageTranslationTokenRect] {
        (codeRects ?? tokens ?? []).compactMap(\.tokenRect)
    }

    private var valuesFromArray: (x: Double, y: Double, width: Double, height: Double)? {
        let values = bbox ?? box
        guard let values, values.count >= 4 else {
            return nil
        }
        return (values[0], values[1], values[2], values[3])
    }

    private func resolvedExtent(from end: Double?, origin: Double) -> Double {
        guard let end else {
            return 0.92
        }
        return max(0.02, end - origin)
    }
}

private struct ImageTranslationRectDTO: Decodable {
    let x: Double?
    let y: Double?
    let width: Double?
    let height: Double?
    let w: Double?
    let h: Double?

    var lineRect: ImageTranslationLineRect? {
        let resolvedWidth = width ?? w
        let resolvedHeight = height ?? h
        guard let x, let y, let resolvedWidth, let resolvedHeight else {
            return nil
        }

        return ImageTranslationLineRect(
            x: x,
            y: y,
            width: resolvedWidth,
            height: resolvedHeight
        )
    }
}

private struct ImageTranslationTokenRectDTO: Decodable {
    let text: String?
    let sourceText: String?
    let x: Double?
    let y: Double?
    let width: Double?
    let height: Double?
    let w: Double?
    let h: Double?
    let rect: ImageTranslationRectDTO?

    var tokenRect: ImageTranslationTokenRect? {
        let resolvedText = text ?? sourceText ?? ""
        let originX = x ?? rect?.x
        let originY = y ?? rect?.y
        let resolvedWidth = width ?? w ?? rect?.width ?? rect?.w
        let resolvedHeight = height ?? h ?? rect?.height ?? rect?.h
        guard let originX, let originY, let resolvedWidth, let resolvedHeight else {
            return nil
        }

        return ImageTranslationTokenRect(
            text: resolvedText,
            x: originX,
            y: originY,
            width: resolvedWidth,
            height: resolvedHeight
        )
    }
}
