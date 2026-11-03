import AppKit
import XCTest
@testable import Marr

final class TranslationMathProtectionTests: XCTestCase {
    func testScalarNumbersFlowWithMathProseWithoutUnlockingBadgesOrCode() throws {
        for number in ["0.3132617", "−0.2689414", "42", "1.5e3", "12%"] {
            let value = fixture(["The", "loss", "was", number, "when", "y", "=", "1"], protectedIndexes: [3, 7])
            let output = ImageTranslationMathProtection.protect([value.region], observations: [value.observation],
                imageSize: CGSize(width: 1200, height: 600))
            let row = try XCTUnwrap(output.first)
            XCTAssertFalse(try XCTUnwrap(row.tokens.first { $0.text == number }).isProtected, number)
            XCTAssertEqual(row.tokens.filter(\.isMathematical).count, 1)
            let slots = ImageTranslationMerger.selectiveProseRanges(in: row)
            XCTAssertEqual(slots.count, 1, "The number must not divide the prose into independent slots")
            let slot = try XCTUnwrap(slots.first)
            let blocks = ImageTranslationMerger.merge(replacements: [ImageTranslationReplacement(id: row.id, text: "",
                segments: [ImageTranslationReplacementSegment(tokenStart: slot.lowerBound, tokenEnd: slot.upperBound,
                                                              text: "损失为 \(number)，对应")])], regions: output)
            XCTAssertEqual(try XCTUnwrap(blocks.first).inlineMathRects.count, 1)

            let badge = fixture(["Count", number], protectedIndexes: [1])
            XCTAssertEqual(ImageTranslationMathProtection.protect([badge.region], observations: [badge.observation],
                imageSize: CGSize(width: 1200, height: 600)), [badge.region])
        }
        let code = fixture(["The", "code", "42", "uses", "y", "=", "1"], protectedIndexes: [2], codeIndexes: [2])
        let result = ImageTranslationMathProtection.protect([code.region], observations: [code.observation],
            imageSize: CGSize(width: 1200, height: 600))
        XCTAssertTrue(try XCTUnwrap(result.flatMap(\.tokens).first { $0.text == "42" }).isProtected)
    }

    func testProseNumbersRangesAndHyphenatedWordsDoNotSplitSentences() {
        for words in [
            ["For", "cases", "A-D,", "choose", "models", "from", "lecture", "1-5"],
            ["For", "cases", "A", "-", "D", "choose", "models"],
            ["Use", "lectures", "1", "-", "5", "for", "reference"],
            ["Read", "pages", "1–5", "before", "class"],
            ["The", "temperature", "is", "-3.5", "degrees"],
            ["The", "score", "(", "12", "marks", ")", "is", "shown"],
            ["Use", "high-quality", "models", "with", "weight-decay"],
            ["Use", "x-ray", "images", "for", "training"]
        ] {
            let value = fixture(words)
            XCTAssertEqual(ImageTranslationMathProtection.protect([value.region],
                observations: [value.observation], imageSize: CGSize(width: 1200, height: 600)),
                [value.region], words.joined(separator: " "))
        }
    }

    func testRealEquationsRemainProtectedAlongsideProseRanges() throws {
        for words in [["Use", "lectures", "1-5", "to", "solve", "x", "-", "y", "=", "3"],
                      ["Use", "lectures", "1-5", "to", "compute", "A-B"],
                      ["Compute", "A-B", "for", "matrices"],
                      ["Compare", "dw-dy", "with", "zero"],
                      ["The", "difference", "is", "5", "−", "3"],
                      ["Solve", "x", "=", "1-5"]] {
            let value = fixture(words)
            let result = ImageTranslationMathProtection.protect([value.region],
                observations: [value.observation], imageSize: CGSize(width: 1200, height: 600))
            XCTAssertTrue(result.flatMap(\.tokens).contains(where: \.isMathematical), words.joined(separator: " "))
            if words.contains("lectures") {
                XCTAssertTrue(result.flatMap(\.tokens).contains { $0.text == "1-5" && !$0.isMathematical })
            }
        }
    }

    func testRaisedAnnotationJoinsItsVariableOnlyWithGeometryAndRelationEvidence() throws {
        let size = CGSize(width: 800, height: 300)
        let source = observation([
            ("solution", CGRect(x: 100, y: 100, width: 100, height: 30)),
            ("wi", CGRect(x: 210, y: 100, width: 40, height: 30)),
            ("Ridge", CGRect(x: 237, y: 82, width: 70, height: 40)),
            ("=", CGRect(x: 310, y: 100, width: 25, height: 30)),
            ("Xw", CGRect(x: 345, y: 100, width: 50, height: 30))
        ], size: size)
        let output = ImageTranslationMathProtection.protect([], observations: [source], imageSize: size)
        let formula = try XCTUnwrap(output.flatMap(\.tokens).first(where: \.isMathematical))
        XCTAssertLessThan(formula.x * size.width, 211)
        XCTAssertLessThan(formula.y * size.height, 83)
        XCTAssertGreaterThan((formula.x + formula.width) * size.width, 394)
        XCTAssertGreaterThan(formula.x * size.width, 200, "The solution word must remain translatable")
        // In the real cropped lecture page, Vision puts wi at the end of
        // one observation and Ridge = at the beginning of the next one.
        let left = observation([
            ("solution", CGRect(x: 100, y: 100, width: 100, height: 30)),
            ("wi", CGRect(x: 210, y: 100, width: 40, height: 30))
        ], size: size)
        let right = observation([
            ("Ridge", CGRect(x: 237, y: 82, width: 70, height: 40)),
            ("=", CGRect(x: 310, y: 100, width: 25, height: 30)),
            ("Xw", CGRect(x: 345, y: 100, width: 50, height: 30))
        ], size: size)
        let detached = ImageTranslationMathProtection.protect([], observations: [left, right], imageSize: size)
        let joined = try XCTUnwrap(detached.flatMap(\.tokens).first(where: \.isMathematical))
        XCTAssertLessThan(joined.x * size.width, 211)
        XCTAssertLessThan(joined.y * size.height, 83)
        XCTAssertGreaterThan((joined.x + joined.width) * size.width, 394)
        XCTAssertGreaterThan(joined.x * size.width, 200)
        let ordinary = fixture(["Visit", "a", "Ridge", "trail"])
        XCTAssertEqual(ImageTranslationMathProtection.protect([ordinary.region], observations: [ordinary.observation],
            imageSize: CGSize(width: 1200, height: 600)), [ordinary.region])
    }

    func testShortScalarCaptionRetainsOCRGlyphWithoutFreezingArticles() throws {
        for words in [["a", "too", "small", ":"], ["a", "too", "large"], ["a", "much", "too", "large", ":"]] {
            let value = fixture(words)
            let output = ImageTranslationMathProtection.protect([value.region], observations: [value.observation],
                imageSize: CGSize(width: 1200, height: 600))
            let translated = try XCTUnwrap(output.first)
            XCTAssertTrue(translated.tokens.first?.isMathematical == true)
            XCTAssertTrue(translated.sourceText.contains("too"))
        }
        for words in [["a", "small", "step"], ["Use", "a", "much", "larger", "step"], ["a", "too", "large", "value"]] {
            let value = fixture(words)
            XCTAssertEqual(ImageTranslationMathProtection.protect([value.region], observations: [value.observation],
                imageSize: CGSize(width: 1200, height: 600)), [value.region])
        }
    }

    func testNormSuperscriptHyphenNeedsSharedGlyphBoxAndNormContext() {
        let size = CGSize(width: 800, height: 250)
        for (sharedBox, trailingWord, expected) in [(true, "norm", true), (false, "norm", false), (true, "label", false)] {
            let letterBox = CGRect(x: 200, y: 100, width: 30, height: 40)
            let hyphenBox = sharedBox ? letterBox : CGRect(x: 235, y: 100, width: 20, height: 40)
            let source = observation([
                ("The", CGRect(x: 100, y: 100, width: 80, height: 40)),
                ("L", letterBox), ("-", hyphenBox),
                (trailingWord, CGRect(x: 265, y: 100, width: 100, height: 40))
            ], size: size)
            let output = ImageTranslationMathProtection.protect([], observations: [source], imageSize: size)
            let mathTokens: [ImageTranslationSourceToken] = output.flatMap(\.tokens).filter(\.isMathematical)
            XCTAssertEqual(mathTokens.contains { pixelRect($0, size: size).contains(CGPoint(x: 215, y: 120)) }, expected)
        }
    }

    func testFlattenedFunctionAnnotationRequiresMathematicalCallGeometry() {
        let size = CGSize(width: 1000, height: 300)
        for (prefix, name, gap, expected) in [("argmin", "Jreg", 5.0, true),
                                              ("Read", "Jreg", 5.0, false),
                                              ("argmin", "with", 5.0, false),
                                              ("Read", "Note", 5.0, false),
                                              ("argmin", "Jreg", 70.0, false)] {
            let source = observation([
                (prefix, CGRect(x: 50, y: 100, width: 140, height: 40)),
                (name, CGRect(x: 200, y: 100, width: 60, height: 40)),
                ("(", CGRect(x: 260 + gap, y: 100, width: 40, height: 40)),
                ("w", CGRect(x: 260 + gap, y: 100, width: 40, height: 40)),
                (")", CGRect(x: 260 + gap, y: 100, width: 40, height: 40))
            ], size: size)
            let output = ImageTranslationMathProtection.protect([], observations: [source], imageSize: size)
            let mathTokens: [ImageTranslationSourceToken] = output.flatMap(\.tokens).filter(\.isMathematical)
            let coversName = mathTokens.contains { pixelRect($0, size: size).contains(CGPoint(x: 230, y: 120)) }
            XCTAssertEqual(coversName, expected, "\(prefix) \(name), gap=\(gap)")
        }
    }

    func testNormNamesAndQualifiedScalarsKeepOriginalGlyphsWithoutFreezingOrdinaryNouns() throws {
        for words in [["The", "L2", "norm", "uses", "squared", "12"],
                      ["Large", "1", "penalizes", "weights"],
                      ["For", "small", "enough", "a", "(", "unless"]] {
            let value = fixture(words)
            let output = ImageTranslationMathProtection.protect([value.region], observations: [value.observation],
                imageSize: CGSize(width: 1200, height: 600))
            let mathTokens: [ImageTranslationSourceToken] = output.flatMap(\.tokens).filter(\.isMathematical)
            XCTAssertEqual(mathTokens.count, words.contains("norm") ? 2 : 1)
            XCTAssertTrue(output.contains( where: \.requiresTranslation))
        }
        for words in [["The", "L2", "cache", "works"], ["12", "people", "arrived"],
                      ["Use", "a", "small", "box"], ["small", "enough", "a", "box"]] {
            let value = fixture(words)
            XCTAssertEqual(ImageTranslationMathProtection.protect([value.region], observations: [value.observation],
                imageSize: CGSize(width: 1200, height: 600)), [value.region])
        }
    }

    func testOCRMissingInlineFractionRequiresSeparatedNumeratorAndDenominator() throws {
        let size = CGSize(width: 500, height: 200)
        let words = observation([
            ("The", CGRect(x: 50, y: 30, width: 80, height: 110)),
            ("factor", CGRect(x: 128, y: 30, width: 180, height: 110)),
            ("convenient", CGRect(x: 310, y: 30, width: 170, height: 110))
        ], size: size)
        let numerator = CGRect(x: 143, y: 59, width: 10, height: 16)
        let bar = CGRect(x: 140, y: 85, width: 15, height: 2)
        let denominator = CGRect(x: 143, y: 99, width: 10, height: 16)
        let proseInk = [CGRect(x: 50, y: 75, width: 75, height: 20),
                        CGRect(x: 170, y: 75, width: 120, height: 20)]
        let image = try inkImage(size: size, rects: proseInk + [numerator, bar, denominator])
        let output = ImageTranslationMathProtection.protect([], observations: [words], imageSize: size, cgImage: image)
        let mathTokens: [ImageTranslationSourceToken] = output.flatMap(\.tokens).filter(\.isMathematical)
        let mathRects: [CGRect] = mathTokens.map { pixelRect($0, size: size) }
        XCTAssertTrue(mathRects.contains { $0.contains(CGPoint(x: 148, y: 60)) && $0.contains(CGPoint(x: 148, y: 114)) })
        XCTAssertFalse(mathRects.contains { $0.contains(CGPoint(x: 180, y: 85)) }, "An inflated OCR word box must not make adjacent prose immutable")
        for excluded in [[bar], [numerator, bar], [bar, denominator],
                         [bar, CGRect(x: 147, y: 68, width: 2, height: 35)]] {
            let nonFraction = try inkImage(size: size, rects: proseInk + excluded)
            XCTAssertTrue(ImageTranslationMathProtection.protect([], observations: [words], imageSize: size,
                cgImage: nonFraction).isEmpty, "Hyphens, underlines and connected letter strokes are not stacked fractions")
        }
    }

    func testMissingFractionTightensInflatedProseWithoutBorrowingNextBulletInk() throws {
        let size = CGSize(width: 500, height: 230)
        let inflated = observation([
            ("The", CGRect(x: 50, y: 30, width: 80, height: 130)),
            ("factor", CGRect(x: 128, y: 30, width: 180, height: 130)),
            ("convenient", CGRect(x: 310, y: 30, width: 170, height: 130))
        ], size: size)
        let following = observation([
            ("Cost", CGRect(x: 50, y: 128, width: 60, height: 32)),
            ("function", CGRect(x: 120, y: 128, width: 150, height: 32)),
            ("averaged", CGRect(x: 280, y: 128, width: 190, height: 32))
        ], size: size)
        func source(_ raw: ImageTranslationMathObservation, id: String, fontSize: Double) -> ImageTranslationSourceRegion {
            let line = raw.rect
            let tokens = raw.tokens.map {
                ImageTranslationSourceToken(text: $0.text, x: $0.x, y: $0.y, width: $0.width, height: $0.height)
            }
            return ImageTranslationSourceRegion(id: id, sourceText: raw.text,
                x: line.x, y: line.y, width: line.width, height: line.height,
                imageAspectRatio: size.width / size.height, lineRects: [line], tokens: tokens, fontSize: fontSize)
        }
        let first = source(inflated, id: "first", fontSize: 0.5)
        let next = source(following, id: "next", fontSize: 0.14)
        let prose = [CGRect(x: 50, y: 75, width: 75, height: 20),
                     CGRect(x: 170, y: 75, width: 120, height: 20),
                     CGRect(x: 320, y: 75, width: 150, height: 20)]
        // The next bullet's ink is taller and denser, so a largest-band-only
        // measurement would incorrectly place this sentence on that row.
        let nextInk = CGRect(x: 50, y: 130, width: 420, height: 28)
        let fraction = [CGRect(x: 143, y: 59, width: 10, height: 16),
                        CGRect(x: 140, y: 85, width: 15, height: 2),
                        CGRect(x: 143, y: 99, width: 10, height: 16)]
        let image = try inkImage(size: size, rects: prose + [nextInk] + fraction)
        let result = ImageTranslationMathProtection.protect([first, next], observations: [inflated, following],
            imageSize: size, cgImage: image)
        let repaired = try XCTUnwrap(result.first { $0.id == "first" })
        XCTAssertEqual(repaired.tokens.map(\.text), ["The", "⟦math_1⟧", "factor", "convenient"])
        let factor = try XCTUnwrap(repaired.tokens.first { $0.text == "factor" })
        XCTAssertGreaterThan(pixelRect(factor, size: size).minX, 160)
        let proseTokens: [ImageTranslationSourceToken] = repaired.tokens.filter { !$0.isMathematical }
        let proseBoxes: [CGRect] = proseTokens.map { pixelRect($0, size: size) }
        XCTAssertTrue(proseBoxes.allSatisfy { $0.minY >= 73 && $0.maxY <= 98 })
        XCTAssertLessThan(try XCTUnwrap(repaired.fontSize), 0.15)
        XCTAssertEqual(result.first { $0.id == "next" }, next, "A neighboring bullet must retain its own geometry")
        let formula = try XCTUnwrap(repaired.tokens.first(where: \.isMathematical))
        XCTAssertTrue(pixelRect(formula, size: size).contains(CGPoint(x: 148, y: 60)))
        XCTAssertTrue(pixelRect(formula, size: size).contains(CGPoint(x: 148, y: 114)))

        let withoutFraction = try inkImage(size: size, rects: prose + [nextInk])
        XCTAssertEqual(ImageTranslationMathProtection.protect([first, next], observations: [inflated, following],
            imageSize: size, cgImage: withoutFraction), [first, next],
            "Do not rewrite prose geometry without a confirmed omitted fraction")
    }

    func testSeparateRelationObservationJoinsDifferentialNumeratorAndDenominator() {
        let size = CGSize(width: 600, height: 300)
        let observations = [
            observation([("dL", CGRect(x: 205, y: 80, width: 30, height: 20)),
                         ("dy", CGRect(x: 245, y: 80, width: 30, height: 20))], size: size),
            observation([("=", CGRect(x: 180, y: 106, width: 20, height: 10))], size: size),
            observation([("dy", CGRect(x: 205, y: 112, width: 30, height: 20)),
                         ("ow", CGRect(x: 245, y: 112, width: 30, height: 20))], size: size)
        ]
        let output = ImageTranslationMathProtection.protect([], observations: observations, imageSize: size)
        let mathTokens: [ImageTranslationSourceToken] = output.flatMap(\.tokens).filter(\.isMathematical)
        let coversFraction: Bool = mathTokens.contains { token in
            let box = pixelRect(token, size: size)
            return box.minX < 181 && box.minY < 81 && box.maxX > 274 && box.maxY > 131
        }
        XCTAssertTrue(coversFraction)
        XCTAssertTrue(ImageTranslationMathProtection.protect([], observations: [observations[1]], imageSize: size).isEmpty,
                      "A standalone relation without operands must never become a display")
    }

    func testDifferentialDenominatorNeedsRealFractionBarAndNumeratorInk() throws {
        let size = CGSize(width: 500, height: 300)
        let numerator = CGRect(x: 220, y: 116, width: 20, height: 20)
        let denominator = CGRect(x: 215, y: 155, width: 30, height: 25)
        let source = observation([("dw", CGRect(x: 210, y: 150, width: 40, height: 35)),
                                  (";", CGRect(x: 210, y: 150, width: 40, height: 35))], size: size)
        let image = try inkImage(size: size, rects: [numerator, denominator,
            CGRect(x: 208, y: 145, width: 45, height: 2)])
        let protected = ImageTranslationMathProtection.protect([], observations: [source], imageSize: size, cgImage: image)
        let mathTokens: [ImageTranslationSourceToken] = protected.flatMap(\.tokens).filter(\.isMathematical)
        let coversNumeratorAndDenominator: Bool = mathTokens.contains { token in
            let box = pixelRect(token, size: size)
            return box.minY < 117 && box.maxY > 179
        }
        XCTAssertTrue(coversNumeratorAndDenominator)
        let noBar = try inkImage(size: size, rects: [numerator, denominator])
        XCTAssertTrue(ImageTranslationMathProtection.protect([], observations: [source], imageSize: size, cgImage: noBar).isEmpty,
                      "A short OCR word alone is insufficient evidence for a fraction")
    }

    func testCropScaleOCRVariantsKeepVectorSpacesAndMixedConnectorBoxes() throws {
        for words in [
            ["Use", "ROXD", "for", "matrices"], ["Use", "Rª", "for", "vectors"],
            ["Use", "bwherew", ",", "x", "e", "RP"]
        ] {
            let value = fixture(words)
            let output = ImageTranslationMathProtection.protect([value.region], observations: [value.observation],
                imageSize: CGSize(width: 1200, height: 600))
            XCTAssertEqual(try XCTUnwrap(output.first).tokens.filter(\.isMathematical).count, 1)
            XCTAssertFalse(output.flatMap(\.tokens).contains { ["ROXD", "Rª", "bwherew"].contains($0.text) })
        }
        let regularized = fixture(["Use", "L2", "regularization", "J", "+", "R"])
        let output = ImageTranslationMathProtection.protect([regularized.region], observations: [regularized.observation],
            imageSize: CGSize(width: 1200, height: 600))
        XCTAssertEqual(try XCTUnwrap(output.first).tokens.filter(\.isMathematical).count, 2)
        let phi = fixture(["In", "general", "«", "can", "be", "a", "function"])
        XCTAssertEqual(try XCTUnwrap(ImageTranslationMathProtection.protect([phi.region], observations: [phi.observation],
            imageSize: CGSize(width: 1200, height: 600)).first).tokens.filter(\.isMathematical).count, 1)
    }

    func testClosingScriptOCRFragmentsUseSharedGlyphGeometry() {
        let size = CGSize(width: 700, height: 250)
        for suffix in [["xi", ")"], ["x", "\"", ")"]] {
            var words: [(String, CGRect)] = [
                ("t", CGRect(x: 50, y: 100, width: 20, height: 30)),
                ("(", CGRect(x: 75, y: 100, width: 10, height: 30)),
                ("i", CGRect(x: 90, y: 100, width: 10, height: 30)),
                (")", CGRect(x: 105, y: 100, width: 10, height: 30)),
                ("with", CGRect(x: 125, y: 100, width: 60, height: 30))
            ]
            words += suffix.map { ($0, CGRect(x: 205, y: 95, width: 45, height: 40)) }
            let source = observation(words, size: size)
            let output = ImageTranslationMathProtection.protect([], observations: [source], imageSize: size)
            let mathTokens: [ImageTranslationSourceToken] = output.flatMap(\.tokens).filter(\.isMathematical)
            let coversScript: Bool = mathTokens.contains { token in
                let box = pixelRect(token, size: size)
                return box.minX < 206 && box.maxX > 249 && box.minX > 190
            }
            XCTAssertTrue(coversScript, suffix.joined())
        }
    }

    func testInlineEdgeRecoveryFindsClippedSuperscriptWithoutTakingNextRow() throws {
        let size = CGSize(width: 600, height: 260)
        let image = try inkImage(size: size, rects: [
            CGRect(x: 20, y: 105, width: 60, height: 25),
            CGRect(x: 100, y: 105, width: 85, height: 25),
            CGRect(x: 140, y: 94, width: 12, height: 10),
            CGRect(x: 205, y: 105, width: 80, height: 25),
            CGRect(x: 140, y: 155, width: 60, height: 25)
        ])
        let source = observation([
            ("Use", CGRect(x: 20, y: 100, width: 60, height: 40)),
            ("x", CGRect(x: 100, y: 100, width: 25, height: 40)),
            ("=", CGRect(x: 130, y: 100, width: 25, height: 40)),
            ("y", CGRect(x: 160, y: 100, width: 25, height: 40)),
            ("above", CGRect(x: 205, y: 100, width: 80, height: 40))
        ], size: size)
        let output = ImageTranslationMathProtection.protect([], observations: [source], imageSize: size, cgImage: image)
        let math = output.flatMap(\.tokens).filter(\.isMathematical).map {
            CGRect(x: $0.x * size.width, y: $0.y * size.height,
                   width: $0.width * size.width, height: $0.height * size.height)
        }
        XCTAssertTrue(math.contains { $0.contains(CGPoint(x: 145, y: 95)) })
        XCTAssertFalse(math.contains { $0.contains(CGPoint(x: 145, y: 160)) })
    }

    func testSharedSemicolonVariableBoxPreservesOCRSubscriptInMathematicalProse() throws {
        let size = CGSize(width: 900, height: 300)
        let words: [(String, CGRect)] = [
            ("If", CGRect(x: 50, y: 100, width: 30, height: 40)),
            ("dJ/dw", CGRect(x: 90, y: 100, width: 90, height: 40)),
            (">", CGRect(x: 190, y: 100, width: 25, height: 40)),
            ("0", CGRect(x: 225, y: 100, width: 25, height: 40)),
            ("then", CGRect(x: 260, y: 100, width: 60, height: 40)),
            ("increasing", CGRect(x: 330, y: 100, width: 130, height: 40)),
            ("w", CGRect(x: 470, y: 100, width: 45, height: 40)),
            (";", CGRect(x: 470, y: 100, width: 45, height: 40)),
            ("increases", CGRect(x: 525, y: 100, width: 130, height: 40))
        ]
        let source = observation(words, size: size)
        let result = ImageTranslationMathProtection.protect([], observations: [source], imageSize: size)
        let mathTokens: [ImageTranslationSourceToken] = result.flatMap(\.tokens).filter(\.isMathematical)
        let coversSubscript: Bool = mathTokens.contains { token in
            let box = pixelRect(token, size: size)
            return box.minX <= 470 && box.maxX >= 515 && box.maxY >= 140
        }
        XCTAssertTrue(coversSubscript, "The original w and its lower j must be kept together")
        let prose = observation(Array(words.dropFirst(4)), size: size)
        XCTAssertTrue(ImageTranslationMathProtection.protect([], observations: [prose], imageSize: size).isEmpty,
                      "A semicolon in ordinary prose must not seed a mathematical region")
    }

    func testSymbolBeforePredicatePreservesOCRGlyphWithoutFreezingEnglishPronounsOrArticles() throws {
        for words in [
            ["The", "rate", "a", "is", "a", "hyperparameter"],
            ["In", "general", "4", "can", "be", "any", "function"],
            ["The", "symbol", "φ", "denotes", "features"],
            ["The", "symbol", "x", "represents", "input"]
        ] {
            let value = fixture(words)
            let output = ImageTranslationMathProtection.protect([value.region], observations: [value.observation],
                imageSize: CGSize(width: 1200, height: 600))
            let translated = try XCTUnwrap(output.first)
            XCTAssertEqual(translated.tokens.filter(\.isMathematical).count, 1)
            XCTAssertTrue(translated.sourceText.contains(words.last!))
            if words.contains("hyperparameter") {
                XCTAssertTrue(translated.tokens.contains { $0.text == "a" && !$0.isProtected },
                              "The article before hyperparameter is still prose")
            }
        }
        for words in [
            ["I", "can", "be", "helpful"], ["I", "can", "take", "notes"],
            ["Take", "a", "can", "of", "beans"], ["Use", "a", "small", "step"]
        ] {
            let value = fixture(words)
            XCTAssertEqual(ImageTranslationMathProtection.protect([value.region], observations: [value.observation],
                imageSize: CGSize(width: 1200, height: 600)), [value.region])
        }
    }

    func testJoinedConnectorVariableBoxStaysSafeOnlyBesideAnExpression() throws {
        let joined = fixture(["Use", "wherew", ",", "xe", "RP"])
        let output = ImageTranslationMathProtection.protect([joined.region], observations: [joined.observation],
            imageSize: CGSize(width: 1200, height: 600))
        XCTAssertEqual(try XCTUnwrap(output.first).tokens.map(\.text), ["Use", "⟦math_1⟧"])
        let ordinary = fixture(["The", "wherew", "label"])
        XCTAssertEqual(ImageTranslationMathProtection.protect([ordinary.region], observations: [ordinary.observation],
            imageSize: CGSize(width: 1200, height: 600)), [ordinary.region])
    }

    func testOCRMembershipSymbolsAndFusedOperandsRequireSpaceEvidence() throws {
        for words in [
            ["Input", "x", "e", "X", "is", "observed"],
            ["Target", "t", "e", "J", "is", "observed"],
            ["Parameters", "w", ",", "x", ",", "bE", "R"],
            ["Parameters", "xe", "RP", ",", "be", "R"],
            ["Target", "ti", ")", "E", "R", "is", "observed"]
        ] {
            let value = fixture(words)
            let output = ImageTranslationMathProtection.protect([value.region],
                observations: [value.observation], imageSize: CGSize(width: 1200, height: 600))
            let region = try XCTUnwrap(output.first)
            XCTAssertEqual(region.tokens.filter(\.isMathematical).count, 1, words.joined(separator: " "))
            XCTAssertTrue(region.sourceText.hasPrefix(words[0]))
            XCTAssertFalse(region.tokens.contains { ["e", "E", "bE", "xe", "be"].contains($0.text) })
        }
        for words in [["Choose", "e", "carefully"], ["It", "may", "be", "R"], ["A", "grade", "E"]] {
            let value = fixture(words)
            XCTAssertEqual(ImageTranslationMathProtection.protect([value.region],
                observations: [value.observation], imageSize: CGSize(width: 1200, height: 600)), [value.region])
        }
    }

    func testRealWrappedVectorSpaceKeepsBothLinesOfMembership() throws {
        // Lecture page 4: Vision emits a closing parenthesis + E at the
        // right edge, then R and ° in the same box at the next line's start.
        let first = fixture(["features", "x", "=", "(", "x1", ",", ".", ".", ",", "xD", ")", "E"], id: "first", y: 0.18)
        let next = fixture(["R", "°", "to", "make", "predictions", "t", "e", "R"], id: "next", y: 0.23)
        let output = ImageTranslationMathProtection.protect([first.region, next.region],
            observations: [first.observation, next.observation], imageSize: CGSize(width: 1440, height: 810))
        XCTAssertEqual(try XCTUnwrap(output.first { $0.id == "first" }).sourceText, "features ⟦math_1⟧")
        XCTAssertEqual(try XCTUnwrap(output.first { $0.id == "next" }).sourceText,
                       "⟦math_1⟧ to make predictions ⟦math_2⟧")
    }

    func testFractionsScriptsSetsAndEllipsesStayInsideExpressions() throws {
        for words in [
            ["If", "@", "J/dw", ";", ">", "0", "then", "continue"],
            ["Unless", "aJ/dw", ";", "=", "0"],
            ["Rate", "a", "'", "=", "a/N"],
            ["Examples", "M", "c", "{", "1", ",", ".", ".", ".", ",", "N", "}"],
            ["Use", "Rd", "as", "input"],
            ["Use", "L", "'", "regularization"]
        ] {
            let value = fixture(words)
            let output = ImageTranslationMathProtection.protect([value.region],
                observations: [value.observation], imageSize: CGSize(width: 1200, height: 600))
            let region = try XCTUnwrap(output.first)
            XCTAssertEqual(region.tokens.filter(\.isMathematical).count, 1, words.joined(separator: " "))
            XCTAssertTrue(region.sourceText.hasPrefix(words[0]))
        }
        let dataset = fixture(["Use", "data", "D", "=", "{", "x", ",", "t", "}"])
        let output = ImageTranslationMathProtection.protect([dataset.region], observations: [dataset.observation],
            imageSize: CGSize(width: 1200, height: 600))
        XCTAssertEqual(try XCTUnwrap(output.first).tokens.map(\.text), ["Use", "data", "⟦math_1⟧"])
        let prose = fixture(["(", "try", "a", "smaller", "step", ")"])
        XCTAssertEqual(ImageTranslationMathProtection.protect([prose.region], observations: [prose.observation],
            imageSize: CGSize(width: 1200, height: 600)), [prose.region])
    }

    func testInlineInkRecoveryFindsOmittedVectorWithoutTakingAdjacentRows() throws {
        let size = CGSize(width: 900, height: 350)
        let vectorInk = stride(from: 200, through: 600, by: 25).map {
            CGRect(x: CGFloat($0), y: 130, width: 15, height: 25)
        }
        let image = try inkImage(size: size, rects: vectorInk + [
            CGRect(x: 200, y: 80, width: 120, height: 20),
            CGRect(x: 200, y: 185, width: 120, height: 20),
            CGRect(x: 650, y: 130, width: 100, height: 25)
        ])
        let source = observation([
            ("E", CGRect(x: 550, y: 125, width: 22, height: 35)),
            ("RP", CGRect(x: 580, y: 125, width: 40, height: 35)),
            ("inputs", CGRect(x: 650, y: 125, width: 100, height: 35))
        ], size: size)
        let output = ImageTranslationMathProtection.protect([], observations: [source], imageSize: size, cgImage: image)
        let math = output.flatMap(\.tokens).filter(\.isMathematical).map {
            CGRect(x: $0.x * size.width, y: $0.y * size.height,
                   width: $0.width * size.width, height: $0.height * size.height)
        }
        XCTAssertTrue(math.contains { $0.contains(CGPoint(x: 205, y: 140)) })
        XCTAssertFalse(math.contains { $0.contains(CGPoint(x: 205, y: 190)) })
        XCTAssertFalse(math.contains { $0.contains(CGPoint(x: 205, y: 90)) })
        XCTAssertFalse(math.contains { $0.contains(CGPoint(x: 660, y: 140)) })
    }

    func testProseAscendersDoNotCutOffLaterDisplayTerms() throws {
        let size = CGSize(width: 1000, height: 350)
        let image = try inkImage(size: size, rects:
            stride(from: 200, through: 750, by: 25).map { CGRect(x: CGFloat($0), y: 130, width: 16, height: 30) } + [
                CGRect(x: 250, y: 200, width: 100, height: 20),
                CGRect(x: 500, y: 190, width: 100, height: 30)
            ])
        let seed = observation([("J", CGRect(x: 200, y: 125, width: 25, height: 40)),
                                ("=", CGRect(x: 240, y: 125, width: 25, height: 40)),
                                ("N", CGRect(x: 280, y: 125, width: 25, height: 40))], size: size)
        let prose = observation([("parameters", CGRect(x: 250, y: 185, width: 100, height: 40)),
                                 ("linear", CGRect(x: 500, y: 185, width: 100, height: 40))], size: size)
        let output = ImageTranslationMathProtection.protect([], observations: [seed, prose], imageSize: size, cgImage: image)
        let math = output.flatMap(\.tokens).filter(\.isMathematical).map {
            CGRect(x: $0.x * size.width, y: $0.y * size.height,
                   width: $0.width * size.width, height: $0.height * size.height)
        }
        XCTAssertTrue(math.contains { $0.contains(CGPoint(x: 755, y: 155)) })
        XCTAssertFalse(math.contains { $0.contains(CGPoint(x: 505, y: 195)) })
    }

    func testCroppedDisplayContinuesAfterEqualsAndKeepsSummationOCRProduct() throws {
        let sum = fixture(["5", "-", "3", "Ewyx", ",", "+", "6"])
        let sumOutput = ImageTranslationMathProtection.protect([sum.region], observations: [sum.observation],
            imageSize: CGSize(width: 1200, height: 600))
        XCTAssertTrue(sumOutput.allSatisfy { !$0.requiresTranslation })
        let size = CGSize(width: 800, height: 220)
        let image = try inkImage(size: size, rects: [
            CGRect(x: 380, y: 125, width: 70, height: 30), // and
            CGRect(x: 470, y: 125, width: 65, height: 30), // w =
            CGRect(x: 550, y: 70, width: 5, height: 150), // bracket, omitted by OCR
            CGRect(x: 565, y: 120, width: 30, height: 70),
            CGRect(x: 605, y: 70, width: 5, height: 150)
        ])
        let observations = [
            observation([("and", CGRect(x: 380, y: 120, width: 70, height: 40)),
                         ("w", CGRect(x: 470, y: 120, width: 65, height: 40)),
                         ("=", CGRect(x: 470, y: 120, width: 65, height: 40))], size: size),
            observation([("W1", CGRect(x: 565, y: 120, width: 30, height: 30))], size: size),
            observation([("W2", CGRect(x: 565, y: 160, width: 30, height: 30))], size: size)
        ]
        let output = ImageTranslationMathProtection.protect([], observations: observations, imageSize: size, cgImage: image)
        let math = output.flatMap(\.tokens).filter(\.isMathematical).map {
            CGRect(x: $0.x * size.width, y: $0.y * size.height,
                   width: $0.width * size.width, height: $0.height * size.height)
        }
        XCTAssertTrue(math.contains { $0.contains(CGPoint(x: 552, y: 75)) })
        XCTAssertTrue(math.contains { $0.contains(CGPoint(x: 552, y: 215)) })
        XCTAssertFalse(math.contains { $0.contains(CGPoint(x: 390, y: 140)) })
    }

    func testAnnotatedVariablesArePreservedOnlyInsideAnExpression() throws {
        let expression = fixture(["The", "solution", "is", "wRidge", "=", "Xw"])
        let result = ImageTranslationMathProtection.protect(
            [expression.region], observations: [expression.observation],
            imageSize: CGSize(width: 1200, height: 600)
        )
        let region = try XCTUnwrap(result.first)
        XCTAssertEqual(region.tokens.map(\.text), ["The", "solution", "is", "⟦math_1⟧"])
        let ordinary = fixture(["Use", "iPhone", "labels"])
        XCTAssertEqual(ImageTranslationMathProtection.protect(
            [ordinary.region], observations: [ordinary.observation],
            imageSize: CGSize(width: 1200, height: 600)
        ), [ordinary.region])
    }

    func testOCRDerivativeProductInsideBracketsIsNotTranslated() {
        // Vision reads the numerator ∂L^(i) as "[aL (i)]". Sending aL to
        // translation produced a tiny vertical Chinese label over the formula.
        let expression = fixture(["[", "aL", "(", "i", ")", "]"])
        let result = ImageTranslationMathProtection.protect(
            [expression.region], observations: [expression.observation],
            imageSize: CGSize(width: 1200, height: 600)
        )
        XCTAssertFalse(result.isEmpty)
        XCTAssertTrue(result.allSatisfy { !$0.requiresTranslation })
        XCTAssertTrue(result.flatMap(\.tokens).allSatisfy(\.isMathematical))
    }

    func testTallProseOCRBoxDoesNotClipTheNextEquationSuperscript() throws {
        let size = CGSize(width: 900, height: 300)
        let image = try inkImage(size: size, rects: [
            CGRect(x: 350, y: 40, width: 100, height: 20), // actual prose ink
            CGRect(x: 380, y: 115, width: 15, height: 15), // upper summation limit
            CGRect(x: 300, y: 160, width: 200, height: 23)
        ])
        let observations = [
            observation([("Expand", CGRect(x: 350, y: 40, width: 100, height: 90))], size: size),
            observation([("J", CGRect(x: 300, y: 160, width: 25, height: 30)),
                         ("=", CGRect(x: 340, y: 160, width: 25, height: 30)),
                         ("0", CGRect(x: 380, y: 160, width: 120, height: 30))], size: size)
        ]
        let result = ImageTranslationMathProtection.protect([], observations: observations,
            imageSize: size, cgImage: image)
        let rects = result.flatMap(\.tokens).filter(\.isMathematical).map {
            CGRect(x: $0.x * size.width, y: $0.y * size.height,
                   width: $0.width * size.width, height: $0.height * size.height)
        }
        XCTAssertTrue(rects.contains { $0.contains(CGPoint(x: 387, y: 116)) })
        XCTAssertFalse(rects.contains { $0.contains(CGPoint(x: 387, y: 45)) })
    }

    func testDisplayFormulaRecoveryContinuesUntilActualBlankColumns() throws {
        let size = CGSize(width: 1400, height: 280)
        let formulaInk = stride(from: 200, through: 1100, by: 30).map {
            CGRect(x: CGFloat($0), y: 110, width: 18, height: 20)
        }
        let image = try inkImage(size: size, rects: formulaInk + [
            CGRect(x: 1250, y: 110, width: 70, height: 20) // separate illustration
        ])
        let seed = observation([("J", CGRect(x: 200, y: 110, width: 25, height: 30)),
                                ("=", CGRect(x: 240, y: 110, width: 25, height: 30)),
                                ("0", CGRect(x: 280, y: 110, width: 25, height: 30))], size: size)
        let result = ImageTranslationMathProtection.protect([], observations: [seed],
            imageSize: size, cgImage: image)
        let rects = result.flatMap(\.tokens).filter(\.isMathematical).map {
            CGRect(x: $0.x * size.width, y: $0.y * size.height,
                   width: $0.width * size.width, height: $0.height * size.height)
        }
        XCTAssertTrue(rects.contains { $0.contains(CGPoint(x: 1105, y: 120)) },
                      "Later terms must survive even when OCR only finds the left side")
        XCTAssertFalse(rects.contains { $0.contains(CGPoint(x: 1260, y: 120)) },
                       "A separate illustration after a blank interval must not be swallowed")
    }

    func testWrappedMembershipUsesFollowingVectorSpaceAsEvidence() throws {
        let first = fixture(["Arbitrary", "point", "t", "e"], id: "first", y: 0.2)
        let continuation = fixture(["RN", "is", "considered"], id: "next", y: 0.25)
        let output = ImageTranslationMathProtection.protect([first.region, continuation.region],
            observations: [first.observation, continuation.observation], imageSize: CGSize(width: 1200, height: 600))
        let wrapped = try XCTUnwrap(output.first { $0.id == "first" })
        XCTAssertEqual(wrapped.tokens.map(\.text), ["Arbitrary", "point", "⟦math_1⟧"])
        XCTAssertEqual(ImageTranslationMathProtection.protect([first.region], observations: [first.observation],
            imageSize: CGSize(width: 1200, height: 600)), [first.region], "An isolated e is not enough mathematical evidence")
    }

    func testCalculusFunctionsAndVectorSpacesRemainOriginalPixels() throws {
        for words in [
            ["Use", "range", "(", "X", ")", "for", "projection"],
            ["Use", "Vf", "(", "w", ")", "for", "optimization"],
            ["Use", "x", "∈", "RN", "for", "prediction"],
            ["Use", "y", "*", "-", "t", "for", "residuals"]
        ] {
            let value = fixture(words)
            let result = ImageTranslationMathProtection.protect([value.region], observations: [value.observation], imageSize: CGSize(width: 1200, height: 600))
            let prose = try XCTUnwrap(result.first(where: \.requiresTranslation))
            XCTAssertTrue(prose.tokens.contains { $0.text == "Use" && !$0.isProtected })
            XCTAssertTrue(prose.tokens.contains( where: \.isMathematical))
            XCTAssertTrue(prose.sourceText.contains(words.last!))
        }
        let prose = fixture(["Choose", "the", "range", "carefully"])
        XCTAssertEqual(ImageTranslationMathProtection.protect([prose.region], observations: [prose.observation], imageSize: CGSize(width: 1200, height: 600)), [prose.region])
    }

    func testDetachedFormulaHasProtectedCarrierWithoutAProseRegion() throws {
        let formula = fixture(["y", "=", "Xw", "+", "b1"])
        let regions = ImageTranslationMathProtection.protect(
            [], observations: [formula.observation], imageSize: CGSize(width: 1200, height: 600)
        )
        let carrier = try XCTUnwrap(regions.first)
        XCTAssertEqual(regions.count, 1)
        XCTAssertFalse(carrier.requiresTranslation)
        XCTAssertTrue(carrier.tokens.allSatisfy(\.isMathematical))
        XCTAssertEqual(carrier.translationStrategy, .selective)
    }

    func testJuxtaposedVariablesAndOCRNormBarsStayOpaqueInline() throws {
        let formula = fixture(["Sometimes", "use", "J", "=", "Illy", "-", "tll", "without", "normalization"])
        let result = ImageTranslationMathProtection.protect(
            [formula.region], observations: [formula.observation], imageSize: CGSize(width: 1200, height: 600)
        )
        let region = try XCTUnwrap(result.first)
        XCTAssertEqual(region.tokens.filter(\.isMathematical).count, 1)
        XCTAssertEqual(region.tokens.map(\.text), ["Sometimes", "use", "⟦math_1⟧", "without", "normalization"])
    }

    func testLowercaseProductsAndDifferentialsNeedMathematicalContext() throws {
        for product in ["wx", "xy", "dx"] {
            let formula = fixture(["Predictions", "are", "y", "=", product, "+", "b1"])
            let result = ImageTranslationMathProtection.protect(
                [formula.region], observations: [formula.observation], imageSize: CGSize(width: 1200, height: 600)
            )
            let region = try XCTUnwrap(result.first)
            XCTAssertEqual(region.tokens.map(\.text), ["Predictions", "are", "⟦math_1⟧"], product)
        }
        for words in [["I", "am", "on", "my", "way"], ["Click", "→", "Go"], ["Use", "dx", "labels"]] {
            let prose = fixture(words)
            XCTAssertEqual(ImageTranslationMathProtection.protect(
                [prose.region], observations: [prose.observation], imageSize: CGSize(width: 1200, height: 600)
            ), [prose.region])
        }
    }

    func testDifferentVariablesAndOperatorsBecomeWholeOpaqueExpressions() throws {
        let words = ["Threshold", "applies", "if", "α_i", "≤", "ε", "and", "m", "/", "n", "→", "0", "."]
        let fixture = fixture(words)
        let output = ImageTranslationMathProtection.protect(
            [fixture.region], observations: [fixture.observation], imageSize: CGSize(width: 1200, height: 600)
        )
        let region = try XCTUnwrap(output.first)
        XCTAssertEqual(region.tokens.filter(\.isMathematical).count, 2)
        XCTAssertEqual(region.tokens.filter(\.isMathematical).map(\.text), ["⟦math_1⟧", "⟦math_2⟧"])
        XCTAssertTrue(region.tokens.contains { $0.text == "and" && !$0.isProtected })
        XCTAssertFalse(region.tokens.contains { ["α_i", "≤", "ε", "m", "/", "n", "→", "0"].contains($0.text) })
        XCTAssertEqual(region.id, fixture.region.id)
        XCTAssertEqual(region.kind, fixture.region.kind)
        XCTAssertEqual(region.weight, fixture.region.weight)
        XCTAssertEqual(region.fontSize, fixture.region.fontSize)
        XCTAssertEqual(region.alignment, fixture.region.alignment)
        XCTAssertEqual(region.textColor, fixture.region.textColor)
        XCTAssertEqual(region.backgroundColor, fixture.region.backgroundColor)
        XCTAssertEqual(region.imageAspectRatio, 2)
    }

    func testIsolatedVariablesDoNotForceOtherSentencesIntoSelectiveTranslation() throws {
        let expression = fixture(["Choose", "t", "<", "Vq"], id: "expression", y: 0.2)
        let prose = fixture(["I", "use", "a", "label", "x", "and", "t"], id: "prose", y: 0.4)
        let output = ImageTranslationMathProtection.protect(
            [expression.region, prose.region], observations: [expression.observation, prose.observation],
            imageSize: CGSize(width: 1200, height: 600)
        )
        let result = try XCTUnwrap(output.first { $0.id == "prose" })
        XCTAssertEqual(result, prose.region)
        XCTAssertEqual(result.translationStrategy, .block)
        XCTAssertFalse(result.preservesInlineMath)
    }

    func testOrdinaryWordsAndListMarkersDoNotCreateMathRegions() {
        for words in [[">", "Choose", "a", "setting"], ["Click", "→", "Next"], ["Use", "Vn", "label"]] {
            let f = fixture(words)
            XCTAssertEqual(ImageTranslationMathProtection.protect(
                [f.region], observations: [f.observation], imageSize: CGSize(width: 1200, height: 600)
            ), [f.region])
        }
    }

    func testInvalidImageSizeKeepsExistingRegions() {
        let f = fixture(["Choose", "t", "<", "Vq"])
        for size in [CGSize.zero, CGSize(width: CGFloat.infinity, height: 600), CGSize(width: 1200, height: CGFloat.nan)] {
            XCTAssertEqual(ImageTranslationMathProtection.protect([f.region], observations: [f.observation], imageSize: size), [f.region])
        }
    }

    private func pixelRect(_ token: ImageTranslationSourceToken, size: CGSize) -> CGRect {
        let normalized = CGRect(x: token.x, y: token.y, width: token.width, height: token.height)
        return normalized.applying(CGAffineTransform(scaleX: size.width, y: size.height))
    }

    private func observation(_ words: [(String, CGRect)], size: CGSize) -> ImageTranslationMathObservation {
        let rect = words.dropFirst().reduce(words[0].1) { $0.union($1.1) }
        return ImageTranslationMathObservation(text: words.map(\.0).joined(separator: " "),
            rect: ImageTranslationLineRect(x: rect.minX / size.width, y: rect.minY / size.height,
                width: rect.width / size.width, height: rect.height / size.height),
            tokens: words.map { word, box in
                ImageTranslationTokenRect(text: word, x: box.minX / size.width, y: box.minY / size.height,
                    width: box.width / size.width, height: box.height / size.height)
            })
    }

    private func inkImage(size: CGSize, rects: [CGRect]) throws -> CGImage {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: Int(size.width) * 4, bitsPerPixel: 32))
        let bytes = try XCTUnwrap(bitmap.bitmapData)
        bytes.initialize(repeating: 255, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        for rect in rects {
            for y in Int(rect.minY)..<Int(rect.maxY) {
                for x in Int(rect.minX)..<Int(rect.maxX) {
                    let offset = y * bitmap.bytesPerRow + x * 4
                    bytes[offset] = 0; bytes[offset + 1] = 0; bytes[offset + 2] = 0
                }
            }
        }
        return try XCTUnwrap(bitmap.cgImage)
    }

    private func fixture(_ words: [String], id: String = "line", y: Double = 0.2,
                         protectedIndexes: Set<Int> = [], codeIndexes: Set<Int> = [])
        -> (region: ImageTranslationSourceRegion, observation: ImageTranslationMathObservation) {
        let raw = words.enumerated().map { index, word in
            ImageTranslationTokenRect(text: word, x: 0.05 + Double(index) * 0.06, y: y, width: 0.05, height: 0.04)
        }
        let line = ImageTranslationLineRect(x: 0.05, y: y, width: Double(words.count) * 0.06, height: 0.04)
        let source = ImageTranslationSourceRegion(
            id: id, sourceText: words.joined(separator: " "), x: line.x, y: line.y,
            width: line.width, height: line.height, imageAspectRatio: 2,
            lineRects: [line], preservesListMarker: true, textRects: raw.map {
                ImageTranslationLineRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
            }, tokens: raw.enumerated().map { index, token in
                ImageTranslationSourceToken(text: token.text, x: token.x, y: token.y, width: token.width, height: token.height,
                                            isProtected: protectedIndexes.contains(index))
            }, codeRects: raw.enumerated().compactMap { codeIndexes.contains($0.offset) ? $0.element : nil },
            kind: "list_item", textColor: "#202020", backgroundColor: "#ffffff", alignment: "left",
            weight: "regular", fontSize: 0.035
        )
        return (source, ImageTranslationMathObservation(text: source.sourceText, rect: line, tokens: raw))
    }
}
