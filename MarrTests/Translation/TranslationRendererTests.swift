import AppKit
import XCTest
@testable import Marr

final class TranslationRendererTests: XCTestCase {
    func testProseFontSharesFamilyAcrossScriptsAndKeepsMediumWeight() throws {
        XCTAssertEqual(TranslationTypography.fontWeight(from: "medium"), .medium)
        XCTAssertEqual(TranslationTypography.fontWeight(from: "semibold"), .semibold)
        let regular = TranslationTypography.proseFont(ofSize: 24)
        let medium = TranslationTypography.proseFont(ofSize: 24, weight: .medium)
        XCTAssertEqual(regular.familyName, medium.familyName)
        XCTAssertGreaterThan(NSFontManager.shared.weight(of: medium), NSFontManager.shared.weight(of: regular))
        let rendered = TranslationTypography.attributedMarkdownLayout("正文 ABC 123 `user_id`",
            fontSize: 24, weight: .medium, foregroundColor: .black, paragraph: NSMutableParagraphStyle())
        for index in [0, 3, 7] {
            let font = try XCTUnwrap(rendered.attributed.attribute(.font, at: index, effectiveRange: nil) as? NSFont)
            XCTAssertEqual(font.fontName, medium.fontName, "Han, Latin and digits must share the same prose face")
        }
        let code = try XCTUnwrap(rendered.codeRanges.first)
        let codeFont = try XCTUnwrap(rendered.attributed.attribute(.font, at: code.location, effectiveRange: nil) as? NSFont)
        XCTAssertNotEqual(codeFont.familyName, regular.familyName, "Actual code retains its monospaced family")
    }

    func testForegroundSamplingUsesStrokeCoreWithoutFlatteningSemanticColors() throws {
        let size = CGSize(width: 660, height: 130)
        for scale in [1, 2] {
            for (foreground, background) in [
                (NSColor.black, NSColor.white),
                (NSColor(srgbRed: 0.4, green: 0.4, blue: 0.4, alpha: 1), NSColor.white),
                (NSColor(srgbRed: 0.75, green: 0.1, blue: 0.1, alpha: 1), NSColor.white),
                (NSColor.white, NSColor(srgbRed: 0.12, green: 0.12, blue: 0.12, alpha: 1))
            ] {
                let source = try sourceImage(size: size, scale: scale)
                let bitmap = try XCTUnwrap(source.representations.first as? NSBitmapImageRep)
                bitmap.size = CGSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
                let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
                background.setFill()
                NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
                var rects: [CGRect] = []
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 22), .foregroundColor: foreground
                ]
                for (index, value) in ["ill", "MWMW", "0.3132617"].enumerated() {
                    let text = value as NSString
                    let rect = CGRect(origin: CGPoint(x: 24 + index * 190, y: 55), size: text.size(withAttributes: attributes))
                    text.draw(at: rect.origin, withAttributes: attributes)
                    rects.append(rect)
                }
                NSGraphicsContext.restoreGraphicsState()
                let colors = try rects.map {
                    try XCTUnwrap(TranslationColorSampling.sampledForegroundColor(in: [$0], bitmap: bitmap,
                        backgroundColor: background, bounds: CGRect(origin: .zero, size: size)),
                        "scale \(scale), ink \(foreground), rect \($0)")
                }
                for color in colors {
                    XCTAssertLessThan(TranslationColorSampling.rgbDistance(color, foreground), 0.04,
                                      "Text density must not turn black into gray or discard intentional gray/red/white ink")
                    XCTAssertLessThan(TranslationColorSampling.rgbDistance(color, colors[0]), 0.04)
                }
            }
        }
    }

    func testForegroundSamplingKeepsGrayFooterWithDarkPageNumber() throws {
        let size = CGSize(width: 500, height: 120)
        let source = try sourceImage(size: size, scale: 1)
        let bitmap = try XCTUnwrap(source.representations.first as? NSBitmapImageRep)
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        let gray = NSColor(srgbRed: 0.4, green: 0.4, blue: 0.4, alpha: 1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        ("Coursework information" as NSString).draw(at: CGPoint(x: 20, y: 45), withAttributes: [
            .font: NSFont.systemFont(ofSize: 18), .foregroundColor: gray
        ])
        ("3" as NSString).draw(at: CGPoint(x: 260, y: 45), withAttributes: [
            .font: NSFont.boldSystemFont(ofSize: 18), .foregroundColor: NSColor.black
        ])
        NSGraphicsContext.restoreGraphicsState()
        let sampled = try XCTUnwrap(TranslationColorSampling.sampledForegroundColor(
            in: [CGRect(x: 15, y: 40, width: 275, height: 30)], bitmap: bitmap,
            backgroundColor: .white, bounds: CGRect(origin: .zero, size: size)))
        XCTAssertLessThan(TranslationColorSampling.rgbDistance(sampled, gray), 0.04,
                          "A minority of darker ink must not turn gray secondary text black")
    }

    func testParagraphTypographyIgnoresOCRJitterAndKeepsColumnsSeparate() throws {
        let size = CGSize(width: 760, height: 220)
        let source = try sourceImage(size: size, scale: 1)
        let bitmap = try XCTUnwrap(source.representations.first as? NSBitmapImageRep)
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        var blocks: [ImageTranslationBlock] = []
        var pairs: [ImageTranslationHighlightPair] = []
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        for column in 0..<2 {
            let fontSize: CGFloat = column == 0 ? 26 : 19
            let left: CGFloat = column == 0 ? 30 : 410
            for row in 0..<3 {
                let y: CGFloat = 160 - CGFloat(row) * 36
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: NSColor.black
                ]
                ("Source paragraph gyjp" as NSString).draw(at: CGPoint(x: left, y: y), withAttributes: attributes)
                let jitter: CGFloat = row == 1 ? 2 : 0
                let rect = ImageTranslationLineRect(x: (left - jitter) / size.width,
                    y: (size.height - y - 32 - jitter) / size.height,
                    width: 300 / size.width, height: (34 + jitter) / size.height)
                let id = "column\(column)-row\(row)"
                let text = ["同一段落对齐", "数字 0.3132617", "正文与 gyjp 对齐"][row]
                blocks.append(ImageTranslationBlock(sourceID: id, text: text,
                    x: rect.x, y: rect.y, width: rect.width, height: rect.height,
                    lineRects: [rect], textRects: [rect], textColor: "#0000ff", alignment: "left",
                    fontSize: Double(fontSize + jitter)))
                pairs.append(ImageTranslationHighlightPair(id: id, sourceID: id, targetText: text,
                    sourceRects: [], translatedRects: []))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        let result = try XCTUnwrap(ImageTranslationRenderer.renderDataWithHighlights(
            sourceData: XCTUnwrap(bitmap.representation(using: .png, properties: [:])), blocks: blocks, highlightPairs: pairs))
        var columnHeights: [CGFloat] = []
        for column in 0..<2 {
            let rects = try (0..<3).map { try XCTUnwrap(result.translatedHighlightRects["column\(column)-row\($0)"]?.first) }
            let heights = rects.map { $0.height * size.height }
            let lefts = rects.map { $0.minX * size.width }
            XCTAssertLessThanOrEqual(try XCTUnwrap(heights.max()) - XCTUnwrap(heights.min()), 1)
            XCTAssertLessThanOrEqual(try XCTUnwrap(lefts.max()) - XCTUnwrap(lefts.min()), 1)
            XCTAssertEqual(lefts[0], column == 0 ? 30 : 410, accuracy: 4,
                           "Normalizing a paragraph must not move it into the other column")
            let steps = zip(rects, rects.dropFirst()).map { ($1.minY - $0.minY) * size.height }
            XCTAssertEqual(steps[0], steps[1], accuracy: 1)
            columnHeights.append(heights[0])
        }
        XCTAssertGreaterThan(columnHeights[0], columnHeights[1] * 1.15,
                             "Separate columns with different source typography must retain their own sizes")
    }

    func testExplicitParagraphUsesOneFontAndPreservesHangingIndent() throws {
        let size = CGSize(width: 620, height: 200)
        let source = try sourceImage(size: size, scale: 1)
        let rows = [
            ImageTranslationLineRect(x: 0.05, y: 0.15, width: 0.88, height: 0.18),
            ImageTranslationLineRect(x: 0.10, y: 0.38, width: 0.83, height: 0.15),
            ImageTranslationLineRect(x: 0.101, y: 0.61, width: 0.829, height: 0.17)
        ]
        let lines = ["1.1 第一行正文", "缩进的第二行正文", "缩进的第三行正文"]
        let block = ImageTranslationBlock(sourceID: "paragraph", text: lines.joined(separator: "\n"),
            x: 0.05, y: 0.15, width: 0.88, height: 0.63, lineRects: rows,
            textColor: "#0000ff", alignment: "left", fontSize: 30)
        let pairs = lines.enumerated().map { index, text in
            ImageTranslationHighlightPair(id: "line\(index)", sourceID: "paragraph", targetText: text,
                sourceRects: [], translatedRects: [])
        }
        let result = try XCTUnwrap(ImageTranslationRenderer.renderDataWithHighlights(
            sourceData: XCTUnwrap(source.tiffRepresentation), blocks: [block], highlightPairs: pairs))
        let rects = try pairs.map { try XCTUnwrap(result.translatedHighlightRects[$0.id]?.first) }
        let heights = rects.map { $0.height * size.height }
        XCTAssertLessThanOrEqual(try XCTUnwrap(heights.max()) - XCTUnwrap(heights.min()), 1,
                                 "Different OCR row heights must not change the font within one paragraph")
        XCTAssertGreaterThan((rects[1].minX - rects[0].minX) * size.width, 20,
                             "A real hanging indent must not be flattened")
        XCTAssertEqual(rects[1].minX * size.width, rects[2].minX * size.width, accuracy: 1)
    }

    func testLeadingFormulaKeepsParagraphOriginDuringBaselineAlignment() throws {
        let source = try sourceImage(size: CGSize(width: 640, height: 200), scale: 1)
        let bitmap = try XCTUnwrap(source.representations.first as? NSBitmapImageRep)
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 26), .foregroundColor: NSColor.black
        ]
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        ("x = 1" as NSString).draw(at: CGPoint(x: 40, y: 100), withAttributes: attributes)
        ("means the condition holds" as NSString).draw(at: CGPoint(x: 160, y: 100), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        let region = ImageTranslationSourceRegion(id: "leading-formula", sourceText: "⟦math_1⟧ means the condition holds",
            x: 40.0 / 640, y: 0.34, width: 540.0 / 640, height: 0.18, imageAspectRatio: 3.2,
            tokens: [
                ImageTranslationSourceToken(text: "⟦math_1⟧", x: 40.0 / 640, y: 0.34,
                    width: 90.0 / 640, height: 0.18, isMathematical: true),
                ImageTranslationSourceToken(text: "means the condition holds", x: 160.0 / 640, y: 0.34,
                    width: 420.0 / 640, height: 0.18)
            ], translationStrategy: .selective, textColor: "#0000ff", fontSize: 26)
        let blocks = ImageTranslationMerger.merge(replacements: [
            ImageTranslationReplacement(id: region.id, text: "", segments: [
                ImageTranslationReplacementSegment(tokenStart: 1, tokenEnd: 2, text: "表示条件成立")
            ])
        ], regions: [region])
        let result = try XCTUnwrap(ImageTranslationRenderer.renderDataWithHighlights(
            sourceData: XCTUnwrap(bitmap.representation(using: .png, properties: [:])), blocks: blocks,
            highlightPairs: [ImageTranslationHighlightPair(id: "prose", sourceID: region.id,
                targetText: "表示条件成立", sourceRects: [], translatedRects: [])]))
        let placement = try XCTUnwrap(result.formulaPlacements.first)
        XCTAssertEqual(placement.targetRect.minX, 40, accuracy: 1,
                       "A leading formula, not the following prose, establishes the paragraph margin")
        let text = try XCTUnwrap(result.translatedHighlightRects["prose"]?.first)
        XCTAssertGreaterThanOrEqual(text.minX * 640, placement.targetRect.maxX)
        XCTAssertLessThanOrEqual(text.minX * 640 - placement.targetRect.maxX, 10)
    }


    func testTranslationPreservesNarrowColoredStrip() throws {
        for scale: CGFloat in [1, 2] {
            try assertBackgroundRecovery(style: .narrowColor, scale: scale)
        }
    }

    func testTranslationPreservesSubtleLightAndDarkCardColors() throws {
        for scale: CGFloat in [1, 2] {
            try assertBackgroundRecovery(style: .subtleLight, scale: scale)
            try assertBackgroundRecovery(style: .subtleDark, scale: scale)
        }
    }

    func testTranslationReconstructsTwoDimensionalGradient() throws {
        for scale: CGFloat in [1, 2] {
            try assertBackgroundRecovery(style: .gradient, scale: scale)
        }
    }

    func testTranslationPreservesDisplayP3StripColorAtNativeScales() throws {
        for scale: CGFloat in [1, 2] {
            try assertBackgroundRecovery(style: .narrowColor, scale: scale, colorSpace: .displayP3)
        }
    }

    func testTranslationPreservesLightStripBoundaryAgainstDarkPage() throws {
        for scale: CGFloat in [1, 2] {
            try assertBackgroundRecovery(style: .lightStripOnDark, scale: scale)
            try assertBackgroundRecovery(style: .lightStripOnDarkLooseOCR, scale: scale)
        }
    }

    func testTranslationRemovesLowContrastSourceGlyphs() throws {
        for scale: CGFloat in [1, 2] {
            try assertBackgroundRecovery(style: .lowContrast, scale: scale)
        }
    }

    func testTranslationErasesSparseRedEmphasisWithinBlackSourceText() throws {
        for scale: CGFloat in [1, 1.5, 2] {
            try assertBackgroundRecovery(style: .mixedEmphasis, scale: scale)
        }
    }

    func testTranslationReconstructsNonlinearBackgroundGradient() throws {
        for scale: CGFloat in [1, 1.5, 2] {
            try assertBackgroundRecovery(style: .nonlinearGradient, scale: scale)
        }
    }

    func testTranslationPreservesFineTextureOverGradient() throws {
        for scale: CGFloat in [1, 1.5, 2] {
            try assertBackgroundRecovery(style: .texturedGradient, scale: scale)
        }
    }

    func testTranslationPreservesTransparentPNGAndTranslucentPanel() throws {
        for scale: CGFloat in [1, 1.5, 2] {
            for opacity: CGFloat in [0, 0.45] {
                try assertTransparencyRecovery(backgroundAlpha: opacity, scale: scale)
            }
        }
    }

    private enum BackgroundFixtureStyle: String {
        case narrowColor, subtleLight, subtleDark, gradient
        case lightStripOnDark, lightStripOnDarkLooseOCR, lowContrast
        case mixedEmphasis, nonlinearGradient, texturedGradient
    }

    private func assertBackgroundRecovery(
        style: BackgroundFixtureStyle,
        scale: CGFloat,
        colorSpace: NSColorSpace = .sRGB,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let fixture = try backgroundRecoveryFixture(style: style, scale: scale, colorSpace: colorSpace)
        let outputImage = try XCTUnwrap(ImageTranslationRenderer.render(
            source: PickedImage(data: Data(), mimeType: "image/png", fileName: "background.png", image: fixture.source),
            blocks: [fixture.block]
        ), file: file, line: line)
        let output = try XCTUnwrap(outputImage.representations.first as? NSBitmapImageRep, file: file, line: line)
        XCTAssertEqual(output.pixelsWide, fixture.before.pixelsWide, file: file, line: line)
        XCTAssertEqual(output.pixelsHigh, fixture.before.pixelsHigh, file: file, line: line)
        XCTAssertEqual(outputImage.size, fixture.source.size, file: file, line: line)
        XCTAssertEqual(output.pixelsWide, Int(fixture.source.size.width * scale), file: file, line: line)
        XCTAssertEqual(output.pixelsHigh, Int(fixture.source.size.height * scale), file: file, line: line)

        let profileName = colorSpace == .displayP3 ? "p3" : "srgb"
        let scaleName = scale == scale.rounded() ? String(Int(scale)) : String(Double(scale))
        let name = "\(style.rawValue)-\(scaleName)x-\(profileName)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OpenLens-background-regressions", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (suffix, bitmap) in [("before", fixture.before), ("after", output), ("background", fixture.clean)] {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]), file: file, line: line)
                .write(to: directory.appendingPathComponent("\(name)-\(suffix).png"))
        }
        print("Background regression artifacts: \(directory.path)/\(name)-after.png")

        func distance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
            max(abs(lhs.redComponent - rhs.redComponent),
                abs(lhs.greenComponent - rhs.greenComponent),
                abs(lhs.blueComponent - rhs.blueComponent))
        }
        var oldTailInkPixels = 0
        var blankPixels = 0
        var maximumOldInkDifference: CGFloat = 0
        var maximumBlankDifference: CGFloat = 0
        var translatedInkPixels = 0
        var redSourceInkPixels = 0
        // The short translation occupies the left of the source line. The
        // right half contains both old glyphs and real blank background, so
        // keeping the source image or merely painting a colored box both fail.
        let auditRect = CGRect(x: fixture.sourceRect.midX, y: fixture.sourceRect.minY - 6,
                               width: fixture.sourceRect.width * 0.5 + 6, height: fixture.sourceRect.height + 12)
        for y in 0..<output.pixelsHigh {
            for x in 0..<output.pixelsWide {
                let actual = try XCTUnwrap(output.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), file: file, line: line)
                if actual.blueComponent > 0.7 && actual.redComponent < 0.3 && actual.greenComponent < 0.3 {
                    translatedInkPixels += 1
                }
                let point = CGPoint(x: (CGFloat(x) + 0.5) / CGFloat(scale),
                                    y: fixture.source.size.height - (CGFloat(y) + 0.5) / CGFloat(scale))
                guard auditRect.contains(point) else { continue }
                let expected = try XCTUnwrap(fixture.clean.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), file: file, line: line)
                let original = try XCTUnwrap(fixture.before.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), file: file, line: line)
                let sourceDifference = distance(original, expected)
                if original.redComponent > 0.75 && original.greenComponent < 0.25 && original.blueComponent < 0.25 {
                    redSourceInkPixels += 1
                }
                let inkThreshold: CGFloat = style == .lowContrast ? 0.02 : 0.10
                if sourceDifference > inkThreshold {
                    oldTailInkPixels += 1
                    maximumOldInkDifference = max(maximumOldInkDifference, distance(actual, expected))
                } else if sourceDifference <= 1.0 / 255 {
                    blankPixels += 1
                    maximumBlankDifference = max(maximumBlankDifference, distance(actual, expected))
                }
            }
        }
        XCTAssertGreaterThan(oldTailInkPixels, Int(60 * scale * scale), "The fixture must contain real source glyphs in its tail", file: file, line: line)
        XCTAssertGreaterThan(blankPixels, Int(200 * scale * scale), "Audit actual background within and around the erased line", file: file, line: line)
        XCTAssertGreaterThan(translatedInkPixels, Int(20 * scale * scale), "The blue translated glyphs must be rendered", file: file, line: line)
        if style == .mixedEmphasis {
            XCTAssertGreaterThan(redSourceInkPixels, Int(40 * scale * scale), "The source tail must really contain sparse red emphasis", file: file, line: line)
        }
        let gradient = style == .gradient || style == .nonlinearGradient
        // Texture hidden by opaque letters is unknowable exactly. Bound its
        // reconstruction error to twice the known ±4/255 noise amplitude,
        // while keeping the originally visible texture to a one-byte error.
        let inkTolerance: CGFloat = style == .texturedGradient ? 8.0 / 255 : (gradient ? 3.0 / 255 : 1.0 / 255)
        let blankTolerance: CGFloat = gradient ? 3.0 / 255 : 1.0 / 255
        XCTAssertLessThanOrEqual(maximumOldInkDifference, inkTolerance, "\(name): remove the old text and reconstruct its original background", file: file, line: line)
        XCTAssertLessThanOrEqual(maximumBlankDifference, blankTolerance, "\(name): preserve existing background, including the card boundary", file: file, line: line)
    }

    private func assertTransparencyRecovery(
        backgroundAlpha: CGFloat,
        scale: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let size = CGSize(width: 520, height: 180)
        let sourceText = "SOURCE BACKGROUND TAIL" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.black
        ]
        let sourceRect = CGRect(origin: CGPoint(x: 48, y: 76), size: sourceText.size(withAttributes: attributes))
        let panelRect = sourceRect.insetBy(dx: -8, dy: -5)
        let raw = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), file: file, line: line)
        let bitmap = try XCTUnwrap(raw.retagging(with: .sRGB), file: file, line: line)
        let pixels = try XCTUnwrap(bitmap.bitmapData, file: file, line: line)
        // Write premultiplied RGBA explicitly. The transparent canvas and the
        // semi-transparent panel remain alpha-bearing when encoded as PNG.
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let point = CGPoint(x: (CGFloat(x) + 0.5) / scale,
                                    y: size.height - (CGFloat(y) + 0.5) / scale)
                let alpha = panelRect.contains(point) ? backgroundAlpha : 0
                let offset = y * bitmap.bytesPerRow + x * 4
                for (channel, value) in [CGFloat(0.35), 0.65, 0.85].enumerated() {
                    pixels[offset + channel] = UInt8((value * alpha * 255).rounded())
                }
                pixels[offset + 3] = UInt8((alpha * 255).rounded())
            }
        }
        let clean = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(bitmap.representation(using: .png, properties: [:]))), file: file, line: line)
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap), file: file, line: line)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        sourceText.draw(at: sourceRect.origin, withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        bitmap.size = size
        let sourceData = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]), file: file, line: line)
        let before = try XCTUnwrap(NSBitmapImageRep(data: sourceData), file: file, line: line)
        let sourceImage = try XCTUnwrap(NSImage(data: sourceData), file: file, line: line)
        sourceImage.size = size
        let rect = ImageTranslationLineRect(x: Double(sourceRect.minX / size.width),
            y: Double((size.height - sourceRect.maxY) / size.height),
            width: Double(sourceRect.width / size.width), height: Double(sourceRect.height / size.height))
        let block = ImageTranslationBlock(sourceID: "alpha-background", text: "译文",
            x: rect.x, y: rect.y, width: rect.width, height: rect.height,
            lineRects: [rect], textRects: [rect], translationStrategy: .block,
            textColor: "#0000ff", alignment: "left", fontSize: 24.0 / Double(size.height))
        let rendered = try XCTUnwrap(ImageTranslationRenderer.render(
            source: PickedImage(data: sourceData, mimeType: "image/png", fileName: "transparent.png", image: sourceImage),
            blocks: [block]), file: file, line: line)
        let output = try XCTUnwrap(rendered.representations.first as? NSBitmapImageRep, file: file, line: line)
        XCTAssertEqual(rendered.size, size, file: file, line: line)
        XCTAssertEqual(output.pixelsWide, Int(size.width * scale), file: file, line: line)
        XCTAssertEqual(output.pixelsHigh, Int(size.height * scale), file: file, line: line)
        let scaleName = scale == scale.rounded() ? String(Int(scale)) : String(Double(scale))
        let name = "alpha\(Int((backgroundAlpha * 100).rounded()))-\(scaleName)x"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OpenLens-background-regressions", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (suffix, image) in [("before", before), ("after", output), ("background", clean)] {
            try XCTUnwrap(image.representation(using: .png, properties: [:]), file: file, line: line)
                .write(to: directory.appendingPathComponent("\(name)-\(suffix).png"))
        }
        print("Background regression artifacts: \(directory.path)/\(name)-after.png")

        let auditRect = CGRect(x: sourceRect.midX, y: sourceRect.minY - 8,
                               width: sourceRect.width * 0.5 + 12, height: sourceRect.height + 16)
        var oldGlyphPixels = 0
        var blankPixels = 0
        var translatedPixels = 0
        var maxGlyphAlphaDifference: CGFloat = 0
        var maxBlankAlphaDifference: CGFloat = 0
        var maxPremultipliedDifference: CGFloat = 0
        for y in 0..<output.pixelsHigh {
            for x in 0..<output.pixelsWide {
                let actual = try XCTUnwrap(output.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), file: file, line: line)
                if actual.alphaComponent > 0.6 && actual.blueComponent > 0.7
                    && actual.redComponent < 0.3 && actual.greenComponent < 0.3 {
                    translatedPixels += 1
                }
                let point = CGPoint(x: (CGFloat(x) + 0.5) / scale,
                                    y: size.height - (CGFloat(y) + 0.5) / scale)
                guard auditRect.contains(point) else { continue }
                let expected = try XCTUnwrap(clean.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), file: file, line: line)
                let original = try XCTUnwrap(before.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), file: file, line: line)
                let sourceAlphaDifference = original.alphaComponent - expected.alphaComponent
                let outputAlphaDifference = abs(actual.alphaComponent - expected.alphaComponent)
                if sourceAlphaDifference > 0.1 {
                    oldGlyphPixels += 1
                    maxGlyphAlphaDifference = max(maxGlyphAlphaDifference, outputAlphaDifference)
                } else if abs(sourceAlphaDifference) <= 1.0 / 255 {
                    blankPixels += 1
                    maxBlankAlphaDifference = max(maxBlankAlphaDifference, outputAlphaDifference)
                }
                // RGB values at alpha zero are undefined. Premultiplication
                // compares their visual contribution without accepting a loss
                // of transparency or a tint introduced in the translucent panel.
                let a = actual.alphaComponent, b = expected.alphaComponent
                maxPremultipliedDifference = max(maxPremultipliedDifference,
                    abs(actual.redComponent * a - expected.redComponent * b),
                    abs(actual.greenComponent * a - expected.greenComponent * b),
                    abs(actual.blueComponent * a - expected.blueComponent * b))
            }
        }
        XCTAssertGreaterThan(oldGlyphPixels, Int(60 * scale * scale), "\(name): source glyphs must measurably increase alpha", file: file, line: line)
        XCTAssertGreaterThan(blankPixels, Int(200 * scale * scale), file: file, line: line)
        XCTAssertGreaterThan(translatedPixels, Int(20 * scale * scale), "\(name): retain visible translated glyphs", file: file, line: line)
        XCTAssertLessThanOrEqual(maxGlyphAlphaDifference, 1.0 / 255, "\(name): remove source ink alpha", file: file, line: line)
        XCTAssertLessThanOrEqual(maxBlankAlphaDifference, 1.0 / 255, "\(name): preserve background transparency and panel edges", file: file, line: line)
        XCTAssertLessThanOrEqual(maxPremultipliedDifference, 2.0 / 255, "\(name): preserve the background's premultiplied color", file: file, line: line)
    }

    private func backgroundRecoveryFixture(
        style: BackgroundFixtureStyle, scale: CGFloat, colorSpace: NSColorSpace
    ) throws -> (source: NSImage, clean: NSBitmapImageRep, before: NSBitmapImageRep,
                 sourceRect: CGRect, block: ImageTranslationBlock) {
        let size = CGSize(width: 520, height: 180)
        let sourceInk: NSColor
        if style == .lowContrast {
            sourceInk = NSColor(srgbRed: 0.95, green: 0.95, blue: 0.95, alpha: 1)
        } else {
            sourceInk = style == .subtleDark ? .white : .black
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 24),
            .foregroundColor: sourceInk
        ]
        let sourceText = "SOURCE BACKGROUND TAIL" as NSString
        let textSize = sourceText.size(withAttributes: attributes)
        let sourceRect = CGRect(origin: CGPoint(x: 48, y: 76), size: textSize)
        // Narrow-strip samples outside the text's padded bounds hit the page.
        // Subtle cards keep three sides of sampling inside and one outside,
        // exposing the old global-color harmonization even with a local majority.
        let cardRect: CGRect
        if [.narrowColor, .lightStripOnDark, .lightStripOnDarkLooseOCR].contains(style) {
            cardRect = sourceRect.insetBy(dx: -4, dy: -4)
        } else {
            cardRect = CGRect(x: sourceRect.minX - 24, y: sourceRect.minY - 12,
                              width: sourceRect.width + 48, height: sourceRect.height + 20)
        }
        let raw = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let bitmap = try XCTUnwrap(raw.retagging(with: colorSpace))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let u = (CGFloat(x) + 0.5) / CGFloat(bitmap.pixelsWide)
                let v = (CGFloat(y) + 0.5) / CGFloat(bitmap.pixelsHigh)
                let point = CGPoint(x: u * size.width, y: (1 - v) * size.height)
                let inside = cardRect.contains(point)
                let channels: [CGFloat]
                switch style {
                case .narrowColor:
                    channels = inside ? [0.28, 0.78, 0.44] : [1, 1, 1]
                case .lightStripOnDark, .lightStripOnDarkLooseOCR:
                    channels = inside ? [0.96, 0.94, 0.82] : [0.18, 0.18, 0.18]
                case .lowContrast, .mixedEmphasis:
                    channels = [1, 1, 1]
                case .subtleLight:
                    channels = Array(repeating: inside ? 250.0 / 255 : 1, count: 3)
                case .subtleDark:
                    channels = Array(repeating: inside ? 25.0 / 255 : 21.0 / 255, count: 3)
                case .gradient:
                    channels = [0.54 + 0.25 * u + 0.12 * v,
                                0.78 - 0.18 * u + 0.10 * v,
                                0.64 + 0.10 * u + 0.17 * v]
                case .nonlinearGradient:
                    channels = [0.44 + 0.40 * u * u + 0.06 * v,
                                0.82 - 0.28 * u * u + 0.04 * v,
                                0.58 + 0.18 * u * u + 0.08 * v]
                case .texturedGradient:
                    let tileX = Int((CGFloat(x) + 0.5) / scale) % 7
                    let tileY = Int((CGFloat(y) + 0.5) / scale) % 5
                    let noise = CGFloat((tileX * 11 + tileY * 17 + tileX * tileY * 3) % 9 - 4) / 255
                    channels = [0.54 + 0.25 * u + 0.12 * v + noise,
                                0.78 - 0.18 * u + 0.10 * v + noise,
                                0.64 + 0.10 * u + 0.17 * v + noise]
                }
                let offset = y * bitmap.bytesPerRow + x * 4
                for component in 0..<3 {
                    pixels[offset + component] = UInt8((channels[component] * 255).rounded())
                }
                pixels[offset + 3] = 255
            }
        }
        let clean = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(bitmap.representation(using: .png, properties: [:]))))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        let attributedSource = NSMutableAttributedString(string: sourceText as String, attributes: attributes)
        if style == .mixedEmphasis {
            attributedSource.addAttribute(.foregroundColor, value: NSColor.red, range: sourceText.range(of: "TAIL"))
        }
        attributedSource.draw(at: sourceRect.origin)
        NSGraphicsContext.restoreGraphicsState()
        bitmap.size = size
        let before = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(bitmap.representation(using: .png, properties: [:]))))
        let source = NSImage(size: size)
        source.addRepresentation(bitmap)
        // OCR leading can cross a real card boundary. Those dark pixels have
        // the same contrast polarity as the black text but are not source ink.
        let recognizedRect = style == .lightStripOnDarkLooseOCR
            ? sourceRect.insetBy(dx: -6, dy: -6) : sourceRect
        let rect = ImageTranslationLineRect(x: Double(recognizedRect.minX / size.width),
            y: Double((size.height - recognizedRect.maxY) / size.height),
            width: Double(recognizedRect.width / size.width), height: Double(recognizedRect.height / size.height))
        let block = ImageTranslationBlock(sourceID: "background", text: "译文",
            x: rect.x, y: rect.y, width: rect.width, height: rect.height,
            lineRects: [rect], textRects: [rect], translationStrategy: .block,
            textColor: "#0000ff", alignment: "left", fontSize: 24.0 / Double(size.height))
        return (source, clean, before, recognizedRect, block)
    }

    func testInlineSentenceClosesFormulaGapsAndKeepsPixelsAndHighlights() throws {
        for scale: CGFloat in [1, 2] {
            let fixture = try inlineFlowFixture(scale: scale)
            let pairs = ["prefix": "取值", "suffix": "时成立"].map { id, text in
                ImageTranslationHighlightPair(id: id, sourceID: "sentence", targetText: text,
                    sourceRects: [], translatedRects: [])
            }
            let result = try XCTUnwrap(ImageTranslationRenderer.renderDataWithHighlights(
                sourceData: fixture.data, blocks: fixture.blocks, highlightPairs: pairs))
            let placement = try XCTUnwrap(result.formulaPlacements.first)
            XCTAssertEqual(result.formulaPlacements.count, 1)
            XCTAssertLessThan(placement.targetRect.minX, placement.sourceRect.minX - 100)
            XCTAssertEqual(placement.targetRect.size, placement.sourceRect.size)
            XCTAssertEqual(placement.targetRect.minY, placement.sourceRect.minY)
            let prefix = try XCTUnwrap(result.translatedHighlightRects["prefix"]?.first)
            let suffix = try XCTUnwrap(result.translatedHighlightRects["suffix"]?.first)
            XCTAssertLessThanOrEqual(abs(placement.targetRect.minX - prefix.maxX * 640), 12)
            XCTAssertLessThanOrEqual(abs(suffix.minX * 640 - placement.targetRect.maxX), 12)
            let original = try XCTUnwrap(NSBitmapImageRep(data: fixture.data))
            let output = try XCTUnwrap(NSBitmapImageRep(data: result.data))
            var sourceInkPixels = 0
            let dx = Int(((placement.targetRect.minX - placement.sourceRect.minX) * scale).rounded())
            for y in Int((200 - placement.sourceRect.maxY) * scale)..<Int((200 - placement.sourceRect.minY) * scale) {
                for x in Int(placement.sourceRect.minX * scale)..<Int(placement.sourceRect.maxX * scale) {
                    let expected = try XCTUnwrap(original.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    if expected.redComponent < 0.5 { sourceInkPixels += 1 }
                    let actual = try XCTUnwrap(output.colorAt(x: x + dx, y: y)?.usingColorSpace(.sRGB))
                    XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 1.0 / 255)
                    XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 1.0 / 255)
                    XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 1.0 / 255)
                    let erased = try XCTUnwrap(output.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    XCTAssertGreaterThan(min(erased.redComponent, erased.greenComponent, erased.blueComponent), 0.98)
                }
            }
            XCTAssertGreaterThan(sourceInkPixels, 100, "The fixture must contain visible formula ink")
            if scale == 1 {
                try XCTUnwrap(output.representation(using: .png, properties: [:]))
                    .write(to: FileManager.default.temporaryDirectory.appendingPathComponent("OpenLens-inline-flow-after.png"))
                try fixture.data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("OpenLens-inline-flow-before.png"))
            }
        }
    }

    func testIncompleteInlineSentenceKeepsFormulaAtSource() throws {
        let fixture = try inlineFlowFixture(includeSuffix: false)
        XCTAssertTrue(fixture.blocks.allSatisfy { $0.inlineMathRects.isEmpty })
        let result = try XCTUnwrap(ImageTranslationRenderer.renderDataWithHighlights(
            sourceData: fixture.data, blocks: fixture.blocks, highlightPairs: []))
        XCTAssertTrue(result.formulaPlacements.isEmpty)
    }

    func testInlineFormulaKeepsItsAnchorOnVaryingBackground() throws {
        let fixture = try inlineFlowFixture(gradientBackground: true)
        let result = try XCTUnwrap(ImageTranslationRenderer.renderDataWithHighlights(
            sourceData: fixture.data, blocks: fixture.blocks, highlightPairs: []))
        XCTAssertTrue(result.formulaPlacements.isEmpty, "Do not move a formula's background patch across a gradient")
        let source = try XCTUnwrap(NSBitmapImageRep(data: fixture.data))
        let output = try XCTUnwrap(NSBitmapImageRep(data: result.data))
        for y in 70..<106 { for x in 310..<370 {
            let expected = try XCTUnwrap(source.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            let actual = try XCTUnwrap(output.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 1.0 / 255)
            XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 1.0 / 255)
            XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 1.0 / 255)
            XCTAssertEqual(actual.alphaComponent, expected.alphaComponent, accuracy: 1.0 / 255)
        } }
    }

    func testLongInlineTranslationFallsBackWithoutMovingFormula() throws {
        let fixture = try inlineFlowFixture(prefix: String(repeating: "完整保留含义", count: 15))
        let result = try XCTUnwrap(ImageTranslationRenderer.renderDataWithHighlights(
            sourceData: fixture.data, blocks: fixture.blocks, highlightPairs: []))
        XCTAssertTrue(result.formulaPlacements.isEmpty)
    }

    func testInlineFormulaKeepsItsAnchorOnTextureAndVaryingOpacity() throws {
        for varyingOpacity in [false, true] {
            let fixture = try inlineFlowFixture(varyingOpacity: varyingOpacity, texturedBackground: !varyingOpacity)
            let result = try XCTUnwrap(ImageTranslationRenderer.renderDataWithHighlights(
                sourceData: fixture.data, blocks: fixture.blocks, highlightPairs: []))
            XCTAssertTrue(result.formulaPlacements.isEmpty,
                          "A flat average color must not move a textured or changing-opacity tile")
            let source = try XCTUnwrap(NSBitmapImageRep(data: fixture.data))
            let output = try XCTUnwrap(NSBitmapImageRep(data: result.data))
            for y in 70..<106 { for x in 310..<370 {
                let expected = try XCTUnwrap(source.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                let actual = try XCTUnwrap(output.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                XCTAssertEqual(actual.alphaComponent, expected.alphaComponent, accuracy: 1.0 / 255)
                XCTAssertEqual(actual.redComponent * actual.alphaComponent,
                               expected.redComponent * expected.alphaComponent, accuracy: 1.0 / 255)
                XCTAssertEqual(actual.greenComponent * actual.alphaComponent,
                               expected.greenComponent * expected.alphaComponent, accuracy: 1.0 / 255)
                XCTAssertEqual(actual.blueComponent * actual.alphaComponent,
                               expected.blueComponent * expected.alphaComponent, accuracy: 1.0 / 255)
            } }
        }
    }

    func testInlineFlowAvoidsUnrelatedFormulaInDestination() throws {
        let fixture = try inlineFlowFixture()
        let obstacle = ImageTranslationLineRect(x: 100.0 / 640, y: 0.35, width: 20.0 / 640, height: 0.18)
        let blocks = fixture.blocks.map { block in
            ImageTranslationBlock(sourceID: block.sourceID, text: block.text,
                x: block.x, y: block.y, width: block.width, height: block.height,
                lineRects: block.lineRects, textRects: block.textRects,
                protectedRects: block.protectedRects, mathRects: block.mathRects + [obstacle],
                inlineMathRects: block.inlineMathRects, translationStrategy: .selective,
                textColor: block.textColor, alignment: block.alignment, fontSize: block.fontSize)
        }
        let result = try XCTUnwrap(ImageTranslationRenderer.renderDataWithHighlights(
            sourceData: fixture.data, blocks: blocks, highlightPairs: []))
        XCTAssertTrue(result.formulaPlacements.isEmpty)
    }

    private func inlineFlowFixture(
        scale: CGFloat = 1, includeSuffix: Bool = true, prefix: String = "取值", gradientBackground: Bool = false,
        varyingOpacity: Bool = false, texturedBackground: Bool = false
    ) throws -> (data: Data, blocks: [ImageTranslationBlock]) {
        let source = try sourceImage(size: CGSize(width: 640, height: 200), scale: Int(scale))
        let bitmap = try XCTUnwrap(source.representations.first as? NSBitmapImageRep)
        if gradientBackground {
            for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
                let value = 0.65 + 0.3 * CGFloat(x) / CGFloat(bitmap.pixelsWide)
                bitmap.setColor(NSColor(deviceRed: value, green: value, blue: value, alpha: 1), atX: x, y: y)
            } }
        }
        if varyingOpacity || texturedBackground {
            for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
                let value: CGFloat = varyingOpacity ? 1 : (((x / 7 + y / 5) % 2 == 0) ? 0.77 : 0.83)
                let alpha: CGFloat = varyingOpacity ? 0.2 + 0.6 * CGFloat(x) / CGFloat(bitmap.pixelsWide) : 1
                bitmap.setColor(NSColor(deviceRed: value, green: value, blue: value, alpha: alpha), atX: x, y: y)
            } }
        }
        let formulaInk = NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 1)
        // An asymmetric formula fixture catches resampling, flipped crops and
        // accidentally restoring fraction bars at their old coordinates.
        for y in Int(74 * scale)..<Int(102 * scale) {
            for x in Int(314 * scale)..<Int(366 * scale) {
                if y < Int(79 * scale) || x < Int(319 * scale) || y > Int(97 * scale) {
                    bitmap.setColor(formulaInk, atX: x, y: y)
                }
            }
        }
        let region = ImageTranslationSourceRegion(id: "sentence",
            sourceText: "The value of ⟦math_1⟧ satisfies the condition", x: 0.0625, y: 0.35,
            width: 0.875, height: 0.18, imageAspectRatio: 3.2,
            tokens: [
                ImageTranslationSourceToken(text: "The value of", x: 40.0 / 640, y: 0.35, width: 260.0 / 640, height: 0.18),
                ImageTranslationSourceToken(text: "⟦math_1⟧", x: 310.0 / 640, y: 0.35, width: 60.0 / 640, height: 0.18, isMathematical: true),
                ImageTranslationSourceToken(text: "satisfies the condition", x: 380.0 / 640, y: 0.35, width: 220.0 / 640, height: 0.18)
            ], translationStrategy: .selective, textColor: "#0000ff", fontSize: 0.12)
        var segments = [ImageTranslationReplacementSegment(tokenStart: 0, tokenEnd: 1, text: prefix)]
        if includeSuffix { segments.append(ImageTranslationReplacementSegment(tokenStart: 2, tokenEnd: 3, text: "时成立")) }
        let blocks = ImageTranslationMerger.merge(replacements: [
            ImageTranslationReplacement(id: region.id, text: "", segments: segments)
        ], regions: [region])
        return (try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), blocks)
    }

    func testShortChineseConnectorUsesOneReadableLineBetweenFormulas() throws {
        let source = try sourceImage(size: CGSize(width: 500, height: 240), scale: 1)
        let bitmap = try XCTUnwrap(source.representations.first as? NSBitmapImageRep)
        let formulas = [CGRect(x: 200, y: 80, width: 80, height: 50),
                        CGRect(x: 320, y: 80, width: 80, height: 50)]
        let black = NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 1)
        for rect in formulas + [CGRect(x: 290, y: 95, width: 20, height: 18)] {
            for y in Int(rect.minY)..<Int(rect.maxY) {
                for x in Int(rect.minX)..<Int(rect.maxX) { bitmap.setColor(black, atX: x, y: y) }
            }
        }
        let math = formulas.map {
            ImageTranslationLineRect(x: $0.minX / 500, y: $0.minY / 240,
                width: $0.width / 500, height: $0.height / 240)
        }
        let line = ImageTranslationLineRect(x: 288.0 / 500, y: 80.0 / 240,
                                            width: 24.0 / 500, height: 50.0 / 240)
        let block = ImageTranslationBlock(sourceID: "connector", text: "中的",
            x: line.x, y: line.y, width: line.width, height: line.height,
            lineRects: [line], textRects: [line], protectedRects: math, mathRects: math,
            translationStrategy: .selective, textColor: "#0000ff", fontSize: 0.15)
        // Encode the mutated bitmap directly. NSImage may cache its original
        // white representation before setColor updates the backing pixels.
        let sourceData = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let encodedSource = try XCTUnwrap(NSBitmapImageRep(data: sourceData))
        for rect in formulas {
            let pixel = try XCTUnwrap(encodedSource.colorAt(x: Int(rect.midX), y: Int(rect.midY))?.usingColorSpace(.sRGB))
            XCTAssertLessThan(max(pixel.redComponent, pixel.greenComponent, pixel.blueComponent), 0.01,
                              "The encoded input must contain the black formula fixture")
        }
        let output = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(
            ImageTranslationRenderer.renderData(sourceData: sourceData, blocks: [block]))))
        var blueInk = CGRect.null
        for y in 60..<150 { for x in 190..<410 {
            let pixel = try XCTUnwrap(output.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            if pixel.blueComponent > 0.65 && pixel.redComponent < 0.35 && pixel.greenComponent < 0.35 {
                blueInk = blueInk.union(CGRect(x: x, y: y, width: 1, height: 1))
            }
        } }
        XCTAssertFalse(blueInk.isNull)
        XCTAssertGreaterThanOrEqual(blueInk.height, 12, "The connector must remain readable")
        XCTAssertGreaterThan(blueInk.width, blueInk.height * 1.45, "Do not stack two tiny glyphs vertically")
        XCTAssertGreaterThanOrEqual(blueInk.minX, 280)
        XCTAssertLessThanOrEqual(blueInk.maxX, 320)
        var changedFormulaPixels = 0
        for rect in formulas {
            for y in Int(rect.minY)..<Int(rect.maxY) {
                for x in Int(rect.minX)..<Int(rect.maxX) {
                    let pixel = try XCTUnwrap(output.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    if max(pixel.redComponent, pixel.greenComponent, pixel.blueComponent) >= 0.01 {
                        changedFormulaPixels += 1
                    }
                }
            }
        }
        XCTAssertEqual(changedFormulaPixels, 0, "Every protected source formula pixel must remain black")
    }

    func testChartStrokeSurvivesLabelErasureWithoutRestoringEnglishGlyphs() throws {
        let source = try sourceImage(size: CGSize(width: 1000, height: 600), scale: 1)
        let bitmap = try XCTUnwrap(source.representations.first as? NSBitmapImageRep)
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        ("OLD LABEL" as NSString).draw(at: CGPoint(x: 500, y: 310), withAttributes: [
            .font: NSFont.systemFont(ofSize: 32), .foregroundColor: NSColor.black
        ])
        NSColor.red.setStroke()
        let curve = NSBezierPath()
        curve.move(to: CGPoint(x: 150, y: 324)); curve.line(to: CGPoint(x: 850, y: 324))
        curve.lineWidth = 2; curve.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let line = ImageTranslationLineRect(x: 0.2, y: 0.40, width: 0.65, height: 0.10)
        let glyphs = ImageTranslationLineRect(x: 0.49, y: 0.40, width: 0.22, height: 0.10)
        let block = ImageTranslationBlock(sourceID: "chart-label", text: "标签", x: line.x, y: line.y,
            width: line.width, height: line.height, lineRects: [line], textRects: [glyphs],
            textColor: "#0000ff", fontSize: 0.04)
        let data = try XCTUnwrap(source.tiffRepresentation)
        let rendered = try XCTUnwrap(ImageTranslationRenderer.renderData(sourceData: data, blocks: [block]))
        let output = try XCTUnwrap(NSBitmapImageRep(data: rendered))
        for x in stride(from: 250, to: 800, by: 10) {
            let pixel = try XCTUnwrap(output.colorAt(x: x, y: 275)?.usingColorSpace(.sRGB))
            XCTAssertGreaterThan(pixel.redComponent, 0.9)
            XCTAssertLessThan(pixel.greenComponent, 0.15, "The continuous chart stroke must survive the erase rectangle")
        }
        var removed = 0
        for y in 252..<266 { for x in 570..<680 {
            guard let before = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                  max(before.redComponent, before.greenComponent, before.blueComponent) < 0.2 else { continue }
            let after = try XCTUnwrap(output.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            if min(after.redComponent, after.greenComponent, after.blueComponent) > 0.9 { removed += 1 }
        } }
        XCTAssertGreaterThan(removed, 30, "Restoring a curve must not bring back the connected English label")
    }

    func testSemiboldSourceWeightDoesNotBecomeBold() {
        XCTAssertEqual(TranslationTypography.fontWeight(from: "semibold"), .semibold)
        XCTAssertEqual(TranslationTypography.fontWeight(from: "bold"), .bold)
        XCTAssertEqual(TranslationTypography.fontWeight(from: nil), .regular)
    }

    func testTallFormulaDoesNotInflateAdjacentMultilineProse() throws {
        let size = CGSize(width: 1000, height: 300)
        let source = NSImage(size: size)
        source.lockFocus()
        NSColor.white.setFill()
        CGRect(origin: .zero, size: size).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 30), .foregroundColor: NSColor.black]
        ("Input" as NSString).draw(at: CGPoint(x: 24, y: 220), withAttributes: attributes)
        ("Output" as NSString).draw(at: CGPoint(x: 800, y: 220), withAttributes: attributes)
        ("A second ordinary line" as NSString).draw(at: CGPoint(x: 24, y: 145), withAttributes: attributes)
        NSColor.black.setStroke()
        let formula = NSBezierPath(rect: CGRect(x: 180, y: 190, width: 560, height: 95))
        formula.lineWidth = 2
        formula.stroke()
        source.unlockFocus()
        let formulaRect = ImageTranslationLineRect(x: 0.178, y: 0.04, width: 0.564, height: 0.333)
        let block = ImageTranslationBlock(
            sourceID: "inflated-lines", text: "译文首行\n第二行末尾",
            x: 0.02, y: 0.04, width: 0.93, height: 0.52,
            lineRects: [
                ImageTranslationLineRect(x: 0.02, y: 0.04, width: 0.93, height: 0.34),
                ImageTranslationLineRect(x: 0.02, y: 0.39, width: 0.93, height: 0.17)
            ],
            textRects: [
                ImageTranslationLineRect(x: 0.02, y: 0.13, width: 0.12, height: 0.16),
                ImageTranslationLineRect(x: 0.795, y: 0.13, width: 0.15, height: 0.16),
                ImageTranslationLineRect(x: 0.02, y: 0.39, width: 0.4, height: 0.17)
            ],
            mathRects: [formulaRect], textColor: "#0000ff", alignment: "left", fontSize: 0.4
        )
        let outputData = try XCTUnwrap(ImageTranslationRenderer.renderData(sourceData: XCTUnwrap(source.tiffRepresentation), blocks: [block]))
        let output = try XCTUnwrap(NSBitmapImageRep(data: outputData))
        let scale = CGFloat(output.pixelsHigh) / size.height
        for (minimum, maximum) in [(0, 110), (110, 180)] {
            var inkRows = Set<Int>()
            for y in Int(CGFloat(minimum) * scale)..<Int(CGFloat(maximum) * scale) {
                for x in 0..<output.pixelsWide {
                    let color = try XCTUnwrap(output.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    if color.blueComponent > color.redComponent + 0.3,
                       color.blueComponent > color.greenComponent + 0.3 { inkRows.insert(y) }
                }
            }
            let first = try XCTUnwrap(inkRows.min(), "The translated row must remain visible")
            let last = try XCTUnwrap(inkRows.max())
            XCTAssertLessThanOrEqual(CGFloat(last - first + 1) / scale, 36, "Prose must be sized from its own ink, not the tall formula")
        }
    }

    func testSingleLineFittingMeasuresTheEntireTranslation() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let text = "A longer translated explanation must keep its final words"
        let rect = CGRect(x: 0, y: 0, width: 240, height: 32)

        let size = TranslationTypography.fittingFontSize(
            for: text,
            baseFontSize: 24,
            rect: rect,
            weight: .regular,
            paragraph: paragraph
        )
        let naturalWidth = NSAttributedString(
            string: text,
            attributes: [.font: TranslationTypography.proseFont(ofSize: size), .paragraphStyle: paragraph]
        ).size().width

        XCTAssertLessThan(size, 24 * 0.88)
        XCTAssertGreaterThanOrEqual(size, 7)
        XCTAssertLessThanOrEqual(naturalWidth, rect.width)
    }

    func testWrappedTranslationFitsItsHeight() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let text = "译文需要在原有区域内完整换行，并在中英文混排时保持清晰。This final sentence must remain visible."
        let rect = CGRect(x: 0, y: 0, width: 240, height: 62)

        let size = TranslationTypography.fittingFontSize(
            for: text,
            baseFontSize: 26,
            rect: rect,
            weight: .regular,
            paragraph: paragraph
        )
        let measured = NSAttributedString(
            string: text,
            attributes: [.font: TranslationTypography.proseFont(ofSize: size), .paragraphStyle: paragraph]
        ).boundingRect(
            with: CGSize(width: rect.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )

        XCTAssertGreaterThanOrEqual(size, 7)
        XCTAssertLessThanOrEqual(ceil(measured.height), rect.height)
        XCTAssertLessThanOrEqual(ceil(measured.width), rect.width)
    }

    func testFittingDoesNotEnlargeSmallSourceText() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        let size = TranslationTypography.fittingFontSize(
            for: "Label",
            baseFontSize: 5,
            rect: CGRect(x: 0, y: 0, width: 100, height: 12),
            weight: .regular,
            paragraph: paragraph
        )

        XCTAssertEqual(size, 5)
    }

    func testLongExplicitLinesKeepMixedScriptAndCodeTailsVisible() throws {
        let size = CGSize(width: 360, height: 240)
        let source = try sourceImage(size: size, scale: 2)
        let block = ImageTranslationBlock(
            sourceID: "paragraph",
            text: "A longer translated explanation must still include TailOne\n第二行包含 `cache_key` and keeps the final words TailTwo",
            x: 0.1,
            y: 0.2,
            width: 0.8,
            height: 0.34,
            lineRects: [
                ImageTranslationLineRect(x: 0.1, y: 0.2, width: 0.8, height: 0.12),
                ImageTranslationLineRect(x: 0.1, y: 0.4, width: 0.8, height: 0.12)
            ],
            textColor: "#0000ff",
            alignment: "left",
            fontSize: 0.1
        )
        let pairs = ["TailOne", "cache_key", "TailTwo"].map { text in
            ImageTranslationHighlightPair(
                id: text,
                sourceID: "paragraph",
                targetText: text,
                sourceRects: [],
                translatedRects: []
            )
        }

        let output = try XCTUnwrap(ImageTranslationRenderer.renderDataWithHighlights(
            sourceData: XCTUnwrap(source.tiffRepresentation),
            blocks: [block],
            highlightPairs: pairs
        ))
        let renderedImage = try XCTUnwrap(NSImage(data: output.data))
        var proposedRect = CGRect(origin: .zero, size: size)
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderedImage.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        )))

        for pair in pairs {
            let rects = try XCTUnwrap(output.translatedHighlightRects[pair.id], pair.id)
            XCTAssertFalse(rects.isEmpty, pair.id)
            XCTAssertTrue(rects.allSatisfy {
                $0.minX >= 0.09 && $0.maxX <= 0.91 && $0.minY >= 0.16 && $0.maxY <= 0.56
            }, pair.id)
            XCTAssertTrue(rects.contains { containsBlueText(bitmap, in: $0) }, pair.id)
        }
    }

    func testRenderingPreservesSourcePixelScaleAndLogicalSize() throws {
        let size = CGSize(width: 180, height: 120)
        for scale in [1, 2, 3] {
            let source = try sourceImage(size: size, scale: scale)
            let originalData = try XCTUnwrap(source.tiffRepresentation)
            let sourceBitmap = try XCTUnwrap(source.representations.first as? NSBitmapImageRep)
            let sourceDetail = try XCTUnwrap(sourceBitmap.colorAt(x: 3, y: 3)?.usingColorSpace(.sRGB))
            XCTAssertGreaterThan(sourceDetail.redComponent, 0.9)
            XCTAssertLessThan(sourceDetail.greenComponent, 0.1)
            XCTAssertGreaterThan(sourceDetail.blueComponent, 0.9)
            let rendered = try XCTUnwrap(ImageTranslationRenderer.render(
                source: PickedImage(data: Data(), mimeType: "image/tiff", fileName: "scale.tiff", image: source),
                blocks: [ImageTranslationBlock(
                    text: "中英 Test",
                    x: 0.1,
                    y: 0.1,
                    width: 0.8,
                    height: 0.2,
                    alignment: "left",
                    fontSize: 0.1
                )]
            ))
            let bitmap = try XCTUnwrap(rendered.representations.first as? NSBitmapImageRep)

            XCTAssertEqual(source.tiffRepresentation, originalData, "Rendering must not mutate the source image")
            XCTAssertEqual(rendered.size, size)
            XCTAssertEqual(bitmap.pixelsWide, Int(size.width) * scale)
            XCTAssertEqual(bitmap.pixelsHigh, Int(size.height) * scale)
            let detail = try XCTUnwrap(bitmap.colorAt(x: 3, y: 3)?.usingColorSpace(.sRGB))
            XCTAssertGreaterThan(detail.redComponent, 0.9)
            XCTAssertLessThan(detail.greenComponent, 0.1)
            XCTAssertGreaterThan(detail.blueComponent, 0.9)
        }
    }

    func testOverlongExplicitLinesWrapInsideTheOriginalBlock() throws {
        let source = try sourceImage(size: CGSize(width: 360, height: 240), scale: 2)
        let text = "This translated explanation is longer than its original line and needs wrapping to include TailOne\nA second translated explanation also needs the available paragraph space to preserve TailTwo"
        let block = ImageTranslationBlock(
            sourceID: "wrap",
            text: text,
            x: 0.1,
            y: 0.1,
            width: 0.4,
            height: 0.65,
            lineRects: [
                ImageTranslationLineRect(x: 0.1, y: 0.1, width: 0.4, height: 0.1),
                ImageTranslationLineRect(x: 0.1, y: 0.65, width: 0.4, height: 0.1)
            ],
            alignment: "left",
            fontSize: 0.08
        )
        let pairs = ["TailOne", "TailTwo"].map { text in
            ImageTranslationHighlightPair(
                id: text, sourceID: "wrap", targetText: text,
                sourceRects: [], translatedRects: []
            )
        }
        let result = try XCTUnwrap(ImageTranslationRenderer.renderDataWithHighlights(
            sourceData: XCTUnwrap(source.tiffRepresentation),
            blocks: [block],
            highlightPairs: pairs
        ))

        for pair in pairs {
            let rects = try XCTUnwrap(result.translatedHighlightRects[pair.id], pair.id)
            XCTAssertFalse(rects.isEmpty, pair.id)
            XCTAssertTrue(rects.allSatisfy {
                $0.minX >= 0.09 && $0.maxX <= 0.51 && $0.minY >= 0.09 && $0.maxY <= 0.76
            }, pair.id)
        }
    }

    func testTightlySpacedRowsDoNotErasePreviouslyRenderedGlyphs() throws {
        for scale in [1, 2] {
            let source = try sourceImage(size: CGSize(width: 360, height: 200), scale: scale)
            let first = ImageTranslationBlock(
                sourceID: "first", text: "细节 gyjp",
                x: 0.1, y: 0.2, width: 0.8, height: 0.2,
                lineRects: [ImageTranslationLineRect(x: 0.1, y: 0.2, width: 0.8, height: 0.2)],
                textColor: "#0000ff", fontSize: 0.19
            )
            let second = ImageTranslationBlock(
                sourceID: "second", text: "下一行",
                x: 0.1, y: 0.38, width: 0.8, height: 0.2,
                lineRects: [ImageTranslationLineRect(x: 0.1, y: 0.38, width: 0.8, height: 0.2)],
                textColor: "#ff0000", fontSize: 0.19
            )
            let sourceData = try XCTUnwrap(source.tiffRepresentation)
            let isolatedData = try XCTUnwrap(ImageTranslationRenderer.renderData(sourceData: sourceData, blocks: [first]))
            let combinedData = try XCTUnwrap(ImageTranslationRenderer.renderData(sourceData: sourceData, blocks: [first, second]))
            let isolated = try XCTUnwrap(NSBitmapImageRep(data: isolatedData))
            let combined = try XCTUnwrap(NSBitmapImageRep(data: combinedData))
            var sourceGlyphPixels = 0
            var erasedGlyphPixels = 0
            for y in 0..<isolated.pixelsHigh {
                for x in 0..<isolated.pixelsWide {
                    let expected = try XCTUnwrap(isolated.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    guard expected.blueComponent > expected.redComponent + 0.3,
                          expected.blueComponent > expected.greenComponent + 0.3 else { continue }
                    sourceGlyphPixels += 1
                    let actual = try XCTUnwrap(combined.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    if actual.blueComponent <= actual.redComponent + 0.3
                        || actual.blueComponent <= actual.greenComponent + 0.3 {
                        erasedGlyphPixels += 1
                    }
                }
            }
            XCTAssertGreaterThan(sourceGlyphPixels, 100, "The isolated row must contain visible test glyphs")
            XCTAssertEqual(erasedGlyphPixels, 0, "Erasing the next row must not cut off the previous row's glyphs")
        }
    }

    func testNeighboringRowsPreserveProtectedPixelsWithoutLeavingSourceTextBelow() throws {
        let source = try sourceImage(size: CGSize(width: 360, height: 200), scale: 1)
        let sourceBitmap = try XCTUnwrap(source.representations.first as? NSBitmapImageRep)
        let protectedPixelRects = [
            CGRect(x: 140, y: 50, width: 40, height: 35),
            CGRect(x: 160, y: 65, width: 40, height: 35)
        ]
        for rect in protectedPixelRects {
            for y in Int(rect.minY)..<Int(rect.maxY) {
                for x in Int(rect.minX)..<Int(rect.maxX) {
                    sourceBitmap.setColor(NSColor(deviceRed: 0.08, green: 0.65, blue: 0.22, alpha: 1), atX: x, y: y)
                }
            }
        }
        for y in 108..<114 {
            for x in 165..<175 {
                sourceBitmap.setColor(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1), atX: x, y: y)
            }
        }
        // Give the synthetic midtone pixels an explicit profile before TIFF
        // encoding, just as the real screenshot fixtures have an ICC profile.
        let taggedSourceBitmap = try XCTUnwrap(sourceBitmap.retagging(with: .sRGB))
        let taggedSource = NSImage(size: source.size)
        taggedSource.addRepresentation(taggedSourceBitmap)
        let protectedRects = protectedPixelRects.map {
            ImageTranslationLineRect(x: $0.minX / 360, y: $0.minY / 200, width: $0.width / 360, height: $0.height / 200)
        }
        let first = ImageTranslationBlock(
            sourceID: "formula", text: "前文",
            x: 0.1, y: 0.15, width: 0.3, height: 0.2,
            lineRects: [ImageTranslationLineRect(x: 0.1, y: 0.15, width: 0.3, height: 0.2)],
            protectedRects: protectedRects, mathRects: protectedRects, translationStrategy: .selective,
            textColor: "#0000ff", fontSize: 0.15
        )
        let neighbor = ImageTranslationBlock(
            sourceID: "neighbor", text: "下一行文字与公式相邻",
            x: 0.1, y: 0.38, width: 0.8, height: 0.2,
            lineRects: [ImageTranslationLineRect(x: 0.1, y: 0.38, width: 0.8, height: 0.2)],
            textColor: "#0000ff", fontSize: 0.19
        )
        let outputData = try XCTUnwrap(ImageTranslationRenderer.renderData(
            sourceData: XCTUnwrap(taggedSource.tiffRepresentation), blocks: [first, neighbor]
        ))
        let output = try XCTUnwrap(NSBitmapImageRep(data: outputData))
        for rect in protectedPixelRects {
            for y in Int(rect.minY)..<Int(rect.maxY) {
                for x in Int(rect.minX)..<Int(rect.maxX) {
                    let expected = try XCTUnwrap(taggedSourceBitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    let actual = try XCTUnwrap(output.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 1.0 / 255)
                    XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 1.0 / 255)
                    XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 1.0 / 255)
                }
            }
        }
        for y in 108..<114 {
            for x in 165..<175 {
                let actual = try XCTUnwrap(output.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                XCTAssertFalse(actual.redComponent > 0.8 && actual.greenComponent < 0.2 && actual.blueComponent < 0.2,
                               "Protect the formula rectangle, not the entire column below it")
            }
        }
    }

    func testLineExpansionPreservesCenterAndTrailingAlignmentAnchors() {
        let rows = [CGRect(x: 100, y: 80, width: 400, height: 36),
                    CGRect(x: 180, y: 20, width: 240, height: 36)]
        let sourceRect = CGRect(x: 96, y: 16, width: 408, height: 104)
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 160)
        let centered = ImageTranslationLayoutGeometry.expandedLineRects(
            rows, sourceRect: sourceRect, bounds: bounds, alignment: .center)
        for (source, expanded) in zip(rows, centered) {
            XCTAssertEqual(expanded.midX, source.midX, accuracy: 0.001)
            XCTAssertGreaterThanOrEqual(expanded.width, source.width)
            XCTAssertTrue(bounds.contains(expanded))
        }
        XCTAssertEqual(centered[0].width, centered[1].width, accuracy: 0.001)

        let rightRows = [rows[0], CGRect(x: 260, y: 20, width: 240, height: 36)]
        let trailing = ImageTranslationLayoutGeometry.expandedLineRects(
            rightRows, sourceRect: sourceRect, bounds: bounds, alignment: .right)
        for (source, expanded) in zip(rightRows, trailing) {
            XCTAssertEqual(expanded.maxX, source.maxX, accuracy: 0.001)
            XCTAssertGreaterThanOrEqual(expanded.width, source.width)
        }
        let leading = ImageTranslationLayoutGeometry.expandedLineRects(
            rows, sourceRect: sourceRect, bounds: bounds)
        XCTAssertEqual(leading.map(\.minX), rows.map(\.minX), "Keep existing paragraph and list indentation")
    }

    func testCenteredTranslatedRowsKeepTheSameVisualCenter() throws {
        let source = try sourceImage(size: CGSize(width: 600, height: 180), scale: 1)
        let rows = [ImageTranslationLineRect(x: 100.0 / 600, y: 30.0 / 180, width: 400.0 / 600, height: 40.0 / 180),
                    ImageTranslationLineRect(x: 180.0 / 600, y: 100.0 / 180, width: 240.0 / 600, height: 40.0 / 180)]
        let block = ImageTranslationBlock(text: "居中标题\n居中", x: 100.0 / 600, y: 30.0 / 180,
            width: 400.0 / 600, height: 110.0 / 180, lineRects: rows,
            textColor: "#0000ff", alignment: "center", fontSize: 24)
        let result = try XCTUnwrap(ImageTranslationRenderer.renderData(
            sourceData: XCTUnwrap(source.tiffRepresentation), blocks: [block]))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: result))
        let first = blueInkBounds(bitmap, yRange: 20..<85)
        let second = blueInkBounds(bitmap, yRange: 90..<155)
        XCTAssertFalse(first.isNull)
        XCTAssertFalse(second.isNull)
        XCTAssertEqual(first.midX, 300, accuracy: 3)
        XCTAssertEqual(second.midX, 300, accuracy: 3)
    }

    func testSourceInkCalibrationDoesNotMoveCenteredText() throws {
        let source = try sourceImage(size: CGSize(width: 600, height: 160), scale: 1)
        let bitmap = try XCTUnwrap(source.representations.first as? NSBitmapImageRep)
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 26), .foregroundColor: NSColor.black]
        let original = "Source title" as NSString
        let width = original.size(withAttributes: attributes).width
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        original.draw(at: CGPoint(x: 300 - width / 2, y: 66), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        let row = ImageTranslationLineRect(x: 100.0 / 600, y: 50.0 / 160, width: 400.0 / 600, height: 50.0 / 160)
        let block = ImageTranslationBlock(sourceID: "centered-title", text: "译文标题",
            x: row.x, y: row.y, width: row.width, height: row.height,
            lineRects: [row], textRects: [row], textColor: "#0000ff", alignment: "center", fontSize: 26)
        let result = try XCTUnwrap(ImageTranslationRenderer.renderData(
            sourceData: XCTUnwrap(bitmap.representation(using: .png, properties: [:])), blocks: [block]))
        let output = try XCTUnwrap(NSBitmapImageRep(data: result))
        let ink = blueInkBounds(output, yRange: 40..<115)
        XCTAssertFalse(ink.isNull)
        XCTAssertEqual(ink.midX, 300, accuracy: 3, "Ink calibration must retain the centered layout anchor")
    }

    private func blueInkBounds(_ bitmap: NSBitmapImageRep, yRange: Range<Int>) -> CGRect {
        var result = CGRect.null
        for y in yRange { for x in 0..<bitmap.pixelsWide {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                  color.blueComponent > 0.65, color.redComponent < 0.35, color.greenComponent < 0.35 else { continue }
            result = result.union(CGRect(x: x, y: y, width: 1, height: 1))
        } }
        return result
    }

    private func sourceImage(size: CGSize, scale: Int) throws -> NSImage {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width) * scale,
            pixelsHigh: Int(size.height) * scale,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSBezierPath(rect: CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh)).fill()
        NSGraphicsContext.restoreGraphicsState()
        // A one-pixel feature must survive even when source and display scales differ.
        bitmap.setColor(NSColor(deviceRed: 1, green: 0, blue: 1, alpha: 1), atX: 3, y: 3)
        bitmap.size = size
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        return image
    }

    private func containsBlueText(_ bitmap: NSBitmapImageRep, in rect: CGRect) -> Bool {
        let minX = max(0, Int(rect.minX * CGFloat(bitmap.pixelsWide)))
        let maxX = min(bitmap.pixelsWide, Int(ceil(rect.maxX * CGFloat(bitmap.pixelsWide))))
        let minY = max(0, Int(rect.minY * CGFloat(bitmap.pixelsHigh)))
        let maxY = min(bitmap.pixelsHigh, Int(ceil(rect.maxY * CGFloat(bitmap.pixelsHigh))))
        guard minX < maxX, minY < maxY else { return false }
        for y in minY..<maxY {
            for x in minX..<maxX {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.blueComponent > color.redComponent + 0.3,
                   color.blueComponent > color.greenComponent + 0.3 { return true }
            }
        }
        return false
    }
}
