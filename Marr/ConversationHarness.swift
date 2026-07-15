import Foundation
import Combine
import MarrCore

struct ImageTranslationBlock: Equatable, Sendable {
    let text: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let lineRects: [ImageTranslationLineRect]
    let textRects: [ImageTranslationLineRect]
    let protectedRects: [ImageTranslationLineRect]
    let trailingAttachments: [ImageTranslationLineRect]
    let translationStrategy: ImageTranslationStrategy
    let codeRects: [ImageTranslationTokenRect]
    let kind: String?
    let textColor: String?
    let backgroundColor: String?
    let alignment: String?
    let weight: String?
    let fontSize: Double?

    init(
        text: String,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        lineRects: [ImageTranslationLineRect] = [],
        textRects: [ImageTranslationLineRect] = [],
        protectedRects: [ImageTranslationLineRect] = [],
        trailingAttachments: [ImageTranslationLineRect] = [],
        translationStrategy: ImageTranslationStrategy = .block,
        codeRects: [ImageTranslationTokenRect] = [],
        kind: String? = nil,
        textColor: String? = nil,
        backgroundColor: String? = nil,
        alignment: String? = nil,
        weight: String? = nil,
        fontSize: Double? = nil
    ) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.x = Self.clamp(x)
        self.y = Self.clamp(y)
        self.width = Self.clamp(width, lowerBound: 0.004)
        self.height = Self.clamp(height, lowerBound: 0.006)
        self.lineRects = lineRects
        self.textRects = textRects
        self.protectedRects = protectedRects
        self.trailingAttachments = trailingAttachments
        self.translationStrategy = translationStrategy
        self.codeRects = codeRects
        self.kind = kind?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.textColor = textColor
        self.backgroundColor = backgroundColor
        self.alignment = alignment
        self.weight = weight
        self.fontSize = fontSize
    }

    private static func clamp(_ value: Double, lowerBound: Double = 0, upperBound: Double = 1) -> Double {
        min(max(value, lowerBound), upperBound)
    }
}

struct ImageTranslationLineRect: Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
        self.width = min(max(width, 0.004), 1)
        self.height = min(max(height, 0.004), 1)
    }
}

struct ImageTranslationTokenRect: Equatable, Sendable {
    let text: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(text: String, x: Double, y: Double, width: Double, height: Double) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
        self.width = min(max(width, 0.004), 1)
        self.height = min(max(height, 0.004), 1)
    }
}

struct ImageTranslationSourceToken: Equatable, Sendable {
    let text: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let isProtected: Bool

    init(
        text: String,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        isProtected: Bool = false
    ) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
        self.width = min(max(width, 0.004), 1)
        self.height = min(max(height, 0.004), 1)
        self.isProtected = isProtected
    }
}

enum ImageTranslationStrategy: String, Equatable, Sendable {
    case block
    case selective
}

struct ImageTranslationSourceRegion: Equatable, Sendable, Identifiable {
    let id: String
    let sourceText: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let lineRects: [ImageTranslationLineRect]
    let textRects: [ImageTranslationLineRect]
    let protectedRects: [ImageTranslationLineRect]
    let tokens: [ImageTranslationSourceToken]
    let translationStrategy: ImageTranslationStrategy
    let codeRects: [ImageTranslationTokenRect]
    let kind: String?
    let textColor: String?
    let backgroundColor: String?
    let alignment: String?
    let weight: String?
    let fontSize: Double?

    init(
        id: String,
        sourceText: String,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        lineRects: [ImageTranslationLineRect] = [],
        textRects: [ImageTranslationLineRect] = [],
        protectedRects: [ImageTranslationLineRect] = [],
        tokens: [ImageTranslationSourceToken] = [],
        translationStrategy: ImageTranslationStrategy = .block,
        codeRects: [ImageTranslationTokenRect] = [],
        kind: String? = nil,
        textColor: String? = nil,
        backgroundColor: String? = nil,
        alignment: String? = "left",
        weight: String? = nil,
        fontSize: Double? = nil
    ) {
        self.id = id
        self.sourceText = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
        self.width = min(max(width, 0.004), 1)
        self.height = min(max(height, 0.006), 1)
        self.lineRects = lineRects
        self.textRects = textRects
        self.protectedRects = protectedRects
        self.tokens = tokens
        self.translationStrategy = translationStrategy
        self.codeRects = codeRects
        self.kind = kind?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.textColor = textColor
        self.backgroundColor = backgroundColor
        self.alignment = alignment
        self.weight = weight
        self.fontSize = fontSize
    }

    func translationBlock(text: String, kind replacementKind: String? = nil) -> ImageTranslationBlock {
        let isSelective = translationStrategy == .selective
        return ImageTranslationBlock(
            text: text,
            x: x,
            y: y,
            width: width,
            height: height,
            lineRects: lineRects,
            textRects: textRects,
            protectedRects: isSelective ? protectedRects : [],
            trailingAttachments: [],
            translationStrategy: translationStrategy,
            codeRects: codeRects,
            kind: replacementKind ?? kind,
            textColor: textColor,
            backgroundColor: backgroundColor,
            alignment: alignment,
            weight: weight,
            fontSize: fontSize
        )
    }
}

struct ImageTranslationReplacement: Equatable, Sendable {
    let id: String
    let text: String
    let kind: String?
    let segments: [ImageTranslationReplacementSegment]

    init(
        id: String,
        text: String,
        kind: String? = nil,
        segments: [ImageTranslationReplacementSegment] = []
    ) {
        self.id = id
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.kind = kind?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.segments = segments
    }
}

struct ImageTranslationReplacementSegment: Equatable, Sendable {
    let tokenStart: Int
    let tokenEnd: Int
    let text: String

    init(tokenStart: Int, tokenEnd: Int, text: String) {
        self.tokenStart = tokenStart
        self.tokenEnd = tokenEnd
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ImageTranslationPrompt {
    static let systemPrompt = """
    You translate visible screenshot text into Simplified Chinese for in-place image replacement.

    Return only valid compact JSON with this exact shape:
    {"translations":[{"text":"translated text","x":0.0,"y":0.0,"width":0.2,"height":0.1,"textColor":"#111111","backgroundColor":"#ffffff","alignment":"center","weight":"regular","fontSize":0.04}]}

    Coordinates and fontSize are normalized from the image's top-left corner and image height.

    Coverage rules:
    - Translate every readable natural-language word, heading, bullet item, caption, and sentence fragment. Do not omit partially visible readable text unless it is cut off so badly that the text cannot be known.
    - Do not translate or redraw text that is already Simplified Chinese, mixed Chinese identity metadata, usernames, numeric badges, or decorative icon glyphs.
    - Preserve personal names, account handles, product names, and brand names exactly; translate only their surrounding natural-language description.
    - Translate faithfully enough to preserve technical meaning. Do not summarize, shorten, merge unrelated bullets, or invent context.
    - Use idiomatic technical Chinese: in research contexts prefer "论文" or "出版成果" for "publications", and express "owns turns" as "管理轮次" or "负责轮次" rather than literal possession.
    - Split long paragraphs and bullet items into line-level items. Never return one large rectangle for an entire paragraph when the source uses multiple visual lines.
    - Split each visual line again whenever styling changes, especially inline code, highlighted terms, badges, keyboard keys, links, and grey rounded code chips.
    - Keep source code identifiers, class names, API names, file names, command names, and symbols exactly as written, but include them as their own tight blocks if they sit inside highlighted or code-styled backgrounds.
    - Translate the natural-language text around those identifiers accurately and completely.

    Box and style rules:
    - Use tight rectangles around the actual glyphs or the highlighted chip that contains the glyphs. Do not extend a block across blank space, separators, underlines, selection highlights, or unrelated neighboring text.
    - Do not create blocks for horizontal rules, bullets by themselves, cursor marks, shadows, decorative highlights, or empty highlighted bars.
    - Match the original foreground color, local background color, alignment, weight, and approximate font size. For highlighted/code blocks, use the chip's local background color and the original identifier text.
    - Preserve useful line breaks inside a block only when the original visual group is multi-line.

    Output rules:
    - Put only replacement text in "text"; do not include labels, source/target prefixes, markdown, explanations, or commentary.
    - If no readable text is present, return {"translations":[]}.
    """

    static let regionSystemPrompt = """
    You classify and translate tokenized OCR layout regions from a screenshot into Simplified Chinese for natural in-place image replacement.

    Return only valid compact JSON with this exact shape:
    {"translations":[{"id":"r001","strategy":"block","kind":"paragraph","targetMarkdown":"complete translated block","segments":[]},{"id":"r002","strategy":"selective","kind":"heading","segments":[{"tokenStart":2,"tokenEnd":4,"targetMarkdown":"translated label"}]}]}

    Rules:
    - Return exactly one item for every provided id. Do not omit ids, merge ids, split ids, or invent ids.
    - Follow the supplied strategy for every region. Never change a region from block to selective or vice versa.
    - The preserve flag is meaningful only for strategy=selective. For strategy=block, translate every natural-language token even when it begins with a capital letter. Ordinary sentence-initial words such as "Screenshots", "Long", and "Failed" are not names.
    - For strategy=block, translate the complete text as one coherent targetMarkdown value and return an empty segments array. Use fluent, idiomatic Simplified Chinese rather than word-for-word English syntax. Preserve only genuine personal names, products, brands, acronyms, and code identifiers. Do not insert visual line breaks; the renderer will reflow the complete translation.
    - For strategy=block, translate English articles, verbs, adjectives, and sentence tails completely. Apart from genuine names, brands, acronyms, and code identifiers, targetMarkdown must not contain leftover English natural-language words.
    - Translate English hyphenated compounds idiomatically. Do not mechanically preserve a hyphen in phrases such as "early-stage" when natural Chinese does not use one.
    - Prefer context-appropriate technical Chinese: translate "publications" as "论文" or "出版成果" when discussing research, and translate phrases such as "owns turns" idiomatically as "管理轮次" or "负责轮次", never as a literal possession.
    - For strategy=block with codeRects, keep those exact code tokens unchanged, in their original order, and wrap only those tokens in single backticks. The renderer will erase the source chips and recreate them in the translated text flow.
    - For strategy=selective, omit targetMarkdown at item level and return only the contiguous token ranges that should change.
    - Token indexes are zero-based. tokenStart is inclusive and tokenEnd is exclusive.
    - Selective segments must be ordered, non-overlapping, and inside the supplied token array.
    - Do not include preserved tokens inside a translated segment. Tokens marked preserve=true must never appear in a segment.
    - Personal names, account handles, usernames, organizations, product names, brand names, code/API identifiers, acronyms, numbers, badges, separators, and decorative glyphs must remain as original screenshot pixels. Omit them from segments instead of copying them into targetMarkdown.
    - If preserved content occurs between two translatable ranges, return two segments so the renderer can leave the original pixels between them untouched.
    - If an entire selective region should remain unchanged, return an empty segments array.
    - Translate each returned range using the full region text and screenshot as context. Keep the translation in the same source order so it fits back into that token range.
    - Treat each segment targetMarkdown as input for a local Markdown/layout renderer. Do not describe layout, colors, labels, or UI behavior in text.
    - Keep or correct "kind" using one of: title, heading, paragraph, list_item, caption, code.
    - Translate faithfully enough to preserve technical meaning. Do not summarize, shorten, merge unrelated bullets, or invent context.
    - Do not create sticker-like translations, overlay labels, background panels, captions, or explanatory notes. The renderer will place the replacement text back into the original image.
    - Put only translated replacement text in each segment's targetMarkdown; do not repeat preserved source tokens or include explanations.
    """

    static func request(for image: PickedImage) -> VisionRequest {
        let asset = ConversationImageAsset(image: image)
        return VisionRequest(
            systemPrompt: systemPrompt,
            messages: [
                VisionMessage(
                    role: .user,
                    content: [
                        .image(asset),
                        .text("Translate all readable text in this screenshot into Simplified Chinese for in-place replacement. Return complete, line-level, style-aware blocks. Preserve inline code identifiers exactly in their own tight blocks. Output only the JSON object.")
                    ]
                )
            ]
        )
    }

    static func request(for image: PickedImage, regions: [ImageTranslationSourceRegion]) -> VisionRequest {
        let asset = ConversationImageAsset(image: image)
        return VisionRequest(
            systemPrompt: regionSystemPrompt,
            messages: [
                VisionMessage(
                    role: .user,
                    content: [
                        .image(asset),
                        .text(regionPromptText(regions))
                    ]
                )
            ]
        )
    }

    private static func regionPromptText(_ regions: [ImageTranslationSourceRegion]) -> String {
        let payload = regions.map { region in
            [
                "id": region.id,
                "text": region.sourceText,
                "kind": region.kind ?? "paragraph",
                "strategy": region.translationStrategy.rawValue,
                "bbox": [
                    "x": region.x,
                    "y": region.y,
                    "width": region.width,
                    "height": region.height
                ],
                "lineRects": region.lineRects.map { lineRect in
                    [
                        "x": lineRect.x,
                        "y": lineRect.y,
                        "width": lineRect.width,
                        "height": lineRect.height
                    ]
                },
                "textRects": region.textRects.map { textRect in
                    [
                        "x": textRect.x,
                        "y": textRect.y,
                        "width": textRect.width,
                        "height": textRect.height
                    ]
                },
                "tokens": region.tokens.enumerated().map { index, token in
                    [
                        "index": index,
                        "text": token.text,
                        "preserve": region.translationStrategy == .selective
                            && token.isProtected,
                        "bbox": [
                            "x": token.x,
                            "y": token.y,
                            "width": token.width,
                            "height": token.height
                        ]
                    ] as [String: Any]
                },
                "codeRects": region.codeRects.map { tokenRect in
                    [
                        "text": tokenRect.text,
                        "x": tokenRect.x,
                        "y": tokenRect.y,
                        "width": tokenRect.width,
                        "height": tokenRect.height
                    ] as [String: Any]
                },
                "fontSize": region.fontSize ?? 0
            ] as [String: Any]
        }

        let data = (try? JSONSerialization.data(withJSONObject: ["regions": payload], options: [.sortedKeys]))
            ?? Data(#"{"regions":[]}"#.utf8)
        let json = String(data: data, encoding: .utf8) ?? #"{"regions":[]}"#

        return """
        Translate these OCR regions into fluent, idiomatic Simplified Chinese using each region's supplied strategy. For research text, render "publications" contextually as "论文" or "出版成果"; render "owns turns" idiomatically as "管理轮次" or "负责轮次". For block regions, translate every natural-language word and return one complete coherent targetMarkdown translation with no leftover English prose; keep only genuine names, brands, acronyms, and backticked code identifiers. For selective regions, return only ordered token-range segments and exclude names, brands, products, code, symbols, separators, and numbers. Never include a token marked preserve=true in a selective segment. Do not output explanations or extra ids.
        \(json)
        """
    }
}

enum ImageTranslationResponseParser {
    static func parse(_ response: String) -> [ImageTranslationBlock] {
        let stripped = stripCodeFence(response.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !stripped.isEmpty else {
            return []
        }

        if let json = extractedJSON(from: stripped),
           let data = json.data(using: .utf8),
           let decoded = decodeBlocks(from: data) {
            return decoded
        }

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
        guard !stripped.isEmpty,
              let json = extractedJSON(from: stripped),
              let data = json.data(using: .utf8)
        else {
            return []
        }

        let decoder = JSONDecoder()
        if let payload = try? decoder.decode(ImageTranslationReplacementPayload.self, from: data) {
            return payload.translationReplacements
        }

        if let array = try? decoder.decode([ImageTranslationReplacementDTO].self, from: data) {
            return array.compactMap(\.replacement)
        }

        return []
    }

    static func merge(
        replacements: [ImageTranslationReplacement],
        regions: [ImageTranslationSourceRegion]
    ) -> [ImageTranslationBlock] {
        let replacementByID = Dictionary(
            replacements.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return regions.flatMap { region -> [ImageTranslationBlock] in
            guard let replacement = replacementByID[region.id] else {
                return []
            }

            if region.translationStrategy == .selective, !region.tokens.isEmpty {
                return segmentBlocks(replacement: replacement, region: region)
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
                kind: resolvedKind(sourceKind: region.kind, replacementKind: replacement.kind)
            )]
        }
    }

    private static func segmentBlocks(
        replacement: ImageTranslationReplacement,
        region: ImageTranslationSourceRegion
    ) -> [ImageTranslationBlock] {
        let sortedSegments = replacement.segments.sorted { lhs, rhs in
            if lhs.tokenStart == rhs.tokenStart {
                return lhs.tokenEnd < rhs.tokenEnd
            }
            return lhs.tokenStart < rhs.tokenStart
        }
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
                claimedIndexes: claimedIndexes
            )
            let selectedTokens = Array(region.tokens[selectedIndexes])
            guard !selectedTokens.contains(where: { $0.isProtected }) else {
                continue
            }

            let sourceText = selectedTokens.map(\.text).joined(separator: " ")
            let text = removingUnexpectedNumericBadges(
                from: sanitizedMarkdown(segment.text, allowedCodeTokens: []),
                sourceText: sourceText
            )
            guard
                !text.isEmpty,
                normalizedComparisonText(text) != normalizedComparisonText(sourceText)
            else {
                continue
            }

            let selectedRects = selectedTokens.map(tokenRect)
            let geometry = selectiveTextGeometry(
                selectedRects: selectedRects,
                allTokens: region.tokens,
                selectedIndexes: selectedIndexes
            )
            guard let sourceRect = unionRect(geometry.layoutRects) else {
                continue
            }
            let lineRects = geometry.layoutRects.map(imageLineRect)
            let textRects = geometry.eraseRects.map(imageLineRect)
            let outsideRects = region.tokens.enumerated().compactMap { index, token in
                selectedIndexes.contains(index) ? nil : protectedTokenBoundaryRect(token)
            }
            let outsideTokenRects = outsideRects.map(imageLineRect)
            let inheritedProtectedRects = region.protectedRects.filter { inheritedRect in
                let inherited = rect(from: inheritedRect)
                return !outsideRects.contains { outsideRect in
                    overlapRatio(inherited, outsideRect) > 0.28
                }
            }

            blocks.append(ImageTranslationBlock(
                text: text,
                x: sourceRect.minX,
                y: sourceRect.minY,
                width: sourceRect.width,
                height: sourceRect.height,
                lineRects: lineRects,
                textRects: textRects,
                protectedRects: inheritedProtectedRects + outsideTokenRects,
                trailingAttachments: trailingNumericAttachmentRects(
                    tokens: region.tokens,
                    selectedIndexes: selectedIndexes
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
        selectedIndexes: Range<Int>
    ) -> [ImageTranslationLineRect] {
        guard selectedIndexes.upperBound < tokens.count else {
            return []
        }
        let selectedRect = tokenRect(tokens[selectedIndexes.upperBound - 1])
        let candidate = tokens[selectedIndexes.upperBound]
        let candidateRect = tokenRect(candidate)
        guard
            candidate.isProtected,
            isNumericBadgeToken(candidate.text),
            belongsToSameTokenLine(selectedRect, candidateRect),
            max(0, candidateRect.minX - selectedRect.maxX)
                <= max(0.018, max(selectedRect.height, candidateRect.height) * 0.85)
        else {
            return []
        }

        let horizontalPadding = max(0.002, candidateRect.height * 0.28)
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
        claimedIndexes: Set<Int>
    ) -> Range<Int> {
        var lowerBound = requestedRange.lowerBound
        var upperBound = requestedRange.upperBound

        while lowerBound > 0 {
            let candidateIndex = lowerBound - 1
            guard
                !claimedIndexes.contains(candidateIndex),
                isShortOCRBoundaryFragment(tokens[candidateIndex]),
                areAdjacentTokenFragments(tokens[candidateIndex], tokens[lowerBound])
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
                areAdjacentTokenFragments(tokens[upperBound - 1], tokens[candidateIndex])
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
        _ rhs: ImageTranslationSourceToken
    ) -> Bool {
        let lhsRect = tokenRect(lhs)
        let rhsRect = tokenRect(rhs)
        guard belongsToSameTokenLine(lhsRect, rhsRect) else {
            return false
        }
        let gap = max(0, max(lhsRect.minX, rhsRect.minX) - min(lhsRect.maxX, rhsRect.maxX))
        return gap <= max(0.003, max(lhsRect.height, rhsRect.height) * 0.30)
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
        selectedIndexes: Range<Int>
    ) -> SelectiveTextGeometry {
        let selectedLines = mergedTokenLineRects(selectedRects)
        let outsideRects = allTokens.enumerated().compactMap { index, token in
            selectedIndexes.contains(index) ? nil : protectedTokenBoundaryRect(token)
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

            let leadingGap = max(0.0015, line.height * 0.12)
            let layoutMinX = previous.map {
                max(line.minX, $0.maxX + leadingGap)
            } ?? line.minX

            // OCR boxes can finish just before the antialiased edge of the last
            // glyph. Extend the erase slot to the next token boundary (which is
            // separately protected), or by a small bounded tail at line end.
            let trailingTail = max(0.002, line.height * 0.22)
            let eraseMaxX = min(
                1,
                max(line.maxX + trailingTail, next?.minX ?? line.maxX)
            )
            let trailingGap = max(0.0015, line.height * 0.10)
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

    private static func protectedTokenBoundaryRect(_ token: ImageTranslationSourceToken) -> CGRect {
        let rect = tokenRect(token)
        if isNumericBadgeToken(token.text) {
            return rect
        }
        let horizontalInset = min(
            max(0.0008, rect.height * 0.08),
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
        guard sourceText.rangeOfCharacter(from: .decimalDigits) == nil else {
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

    private static func decodeBlocks(from data: Data) -> [ImageTranslationBlock]? {
        let decoder = JSONDecoder()

        if let payload = try? decoder.decode(ImageTranslationPayload.self, from: data) {
            return payload.translationBlocks
        }

        if let array = try? decoder.decode([ImageTranslationBlockDTO].self, from: data) {
            return array.compactMap(\.translationBlock)
        }

        return nil
    }

    private static func extractedJSON(from response: String) -> String? {
        if response.first == "{" || response.first == "[" {
            return response
        }

        if let objectStart = response.firstIndex(of: "{"),
           let objectEnd = response.lastIndex(of: "}"),
           objectStart <= objectEnd {
            return String(response[objectStart...objectEnd])
        }

        if let arrayStart = response.firstIndex(of: "["),
           let arrayEnd = response.lastIndex(of: "]"),
           arrayStart <= arrayEnd {
            return String(response[arrayStart...arrayEnd])
        }

        return nil
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

private struct ImageTranslationPayload: Decodable {
    let translations: [ImageTranslationBlockDTO]?
    let blocks: [ImageTranslationBlockDTO]?

    var translationBlocks: [ImageTranslationBlock] {
        (translations ?? blocks ?? []).compactMap(\.translationBlock)
    }
}

private struct ImageTranslationReplacementPayload: Decodable {
    let translations: [ImageTranslationReplacementDTO]?
    let replacements: [ImageTranslationReplacementDTO]?
    let items: [ImageTranslationReplacementDTO]?

    var translationReplacements: [ImageTranslationReplacement] {
        (translations ?? replacements ?? items ?? []).compactMap(\.replacement)
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
    let segments: [ImageTranslationReplacementSegmentDTO]?

    var replacement: ImageTranslationReplacement? {
        guard let id else {
            return nil
        }

        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedText = (targetMarkdown ?? markdown ?? text ?? translation ?? content ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedSegments = (segments ?? []).compactMap(\.replacementSegment)
        guard !trimmedID.isEmpty, !trimmedText.isEmpty || segments != nil else {
            return nil
        }

        return ImageTranslationReplacement(
            id: trimmedID,
            text: trimmedText,
            kind: kind ?? type,
            segments: resolvedSegments
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

struct ConversationContextPolicy: Equatable, Sendable {
    var maximumCompletedTurns = 12
    var maximumTextCharacters = 24_000
    var maximumImages = 4

    static let `default` = ConversationContextPolicy()
}

struct ConversationContextBuilder: Sendable {
    static let systemPrompt = """
    You answer questions about screenshots. Answer the latest user question directly and use earlier turns only when they are relevant.

    Images belong to the user message where they appear. A newly attached image is new visual context and may differ from earlier screenshots. Do not claim that two screenshots are the same unless the user says so. When the question is ambiguous, prefer the most recently attached image.
    """

    let policy: ConversationContextPolicy

    init(policy: ConversationContextPolicy = .default) {
        self.policy = policy
    }

    func build(
        turns: [ConversationTurn],
        images: [UUID: ConversationImageAsset],
        through targetTurnID: UUID
    ) -> VisionRequest? {
        guard let targetIndex = turns.firstIndex(where: { $0.id == targetTurnID }) else {
            return nil
        }

        let target = turns[targetIndex]
        let completed = turns[..<targetIndex].filter {
            $0.status == .completed && !$0.answer.isEmpty
        }
        let selectedCompleted = selectCompletedTurns(Array(completed))
        var selected = selectedCompleted + [target]
        let latestImageID = turns[...targetIndex].reversed().lazy.flatMap(\.imageIDs).first
        selected = enforceImageBudget(
            selected,
            targetID: target.id,
            fallbackImageID: latestImageID
        )

        var messages: [VisionMessage] = []
        for turn in selected {
            var userContent: [VisionContent] = turn.imageIDs.compactMap { imageID in
                images[imageID].map(VisionContent.image)
            }
            userContent.append(.text(turn.question))
            messages.append(VisionMessage(role: .user, content: userContent))

            if turn.id != target.id, !turn.answer.isEmpty {
                messages.append(VisionMessage(role: .assistant, content: [.text(turn.answer)]))
            }
        }

        return VisionRequest(systemPrompt: Self.systemPrompt, messages: messages)
    }

    private func selectCompletedTurns(_ turns: [ConversationTurn]) -> [ConversationTurn] {
        var selected: [ConversationTurn] = []
        var characterCount = 0

        for turn in turns.reversed() {
            guard selected.count < policy.maximumCompletedTurns else { break }
            let turnCharacters = turn.question.count + turn.answer.count
            guard selected.isEmpty || characterCount + turnCharacters <= policy.maximumTextCharacters else {
                break
            }
            selected.append(turn)
            characterCount += turnCharacters
        }

        return selected.reversed()
    }

    private func enforceImageBudget(
        _ turns: [ConversationTurn],
        targetID: UUID,
        fallbackImageID: UUID?
    ) -> [ConversationTurn] {
        var remainingImages = max(1, policy.maximumImages)
        var result = turns

        for index in result.indices.reversed() {
            let imageIDs = result[index].imageIDs
            if imageIDs.count <= remainingImages {
                remainingImages -= imageIDs.count
            } else {
                result[index] = ConversationTurn(
                    id: result[index].id,
                    question: result[index].question,
                    imageIDs: Array(imageIDs.suffix(remainingImages)),
                    answer: result[index].answer,
                    errorMessage: result[index].errorMessage,
                    status: result[index].status,
                    showsAssistant: result[index].showsAssistant
                )
                remainingImages = 0
            }
        }

        if !result.contains(where: { !$0.imageIDs.isEmpty }),
           let targetIndex = result.firstIndex(where: { $0.id == targetID }),
           let fallbackImageID {
            result[targetIndex] = ConversationTurn(
                id: result[targetIndex].id,
                question: result[targetIndex].question,
                imageIDs: [fallbackImageID],
                answer: result[targetIndex].answer,
                errorMessage: result[targetIndex].errorMessage,
                status: result[targetIndex].status,
                showsAssistant: result[targetIndex].showsAssistant
            )
        }

        return result
    }
}

@MainActor
final class ConversationSession: ObservableObject {
    let id: UUID
    let createdAt: Date
    @Published private(set) var turns: [ConversationTurn]
    @Published private(set) var images: [UUID: ConversationImageAsset]
    @Published private(set) var pendingImageIDs: [UUID]
    @Published var focusRequestID = 0

    private let contextBuilder: ConversationContextBuilder
    private var updatedAt: Date
    private var archiveHandler: ((ConversationArchive) -> Void)?

    init(
        initialImage: PickedImage,
        initialQuestion: String,
        contextBuilder: ConversationContextBuilder = ConversationContextBuilder()
    ) {
        id = UUID()
        createdAt = Date()
        updatedAt = createdAt
        let asset = ConversationImageAsset(image: initialImage)
        let turn = ConversationTurn(
            id: UUID(),
            question: initialQuestion,
            imageIDs: [asset.id],
            answer: "",
            errorMessage: nil,
            status: .loading,
            showsAssistant: true
        )
        turns = [turn]
        images = [asset.id: asset]
        pendingImageIDs = []
        self.contextBuilder = contextBuilder
    }

    init(
        historyRecord: ConversationHistoryRecord,
        imageAssets: [ConversationImageAsset],
        contextBuilder: ConversationContextBuilder = ConversationContextBuilder()
    ) {
        id = historyRecord.id
        createdAt = historyRecord.createdAt
        updatedAt = historyRecord.updatedAt
        turns = historyRecord.turns.map { turn in
            guard turn.status == .loading else {
                return turn
            }
            return ConversationTurn(
                id: turn.id,
                question: turn.question,
                imageIDs: turn.imageIDs,
                answer: "",
                errorMessage: turn.errorMessage ?? "This request did not finish before the session ended.",
                status: .failed,
                showsAssistant: true
            )
        }
        images = Dictionary(uniqueKeysWithValues: imageAssets.map { ($0.id, $0) })
        pendingImageIDs = historyRecord.pendingImageIDs
        self.contextBuilder = contextBuilder
    }

    var hasLoadingTurn: Bool {
        turns.contains(where: \.isLoading)
    }

    var latestEditableTurnID: UUID? {
        guard let turn = turns.last, !turn.isLoading else {
            return nil
        }
        return turn.id
    }

    func setArchiveHandler(
        persistImmediately: Bool = true,
        _ handler: @escaping (ConversationArchive) -> Void
    ) {
        archiveHandler = handler
        if persistImmediately {
            handler(makeArchive())
        }
    }

    @discardableResult
    func appendScreenshot(_ image: PickedImage) -> UUID {
        let asset = ConversationImageAsset(image: image)
        images[asset.id] = asset
        pendingImageIDs.append(asset.id)
        focusRequestID += 1
        archiveChanges()
        return asset.id
    }

    func requestFocus() {
        focusRequestID += 1
    }

    func beginTurn(question rawQuestion: String) -> UUID? {
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !hasLoadingTurn else { return nil }

        let turn = ConversationTurn(
            id: UUID(),
            question: question,
            imageIDs: pendingImageIDs,
            answer: "",
            errorMessage: nil,
            status: .loading,
            showsAssistant: false
        )
        pendingImageIDs = []
        turns.append(turn)
        archiveChanges()
        return turn.id
    }

    func request(for turnID: UUID) -> VisionRequest? {
        contextBuilder.build(turns: turns, images: images, through: turnID)
    }

    func revealAssistant(for turnID: UUID) {
        update(turnID) { $0.showsAssistant = true }
    }

    func reviseLatestTurn(_ turnID: UUID, question rawQuestion: String) -> Bool {
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !question.isEmpty,
            !hasLoadingTurn,
            turns.last?.id == turnID,
            let index = turns.indices.last
        else {
            return false
        }

        turns[index].question = question
        turns[index].answer = ""
        turns[index].errorMessage = nil
        turns[index].status = .loading
        turns[index].showsAssistant = true
        archiveChanges()
        return true
    }

    func complete(_ turnID: UUID, answer: String) {
        update(turnID) {
            $0.answer = answer
            $0.errorMessage = nil
            $0.status = .completed
            $0.showsAssistant = true
        }
        focusRequestID += 1
        archiveChanges()
    }

    func fail(_ turnID: UUID, message: String) {
        update(turnID) {
            $0.answer = ""
            $0.errorMessage = message
            $0.status = .failed
            $0.showsAssistant = true
        }
        focusRequestID += 1
        archiveChanges()
    }

    func prepareRetry(_ turnID: UUID) -> Bool {
        guard let index = turns.firstIndex(where: { $0.id == turnID }), turns[index].status == .failed else {
            return false
        }
        turns[index].answer = ""
        turns[index].errorMessage = nil
        turns[index].status = .loading
        turns[index].showsAssistant = true
        archiveChanges()
        return true
    }

    private func update(_ turnID: UUID, mutation: (inout ConversationTurn) -> Void) {
        guard let index = turns.firstIndex(where: { $0.id == turnID }) else { return }
        mutation(&turns[index])
    }

    private func archiveChanges() {
        updatedAt = Date()
        archiveHandler?(makeArchive())
    }

    private func makeArchive() -> ConversationArchive {
        ConversationArchive(
            id: id,
            createdAt: createdAt,
            updatedAt: updatedAt,
            turns: turns,
            images: Array(images.values),
            pendingImageIDs: pendingImageIDs
        )
    }
}
