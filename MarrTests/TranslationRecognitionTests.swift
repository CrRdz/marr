import AppKit
import CoreGraphics
import Foundation
import XCTest
@testable import Marr

final class TranslationRecognitionTests: XCTestCase {
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
        lines: [(text: String, top: CGFloat, size: CGFloat, centered: Bool)]
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
                .font: NSFont.systemFont(ofSize: line.size), .foregroundColor: NSColor.black
            ]
            let string = line.text as NSString
            let size = string.size(withAttributes: attributes)
            string.draw(at: NSPoint(
                x: line.centered ? (width - size.width) / 2 : 50,
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

    func testTradeoffsSlideKeepsEveryParentAndChildInReadingOrder() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "tradeoffs-source", withExtension: "png"
        ))
        let data = try Data(contentsOf: url)
        let image = try XCTUnwrap(NSImage(data: data))
        let regions = try ImageTranslationTextRecognizer.regions(for: PickedImage(
            data: data, mimeType: "image/png", fileName: url.lastPathComponent, image: image
        ))
        let prefixes = [
            "Tradeoffs in choosing", "Small", "Good at capturing", "May overfit",
            "Large", "Makes stable predictions", "May underfit", "Balancing",
            "Optimal choice", "Nice theoretical properties", "Rule of thumb", "We can choose"
        ]
        let ordered = try prefixes.map { prefix in
            try XCTUnwrap(regions.first { $0.sourceText.hasPrefix(prefix) }, "Missing independent item: \(prefix)")
        }
        XCTAssertEqual(Set(ordered.map(\.id)).count, 12)
        XCTAssertEqual(ordered[7].sourceText, "Balancing k")
        XCTAssertFalse(ordered[7].preservesInlineMath)
        XCTAssertEqual(ordered.filter(\.preservesInlineMath).map(\.id), [ordered[9].id, ordered[10].id])
        for (upper, lower) in zip(ordered, ordered.dropFirst()) {
            XCTAssertLessThan(upper.y, lower.y)
        }
        for item in ordered.dropFirst() {
            XCTAssertEqual(item.kind, "list_item")
            XCTAssertTrue(item.preservesListMarker)
            XCTAssertEqual(item.lineRects.count, 1)
        }
        // OCR sees the app's Original badge too. It may be its own region, but
        // must never be absorbed into the final child or an earlier parent.
        XCTAssertFalse(ordered.last!.sourceText.contains("Original"))
        XCTAssertFalse(ordered[7].sourceText.contains("Nice"))
        XCTAssertFalse(ordered[7].sourceText.contains("We can"))
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

    func testShallowNearestNeighborCropKeepsBulletsOutsideReplacementGeometry() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "nearest-neighbor-source", withExtension: "png"
        ))
        let data = try Data(contentsOf: url)
        let image = try XCTUnwrap(NSImage(data: data))
        let regions = try ImageTranslationTextRecognizer.regions(for: PickedImage(
            data: data, mimeType: "image/png", fileName: url.lastPathComponent, image: image
        ))
        let first = try XCTUnwrap(regions.first { $0.sourceText.hasPrefix("Suppose") })
        let second = try XCTUnwrap(regions.first { $0.sourceText.hasPrefix("The idea") })

        // The source has visible bullets centered at x≈46 px. Its third line
        // is partly covered by the Original badge and must not be reconstructed.
        for region in [first, second] {
            XCTAssertEqual(region.kind, "list_item")
            XCTAssertNil(region.weight)
            XCTAssertTrue(region.preservesListMarker)
            XCTAssertEqual(region.imageAspectRatio, 1440.0 / 164.0, accuracy: 0.0001)
            XCTAssertGreaterThan(region.x * 1440, 68)
            XCTAssertEqual(region.lineRects.count, 1)
            for rect in region.lineRects + region.textRects {
                XCTAssertGreaterThan(rect.x * 1440, 68, "Replacement box must not cover the bullet")
            }
            XCTAssertTrue(region.tokens.contains { $0.text == "x" })
        }
        XCTAssertTrue(first.sourceText.contains("we're"))
        XCTAssertTrue(first.sourceText.contains("we'd"))
        XCTAssertTrue(first.sourceText.hasSuffix("classify."))
        XCTAssertTrue(second.sourceText.hasPrefix("The idea:"))
        XCTAssertFalse(first.sourceText.contains(" ' "))
        XCTAssertFalse(second.sourceText.contains(" ."))
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

    func testRealMachineLearningSlidePreservesListHierarchyAndExcludesCode() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "ml-slide-source", withExtension: "png"
        ))
        let data = try Data(contentsOf: url)
        let image = try XCTUnwrap(NSImage(data: data))
        let regions = try ImageTranslationTextRecognizer.regions(for: PickedImage(
            data: data, mimeType: "image/png", fileName: url.lastPathComponent, image: image
        ))

        // The user's screenshot contains one title and four independent list
        // items to translate. Mathematical carriers keep the equation/code
        // pixels protected globally, without adding model translation work.
        let proseRegions = regions.filter(\.requiresTranslation)
        XCTAssertEqual(proseRegions.count, 5)
        let preservedRegions = regions.filter { !$0.requiresTranslation }
        XCTAssertFalse(preservedRegions.isEmpty)
        for region in preservedRegions {
            XCTAssertTrue(region.preservesInlineMath)
            XCTAssertTrue(region.tokens.allSatisfy(\.isProtected))
            XCTAssertEqual(region.translationStrategy, .selective)
        }
        let title = try XCTUnwrap(proseRegions.first { $0.sourceText.contains("Implementing machine learning") })
        let firstItem = try XCTUnwrap(proseRegions.first { $0.sourceText.hasPrefix("You will often") })
        let parentItem = try XCTUnwrap(proseRegions.first { $0.sourceText.hasPrefix("Array processing") })
        let childItem = try XCTUnwrap(proseRegions.first { $0.sourceText.hasPrefix("vectorize computations") })
        let lastItem = try XCTUnwrap(proseRegions.first { $0.sourceText.hasPrefix("This also makes") })

        XCTAssertEqual(title.kind, "title")
        XCTAssertEqual(title.weight, "semibold")
        XCTAssertFalse(title.preservesListMarker)
        XCTAssertFalse(title.sourceText.contains("You will"))
        XCTAssertFalse(parentItem.sourceText.contains("vectorize"))
        XCTAssertGreaterThan(childItem.x, parentItem.x)
        XCTAssertEqual(firstItem.lineRects.count, 2)
        XCTAssertEqual(childItem.lineRects.count, 2)
        XCTAssertEqual(parentItem.lineRects.count, 1)
        XCTAssertEqual(lastItem.lineRects.count, 1)
        for item in [firstItem, parentItem, childItem, lastItem] {
            XCTAssertEqual(item.kind, "list_item")
            XCTAssertTrue(item.preservesListMarker)
            XCTAssertNil(item.weight)
            XCTAssertFalse(ImageTranslationSourcePolicy.startsListItem(item.sourceText))
        }
        for region in regions {
            XCTAssertFalse(region.sourceText.contains("range"))
            XCTAssertFalse(region.sourceText.contains("="))
            XCTAssertFalse(ImageTranslationTextRecognizer.isCodeOnlyLine(region.sourceText))
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
            "> Nice theoretical properties", "› We can choose k", "1- Choose a sample", "2. Update the weights"
        ] {
            XCTAssertTrue(ImageTranslationSourcePolicy.startsListItem(line), line)
        }
        XCTAssertFalse(ImageTranslationSourcePolicy.startsListItem("hardware efficiency."))
        XCTAssertFalse(ImageTranslationSourcePolicy.startsListItem("k > n"))
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
