import AppKit
import CoreGraphics
import Foundation
import XCTest
@testable import Marr

final class TranslationRecognitionTests: XCTestCase {
    func testCourseworkScreenshotKeepsProseReferencesAndTextStyle() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "coursework-style", withExtension: "png"))
        let image = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: url)))
        // Only the source document on the right, excluding the translated overlay.
        let crop = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(x: 1020, y: 20, width: 960, height: 780)))
        let size = CGSize(width: 960, height: 780)
        let bitmap = NSBitmapImageRep(cgImage: crop)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let regions = try ImageTranslationTextRecognizer.regions(for: PickedImage(
            data: data, mimeType: "image/png", fileName: "coursework.png", image: NSImage(cgImage: crop, size: size)))
        let reference = try XCTUnwrap(regions.first { $0.sourceText.contains("Describe the advantage") })
        XCTAssertTrue(reference.codeRects.isEmpty, "subtasks2.1-2.4 is a prose reference, not code")
        XCTAssertFalse(reference.tokens.contains { $0.isProtected && $0.text.lowercased().contains("subtasks") })
        // Fixed translations isolate visual style from model variability.
        let translations: [(String, [String])] = [
            ("For a separate", ["对于一个独立的状况分类器，一个包裹的三个类别得分为", "记录的"]),
            ("condition is class", ["状况属于类别 1，要求的类别分离间隔为 1。系统不要求输出具有概率形式。"]),
            ("Define the input", ["定义输入、目标和所需输出，然后选择合适的损失函数。解释为何该形式不要求归一化的"]),
            ("class probabilities", ["类别概率。[2 分]"]),
            ("Compute every", ["计算各类别的间隔，找出起作用的项，并计算总损失。[3 分]"]),
            ("Coursework", ["AIP304 课程作业 1"]),
            ("Page 3", ["第 3 页"]),
            ("Compute a valid", ["计算远离铰链边界时的有效得分梯度，并给出恰好处于"]),
            ("contribution of", ["铰链边界上的某个类别对完整次梯度的贡献。[3 分]"]),
            ("Increase only", ["仅将正确类别的得分从 1 提高到 3。重新计算损失，并将此时的梯度"]),
            ("behavior with", ["行为与路由模型在满足所需间隔后的梯度行为对比。[2 分]"]),
            ("Describe the advantage", ["描述子任务 2.1–2.4 中使用的模型和损失函数的优缺点。"]),
            ("[5 marks]", ["[5 分]"])
        ]
        var replacements: [ImageTranslationReplacement] = []
        var pairs: [ImageTranslationHighlightPair] = []
        for region in regions where region.requiresTranslation {
            let values = try XCTUnwrap(translations.first { region.sourceText.contains($0.0) }?.1, region.sourceText)
            let slots = ImageTranslationMerger.selectiveProseRanges(in: region)
            if region.translationStrategy == .selective {
                XCTAssertEqual(slots.count, values.count, region.sourceText)
            }
            replacements.append(ImageTranslationReplacement(id: region.id,
                text: region.translationStrategy == .block ? values.joined() : "",
                segments: zip(slots, values).map {
                    ImageTranslationReplacementSegment(tokenStart: $0.lowerBound, tokenEnd: $0.upperBound, text: $1)
                }))
            pairs += values.enumerated().map { index, text in
                ImageTranslationHighlightPair(id: "\(region.id)-\(index)", sourceID: region.id, targetText: text,
                    sourceRects: [], translatedRects: [])
            }
        }
        let blocks = ImageTranslationMerger.merge(replacements: replacements, regions: regions)
        XCTAssertFalse(blocks.filter { $0.sourceID == reference.id }.contains { $0.text.contains("`") })
        let result = try XCTUnwrap(ImageTranslationRenderer.renderDataWithHighlights(
            sourceData: data, blocks: blocks, highlightPairs: pairs))
        let output = try XCTUnwrap(NSBitmapImageRep(data: result.data))
        for pair in pairs where pair.sourceID != regions.first(where: { $0.sourceText.contains("Coursework") })?.id {
            guard pair.targetText != "第 3 页" else { continue }
            let highlights = try XCTUnwrap(result.translatedHighlightRects[pair.id], pair.targetText ?? "")
            let rects = highlights.map {
                CGRect(x: $0.minX * size.width, y: (1 - $0.maxY) * size.height,
                       width: $0.width * size.width, height: $0.height * size.height)
            }
            let color = try XCTUnwrap(TranslationColorSampling.sampledForegroundColor(in: rects, bitmap: output,
                backgroundColor: .white, bounds: CGRect(origin: .zero, size: size)))
            XCTAssertLessThan(TranslationColorSampling.rgbDistance(color, .black), 0.06,
                              "Black body text must not vary by translated fragment")
        }
        let preview = FileManager.default.temporaryDirectory.appendingPathComponent("OpenLens-coursework-style-after.png")
        try XCTUnwrap(output.representation(using: .png, properties: [:])).write(to: preview)
        print("Coursework style preview: \(preview.path)")
    }

    func testDocumentReferencesDoNotBecomeCodeFonts() {
        for token in ["subtasks2.1-2.4", "subtasks2.1", "Section3.2", "figures2–4", "questions1.1—1.3"] {
            XCTAssertFalse(ImageTranslationTextRecognizer.shouldPreserveCodeToken(token), token)
            XCTAssertFalse(ImageTranslationSourcePolicy.isProtectedRecognizedToken(token, index: 3, totalCount: 8), token)
        }
        for token in ["numpy.linalg", "v1.2.3", "src/main.swift", "user_42", "layer2.weight"] {
            XCTAssertTrue(ImageTranslationTextRecognizer.shouldPreserveCodeToken(token), token)
        }
    }

    func testLossParagraphNumbersDoNotDisableInlineMathFlow() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "loss-inline-math", withExtension: "png"))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: url)))
        let crop = try XCTUnwrap(bitmap.cgImage?.cropping(to: CGRect(x: 0, y: 20, width: 1040, height: 128)))
        let source = NSBitmapImageRep(cgImage: crop)
        let data = try XCTUnwrap(source.representation(using: .png, properties: [:]))
        let regions = try ImageTranslationTextRecognizer.regions(for: PickedImage(
            data: data, mimeType: "image/png", fileName: "loss-inline-math.png",
            image: NSImage(cgImage: crop, size: CGSize(width: 1040, height: 128))))
        let decimals = regions.flatMap(\.tokens).filter { $0.text.contains("0.3132617") || $0.text.contains("0.2689414") }
        XCTAssertEqual(decimals.count, 2)
        XCTAssertTrue(decimals.allSatisfy { !$0.isProtected }, "Ordinary scalar values must remain in their prose slots")
        let rows = regions.filter(\.requiresTranslation).sorted { $0.y < $1.y }
        XCTAssertEqual(rows.count, 4)
        guard rows.count == 4 else { return }
        // Fixed translations isolate recognition/merging/rendering from model
        // variability. Every prose slot is filled, including the tiny "for".
        let text = [
            ["损失高于 0.3132617（对应", "），因为模型仍将"],
            ["未受损包裹判为高损坏概率。对于", "，得分梯度为"],
            ["−0.2689414，因此梯度下降会增大", "对于", "，正梯度使得分"],
            ["减小 z。尽管当前得分不变，学习方向却反转了。"]
        ]
        var replacements: [ImageTranslationReplacement] = []
        var pairs: [ImageTranslationHighlightPair] = []
        for (index, row) in rows.enumerated() {
            let slots = ImageTranslationMerger.selectiveProseRanges(in: row)
            XCTAssertEqual(slots.count, text[index].count)
            let segments = zip(slots, text[index]).map {
                ImageTranslationReplacementSegment(tokenStart: $0.lowerBound, tokenEnd: $0.upperBound, text: $1)
            }
            replacements.append(ImageTranslationReplacement(id: row.id,
                text: row.translationStrategy == .block ? text[index][0] : "", segments: segments))
            pairs += text[index].enumerated().map { part, value in
                ImageTranslationHighlightPair(id: "\(row.id)-\(part)", sourceID: row.id,
                    targetText: value, sourceRects: [], translatedRects: [])
            }
        }
        let blocks = ImageTranslationMerger.merge(replacements: replacements, regions: regions)
        XCTAssertTrue(blocks.filter { $0.translationStrategy == .selective }.allSatisfy { !$0.inlineMathRects.isEmpty })
        let rendered = try XCTUnwrap(ImageTranslationRenderer.renderDataWithHighlights(
            sourceData: data, blocks: blocks, highlightPairs: pairs))
        XCTAssertEqual(rendered.formulaPlacements.count, 4, "Every owned inline expression must flow with its complete row")
        for pair in pairs {
            let highlights = try XCTUnwrap(rendered.translatedHighlightRects[pair.id], pair.targetText ?? "")
            XCTAssertTrue(highlights.allSatisfy { $0.height * 128 >= 16 },
                          "A short source slot must not shrink its translation to microscopic text")
        }
        for row in rows where row.preservesInlineMath {
            let heights = pairs.filter { $0.sourceID == row.id }.flatMap {
                rendered.translatedHighlightRects[$0.id] ?? []
            }.map(\.height)
            XCTAssertLessThanOrEqual(try XCTUnwrap(heights.max()), try XCTUnwrap(heights.min()) * 1.25,
                                     "Use a consistent font size across each mixed prose/formula row")
        }
        let allHighlights = pairs.flatMap { rendered.translatedHighlightRects[$0.id] ?? [] }
        let heights = allHighlights.map { $0.height * 128 }
        XCTAssertLessThanOrEqual(try XCTUnwrap(heights.max()) - XCTUnwrap(heights.min()), 1,
                                 "The whole paragraph, including its plain final row, needs one font size")
        let starts = try rows.map { row in
            try XCTUnwrap(rendered.translatedHighlightRects["\(row.id)-0"]?.first)
        }
        let lefts = starts.map { $0.minX * 1040 }
        XCTAssertLessThanOrEqual(try XCTUnwrap(lefts.max()) - XCTUnwrap(lefts.min()), 1,
                                 "OCR box jitter must not become a ragged paragraph margin")
        let steps = zip(starts, starts.dropFirst()).map { ($1.minY - $0.minY) * 128 }
        XCTAssertLessThanOrEqual(try XCTUnwrap(steps.max()) - XCTUnwrap(steps.min()), 2,
                                 "Adjacent prose and formula rows must keep a consistent baseline rhythm")
        for row in rows {
            let tops = pairs.filter { $0.sourceID == row.id }.flatMap {
                rendered.translatedHighlightRects[$0.id] ?? []
            }.map { $0.minY * 128 }
            XCTAssertLessThanOrEqual(try XCTUnwrap(tops.max()) - XCTUnwrap(tops.min()), 1,
                                     "Fragments on one row must not use their individual OCR top edges")
        }
        let output = try XCTUnwrap(NSBitmapImageRep(data: rendered.data))
        for placement in rendered.formulaPlacements {
            XCTAssertEqual(placement.sourceRect.size, placement.targetRect.size)
            XCTAssertEqual(placement.sourceRect.minY, placement.targetRect.minY)
            let dx = Int((placement.targetRect.minX - placement.sourceRect.minX).rounded())
            var changed = 0
            for y in Int(128 - placement.sourceRect.maxY)..<Int(128 - placement.sourceRect.minY) {
                for x in Int(placement.sourceRect.minX)..<Int(placement.sourceRect.maxX) {
                    let before = try XCTUnwrap(source.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    let after = try XCTUnwrap(output.colorAt(x: x + dx, y: y)?.usingColorSpace(.sRGB))
                    if max(abs(before.redComponent - after.redComponent), abs(before.greenComponent - after.greenComponent),
                           abs(before.blueComponent - after.blueComponent)) > 1.0 / 255 { changed += 1 }
                }
            }
            XCTAssertEqual(changed, 0, "Moving inline math must preserve its original glyph pixels")
        }
        let preview = FileManager.default.temporaryDirectory.appendingPathComponent("OpenLens-loss-inline-after.png")
        try XCTUnwrap(output.representation(using: .png, properties: [:])).write(to: preview)
        print("Loss paragraph regression preview: \(preview.path)")
    }

    func testSupplementaryFastMathRequiresOperatorAndVariableOperands() {
        for text in ["w&w-", "w ← w - α", "x = y + 1", "∂J / ∂w = 0", "dx/dy = 2", "w_i - w_j"] {
            XCTAssertTrue(ImageTranslationSourcePolicy.isSupplementaryMathObservation(text), text)
        }
        for text in ["N", "=", "---", "→ → →", "• • •", "T&C", "high-quality", "x-ray", "go-to", "input/output",
                     "Gradient Descent", "Loss = prediction error", "A reasonable value = 1", "w changes by - 1"] {
            XCTAssertFalse(ImageTranslationSourcePolicy.isSupplementaryMathObservation(text), text)
        }
    }

    func testNamedEntityFalsePositiveCannotFreezeTechnicalHeadingPrefix() {
        XCTAssertEqual(ImageTranslationSourcePolicy.translationStrategy(
            tokenTexts: ["Linear", "Regression", "-", "Loss", "Function"],
            protectedIndexes: [0, 1, 2, 3], lineCount: 1
        ), .block)
        XCTAssertEqual(ImageTranslationSourcePolicy.translationStrategy(
            tokenTexts: ["Bayesian", "Inference", "-", "Introduction"],
            protectedIndexes: [0, 1, 2], lineCount: 1
        ), .block)
        XCTAssertEqual(ImageTranslationSourcePolicy.translationStrategy(
            tokenTexts: ["Rongqi", "Lu", "|", "Research", "Profile"],
            protectedIndexes: [0, 1, 2], lineCount: 1
        ), .selective)
        XCTAssertEqual(ImageTranslationSourcePolicy.translationStrategy(
            tokenTexts: ["user_42", "-", "Profile"],
            protectedIndexes: [0, 1], lineCount: 1
        ), .selective)
    }

    func testSlashProseCannotBecomeCodeBecauseOfBackgroundSamplingNoise() {
        for word in ["super/sub", "write/understand", "constraint/penalty", "input/output", "Input/Output", "w.r.t", "e.g", "i.e"] {
            XCTAssertFalse(ImageTranslationTextRecognizer.shouldPreserveCodeToken(word), word)
            XCTAssertFalse(ImageTranslationSourcePolicy.isProtectedRecognizedToken(word, index: 2, totalCount: 6), word)
        }
        for code in ["src/lib/main.swift", "src/lib/main", "src/main.swift", "np.zeros", "user_name", "VisionRequest"] {
            XCTAssertTrue(ImageTranslationTextRecognizer.shouldPreserveCodeToken(code), code)
        }
    }

    func testSentenceInitialArticlesAndFirstPersonPronounAreNotIconGlyphs() {
        for word in ["A", "a", "I"] {
            XCTAssertFalse(ImageTranslationSourcePolicy.isProtectedRecognizedToken(word, index: 0, totalCount: 5), word)
        }
        XCTAssertTrue(ImageTranslationSourcePolicy.isProtectedRecognizedToken("L", index: 0, totalCount: 5))
        XCTAssertTrue(ImageTranslationSourcePolicy.isProtectedRecognizedToken("A", index: 0, totalCount: 1))
        XCTAssertTrue(ImageTranslationSourcePolicy.isProtectedRecognizedToken("SGD", index: 0, totalCount: 5))
    }

    func testBilingualOrganizationLockupRequiresNearbyMatchingTranslation() {
        let english = CGRect(x: 0.3, y: 0.08, width: 0.4, height: 0.04)
        let chinese = CGRect(x: 0.3, y: 0.14, width: 0.4, height: 0.06)
        for organization in ["Northbridge Institute of Technology", "Riverbank University"] {
            XCTAssertTrue(ImageTranslationSourcePolicy.isBilingualOrganizationIdentity(
                organization, rect: english, targetLanguageRects: [chinese]
            ))
            XCTAssertFalse(ImageTranslationSourcePolicy.isBilingualOrganizationIdentity(
                organization, rect: english, targetLanguageRects: []
            ))
            XCTAssertFalse(ImageTranslationSourcePolicy.isBilingualOrganizationIdentity(
                organization, rect: english, targetLanguageRects: [chinese.offsetBy(dx: -0.4, dy: 0)]
            ))
            XCTAssertFalse(ImageTranslationSourcePolicy.isBilingualOrganizationIdentity(
                organization, rect: english, targetLanguageRects: [chinese.offsetBy(dx: 0, dy: 0.3)]
            ))
            XCTAssertFalse(ImageTranslationSourcePolicy.isBilingualOrganizationIdentity(
                organization, rect: english.offsetBy(dx: 0, dy: 0.4),
                targetLanguageRects: [chinese.offsetBy(dx: 0, dy: 0.4)]
            ))
        }
        for prose in ["Linear Regression - Loss Function", "The university offers several courses"] {
            XCTAssertFalse(ImageTranslationSourcePolicy.isBilingualOrganizationIdentity(
                prose, rect: english, targetLanguageRects: [chinese]
            ))
        }
    }

    func testCenteredCoverGroupNeedsMultipleIndependentAlignedLines() {
        let centered = [
            CGRect(x: 0.30, y: 0.30, width: 0.40, height: 0.05),
            CGRect(x: 0.43, y: 0.42, width: 0.14, height: 0.04),
            CGRect(x: 0.18, y: 0.54, width: 0.64, height: 0.05)
        ]
        XCTAssertEqual(ImageTranslationTextRecognizer.centeredTextBlockIndexes(
            rects: centered, lineCounts: [1, 1, 1]
        ), [0, 1, 2])
        XCTAssertTrue(ImageTranslationTextRecognizer.centeredTextBlockIndexes(
            rects: centered, lineCounts: [1, 2, 1]
        ).isEmpty)
        XCTAssertTrue(ImageTranslationTextRecognizer.centeredTextBlockIndexes(
            rects: centered, lineCounts: [1, 1, 1], excludedIndexes: [1]
        ).isEmpty)
        XCTAssertTrue(ImageTranslationTextRecognizer.centeredTextBlockIndexes(
            rects: [centered[2]], lineCounts: [1]
        ).isEmpty)
        let leftAligned = centered.map { CGRect(x: 0.1, y: $0.minY, width: $0.width, height: $0.height) }
        XCTAssertTrue(ImageTranslationTextRecognizer.centeredTextBlockIndexes(
            rects: leftAligned, lineCounts: [1, 1, 1]
        ).isEmpty)
    }

    func testMultilineAlignmentUsesRepeatedCenterOrTrailingAnchors() {
        let widths: [CGFloat] = [0.30, 0.36, 0.42]
        let centered = widths.enumerated().map { index, width in
            CGRect(x: 0.63 - width / 2, y: 0.20 + CGFloat(index) * 0.05, width: width, height: 0.04)
        }
        XCTAssertEqual(ImageTranslationTextRecognizer.multilineTextAlignment(
            lineRects: centered, imageAspectRatio: 1.6), "center")
        let right = centered.map { CGRect(x: 0.85 - $0.width, y: $0.minY, width: $0.width, height: $0.height) }
        XCTAssertEqual(ImageTranslationTextRecognizer.multilineTextAlignment(
            lineRects: right, imageAspectRatio: 1.6), "right")
        let left = centered.map { CGRect(x: 0.1, y: $0.minY, width: $0.width, height: $0.height) }
        XCTAssertEqual(ImageTranslationTextRecognizer.multilineTextAlignment(
            lineRects: left, imageAspectRatio: 1.6), "left")
        let jitter: [CGFloat] = [0.001, -0.001, 0.0005]
        XCTAssertEqual(ImageTranslationTextRecognizer.multilineTextAlignment(
            lineRects: centered.enumerated().map { $0.element.offsetBy(dx: jitter[$0.offset], dy: 0) },
            imageAspectRatio: 1.6), "center")
    }

    func testMultilineAlignmentRejectsAmbiguousBodyRowsAndHangingIndent() {
        let nearEqual = [0.40, 0.41, 0.42].enumerated().map { index, width in
            CGRect(x: 0.5 - width / 2, y: 0.2 + Double(index) * 0.05, width: width, height: 0.04)
        }
        let hanging = [CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.04),
                       CGRect(x: 0.2, y: 0.25, width: 0.4, height: 0.04),
                       CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.04)]
        let ragged = [CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.04),
                      CGRect(x: 0.16, y: 0.25, width: 0.3, height: 0.04),
                      CGRect(x: 0.12, y: 0.3, width: 0.5, height: 0.04)]
        for rows in [nearEqual, hanging, ragged, Array(ragged.prefix(2))] {
            XCTAssertEqual(ImageTranslationTextRecognizer.multilineTextAlignment(
                lineRects: rows, imageAspectRatio: 1.6), "left")
        }
        let separated = [0.30, 0.36, 0.42].enumerated().map { index, width in
            CGRect(x: 0.5 - width / 2, y: 0.2 + Double(index) * 0.2, width: width, height: 0.04)
        }
        XCTAssertEqual(ImageTranslationTextRecognizer.multilineTextAlignment(
            lineRects: separated, imageAspectRatio: 1.6), "left", "Independent controls are not one paragraph")
    }

    func testMultilineAlignmentNormalizesGlyphToleranceAcrossWideCrops() {
        for imageHeight: CGFloat in [180, 900] {
            let pixelWidths: [CGFloat] = [360, 430, 500]
            let rows = pixelWidths.enumerated().map { index, width in
                CGRect(x: (700 - width / 2) / 1200,
                       y: (30 + CGFloat(index) * 30) / imageHeight,
                       width: width / 1200, height: 24 / imageHeight)
            }
            XCTAssertEqual(ImageTranslationTextRecognizer.multilineTextAlignment(
                lineRects: rows, imageAspectRatio: 1200 / imageHeight), "center")
        }
    }

    func testSyntheticMultilineParagraphInfersCenterAndRightAlignment() throws {
        for alignment in [NSTextAlignment.center, .right] {
            let regions = try recognizeSyntheticCanvas(lines: [
                // At 22 pt, four monospaced characters plus OCR side-bearing
                // variation approach the existing 0.035 column-join limit.
                // Keep this fixture clearly inside one right-aligned block.
                ("learning can improve our results,", 300, 20, false),
                ("when we compare every method,", 327, 20, false),
                ("and examine each outcome.", 354, 20, false)
            ], alignmentOverride: alignment, monospaced: true)
            let paragraph = try XCTUnwrap(regions.first { $0.sourceText.contains("learning") }, regions.map(\.sourceText).joined(separator: " | "))
            let geometry = regions.map { "\($0.sourceText): \($0.lineRects)" }.joined(separator: " | ")
            XCTAssertEqual(paragraph.lineRects.count, 3,
                           "The fixture must exercise one multiline OCR block: \(geometry)")
            XCTAssertEqual(paragraph.translationStrategy, .block)
            XCTAssertEqual(paragraph.alignment, alignment == .center ? "center" : "right")
        }
    }

    func testLogoVerificationMapsLocalVisionCoordinatesBackToSourceImage() {
        let roi = CGRect(x: 0.35, y: 0.12, width: 0.4, height: 0.14)
        let rect = ImageTranslationTextRecognizer.fullImageRect(
            fromVisionBox: CGRect(x: 0.065, y: 0.21, width: 0.82, height: 0.60),
            withinTopLeftROI: roi
        )
        XCTAssertEqual(rect.minX, 0.376, accuracy: 0.00001)
        XCTAssertEqual(rect.minY, 0.1466, accuracy: 0.00001)
        XCTAssertEqual(rect.width, 0.328, accuracy: 0.00001)
        XCTAssertEqual(rect.height, 0.084, accuracy: 0.00001)
        XCTAssertTrue(ImageTranslationSourcePolicy.isBilingualOrganizationIdentity(
            "Northbridge Institute of Technology",
            rect: CGRect(x: 0.378, y: 0.101, width: 0.323, height: 0.036),
            targetLanguageRects: [rect]
        ))
    }

    func testSyntheticBilingualCoverKeepsLogoPixelsOutsideTranslationAndTitlesCentered() throws {
        let regions = try recognizeSyntheticCanvas(lines: [
            ("Northbridge Institute of Technology", 60, 36, true),
            // Match the bilingual lockup's visual widths, including the tighter
            // Chinese glyph boxes returned by Vision rather than font advances.
            ("北桥科学技术研究学院", 108, 48, true),
            ("Machine Learning", 320, 60, true),
            ("Lecture Two", 450, 46, true),
            ("Linear Models and Optimization", 560, 56, true)
        ])
        XCTAssertFalse(regions.contains { $0.requiresTranslation && $0.sourceText.contains("Northbridge") },
                       regions.map(\.sourceText).joined(separator: " | "))
        for prefix in ["Machine Learning", "Lecture Two", "Linear Models"] {
            let region = try XCTUnwrap(regions.first { $0.sourceText.hasPrefix(prefix) }, prefix)
            XCTAssertEqual(region.alignment, "center", region.sourceText)
            XCTAssertEqual(region.x + region.width / 2, 0.5, accuracy: 0.035)
        }
    }

    func testSyntheticTechnicalTitleAndSlashProseStayTranslatable() throws {
        let regions = try recognizeSyntheticCanvas(lines: [
            ("Linear Regression - Loss Function", 80, 48, false),
            ("Excessive super/sub scripts are hard to work with.", 260, 40, false),
            ("Algorithms are easier to write/understand.", 440, 40, false)
        ])
        let title = try XCTUnwrap(regions.first { $0.sourceText.hasPrefix("Linear Regression") })
        XCTAssertEqual(title.translationStrategy, .block)
        for word in ["super/sub", "write/understand"] {
            let region = try XCTUnwrap(regions.first { $0.sourceText.contains(word) })
            XCTAssertFalse(region.codeRects.contains { $0.text == word })
            XCTAssertFalse(try XCTUnwrap(region.tokens.first { $0.text == word }).isProtected)
        }
    }

    private func recognizeSyntheticCanvas(
        lines: [(text: String, top: CGFloat, size: CGFloat, centered: Bool)],
        alignmentOverride: NSTextAlignment? = nil,
        monospaced: Bool = false
    ) throws -> [ImageTranslationSourceRegion] {
        let width: CGFloat = 1600, height: CGFloat = 1000
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        for line in lines {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: monospaced ? NSFont.monospacedSystemFont(ofSize: line.size, weight: .regular) : NSFont.systemFont(ofSize: line.size),
                .foregroundColor: NSColor.black
            ]
            let string = line.text as NSString
            let size = string.size(withAttributes: attributes)
            let x: CGFloat
            switch alignmentOverride {
            case .right: x = width - 50 - size.width
            case .center: x = (width - size.width) / 2
            default: x = line.centered ? (width - size.width) / 2 : 50
            }
            string.draw(at: NSPoint(
                x: x,
                y: height - line.top - size.height
            ), withAttributes: attributes)
        }
        NSGraphicsContext.restoreGraphicsState()
        let cgImage = try XCTUnwrap(bitmap.cgImage)
        let image = NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        return try ImageTranslationTextRecognizer.regions(for: PickedImage(
            data: data, mimeType: "image/png", fileName: "synthetic-recognition.png", image: image
        ))
    }

    func testOCRChevronBulletAndSlashSeparatedProseStayTranslatable() {
        XCTAssertTrue(ImageTranslationSourcePolicy.startsListItem("» choose a model"))
        XCTAssertTrue(ImageTranslationSourcePolicy.isLeadingDecorativeCharacter("»"))
        for word in ["constraint/penalty", "input/output", "e.g"] {
            XCTAssertFalse(ImageTranslationCodeHeuristics.isStrongIdentifier(word), word)
            XCTAssertFalse(ImageTranslationSourcePolicy.isProtectedRecognizedToken(word, index: 2, totalCount: 6), word)
        }
        XCTAssertTrue(ImageTranslationCodeHeuristics.isStrongIdentifier("src/lib/main.swift"))
        XCTAssertTrue(ImageTranslationCodeHeuristics.isStrongIdentifier("np.zeros"))
    }

    func testListMarkerKeepsLeftBadgeSeparateWhileJoiningRightStyledText() {
        let badge = CGRect(x: 0.01, y: 0.40, width: 0.10, height: 0.04)
        let listText = CGRect(x: 0.12, y: 0.40, width: 0.40, height: 0.04)
        let suffix = CGRect(x: 0.525, y: 0.40, width: 0.10, height: 0.04)
        let groups = ImageTranslationReadingOrderLayout.visualLineGroups(
            for: [badge, listText, suffix], listItemStarts: [1]
        )
        XCTAssertEqual(groups, [[0], [1, 2]])
    }

    func testIndentedListContinuationIgnoresBlankVerticalCropPadding() throws {
        // Identical 28 px glyphs and a 40 px continuation indent, with only
        // blank vertical padding changed. The preceding period must not make
        // the shallow crop lose its indented continuation.
        for height in [130, 1200] {
            let canvasHeight = CGFloat(height)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 1000, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ))
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 1000, height: canvasHeight).fill()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.black
            ]
            ("• Main idea ends here." as NSString).draw(
                at: NSPoint(x: 30, y: canvasHeight - 50), withAttributes: attributes
            )
            ("Additional detail stays with this item." as NSString).draw(
                at: NSPoint(x: 90, y: canvasHeight - 90), withAttributes: attributes
            )
            NSGraphicsContext.restoreGraphicsState()

            let cgImage = try XCTUnwrap(bitmap.cgImage)
            let image = NSImage(cgImage: cgImage, size: NSSize(width: 1000, height: canvasHeight))
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let regions = try ImageTranslationTextRecognizer.regions(for: PickedImage(
                data: data, mimeType: "image/png", fileName: "list-\(height).png", image: image
            ))
            let item = try XCTUnwrap(regions.first { $0.sourceText.hasPrefix("Main idea") })
            XCTAssertTrue(item.sourceText.contains("Additional detail"), "crop height \(height)")
            XCTAssertEqual(item.lineRects.count, 2, "crop height \(height)")
            XCTAssertTrue(item.preservesListMarker)
        }
    }

    func testParagraphRightEdgeSlackIsIndependentOfCropAspectRatio() {
        // Two identical physical paragraphs: one preceding line leaves a
        // 100 px ragged edge (new paragraph), the other leaves only 20 px.
        for imageHeight: CGFloat in [180, 1800] {
            func normalized(_ rect: CGRect) -> CGRect {
                CGRect(x: rect.minX / 1000, y: rect.minY / imageHeight,
                       width: rect.width / 1000, height: rect.height / imageHeight)
            }
            let candidate = normalized(CGRect(x: 20, y: 40, width: 680, height: 30))
            let block = normalized(CGRect(x: 20, y: 40, width: 800, height: 70))
            for (width, expected): (CGFloat, Bool) in [(700, false), (780, true)] {
                let previous = normalized(CGRect(x: 20, y: 80, width: width, height: 30))
                XCTAssertEqual(ImageTranslationReadingOrderLayout.isTightWrappedParagraphContinuation(
                    previousRect: previous, candidateRect: candidate, blockRect: block,
                    imageAspectRatio: 1000 / imageHeight
                ), expected, "crop height \(imageHeight), line width \(width)")
            }
        }
    }

    func testHighlightWidthsUseTheImageAspectRatio() throws {
        let region = ImageTranslationSourceRegion(
            id: "r1", sourceText: "vector", x: 0.1, y: 0.1, width: 0.8, height: 0.25,
            imageAspectRatio: 10,
            lineRects: [ImageTranslationLineRect(x: 0.1, y: 0.1, width: 0.8, height: 0.25)],
            tokens: [ImageTranslationSourceToken(text: "vector", x: 0.1, y: 0.1, width: 0.1, height: 0.25)],
            fontSize: 0.2
        )
        let pairs = ImageTranslationHighlightBuilder.pairs(
            regions: [region], replacements: [ImageTranslationReplacement(id: "r1", text: "向量")]
        )
        let target = try XCTUnwrap(pairs.first?.translatedRects.first)
        XCTAssertGreaterThan(target.width, 0.02)
        XCTAssertLessThan(target.width, 0.06)
    }

    func testSingleLineCropFontSizeStaysInNormalizedRange() {
        for kind: ImageTranslationTextRecognizer.TextBlockKind in [.paragraph, .listItem, .caption] {
            let size = ImageTranslationTextRecognizer.fontSize(for: kind, sourceLineHeight: 0.98)
            XCTAssertGreaterThan(size, 0.9)
            XCTAssertLessThanOrEqual(size, 1, "Values above 1 are interpreted as absolute point sizes")
        }
    }

    func testCodeAndFormulaStatementsSurviveOCRInsertedSpaces() {
        let lines = [
            "z = np.zeros(m)", "for i in range(m):", "for i in",
            "for j in range ( n ) :", "in range(M):", "for in range(M):", "z [ i ] + = W [ i , j ] * × [ j ]",
            "z [ i ] + = b [ i ]", "2 = Wx + b", "= W @ x + b",
            "if values[i] > threshold:", "while is_ready():", "label = \"two words\""
        ]
        for line in lines {
            XCTAssertTrue(ImageTranslationTextRecognizer.isCodeOnlyLine(line), line)
        }
    }

    func testCodeDetectionRetainsExplanatoryProse() {
        let lines = [
            "Array processing ( NumPy )", "vectorize computations", "variables/indices!",
            "from the image into another format", "for example in this document",
            "for example in this document:", "if you need help:",
            "while the upload completes:", "class objectives:",
            "Loss = prediction error averaged over the examples",
            "Accuracy = number of correct predictions / number of examples",
            "You will often need to derive an algorithm (with pencil and paper).",
            "This also makes your code cleaner and more readable!"
        ]
        for line in lines {
            XCTAssertFalse(ImageTranslationTextRecognizer.isCodeOnlyLine(line), line)
        }
    }

    func testListMarkersAreRecognizedBeforeTheirGlyphsAreProtected() {
        for line in [
            "• Array processing", "➢ vectorize computations", "▪ Child item", "- Another item",
            "> Nice theoretical properties", "› We can choose k", "1- Choose a sample", "2. Update the weights",
            "1.1 For cases A-D", "1.2 The word regression", "1.3 Diagnose the statement",
            "12.3.4 Explain the model", "12.3.4. Explain the model", "1.2 “Regression” means"
        ] {
            XCTAssertTrue(ImageTranslationSourcePolicy.startsListItem(line), line)
        }
        XCTAssertFalse(ImageTranslationSourcePolicy.startsListItem("hardware efficiency."))
        XCTAssertFalse(ImageTranslationSourcePolicy.startsListItem("k > n"))
        for line in ["1.5 times faster", "0.25 is the probability", "1-5 lectures cover this",
                     "Read section 1.2 before continuing", "The value is 1.2"] {
            XCTAssertFalse(ImageTranslationSourcePolicy.startsListItem(line), line)
        }
    }

    func testPreservedSourceListMarkerKeepsRecognizedGeometryDuringNormalization() {
        let block = ImageTranslationBlock(
            sourceID: "r004", text: "• 向量化计算 • 提高硬件效率", x: 0.06, y: 0.44,
            width: 0.9, height: 0.1,
            lineRects: [ImageTranslationLineRect(x: 0.06, y: 0.44, width: 0.9, height: 0.05)],
            preservesListMarker: true, kind: "list_item"
        )
        XCTAssertEqual(ImageTranslationSemanticNormalizer.normalize([block]), [block])
    }

    func testSplitListKeepsSharedImmutableMathProtection() {
        let formula = ImageTranslationLineRect(x: 0.7, y: 0.4, width: 0.2, height: 0.1)
        let block = ImageTranslationBlock(
            sourceID: "r010", text: "• 第一项\n• 第二项", x: 0.1, y: 0.4,
            width: 0.8, height: 0.2, protectedRects: [formula], mathRects: [formula],
            translationStrategy: .selective, kind: "list_item"
        )
        let items = ImageTranslationSemanticNormalizer.normalize([block])
        XCTAssertEqual(items.count, 2)
        for item in items {
            XCTAssertEqual(item.sourceID, block.sourceID)
            XCTAssertEqual(item.protectedRects, [formula])
            XCTAssertEqual(item.mathRects, [formula])
        }
    }

    func testWideCropKeepsSeparateColumnsApart() {
        // 1,000 × 200 crop: 16 px text with a 40 px column gutter.
        let left = CGRect(x: 0.05, y: 0.40, width: 0.40, height: 0.08)
        let right = CGRect(x: 0.49, y: 0.40, width: 0.40, height: 0.08)

        XCTAssertFalse(ImageTranslationReadingOrderLayout.belongsToSameVisualLine(
            right, lineRect: left, imageAspectRatio: 5
        ))
    }

    func testStyledFragmentsStillJoinInWideCrop() {
        // The same crop with a normal 5 px word space.
        let prefix = CGRect(x: 0.05, y: 0.40, width: 0.12, height: 0.08)
        let suffix = CGRect(x: 0.175, y: 0.40, width: 0.25, height: 0.08)

        XCTAssertTrue(ImageTranslationReadingOrderLayout.belongsToSameVisualLine(
            suffix, lineRect: prefix, imageAspectRatio: 5
        ))
    }

    func testStyledFragmentsStillJoinInTallCrop() {
        // 400 × 1,000 crop: 16 px text with a 7 px word space.
        let prefix = CGRect(x: 0.05, y: 0.40, width: 0.12, height: 0.016)
        let suffix = CGRect(x: 0.1875, y: 0.40, width: 0.25, height: 0.016)

        XCTAssertTrue(ImageTranslationReadingOrderLayout.belongsToSameVisualLine(
            suffix, lineRect: prefix, imageAspectRatio: 0.4
        ))
    }

    func testSmallTextDoesNotGainAnImageWideMinimumJoinDistance() {
        let left = CGRect(x: 0.10, y: 0.40, width: 0.20, height: 0.006)
        let right = CGRect(x: 0.309, y: 0.40, width: 0.20, height: 0.006)

        XCTAssertFalse(ImageTranslationReadingOrderLayout.belongsToSameVisualLine(
            right, lineRect: left
        ))
    }

    func testDenseRowsRetainTopToBottomOrderRegardlessOfIndentation() {
        let upper = CGRect(x: 0.30, y: 0.700, width: 0.4, height: 0.006)
        let middle = CGRect(x: 0.20, y: 0.692, width: 0.4, height: 0.006)
        let lower = CGRect(x: 0.10, y: 0.684, width: 0.4, height: 0.006)
        let shuffled = [lower, upper, middle]

        XCTAssertEqual(
            shuffled.sorted(by: ImageTranslationReadingOrderLayout.precedesInReadingOrder),
            [upper, middle, lower]
        )
        XCTAssertTrue(ImageTranslationReadingOrderLayout.precedesInReadingOrder(upper, middle))
        XCTAssertTrue(ImageTranslationReadingOrderLayout.precedesInReadingOrder(middle, lower))
        XCTAssertTrue(ImageTranslationReadingOrderLayout.precedesInReadingOrder(upper, lower))
    }

    func testMiddleStyledFragmentBridgesEarlierGroupsRegardlessOfInputOrder() {
        let left = CGRect(x: 0.10, y: 0.421, width: 0.10, height: 0.026)
        let middle = CGRect(x: 0.208, y: 0.420, width: 0.10, height: 0.026)
        let right = CGRect(x: 0.316, y: 0.422, width: 0.10, height: 0.026)
        for rects in [[right, middle, left], [left, right, middle], [middle, left, right]] {
            let groups = ImageTranslationReadingOrderLayout.visualLineGroups(for: rects)
            XCTAssertEqual(groups.map { group in group.map { rects[$0] } }, [[left, middle, right]])
        }
    }

    func testAlignedRowsOrderFromLeftToRight() {
        let left = CGRect(x: 0.05, y: 0.50, width: 0.30, height: 0.02)
        let right = CGRect(x: 0.55, y: 0.50, width: 0.30, height: 0.02)

        XCTAssertEqual(
            [right, left].sorted(by: ImageTranslationReadingOrderLayout.precedesInReadingOrder),
            [left, right]
        )
    }

    func testShortSidebarLabelsStaySeparate() {
        XCTAssertFalse(ImageTranslationReadingOrderLayout.isWrappedHeadingContinuation(
            previousRect: CGRect(x: 0.04, y: 0.50, width: 0.08, height: 0.024),
            candidateRect: CGRect(x: 0.04, y: 0.467, width: 0.10, height: 0.024),
            previousLooksLikeHeading: true,
            candidateLooksLikeHeading: true
        ))
    }

    func testHeadingWrapUsesPhysicalWidthInShallowCrop() {
        XCTAssertTrue(ImageTranslationReadingOrderLayout.isWrappedHeadingContinuation(
            previousRect: CGRect(x: 0.04, y: 0.50, width: 0.25, height: 0.15),
            candidateRect: CGRect(x: 0.04, y: 0.33, width: 0.10, height: 0.15),
            previousLooksLikeHeading: true,
            candidateLooksLikeHeading: true,
            imageAspectRatio: 5
        ))
    }

    func testSpacedSidebarLabelsStaySeparateEvenWhenLong() {
        XCTAssertFalse(ImageTranslationReadingOrderLayout.isWrappedHeadingContinuation(
            previousRect: CGRect(x: 0.04, y: 0.50, width: 0.30, height: 0.025),
            candidateRect: CGRect(x: 0.04, y: 0.455, width: 0.30, height: 0.025),
            previousLooksLikeHeading: true,
            candidateLooksLikeHeading: true
        ))
    }

    func testSeparateColumnsCannotContinueOneAnother() {
        let previous = CGRect(x: 0.10, y: 0.50, width: 0.02, height: 0.02)
        let nextColumn = CGRect(x: 0.13, y: 0.472, width: 0.02, height: 0.02)

        // A small normalized indent alone previously admitted this pair.
        XCTAssertFalse(ImageTranslationReadingOrderLayout.canContinueTextColumn(
            previousRect: previous, candidateRect: nextColumn
        ))
        XCTAssertFalse(ImageTranslationReadingOrderLayout.isTightWrappedParagraphContinuation(
            previousRect: previous,
            candidateRect: nextColumn,
            blockRect: previous.union(nextColumn)
        ))
    }

    func testSameRowCannotBecomeAParagraphContinuation() {
        let row = CGRect(x: 0.10, y: 0.50, width: 0.40, height: 0.02)

        XCTAssertFalse(ImageTranslationReadingOrderLayout.canContinueTextColumn(
            previousRect: row, candidateRect: row
        ))
    }
}
