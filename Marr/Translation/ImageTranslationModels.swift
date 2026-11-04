import Foundation

struct ImageTranslationBlock: Equatable, Sendable {
    let sourceID: String?
    let text: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let lineRects: [ImageTranslationLineRect]
    let preservesListMarker: Bool
    /// Structural marker pixels, separate from movable numbers in prose.
    let listMarkerRects: [ImageTranslationLineRect]
    let textRects: [ImageTranslationLineRect]
    let protectedRects: [ImageTranslationLineRect]
    /// Source formula pixels that must survive translation.
    let mathRects: [ImageTranslationLineRect]
    /// Inline formulas owned by a fully translated line; their pixels may flow with prose.
    let inlineMathRects: [ImageTranslationLineRect]
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
        sourceID: String? = nil,
        text: String,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        lineRects: [ImageTranslationLineRect] = [],
        preservesListMarker: Bool = false,
        listMarkerRects: [ImageTranslationLineRect] = [],
        textRects: [ImageTranslationLineRect] = [],
        protectedRects: [ImageTranslationLineRect] = [],
        mathRects: [ImageTranslationLineRect] = [],
        inlineMathRects: [ImageTranslationLineRect] = [],
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
        self.sourceID = sourceID
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.x = Self.clamp(x)
        self.y = Self.clamp(y)
        self.width = Self.clamp(width, lowerBound: 0.004)
        self.height = Self.clamp(height, lowerBound: 0.006)
        self.lineRects = lineRects
        self.preservesListMarker = preservesListMarker
        self.listMarkerRects = listMarkerRects
        self.textRects = textRects
        self.protectedRects = protectedRects
        self.mathRects = mathRects
        self.inlineMathRects = inlineMathRects
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
    let isMathematical: Bool

    init(
        text: String,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        isProtected: Bool = false,
        isMathematical: Bool = false
    ) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
        self.width = min(max(width, 0.004), 1)
        self.height = min(max(height, 0.004), 1)
        self.isProtected = isProtected || isMathematical
        self.isMathematical = isMathematical
    }
}

enum ImageTranslationStrategy: String, Equatable, Sendable {
    case block
    case selective
}

struct ImageTranslationSourceRegion: Equatable, Sendable, Identifiable {
    let id: String
    let sourceText: String
    /// Converts normalized vertical lengths to normalized horizontal lengths.
    let imageAspectRatio: Double
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let lineRects: [ImageTranslationLineRect]
    let preservesListMarker: Bool
    /// Structural marker pixels, separate from movable numbers in prose.
    let listMarkerRects: [ImageTranslationLineRect]
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

    var preservesInlineMath: Bool { tokens.contains(where: \.isMathematical) }

    /// Formula-only regions carry immutable source geometry through merging,
    /// but must never become translation requests or completion work.
    var requiresTranslation: Bool {
        !(translationStrategy == .selective && preservesInlineMath
            && tokens.allSatisfy(\.isProtected))
    }

    init(
        id: String,
        sourceText: String,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        imageAspectRatio: Double = 1,
        lineRects: [ImageTranslationLineRect] = [],
        preservesListMarker: Bool = false,
        listMarkerRects: [ImageTranslationLineRect] = [],
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
        self.imageAspectRatio = imageAspectRatio.isFinite && imageAspectRatio > 0 ? imageAspectRatio : 1
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
        self.width = min(max(width, 0.004), 1)
        self.height = min(max(height, 0.006), 1)
        self.lineRects = lineRects
        self.preservesListMarker = preservesListMarker
        self.listMarkerRects = listMarkerRects
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

    func translationBlock(
        text: String,
        kind replacementKind: String? = nil,
        mathRects: [ImageTranslationLineRect] = []
    ) -> ImageTranslationBlock {
        let isSelective = translationStrategy == .selective
        return ImageTranslationBlock(
            sourceID: id,
            text: text,
            x: x,
            y: y,
            width: width,
            height: height,
            lineRects: lineRects,
            preservesListMarker: preservesListMarker,
            listMarkerRects: listMarkerRects,
            textRects: textRects,
            protectedRects: isSelective ? protectedRects : [],
            mathRects: mathRects + tokens.filter(\.isMathematical).map {
                ImageTranslationLineRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
            },
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
    let alignments: [ImageTranslationAlignment]

    init(
        id: String,
        text: String,
        kind: String? = nil,
        segments: [ImageTranslationReplacementSegment] = [],
        alignments: [ImageTranslationAlignment] = []
    ) {
        self.id = id
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.kind = kind?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.segments = segments
        self.alignments = alignments
    }
}

struct ImageTranslationAlignment: Equatable, Sendable {
    let tokenStart: Int
    let tokenEnd: Int
    let targetText: String

    init(tokenStart: Int, tokenEnd: Int, targetText: String) {
        self.tokenStart = tokenStart
        self.tokenEnd = tokenEnd
        self.targetText = targetText.trimmingCharacters(in: .whitespacesAndNewlines)
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
