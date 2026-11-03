import AppKit
import XCTest
@testable import Marr

final class TranslationRendererTests: XCTestCase {
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

    func testVectorizationSlidePreservesMatricesAndFormulaPixels() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "vectorization-source", withExtension: "png"))
        let data = try Data(contentsOf: url)
        let image = try XCTUnwrap(NSImage(data: data))
        let started = Date()
        let regions = try ImageTranslationTextRecognizer.regions(for: PickedImage(
            data: data, mimeType: "image/png", fileName: url.lastPathComponent, image: image
        ))
        let recognizedAt = Date()
        let targets = [
            ("Vectorization", "向量化"),
            ("Computing the squared", "计算整个数据集的平方误差代价："),
            ("Sometimes we may use", "有时我们也可以使用"),
            ("without a normalizer", "而不使用归一化因子。这对应于"),
            ("to the sum of losses", "损失之和，而非平均损失。最小化解不依赖于 N"),
            ("but optimization might", "（但优化过程可能受影响！）。"),
            ("We can also add", "我们还可以在设计矩阵中加入一列 1，将偏置与权重合并，"),
            ("and conveniently write", "并简洁地写为"),
            ("Then, our predictions", "于是，预测可以简化为")
        ]
        var translatedPrefixes = Set<String>()
        func translated(_ rawSource: String) throws -> String {
            let source = rawSource.replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
            if source.trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines)) == "and" { return "以及" }
            let matches = targets.filter { source.contains($0.0) }
            XCTAssertFalse(matches.isEmpty, "Unexpected formula or prose sent for translation: \(source)")
            translatedPrefixes.formUnion(matches.map(\.0))
            return matches.map(\.1).joined(separator: " ")
        }
        var replacements: [ImageTranslationReplacement] = []
        for region in regions where region.requiresTranslation {
            if region.translationStrategy == .selective {
                var ranges: [Range<Int>] = []
                var start: Int?
                for index in region.tokens.indices {
                    if region.tokens[index].isProtected {
                        if let lower = start { ranges.append(lower..<index) }
                        start = nil
                    } else if start == nil { start = index }
                }
                if let start { ranges.append(start..<region.tokens.count) }
                let segments = try ranges.map { range in
                    ImageTranslationReplacementSegment(tokenStart: range.lowerBound, tokenEnd: range.upperBound,
                        text: try translated(region.tokens[range].map(\.text).joined(separator: " ")))
                }
                replacements.append(ImageTranslationReplacement(id: region.id, text: segments.map(\.text).joined(), segments: segments))
            } else {
                replacements.append(ImageTranslationReplacement(id: region.id, text: try translated(region.sourceText)))
            }
        }
        XCTAssertEqual(translatedPrefixes, Set(targets.map(\.0)), "Every prose row must remain available for translation")
        let blocks = ImageTranslationResponseParser.merge(replacements: replacements, regions: regions)
        let renderingStartedAt = Date()
        let outputData = try XCTUnwrap(ImageTranslationRenderer.renderData(sourceData: data, blocks: blocks))
        let renderedAt = Date()
        let output = try XCTUnwrap(NSBitmapImageRep(data: outputData))
        let original = try XCTUnwrap(NSBitmapImageRep(data: data))
        // Fixed visual regions from the real screenshot, independent of the
        // detector's own output, include OCR-missing norm and matrix strokes.
        let formulaRects = [
            CGRect(x: 574, y: 195, width: 279, height: 141),
            CGRect(x: 437, y: 351, width: 243, height: 70),
            CGRect(x: 260, y: 630, width: 490, height: 150),
            CGRect(x: 864, y: 612, width: 296, height: 174)
        ]
        for rect in formulaRects {
            var ink = 0
            var changed = 0
            for y in Int(rect.minY)..<Int(rect.maxY) {
                for x in Int(rect.minX)..<Int(rect.maxX) {
                    let expected = try XCTUnwrap(original.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    let actual = try XCTUnwrap(output.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    if max(expected.redComponent, expected.greenComponent, expected.blueComponent) < 0.5 { ink += 1 }
                    if max(abs(expected.redComponent - actual.redComponent), abs(expected.greenComponent - actual.greenComponent), abs(expected.blueComponent - actual.blueComponent)) > 1.0 / 255 { changed += 1 }
                }
            }
            XCTAssertGreaterThan(ink, 100)
            XCTAssertEqual(changed, 0, "The entire original formula must survive, including strokes omitted by OCR: \(rect)")
        }
        let preview = FileManager.default.temporaryDirectory.appendingPathComponent("OpenLens-vectorization-after.png")
        try XCTUnwrap(output.representation(using: .png, properties: [:])).write(to: preview)
        print("Vectorization local OCR/protection: \(recognizedAt.timeIntervalSince(started)) s; render: \(renderedAt.timeIntervalSince(renderingStartedAt)) s; preview: \(preview.path)")
    }

    func testSemiboldSourceWeightDoesNotBecomeBold() {
        XCTAssertEqual(ImageTranslationRenderer.fontWeight(from: "semibold"), .semibold)
        XCTAssertEqual(ImageTranslationRenderer.fontWeight(from: "bold"), .bold)
        XCTAssertEqual(ImageTranslationRenderer.fontWeight(from: nil), .regular)
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

        let size = ImageTranslationRenderer.fittingFontSize(
            for: text,
            baseFontSize: 24,
            rect: rect,
            weight: .regular,
            paragraph: paragraph
        )
        let naturalWidth = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: size), .paragraphStyle: paragraph]
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

        let size = ImageTranslationRenderer.fittingFontSize(
            for: text,
            baseFontSize: 26,
            rect: rect,
            weight: .regular,
            paragraph: paragraph
        )
        let measured = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: size), .paragraphStyle: paragraph]
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
        let size = ImageTranslationRenderer.fittingFontSize(
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

    func testRealMachineLearningSlideKeepsTextAnchorsAndSourceIllustrations() throws {
        let fixtureURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ml-slide-source", withExtension: "png"))
        let sourceData = try Data(contentsOf: fixtureURL)
        let source = try XCTUnwrap(NSImage(data: sourceData))
        let picked = PickedImage(data: sourceData, mimeType: "image/png", fileName: fixtureURL.lastPathComponent, image: source)
        let regions = try ImageTranslationTextRecognizer.regions(for: picked)
        let translations: [(source: String, target: String)] = [
            ("Implementing machine learning", "实现机器学习系统"),
            ("You will often", "你通常需要先用纸笔推导算法，然后将数学表达式转换为代码。"),
            ("Array processing", "数组处理（NumPy）"),
            ("vectorize computations", "将计算向量化（用矩阵或向量运算来表达），以利用硬件效率。"),
            ("This also makes", "这也会让你的代码更简洁、更易读！")
        ]
        var matchedRegions: [ImageTranslationSourceRegion] = []
        let replacements = try translations.map { translation in
            let region = try XCTUnwrap(regions.first { $0.sourceText.contains(translation.source) }, translation.source)
            matchedRegions.append(region)
            return ImageTranslationReplacement(id: region.id, text: translation.target)
        }
        XCTAssertEqual(Set(matchedRegions.map(\.id)).count, 5, "Title, parent bullets and child bullets need separate source anchors")
        let blocks = ImageTranslationResponseParser.merge(replacements: replacements, regions: regions)
        XCTAssertEqual(blocks.count, 5)
        let pairs = replacements.map { replacement in
            ImageTranslationHighlightPair(
                id: replacement.id, sourceID: replacement.id, targetText: replacement.text,
                sourceRects: [], translatedRects: []
            )
        }
        let output = try XCTUnwrap(ImageTranslationRenderer.renderDataWithHighlights(
            sourceData: sourceData, blocks: blocks, highlightPairs: pairs
        ))

        for region in matchedRegions.dropFirst() {
            let firstLine = try XCTUnwrap(region.lineRects.min { $0.y < $1.y })
            let rects = try XCTUnwrap(output.translatedHighlightRects[region.id], region.sourceText)
            let firstGlyphLine = try XCTUnwrap(rects.min { $0.minY < $1.minY })
            XCTAssertLessThan(firstGlyphLine.minY, CGFloat(firstLine.y + firstLine.height * 0.5), "Translated list text must stay beside its original marker")
            XCTAssertLessThanOrEqual(firstGlyphLine.height, CGFloat(firstLine.height * 1.1), "Body text must fit the source row")
            XCTAssertLessThan(abs(firstGlyphLine.minX - CGFloat(firstLine.x)), 0.012, "Keep the original parent/child indentation")
        }

        let sourceBitmap = try XCTUnwrap(NSBitmapImageRep(data: sourceData))
        let outputBitmap = try XCTUnwrap(NSBitmapImageRep(data: output.data))
        XCTAssertEqual(outputBitmap.pixelsWide, sourceBitmap.pixelsWide)
        XCTAssertEqual(outputBitmap.pixelsHigh, sourceBitmap.pixelsHigh)
        // This is the actual handwritten formula plus both Python examples,
        // whose identifiers were previously erased and redrawn by translation.
        var maximumIllustrationDifference: CGFloat = 0
        for y in stride(from: 450, to: 640, by: 2) {
            for x in stride(from: 35, to: 1130, by: 2) {
                let expected = try XCTUnwrap(sourceBitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                let actual = try XCTUnwrap(outputBitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                maximumIllustrationDifference = max(
                    maximumIllustrationDifference,
                    abs(actual.redComponent - expected.redComponent),
                    abs(actual.greenComponent - expected.greenComponent),
                    abs(actual.blueComponent - expected.blueComponent)
                )
            }
        }
        XCTAssertLessThanOrEqual(maximumIllustrationDifference, 0.01, "Keep the source code and formula pixels unchanged")
        var maximumSeparatorDifference: CGFloat = 0
        for y in 83...87 {
            for x in 0..<sourceBitmap.pixelsWide {
                let expected = try XCTUnwrap(sourceBitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                let actual = try XCTUnwrap(outputBitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                maximumSeparatorDifference = max(
                    maximumSeparatorDifference,
                    abs(actual.redComponent - expected.redComponent),
                    abs(actual.greenComponent - expected.greenComponent),
                    abs(actual.blueComponent - expected.blueComponent)
                )
            }
        }
        XCTAssertLessThanOrEqual(maximumSeparatorDifference, 0.01, "Keep the dotted separator below the heading")
    }

    func testWideSlideCropKeepsOriginalBulletsAndBodyIndentation() throws {
        let fixtureURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "nearest-neighbor-source", withExtension: "png"))
        let sourceData = try Data(contentsOf: fixtureURL)
        let source = try XCTUnwrap(NSImage(data: sourceData))
        let picked = PickedImage(data: sourceData, mimeType: "image/png", fileName: fixtureURL.lastPathComponent, image: source)
        let regions = try ImageTranslationTextRecognizer.regions(for: picked)
        let targets: [(String, String)] = [
            ("Suppose", "假设我们获得了一个想要进行分类的新输入向量 x。"),
            ("The idea", "思路：在训练集中找到与 x 最近的输入向量，并复制其标签。")
        ]
        let selected = try targets.map { sourceText, target in
            let region = try XCTUnwrap(regions.first { $0.sourceText.contains(sourceText) }, sourceText)
            XCTAssertTrue(region.preservesListMarker)
            XCTAssertEqual(region.kind, "list_item")
            XCTAssertEqual(ImageTranslationRenderer.fontWeight(from: region.weight), .regular)
            return (region, ImageTranslationReplacement(id: region.id, text: target))
        }
        let blocks = ImageTranslationResponseParser.merge(replacements: selected.map(\.1), regions: regions)
        XCTAssertEqual(blocks.count, 2)
        let pairs = selected.map { region, replacement in
            ImageTranslationHighlightPair(
                id: region.id, sourceID: region.id, targetText: replacement.text,
                sourceRects: [], translatedRects: []
            )
        }
        let output = try XCTUnwrap(ImageTranslationRenderer.renderDataWithHighlights(
            sourceData: sourceData, blocks: blocks, highlightPairs: pairs
        ))
        let sourceBitmap = try XCTUnwrap(NSBitmapImageRep(data: sourceData))
        let outputBitmap = try XCTUnwrap(NSBitmapImageRep(data: output.data))
        XCTAssertEqual(outputBitmap.pixelsWide, 1440)
        XCTAssertEqual(outputBitmap.pixelsHigh, 164)

        // These are the real source bullets. In a shallow crop, using image
        // height as a normalized x inset previously erased both of them.
        for centerY in [42, 88] {
            var maximumDifference: CGFloat = 0
            for y in (centerY - 7)...(centerY + 7) {
                for x in 38...54 {
                    let expected = try XCTUnwrap(sourceBitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    let actual = try XCTUnwrap(outputBitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    maximumDifference = max(
                        maximumDifference,
                        abs(actual.redComponent - expected.redComponent),
                        abs(actual.greenComponent - expected.greenComponent),
                        abs(actual.blueComponent - expected.blueComponent)
                    )
                }
            }
            XCTAssertEqual(maximumDifference, 0, accuracy: 0.01, "The original bullet must remain visible")
        }

        // Flat white pixels within the erased second row must stay white. The
        // surrounding rows and overlay controls previously tinted this gray.
        for (x, y) in [(1200, 70), (1000, 60)] {
            let expected = try XCTUnwrap(sourceBitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            let actual = try XCTUnwrap(outputBitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            XCTAssertEqual(expected.redComponent, 1, accuracy: 0.001)
            XCTAssertEqual(expected.greenComponent, 1, accuracy: 0.001)
            XCTAssertEqual(expected.blueComponent, 1, accuracy: 0.001)
            XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 1.0 / 255)
            XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 1.0 / 255)
            XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 1.0 / 255)
        }

        for (region, _) in selected {
            let rects = try XCTUnwrap(output.translatedHighlightRects[region.id])
            let glyphLine = try XCTUnwrap(rects.first)
            let sourceLine = try XCTUnwrap(region.lineRects.first)
            // Keep the source text anchor while allowing a small glyph bearing.
            // The broken crop put text at x≈42 px, in the bullet column.
            XCTAssertGreaterThanOrEqual(glyphLine.minX * 1440, sourceLine.x * 1440 - 2)
            XCTAssertGreaterThanOrEqual(glyphLine.minX * 1440, 68)
            XCTAssertLessThanOrEqual(glyphLine.minX * 1440, 89)
            XCTAssertLessThanOrEqual(glyphLine.height, CGFloat(sourceLine.height * 1.1))
            XCTAssertLessThan(abs(glyphLine.minY - CGFloat(sourceLine.y)), 0.04)
        }
    }

    func testTradeoffsSlideKeepsChildGlyphsAndOriginalFormulas() throws {
        let fixtureURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "tradeoffs-source", withExtension: "png"))
        let sourceData = try Data(contentsOf: fixtureURL)
        let source = try XCTUnwrap(NSImage(data: sourceData))
        let picked = PickedImage(data: sourceData, mimeType: "image/png", fileName: fixtureURL.lastPathComponent, image: source)
        let regions = try ImageTranslationTextRecognizer.regions(for: picked)
        let targets: [(String, [String])] = [
            ("Tradeoffs", ["选择 k 时的权衡？"]),
            ("Small", ["较小的 k"]),
            ("Good at capturing", ["擅长捕捉细粒度模式。"]),
            ("May overfit", ["可能过拟合，即对训练数据中的随机特异性较为敏感。"]),
            ("Large", ["较大的 k"]),
            ("Makes stable", ["通过对大量示例取平均来做出稳定的预测。"]),
            ("May underfit", ["可能欠拟合，即无法捕捉重要的规律。"]),
            ("Balancing", ["平衡 k"]),
            ("Optimal choice", ["k 的最优选择取决于数据点的数量 n。"]),
            ("Nice theoretical", ["若满足以下条件，则具有良好的理论性质：", "且"]),
            ("Rule of thumb", ["经验法则：选择"]),
            ("We can choose", ["我们可以使用验证集来选择 k（见下一张幻灯片）。"])
        ]
        var matchedRegions: [ImageTranslationSourceRegion] = []
        let replacements = try targets.map { prefix, translations in
            let region = try XCTUnwrap(regions.first { $0.sourceText.contains(prefix) }, prefix)
            matchedRegions.append(region)
            guard region.preservesInlineMath else {
                return ImageTranslationReplacement(id: region.id, text: translations.joined())
            }
            var ranges: [Range<Int>] = []
            var start: Int?
            for index in region.tokens.indices {
                if region.tokens[index].isProtected {
                    if let lower = start { ranges.append(lower..<index) }
                    start = nil
                } else if start == nil {
                    start = index
                }
            }
            if let start { ranges.append(start..<region.tokens.count) }
            XCTAssertEqual(ranges.count, translations.count, "Translate prose on each side of the original formula")
            return ImageTranslationReplacement(
                id: region.id, text: translations.joined(),
                segments: zip(ranges, translations).map { range, text in
                    ImageTranslationReplacementSegment(tokenStart: range.lowerBound, tokenEnd: range.upperBound, text: text)
                }
            )
        }
        XCTAssertEqual(Set(matchedRegions.map(\.id)).count, 12, "Every parent and child needs its own source anchor")
        let blocks = ImageTranslationResponseParser.merge(replacements: replacements, regions: regions)
        let outputData = try XCTUnwrap(ImageTranslationRenderer.renderData(sourceData: sourceData, blocks: blocks))
        let output = try XCTUnwrap(NSBitmapImageRep(data: outputData))
        let sourceBitmap = try XCTUnwrap(NSBitmapImageRep(data: sourceData))
        let mathTokens = regions.flatMap(\.tokens).filter(\.isMathematical)
        XCTAssertEqual(mathTokens.count, 3, "Preserve both limits and the square-root inequality")
        for token in mathTokens {
            let rect = CGRect(x: token.x * 1310, y: token.y * 690, width: token.width * 1310, height: token.height * 690).integral
            var maximumDifference: CGFloat = 0
            var sourceInkPixels = 0
            for y in Int(rect.minY)..<min(Int(rect.maxY), sourceBitmap.pixelsHigh) {
                for x in Int(rect.minX)..<min(Int(rect.maxX), sourceBitmap.pixelsWide) {
                    let expected = try XCTUnwrap(sourceBitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    let actual = try XCTUnwrap(output.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    if max(expected.redComponent, expected.greenComponent, expected.blueComponent) < 0.5 { sourceInkPixels += 1 }
                    maximumDifference = max(maximumDifference, abs(actual.redComponent - expected.redComponent),
                                            abs(actual.greenComponent - expected.greenComponent), abs(actual.blueComponent - expected.blueComponent))
                }
            }
            XCTAssertGreaterThan(sourceInkPixels, 100, "The protected box must contain the actual formula")
            XCTAssertLessThanOrEqual(maximumDifference, 1.0 / 255, "Formula strokes, fraction bar and denominator must survive neighboring rows")
        }

        for prefix in ["Good at capturing", "Makes stable"] {
            let region = try XCTUnwrap(matchedRegions.first { $0.sourceText.contains(prefix) })
            let block = try XCTUnwrap(blocks.first { $0.sourceID == region.id })
            let blueBlock = ImageTranslationBlock(
                sourceID: block.sourceID, text: block.text,
                x: block.x, y: block.y, width: block.width, height: block.height,
                lineRects: block.lineRects, preservesListMarker: block.preservesListMarker,
                textRects: block.textRects, protectedRects: block.protectedRects, mathRects: block.mathRects,
                translationStrategy: block.translationStrategy, kind: block.kind,
                textColor: "#0000ff", alignment: block.alignment, weight: block.weight, fontSize: block.fontSize
            )
            let isolatedData = try XCTUnwrap(ImageTranslationRenderer.renderData(sourceData: sourceData, blocks: [blueBlock]))
            let togetherData = try XCTUnwrap(ImageTranslationRenderer.renderData(
                sourceData: sourceData, blocks: blocks.map { $0.sourceID == region.id ? blueBlock : $0 }
            ))
            let isolated = try XCTUnwrap(NSBitmapImageRep(data: isolatedData))
            let together = try XCTUnwrap(NSBitmapImageRep(data: togetherData))
            let line = try XCTUnwrap(region.lineRects.first)
            let rect = CGRect(x: line.x * 1310, y: line.y * 690, width: line.width * 1310, height: line.height * 690).integral
            var sourceGlyphPixels = 0
            var erasedGlyphPixels = 0
            for y in Int(rect.minY)..<min(Int(rect.maxY), isolated.pixelsHigh) {
                for x in Int(rect.minX)..<min(Int(rect.maxX), isolated.pixelsWide) {
                    let expected = try XCTUnwrap(isolated.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    guard expected.blueComponent > expected.redComponent + 0.3,
                          expected.blueComponent > expected.greenComponent + 0.3 else { continue }
                    sourceGlyphPixels += 1
                    let actual = try XCTUnwrap(together.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    if actual.blueComponent <= actual.redComponent + 0.3
                        || actual.blueComponent <= actual.greenComponent + 0.3 {
                        erasedGlyphPixels += 1
                    }
                }
            }
            XCTAssertGreaterThan(sourceGlyphPixels, 100, prefix)
            XCTAssertEqual(erasedGlyphPixels, 0, "The full slide must retain every glyph of \(prefix)")
        }
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
