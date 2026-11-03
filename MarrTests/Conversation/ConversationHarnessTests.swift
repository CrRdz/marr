import AppKit
import Carbon
import ImageIO
import MarrCore
import MarrNetworking
import MarrSettings
import ScreenCaptureKit
import SwiftUI
import class Vision.VNImageRequestHandler
import class Vision.VNRecognizeTextRequest
import XCTest
@testable import Marr

@MainActor
final class ConversationHarnessTests: XCTestCase {
    func testTranslationParserExtractsCompleteArraysWithCommentaryAndQuotedDelimiters() {
        let response = #"Result: [{"id":"first","text":"保留 {name} 与 [API]"},{"id":"second","text":"引用 \"文本\""}] End of result."#
        let replacements = ImageTranslationResponseParser.parseReplacements(response)
        XCTAssertEqual(replacements.map(\.id), ["first", "second"])
        XCTAssertEqual(replacements.map(\.text), ["保留 {name} 与 [API]", "引用 \"文本\""])
        XCTAssertEqual(ImageTranslationResponseParser.parseReplacements(
            #"{"translations":[{"id":"first","text":"译文"}]} Trailing note."#
        ).map(\.text), ["译文"])
        XCTAssertEqual(ImageTranslationResponseParser.parseReplacements(
            #"[done] {"status":"ok"} [{"status":"ok"}] {"translations":[{"id":"first","text":"译文"}]}"#
        ).map(\.text), ["译文"])
    }

    func testTranslationParserPreservesPlainTextBracketsAndMathematicalSets() {
        for prose in ["保留 [API] 标签", "集合 {x,y}", "区间 [1, 2]", "[API] 是接口", "**保留 [名称](地址)**"] {
            XCTAssertEqual(ImageTranslationResponseParser.parse(prose).map(\.text), [prose])
        }
        XCTAssertEqual(ImageTranslationResponseParser.parse(
            #"[done] {"status":"ok"} {"translations":[{"text":"译文","x":0.1,"y":0.2}]}"#
        ).map(\.text), ["译文"])
    }

    func testTranslationParserKeepsValidSiblingsAndSegmentsAfterMalformedItems() {
        let response = #"{"translations":[{"id":"first","text":"有效译文","alignments":[null,{"tokenStart":"bad","tokenEnd":1,"text":"无效"},{"tokenStart":0,"tokenEnd":1,"text":"有效译文"}]},{"id":17,"text":"无效ID"},null,{"id":"label","segments":[{"tokenStart":"bad","tokenEnd":1,"text":"无效"},{"tokenStart":2,"tokenEnd":3,"text":"设置"}]}]}"#
        let replacements = ImageTranslationResponseParser.parseReplacements(response)
        XCTAssertEqual(replacements.map(\.id), ["first", "label"])
        XCTAssertEqual(replacements.first?.text, "有效译文")
        XCTAssertEqual(replacements.first?.alignments.count, 1)
        XCTAssertEqual(replacements.last?.segments, [
            ImageTranslationReplacementSegment(tokenStart: 2, tokenEnd: 3, text: "设置")
        ])
    }

    func testTranslationParserIgnoresMalformedOptionalMetadataButKeepsIdentityAndTextStrict() {
        let response = #"{"translations":[{"id":"block","text":"完整译文","kind":17,"type":[],"alignments":{"unexpected":true}},{"id":"label","segments":[{"tokenStart":"bad","tokenEnd":1,"text":"丢弃"},{"tokenStart":2,"tokenEnd":3,"text":"设置"}],"kind":{},"alignments":"unavailable"},{"id":17,"text":"错误ID"},{"id":"bad-text","text":{"value":"错误文本类型"}}]}"#
        let replacements = ImageTranslationResponseParser.parseReplacements(response)
        XCTAssertEqual(replacements.map(\.id), ["block", "label"])
        XCTAssertEqual(replacements.first?.text, "完整译文")
        XCTAssertNil(replacements.first?.kind)
        XCTAssertEqual(replacements.first?.alignments, [])
        XCTAssertEqual(replacements.last?.segments, [
            ImageTranslationReplacementSegment(tokenStart: 2, tokenEnd: 3, text: "设置")
        ])
        XCTAssertEqual(replacements.last?.alignments, [])
    }

    func testTranslationCoordinateParserIgnoresMalformedStyleButRejectsMalformedGeometry() throws {
        let blocks = ImageTranslationResponseParser.parse(#"{"translations":[{"text":"保留译文","x":0.1,"y":0.2,"width":0.3,"height":0.1,"kind":{},"type":17,"textColor":[1,2,3],"foregroundColor":12,"color":false,"backgroundColor":{},"bgColor":3,"alignment":[],"fontSize":"large","weight":700,"fontWeight":{}},{"text":"错误坐标","x":"left","y":0.2},{"text":"错误宽度","x":0.1,"width":{}},{"text":17,"x":0.1,"y":0.2}]}"#)
        XCTAssertEqual(blocks.map(\.text), ["保留译文"])
        let block = try XCTUnwrap(blocks.first)
        XCTAssertEqual(block.x, 0.1, accuracy: 0.00001)
        XCTAssertEqual(block.y, 0.2, accuracy: 0.00001)
        XCTAssertEqual(block.width, 0.3, accuracy: 0.00001)
        XCTAssertEqual(block.height, 0.1, accuracy: 0.00001)
        XCTAssertNil(block.kind)
        XCTAssertNil(block.textColor)
        XCTAssertNil(block.backgroundColor)
        XCTAssertNil(block.alignment)
        XCTAssertNil(block.fontSize)
        XCTAssertNil(block.weight)
    }

    func testTranslationParserUsesNonemptyDuplicateWithoutChangingOrder() {
        let response = #"{"translations":[{"id":"first","segments":[]},{"id":"second","text":"第二项"},{"id":"first","text":"第一项"},{"id":"second","segments":[]}]}"#
        let replacements = ImageTranslationResponseParser.parseReplacements(response)
        XCTAssertEqual(replacements.map(\.id), ["first", "second"])
        XCTAssertEqual(replacements.map(\.text), ["第一项", "第二项"])
    }

    func testTranslationCoordinateParserDoesNotRenderBrokenJSONAsText() {
        for response in [#"{"translations":[{"text":"未完成""#,
                         "```json\n{\"translations\":[{\"text\":\"未完成\"}\n```",
                         #"Result: [{"text": }]"#] {
            XCTAssertTrue(ImageTranslationResponseParser.parse(response).isEmpty, response)
        }
        let blocks = ImageTranslationResponseParser.parse(
            #"{"translations":[{"text":"有效译文","x":0.1,"y":0.2,"width":0.3,"height":0.1},{"text":12}]}"#)
        XCTAssertEqual(blocks.map(\.text), ["有效译文"])
        XCTAssertEqual(ImageTranslationResponseParser.parse("正常的纯文本译文").map(\.text), ["正常的纯文本译文"])
    }

    private func ordinarySelectiveTranslationRegion() -> ImageTranslationSourceRegion {
        ImageTranslationSourceRegion(id: "label", sourceText: "Open API settings",
            x: 0.1, y: 0.2, width: 0.6, height: 0.1,
            tokens: [
                ImageTranslationSourceToken(text: "Open", x: 0.1, y: 0.2, width: 0.15, height: 0.1),
                ImageTranslationSourceToken(text: "API", x: 0.3, y: 0.2, width: 0.1, height: 0.1, isProtected: true),
                ImageTranslationSourceToken(text: "settings", x: 0.45, y: 0.2, width: 0.25, height: 0.1)
            ], translationStrategy: .selective)
    }

    func testTranslationCompletionDetectsInvalidAndMissingOrdinarySelectiveSlots() {
        let region = ordinarySelectiveTranslationRegion()
        let missingReplacements = [
            ImageTranslationReplacement(id: region.id, text: ""),
            ImageTranslationReplacement(id: region.id, text: "", segments: [
                ImageTranslationReplacementSegment(tokenStart: 0, tokenEnd: 1, text: "打开")
            ]),
            ImageTranslationReplacement(id: region.id, text: "", segments: [
                ImageTranslationReplacementSegment(tokenStart: 0, tokenEnd: 3, text: "不得覆盖API")
            ]),
            ImageTranslationReplacement(id: region.id, text: "", segments: [
                ImageTranslationReplacementSegment(tokenStart: 0, tokenEnd: 1, text: "Open"),
                ImageTranslationReplacementSegment(tokenStart: 2, tokenEnd: 3, text: "settings")
            ])
        ]
        for replacement in missingReplacements {
            XCTAssertEqual(MarrController.missingTranslationRegions(in: [region], replacements: [replacement]), [region])
        }
        let complete = ImageTranslationReplacement(id: region.id, text: "", segments: [
            ImageTranslationReplacementSegment(tokenStart: 0, tokenEnd: 1, text: "打开"),
            ImageTranslationReplacementSegment(tokenStart: 2, tokenEnd: 3, text: "设置")
        ])
        XCTAssertTrue(MarrController.missingTranslationRegions(in: [region], replacements: [complete]).isEmpty)
    }

    func testSelectiveCompletionRejectsNumericBadgeEchoAfterCleaning() {
        let region = ordinarySelectiveTranslationRegion()
        let response = ImageTranslationReplacement(id: region.id, text: "", segments: [
            ImageTranslationReplacementSegment(tokenStart: 0, tokenEnd: 1, text: "Open 7"),
            ImageTranslationReplacementSegment(tokenStart: 2, tokenEnd: 3, text: "设置")
        ])
        XCTAssertEqual(ImageTranslationMerger.translatedSelectiveSegments(
            replacement: response, region: region).map(\.text), ["设置"])
        XCTAssertEqual(ImageTranslationMerger.missingSelectiveProseIndexes(replacement: response, region: region), [0])
        XCTAssertEqual(ImageTranslationMerger.merge(replacements: [response], regions: [region]).map(\.text), ["设置"])
        XCTAssertEqual(MarrController.missingTranslationRegions(in: [region], replacements: [response]), [region])
        XCTAssertEqual(MarrController.translationCompletionStatus(regions: [region], replacements: [response], isCompleting: false),
                       "Translation incomplete: 1 text region remains untranslated.")
    }

    func testSelectiveCompletionRejectsNumericOnlyTranslationAfterCleaning() {
        let region = ordinarySelectiveTranslationRegion()
        for text in ["7", "(7)", "[7]"] {
            let response = ImageTranslationReplacement(id: region.id, text: "", segments: [
                ImageTranslationReplacementSegment(tokenStart: 0, tokenEnd: 1, text: text),
                ImageTranslationReplacementSegment(tokenStart: 2, tokenEnd: 3, text: "设置")
            ])
            XCTAssertEqual(ImageTranslationMerger.missingSelectiveProseIndexes(replacement: response, region: region), [0])
            XCTAssertEqual(ImageTranslationMerger.merge(replacements: [response], regions: [region]).map(\.text), ["设置"])
            XCTAssertEqual(ImageTranslationHighlightBuilder.pairs(regions: [region], replacements: [response]).count, 1)
        }
        let numberRegion = ImageTranslationSourceRegion(id: "number", sourceText: "one", x: 0, y: 0, width: 0.2, height: 0.1,
            tokens: [ImageTranslationSourceToken(text: "one", x: 0, y: 0, width: 0.2, height: 0.1)], translationStrategy: .selective)
        let number = ImageTranslationReplacement(id: numberRegion.id, text: "", segments: [
            ImageTranslationReplacementSegment(tokenStart: 0, tokenEnd: 1, text: "1")
        ])
        XCTAssertTrue(ImageTranslationMerger.missingSelectiveProseIndexes(replacement: number, region: numberRegion).isEmpty)
        XCTAssertEqual(ImageTranslationMerger.merge(replacements: [number], regions: [numberRegion]).map(\.text), ["1"])
    }

    func testSelectiveRetryCannotReplaceUsableSegmentWithCleanedNoOp() {
        let region = ordinarySelectiveTranslationRegion()
        let original = ImageTranslationReplacement(id: region.id, text: "", segments: [
            ImageTranslationReplacementSegment(tokenStart: 0, tokenEnd: 1, text: "打开")
        ])
        for discarded in ["Open 7", "7", "[7]"] {
            let retry = ImageTranslationReplacement(id: region.id, text: "", segments: [
                ImageTranslationReplacementSegment(tokenStart: 0, tokenEnd: 1, text: discarded),
                ImageTranslationReplacementSegment(tokenStart: 2, tokenEnd: 3, text: "设置")
            ])
            let combined = MarrController.combiningSelectiveTranslation(original: original, retry: retry, region: region)
            XCTAssertEqual(combined.segments.map(\.text), ["打开", "设置"])
            XCTAssertTrue(MarrController.missingTranslationRegions(in: [region], replacements: [combined]).isEmpty)
            XCTAssertEqual(ImageTranslationMerger.merge(replacements: [combined], regions: [region]).map(\.text), ["打开", "设置"])
        }
    }

    func testTranslationCompletionRejectsUnchangedBlockAndReportsIncompleteStatus() {
        let region = ImageTranslationSourceRegion(id: "block", sourceText: "Open settings", x: 0, y: 0, width: 1, height: 0.1)
        let unchanged = ImageTranslationReplacement(id: region.id, text: region.sourceText)
        XCTAssertEqual(MarrController.missingTranslationRegions(in: [region], replacements: [unchanged]), [region])
        XCTAssertEqual(MarrController.translationCompletionStatus(regions: [region], replacements: [unchanged], isCompleting: true),
                       "Completing untranslated text...")
        XCTAssertEqual(MarrController.translationCompletionStatus(regions: [region], replacements: [unchanged], isCompleting: false),
                       "Translation incomplete: 1 text region remains untranslated.")
        XCTAssertEqual(MarrController.translationCompletionStatus(regions: [region], replacements: [
            ImageTranslationReplacement(id: region.id, text: "打开设置")
        ], isCompleting: false), "Translation ready.")
    }

    func testTranslationCompletionRetainsExistingOrdinarySelectiveSegmentsAndRejectsUnknownIDs() async throws {
        let fixture = TranslationRoutingFixture(settings: .default)
        addTeardownBlock { try await fixture.cleanUp() }
        fixture.codex.responseText = #"{"translations":[{"id":"label","segments":[{"tokenStart":2,"tokenEnd":3,"text":"设置"}]},{"id":"unknown","text":"无关译文"}]}"#
        let controller = fixture.makeController()
        let region = ordinarySelectiveTranslationRegion()
        let original = ImageTranslationReplacement(id: region.id, text: "", segments: [
            ImageTranslationReplacementSegment(tokenStart: 0, tokenEnd: 1, text: "打开")
        ])
        let completed = try await controller.completedTranslationReplacements(
            [original], regions: [region], configuration: .codex(model: "test-model", effort: nil))
        XCTAssertEqual(completed.map(\.id), [region.id])
        XCTAssertEqual(completed.first?.segments, [
            ImageTranslationReplacementSegment(tokenStart: 0, tokenEnd: 1, text: "打开"),
            ImageTranslationReplacementSegment(tokenStart: 2, tokenEnd: 3, text: "设置")
        ])
        XCTAssertEqual(fixture.codex.calls.count, 1)
        XCTAssertTrue(MarrController.missingTranslationRegions(in: [region], replacements: completed).isEmpty)
        let repeated = try await controller.completedTranslationReplacements(
            completed, regions: [region], configuration: .codex(model: "test-model", effort: nil))
        XCTAssertEqual(repeated, completed)
        XCTAssertEqual(fixture.codex.calls.count, 1, "A complete result must not trigger another completion request")
    }

    func testStreamingCancellationKeepsPartialTextAndRejectsLateEventsForRetriedTurn() async throws {
        let session = ConversationSession()
        let turnID = try XCTUnwrap(session.beginTurn(question: "Explain this"))
        let firstStarted = expectation(description: "first stream started")
        let secondStarted = expectation(description: "replacement stream started")
        let failed = expectation(description: "replacement stream failed")
        var handlers: [VisionResponseHandler] = []
        var continuations: [CheckedContinuation<String, Error>] = []
        let coordinator = ConversationRequestCoordinator(session: session) { _, onEvent in
            handlers.append(onEvent)
            return try await withCheckedThrowingContinuation { continuation in
                continuations.append(continuation)
                if continuations.count == 1 { firstStarted.fulfill() }
                else { secondStarted.fulfill() }
            }
        }
        session.setArchiveHandler(persistImmediately: false) { archive in
            if archive.turns.first?.errorMessage == "Stream interrupted." { failed.fulfill() }
        }
        coordinator.submit(turnID)
        await fulfillment(of: [firstStarted], timeout: 1)
        handlers[0](.text("First partial"))
        XCTAssertEqual(session.turns[0].answer, "First partial")
        XCTAssertEqual(session.turns[0].status, .loading)
        XCTAssertTrue(session.turns[0].showsAssistant)
        coordinator.cancel()
        XCTAssertEqual(session.turns[0].status, .failed)
        XCTAssertEqual(session.turns[0].answer, "First partial")
        XCTAssertEqual(session.turns[0].errorMessage, "Request cancelled.")

        XCTAssertTrue(session.prepareRetry(turnID))
        coordinator.submit(turnID)
        await fulfillment(of: [secondStarted], timeout: 1)
        handlers[1](.text("New partial"))
        handlers[0](.text("Stale response"))
        continuations[0].resume(returning: "Stale completion")
        XCTAssertEqual(session.turns[0].answer, "New partial")
        continuations[1].resume(throwing: UserFacingError("Stream interrupted."))
        await fulfillment(of: [failed], timeout: 1)
        XCTAssertEqual(session.turns[0].answer, "New partial")
        XCTAssertEqual(session.turns[0].status, .failed)
        XCTAssertFalse(session.hasLoadingTurn)
    }

    func testStreamingRetryStateClearsOnNewAttemptAndFinalCompletion() throws {
        let session = ConversationSession()
        let turnID = try XCTUnwrap(session.beginTurn(question: "Retry safely"))
        let retryAt = Date().addingTimeInterval(3)
        session.receive(.retryScheduled(attempt: 1, resumeAt: retryAt), for: turnID)
        XCTAssertEqual(session.turns[0].retryAt, retryAt)
        XCTAssertEqual(session.turns[0].retryAttempt, 1)
        XCTAssertEqual(session.turns[0].status, .loading)
        session.receive(.requestStarted, for: turnID)
        XCTAssertNil(session.turns[0].retryAt)
        session.receive(.text("Working answer"), for: turnID)
        session.complete(turnID, answer: "Finished answer")
        session.receive(.text("Late answer"), for: turnID)
        XCTAssertEqual(session.turns[0].answer, "Finished answer")
        XCTAssertEqual(session.turns[0].status, .completed)
        XCTAssertNil(session.turns[0].retryAttempt)
    }

    func testRestoringInterruptedStreamPreservesPartialAnswerAndClearsRetryState() throws {
        let session = ConversationSession()
        let turnID = try XCTUnwrap(session.beginTurn(question: "Continue later"))
        session.receive(.text("Already received"), for: turnID)
        session.receive(.retryScheduled(attempt: 1, resumeAt: Date()), for: turnID)
        let record = ConversationHistoryRecord(
            id: session.id, createdAt: Date(), updatedAt: Date(), turns: session.turns, images: [], pendingImageIDs: [])
        let restored = ConversationSession(historyRecord: record, imageAssets: [])
        XCTAssertEqual(restored.turns[0].answer, "Already received")
        XCTAssertEqual(restored.turns[0].status, .failed)
        XCTAssertNotNil(restored.turns[0].errorMessage)
        XCTAssertNil(restored.turns[0].retryAt)
        XCTAssertNil(restored.turns[0].retryAttempt)
    }

    private func standaloneMathRegion() -> ImageTranslationSourceRegion {
        ImageTranslationSourceRegion(
            id: "formula-only", sourceText: "⟦math_1⟧",
            x: 0.2, y: 0.4, width: 0.6, height: 0.2,
            tokens: [ImageTranslationSourceToken(
                text: "⟦math_1⟧", x: 0.2, y: 0.4, width: 0.6, height: 0.2,
                isMathematical: true
            )], translationStrategy: .selective
        )
    }

    func testStandaloneFormulasAreExcludedFromTranslationPromptsAndCompletion() throws {
        let formula = standaloneMathRegion()
        let prose = inlineMathRegion()
        XCTAssertFalse(formula.requiresTranslation)
        XCTAssertTrue(prose.requiresTranslation)
        XCTAssertFalse([formula].contains(where: \.requiresTranslation),
                       "A formula-only capture must return its source image before sending a request")

        for request in [
            ImageTranslationPrompt.fastRequest(regions: [formula, prose]),
            ImageTranslationPrompt.request(regions: [formula, prose]),
            ImageTranslationPrompt.request(for: makeImage(name: "math.png", byte: 8), regions: [formula, prose])
        ] {
            let prompt = try XCTUnwrap(text(in: request.messages[0]))
            XCTAssertFalse(prompt.contains(formula.id))
            XCTAssertTrue(prompt.contains(prose.id))
        }
        XCTAssertTrue(MarrController.missingTranslationRegions(in: [formula], replacements: []).isEmpty)
        XCTAssertEqual(MarrController.missingTranslationRegions(
            in: [formula, prose], replacements: []
        ).map(\.id), [prose.id])
        XCTAssertTrue(MarrController.deepLXSelectiveRanges(for: formula).isEmpty)
    }

    func testStandaloneFormulaGeometrySurvivesWithoutAnyFormulaReplacement() throws {
        let formula = standaloneMathRegion()
        let prose = ImageTranslationSourceRegion(
            id: "prose", sourceText: "Then our predictions reduce to", x: 0.05, y: 0.7,
            width: 0.8, height: 0.05
        )
        let expectedRect = ImageTranslationLineRect(x: 0.2, y: 0.4, width: 0.6, height: 0.2)
        for formulaReplacements in [[], [ImageTranslationReplacement(
            id: formula.id, text: "模型错误地重写了整个矩阵", segments: [
                ImageTranslationReplacementSegment(tokenStart: 0, tokenEnd: 1, text: "预测值")
            ]
        )]] {
            let blocks = ImageTranslationMerger.merge(
                replacements: formulaReplacements + [ImageTranslationReplacement(id: prose.id, text: "于是预测可简化为")],
                regions: [formula, prose]
            )
            XCTAssertEqual(blocks.map(\.sourceID), [prose.id])
            XCTAssertEqual(try XCTUnwrap(blocks.first).mathRects, [expectedRect])
        }
        XCTAssertTrue(ImageTranslationMerger.merge(
            replacements: [ImageTranslationReplacement(id: formula.id, text: "错误重写")],
            regions: [formula]
        ).isEmpty)
    }

    func testFormulaFilteringDoesNotSuppressProtectedWordsInBlockTranslation() {
        let region = ImageTranslationSourceRegion(
            id: "ordinary", sourceText: "Screenshots", x: 0, y: 0, width: 0.3, height: 0.1,
            tokens: [ImageTranslationSourceToken(
                text: "Screenshots", x: 0, y: 0, width: 0.3, height: 0.1, isProtected: true
            )]
        )
        XCTAssertTrue(region.requiresTranslation)
        XCTAssertEqual(MarrController.missingTranslationRegions(in: [region], replacements: []), [region])
    }

    private func inlineMathRegion() -> ImageTranslationSourceRegion {
        ImageTranslationSourceRegion(
            id: "math", sourceText: "Nice properties if ⟦math_1⟧ and ⟦math_2⟧",
            x: 0.1, y: 0.2, width: 0.7, height: 0.09,
            tokens: [
                ImageTranslationSourceToken(text: "Nice", x: 0.1, y: 0.2, width: 0.08, height: 0.04),
                ImageTranslationSourceToken(text: "properties", x: 0.18, y: 0.2, width: 0.16, height: 0.04),
                ImageTranslationSourceToken(text: "if", x: 0.34, y: 0.2, width: 0.04, height: 0.04),
                ImageTranslationSourceToken(text: "⟦math_1⟧", x: 0.39, y: 0.19, width: 0.15, height: 0.06, isMathematical: true),
                ImageTranslationSourceToken(text: "and", x: 0.55, y: 0.2, width: 0.08, height: 0.04),
                ImageTranslationSourceToken(text: "⟦math_2⟧", x: 0.64, y: 0.18, width: 0.14, height: 0.09, isMathematical: true)
            ], translationStrategy: .selective
        )
    }

    func testMathTranslationKeepsCompleteFormulaBoundsAndRejectsFormulaRewrites() throws {
        let region = inlineMathRegion()
        let replacement = ImageTranslationReplacement(id: region.id, text: "", segments: [
            ImageTranslationReplacementSegment(tokenStart: 0, tokenEnd: 4, text: "非法跨公式翻译"),
            ImageTranslationReplacementSegment(tokenStart: 0, tokenEnd: 3, text: "具有良好的理论性质，当"),
            ImageTranslationReplacementSegment(tokenStart: 4, tokenEnd: 5, text: "且")
        ])
        let blocks = ImageTranslationMerger.merge(replacements: [replacement], regions: [region])
        XCTAssertEqual(blocks.map(\.text), ["具有良好的理论性质，当", "且"])
        for block in blocks {
            XCTAssertTrue(block.trailingAttachments.isEmpty)
            for token in region.tokens.filter(\.isMathematical) {
                XCTAssertTrue(block.protectedRects.contains(ImageTranslationLineRect(
                    x: token.x, y: token.y, width: token.width, height: token.height
                )))
            }
        }
        XCTAssertTrue(ImageTranslationMerger.missingSelectiveProseIndexes(replacement: replacement, region: region).isEmpty)
    }

    func testMathCompletionDetectsOmittedProseAndRetainsAlreadyTranslatedSegments() {
        let region = inlineMathRegion()
        let original = ImageTranslationReplacement(id: region.id, text: "", segments: [
            ImageTranslationReplacementSegment(tokenStart: 0, tokenEnd: 3, text: "具有良好的理论性质，当")
        ])
        XCTAssertEqual(ImageTranslationMerger.missingSelectiveProseIndexes(replacement: original, region: region), [4])
        let retry = ImageTranslationReplacement(id: region.id, text: "", segments: [
            ImageTranslationReplacementSegment(tokenStart: 3, tokenEnd: 6, text: "错误的公式重写"),
            ImageTranslationReplacementSegment(tokenStart: 4, tokenEnd: 5, text: "且")
        ])
        let combined = MarrController.combiningSelectiveTranslation(original: original, retry: retry, region: region)
        XCTAssertEqual(combined.segments.map(\.text), ["具有良好的理论性质，当", "且"])
        XCTAssertTrue(ImageTranslationMerger.missingSelectiveProseIndexes(replacement: combined, region: region).isEmpty)
        let repeatedPlaceholder = ImageTranslationReplacement(id: region.id, text: "", segments: [
            ImageTranslationReplacementSegment(tokenStart: 0, tokenEnd: 3, text: "当 ⟦math_1⟧")
        ])
        XCTAssertTrue(ImageTranslationMerger.merge(replacements: [repeatedPlaceholder], regions: [region]).isEmpty)
    }

    func testUntranslatedFormulaRemainsProtectedFromNeighboringBlock() throws {
        let math = inlineMathRegion()
        let prose = ImageTranslationSourceRegion(
            id: "prose", sourceText: "The next line", x: 0.1, y: 0.28, width: 0.6, height: 0.04
        )
        let block = try XCTUnwrap(ImageTranslationMerger.merge(
            replacements: [ImageTranslationReplacement(id: prose.id, text: "下一行")],
            regions: [math, prose]
        ).first)
        XCTAssertEqual(block.mathRects.count, 2)
        XCTAssertTrue(block.protectedRects.isEmpty)
    }

    func testMathCompletionDoesNotDiscardTranslationOnPartialOverlapOrNoOp() {
        let region = inlineMathRegion()
        let original = ImageTranslationReplacement(id: region.id, text: "", segments: [
            ImageTranslationReplacementSegment(tokenStart: 0, tokenEnd: 3, text: "具有良好的理论性质，当")
        ])
        for partial in [
            ImageTranslationReplacementSegment(tokenStart: 0, tokenEnd: 1, text: "良好"),
            ImageTranslationReplacementSegment(tokenStart: 0, tokenEnd: 3, text: "Nice properties if")
        ] {
            let retry = ImageTranslationReplacement(id: region.id, text: "", segments: [
                partial, ImageTranslationReplacementSegment(tokenStart: 4, tokenEnd: 5, text: "且")
            ])
            let result = MarrController.combiningSelectiveTranslation(original: original, retry: retry, region: region)
            XCTAssertEqual(result.segments.map(\.text), ["具有良好的理论性质，当", "且"])
            XCTAssertTrue(ImageTranslationMerger.missingSelectiveProseIndexes(replacement: result, region: region).isEmpty)
        }
    }

    func testSelectiveHighlightsRejectOutOfBoundsAndFormulaCrossingRanges() {
        let region = inlineMathRegion()
        let response = ImageTranslationReplacement(id: region.id, text: "", segments: [
            ImageTranslationReplacementSegment(tokenStart: 20, tokenEnd: 21, text: "越界"),
            ImageTranslationReplacementSegment(tokenStart: -1, tokenEnd: 2, text: "负数范围"),
            ImageTranslationReplacementSegment(tokenStart: 3, tokenEnd: 6, text: "跨公式"),
            ImageTranslationReplacementSegment(tokenStart: 0, tokenEnd: 3, text: "具有良好的理论性质，当")
        ])
        let pairs = ImageTranslationHighlightBuilder.pairs(regions: [region], replacements: [response])
        XCTAssertEqual(pairs.count, 1)
    }

    func testTranslationThreadDisablesDiscoveredSkillsWithoutPersistentWrites() throws {
        let overrides = CodexConversationClient.translationSkillOverrides(from: [
            "data": [["skills": [
                ["path": "/skills/reader/SKILL.md", "enabled": true],
                ["path": "/skills/writer/SKILL.md", "enabled": false],
                ["path": "/skills/reader/SKILL.md", "enabled": true],
                ["path": "invalid-relative-path", "enabled": true]
            ]]]
        ])
        let skills = try XCTUnwrap(overrides["skills.config"] as? [[String: Any]])
        XCTAssertEqual(skills.compactMap { $0["path"] as? String }, ["/skills/reader/SKILL.md", "/skills/writer/SKILL.md"])
        XCTAssertTrue(skills.allSatisfy { $0["enabled"] as? Bool == false })
        XCTAssertEqual(Set(overrides.keys), ["skills.config"])
    }

    func testTranslationThreadCanUseOlderRuntimeWithoutSkillsListing() {
        XCTAssertEqual(CodexConversationClient.translationSkillOverrides(from: nil)["skills.max_context_tokens"] as? Int, 1)
        let empty = CodexConversationClient.translationSkillOverrides(from: ["data": [["skills": []]]])
        XCTAssertEqual((empty["skills.config"] as? [[String: Any]])?.count, 0)
    }

    func testTranslationMergeKeepsExistingListMarkerMetadata() throws {
        let region = ImageTranslationSourceRegion(
            id: "r001", sourceText: "Array processing (NumPy)",
            x: 0.1, y: 0.2, width: 0.6, height: 0.04,
            lineRects: [ImageTranslationLineRect(x: 0.1, y: 0.2, width: 0.6, height: 0.04)],
            preservesListMarker: true,
            kind: "list_item"
        )
        let block = try XCTUnwrap(ImageTranslationMerger.merge(
            replacements: [ImageTranslationReplacement(id: "r001", text: "数组处理（NumPy）")],
            regions: [region]
        ).first)
        XCTAssertTrue(block.preservesListMarker)
        XCTAssertEqual(block.lineRects, region.lineRects)
        XCTAssertEqual(block.kind, "list_item")
    }

    func testSelectiveTranslationKeepsListMetadataAndPhysicalHorizontalSpacing() throws {
        var baseline: ImageTranslationBlock?
        // The same 1,000 px-wide label in tall, square and shallow captures.
        // Cropping the canvas height must not move its text or protected badge.
        for aspectRatio in [0.5, 1.0, 8.0, 12.0] {
            let tokenHeight = 0.03 * aspectRatio
            let region = ImageTranslationSourceRegion(
                id: "label", sourceText: "• OpenLens | Settings 42",
                x: 0.07, y: 0.2, width: 0.4, height: tokenHeight,
                imageAspectRatio: aspectRatio,
                preservesListMarker: true,
                tokens: [
                    ImageTranslationSourceToken(text: "•", x: 0.07, y: 0.2, width: 0.008, height: 0.008 * aspectRatio, isProtected: true),
                    ImageTranslationSourceToken(text: "OpenLens", x: 0.1, y: 0.2, width: 0.12, height: tokenHeight, isProtected: true),
                    ImageTranslationSourceToken(text: "|", x: 0.235, y: 0.2, width: 0.015, height: tokenHeight, isProtected: true),
                    ImageTranslationSourceToken(text: "Settings", x: 0.25, y: 0.2, width: 0.1, height: tokenHeight),
                    ImageTranslationSourceToken(text: "42", x: 0.365, y: 0.2, width: 0.03, height: tokenHeight, isProtected: true)
                ],
                translationStrategy: .selective, kind: "list_item"
            )
            let block = try XCTUnwrap(ImageTranslationMerger.merge(
                replacements: [ImageTranslationReplacement(
                    id: "label", text: "",
                    segments: [ImageTranslationReplacementSegment(tokenStart: 3, tokenEnd: 4, text: "设置")]
                )],
                regions: [region]
            ).first)
            XCTAssertEqual(block.sourceID, region.id)
            XCTAssertTrue(block.preservesListMarker)
            XCTAssertEqual(block.kind, "list_item")
            XCTAssertEqual(block.trailingAttachments.count, 1)
            if let baseline {
                let expected = baseline.lineRects + baseline.textRects + baseline.protectedRects + baseline.trailingAttachments
                let actual = block.lineRects + block.textRects + block.protectedRects + block.trailingAttachments
                XCTAssertEqual(actual.count, expected.count)
                for (lhs, rhs) in zip(actual, expected) {
                    XCTAssertEqual(lhs.x, rhs.x, accuracy: 0.000_001)
                    XCTAssertEqual(lhs.width, rhs.width, accuracy: 0.000_001)
                }
            } else {
                baseline = block
            }
        }
    }

    func testFastTranslationKeepsSelectiveProtectionAndReducesInitialPayload() throws {
        let words = "The application translates a screenshot while preserving every code identifier and all useful context".components(separatedBy: " ")
        let tokens = words.enumerated().map { index, word in
            ImageTranslationSourceToken(text: word, x: Double(index) * 0.02, y: 0.1, width: 0.02, height: 0.03)
        }
        let paragraph = ImageTranslationSourceRegion(
            id: "r001", sourceText: words.joined(separator: " "),
            x: 0.1, y: 0.1, width: 0.8, height: 0.1, tokens: tokens
        )
        let selective = ImageTranslationSourceRegion(
            id: "r002", sourceText: "OpenLens Settings", x: 0.1, y: 0.3, width: 0.3, height: 0.04,
            tokens: [
                ImageTranslationSourceToken(text: "OpenLens", x: 0.1, y: 0.3, width: 0.1, height: 0.04, isProtected: true),
                ImageTranslationSourceToken(text: "Settings", x: 0.2, y: 0.3, width: 0.1, height: 0.04)
            ], translationStrategy: .selective
        )
        let regions = [paragraph, selective]
        let fast = ImageTranslationPrompt.fastRequest(regions: regions)
        let previous = ImageTranslationPrompt.request(regions: regions)
        let fastText = try XCTUnwrap(text(in: fast.messages[0]))
        let previousText = try XCTUnwrap(text(in: previous.messages[0]))
        let data = try XCTUnwrap(fastText.data(using: .utf8))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payload = try XCTUnwrap(json["regions"] as? [[String: Any]])
        XCTAssertNil(payload[0]["tokens"])
        XCTAssertEqual(payload[0]["text"] as? String, paragraph.sourceText)
        let selectiveTokens = try XCTUnwrap(payload[1]["tokens"] as? [[String: Any]])
        XCTAssertEqual(selectiveTokens[0]["preserve"] as? Bool, true)
        XCTAssertEqual(selectiveTokens[1]["index"] as? Int, 1)
        let slots = try XCTUnwrap(payload[1]["translationSlots"] as? [[String: Any]])
        XCTAssertEqual(slots.count, 1)
        XCTAssertEqual(slots[0]["tokenStart"] as? Int, 1)
        XCTAssertEqual(slots[0]["tokenEnd"] as? Int, 2)
        XCTAssertTrue(fast.messages[0].content.allSatisfy { if case .text = $0 { return true }; return false })
        XCTAssertTrue(fast.systemPrompt.contains("Do not return alignments"))
        XCTAssertLessThan(fastText.utf8.count, previousText.utf8.count)
        XCTAssertLessThan(fast.systemPrompt.utf8.count, previous.systemPrompt.utf8.count)
        // The existing parser/renderer accepts the smaller response without alignments.
        let replacements = ImageTranslationResponseParser.parseReplacements(#"{"translations":[{"id":"r001","targetMarkdown":"应用翻译截图。"},{"id":"r002","segments":[{"tokenStart":1,"tokenEnd":2,"targetMarkdown":"设置"}]}]}"#)
        XCTAssertEqual(replacements.count, 2)
        XCTAssertEqual(replacements[1].segments.first?.tokenStart, 1)
        XCTAssertFalse(ImageTranslationMerger.merge(replacements: replacements, regions: regions).isEmpty)
    }

    func testFastTranslationSlotsNeverCrossPreservedFormulaTokens() throws {
        let words = ["Thus", "the", "⟦math_1⟧", "gradient", "of", "⟦math_2⟧", "is"]
        let region = ImageTranslationSourceRegion(
            id: "formula", sourceText: words.joined(separator: " "),
            x: 0.1, y: 0.1, width: 0.8, height: 0.08,
            tokens: words.enumerated().map { index, word in
                ImageTranslationSourceToken(text: word, x: Double(index) * 0.1, y: 0.1,
                    width: 0.08, height: 0.08, isProtected: [2, 5].contains(index))
            }, translationStrategy: .selective
        )
        let request = ImageTranslationPrompt.fastRequest(regions: [region])
        let payload = try XCTUnwrap(text(in: request.messages[0])?.data(using: .utf8))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let rows = try XCTUnwrap(json["regions"] as? [[String: Any]])
        let slots = try XCTUnwrap(rows[0]["translationSlots"] as? [[String: Any]])
        XCTAssertEqual(slots.compactMap { $0["tokenStart"] as? Int }, [0, 3, 6])
        XCTAssertEqual(slots.compactMap { $0["tokenEnd"] as? Int }, [2, 5, 7])
        XCTAssertEqual(slots.compactMap { $0["source"] as? String }, ["Thus the", "gradient of", "is"])
        XCTAssertTrue(request.systemPrompt.contains("copying tokenStart and tokenEnd exactly"))
    }

    func testFastTranslationSlotsRespectWrappedMathematicalProseValidation() {
        let region = ImageTranslationSourceRegion(
            id: "wrapped", sourceText: "Given ⟦math_1⟧ we can show that",
            x: 0.1, y: 0.1, width: 0.8, height: 0.2,
            tokens: [
                ImageTranslationSourceToken(text: "Given", x: 0.1, y: 0.1, width: 0.1, height: 0.04),
                ImageTranslationSourceToken(text: "⟦math_1⟧", x: 0.22, y: 0.1, width: 0.2, height: 0.04, isProtected: true, isMathematical: true),
                ImageTranslationSourceToken(text: "we", x: 0.44, y: 0.1, width: 0.08, height: 0.04),
                ImageTranslationSourceToken(text: "can", x: 0.54, y: 0.1, width: 0.08, height: 0.04),
                ImageTranslationSourceToken(text: "show", x: 0.1, y: 0.2, width: 0.1, height: 0.04),
                ImageTranslationSourceToken(text: "that", x: 0.22, y: 0.2, width: 0.08, height: 0.04)
            ], translationStrategy: .selective
        )
        let ranges = ImageTranslationMerger.selectiveProseRanges(in: region)
        XCTAssertEqual(ranges, [0..<1, 2..<4, 4..<6])
        let replacement = ImageTranslationReplacement(id: region.id, text: "", segments: ranges.map {
            ImageTranslationReplacementSegment(tokenStart: $0.lowerBound, tokenEnd: $0.upperBound, text: "译文")
        })
        XCTAssertEqual(ImageTranslationMerger.validSelectiveSegments(replacement: replacement, region: region).count, 3)
        XCTAssertTrue(ImageTranslationMerger.missingSelectiveProseIndexes(replacement: replacement, region: region).isEmpty)
        let crossingLines = ImageTranslationReplacement(id: region.id, text: "", segments: [
            ImageTranslationReplacementSegment(tokenStart: 0, tokenEnd: 1, text: "给定"),
            ImageTranslationReplacementSegment(tokenStart: 2, tokenEnd: 6, text: "我们可以证明")
        ])
        XCTAssertEqual(ImageTranslationMerger.validSelectiveSegments(replacement: crossingLines, region: region).count, 1)
        XCTAssertEqual(ImageTranslationMerger.missingSelectiveProseIndexes(replacement: crossingLines, region: region), Set(2..<6))
    }

    func testParallelAlignmentDoesNotOverwriteCompletedTranslations() {
        let original = ImageTranslationReplacement(id: "r1", text: "原译文")
        let repaired = ImageTranslationReplacement(
            id: "r1", text: "原译文",
            alignments: [ImageTranslationAlignment(tokenStart: 0, tokenEnd: 2, targetText: "原译文")]
        )
        let completed = ImageTranslationReplacement(id: "r1", text: "补全译文")
        let added = ImageTranslationReplacement(id: "r2", text: "新增译文")
        XCTAssertEqual(MarrController.reusingTranslationAlignments(
            original: [original], aligned: [repaired], completed: [original, added]
        ), [repaired, added])
        XCTAssertEqual(MarrController.reusingTranslationAlignments(
            original: [original], aligned: [repaired], completed: [completed, added]
        ), [completed, added])
    }

    func testDeepLXSelectiveRangesKeepProtectedTokensAndPunctuationBoundaries() {
        let words: [(String, Bool)] = [
            ("Alice", true), ("writes", false), ("well", false),
            ("API", true), ("!", false), ("42", true), ("Learn", false)
        ]
        let region = ImageTranslationSourceRegion(
            id: "r001", sourceText: "Alice writes well API ! 42 Learn",
            x: 0, y: 0, width: 1, height: 0.1,
            tokens: words.map { text, protected in
                ImageTranslationSourceToken(
                    text: text, x: 0, y: 0, width: 0.1, height: 0.1,
                    isProtected: protected
                )
            },
            translationStrategy: .selective
        )
        XCTAssertEqual(MarrController.deepLXSelectiveRanges(for: region), [1..<3, 6..<7])
    }

    func testCodexModelsUseServerIdentifiersAndKeepFullCatalog() {
        let models = CodexModelOption.parse([
            ["id": "display-id", "model": "actual-model", "displayName": "Model A"],
            ["id": "legacy-model", "hidden": true],
            ["model": "actual-model", "displayName": "Duplicate"],
            ["id": "", "displayName": "Invalid"],
            ["id": "new-model", "displayName": "  "]
        ])
        XCTAssertEqual(models.map(\.id), ["actual-model", "legacy-model", "new-model"])
        XCTAssertEqual(models.map(\.name), ["Model A", "legacy-model", "new-model"])
    }

    func testProjectHistoryRefreshUpdatesExistingTaskWithoutDuplicatesOrSelectionChanges() {
        let suite = "MarrTests.Refresh.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkbenchStore(defaults: defaults)
        let workspace = store.upsertWorkspace(url: URL(fileURLWithPath: "/tmp/project"), bookmark: Data())
        let date = Date()
        let first = store.upsertRemoteTask(
            workspaceID: workspace.id, threadID: "remote", title: "Before", state: .running,
            statusMessage: "Running", createdAt: date, updatedAt: date
        )
        let selected = store.selectedTaskID
        let refreshed = store.upsertRemoteTask(
            workspaceID: workspace.id, threadID: "remote", title: "After", state: .completed,
            statusMessage: "Done", createdAt: date, updatedAt: date.addingTimeInterval(1)
        )
        XCTAssertEqual(first.id, refreshed.id)
        XCTAssertEqual(store.tasks.count, 1)
        XCTAssertEqual(store.tasks.first?.title, "After")
        XCTAssertEqual(store.tasks.first?.state, .completed)
        XCTAssertEqual(store.selectedTaskID, selected)
    }

    func testAutomaticCodexRuntimePrefersDesktopAndHonorsExplicitOverride() {
        let automatic = CodexRuntime.executableURLs(preferred: nil).map(\.path)
        XCTAssertLessThan(automatic.firstIndex(of: "/Applications/ChatGPT.app/Contents/Resources/codex")!,
                          automatic.firstIndex(of: "/opt/homebrew/bin/codex")!)
        let explicit = URL(fileURLWithPath: "/opt/homebrew/bin/codex")
        let paths = CodexRuntime.executableURLs(preferred: explicit).map(\.path)
        XCTAssertEqual(paths.first, explicit.path)
        XCTAssertEqual(paths.filter { $0 == explicit.path }.count, 1)
    }

    func testCodexReasoningOptionsComeFromSelectedModelCatalog() {
        let models = CodexModelOption.parse([
            ["model": "desktop-model", "displayName": "Desktop Model",
             "supportedReasoningEfforts": [["reasoningEffort": "low"], ["reasoningEffort": "xhigh"]],
             "defaultReasoningEffort": "xhigh"]
        ])
        XCTAssertEqual(models.first?.reasoningEfforts, ["low", "xhigh"])
        XCTAssertEqual(models.first?.defaultReasoningEffort, "xhigh")
    }

    func testCachedCodexHistoryRetainsTurnGroupingAndTiming() {
        let suite = "MarrTests.TurnMetadata.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkbenchStore(defaults: defaults)
        let workspace = store.upsertWorkspace(url: URL(fileURLWithPath: "/tmp/project"), bookmark: Data())
        let task = store.createTask(workspaceID: workspace.id, prompt: "Hello")
        store.updateTask(id: task.id, activities: [WorkActivity(
            kind: .message, title: "Codex", detail: "Done", processingSeconds: 12, turnID: "turn-1"
        )])
        let restored = WorkbenchStore(defaults: defaults)
        XCTAssertEqual(restored.tasks.first?.activities.first?.turnID, "turn-1")
        XCTAssertEqual(restored.tasks.first?.activities.first?.processingSeconds, 12)
    }

    func testProjectCatalogImportPreservesSelectionAndBookmarks() {
        let suite = "MarrTests.Catalog.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkbenchStore(defaults: defaults)
        let original = store.upsertWorkspace(url: URL(fileURLWithPath: "/tmp/local"), bookmark: Data([1, 2]))
        let projects: [[String: Any]] = [
            ["name": "Renamed", "roots": [["path": "/tmp/local"]]],
            ["name": "Remote", "roots": [["path": "/tmp/remote"]]],
            ["name": "Invalid", "roots": [["path": "relative"]]]
        ]
        store.importProjects(projects)
        store.importProjects(projects)
        XCTAssertEqual(store.workspaces.count, 2)
        XCTAssertEqual(store.selectedWorkspaceID, original.id)
        XCTAssertEqual(store.selectedWorkspace?.bookmark, Data([1, 2]))
        XCTAssertEqual(store.selectedWorkspace?.name, "Renamed")
    }

    func testCodexRuntimeDiscoversCurrentDesktopBundleLayout() {
        XCTAssertTrue(CodexRuntime.automaticPaths.contains("/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"))
        let preferred = URL(fileURLWithPath: "/tmp/custom-codex")
        XCTAssertEqual(CodexRuntime.executableURLs(preferred: preferred).first, preferred)
    }

    func testCodexConversationIncludesHistoryAndImageInputs() throws {
        let image = ConversationImageAsset(image: makeImage(name: "capture.png", byte: 1))
        let request = VisionRequest(systemPrompt: "Explain screenshots", messages: [
            VisionMessage(role: .user, content: [.text("First question"), .image(image)]),
            VisionMessage(role: .assistant, content: [.text("First answer")]),
            VisionMessage(role: .user, content: [.text("Follow up")])
        ])
        let input = try CodexConversationClient.input(for: request)
        XCTAssertEqual(input.filter { $0["type"] as? String == "image" }.count, 1)
        XCTAssertTrue(input.contains { $0["text"] as? String == "First answer" })
        XCTAssertEqual(input.last?["text"] as? String, "Follow up")
    }

    func testLiveCodexConversationThroughDesktopLogin() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--live-codex-conversation") else {
            throw XCTSkip("Opt-in live inference check")
        }
        let controller = MarrController(client: InferenceClient(), usesCodexForConversation: true)
        let workspace = controller.codexWorkspace
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<4 { for y in 0..<4 { bitmap.setColor(.red, atX: x, y: y) } }
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let image = ConversationImageAsset(data: png, mimeType: "image/png", fileName: "smoke.png")
        let request = VisionRequest(systemPrompt: "Answer concisely.", messages: [
            VisionMessage(role: .user, content: [.text("Reply with exactly MARR_OK."), .image(image)])
        ])
        let response = try await controller.submit(request: request)
        XCTAssertTrue(response.contains("MARR_OK"), response)
        print("LIVE_CONVERSATION_OK")
        print("LIVE_CONVERSATION_MODELS=\(workspace.availableModels.map(\.id))")
    }

    func testLiveCodexSyncThroughSandboxedAppHelper() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--live-codex-sync") else {
            throw XCTSkip("Opt-in local app-server integration check")
        }
        let controller = RuntimeWorkspaceController(codexSyncEnabled: true)
        controller.useDesktopRuntime()
        for _ in 0..<100 {
            if !controller.isLoadingModels { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertNil(controller.modelLoadError, controller.statusMessage)
        XCTAssertFalse(controller.availableModels.isEmpty, controller.statusMessage)
        guard !controller.availableModels.isEmpty else { return }
        controller.loadAllTaskHistory()
        for _ in 0..<200 {
            if !controller.isLoadingProjects && !controller.isLoadingTaskHistory { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertFalse(controller.isLoadingProjects, controller.statusMessage)
        XCTAssertFalse(controller.isLoadingTaskHistory, controller.statusMessage)
        XCTAssertNotNil(controller.lastProjectSyncAt, controller.statusMessage)
        let repositoryPath = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        XCTAssertTrue(controller.savedWorkspaces.contains { $0.path == repositoryPath })
        XCTAssertTrue(controller.savedTasks.contains { task in
            controller.savedWorkspaces.contains { $0.id == task.workspaceID && $0.path == repositoryPath }
        })
        print("LIVE_SYNC_MODELS=\(controller.availableModels.map(\.id))")
        print("LIVE_SYNC_PROJECTS=\(controller.savedWorkspaces.count)")
    }

    func testHotKeyActivationGateIgnoresRepeatedPressUntilRelease() {
        var gate = HotKeyActivationGate()

        XCTAssertTrue(gate.shouldActivate(identifier: 1))
        XCTAssertFalse(gate.shouldActivate(identifier: 1))

        gate.release(identifier: 1)

        XCTAssertTrue(gate.shouldActivate(identifier: 1))
    }

    func testScreenshotPreviewLayoutAvoidsSelectionAndPrompt() throws {
        let bounds = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        let selection = CGRect(x: 300, y: 200, width: 600, height: 400)
        let prompt = CGRect(x: 350, y: 620, width: 500, height: 54)

        let layout = try XCTUnwrap(ScreenshotPreviewLayout.resolve(
            bounds: bounds,
            selection: selection,
            prompt: prompt,
            imageAspectRatio: 16.0 / 9.0
        ))

        XCTAssertTrue(bounds.contains(layout.frame))
        XCTAssertFalse(layout.frame.intersects(selection))
        XCTAssertFalse(layout.frame.intersects(prompt))
    }

    func testAnswerPanelEscapeClosesNestedStateBeforePanel() {
        XCTAssertEqual(
            AnswerPanelEscapeAction.resolve(
                showsSettings: true,
                showsHistory: true,
                isEditing: true
            ),
            .closeSettings
        )
        XCTAssertEqual(
            AnswerPanelEscapeAction.resolve(
                showsSettings: false,
                showsHistory: true,
                isEditing: true
            ),
            .closeHistory
        )
        XCTAssertEqual(
            AnswerPanelEscapeAction.resolve(
                showsSettings: false,
                showsHistory: false,
                isEditing: true
            ),
            .cancelEditing
        )
        XCTAssertEqual(
            AnswerPanelEscapeAction.resolve(
                showsSettings: false,
                showsHistory: false,
                isEditing: false
            ),
            .closePanel
        )
    }

    func testSlashCommandMenuFiltersAndStopsAfterArgumentsBegin() {
        XCTAssertEqual(ConversationSlashCommand.matching("/").count, 5)
        XCTAssertEqual(ConversationSlashCommand.matching("/tr"), [.translate])
        XCTAssertTrue(ConversationSlashCommand.matching("/translate ").isEmpty)
        XCTAssertTrue(ConversationSlashCommand.matching("explain").isEmpty)
    }

    func testSlashCommandsExpandBeforeBeingSentToTheModel() {
        let expanded = ConversationSlashCommand.expandedPrompt(
            for: "/translate to Japanese"
        )

        XCTAssertTrue(expanded.contains("Translate the latest screenshot"))
        XCTAssertTrue(expanded.contains("Additional instruction: to Japanese"))
        XCTAssertEqual(
            ConversationSlashCommand.expandedPrompt(for: "/unknown keep this"),
            "/unknown keep this"
        )
    }

    func testConversationTitlePromptCleansModelOutput() {
        XCTAssertEqual(
            ConversationTitlePrompt.clean("标题：Homebrew 包发布准备。\n额外解释"),
            "Homebrew 包发布准备"
        )
        XCTAssertEqual(
            ConversationTitlePrompt.clean("**Settings comparison result**"),
            "Settings comparison result"
        )
    }

    func testConversationTitlePromptSummarizesQuestionAndAnswerWithoutImages() throws {
        let request = ConversationTitlePrompt.request(
            question: "What changed in these settings?",
            answer: "The proxy mode was changed from automatic to manual."
        )

        XCTAssertTrue(request.systemPrompt.contains("summarizes the conversation"))
        XCTAssertEqual(request.messages.count, 1)
        XCTAssertEqual(imageCount(in: request.messages[0]), 0)
        XCTAssertTrue(try XCTUnwrap(text(in: request.messages[0])).contains("proxy mode"))
    }



    func testScreenCapturePreviewTracksLatestSelectionSize() throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 200,
            height: 100,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try XCTUnwrap(context.makeImage())
        let snapshot = ScreenCaptureSnapshot(
            image: image,
            screenFrame: CGRect(x: 0, y: 0, width: 100, height: 50)
        )

        let initialPreview = try XCTUnwrap(ScreenCapture.preview(
            rect: CGRect(x: 10, y: 10, width: 30, height: 15),
            snapshot: snapshot
        ))
        XCTAssertEqual(initialPreview.size, NSSize(width: 60, height: 30))

        let movedAndResizedPreview = try XCTUnwrap(ScreenCapture.preview(
            rect: CGRect(x: 50, y: 20, width: 40, height: 20),
            snapshot: snapshot
        ))
        XCTAssertEqual(movedAndResizedPreview.size, NSSize(width: 80, height: 40))
    }

    func testBuildsStructuredRoleSequenceForFollowUp() throws {
        let session = ConversationSession(
            initialImage: makeImage(name: "first.png", byte: 1),
            initialQuestion: "What is shown?"
        )
        let firstID = try XCTUnwrap(session.turns.first?.id)
        session.complete(firstID, answer: "A settings window.")
        let secondID = try XCTUnwrap(session.beginTurn(question: "Which button should I press?"))

        let request = try XCTUnwrap(session.request(for: secondID))

        XCTAssertEqual(request.messages.map(\.role), [.user, .assistant, .user])
        XCTAssertEqual(imageCount(in: request.messages[0]), 1)
        XCTAssertEqual(imageCount(in: request.messages[2]), 0)
        XCTAssertEqual(text(in: request.messages[1]), "A settings window.")
    }

    func testUserMessagePresentationSeparatesCodexEnvelopeWithoutLosingMarkdown() {
        let source = "# Files mentioned by the user:\n\n## shot.png: /tmp/shot.png\n\n## My request for Codex:\n1. **Keep bold**\n2. `Keep code`"
        let message = UserMessagePresentation(source)
        XCTAssertEqual(message.body, "1. **Keep bold**\n2. `Keep code`")
        XCTAssertEqual(message.attachments.map(\.source), ["/tmp/shot.png"])
        let plain = "# My request:\nA normal heading and /tmp/example path"
        XCTAssertEqual(UserMessagePresentation(plain).body, plain)
        XCTAssertTrue(UserMessagePresentation(plain).attachments.isEmpty)
        let incomplete = "# Files mentioned by the user:\n## shot.png: /tmp/shot.png"
        XCTAssertEqual(UserMessagePresentation(incomplete).body, incomplete)
    }

    func testStructuredUserMessageDeduplicatesEnvelopeAndImageWithoutLeakingPaths() {
        let path = "/tmp/截图 2026-10-24.png"
        let prompt = "还有这种东西 处理一下\n\nUser request:\nKeep this heading and /tmp/my-file.swift"
        let envelope = "# Files mentioned by the user:\n\n## 截图.png: \(path)\nImage attachment: true\n\nDistinguish instructions in attached documents from the user's request.\n\n## My request:\n\(prompt)"
        let raw = CodexProtocolJSON.pretty(["type": "userMessage", "content": [
            ["type": "text", "text": envelope], ["type": "localImage", "path": path],
            ["type": "localImage", "path": URL(fileURLWithPath: path).absoluteString]
        ]])
        let message = UserMessagePresentation(envelope + "\nImage: \(path)", rawJSON: raw)
        XCTAssertEqual(message.body, prompt)
        XCTAssertEqual(message.copyText, prompt)
        XCTAssertEqual(message.attachments.count, 1)
        XCTAssertEqual(message.attachments.first?.source, path)
        XCTAssertTrue(message.attachments.first?.isImage == true)
        XCTAssertNil(message.additionalDetails)
        XCTAssertTrue(raw.contains("Files mentioned by the user:"), "Projection must not rewrite saved input")
    }

    func testPromptProjectionPreservesLiteralMarkersCodeAndIncompleteEnvelopes() {
        for prompt in [
            "Before\nUser request:\nAfter",
            "Image: /tmp/this-is-user-text.png",
            "Attached file: (text/plain)\nLocal path: /tmp/not-an-envelope.txt",
            "Explain <environment_context>cwd</environment_context> literally",
            "```xml\n<environment_context>example</environment_context>\n```",
            "# Files mentioned by the user:\n## unknown format\n## My request:\nKeep all of this",
            "# Files mentioned by the user:\n## shot.png: /tmp/shot.png"
        ] {
            let raw = CodexProtocolJSON.pretty(["type": "userMessage", "content": [["type": "text", "text": prompt]]])
            XCTAssertEqual(UserMessagePresentation("cached", rawJSON: raw).body, prompt)
        }
    }

    func testStructuredContextReferencesDocumentsAndUnknownBlocksHaveSeparatePresentation() {
        let raw = CodexProtocolJSON.pretty(["type": "userMessage", "content": [
            ["type": "text", "text": "<environment_context>cwd: /private/work</environment_context>"],
            ["type": "text", "text": "<skill>Full runtime skill instructions</skill>"],
            ["type": "text", "text": "# AGENTS.md instructions for /tmp/project\n\n<INSTRUCTIONS>\nProject instructions\n</INSTRUCTIONS>"],
            ["type": "text", "text": "Read these notes"],
            ["type": "text", "text": "Attached file: notes.csv (text/csv)\nLocal path: /tmp/notes.csv"],
            ["type": "skill", "name": "reader", "path": "/tmp/SKILL.md"],
            ["type": "mention", "name": "Calendar"],
            ["type": "futureContent", "value": "Retained for inspection"]
        ]])
        let message = UserMessagePresentation("stale flattened payload", rawJSON: raw)
        XCTAssertEqual(message.body, "Read these notes")
        XCTAssertEqual(message.attachments.first?.label, "notes.csv")
        XCTAssertEqual(message.references, ["$reader", "@Calendar"])
        XCTAssertTrue(message.additionalDetails?.contains("Retained for inspection") == true)
        XCTAssertFalse(message.copyText.contains("private"))
        XCTAssertFalse(message.copyText.contains("futureContent"))
    }

    func testAttachmentOnlyMessagesRemainInTimelineAndRuntimeContextDoesNotCreateTurns() throws {
        let context = WorkActivity(kind: .user, title: "You", detail: "context", rawJSON: CodexProtocolJSON.pretty([
            "type": "userMessage", "content": [["type": "text", "text": "<environment_context>cwd</environment_context>"]]
        ]))
        let image = WorkActivity(kind: .user, title: "You", detail: "", rawJSON: CodexProtocolJSON.pretty([
            "type": "userMessage", "content": [["type": "localImage", "path": "/tmp/image.png"]]
        ]))
        let answer = WorkActivity(kind: .message, title: "Codex", detail: "An image")
        let cache = MarrWorkTimelineCache()
        let groups = cache.groups(activities: [context, image, answer], revision: 1)
        XCTAssertEqual(groups.count, 1)
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(group.userMessage.id, image.id)
        XCTAssertEqual(group.userPresentation.attachments.count, 1)
        XCTAssertEqual(group.finalMessage?.detail, "An image")
        XCTAssertFalse(UserMessagePresentation(context.detail, rawJSON: context.rawJSON).isVisible)
        let emptyPromptEnvelope = "# Files mentioned by the user:\n## image.png: /tmp/image.png\n## My request:\n"
        XCTAssertTrue(UserMessagePresentation(emptyPromptEnvelope).isVisible)
        XCTAssertTrue(UserMessagePresentation(emptyPromptEnvelope).body.isEmpty)
    }

    func testBrowserAmbientContextKeepsTheFollowingUserRequest() {
        let context = "<in-app-browser-context source=\"ambient-ui-state\">\nBrowser state\n</in-app-browser-context>"
        func present(_ text: String) -> UserMessagePresentation {
            UserMessagePresentation("cached", rawJSON: CodexProtocolJSON.pretty([
                "type": "userMessage", "content": [["type": "text", "text": text]]
            ]))
        }
        XCTAssertFalse(present(context).isVisible)
        let request = "这样的ui并不好看\n\n**保留格式**\n<custom>user content</custom>"
        XCTAssertEqual(present(context + "\n\n## My request:\n" + request).body, request)
        XCTAssertEqual(present(context + "\n\n## My request for Codex:\n" + request).copyText, request)
        for literal in ["Explain " + context, "```xml\n" + context + "\n```",
                        context + "\nMy own notes", "<in-app-browser-context>incomplete",
                        "<in-app-browser-contextual>keep</in-app-browser-contextual>"] {
            XCTAssertEqual(present(literal).body, literal)
        }
        XCTAssertEqual(UserMessagePresentation(context).body, context, "Unstructured user text stays verbatim")
    }

    func testQuestionReplyEnvelopeShowsTheAnswerInsteadOfProtocolJSON() {
        let reply = "<send_user_message_question_reply>\n[{\"question\":\"保持窗口宽度？\",\"answer\":\"保持窗口宽度\",\"questionItemId\":\"internal-id\"}]\n</send_user_message_question_reply>"
        let raw = CodexProtocolJSON.pretty(["type": "userMessage", "content": [["type": "text", "text": reply]]])
        XCTAssertEqual(UserMessagePresentation(reply, rawJSON: raw).body, "保持窗口宽度")
        let malformed = "<send_user_message_question_reply>not JSON</send_user_message_question_reply>"
        let malformedRaw = CodexProtocolJSON.pretty(["type": "userMessage", "content": [["type": "text", "text": malformed]]])
        XCTAssertEqual(UserMessagePresentation(malformed, rawJSON: malformedRaw).body, malformed)
    }

    func testHistoryAndLiveProjectionPreserveUserRequestMarkersAndOriginalPayload() throws {
        let prompt = "Keep the beginning\nUser request:\nKeep the end"
        let item: [String: Any] = ["id": "user", "type": "userMessage", "content": [
            ["type": "text", "text": prompt], ["type": "localImage", "path": "/tmp/image.png"]
        ]]
        let history = RuntimeHistoryProjection.prepareHistory(["id": "thread", "turns": [
            ["id": "turn", "status": "completed", "items": [item]]
        ]])
        let activity = try XCTUnwrap(history.activities.first)
        XCTAssertEqual(activity.detail, prompt)
        XCTAssertEqual(UserMessagePresentation(activity.detail, rawJSON: activity.rawJSON).body, prompt)
        XCTAssertTrue(activity.rawJSON?.contains("localImage") == true)
    }

    func testPinnedScreenshotsAreIncludedTogetherInFirstRequest() throws {
        let session = ConversationSession()
        let first = session.appendScreenshot(makeImage(name: "pinned-one.png", byte: 1))
        let second = session.appendScreenshot(makeImage(name: "pinned-two.png", byte: 2))
        let current = session.appendScreenshot(makeImage(name: "current.png", byte: 3))
        let turn = try XCTUnwrap(session.beginTurn(question: "Compare all three screenshots."))
        let request = try XCTUnwrap(session.request(for: turn))
        XCTAssertEqual(session.turns.first?.imageIDs, [first, second, current])
        XCTAssertEqual(imageCount(in: request.messages[0]), 3)
        XCTAssertTrue(session.pendingImageIDs.isEmpty)
    }

    func testNewScreenshotBelongsToNextTurnWithoutReplacingHistory() throws {
        let session = ConversationSession(
            initialImage: makeImage(name: "first.png", byte: 1),
            initialQuestion: "Describe this."
        )
        let firstID = try XCTUnwrap(session.turns.first?.id)
        let firstImageID = try XCTUnwrap(session.turns.first?.imageIDs.first)
        session.complete(firstID, answer: "The first screen.")

        let secondImageID = session.appendScreenshot(makeImage(name: "second.png", byte: 2))
        let secondID = try XCTUnwrap(session.beginTurn(question: "What changed?"))
        let request = try XCTUnwrap(session.request(for: secondID))

        XCTAssertNotEqual(firstImageID, secondImageID)
        XCTAssertNotNil(session.images[firstImageID])
        XCTAssertNotNil(session.images[secondImageID])
        XCTAssertEqual(session.turns[1].imageIDs, [secondImageID])
        XCTAssertEqual(imageCount(in: request.messages[0]), 1)
        XCTAssertEqual(imageCount(in: request.messages[2]), 1)
    }

    func testPickedImageLoadsSupportedFileAttachment() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarrAttachment-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: fileURL)

        let attachment = try PickedImage.attachment(from: fileURL)

        XCTAssertEqual(attachment.data, data)
        XCTAssertEqual(attachment.mimeType, "image/png")
        XCTAssertEqual(attachment.fileName, fileURL.lastPathComponent)
        XCTAssertTrue(attachment.image.isValid)
    }

    func testPickedAttachmentLoadsTextAndDocumentFiles() throws {
        let textURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarrAttachment-\(UUID().uuidString).txt")
        let documentURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarrAttachment-\(UUID().uuidString).docx")
        defer {
            try? FileManager.default.removeItem(at: textURL)
            try? FileManager.default.removeItem(at: documentURL)
        }
        let textData = Data("hello attachment".utf8)
        let documentData = Data([0x50, 0x4B, 0x03, 0x04])
        try textData.write(to: textURL)
        try documentData.write(to: documentURL)

        let textAttachment = try PickedAttachment.attachment(from: textURL)
        let documentAttachment = try PickedAttachment.attachment(from: documentURL)

        XCTAssertEqual(textAttachment.data, textData)
        XCTAssertEqual(textAttachment.mimeType, "text/plain")
        XCTAssertNil(textAttachment.image)
        XCTAssertEqual(
            documentAttachment.mimeType,
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        )
        XCTAssertEqual(documentAttachment.data, documentData)
        XCTAssertNil(documentAttachment.image)
    }

    func testPickedAttachmentRejectsUnsupportedFileAttachment() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarrAttachment-\(UUID().uuidString).dmg")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try Data("not supported".utf8).write(to: fileURL)

        XCTAssertThrowsError(try PickedAttachment.attachment(from: fileURL)) { error in
            guard case PickedImageAttachmentError.unsupportedFormat = error else {
                return XCTFail("Expected an unsupported attachment error, got \(error)")
            }
        }
    }

    func testAttachedFileIsSentWithTheNextTurn() throws {
        let session = ConversationSession(
            initialImage: makeImage(name: "first.png", byte: 1),
            initialQuestion: "Question one"
        )
        let firstTurnID = try XCTUnwrap(session.turns.first?.id)
        session.complete(firstTurnID, answer: "Answer one")

        let attachment = PickedAttachment(
            data: Data("file contents".utf8),
            mimeType: "text/plain",
            fileName: "notes.txt",
            image: nil
        )
        let attachmentID = session.appendAttachment(attachment)
        let nextTurnID = try XCTUnwrap(session.beginTurn(question: "Summarize the file"))
        let request = try XCTUnwrap(session.request(for: nextTurnID))

        XCTAssertEqual(session.turns.last?.imageIDs, [attachmentID])
        XCTAssertEqual(fileCount(in: request.messages.last), 1)
    }

    func testContextPolicyKeepsOnlyMostRecentCompletedTurns() throws {
        let policy = ConversationContextPolicy(
            maximumCompletedTurns: 1,
            maximumTextCharacters: 10_000,
            maximumImages: 2
        )
        let session = ConversationSession(
            initialImage: makeImage(name: "first.png", byte: 1),
            initialQuestion: "Question one",
            contextBuilder: ConversationContextBuilder(policy: policy)
        )
        let firstID = try XCTUnwrap(session.turns.first?.id)
        session.complete(firstID, answer: "Answer one")
        let secondID = try XCTUnwrap(session.beginTurn(question: "Question two"))
        session.complete(secondID, answer: "Answer two")
        let thirdID = try XCTUnwrap(session.beginTurn(question: "Question three"))

        let request = try XCTUnwrap(session.request(for: thirdID))

        XCTAssertEqual(request.messages.map(\.role), [.user, .assistant, .user])
        XCTAssertEqual(text(in: request.messages[0]), "Question two")
        XCTAssertEqual(text(in: request.messages[2]), "Question three")
        XCTAssertEqual(imageCount(in: request.messages[2]), 1)
    }

    func testFailedTurnCanBeRetriedWithSameContext() throws {
        let session = ConversationSession(
            initialImage: makeImage(name: "first.png", byte: 1),
            initialQuestion: "Try this"
        )
        let turnID = try XCTUnwrap(session.turns.first?.id)
        session.fail(turnID, message: "Network error")

        XCTAssertTrue(session.prepareRetry(turnID))
        XCTAssertEqual(session.turns[0].status, .loading)
        XCTAssertNil(session.turns[0].errorMessage)
        XCTAssertNotNil(session.request(for: turnID))
    }

    func testAnswerPanelDeliversWheelEventsToConversationScrollView() throws {
        try MarrUITestSupport.requireVisibleWindows()
        try assertAnswerPanelDeliversWheelEvents(usesGlassSurfaces: true)
    }

    func testAnswerPanelDeliversWheelEventsWhenGlassSurfacesAreDisabled() throws {
        try MarrUITestSupport.requireVisibleWindows()
        try assertAnswerPanelDeliversWheelEvents(usesGlassSurfaces: false)
    }

    func testDisabledGlassSelectsUnfocusedMode() {
        XCTAssertEqual(
            MarrSurfaceMode.resolve(usesLiquidGlass: false, prefersClearGlass: true),
            .unfocused
        )
        XCTAssertEqual(
            MarrSurfaceMode.resolve(usesLiquidGlass: false, prefersClearGlass: false),
            .unfocused
        )
        XCTAssertEqual(
            MarrSurfaceMode.resolve(usesLiquidGlass: true, prefersClearGlass: true),
            .activeClear
        )
        XCTAssertEqual(
            MarrSurfaceMode.resolve(usesLiquidGlass: true, prefersClearGlass: false),
            .activeRegular
        )
    }

    func testAnswerBubbleBottomInsetStaysProportionalToSurfaceRadius() {
        XCTAssertEqual(AnswerPanelConversationLayout.bottomInset, 16)
        XCTAssertEqual(
            AnswerPanelConversationLayout.bottomInset
                / AnswerPanelConversationLayout.surfaceCornerRadius,
            2.0 / 3.0,
            accuracy: 0.001
        )
    }

    func testAnswerPanelUsesReferenceInspiredTallLayoutWithEmbeddedComposer() {
        XCTAssertEqual(AnswerPanelConversationLayout.panelSize.width, 420)
        XCTAssertEqual(AnswerPanelConversationLayout.panelSize.height, 596)
        XCTAssertLessThan(
            AnswerPanelConversationLayout.panelSize.width
                / AnswerPanelConversationLayout.panelSize.height,
            0.75
        )
        XCTAssertEqual(
            AnswerPanelConversationLayout.composerWidth,
            AnswerPanelConversationLayout.surfaceWidth - 64
        )
        XCTAssertEqual(AnswerPanelConversationLayout.composerHeight, 44)
        XCTAssertEqual(
            AnswerPanelConversationLayout.assistantTextWidth,
            AnswerPanelConversationLayout.composerWidth - 8
        )
    }

    func testAnswerPanelAppearsBesideQuestionBarWhenRightSideFits() {
        let frame = AnswerPanelPlacement.initialFrame(
            panelSize: AnswerPanelConversationLayout.panelSize,
            anchorRect: CGRect(x: 300, y: 370, width: 500, height: 46),
            visibleFrame: CGRect(x: 0, y: 24, width: 1440, height: 876)
        )

        XCTAssertEqual(frame.minX, 814)
        XCTAssertEqual(frame.midY, 393)
    }

    func testAnswerPanelChoosesLeftSideNearRightScreenEdge() {
        let anchor = CGRect(x: 900, y: 370, width: 500, height: 46)
        let frame = AnswerPanelPlacement.initialFrame(
            panelSize: AnswerPanelConversationLayout.panelSize,
            anchorRect: anchor,
            visibleFrame: CGRect(x: 0, y: 24, width: 1440, height: 876)
        )

        XCTAssertEqual(frame.maxX, anchor.minX - AnswerPanelPlacement.gap)
        XCTAssertEqual(frame.midY, anchor.midY)
    }

    func testAnswerPanelPlacementStaysInsideVisibleScreen() {
        let visibleFrame = CGRect(x: -1200, y: 24, width: 1200, height: 760)
        let frame = AnswerPanelPlacement.initialFrame(
            panelSize: AnswerPanelConversationLayout.panelSize,
            anchorRect: CGRect(x: -260, y: 40, width: 500, height: 46),
            visibleFrame: visibleFrame
        )

        XCTAssertTrue(
            visibleFrame
                .insetBy(
                    dx: AnswerPanelPlacement.screenMargin,
                    dy: AnswerPanelPlacement.screenMargin
                )
                .contains(frame)
        )
    }

    func testConversationTitleFadesWithoutFullyDisappearingWhileScrolling() {
        XCTAssertEqual(AnswerPanelTitleFade.opacity(forScrollDistance: 0), 1)
        XCTAssertLessThan(AnswerPanelTitleFade.opacity(forScrollDistance: 36), 1)
        XCTAssertEqual(AnswerPanelTitleFade.opacity(forScrollDistance: 1_000), 0.18, accuracy: 0.001)
    }

    func testAnswerPanelHistoryExpandsAlongsideConversationWithoutShowingWindow() throws {
        let historyURL = makeTemporaryHistoryURL()
        let suite = "Marr.SidebarWindow.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let historyResources = MarrHistoryTestResources(rootURL: historyURL)
        addTeardownBlock { try await historyResources.cleanUp() }

        let historyStore = historyResources.makeStore()
        let controller = MarrController(
            client: AnswerPanelTestClient(),
            historyStore: historyStore,
            tokenUsageStore: TokenUsageStore(rootURL: historyURL.appendingPathComponent("Usage")),
            settingsRepository: InferenceSettingsRepository(
                values: TranslationRoutingValues(), secrets: TranslationRoutingSecrets(credentials: nil)),
            codexWorkspace: RuntimeWorkspaceController(defaults: defaults,
                attachmentDirectory: historyURL.appendingPathComponent("WorkAttachments"),
                draftDirectory: historyURL.appendingPathComponent("Drafts"), codexSyncEnabled: true)
        )
        let session = ConversationSession(
            initialImage: makeImage(name: "history-window-test.png", byte: 1),
            initialQuestion: "Explain this in detail"
        )
        let turnID = try XCTUnwrap(session.turns.first?.id)
        session.complete(
            turnID,
            answer: (1...80).map { "Paragraph \($0): enough content to stress hosting-view sizing." }
                .joined(separator: "\n\n")
        )
        session.setGeneratedTitle("History sidebar window")

        let panel = AnswerPanelController(
            controller: controller,
            historyStore: historyStore,
            session: session,
            anchorRect: .zero,
            persistImmediately: false
        )
        let window = panel.windowForTesting
        defer {
            panel.close()
            // Offscreen SwiftUI hosts release their last rendering transaction
            // on a later run-loop pass, before the history database teardown.
            RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        }

        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        let originalMinY = window.frame.minY

        XCTAssertEqual(window.frame.width, MarrPanelShellLayout.windowSize.width, accuracy: 1)
        XCTAssertEqual(window.frame.height, 596, accuracy: 1)
        XCTAssertTrue(window.isMovable)
        XCTAssertFalse(window.isMovableByWindowBackground, "Answer text drags must select text rather than move the window")

        panel.setHistoryExpanded(true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        let visibleWidth = (window.screen ?? NSScreen.main)?.visibleFrame.width ?? 2_000
        let expandedWidth = min(MarrPanelShellLayout.windowSize.width + AnswerPanelSidebarLayout.sidebarWidth, visibleWidth)
        XCTAssertEqual(window.frame.width, expandedWidth, accuracy: 1)
        XCTAssertTrue(panel.sidebarPresentation.layout.isExpanded)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertEqual(window.frame.height, 596, accuracy: 1)
        XCTAssertEqual(window.frame.minY, originalMinY, accuracy: 1)

        panel.setHistoryExpanded(false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        XCTAssertEqual(window.frame.width, expandedWidth, accuracy: 1)
        XCTAssertFalse(panel.sidebarPresentation.layout.isExpanded)
        XCTAssertEqual(window.frame.height, 596, accuracy: 1)
        XCTAssertEqual(window.frame.minY, originalMinY, accuracy: 1)

        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertEqual(window.contentMinSize, MarrPanelShellLayout.windowSize)
        XCTAssertEqual(AnswerPanelConversationLayout.windowPadding, 0)
        XCTAssertEqual(AnswerPanelConversationLayout.surfaceWidth, 420)
        XCTAssertEqual(AnswerPanelConversationLayout.surfaceHeight, 596)
        window.setContentSize(NSSize(width: 680, height: 760))
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertEqual(window.contentView?.bounds.width ?? 0, 680, accuracy: 1)
        XCTAssertEqual(window.contentView?.bounds.height ?? 0, 760, accuracy: 1)
        panel.setHistoryExpanded(true)
        XCTAssertEqual(window.frame.width, expandedWidth, accuracy: 1)
        let visibleHeight = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 760
        XCTAssertEqual(window.frame.height, min(760, visibleHeight), accuracy: 1)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
    }

    private func assertAnswerPanelDeliversWheelEvents(usesGlassSurfaces: Bool) throws {
        try MarrUITestSupport.requireVisibleWindows()
        let defaults = UserDefaults.standard
        let previousPreference = defaults.object(forKey: MarrAppearanceKeys.glassSurfaces)
        defaults.set(usesGlassSurfaces, forKey: MarrAppearanceKeys.glassSurfaces)
        defer {
            if let previousPreference {
                defaults.set(previousPreference, forKey: MarrAppearanceKeys.glassSurfaces)
            } else {
                defaults.removeObject(forKey: MarrAppearanceKeys.glassSurfaces)
            }
        }

        let historyURL = makeTemporaryHistoryURL()
        let historyResources = MarrHistoryTestResources(rootURL: historyURL)
        addTeardownBlock { try await historyResources.cleanUp() }

        let historyStore = historyResources.makeStore()
        let controller = MarrController(
            client: AnswerPanelTestClient(),
            historyStore: historyStore
        )
        let session = ConversationSession(
            initialImage: makeImage(name: "scroll-test.png", byte: 1),
            initialQuestion: "Explain this in detail"
        )
        let turnID = try XCTUnwrap(session.turns.first?.id)
        session.complete(
            turnID,
            answer: (1...80).map { "Paragraph \($0): enough content to require scrolling." }.joined(separator: "\n\n")
        )

        let panel = AnswerPanelController(
            controller: controller,
            historyStore: historyStore,
            session: session,
            anchorRect: .zero,
            persistImmediately: false
        )
        let window = panel.windowForTesting
        window.makeKeyAndOrderFront(nil)
        defer { panel.close() }

        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        window.contentView?.layoutSubtreeIfNeeded()

        let scrollView = try XCTUnwrap(largestScrollableView(in: window.contentView))
        let clipView = scrollView.contentView
        XCTAssertGreaterThan(
            scrollView.documentView?.bounds.height ?? 0,
            clipView.bounds.height + 100,
            "The fixture must overflow the answer region before wheel routing can be tested."
        )

        clipView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(clipView)
        let initialOrigin = clipView.bounds.origin
        let locationInWindow = scrollView.convert(
            NSPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY),
            to: nil
        )

        let hitView = try XCTUnwrap(window.contentView?.hitTest(locationInWindow))
        XCTAssertTrue(
            hitView === scrollView || hitView.isDescendant(of: scrollView),
            "The visible center of the answer surface must hit inside its scroll view."
        )

        sendWheelEvent(deltaY: -80, at: locationInWindow, through: hitView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        if clipView.bounds.origin == initialOrigin {
            sendWheelEvent(deltaY: 80, at: locationInWindow, through: hitView)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        XCTAssertNotEqual(
            clipView.bounds.origin,
            initialOrigin,
            "A wheel event inside the answer surface must move its native scroll view."
        )
    }

    func testHistoryFixtureDrainsQueuedWritesBeforeReleasingAndDeletingDatabase() async throws {
        let rootURL = makeTemporaryHistoryURL()
        let resources = MarrHistoryTestResources(rootURL: rootURL)
        resources.makeStore().save(ConversationArchive(
            id: UUID(), createdAt: Date(), updatedAt: Date(), generatedTitle: "Pending fixture save",
            turns: [], images: [], pendingImageIDs: []))

        try await resources.cleanUp()

        XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL.path))
    }

    func testHistoryStorePersistsTurnsAndImageDataAcrossReload() async throws {
        let rootURL = makeTemporaryHistoryURL()
        let historyResources = MarrHistoryTestResources(rootURL: rootURL)
        addTeardownBlock { try await historyResources.cleanUp() }
        let store = historyResources.makeStore()
        let session = ConversationSession(
            initialImage: makeImage(name: "persisted.png", byte: 42),
            initialQuestion: "Remember this screenshot"
        )
        session.setArchiveHandler { store.save($0) }
        let turnID = try XCTUnwrap(session.turns.first?.id)
        let imageID = try XCTUnwrap(session.turns.first?.imageIDs.first)
        session.complete(turnID, answer: "Stored safely")
        session.setGeneratedTitle("Screenshot persistence")
        await store.waitForPendingOperations()

        let reloaded = historyResources.makeStore()
        await reloaded.waitForPendingOperations()
        let record = try XCTUnwrap(reloaded.conversations.first)

        XCTAssertEqual(record.title, "Screenshot persistence")
        XCTAssertEqual(record.generatedTitle, "Screenshot persistence")
        XCTAssertEqual(record.turns.first?.answer, "Stored safely")
        XCTAssertEqual(record.completedTurnCount, 1)
        XCTAssertEqual(reloaded.imageData(conversationID: record.id, imageID: imageID), Data([42]))
    }

    func testHistoryStorePersistsPendingScreenshotAndDeletesConversation() async throws {
        let rootURL = makeTemporaryHistoryURL()
        let historyResources = MarrHistoryTestResources(rootURL: rootURL)
        addTeardownBlock { try await historyResources.cleanUp() }
        let store = historyResources.makeStore()
        let session = ConversationSession(
            initialImage: makeImage(name: "first.png", byte: 1),
            initialQuestion: "First"
        )
        session.setArchiveHandler { store.save($0) }
        let pendingID = session.appendScreenshot(makeImage(name: "pending.png", byte: 2))
        await store.waitForPendingOperations()

        let record = try XCTUnwrap(store.conversations.first)
        XCTAssertEqual(record.pendingImageIDs, [pendingID])
        XCTAssertEqual(record.images.count, 2)

        store.delete(record.id)
        await store.waitForPendingOperations()
        XCTAssertTrue(store.conversations.isEmpty, store.lastErrorMessage ?? "Unexpected persisted record")
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent(record.id.uuidString).path))
    }

    func testHistoryStoreMigratesLegacyJSONHistoryIntoSQLite() async throws {
        let rootURL = makeTemporaryHistoryURL()
        let historyResources = MarrHistoryTestResources(rootURL: rootURL)
        addTeardownBlock { try await historyResources.cleanUp() }

        let conversationID = UUID()
        let turnID = UUID()
        let imageID = UUID()
        let createdAt = Date()
        let storedFileName = imageID.uuidString + ".png"
        let legacyConversationURL = rootURL
            .appendingPathComponent("History", isDirectory: true)
            .appendingPathComponent(conversationID.uuidString, isDirectory: true)
        let legacyImagesURL = legacyConversationURL.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyImagesURL, withIntermediateDirectories: true)
        try Data([77]).write(to: legacyImagesURL.appendingPathComponent(storedFileName))

        let record = ConversationHistoryRecord(
            id: conversationID,
            createdAt: createdAt,
            updatedAt: createdAt,
            turns: [
                ConversationTurn(
                    id: turnID,
                    question: "Legacy question",
                    imageIDs: [imageID],
                    answer: "Legacy answer",
                    errorMessage: nil,
                    status: .completed,
                    showsAssistant: true
                )
            ],
            images: [
                ConversationImageReference(
                    id: imageID,
                    mimeType: "image/png",
                    fileName: "legacy.png",
                    storedFileName: storedFileName
                )
            ],
            pendingImageIDs: []
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: legacyConversationURL.appendingPathComponent("conversation.json"))

        let store = historyResources.makeStore()
        await store.waitForPendingOperations()
        let migrated = try XCTUnwrap(store.conversations.first)

        XCTAssertEqual(migrated.id, conversationID)
        XCTAssertEqual(migrated.turns.first?.answer, "Legacy answer")
        XCTAssertEqual(store.imageData(conversationID: conversationID, imageID: imageID), Data([77]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("marr.sqlite").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("Attachments").appendingPathComponent(storedFileName).path))
    }

    func testTranslationParserReadsFencedJSONBlocks() throws {
        let response = """
        ```json
        {"translations":[{"text":"Hello","x":0.1,"y":0.2,"width":0.3,"height":0.4}]}
        ```
        """

        let blocks = ImageTranslationResponseParser.parse(response)

        XCTAssertEqual(blocks, [
            ImageTranslationBlock(text: "Hello", x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        ])
    }

    func testTranslationParserFallsBackToFullSelectionText() throws {
        let blocks = ImageTranslationResponseParser.parse("Translated text only")

        XCTAssertEqual(blocks, [
            ImageTranslationBlock(
                text: "Translated text only",
                x: 0.04,
                y: 0.04,
                width: 0.92,
                height: 0.92,
                alignment: "center"
            )
        ])
    }

    func testTranslationParserReadsStyleHints() throws {
        let response = """
        {"translations":[{"text":"Settings","x":0.2,"y":0.3,"width":0.4,"height":0.1,"textColor":"#101010","backgroundColor":"#f9f9f9","alignment":"left","weight":"bold","fontSize":0.05}]}
        """

        let blocks = ImageTranslationResponseParser.parse(response)

        XCTAssertEqual(blocks, [
            ImageTranslationBlock(
                text: "Settings",
                x: 0.2,
                y: 0.3,
                width: 0.4,
                height: 0.1,
                textColor: "#101010",
                backgroundColor: "#f9f9f9",
                alignment: "left",
                weight: "bold",
                fontSize: 0.05
            )
        ])
    }

    func testTranslationPromptRequiresLineLevelStyleAwareBlocks() throws {
        let request = ImageTranslationPrompt.request(for: makeImage(name: "prompt.png", byte: 9))
        let userText = try XCTUnwrap(text(in: request.messages[0]))

        XCTAssertTrue(ImageTranslationPrompt.systemPrompt.contains("line-level items"))
        XCTAssertTrue(ImageTranslationPrompt.systemPrompt.contains("inline code"))
        XCTAssertTrue(ImageTranslationPrompt.systemPrompt.contains("highlighted/code blocks"))
        XCTAssertTrue(ImageTranslationPrompt.systemPrompt.contains("Translate faithfully"))
        XCTAssertTrue(userText.contains("line-level, style-aware blocks"))
        XCTAssertTrue(userText.contains("Preserve inline code identifiers exactly"))
    }

    func testTranslationRegionPromptRequiresTokenRangeReplacements() throws {
        let region = ImageTranslationSourceRegion(
            id: "r001",
            sourceText: "ConversationSession owns turns, immutable screenshot assets",
            x: 0.08,
            y: 0.16,
            width: 0.7,
            height: 0.04,
            lineRects: [
                ImageTranslationLineRect(x: 0.08, y: 0.16, width: 0.7, height: 0.04)
            ],
            textRects: [
                ImageTranslationLineRect(x: 0.08, y: 0.16, width: 0.36, height: 0.04)
            ],
            tokens: [
                ImageTranslationSourceToken(
                    text: "ConversationSession",
                    x: 0.08,
                    y: 0.16,
                    width: 0.2,
                    height: 0.04,
                    isProtected: true
                ),
                ImageTranslationSourceToken(
                    text: "owns",
                    x: 0.29,
                    y: 0.16,
                    width: 0.07,
                    height: 0.04
                )
            ],
            codeRects: [
                ImageTranslationTokenRect(text: "ConversationSession", x: 0.08, y: 0.16, width: 0.2, height: 0.04)
            ]
        )
        let request = ImageTranslationPrompt.request(regions: [region])
        let gatewayText = try XCTUnwrap(text(in: request.messages[0]))

        XCTAssertFalse(request.messages[0].content.contains { content in
            if case .image = content { return true }
            return false
        })
        XCTAssertTrue(request.systemPrompt.contains("targetMarkdown, and alignments"))
        XCTAssertTrue(request.systemPrompt.contains("partition every supplied indexed token exactly once"))
        XCTAssertTrue(request.systemPrompt.contains("never just a matching keyword"))
        XCTAssertTrue(request.systemPrompt.contains("Do not return coordinates"))
        XCTAssertTrue(request.systemPrompt.contains(#""alignments":[{"#))
        XCTAssertFalse(gatewayText.contains(#""bbox""#))
        XCTAssertTrue(gatewayText.contains(#""codeTokens":["ConversationSession"]"#))
        XCTAssertTrue(gatewayText.contains(#""tokens":[{"index":0,"text":"ConversationSession"},{"index":1,"text":"owns"}]"#))

        let visualRequest = ImageTranslationPrompt.request(
            for: makeImage(name: "lines.png", byte: 10),
            regions: [region]
        )
        let userText = try XCTUnwrap(text(in: visualRequest.messages[0]))
        XCTAssertTrue(visualRequest.messages[0].content.contains { content in
            if case .image = content { return true }
            return false
        })

        let requiredSystemFragments = [
            "tokenStart is inclusive",
            "ordered, non-overlapping",
            "targetMarkdown",
            "local Markdown/layout renderer",
            "sticker-like translations",
            "Translate faithfully",
            "preserve=true",
            "publications",
            "owns turns"
        ]
        for fragment in requiredSystemFragments {
            XCTAssertTrue(
                ImageTranslationPrompt.regionSystemPrompt.contains(fragment),
                "Missing system-prompt fragment: \(fragment)"
            )
        }

        let requiredUserFragments = [
            "ordered token-range segments",
            "Never include a token marked preserve=true",
            #""kind":"paragraph""#,
            #""strategy":"block""#,
            #""bbox""#,
            #""lineRects""#,
            #""textRects""#,
            #""tokens""#,
            #""preserve":false"#,
            #""codeRects""#,
            "ConversationSession owns turns, immutable screenshot assets"
        ]
        for fragment in requiredUserFragments {
            XCTAssertTrue(userText.contains(fragment), "Missing user-prompt fragment: \(fragment)")
        }
    }

    func testTranslationParserReadsIDReplacements() throws {
        let response = """
        {"translations":[{"id":"r001","text":"拥有轮次"},{"id":"r002","text":"不可变截图资源"}]}
        """

        let replacements = ImageTranslationResponseParser.parseReplacements(response)

        XCTAssertEqual(replacements, [
            ImageTranslationReplacement(id: "r001", text: "拥有轮次"),
            ImageTranslationReplacement(id: "r002", text: "不可变截图资源")
        ])
    }

    func testTranslationParserReadsSemanticAlignments() throws {
        let response = """
        {"translations":[{"id":"r001","targetMarkdown":"高海拔卒中筛查系统","alignments":[{"tokenStart":0,"tokenEnd":2,"targetText":"高海拔卒中筛查"},{"tokenStart":2,"tokenEnd":3,"targetText":"系统"}]}]}
        """

        let replacements = ImageTranslationResponseParser.parseReplacements(response)

        XCTAssertEqual(replacements, [
            ImageTranslationReplacement(
                id: "r001",
                text: "高海拔卒中筛查系统",
                alignments: [
                    ImageTranslationAlignment(tokenStart: 0, tokenEnd: 2, targetText: "高海拔卒中筛查"),
                    ImageTranslationAlignment(tokenStart: 2, tokenEnd: 3, targetText: "系统")
                ]
            )
        ])
    }

    func testTranslationHighlightBuilderMapsSemanticGroupsAcrossImages() throws {
        let region = ImageTranslationSourceRegion(
            id: "r001",
            sourceText: "high altitude system",
            x: 0.10,
            y: 0.20,
            width: 0.80,
            height: 0.10,
            lineRects: [
                ImageTranslationLineRect(x: 0.10, y: 0.20, width: 0.80, height: 0.04),
                ImageTranslationLineRect(x: 0.10, y: 0.25, width: 0.80, height: 0.04)
            ],
            tokens: [
                ImageTranslationSourceToken(text: "high", x: 0.10, y: 0.20, width: 0.12, height: 0.04),
                ImageTranslationSourceToken(text: "altitude", x: 0.24, y: 0.20, width: 0.18, height: 0.04),
                ImageTranslationSourceToken(text: "system", x: 0.44, y: 0.20, width: 0.15, height: 0.04)
            ],
            fontSize: 0.032
        )
        let replacement = ImageTranslationReplacement(
            id: "r001",
            text: "高海拔系统",
            alignments: [
                ImageTranslationAlignment(tokenStart: 0, tokenEnd: 2, targetText: "高海拔"),
                ImageTranslationAlignment(tokenStart: 2, tokenEnd: 3, targetText: "系统")
            ]
        )

        let pairs = ImageTranslationHighlightBuilder.pairs(
            regions: [region],
            replacements: [replacement]
        )

        XCTAssertEqual(pairs.count, 2)
        XCTAssertEqual(pairs[0].sourceRects.count, 1)
        XCTAssertFalse(pairs[0].translatedRects.isEmpty)
        XCTAssertFalse(pairs[1].translatedRects.isEmpty)
        XCTAssertLessThan(pairs[0].translatedRects[0].minX, pairs[1].translatedRects[0].minX)
    }

    func testTranslationHighlightBuilderRejectsKeywordOnlyClauseAlignment() throws {
        let words = ["the", "system", "initiates", "a", "proactive", "consultation", "request"]
        let region = ImageTranslationSourceRegion(
            id: "r001",
            sourceText: words.joined(separator: " "),
            x: 0.05,
            y: 0.20,
            width: 0.90,
            height: 0.08,
            tokens: words.enumerated().map { index, word in
                ImageTranslationSourceToken(
                    text: word,
                    x: 0.05 + Double(index) * 0.10,
                    y: 0.20,
                    width: 0.08,
                    height: 0.04
                )
            }
        )
        let replacement = ImageTranslationReplacement(
            id: "r001",
            text: "系统主动发起咨询请求",
            alignments: [
                ImageTranslationAlignment(tokenStart: 0, tokenEnd: 7, targetText: "请求")
            ]
        )

        XCTAssertFalse(ImageTranslationHighlightBuilder.hasReliableAlignments(
            replacement: replacement,
            region: region
        ))
    }

    func testTranslationAlignmentRepairSkipsAlreadyReliableRegions() throws {
        let region = ImageTranslationSourceRegion(
            id: "r001",
            sourceText: "high altitude system",
            x: 0.1,
            y: 0.2,
            width: 0.8,
            height: 0.1,
            tokens: [
                ImageTranslationSourceToken(text: "high", x: 0.1, y: 0.2, width: 0.1, height: 0.04),
                ImageTranslationSourceToken(text: "altitude", x: 0.21, y: 0.2, width: 0.15, height: 0.04),
                ImageTranslationSourceToken(text: "system", x: 0.37, y: 0.2, width: 0.12, height: 0.04)
            ]
        )
        let reliable = ImageTranslationReplacement(
            id: "r001",
            text: "高海拔系统",
            alignments: [
                ImageTranslationAlignment(tokenStart: 0, tokenEnd: 2, targetText: "高海拔"),
                ImageTranslationAlignment(tokenStart: 2, tokenEnd: 3, targetText: "系统")
            ]
        )

        XCTAssertTrue(ImageTranslationHighlightBuilder.regionsNeedingAlignmentRepair(
            regions: [region],
            replacements: [reliable]
        ).isEmpty)
        XCTAssertEqual(ImageTranslationHighlightBuilder.regionsNeedingAlignmentRepair(
            regions: [region],
            replacements: [ImageTranslationReplacement(id: "r001", text: "高海拔系统")]
        ).map(\.id), ["r001"])
    }

    func testTranslationParserReadsMarkdownLayoutReplacements() throws {
        let response = """
        {"translations":[{"id":"r001","targetMarkdown":"`ConversationSession` 管理轮次","kind":"list_item"}]}
        """

        let replacements = ImageTranslationResponseParser.parseReplacements(response)

        XCTAssertEqual(replacements, [
            ImageTranslationReplacement(
                id: "r001",
                text: "`ConversationSession` 管理轮次",
                kind: "list_item"
            )
        ])
    }

    func testTranslationParserReadsLineRectsFromCoordinateBlocks() throws {
        let response = """
        {"translations":[{"targetMarkdown":"`ConversationSession` 管理轮次","x":0.1,"y":0.2,"width":0.6,"height":0.08,"lineRects":[{"x":0.1,"y":0.2,"width":0.6,"height":0.03},{"x":0.1,"y":0.25,"width":0.5,"height":0.03}],"textRects":[{"x":0.1,"y":0.2,"width":0.3,"height":0.03}],"codeRects":[{"text":"ConversationSession","x":0.1,"y":0.2,"width":0.22,"height":0.03}]}]}
        """

        let blocks = ImageTranslationResponseParser.parse(response)

        XCTAssertEqual(blocks, [
            ImageTranslationBlock(
                text: "`ConversationSession` 管理轮次",
                x: 0.1,
                y: 0.2,
                width: 0.6,
                height: 0.08,
                lineRects: [
                    ImageTranslationLineRect(x: 0.1, y: 0.2, width: 0.6, height: 0.03),
                    ImageTranslationLineRect(x: 0.1, y: 0.25, width: 0.5, height: 0.03)
                ],
                textRects: [
                    ImageTranslationLineRect(x: 0.1, y: 0.2, width: 0.3, height: 0.03)
                ],
                codeRects: [
                    ImageTranslationTokenRect(text: "ConversationSession", x: 0.1, y: 0.2, width: 0.22, height: 0.03)
                ]
            )
        ])
    }

    func testTranslationReplacementsMergeWithOCRRegions() throws {
        let regions = [
            ImageTranslationSourceRegion(
                id: "r001",
                sourceText: "owns turns",
                x: 0.1,
                y: 0.2,
                width: 0.3,
                height: 0.04,
                alignment: "left",
                fontSize: 0.03
            )
        ]
        let replacements = [
            ImageTranslationReplacement(id: "r001", text: "拥有轮次")
        ]

        let blocks = ImageTranslationMerger.merge(replacements: replacements, regions: regions)

        XCTAssertEqual(blocks, [
            ImageTranslationBlock(
                sourceID: "r001",
                text: "拥有轮次",
                x: 0.1,
                y: 0.2,
                width: 0.3,
                height: 0.04,
                alignment: "left",
                fontSize: 0.03
            )
        ])
    }

    func testTranslationReplacementsMergeLayoutKindWithOCRRegions() throws {
        let regions = [
            ImageTranslationSourceRegion(
                id: "r001",
                sourceText: "ConversationSession owns turns",
                x: 0.1,
                y: 0.2,
                width: 0.5,
                height: 0.05,
                lineRects: [
                    ImageTranslationLineRect(x: 0.1, y: 0.2, width: 0.5, height: 0.05)
                ],
                textRects: [
                    ImageTranslationLineRect(x: 0.1, y: 0.2, width: 0.32, height: 0.05)
                ],
                codeRects: [
                    ImageTranslationTokenRect(text: "ConversationSession", x: 0.1, y: 0.2, width: 0.22, height: 0.05)
                ],
                kind: "paragraph",
                alignment: "left",
                fontSize: 0.024
            )
        ]
        let replacements = [
            ImageTranslationReplacement(
                id: "r001",
                text: "`ConversationSession` 管理轮次",
                kind: "list_item"
            )
        ]

        let blocks = ImageTranslationMerger.merge(replacements: replacements, regions: regions)

        XCTAssertEqual(blocks, [
            ImageTranslationBlock(
                sourceID: "r001",
                text: "`ConversationSession` 管理轮次",
                x: 0.1,
                y: 0.2,
                width: 0.5,
                height: 0.05,
                lineRects: [
                    ImageTranslationLineRect(x: 0.1, y: 0.2, width: 0.5, height: 0.05)
                ],
                textRects: [
                    ImageTranslationLineRect(x: 0.1, y: 0.2, width: 0.32, height: 0.05)
                ],
                codeRects: [
                    ImageTranslationTokenRect(text: "ConversationSession", x: 0.1, y: 0.2, width: 0.22, height: 0.05)
                ],
                kind: "paragraph",
                alignment: "left",
                fontSize: 0.024
            )
        ])
    }

    func testTranslationSourcePolicyRejectsExistingChineseAndMixedIdentityMetadata() throws {
        XCTAssertFalse(ImageTranslationSourcePolicy.shouldTranslate("如题，楼主做了一个个人学术界面"))
        XCTAssertFalse(ImageTranslationSourcePolicy.shouldTranslate("融麒麟Ronchy Ronchy1949 活跃用户"))
        XCTAssertTrue(ImageTranslationSourcePolicy.shouldTranslate("Rongqi Lu Research Profile"))
        XCTAssertTrue(ImageTranslationSourcePolicy.shouldTranslate("Academic profile and contact information."))
    }

    func testTranslationSourcePolicyRejectsIsolatedAvatarAndIconGlyphs() throws {
        XCTAssertTrue(ImageTranslationSourcePolicy.isDecorativeFragment("R"))
        XCTAssertTrue(ImageTranslationSourcePolicy.isDecorativeFragment("•"))
        XCTAssertTrue(ImageTranslationSourcePolicy.isDecorativeFragment("↗"))
        XCTAssertFalse(ImageTranslationSourcePolicy.isDecorativeFragment("Profile"))
    }

    func testTranslationSourcePolicyProtectsLeadingIconsAndNumericBadges() throws {
        XCTAssertFalse(ImageTranslationSourcePolicy.shouldIncludeRecognizedToken("↗", index: 0, totalCount: 5))
        XCTAssertFalse(ImageTranslationSourcePolicy.shouldIncludeRecognizedToken("•", index: 0, totalCount: 5))
        XCTAssertFalse(ImageTranslationSourcePolicy.shouldIncludeRecognizedToken("L", index: 0, totalCount: 5))
        XCTAssertFalse(ImageTranslationSourcePolicy.shouldIncludeRecognizedToken("280", index: 4, totalCount: 5))
        XCTAssertFalse(ImageTranslationSourcePolicy.shouldIncludeRecognizedToken("(68)", index: 4, totalCount: 5))
        XCTAssertTrue(ImageTranslationSourcePolicy.shouldIncludeRecognizedToken("In", index: 0, totalCount: 5))
        XCTAssertFalse(ImageTranslationSourcePolicy.shouldIncludeRecognizedToken("|", index: 2, totalCount: 5))
        XCTAssertTrue(ImageTranslationSourcePolicy.shouldIncludeRecognizedToken("Profile", index: 3, totalCount: 5))
    }

    func testTranslationSourcePolicyDiscoversIdentityPrefixWithoutLabelVocabulary() throws {
        XCTAssertEqual(
            ImageTranslationSourcePolicy.identityPhraseBeforeSeparator(
                ["Rongqi", "Lu", "|", "Portfolio", "Showcase"]
            ),
            ["Rongqi", "Lu"]
        )
    }

    func testTranslationSourcePolicyProtectsDynamicEntityPhraseEverywhere() throws {
        XCTAssertEqual(
            ImageTranslationSourcePolicy.protectedTokenIndexes(
                ["Rongqi", "Lu", "Portfolio", "Showcase"],
                preservedPhrases: [["Rongqi", "Lu"]]
            ),
            Set([0, 1])
        )
    }

    func testTranslationSourcePolicyProtectsNamedEntityIndexesInsideSentence() throws {
        let protected = ImageTranslationSourcePolicy.protectedTokenIndexes(
            ["Academic", "profile", "for", "Rongqi", "Lu", "showcasing", "research"],
            namedEntityIndexes: Set([3, 4])
        )

        XCTAssertTrue(protected.contains(3))
        XCTAssertTrue(protected.contains(4))
        XCTAssertFalse(protected.contains(0))
        XCTAssertFalse(protected.contains(1))
    }

    func testTranslationSourcePolicyProtectsAcronymButNotItsNaturalLanguageSuffix() throws {
        let protected = ImageTranslationSourcePolicy.protectedTokenIndexes(
            ["UI", "-", "observable"]
        )

        XCTAssertEqual(protected, Set([0, 1]))
        XCTAssertFalse(protected.contains(2))
    }

    func testTranslationStrategyUsesSelectiveModeForCompactIdentityLabel() throws {
        XCTAssertEqual(
            ImageTranslationSourcePolicy.translationStrategy(
                tokenTexts: ["Rongqi", "Lu", "|", "Portfolio", "Showcase", "280"],
                protectedIndexes: Set([0, 1, 2, 5]),
                lineCount: 1
            ),
            .selective
        )
    }

    func testTranslationStrategyUsesBlockModeForSentencesAndMultilineText() throws {
        XCTAssertEqual(
            ImageTranslationSourcePolicy.translationStrategy(
                tokenTexts: ["Ask", "AI", "anywhere", "on", "your", "screen", "."],
                protectedIndexes: Set([1, 6]),
                lineCount: 1
            ),
            .block
        )
        XCTAssertEqual(
            ImageTranslationSourcePolicy.translationStrategy(
                tokenTexts: ["Profile", "for", "Rongqi", "Lu", "showcasing", "research"],
                protectedIndexes: Set([2, 3]),
                lineCount: 2
            ),
            .block
        )
    }

    func testTranslationStrategyDoesNotPreserveSingleBrandPrefixInsideSentence() {
        XCTAssertEqual(
            ImageTranslationSourcePolicy.translationStrategy(
                tokenTexts: ["Siri", "understands", "your", "personal", "context"],
                protectedIndexes: Set([0]),
                lineCount: 1
            ),
            .block
        )
    }

    func testTranslationStrategyFindsMisorderedSentenceTerminator() {
        XCTAssertEqual(
            ImageTranslationSourcePolicy.translationStrategy(
                tokenTexts: ["Siri", "understands", "your", "personal", ".", "context"],
                protectedIndexes: Set([0, 4]),
                lineCount: 1
            ),
            .block
        )
    }

    func testTranslationTypographyPreservesSourceScaleForWideCrops() {
        XCTAssertEqual(
            ImageTranslationTextRecognizer.fontSize(
                for: .paragraph,
                sourceLineHeight: 0.12
            ),
            0.1296,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ImageTranslationTextRecognizer.fontSize(
                for: .heading,
                sourceLineHeight: 0.12
            ),
            0.0984,
            accuracy: 0.0001
        )
    }

    func testTranslationTypographyCompensatesForDenseCJKGlyphs() {
        XCTAssertEqual(
            TranslationTypography.targetScriptFontScale(
                for: "只需询问 Siri AI，并获得相关答案。"
            ),
            0.88,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            TranslationTypography.targetScriptFontScale(
                for: "Siri understands your personal context."
            ),
            1,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            TranslationTypography.targetScriptFontScale(
                for: "使用 `ConversationSession`"
            ),
            1,
            accuracy: 0.0001
        )
    }

    func testTranslationSegmentParserAcceptsTokenRangesAndEmptyPreserveResult() throws {
        let replacements = ImageTranslationResponseParser.parseReplacements(
            #"{"translations":[{"id":"r001","kind":"heading","segments":[{"tokenStart":3,"tokenEnd":5,"targetMarkdown":"研究档案"}]},{"id":"r002","segments":[]}]}"#
        )

        XCTAssertEqual(replacements.count, 2)
        XCTAssertEqual(replacements[0].segments, [
            ImageTranslationReplacementSegment(tokenStart: 3, tokenEnd: 5, text: "研究档案")
        ])
        XCTAssertTrue(replacements[1].segments.isEmpty)
    }

    func testTranslationMergeRendersOnlyRequestedTokenRange() throws {
        let regions = [
            ImageTranslationSourceRegion(
                id: "r001",
                sourceText: "Rongqi Lu | Research Profile 280",
                x: 0.1,
                y: 0.2,
                width: 0.6,
                height: 0.05,
                tokens: [
                    ImageTranslationSourceToken(text: "Rongqi", x: 0.10, y: 0.20, width: 0.08, height: 0.04, isProtected: true),
                    ImageTranslationSourceToken(text: "Lu", x: 0.19, y: 0.20, width: 0.03, height: 0.04, isProtected: true),
                    ImageTranslationSourceToken(text: "|", x: 0.23, y: 0.20, width: 0.01, height: 0.04, isProtected: true),
                    ImageTranslationSourceToken(text: "Research", x: 0.25, y: 0.20, width: 0.10, height: 0.04),
                    ImageTranslationSourceToken(text: "Profile", x: 0.36, y: 0.20, width: 0.08, height: 0.04),
                    ImageTranslationSourceToken(text: "280", x: 0.46, y: 0.20, width: 0.04, height: 0.04, isProtected: true)
                ],
                translationStrategy: .selective,
                kind: "heading"
            )
        ]
        let replacements = [
            ImageTranslationReplacement(
                id: "r001",
                text: "",
                segments: [
                    ImageTranslationReplacementSegment(tokenStart: 3, tokenEnd: 5, text: "研究档案")
                ]
            )
        ]

        let blocks = ImageTranslationMerger.merge(replacements: replacements, regions: regions)

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].text, "研究档案")
        XCTAssertEqual(blocks[0].translationStrategy, .selective)
        XCTAssertEqual(blocks[0].trailingAttachments.count, 1)
        XCTAssertEqual(blocks[0].x, 0.25, accuracy: 0.0001)
        XCTAssertGreaterThan(blocks[0].width, 0.20)
        XCTAssertLessThan(blocks[0].width, 0.22)
        XCTAssertGreaterThanOrEqual(blocks[0].protectedRects.count, 4)
        XCTAssertEqual(blocks[0].lineRects[0].x, 0.25, accuracy: 0.0001)
        XCTAssertEqual(blocks[0].textRects[0].x, 0.25, accuracy: 0.0001)
        XCTAssertGreaterThan(blocks[0].textRects[0].width, 0.19)
    }

    func testTranslationMergeSeparatesEraseAndLayoutSlotsAroundProtectedNeighbors() throws {
        let region = ImageTranslationSourceRegion(
            id: "r001",
            sourceText: "Rongqi Lu | Research Profile 280",
            x: 0.1,
            y: 0.2,
            width: 0.6,
            height: 0.05,
            tokens: [
                ImageTranslationSourceToken(text: "Rongqi", x: 0.10, y: 0.20, width: 0.08, height: 0.04, isProtected: true),
                ImageTranslationSourceToken(text: "Lu", x: 0.19, y: 0.20, width: 0.03, height: 0.04, isProtected: true),
                ImageTranslationSourceToken(text: "|", x: 0.238, y: 0.20, width: 0.014, height: 0.04, isProtected: true),
                ImageTranslationSourceToken(text: "Research", x: 0.25, y: 0.20, width: 0.10, height: 0.04),
                ImageTranslationSourceToken(text: "Profile", x: 0.36, y: 0.20, width: 0.08, height: 0.04),
                ImageTranslationSourceToken(text: "280", x: 0.455, y: 0.20, width: 0.04, height: 0.04, isProtected: true)
            ],
            translationStrategy: .selective,
            kind: "heading"
        )
        let replacement = ImageTranslationReplacement(
            id: "r001",
            text: "",
            segments: [
                ImageTranslationReplacementSegment(tokenStart: 3, tokenEnd: 5, text: "研究档案")
            ]
        )

        let block = try XCTUnwrap(ImageTranslationMerger.merge(
            replacements: [replacement],
            regions: [region]
        ).first)

        XCTAssertGreaterThan(block.lineRects[0].x, 0.25)
        XCTAssertEqual(block.textRects[0].x, 0.25, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(
            block.textRects[0].x + block.textRects[0].width,
            0.455
        )
        XCTAssertLessThan(
            block.lineRects[0].x,
            block.textRects[0].x + block.textRects[0].width
        )
    }

    func testTranslationMergeAbsorbsUnprotectedTrailingOCRLetterFragment() throws {
        let region = ImageTranslationSourceRegion(
            id: "r001",
            sourceText: "Rongqi Lu | Research Profil e 280",
            x: 0.1,
            y: 0.2,
            width: 0.6,
            height: 0.05,
            tokens: [
                ImageTranslationSourceToken(text: "Rongqi", x: 0.10, y: 0.20, width: 0.08, height: 0.04, isProtected: true),
                ImageTranslationSourceToken(text: "Lu", x: 0.19, y: 0.20, width: 0.03, height: 0.04, isProtected: true),
                ImageTranslationSourceToken(text: "|", x: 0.23, y: 0.20, width: 0.01, height: 0.04, isProtected: true),
                ImageTranslationSourceToken(text: "Research", x: 0.25, y: 0.20, width: 0.10, height: 0.04),
                ImageTranslationSourceToken(text: "Profil", x: 0.36, y: 0.20, width: 0.065, height: 0.04),
                ImageTranslationSourceToken(text: "e", x: 0.426, y: 0.20, width: 0.012, height: 0.04),
                ImageTranslationSourceToken(text: "280", x: 0.455, y: 0.20, width: 0.04, height: 0.04, isProtected: true)
            ],
            translationStrategy: .selective,
            kind: "heading"
        )
        let replacement = ImageTranslationReplacement(
            id: "r001",
            text: "",
            segments: [
                ImageTranslationReplacementSegment(tokenStart: 3, tokenEnd: 5, text: "研究资料")
            ]
        )

        let block = try XCTUnwrap(ImageTranslationMerger.merge(
            replacements: [replacement],
            regions: [region]
        ).first)
        let eraseRect = try XCTUnwrap(block.textRects.first)

        XCTAssertGreaterThanOrEqual(eraseRect.x + eraseRect.width, 0.438)
        XCTAssertFalse(block.protectedRects.contains { rect in
            rect.x <= 0.43 && rect.x + rect.width >= 0.438
        })
    }

    func testTranslationMergeUsesCompleteReplacementForTokenizedBlockRegion() throws {
        let region = ImageTranslationSourceRegion(
            id: "r001",
            sourceText: "Academic profile for Rongqi Lu showcasing research interests .",
            x: 0.1,
            y: 0.2,
            width: 0.7,
            height: 0.08,
            lineRects: [
                ImageTranslationLineRect(x: 0.1, y: 0.2, width: 0.7, height: 0.04),
                ImageTranslationLineRect(x: 0.1, y: 0.24, width: 0.3, height: 0.04)
            ],
            tokens: [
                ImageTranslationSourceToken(text: "Academic", x: 0.1, y: 0.2, width: 0.1, height: 0.04),
                ImageTranslationSourceToken(text: "profile", x: 0.21, y: 0.2, width: 0.08, height: 0.04),
                ImageTranslationSourceToken(text: "for", x: 0.30, y: 0.2, width: 0.04, height: 0.04),
                ImageTranslationSourceToken(text: "Rongqi", x: 0.35, y: 0.2, width: 0.08, height: 0.04, isProtected: true),
                ImageTranslationSourceToken(text: "Lu", x: 0.44, y: 0.2, width: 0.03, height: 0.04, isProtected: true)
            ],
            translationStrategy: .block
        )
        let replacement = ImageTranslationReplacement(
            id: "r001",
            text: "Rongqi Lu 的学术简介，展示其研究兴趣。"
        )

        let blocks = ImageTranslationMerger.merge(
            replacements: [replacement],
            regions: [region]
        )

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].text, "Rongqi Lu 的学术简介，展示其研究兴趣。")
        XCTAssertEqual(blocks[0].translationStrategy, .block)
        XCTAssertEqual(blocks[0].lineRects.count, 2)
    }

    func testBlockPromptDoesNotProtectOrdinarySentenceInitialCapitalizedWord() throws {
        let region = ImageTranslationSourceRegion(
            id: "r001",
            sourceText: "Screenshots belong to the user turn.",
            x: 0.1,
            y: 0.2,
            width: 0.6,
            height: 0.05,
            tokens: [
                ImageTranslationSourceToken(
                    text: "Screenshots",
                    x: 0.1,
                    y: 0.2,
                    width: 0.12,
                    height: 0.04,
                    isProtected: true
                )
            ],
            translationStrategy: .block
        )

        let request = ImageTranslationPrompt.request(regions: [region])
        let promptText = request.messages
            .flatMap(\.content)
            .compactMap { content -> String? in
                guard case let .text(text) = content else {
                    return nil
                }
                return text
            }
            .joined(separator: "\n")

        XCTAssertTrue(request.systemPrompt.contains("Screenshots"))
        XCTAssertFalse(promptText.contains("\"preserve\":true"))
    }

    func testTranslationMergeRejectsSegmentThatTouchesProtectedToken() throws {
        let region = ImageTranslationSourceRegion(
            id: "r001",
            sourceText: "Rongqi Lu Research Profile",
            x: 0.1,
            y: 0.2,
            width: 0.5,
            height: 0.05,
            tokens: [
                ImageTranslationSourceToken(text: "Rongqi", x: 0.1, y: 0.2, width: 0.08, height: 0.04, isProtected: true),
                ImageTranslationSourceToken(text: "Lu", x: 0.19, y: 0.2, width: 0.03, height: 0.04, isProtected: true),
                ImageTranslationSourceToken(text: "Research", x: 0.23, y: 0.2, width: 0.1, height: 0.04),
                ImageTranslationSourceToken(text: "Profile", x: 0.34, y: 0.2, width: 0.08, height: 0.04)
            ],
            translationStrategy: .selective
        )
        let replacement = ImageTranslationReplacement(
            id: "r001",
            text: "",
            segments: [
                ImageTranslationReplacementSegment(tokenStart: 0, tokenEnd: 4, text: "Rongqi Lu 研究档案")
            ]
        )

        XCTAssertTrue(ImageTranslationMerger.merge(
            replacements: [replacement],
            regions: [region]
        ).isEmpty)
    }

    func testTranslationMergeKeepsMiddleEntityAsOriginalPixels() throws {
        let region = ImageTranslationSourceRegion(
            id: "r001",
            sourceText: "Profile for Rongqi Lu showcasing research",
            x: 0.1,
            y: 0.2,
            width: 0.7,
            height: 0.05,
            tokens: [
                ImageTranslationSourceToken(text: "Profile", x: 0.10, y: 0.2, width: 0.08, height: 0.04),
                ImageTranslationSourceToken(text: "for", x: 0.19, y: 0.2, width: 0.04, height: 0.04),
                ImageTranslationSourceToken(text: "Rongqi", x: 0.24, y: 0.2, width: 0.08, height: 0.04, isProtected: true),
                ImageTranslationSourceToken(text: "Lu", x: 0.33, y: 0.2, width: 0.03, height: 0.04, isProtected: true),
                ImageTranslationSourceToken(text: "showcasing", x: 0.37, y: 0.2, width: 0.11, height: 0.04),
                ImageTranslationSourceToken(text: "research", x: 0.49, y: 0.2, width: 0.09, height: 0.04)
            ],
            translationStrategy: .selective
        )
        let replacement = ImageTranslationReplacement(
            id: "r001",
            text: "",
            segments: [
                ImageTranslationReplacementSegment(tokenStart: 0, tokenEnd: 2, text: "简介"),
                ImageTranslationReplacementSegment(tokenStart: 4, tokenEnd: 6, text: "展示研究")
            ]
        )

        let blocks = ImageTranslationMerger.merge(
            replacements: [replacement],
            regions: [region]
        )

        XCTAssertEqual(blocks.map(\.text), ["简介", "展示研究"])
        XCTAssertEqual(blocks.count, 2)
        XCTAssertTrue(blocks.allSatisfy { !$0.protectedRects.isEmpty })
    }

    func testTranslationMergeSkipsNoOpReplacementToPreserveOriginalPixels() throws {
        let regions = [
            ImageTranslationSourceRegion(
                id: "r001",
                sourceText: "Rongqi Lu",
                x: 0.1,
                y: 0.2,
                width: 0.3,
                height: 0.04,
                kind: "heading"
            )
        ]

        let blocks = ImageTranslationMerger.merge(
            replacements: [ImageTranslationReplacement(id: "r001", text: "Rongqi Lu", kind: "list_item")],
            regions: regions
        )

        XCTAssertTrue(blocks.isEmpty)
    }

    func testTranslationMergePreservesDigitsTranslatedFromNumberWords() {
        for (source, translated) in [
            ("For example, all zeros", "例如全为 0"),
            ("Use twenty-one samples", "使用 21 个样本"),
            ("Multiply by half", "乘以 0.5"),
            ("Take the first example", "取第 1 个示例")
        ] {
            let region = ImageTranslationSourceRegion(id: "r001", sourceText: source,
                x: 0.1, y: 0.2, width: 0.8, height: 0.05, kind: "paragraph")
            let blocks = ImageTranslationMerger.merge(
                replacements: [ImageTranslationReplacement(id: region.id, text: translated)],
                regions: [region])
            XCTAssertEqual(blocks.first?.text, translated, source)
        }
    }

    func testTranslationMergeNumberWordCheckDoesNotMatchInsideOrdinaryWords() {
        let region = ImageTranslationSourceRegion(id: "r001", sourceText: "Someone's profile",
            x: 0.1, y: 0.2, width: 0.8, height: 0.05, kind: "heading")
        let blocks = ImageTranslationMerger.merge(
            replacements: [ImageTranslationReplacement(id: region.id, text: "个人主页 280")],
            regions: [region])
        XCTAssertEqual(blocks.first?.text, "个人主页")
    }

    func testTranslationMergeDoesNotRedrawProtectedNumericBadge() throws {
        let regions = [
            ImageTranslationSourceRegion(
                id: "r001",
                sourceText: "Rongqi Lu | Research Profile",
                x: 0.1,
                y: 0.2,
                width: 0.5,
                height: 0.05,
                kind: "heading"
            )
        ]

        let blocks = ImageTranslationMerger.merge(
            replacements: [
                ImageTranslationReplacement(
                    id: "r001",
                    text: "Rongqi Lu | 研究主页 280",
                    kind: "list_item"
                )
            ],
            regions: regions
        )

        XCTAssertEqual(blocks.first?.text, "Rongqi Lu | 研究主页")
        XCTAssertEqual(blocks.first?.kind, "heading")
    }

    func testTranslationReplacementsKeepOnlySourceCodeRectMarkdown() throws {
        let regions = [
            ImageTranslationSourceRegion(
                id: "r001",
                sourceText: "Marr uses ConversationSession",
                x: 0.1,
                y: 0.2,
                width: 0.5,
                height: 0.05,
                codeRects: [
                    ImageTranslationTokenRect(text: "ConversationSession", x: 0.2, y: 0.2, width: 0.2, height: 0.05)
                ]
            )
        ]
        let replacements = [
            ImageTranslationReplacement(
                id: "r001",
                text: "`Marr` 使用 `ConversationSession`",
                kind: "paragraph"
            )
        ]

        let blocks = ImageTranslationMerger.merge(replacements: replacements, regions: regions)

        XCTAssertEqual(blocks.first?.text, "Marr 使用 `ConversationSession`")
    }

    func testTranslationReplacementsRestoreMissingSourceCodeMarkdown() throws {
        let regions = [
            ImageTranslationSourceRegion(
                id: "r001",
                sourceText: "VisionAIClient receives VisionRequest; InferenceClient encodes it",
                x: 0.1,
                y: 0.2,
                width: 0.8,
                height: 0.05,
                codeRects: [
                    ImageTranslationTokenRect(text: "VisionAIClient", x: 0.1, y: 0.2, width: 0.16, height: 0.05),
                    ImageTranslationTokenRect(text: "VisionRequest", x: 0.4, y: 0.2, width: 0.15, height: 0.05),
                    ImageTranslationTokenRect(text: "InferenceClient", x: 0.6, y: 0.2, width: 0.15, height: 0.05)
                ]
            )
        ]
        let replacements = [
            ImageTranslationReplacement(
                id: "r001",
                text: "VisionAIClient 接收 VisionRequest；InferenceClient 对其编码",
                kind: "list_item"
            )
        ]

        let blocks = ImageTranslationMerger.merge(replacements: replacements, regions: regions)

        XCTAssertEqual(
            blocks.first?.text,
            "`VisionAIClient` 接收 `VisionRequest`；`InferenceClient` 对其编码"
        )
    }

    func testTranslationReplacementsRemoveMarkdownWhenNoSourceCodeRects() throws {
        let regions = [
            ImageTranslationSourceRegion(
                id: "r001",
                sourceText: "Marr uses ConversationSession",
                x: 0.1,
                y: 0.2,
                width: 0.5,
                height: 0.05
            )
        ]
        let replacements = [
            ImageTranslationReplacement(
                id: "r001",
                text: "`Marr` 使用 `ConversationSession`",
                kind: "paragraph"
            )
        ]

        let blocks = ImageTranslationMerger.merge(replacements: replacements, regions: regions)

        XCTAssertEqual(blocks.first?.text, "Marr 使用 ConversationSession")
    }

    func testTranslationReplacementsKeepCodeMarkdownAcrossMinorOCRTypos() throws {
        let regions = [
            ImageTranslationSourceRegion(
                id: "r001",
                sourceText: "ConversationSesslon owns turns",
                x: 0.1,
                y: 0.2,
                width: 0.5,
                height: 0.05,
                codeRects: [
                    ImageTranslationTokenRect(text: "ConversationSesslon", x: 0.1, y: 0.2, width: 0.22, height: 0.05)
                ]
            )
        ]
        let replacements = [
            ImageTranslationReplacement(
                id: "r001",
                text: "`ConversationSession` 管理轮次",
                kind: "paragraph"
            )
        ]

        let blocks = ImageTranslationMerger.merge(replacements: replacements, regions: regions)

        XCTAssertEqual(blocks.first?.text, "`ConversationSession` 管理轮次")
    }

    func testTranslationLayoutExpandsShortTrailingLinesToBlockWidth() throws {
        let expanded = ImageTranslationLayoutGeometry.expandedLineRects(
            [
                CGRect(x: 10, y: 30, width: 180, height: 18),
                CGRect(x: 24, y: 8, width: 42, height: 18)
            ],
            sourceRect: CGRect(x: 8, y: 6, width: 186, height: 44),
            bounds: CGRect(x: 0, y: 0, width: 220, height: 80)
        )

        XCTAssertEqual(expanded.count, 2)
        XCTAssertEqual(expanded[0].maxX, 194)
        XCTAssertEqual(expanded[1].minX, 24)
        XCTAssertEqual(expanded[1].maxX, 194)
    }

    func testTranslationLayoutExpandsNarrowOCRCodeRectToExpectedTokenWidth() throws {
        let expanded = ImageTranslationLayoutGeometry.expandedCodeRect(
            CGRect(x: 100, y: 20, width: 245, height: 40),
            text: "ConversationSession",
            bounds: CGRect(x: 0, y: 0, width: 800, height: 100)
        )

        XCTAssertEqual(expanded.minX, 100)
        XCTAssertGreaterThan(expanded.width, 295)
        XCTAssertLessThan(expanded.width, 315)
    }

    func testTranslationReadingOrderKeepsDistantColumnsAsSeparateVisualLines() {
        let leftColumnLine = CGRect(x: 0.03, y: 0.42, width: 0.45, height: 0.026)
        let rightColumnLine = CGRect(x: 0.54, y: 0.421, width: 0.40, height: 0.025)

        XCTAssertFalse(
            ImageTranslationReadingOrderLayout.belongsToSameVisualLine(
                rightColumnLine,
                lineRect: leftColumnLine
            )
        )
    }

    func testTranslationReadingOrderStillJoinsNearbyStyledFragments() {
        let boldPrefix = CGRect(x: 0.03, y: 0.42, width: 0.12, height: 0.026)
        let regularSuffix = CGRect(x: 0.158, y: 0.421, width: 0.31, height: 0.025)

        XCTAssertTrue(
            ImageTranslationReadingOrderLayout.belongsToSameVisualLine(
                regularSuffix,
                lineRect: boldPrefix
            )
        )
    }

    func testTranslationReadingOrderKeepsOverlappingAdjacentRowsSeparate() {
        let upperRow = CGRect(x: 0.0247, y: 0.5447, width: 0.4012, height: 0.0279)
        let lowerRow = CGRect(x: 0.0208, y: 0.5183, width: 0.3625, height: 0.0366)

        XCTAssertFalse(
            ImageTranslationReadingOrderLayout.belongsToSameVisualLine(
                lowerRow,
                lineRect: upperRow
            )
        )
    }

    func testTranslationReadingOrderContinuesEarlierColumnBlock() throws {
        let previousLeftLine = CGRect(x: 0.03, y: 0.48, width: 0.44, height: 0.026)
        let previousRightLine = CGRect(x: 0.54, y: 0.48, width: 0.40, height: 0.026)
        let nextLeftLine = CGRect(x: 0.03, y: 0.44, width: 0.42, height: 0.026)
        let previousLines = [previousLeftLine, previousRightLine]

        let blockIndex = try XCTUnwrap(
            ImageTranslationReadingOrderLayout.closestCompatibleBlockIndex(
                for: nextLeftLine,
                lastLineRects: previousLines,
                isCompatible: { index in
                    abs(previousLines[index].minX - nextLeftLine.minX) < 0.035
                }
            )
        )

        XCTAssertEqual(blockIndex, 0)
    }

    func testTranslationReadingOrderJoinsWrappedLargeHeadingLines() {
        XCTAssertTrue(
            ImageTranslationReadingOrderLayout.isWrappedHeadingContinuation(
                previousRect: CGRect(x: 0.06, y: 0.50, width: 0.70, height: 0.10),
                candidateRect: CGRect(x: 0.068, y: 0.39, width: 0.30, height: 0.09),
                previousLooksLikeHeading: true,
                candidateLooksLikeHeading: true
            )
        )
    }

    func testTranslationReadingOrderDoesNotJoinHeadingWithSmallerBody() {
        XCTAssertFalse(
            ImageTranslationReadingOrderLayout.isWrappedHeadingContinuation(
                previousRect: CGRect(x: 0.06, y: 0.50, width: 0.70, height: 0.10),
                candidateRect: CGRect(x: 0.06, y: 0.43, width: 0.62, height: 0.035),
                previousLooksLikeHeading: true,
                candidateLooksLikeHeading: true
            )
        )
    }

    func testTranslationReadingOrderDoesNotJoinDistantHeadings() {
        XCTAssertFalse(
            ImageTranslationReadingOrderLayout.isWrappedHeadingContinuation(
                previousRect: CGRect(x: 0.06, y: 0.60, width: 0.70, height: 0.10),
                candidateRect: CGRect(x: 0.06, y: 0.31, width: 0.42, height: 0.09),
                previousLooksLikeHeading: true,
                candidateLooksLikeHeading: true
            )
        )
    }

    func testTranslationReadingOrderKeepsSentenceAtNextLineInsideParagraph() {
        XCTAssertTrue(
            ImageTranslationReadingOrderLayout.isTightWrappedParagraphContinuation(
                previousRect: CGRect(x: 0.025, y: 0.280, width: 0.90, height: 0.025),
                candidateRect: CGRect(x: 0.026, y: 0.245, width: 0.78, height: 0.025),
                blockRect: CGRect(x: 0.025, y: 0.245, width: 0.93, height: 0.36)
            )
        )
    }

    func testTranslationReadingOrderDoesNotJoinAfterShortParagraphEnding() {
        XCTAssertFalse(
            ImageTranslationReadingOrderLayout.isTightWrappedParagraphContinuation(
                previousRect: CGRect(x: 0.025, y: 0.280, width: 0.45, height: 0.025),
                candidateRect: CGRect(x: 0.026, y: 0.245, width: 0.78, height: 0.025),
                blockRect: CGRect(x: 0.025, y: 0.245, width: 0.93, height: 0.36)
            )
        )
    }

    func testTranslationReadingOrderDoesNotJoinParagraphAcrossLargeGap() {
        XCTAssertFalse(
            ImageTranslationReadingOrderLayout.isTightWrappedParagraphContinuation(
                previousRect: CGRect(x: 0.025, y: 0.280, width: 0.90, height: 0.025),
                candidateRect: CGRect(x: 0.026, y: 0.205, width: 0.78, height: 0.025),
                blockRect: CGRect(x: 0.025, y: 0.205, width: 0.93, height: 0.40)
            )
        )
    }

    func testCompareImageResizePreservesAspectRatioAndFitsScreen() {
        let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let current = CGRect(x: 900, y: 600, width: 240, height: 120)
        for scale: CGFloat in [0.01, 0.5, 1, 2, 10] {
            let frame = TranslationCompareLayout.resizedOriginalFrame(
                currentFrame: current, sourceSize: CGSize(width: 400, height: 200),
                scale: scale, visibleFrame: bounds
            )
            XCTAssertEqual(frame.width / frame.height, 2, accuracy: 0.0001)
            XCTAssertTrue(bounds.insetBy(dx: 8, dy: 8).contains(frame))
            XCTAssertGreaterThanOrEqual(frame.width, 120)
        }
    }

    func testCompareImageResizeRestoresSourceSize() {
        let frame = TranslationCompareLayout.resizedOriginalFrame(
            currentFrame: CGRect(x: 200, y: 200, width: 800, height: 400),
            sourceSize: CGSize(width: 400, height: 200), scale: 1,
            visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000)
        )
        XCTAssertEqual(frame.size, CGSize(width: 400, height: 200))
        XCTAssertEqual(frame.midX, 600)
        XCTAssertEqual(frame.midY, 400)
    }

    func testCompareLayoutPlacesOriginalToLeftWhenSpaceAllows() throws {
        let frame = TranslationCompareLayout.originalFrame(
            anchorFrame: CGRect(x: 700, y: 200, width: 300, height: 220),
            visibleFrame: CGRect(x: 0, y: 24, width: 1200, height: 760)
        )

        XCTAssertEqual(frame, CGRect(x: 392, y: 200, width: 300, height: 220))
    }

    func testCompareLayoutPlacesOriginalToRightWhenLeftDoesNotFit() throws {
        let frame = TranslationCompareLayout.originalFrame(
            anchorFrame: CGRect(x: 40, y: 200, width: 300, height: 220),
            visibleFrame: CGRect(x: 0, y: 24, width: 1200, height: 760)
        )

        XCTAssertEqual(frame, CGRect(x: 348, y: 200, width: 300, height: 220))
    }

    func testCompareLayoutUsesVerticalSpaceWhenBothSidesAreBlocked() throws {
        let frame = TranslationCompareLayout.originalFrame(
            anchorFrame: CGRect(x: 200, y: 100, width: 600, height: 200),
            visibleFrame: CGRect(x: 0, y: 24, width: 1000, height: 700)
        )

        XCTAssertEqual(frame, CGRect(x: 200, y: 308, width: 600, height: 200))
        XCTAssertFalse(frame.intersects(CGRect(x: 200, y: 100, width: 600, height: 200)))
    }

    func testCompareLayoutMinimizesOverlapWhenNoClearPlacementExists() throws {
        let anchorFrame = CGRect(x: 200, y: 150, width: 600, height: 400)
        let frame = TranslationCompareLayout.originalFrame(
            anchorFrame: anchorFrame,
            visibleFrame: CGRect(x: 0, y: 24, width: 1000, height: 700)
        )

        XCTAssertEqual(frame, CGRect(x: 200, y: 312, width: 600, height: 400))
        XCTAssertEqual(frame.size, anchorFrame.size)
    }

    func testSemanticNormalizerSplitsMergedBulletItems() throws {
        let block = ImageTranslationBlock(
            text: "• 第一项\n• 第二项\n• 第三项",
            x: 0.1,
            y: 0.4,
            width: 0.8,
            height: 0.2,
            kind: "list_item",
            alignment: "left",
            fontSize: 0.026
        )

        let normalized = ImageTranslationSemanticNormalizer.normalize([block])

        XCTAssertEqual(normalized.map(\.text), ["第一项", "第二项", "第三项"])
        XCTAssertTrue(normalized.allSatisfy { $0.kind == "list_item" })
    }

    func testCodeHeuristicsRecognizesStrongAPIIdentifiers() throws {
        XCTAssertTrue(ImageTranslationCodeHeuristics.isStrongIdentifier("ConversationSession"))
        XCTAssertTrue(ImageTranslationCodeHeuristics.isStrongIdentifier("VisionAIClient"))
        XCTAssertTrue(ImageTranslationCodeHeuristics.isStrongIdentifier("InferenceClient"))
        XCTAssertFalse(ImageTranslationCodeHeuristics.isStrongIdentifier("macOS"))
        XCTAssertFalse(ImageTranslationCodeHeuristics.isStrongIdentifier("Marr"))
    }

    func testElasticSpacingDistributesSectionSlackEvenly() throws {
        let gaps = ImageTranslationElasticSpacing.distributedGaps(
            baseGaps: [20, 20, 20],
            minimumGaps: [8, 8, 8],
            maximumGaps: [50, 50, 50],
            itemHeights: [40, 40, 40],
            availableHeight: 240
        )

        XCTAssertEqual(gaps.count, 3)
        XCTAssertTrue(gaps.allSatisfy { abs($0 - 40) < 0.001 })
    }

    func testElasticSpacingCompressesGapsBeforeContent() throws {
        let gaps = ImageTranslationElasticSpacing.distributedGaps(
            baseGaps: [20, 20, 20],
            minimumGaps: [8, 8, 8],
            maximumGaps: [50, 50, 50],
            itemHeights: [40, 40, 40],
            availableHeight: 150
        )

        XCTAssertEqual(gaps.count, 3)
        XCTAssertTrue(gaps.allSatisfy { abs($0 - 10) < 0.001 })
    }

    func testTranslationRendererErasesWholeLineWhenTokenRectsAreIncomplete() throws {
        let size = NSSize(width: 200, height: 100)
        let source = NSImage(size: size)
        source.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
        NSColor.red.setFill()
        NSBezierPath(rect: CGRect(x: 20, y: 50, width: 140, height: 20)).fill()
        source.unlockFocus()

        let pickedImage = PickedImage(
            data: Data(),
            mimeType: "image/png",
            fileName: "synthetic.png",
            image: source
        )
        let block = ImageTranslationBlock(
            text: "译",
            x: 0.10,
            y: 0.30,
            width: 0.70,
            height: 0.20,
            lineRects: [
                ImageTranslationLineRect(x: 0.10, y: 0.30, width: 0.70, height: 0.20)
            ],
            textRects: [
                ImageTranslationLineRect(x: 0.10, y: 0.30, width: 0.10, height: 0.20)
            ],
            textColor: "#0000ff",
            backgroundColor: "#ffffff",
            alignment: "left",
            fontSize: 0.12
        )

        let rendered = try XCTUnwrap(ImageTranslationRenderer.render(source: pickedImage, blocks: [block]))
        var renderedRect = CGRect(origin: .zero, size: size)
        let cgImage = try XCTUnwrap(rendered.cgImage(forProposedRect: &renderedRect, context: nil, hints: nil))
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let color = try XCTUnwrap(bitmap.colorAt(x: 140, y: 39)?.usingColorSpace(.sRGB))

        XCTAssertGreaterThan(color.redComponent, 0.95)
        XCTAssertGreaterThan(color.greenComponent, 0.95)
        XCTAssertGreaterThan(color.blueComponent, 0.95)
    }

    func testTranslationRendererPreservesRetinaLogicalSize() throws {
        let logicalSize = NSSize(width: 120, height: 60)
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 240,
                pixelsHigh: 120,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bitmapFormat: [],
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        bitmap.size = logicalSize
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        NSBezierPath(rect: CGRect(origin: .zero, size: logicalSize)).fill()
        NSGraphicsContext.restoreGraphicsState()

        let sourceImage = NSImage(size: logicalSize)
        sourceImage.addRepresentation(bitmap)
        let pickedImage = PickedImage(
            data: Data(),
            mimeType: "image/tiff",
            fileName: "retina-source.tiff",
            image: sourceImage
        )
        let translatedImage = try XCTUnwrap(
            ImageTranslationRenderer.render(
                source: pickedImage,
                blocks: [
                    ImageTranslationBlock(
                        text: "字号测试",
                        x: 0.10,
                        y: 0.20,
                        width: 0.60,
                        height: 0.30,
                        textColor: "#ffffff",
                        backgroundColor: "#1f1f1f",
                        fontSize: 0.16
                    )
                ]
            )
        )

        XCTAssertEqual(bitmap.pixelsWide, Int(logicalSize.width * 2))
        XCTAssertEqual(bitmap.pixelsHigh, Int(logicalSize.height * 2))
        XCTAssertEqual(sourceImage.size.width, logicalSize.width, accuracy: 0.01)
        XCTAssertEqual(sourceImage.size.height, logicalSize.height, accuracy: 0.01)
        XCTAssertEqual(translatedImage.size.width, sourceImage.size.width, accuracy: 0.01)
        XCTAssertEqual(translatedImage.size.height, sourceImage.size.height, accuracy: 0.01)
    }

    func testTranslationRendererPreservesSourceDetailsOutsideTranslatedRegion() throws {
        let size = NSSize(width: 240, height: 140)
        let source = NSImage(size: size)
        source.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
        NSColor.magenta.setFill()
        NSBezierPath(rect: CGRect(x: 82, y: 48, width: 76, height: 44)).fill()
        source.unlockFocus()

        let pickedImage = PickedImage(
            data: Data(),
            mimeType: "image/png",
            fileName: "source-artifact.png",
            image: source
        )
        let block = ImageTranslationBlock(
            text: "翻译标题",
            x: 0.08,
            y: 0.08,
            width: 0.84,
            height: 0.12,
            kind: "title",
            alignment: "left",
            fontSize: 0.08
        )

        let rendered = try XCTUnwrap(ImageTranslationRenderer.render(source: pickedImage, blocks: [block]))
        let sourceBitmap = try XCTUnwrap(displayBitmap(for: source, size: size))
        let detailPoint = try XCTUnwrap(firstPixel(in: sourceBitmap) { color in
            color.redComponent > color.greenComponent + 0.20
                && color.blueComponent > color.greenComponent + 0.20
        })
        let bitmap = try XCTUnwrap(displayBitmap(for: rendered, size: size))
        let renderedDetail = try XCTUnwrap(bitmap.colorAt(x: detailPoint.x, y: detailPoint.y)?.usingColorSpace(.sRGB))

        XCTAssertGreaterThan(renderedDetail.redComponent, renderedDetail.greenComponent + 0.20)
        XCTAssertGreaterThan(renderedDetail.blueComponent, renderedDetail.greenComponent + 0.20)
    }

    func testTranslationRendererUsesReliableTextRectsWithoutErasingAdjacentIcon() throws {
        let size = NSSize(width: 220, height: 100)
        let source = NSImage(size: size)
        source.lockFocus()
        NSColor(calibratedWhite: 0.10, alpha: 1).setFill()
        NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
        NSColor.cyan.setFill()
        NSBezierPath(rect: CGRect(x: 24, y: 56, width: 14, height: 14)).fill()
        NSColor.white.setFill()
        NSBezierPath(rect: CGRect(x: 58, y: 56, width: 112, height: 14)).fill()
        source.unlockFocus()

        let pickedImage = PickedImage(
            data: Data(),
            mimeType: "image/png",
            fileName: "icon-and-text.png",
            image: source
        )
        let block = ImageTranslationBlock(
            text: "译",
            x: 0.08,
            y: 0.25,
            width: 0.74,
            height: 0.20,
            lineRects: [
                ImageTranslationLineRect(x: 0.08, y: 0.25, width: 0.74, height: 0.20)
            ],
            textRects: [
                ImageTranslationLineRect(x: 0.26, y: 0.25, width: 0.51, height: 0.20)
            ],
            translationStrategy: .selective,
            backgroundColor: "#1a1a1a",
            alignment: "right",
            fontSize: 0.12
        )

        let rendered = try XCTUnwrap(ImageTranslationRenderer.render(source: pickedImage, blocks: [block]))
        let sourceBitmap = try XCTUnwrap(displayBitmap(for: source, size: size))
        let iconPoint = try XCTUnwrap(firstPixel(in: sourceBitmap) { color in
            color.greenComponent > color.redComponent + 0.20
                && color.blueComponent > color.redComponent + 0.20
        })
        let bitmap = try XCTUnwrap(displayBitmap(for: rendered, size: size))
        let renderedIcon = try XCTUnwrap(bitmap.colorAt(x: iconPoint.x, y: iconPoint.y)?.usingColorSpace(.sRGB))

        XCTAssertGreaterThan(renderedIcon.greenComponent, renderedIcon.redComponent + 0.20)
        XCTAssertGreaterThan(renderedIcon.blueComponent, renderedIcon.redComponent + 0.20)
    }

    func testTranslationRendererNeverErasesProtectedNumericBadge() throws {
        let size = NSSize(width: 220, height: 100)
        let source = NSImage(size: size)
        source.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
        NSColor.black.setFill()
        NSBezierPath(rect: CGRect(x: 22, y: 50, width: 132, height: 20)).fill()
        NSColor.magenta.setFill()
        NSBezierPath(roundedRect: CGRect(x: 160, y: 50, width: 28, height: 20), xRadius: 8, yRadius: 8).fill()
        source.unlockFocus()

        let pickedImage = PickedImage(
            data: Data(),
            mimeType: "image/png",
            fileName: "protected-badge.png",
            image: source
        )
        let block = ImageTranslationBlock(
            text: "研究主页",
            x: 0.10,
            y: 0.30,
            width: 0.76,
            height: 0.20,
            lineRects: [
                ImageTranslationLineRect(x: 0.10, y: 0.30, width: 0.76, height: 0.20)
            ],
            textRects: [
                ImageTranslationLineRect(x: 0.10, y: 0.30, width: 0.40, height: 0.20)
            ],
            protectedRects: [
                ImageTranslationLineRect(x: 0.72, y: 0.30, width: 0.14, height: 0.20)
            ],
            translationStrategy: .selective,
            textColor: "#0066cc",
            backgroundColor: "#ffffff",
            alignment: "left",
            fontSize: 0.12
        )

        let rendered = try XCTUnwrap(ImageTranslationRenderer.render(source: pickedImage, blocks: [block]))
        let sourceBitmap = try XCTUnwrap(displayBitmap(for: source, size: size))
        let badgePoint = try XCTUnwrap(firstPixel(in: sourceBitmap) { color in
            color.redComponent > color.greenComponent + 0.30
                && color.blueComponent > color.greenComponent + 0.30
        })
        let bitmap = try XCTUnwrap(displayBitmap(for: rendered, size: size))
        let renderedBadge = try XCTUnwrap(
            bitmap.colorAt(x: badgePoint.x, y: badgePoint.y)?.usingColorSpace(.sRGB)
        )

        XCTAssertGreaterThan(renderedBadge.redComponent, renderedBadge.greenComponent + 0.30)
        XCTAssertGreaterThan(renderedBadge.blueComponent, renderedBadge.greenComponent + 0.30)
    }

    func testTranslationRendererMovesTrailingBadgeNextToShorterTranslation() throws {
        let size = NSSize(width: 300, height: 100)
        let source = NSImage(size: size)
        source.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
        NSColor.magenta.setFill()
        NSBezierPath(
            roundedRect: CGRect(x: 220, y: 50, width: 34, height: 20),
            xRadius: 8,
            yRadius: 8
        ).fill()
        NSColor.blue.setFill()
        NSBezierPath(rect: CGRect(x: 205, y: 50, width: 4, height: 20)).fill()
        source.unlockFocus()

        let pickedImage = PickedImage(
            data: Data(),
            mimeType: "image/png",
            fileName: "movable-badge.png",
            image: source
        )
        let block = ImageTranslationBlock(
            text: "研究资料",
            x: 0.32,
            y: 0.30,
            width: 0.50,
            height: 0.20,
            lineRects: [
                ImageTranslationLineRect(x: 0.32, y: 0.30, width: 0.50, height: 0.20)
            ],
            textRects: [
                ImageTranslationLineRect(x: 0.32, y: 0.30, width: 0.50, height: 0.20)
            ],
            protectedRects: [
                ImageTranslationLineRect(x: 0.72, y: 0.30, width: 0.14, height: 0.20)
            ],
            trailingAttachments: [
                ImageTranslationLineRect(x: 0.72, y: 0.30, width: 0.14, height: 0.20)
            ],
            translationStrategy: .selective,
            textColor: "#0066cc",
            backgroundColor: "#ffffff",
            alignment: "left",
            fontSize: 0.12
        )

        let sourceBitmap = try XCTUnwrap(displayBitmap(for: source, size: size))
        let oldBadgePoint = try XCTUnwrap(firstPixel(in: sourceBitmap) { color in
            color.redComponent > color.greenComponent + 0.30
                && color.blueComponent > color.greenComponent + 0.30
        })
        let rendered = try XCTUnwrap(ImageTranslationRenderer.render(
            source: pickedImage,
            blocks: [block]
        ))
        let renderedBitmap = try XCTUnwrap(displayBitmap(for: rendered, size: size))
        let movedBadgePoint = try XCTUnwrap(firstPixel(in: renderedBitmap) { color in
            color.redComponent > color.greenComponent + 0.30
                && color.blueComponent > color.greenComponent + 0.30
        })
        let oldLocationColor = try XCTUnwrap(
            renderedBitmap.colorAt(x: oldBadgePoint.x, y: oldBadgePoint.y)?.usingColorSpace(.sRGB)
        )
        let oldCorridorColor = try XCTUnwrap(
            renderedBitmap.colorAt(x: 206, y: oldBadgePoint.y)?.usingColorSpace(.sRGB)
        )

        XCTAssertLessThan(movedBadgePoint.x, oldBadgePoint.x - 20)
        XCTAssertGreaterThan(oldLocationColor.redComponent, 0.95)
        XCTAssertGreaterThan(oldLocationColor.greenComponent, 0.95)
        XCTAssertGreaterThan(oldLocationColor.blueComponent, 0.95)
        XCTAssertGreaterThan(oldCorridorColor.redComponent, 0.95)
        XCTAssertGreaterThan(oldCorridorColor.greenComponent, 0.95)
        XCTAssertGreaterThan(oldCorridorColor.blueComponent, 0.95)
    }

    func testBlockRendererDoesNotProtectNaturalTextAfterCodeChip() throws {
        let size = NSSize(width: 300, height: 100)
        let source = NSImage(size: size)
        source.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
        NSColor(calibratedWhite: 0.72, alpha: 1).setFill()
        NSBezierPath(roundedRect: CGRect(x: 20, y: 50, width: 136, height: 20), xRadius: 5, yRadius: 5).fill()
        NSColor.red.setFill()
        NSBezierPath(rect: CGRect(x: 160, y: 50, width: 100, height: 20)).fill()
        source.unlockFocus()

        let block = ImageTranslationBlock(
            text: "`ConversationSession` 拥有轮次",
            x: 0.06,
            y: 0.30,
            width: 0.82,
            height: 0.20,
            lineRects: [
                ImageTranslationLineRect(x: 0.06, y: 0.30, width: 0.82, height: 0.20)
            ],
            textRects: [
                ImageTranslationLineRect(x: 0.06, y: 0.30, width: 0.40, height: 0.20),
                ImageTranslationLineRect(x: 0.53, y: 0.30, width: 0.33, height: 0.20)
            ],
            protectedRects: [
                ImageTranslationLineRect(x: 0.53, y: 0.30, width: 0.33, height: 0.20)
            ],
            translationStrategy: .block,
            codeRects: [
                ImageTranslationTokenRect(
                    text: "ConversationSession",
                    x: 0.06,
                    y: 0.30,
                    width: 0.40,
                    height: 0.20
                )
            ],
            textColor: "#0000ff",
            backgroundColor: "#ffffff",
            alignment: "left",
            fontSize: 0.12
        )
        let pickedImage = PickedImage(
            data: Data(),
            mimeType: "image/png",
            fileName: "code-followed-by-prose.png",
            image: source
        )

        let rendered = try XCTUnwrap(ImageTranslationRenderer.render(
            source: pickedImage,
            blocks: [block]
        ))
        let bitmap = try XCTUnwrap(displayBitmap(for: rendered, size: size))
        let redRemainder = firstPixel(in: bitmap) { color in
            color.redComponent > 0.90
                && color.greenComponent < 0.20
                && color.blueComponent < 0.20
        }
        let redrawnChipPixel = firstPixel(in: bitmap) { color in
            let channels = [color.redComponent, color.greenComponent, color.blueComponent]
            return channels.allSatisfy { (0.52...0.94).contains($0) }
                && max(
                    abs(color.redComponent - color.greenComponent),
                    abs(color.greenComponent - color.blueComponent)
                ) < 0.04
        }

        XCTAssertNil(redRemainder)
        XCTAssertNotNil(redrawnChipPixel)
    }

    func testTranslationRendererAnchorsShortTranslationToFirstSourceLine() throws {
        let size = NSSize(width: 220, height: 120)
        let source = NSImage(size: size)
        source.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
        NSColor.red.setFill()
        NSBezierPath(rect: CGRect(x: 24, y: 74, width: 170, height: 18)).fill()
        NSBezierPath(rect: CGRect(x: 24, y: 30, width: 140, height: 18)).fill()
        source.unlockFocus()

        let block = ImageTranslationBlock(
            text: "短译文",
            x: 0.10,
            y: 0.23,
            width: 0.78,
            height: 0.52,
            lineRects: [
                ImageTranslationLineRect(x: 0.10, y: 0.23, width: 0.78, height: 0.15),
                ImageTranslationLineRect(x: 0.10, y: 0.60, width: 0.64, height: 0.15)
            ],
            textColor: "#0000ff",
            backgroundColor: "#ffffff",
            alignment: "left",
            fontSize: 0.10
        )
        let pickedImage = PickedImage(
            data: Data(),
            mimeType: "image/png",
            fileName: "short-top-aligned-translation.png",
            image: source
        )

        let rendered = try XCTUnwrap(ImageTranslationRenderer.render(
            source: pickedImage,
            blocks: [block]
        ))
        let bitmap = try XCTUnwrap(displayBitmap(for: rendered, size: size))
        var translatedRows: [Int] = []
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                    continue
                }
                if color.blueComponent > 0.65,
                   color.blueComponent > color.redComponent + 0.30,
                   color.blueComponent > color.greenComponent + 0.30 {
                    translatedRows.append(y)
                }
            }
        }

        XCTAssertFalse(translatedRows.isEmpty)
        let backingScale = CGFloat(bitmap.pixelsHigh) / size.height
        XCTAssertGreaterThanOrEqual(
            CGFloat(translatedRows.min() ?? 0),
            25 * backingScale
        )
        XCTAssertLessThan(
            CGFloat(translatedRows.max() ?? bitmap.pixelsHigh),
            48 * backingScale
        )
    }

    func testTranslationRendererReturnsHighlightRectsFromActualGlyphLayout() throws {
        let size = NSSize(width: 420, height: 240)
        let source = NSImage(size: size)
        source.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
        source.unlockFocus()
        let sourceData = try XCTUnwrap(source.tiffRepresentation)
        let block = ImageTranslationBlock(
            sourceID: "r001",
            text: "该系统能够同时远程监测多名用户的健康信息，同时为每位用户提供数字医生并按需监测其健康状态。",
            x: 0.08,
            y: 0.10,
            width: 0.84,
            height: 0.70,
            lineRects: (0..<7).map { index in
                ImageTranslationLineRect(
                    x: 0.08,
                    y: 0.10 + Double(index) * 0.09,
                    width: 0.84,
                    height: 0.075
                )
            },
            textColor: "#0000ff",
            backgroundColor: "#ffffff",
            alignment: "left",
            fontSize: 0.065
        )
        let pair = ImageTranslationHighlightPair(
            id: "r001-a0",
            sourceID: "r001",
            targetText: "按需监测其健康状态",
            sourceRects: [],
            translatedRects: []
        )

        let result = try XCTUnwrap(ImageTranslationRenderer.renderDataWithHighlights(
            sourceData: sourceData,
            blocks: [block],
            highlightPairs: [pair]
        ))
        let rects = try XCTUnwrap(result.translatedHighlightRects[pair.id])
        XCTAssertFalse(rects.isEmpty)

        let renderedImage = try XCTUnwrap(NSImage(data: result.data))
        let bitmap = try XCTUnwrap(displayBitmap(for: renderedImage, size: size))
        let overlapsRenderedText = rects.contains { rect in
            let minimumX = max(0, Int(rect.minX * CGFloat(bitmap.pixelsWide)))
            let maximumX = min(bitmap.pixelsWide, Int(ceil(rect.maxX * CGFloat(bitmap.pixelsWide))))
            let minimumY = max(0, Int(rect.minY * CGFloat(bitmap.pixelsHigh)))
            let maximumY = min(bitmap.pixelsHigh, Int(ceil(rect.maxY * CGFloat(bitmap.pixelsHigh))))
            guard minimumX < maximumX, minimumY < maximumY else { return false }
            for y in minimumY..<maximumY {
                for x in minimumX..<maximumX {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                        continue
                    }
                    if color.blueComponent > color.redComponent + 0.30,
                       color.blueComponent > color.greenComponent + 0.30 {
                        return true
                    }
                }
            }
            return false
        }
        var blueBounds = CGRect.null
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      color.blueComponent > color.redComponent + 0.30,
                      color.blueComponent > color.greenComponent + 0.30
                else { continue }
                blueBounds = blueBounds.union(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        XCTAssertTrue(
            overlapsRenderedText,
            "Highlight rects \(rects) did not overlap rendered blue bounds \(blueBounds)"
        )
    }

    func testTranslationRendererHarmonizesNearWhiteErasePatches() throws {
        let size = NSSize(width: 200, height: 100)
        let pageColor = NSColor(calibratedWhite: 0.98, alpha: 1)
        let source = NSImage(size: size)
        source.lockFocus()
        pageColor.setFill()
        NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
        NSColor.red.setFill()
        NSBezierPath(rect: CGRect(x: 20, y: 40, width: 160, height: 20)).fill()
        source.unlockFocus()

        let block = ImageTranslationBlock(
            text: "译",
            x: 0.10,
            y: 0.40,
            width: 0.80,
            height: 0.20,
            lineRects: [
                ImageTranslationLineRect(x: 0.10, y: 0.40, width: 0.80, height: 0.20)
            ],
            textColor: "#0000ff",
            backgroundColor: "#f8f8f8",
            alignment: "left",
            fontSize: 0.12
        )
        let pickedImage = PickedImage(
            data: Data(),
            mimeType: "image/png",
            fileName: "near-white-background.png",
            image: source
        )

        let rendered = try XCTUnwrap(ImageTranslationRenderer.render(
            source: pickedImage,
            blocks: [block]
        ))
        let bitmap = try XCTUnwrap(displayBitmap(for: rendered, size: size))
        let patchColor = try XCTUnwrap(bitmap.colorAt(x: 150, y: 50)?.usingColorSpace(.sRGB))

        XCTAssertEqual(patchColor.redComponent, 0.98, accuracy: 0.02)
        XCTAssertEqual(patchColor.greenComponent, 0.98, accuracy: 0.02)
        XCTAssertEqual(patchColor.blueComponent, 0.98, accuracy: 0.02)
    }

    func testTranslationRendererUsesSourcePixelsInsteadOfApproximateDarkMetadata() throws {
        let size = NSSize(width: 220, height: 100)
        let pageColor = NSColor(
            srgbRed: 13.0 / 255.0,
            green: 17.0 / 255.0,
            blue: 23.0 / 255.0,
            alpha: 1
        )
        let source = NSImage(size: size)
        source.lockFocus()
        pageColor.setFill()
        NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
        NSColor.red.setFill()
        NSBezierPath(rect: CGRect(x: 18, y: 40, width: 184, height: 20)).fill()
        source.unlockFocus()

        let block = ImageTranslationBlock(
            text: "深色背景翻译",
            x: 0.08,
            y: 0.40,
            width: 0.84,
            height: 0.20,
            lineRects: [
                ImageTranslationLineRect(x: 0.08, y: 0.40, width: 0.84, height: 0.20)
            ],
            textColor: "#ffffff",
            backgroundColor: "#162232",
            alignment: "left",
            fontSize: 0.12
        )
        let pickedImage = PickedImage(
            data: Data(),
            mimeType: "image/png",
            fileName: "dark-background-metadata.png",
            image: source
        )

        let rendered = try XCTUnwrap(ImageTranslationRenderer.render(
            source: pickedImage,
            blocks: [block]
        ))
        let sourceBitmap = try XCTUnwrap(displayBitmap(for: source, size: size))
        let bitmap = try XCTUnwrap(displayBitmap(for: rendered, size: size))
        let backingScale = CGFloat(bitmap.pixelsHigh) / size.height
        let sampleX = Int(190 * backingScale)
        let sourceBackgroundColor = try XCTUnwrap(
            sourceBitmap.colorAt(
                x: sampleX,
                y: Int(20 * backingScale)
            )?.usingColorSpace(.sRGB)
        )
        let patchColor = try XCTUnwrap(
            bitmap.colorAt(
                x: sampleX,
                y: Int(50 * backingScale)
            )?.usingColorSpace(.sRGB)
        )

        XCTAssertEqual(patchColor.redComponent, sourceBackgroundColor.redComponent, accuracy: 0.012)
        XCTAssertEqual(patchColor.greenComponent, sourceBackgroundColor.greenComponent, accuracy: 0.012)
        XCTAssertEqual(patchColor.blueComponent, sourceBackgroundColor.blueComponent, accuracy: 0.012)
    }

    func testTrailingBadgeGapDoesNotDependOnBadgeWidth() throws {
        let size = NSSize(width: 300, height: 120)
        let source = NSImage(size: size)
        source.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
        NSColor.magenta.setFill()
        NSBezierPath(roundedRect: CGRect(x: 220, y: 78, width: 34, height: 18), xRadius: 8, yRadius: 8).fill()
        NSColor.green.setFill()
        NSBezierPath(roundedRect: CGRect(x: 220, y: 24, width: 20, height: 18), xRadius: 8, yRadius: 8).fill()
        source.unlockFocus()

        let first = ImageTranslationBlock(
            text: "研究主页",
            x: 0.25,
            y: 0.20,
            width: 0.60,
            height: 0.15,
            lineRects: [ImageTranslationLineRect(x: 0.25, y: 0.20, width: 0.60, height: 0.15)],
            textRects: [ImageTranslationLineRect(x: 0.25, y: 0.20, width: 0.60, height: 0.15)],
            trailingAttachments: [ImageTranslationLineRect(x: 0.733, y: 0.20, width: 0.113, height: 0.15)],
            translationStrategy: .selective,
            textColor: "#0066cc",
            backgroundColor: "#ffffff",
            alignment: "left",
            fontSize: 0.10
        )
        let second = ImageTranslationBlock(
            text: "研究主页",
            x: 0.25,
            y: 0.65,
            width: 0.55,
            height: 0.15,
            lineRects: [ImageTranslationLineRect(x: 0.25, y: 0.65, width: 0.55, height: 0.15)],
            textRects: [ImageTranslationLineRect(x: 0.25, y: 0.65, width: 0.55, height: 0.15)],
            trailingAttachments: [ImageTranslationLineRect(x: 0.733, y: 0.65, width: 0.067, height: 0.15)],
            translationStrategy: .selective,
            textColor: "#0066cc",
            backgroundColor: "#ffffff",
            alignment: "left",
            fontSize: 0.10
        )
        let pickedImage = PickedImage(
            data: Data(),
            mimeType: "image/png",
            fileName: "badge-widths.png",
            image: source
        )

        let rendered = try XCTUnwrap(ImageTranslationRenderer.render(
            source: pickedImage,
            blocks: [first, second]
        ))
        let bitmap = try XCTUnwrap(displayBitmap(for: rendered, size: size))
        let wideBadge = try XCTUnwrap(leftmostPixel(in: bitmap) { color in
            color.redComponent > 0.75
                && color.blueComponent > 0.75
                && color.greenComponent < 0.35
        })
        let narrowBadge = try XCTUnwrap(leftmostPixel(in: bitmap) { color in
            color.greenComponent > 0.55
                && color.greenComponent > color.redComponent + 0.30
                && color.greenComponent > color.blueComponent + 0.30
        })

        let backingScale = CGFloat(bitmap.pixelsWide) / size.width
        XCTAssertLessThanOrEqual(
            CGFloat(abs(wideBadge.x - narrowBadge.x)),
            backingScale
        )
    }

    private func makeImage(name: String, byte: UInt8) -> PickedImage {
        PickedImage(
            data: Data([byte]),
            mimeType: "image/png",
            fileName: name,
            image: NSImage(size: NSSize(width: 1, height: 1))
        )
    }

    private func largestScrollableView(in rootView: NSView?) -> NSScrollView? {
        guard let rootView else { return nil }

        let candidates = ([rootView] + rootView.descendants)
            .compactMap { $0 as? NSScrollView }
            .filter { scrollView in
                guard let documentView = scrollView.documentView else { return false }
                return documentView.bounds.height > scrollView.contentView.bounds.height + 1
            }

        return candidates.max { lhs, rhs in
            let lhsOverflow = (lhs.documentView?.bounds.height ?? 0) - lhs.contentView.bounds.height
            let rhsOverflow = (rhs.documentView?.bounds.height ?? 0) - rhs.contentView.bounds.height
            return lhsOverflow < rhsOverflow
        }
    }

    private func sendWheelEvent(deltaY: CGFloat, at location: NSPoint, through hitView: NSView) {
        guard let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: Int32(deltaY),
            wheel2: 0,
            wheel3: 0
        ) else {
            XCTFail("Could not create a wheel event.")
            return
        }

        cgEvent.location = hitView.window?.convertPoint(toScreen: location) ?? location
        guard let event = NSEvent(cgEvent: cgEvent) else {
            XCTFail("Could not bridge the wheel event to AppKit.")
            return
        }

        XCTAssertEqual(event.type, .scrollWheel)
        XCTAssertNotEqual(event.scrollingDeltaY, 0)
        hitView.scrollWheel(with: event)
    }

    private func firstPixel(
        in bitmap: NSBitmapImageRep,
        matching predicate: (NSColor) -> Bool
    ) -> (x: Int, y: Int)? {
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard
                    let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                    predicate(color)
                else {
                    continue
                }
                return (x, y)
            }
        }
        return nil
    }

    private func leftmostPixel(
        in bitmap: NSBitmapImageRep,
        matching predicate: (NSColor) -> Bool
    ) -> (x: Int, y: Int)? {
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard
                    let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                    predicate(color)
                else {
                    continue
                }
                return (x, y)
            }
        }
        return nil
    }

    private func displayBitmap(for image: NSImage, size: NSSize) -> NSBitmapImageRep? {
        let displayImage = NSImage(size: size)
        displayImage.lockFocus()
        image.draw(
            in: CGRect(origin: .zero, size: size),
            from: CGRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1
        )
        displayImage.unlockFocus()

        var rect = CGRect(origin: .zero, size: size)
        guard let cgImage = displayImage.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return nil
        }
        return NSBitmapImageRep(cgImage: cgImage)
    }

    private func makeTemporaryHistoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MarrHistoryTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func imageCount(in message: VisionMessage) -> Int {
        message.content.reduce(into: 0) { count, content in
            if case .image = content { count += 1 }
        }
    }

    private func fileCount(in message: VisionMessage?) -> Int {
        message?.content.reduce(into: 0) { count, content in
            if case .file = content { count += 1 }
        } ?? 0
    }

    private func text(in message: VisionMessage) -> String? {
        message.content.compactMap { content in
            if case .text(let value) = content { return value }
            return nil
        }.last
    }
}

private extension NSView {
    var descendants: [NSView] {
        subviews + subviews.flatMap(\.descendants)
    }
}

private struct AnswerPanelTestClient: VisionAIClient {
    func ask(
        request: VisionRequest,
        model: String,
        connection: InferenceConnection
    ) async throws -> String {
        "Unused in the completed-session fixture."
    }
}

@MainActor
final class AnswerPanelResizeTests: XCTestCase {
    func testSideGripsLeaveTheContentAndNativeCornerResizeAreasAvailable() {
        let bounds = CGRect(x: 0, y: 0, width: 420, height: 596)
        XCTAssertEqual(AnswerPanelResizeGeometry.edge(at: CGPoint(x: 0, y: 100), in: bounds), .left)
        XCTAssertEqual(AnswerPanelResizeGeometry.edge(at: CGPoint(x: 7.9, y: 100), in: bounds), .left)
        XCTAssertEqual(AnswerPanelResizeGeometry.edge(at: CGPoint(x: 412, y: 100), in: bounds), .right)
        XCTAssertEqual(AnswerPanelResizeGeometry.edge(at: CGPoint(x: 419.9, y: 100), in: bounds), .right)
        for point in [CGPoint(x: 8, y: 100), CGPoint(x: 411.9, y: 100), CGPoint(x: 200, y: 100),
                      CGPoint(x: 4, y: 23), CGPoint(x: 416, y: 573),
                      CGPoint(x: -1, y: 100), CGPoint(x: 421, y: 100)] {
            XCTAssertNil(AnswerPanelResizeGeometry.edge(at: point, in: bounds), "Unexpected resize grip at \(point)")
        }
    }

    func testBothSidesKeepTheOppositeEdgeFixedAndRespectWindowSizeLimits() {
        let initialFrame = CGRect(x: 100, y: 200, width: 520, height: 596)
        let cases: [(AnswerPanelResizeEdge, CGFloat, CGFloat)] = [
            (.left, -80, 600), (.left, 300, 420), (.left, -500, 800),
            (.right, 80, 600), (.right, -300, 420), (.right, 500, 800)
        ]
        for (edge, translation, expectedWidth) in cases {
            let frame = AnswerPanelResizeGeometry.frame(
                startingAt: initialFrame, edge: edge, screenTranslationX: translation,
                minimumWidth: 420, maximumWidth: 800
            )
            XCTAssertEqual(frame.width, expectedWidth)
            XCTAssertEqual(frame.minY, initialFrame.minY)
            XCTAssertEqual(frame.height, initialFrame.height)
            if edge == .left {
                XCTAssertEqual(frame.maxX, initialFrame.maxX)
            } else {
                XCTAssertEqual(frame.minX, initialFrame.minX)
            }
        }
    }

    func testReturningFromTheMinimumSizeUsesTheOriginalScreenDragAnchor() {
        let initialFrame = CGRect(x: -120, y: 80, width: 520, height: 700)
        let clamped = AnswerPanelResizeGeometry.frame(
            startingAt: initialFrame, edge: .left, screenTranslationX: 250,
            minimumWidth: 420, maximumWidth: 1_000
        )
        XCTAssertEqual(clamped, CGRect(x: -20, y: 80, width: 420, height: 700))
        let returned = AnswerPanelResizeGeometry.frame(
            startingAt: initialFrame, edge: .left, screenTranslationX: 30,
            minimumWidth: 420, maximumWidth: 1_000
        )
        XCTAssertEqual(returned, CGRect(x: -90, y: 80, width: 490, height: 700))
        let restored = AnswerPanelResizeGeometry.frame(
            startingAt: initialFrame, edge: .left, screenTranslationX: 0,
            minimumWidth: 420, maximumWidth: 1_000
        )
        XCTAssertEqual(restored, initialFrame)
    }

    func testResizeOverlayPassesScrollingContextMenusAndNativeControlsThrough() {
        let hostedView = NSView(frame: .zero)
        let container = AnswerPanelContentView(
            frame: CGRect(x: 0, y: 0, width: 420, height: 596), hostedView: hostedView
        )
        let overlay = container.resizeOverlay
        let gripPoint = CGPoint(x: 4, y: 100)
        XCTAssertTrue(overlay.hitTarget(at: gripPoint, eventType: .leftMouseDown) === overlay)
        XCTAssertNil(overlay.hitTarget(at: gripPoint, eventType: .scrollWheel))
        XCTAssertNil(overlay.hitTarget(at: gripPoint, eventType: .rightMouseDown))
        XCTAssertNil(overlay.hitTarget(at: CGPoint(x: 200, y: 100), eventType: .leftMouseDown))

        let button = NSButton(frame: CGRect(x: 0, y: 80, width: 40, height: 40))
        hostedView.addSubview(button)
        XCTAssertNil(overlay.hitTarget(at: gripPoint, eventType: .leftMouseDown))
        XCTAssertTrue(container.hitTest(gripPoint) === button)

        let scroller = NSScroller(frame: CGRect(x: 405, y: 40, width: 15, height: 500))
        hostedView.addSubview(scroller)
        XCTAssertNil(overlay.hitTarget(at: CGPoint(x: 416, y: 200), eventType: .leftMouseDown))

        let textView = NSTextView(frame: CGRect(x: 0, y: 180, width: 60, height: 60))
        hostedView.addSubview(textView)
        XCTAssertNil(overlay.hitTarget(at: CGPoint(x: 4, y: 200), eventType: .leftMouseDown))
    }

    func testHostingAndResizeGripsFollowTheWindowContentSize() {
        let hostedView = NSView(frame: .zero)
        let container = AnswerPanelContentView(
            frame: CGRect(x: 0, y: 0, width: 420, height: 596), hostedView: hostedView
        )
        container.setFrameSize(CGSize(width: 680, height: 760))
        XCTAssertEqual(hostedView.frame, container.bounds)
        XCTAssertEqual(container.resizeOverlay.frame, container.bounds)
        XCTAssertNil(container.resizeOverlay.hitTarget(at: CGPoint(x: 416, y: 100), eventType: .leftMouseDown))
        XCTAssertTrue(container.resizeOverlay.hitTarget(at: CGPoint(x: 676, y: 100), eventType: .leftMouseDown) === container.resizeOverlay)
    }
}

@MainActor
final class HistoryFailurePresentationTests: XCTestCase {
    func testHistoryReadFailuresRemainVisibleAndReloadRecoversWithoutLosingCachedRecords() async throws {
        try MarrUITestSupport.requireVisibleWindows()
        for hasCachedRecord in [false, true] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("Marr-HistoryFailure-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let historyResources = MarrHistoryTestResources(rootURL: root)
            addTeardownBlock { try await historyResources.cleanUp() }
            let blockedHistoryDirectory = root.appendingPathComponent("History")
            // A file where a directory belongs gives a real, reversible read
            // failure without changing any database contents.
            if !hasCachedRecord { try Data("fixture".utf8).write(to: blockedHistoryDirectory) }
            let store = historyResources.makeStore()
            await store.waitForPendingOperations()
            let recordID = UUID()
            if hasCachedRecord {
                store.save(ConversationArchive(id: recordID, createdAt: Date(), updatedAt: Date(),
                    generatedTitle: "Keep this conversation", turns: [], images: [], pendingImageIDs: []))
                await store.waitForPendingOperations()
                XCTAssertEqual(store.conversations.map(\.id), [recordID])
                try Data("fixture".utf8).write(to: blockedHistoryDirectory)
                store.reload()
                await store.waitForPendingOperations()
            }
            XCTAssertNotNil(store.lastErrorMessage)
            XCTAssertEqual(store.conversations.map(\.id), hasCachedRecord ? [recordID] : [])
            let controller = MarrController(client: AnswerPanelTestClient(), historyStore: store,
                tokenUsageStore: TokenUsageStore(rootURL: root.appendingPathComponent("Usage")),
                settingsRepository: InferenceSettingsRepository(
                    values: TranslationRoutingValues(), secrets: TranslationRoutingSecrets(credentials: nil)))
            let compact = try window(
                AnswerPanelHistoryView(store: store, currentConversationID: UUID(),
                    searchText: .constant(""), onOpen: { _ in }),
                width: 420
            )
            let full = try window(HistoryView(controller: controller), width: 640)
            defer { compact.close(); full.close() }
            await settle([compact, full])
            await store.waitForPendingOperations()
            await settle([compact, full])
            var retryPoint: NSPoint?
            let retryWindow = hasCachedRecord ? full : compact
            for (name, window) in [("compact", compact), ("full", full)] {
                let observations = try renderedText(window, attachmentName: "history-error-\(name)-\(hasCachedRecord)")
                let text = observations.map(\.text).joined(separator: " ")
                XCTAssertTrue(text.contains("History needs attention"), text)
                XCTAssertTrue(text.contains("Could not load conversation history"), text)
                XCTAssertFalse(text.localizedCaseInsensitiveContains("No history"), text)
                if hasCachedRecord {
                    XCTAssertTrue(text.contains("Keep this conversation"), text)
                    XCTAssertTrue(text.contains("previously loaded"), text)
                }
                if window === retryWindow {
                    let retry = try XCTUnwrap(observations.first { $0.text.contains("Reload history") }, text)
                    retryPoint = NSPoint(x: retry.bounds.midX * window.contentLayoutRect.width,
                        y: retry.bounds.midY * window.contentLayoutRect.height)
                }
            }

            try FileManager.default.removeItem(at: blockedHistoryDirectory)
            let point = try XCTUnwrap(retryPoint)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                retryWindow.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point,
                    modifierFlags: [], timestamp: 0, windowNumber: retryWindow.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1)))
            }
            await settle([compact, full])
            await store.waitForPendingOperations()
            await settle([compact, full])
            XCTAssertNil(store.lastErrorMessage, "Reload history must retry the failed read")
            XCTAssertEqual(store.conversations.map(\.id), hasCachedRecord ? [recordID] : [])
            for (name, window) in [("compact", compact), ("full", full)] {
                let text = try renderedText(window, attachmentName: "history-recovered-\(name)-\(hasCachedRecord)")
                    .map(\.text).joined(separator: " ")
                XCTAssertFalse(text.contains("History needs attention"), text)
                XCTAssertFalse(text.contains("Reload history"), text)
                XCTAssertTrue(hasCachedRecord ? text.contains("Keep this conversation")
                    : text.localizedCaseInsensitiveContains("No history"), text)
            }
        }
    }

    private func window<Content: View>(_ content: Content, width: CGFloat) throws -> NSWindow {
        try MarrUITestSupport.requireVisibleWindows()
        let hosting = NSHostingView(rootView: content.padding(16).environment(\.colorScheme, .light)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: 596),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        window.orderFront(nil)
        return window
    }

    private func settle(_ windows: [NSWindow]) async {
        try? await Task.sleep(for: .milliseconds(150))
        for window in windows {
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
        }
    }

    private func renderedText(_ window: NSWindow, attachmentName: String) throws -> [(text: String, bounds: CGRect)] {
        let view = try XCTUnwrap(window.contentView)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
            uniformTypeIdentifier: "public.png")
        attachment.name = attachmentName
        attachment.lifetime = .keepAlways
        add(attachment)
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["en-US"]
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: try XCTUnwrap(bitmap.cgImage)).perform([request])
        return (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map { ($0.string, observation.boundingBox) }
        }
    }
}

@MainActor
final class CaptureSettingsTests: XCTestCase {
    func testCapturePanelSupportsOtherApplicationsFullScreenSpacesWithoutActivation() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let panel = ScreenshotOverlayPanel.make(on: screen)
        defer { panel.close() }

        // Area capture uses this native panel. A regular NSWindow
        // plus fullScreenAuxiliary alone cannot cover another app's full-screen
        // Space when Marr is a Dock app with its main window on another Space.
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllApplications))
        XCTAssertFalse(panel.collectionBehavior.contains(.moveToActiveSpace))
        XCTAssertFalse(panel.collectionBehavior.contains(.primary))
        XCTAssertFalse(panel.collectionBehavior.contains(.auxiliary))
        XCTAssertFalse(panel.hidesOnDeactivate, "Capture must remain visible while the source app stays active")
        XCTAssertTrue(panel.canBecomeKey, "Escape, Return and the question field still need keyboard input")
        XCTAssertFalse(panel.becomesKeyOnlyIfNeeded)
        XCTAssertFalse(panel.canBecomeMain, "Capture must not replace Marr's main conversation window")
        XCTAssertEqual(panel.level, .screenSaver)
        XCTAssertEqual(panel.frame, screen.frame)
        XCTAssertFalse(panel.isVisible, "The quiet regression test must not cover the user's desktop")
    }

    func testRecorderRejectsConflictBeforePersistenceAndAcceptsDifferentShortcut() throws {
        let suite = "Marr.CaptureShortcutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(kVK_ANSI_0, forKey: "keyCode")
        defaults.set(Int(cmdKey | shiftKey), forKey: "modifiers")
        var writes = 0
        var saves = 0
        var validation: String?
        let keyBinding = Binding<Int>(
            get: { defaults.integer(forKey: "keyCode") },
            set: { writes += 1; defaults.set($0, forKey: "keyCode") }
        )
        let modifierBinding = Binding<Int>(
            get: { defaults.integer(forKey: "modifiers") },
            set: { writes += 1; defaults.set($0, forKey: "modifiers") }
        )
        func root(conflictingKeyCode: Int) -> HotKeyRecorder {
            HotKeyRecorder(keyCode: keyBinding, modifiers: modifierBinding,
                conflictingKeyCode: conflictingKeyCode, conflictingModifiers: Int(cmdKey | shiftKey),
                conflictingAction: "Another action", onValidation: { validation = $0 }, onChange: { saves += 1 })
        }
        let hosting = NSHostingView(rootView: root(conflictingKeyCode: kVK_ANSI_9))
        let window = MarrOffscreenTestWindow(contentRect: NSRect(x: 0, y: 0, width: 170, height: 40),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        let recorder = try XCTUnwrap(findRecorder(in: hosting))

        recorder.performClick(nil)
        recorder.keyDown(with: try event(keyCode: kVK_ANSI_9, characters: "9"))
        XCTAssertEqual(defaults.integer(forKey: "keyCode"), kVK_ANSI_0)
        XCTAssertEqual(defaults.integer(forKey: "modifiers"), Int(cmdKey | shiftKey))
        XCTAssertEqual(writes, 0, "Neither persisted field may change before conflict validation")
        XCTAssertEqual(saves, 0, "A rejected shortcut must not re-register global capture keys")
        XCTAssertTrue(try XCTUnwrap(validation).contains("Another action"))
        XCTAssertEqual(recorder.title, "⇧⌘0", "The recorder must continue to display the prior shortcut")

        recorder.performClick(nil)
        recorder.keyDown(with: try event(keyCode: kVK_ANSI_8, characters: "8"))
        XCTAssertEqual(defaults.integer(forKey: "keyCode"), kVK_ANSI_8)
        XCTAssertEqual(saves, 1)
        XCTAssertNil(validation, "A valid replacement clears the conflict")

        // The second recorder can change while the first remains mounted.
        // A stale makeNSView callback must not validate against its old chord.
        hosting.rootView = root(conflictingKeyCode: kVK_ANSI_7)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        recorder.performClick(nil)
        recorder.keyDown(with: try event(keyCode: kVK_ANSI_7, characters: "7"))
        XCTAssertEqual(defaults.integer(forKey: "keyCode"), kVK_ANSI_8)
        XCTAssertEqual(saves, 1)
        XCTAssertNotNil(validation)
        XCTAssertFalse(window.isVisible)
    }

    func testAreaShortcutCanUseFormerWindowShortcutWithoutConflict() throws {
        var keyCode = kVK_ANSI_0
        var modifiers = Int(cmdKey | shiftKey)
        var saves = 0
        var validation: String? = "Previous error"
        let hosting = NSHostingView(rootView: HotKeyRecorder(
            keyCode: Binding(get: { keyCode }, set: { keyCode = $0 }),
            modifiers: Binding(get: { modifiers }, set: { modifiers = $0 }),
            onValidation: { validation = $0 }, onChange: { saves += 1 }
        ))
        let window = MarrOffscreenTestWindow(contentRect: NSRect(x: 0, y: 0, width: 170, height: 40),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        let recorder = try XCTUnwrap(findRecorder(in: hosting))

        recorder.performClick(nil)
        recorder.keyDown(with: try event(keyCode: kVK_ANSI_9, characters: "9"))

        XCTAssertEqual(keyCode, kVK_ANSI_9)
        XCTAssertEqual(modifiers, Int(cmdKey | shiftKey))
        XCTAssertEqual(saves, 1)
        XCTAssertNil(validation)
        XCTAssertFalse(window.isVisible)
    }

    func testRegisteredCaptureShortcutRecordsWithoutLaunchingCapture() {
        let recorder = HotKeyRecorderView()
        var recorded: [(UInt32, UInt32)] = []
        var captures = 0
        recorder.onRecord = { recorded.append(($0, $1)) }
        let manager = HotKeyManager(keyCode: UInt32(kVK_ANSI_9), modifiers: UInt32(cmdKey | shiftKey),
            identifier: 9_999) { captures += 1 }

        recorder.performClick(nil)
        manager.handleActivation(firstResponder: recorder)
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded.first?.0, UInt32(kVK_ANSI_9))
        XCTAssertEqual(recorded.first?.1, UInt32(cmdKey | shiftKey))
        XCTAssertEqual(captures, 0, "A global shortcut must reach the active recorder instead of opening capture")

        manager.handleActivation(firstResponder: recorder)
        XCTAssertEqual(captures, 1, "A focused button that is no longer recording must not swallow capture")
        manager.handleActivation(firstResponder: nil)
        XCTAssertEqual(captures, 2)
    }

    func testSavedCaptureApplicationRemainsSelectableAfterQuitAndRejoinsOnLaunch() {
        let other = RunningApplicationOption(bundleID: "com.example.other", name: "Other")
        let savedID = "com.example.editor"
        let afterQuit = RunningApplicationOption.includingSavedApplication(
            in: [other], bundleID: savedID, name: "Editor"
        )
        XCTAssertEqual(afterQuit.map(\.bundleID), [savedID, other.bundleID])
        XCTAssertEqual(afterQuit.first?.title, "Editor (Not running)")
        XCTAssertFalse(afterQuit.first?.isRunning ?? true)

        let relaunched = RunningApplicationOption(bundleID: savedID, name: "Editor Pro")
        let afterLaunch = RunningApplicationOption.includingSavedApplication(
            in: [relaunched, other], bundleID: savedID, name: "Editor"
        )
        XCTAssertEqual(afterLaunch.filter { $0.bundleID == savedID }.count, 1)
        XCTAssertEqual(afterLaunch.first?.title, "Editor Pro", "The live app name replaces the saved fallback")
        XCTAssertTrue(afterLaunch.first?.isRunning ?? false)
        XCTAssertEqual(RunningApplicationOption.includingSavedApplication(
            in: [other], bundleID: "", name: ""
        ), [other], "An unset restriction must not create a blank picker item")
        XCTAssertEqual(RunningApplicationOption.includingSavedApplication(
            in: [], bundleID: savedID, name: ""
        ).first?.name, savedID, "Older saved restrictions without a display name still need a visible option")
    }

    private func findRecorder(in view: NSView) -> HotKeyRecorderView? {
        if let recorder = view as? HotKeyRecorderView { return recorder }
        return view.subviews.lazy.compactMap { self.findRecorder(in: $0) }.first
    }

    private func event(keyCode: Int, characters: String) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
            timestamp: 0, windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(keyCode)))
    }
}

@MainActor
final class SettingsNavigationTests: XCTestCase {
    func testMergedSettingsKeepLegacyDeepLinksAndSearchReachable() {
        XCTAssertEqual(MarrSettingsSection.visibleSections, [.general, .conversation, .translation, .work, .usage, .archives, .storage, .advanced])
        let navigation = MarrSettingsNavigation()
        for (old, target): (MarrSettingsSection, MarrSettingsSection) in [(.appearance, .general), (.account, .conversation), (.usage, .usage), (.configuration, .advanced)] {
            navigation.open(old)
            XCTAssertEqual(navigation.selection, target)
        }
        for query in ["theme", "capture", "limits", "sandbox"] {
            XCTAssertTrue(MarrSettingsSearchResult.search(query).allSatisfy { MarrSettingsSection.visibleSections.contains($0.section.navigationSection) })
        }
    }

    func testSettingsSearchFindsFeaturesAcrossAllSixSections() {
        let features: [(String, MarrSettingsSection)] = [
            ("shortcut", .general),
            ("theme", .appearance),
            ("style", .appearance),
            ("models", .conversation),
            ("translate", .translation),
            ("conversation model", .conversation),
            ("translation reasoning", .translation),
            ("app-server", .advanced),
            ("token activity", .usage),
            ("快捷键", .general),
            ("主题", .appearance),
            ("翻译", .translation),
            ("DeepLX", .translation)
        ]
        for (query, section) in features {
            let results = MarrSettingsSearchResult.search(query)
            XCTAssertTrue(results.contains { $0.section == section }, "No destination found for \(query)")
            XCTAssertEqual(Set(results.map(\.id)).count, results.count, "Search results need unique navigation identities")
        }
    }

    func testSettingsSearchNormalizesQueriesAndRequiresEveryTerm() {
        XCTAssertTrue(MarrSettingsSearchResult.search("").isEmpty)
        XCTAssertTrue(MarrSettingsSearchResult.search(" \n\t ").isEmpty)
        let expected = MarrSettingsSearchResult.search("translation model")
        XCTAssertFalse(expected.isEmpty)
        XCTAssertEqual(
            MarrSettingsSearchResult.search("  TrÁnSlÁtiÓn\n\t MODEL  ").map(\.id),
            expected.map(\.id)
        )
        let reasoning = Set(MarrSettingsSearchResult.search("reasoning").map(\.id))
        let translation = Set(MarrSettingsSearchResult.search("translation").map(\.id))
        let combined = MarrSettingsSearchResult.search("translation reasoning")
        XCTAssertFalse(combined.isEmpty)
        XCTAssertTrue(combined.allSatisfy { reasoning.contains($0.id) && translation.contains($0.id) })
        XCTAssertTrue(MarrSettingsSearchResult.search("DeepLX nonexistent-setting-98473").isEmpty)
    }

    func testSettingsBackClearsSearchThenClosesWithoutResettingSelectedTab() {
        let navigation = MarrSettingsNavigation()
        XCTAssertEqual(navigation.selection, .general, "Settings should open directly on General")
        XCTAssertFalse(navigation.back(), "A tab without search should let the parent close settings")
        XCTAssertEqual(navigation.selection, .general)

        navigation.open(.translation)
        navigation.query = "reasoning"
        XCTAssertTrue(navigation.back())
        XCTAssertEqual(navigation.query, "")
        XCTAssertEqual(navigation.selection, .translation, "Clearing search must keep the current tab")

        XCTAssertFalse(navigation.back(), "There is no overview level between the tab and its parent panel")
        XCTAssertEqual(navigation.selection, .translation, "Reopening settings should retain the selected tab")

        for section in MarrSettingsSection.allCases {
            navigation.open(section)
            XCTAssertFalse(navigation.back())
            XCTAssertEqual(navigation.selection, section.navigationSection, "Back must retain every category, not only Translation")
        }
    }

    func testOpeningSettingsSearchResultClearsQueryAndReplacesDestination() throws {
        let navigation = MarrSettingsNavigation()
        navigation.open(.general)
        navigation.query = "DeepLX"
        let result = try XCTUnwrap(MarrSettingsSearchResult.search(navigation.query).first { $0.section == .translation })

        navigation.open(result.section)

        XCTAssertEqual(navigation.selection, .translation)
        XCTAssertEqual(navigation.query, "")
        XCTAssertFalse(navigation.back())
        XCTAssertEqual(navigation.selection, .translation, "Closing after search must retain the destination tab")

        navigation.query = "theme"
        navigation.open(.appearance)
        XCTAssertEqual(navigation.selection, .general)
        XCTAssertEqual(navigation.query, "", "Selecting a tab must dismiss search immediately")
        XCTAssertFalse(navigation.back())
        XCTAssertEqual(navigation.selection, .general)
    }
}

@MainActor
final class TranslationRoutingTests: XCTestCase {
    func testIndependentCodexSelectionIsPersistedAndUsedByTranslationAndProbe() async throws {
        let fixture = TranslationRoutingFixture(
            settings: staleTranslationSettings(),
            codexModels: [translationCodexModel()]
        )
        addTeardownBlock { try await fixture.cleanUp() }
        let controller = fixture.makeController()
        let conversationModel = controller.codexWorkspace.selectedModel
        let conversationEffort = controller.codexWorkspace.selectedReasoningEffort
        XCTAssertEqual(controller.translationCodexModel, "")
        XCTAssertEqual(controller.translationCodexReasoningEffort, "")

        controller.translationCodexModel = "translation-codex"
        controller.translationCodexReasoningEffort = "high"
        // These choices must survive an immediate restart, without a debounce delay.
        let saved = fixture.repository.loadConfiguration()
        XCTAssertEqual(saved.translationCodexModel, "translation-codex")
        XCTAssertEqual(saved.translationCodexReasoningEffort, "high")
        let restored = fixture.makeController()
        XCTAssertEqual(restored.translationCodexModel, "translation-codex")
        XCTAssertEqual(restored.translationCodexReasoningEffort, "high")

        let request = translationRequest()
        let configuration = try await restored.resolvedTranslationConfiguration()
        let result = try await restored.submitTranslation(request: request, configuration: configuration)
        let probe = try await restored.testTranslationConnection()
        XCTAssertEqual(result, TranslationCodexSpy.response)
        XCTAssertEqual(probe, TranslationCodexSpy.response)
        XCTAssertEqual(fixture.codex.calls.count, 2)
        for call in fixture.codex.calls {
            XCTAssertEqual(call.model, "translation-codex")
            XCTAssertEqual(call.effort, "high")
        }
        XCTAssertEqual(fixture.codex.calls.first?.request, request)
        XCTAssertEqual(fixture.codex.calls.last?.request.messages, [
            VisionMessage(role: .user, content: [.text("Hello, world!")])
        ])
        XCTAssertEqual(controller.codexWorkspace.selectedModel, conversationModel)
        XCTAssertEqual(controller.codexWorkspace.selectedReasoningEffort, conversationEffort)
        XCTAssertEqual(restored.codexWorkspace.selectedModel, conversationModel)
        XCTAssertEqual(restored.codexWorkspace.selectedReasoningEffort, conversationEffort)
        XCTAssertTrue(fixture.secrets.readAccounts.isEmpty)
        let requests = await fixture.http.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testIndependentCodexModelUsesItsCatalogDefaultEffort() async throws {
        var settings = staleTranslationSettings()
        settings.translationCodexModel = "translation-codex"
        let fixture = TranslationRoutingFixture(settings: settings, codexModels: [translationCodexModel()])
        addTeardownBlock { try await fixture.cleanUp() }
        let controller = fixture.makeController()
        let conversationEffort = controller.codexWorkspace.selectedReasoningEffort

        _ = try await controller.testTranslationConnection()

        let call = try XCTUnwrap(fixture.codex.calls.first)
        XCTAssertEqual(call.model, "translation-codex")
        XCTAssertEqual(call.effort, "low")
        XCTAssertEqual(controller.translationCodexReasoningEffort, "", "A resolved default must not overwrite the saved automatic choice")
        XCTAssertEqual(controller.codexWorkspace.selectedReasoningEffort, conversationEffort)
    }

    func testInheritedCodexModelCanOverrideTranslationEffortWithoutChangingConversation() async throws {
        var settings = staleTranslationSettings()
        settings.translationCodexReasoningEffort = "high"
        let fixture = TranslationRoutingFixture(settings: settings)
        addTeardownBlock { try await fixture.cleanUp() }
        let controller = fixture.makeController()
        let conversationModel = controller.codexWorkspace.selectedModel
        let conversationEffort = controller.codexWorkspace.selectedReasoningEffort

        _ = try await controller.testTranslationConnection()

        let call = try XCTUnwrap(fixture.codex.calls.first)
        XCTAssertEqual(call.model, conversationModel)
        XCTAssertEqual(call.effort, "high")
        XCTAssertEqual(controller.translationCodexModel, "")
        XCTAssertEqual(controller.codexWorkspace.selectedModel, conversationModel)
        XCTAssertEqual(controller.codexWorkspace.selectedReasoningEffort, conversationEffort)
    }

    func testInvalidCodexTranslationSelectionsBlockTranslationAndProbeWithoutFallback() async throws {
        for selection in [(model: "retired-codex", effort: "", diagnostic: "model"),
                          (model: "translation-codex", effort: "unsupported", diagnostic: "effort")] {
            var settings = staleTranslationSettings()
            settings.translationCodexModel = selection.model
            settings.translationCodexReasoningEffort = selection.effort
            let fixture = TranslationRoutingFixture(settings: settings, codexModels: [translationCodexModel()])
            addTeardownBlock { try await fixture.cleanUp() }
            let controller = fixture.makeController()

            do {
                let configuration = try await controller.resolvedTranslationConfiguration()
                _ = try await controller.submitTranslation(request: translationRequest(), configuration: configuration)
                XCTFail("An invalid Codex selection must stop before inference")
            } catch {
                XCTAssertTrue(error is UserFacingError)
                XCTAssertTrue(controller.userFacingMessage(for: error).contains(selection.diagnostic))
            }
            do {
                _ = try await controller.testTranslationConnection()
                XCTFail("The connection probe must validate the same selection")
            } catch {
                XCTAssertTrue(error is UserFacingError)
                XCTAssertTrue(controller.userFacingMessage(for: error).contains(selection.diagnostic))
            }
            XCTAssertTrue(fixture.codex.calls.isEmpty)
            XCTAssertTrue(fixture.secrets.readAccounts.isEmpty)
            let requests = await fixture.http.requests
            XCTAssertTrue(requests.isEmpty, "Invalid Codex settings must not fall back to an HTTP provider")
        }
    }

    func testDisabledDedicatedTranslationUsesCodexAfterControllerRecreation() async throws {
        let fixture = TranslationRoutingFixture(settings: staleTranslationSettings())
        addTeardownBlock { try await fixture.cleanUp() }
        let request = translationRequest()

        // Recreate the controller from the same persisted configuration, as on restart.
        for _ in 0..<2 {
            let controller = fixture.makeController()
            let configuration = try await controller.resolvedTranslationConfiguration()
            guard case .codex(let model, let effort) = configuration else {
                return XCTFail("Disabled dedicated translation must use the default Codex route")
            }
            XCTAssertEqual(model, controller.codexWorkspace.selectedModel)
            XCTAssertEqual(effort, controller.codexWorkspace.selectedReasoningEffort)

            let result = try await controller.submitTranslation(request: request, configuration: configuration)
            let probe = try await controller.testTranslationConnection()
            XCTAssertEqual(result, TranslationCodexSpy.response)
            XCTAssertEqual(probe, TranslationCodexSpy.response)
        }

        guard fixture.codex.calls.count == 4 else {
            return XCTFail("Both translation and probe must call Codex after each initialization")
        }
        XCTAssertEqual(fixture.codex.calls[0].request, request)
        XCTAssertEqual(fixture.codex.calls[2].request, request)
        XCTAssertEqual(fixture.codex.calls[1].request.messages, [
            VisionMessage(role: .user, content: [.text("Hello, world!")])
        ])
        XCTAssertEqual(fixture.secrets.readAccounts, [])
        let requests = await fixture.http.requests
        XCTAssertTrue(requests.isEmpty, "Neither the stale gateway nor DeepLX may be contacted")
    }

    func testDedicatedAIOverridesCodexWithItsOwnConnection() async throws {
        var settings = staleTranslationSettings()
        settings.translationUsesDedicatedConfiguration = true
        settings.translationProvider = .gateway
        settings.translationGatewayBaseURL = "https://translation.example/v1"
        settings.translationGatewayAuthScheme = .bearer
        settings.translationGatewayAPIFormat = .openAIChatCompletions
        settings.translationModel = "dedicated-translation-model"
        settings.translationCodexModel = "translation-codex"
        settings.translationCodexReasoningEffort = "high"
        let fixture = TranslationRoutingFixture(
            settings: settings,
            credentials: [
                "translation-gateway-api-key": "test-dedicated-key",
                "translation-custom-headers": "X-Translation-Test: dedicated"
            ],
            responseBody: #"{"choices":[{"message":{"role":"assistant","content":"专用 AI 译文"}}]}"#,
            codexModels: [translationCodexModel()]
        )
        addTeardownBlock { try await fixture.cleanUp() }
        let controller = fixture.makeController()
        let configuration = try await controller.resolvedTranslationConfiguration()
        guard case .ai(let model, let connection) = configuration else {
            return XCTFail("An enabled dedicated AI connection must override Codex")
        }
        XCTAssertEqual(model, settings.translationModel)
        XCTAssertEqual(connection.baseURL, settings.translationGatewayBaseURL)
        let result = try await controller.submitTranslation(
            request: translationRequest(), configuration: configuration, requestTimeout: 7
        )
        XCTAssertEqual(result, "专用 AI 译文")
        XCTAssertTrue(fixture.codex.calls.isEmpty)
        XCTAssertEqual(fixture.catalog.loadCount, 0, "A dedicated HTTP connection must not prepare Codex")
        XCTAssertEqual(fixture.secrets.readAccounts, ["translation-gateway-api-key", "translation-custom-headers"])
        let requests = await fixture.http.requests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://translation.example/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-dedicated-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Translation-Test"), "dedicated")
        XCTAssertEqual(request.timeoutInterval, 7)
        let body = try jsonBody(request)
        XCTAssertEqual(body["model"] as? String, settings.translationModel)

        XCTAssertEqual(controller.translationCodexModel, "translation-codex")
        XCTAssertEqual(controller.translationCodexReasoningEffort, "high")
        controller.translationUsesDedicatedConfiguration = false
        let restoredConfiguration = try await controller.resolvedTranslationConfiguration()
        guard case .codex(let restoredModel, let restoredEffort) = restoredConfiguration else {
            return XCTFail("Disabling the HTTP override must restore the independent Codex selection")
        }
        XCTAssertEqual(restoredModel, "translation-codex")
        XCTAssertEqual(restoredEffort, "high")
        let saved = fixture.repository.loadConfiguration()
        XCTAssertEqual(saved.translationCodexModel, "translation-codex")
        XCTAssertEqual(saved.translationCodexReasoningEffort, "high")
    }

    func testDedicatedDeepLXProbeOverridesCodex() async throws {
        var settings = staleTranslationSettings()
        settings.translationUsesDedicatedConfiguration = true
        settings.translationProvider = .deepLX
        settings.translationDeepLXServerURL = "https://translation.example/deeplx"
        let fixture = TranslationRoutingFixture(
            settings: settings,
            credentials: ["translation-deeplx-access-token": "test-deeplx-token"],
            responseBody: #"{"data":"你好，世界！"}"#
        )
        addTeardownBlock { try await fixture.cleanUp() }
        let result = try await fixture.makeController().testTranslationConnection()
        XCTAssertEqual(result, "你好，世界！")
        XCTAssertTrue(fixture.codex.calls.isEmpty)
        XCTAssertEqual(fixture.secrets.readAccounts, ["translation-deeplx-access-token"])
        let requests = await fixture.http.requests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://translation.example/deeplx/translate")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-deeplx-token")
        let body = try jsonBody(request)
        XCTAssertEqual(body["text"] as? String, "Hello, world!")
        XCTAssertEqual(body["target_lang"] as? String, "ZH")
    }

    func testDisabledDedicatedTranslationPreservesLegacyNonCodexRoute() async throws {
        var settings = staleTranslationSettings()
        settings.gatewayBaseURL = "https://legacy.example/v1"
        settings.gatewayAuthScheme = .bearer
        settings.gatewayAPIFormat = .openAIChatCompletions
        settings.model = "legacy-model"
        let fixture = TranslationRoutingFixture(
            settings: settings,
            credentials: ["gateway-api-key": "test-legacy-key"],
            responseBody: #"{"choices":[{"message":{"role":"assistant","content":"旧接口译文"}}]}"#
        )
        addTeardownBlock { try await fixture.cleanUp() }
        let controller = fixture.makeController(usesCodex: false)
        let configuration = try await controller.resolvedTranslationConfiguration()
        guard case .ai(let model, _) = configuration else {
            return XCTFail("The non-Codex integration must retain its standard API")
        }
        XCTAssertEqual(model, "legacy-model")
        let result = try await controller.submitTranslation(request: translationRequest(), configuration: configuration)
        XCTAssertEqual(result, "旧接口译文")
        XCTAssertTrue(fixture.codex.calls.isEmpty)
        XCTAssertEqual(fixture.secrets.readAccounts, ["gateway-api-key", "custom-headers"])
        let requests = await fixture.http.requests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://legacy.example/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-legacy-key")
        XCTAssertEqual(try jsonBody(request)["model"] as? String, "legacy-model")
    }

    func testRepeatedCodexTranslationReusesResponseAcrossDeadlines() async throws {
        let fixture = TranslationRoutingFixture(settings: staleTranslationSettings())
        addTeardownBlock { try await fixture.cleanUp() }
        let controller = fixture.makeController()
        let configuration = try await controller.resolvedTranslationConfiguration()
        let request = translationRequest()
        let first = try await controller.submitTranslation(request: request, configuration: configuration)
        fixture.codex.behavior = .fail
        let second = try await controller.submitTranslation(
            request: request, configuration: configuration, requestTimeout: 5
        )
        XCTAssertEqual(first, second)
        XCTAssertEqual(fixture.codex.calls.count, 1, "A repeated OCR request should avoid another model round trip")
    }

    func testCodexTranslationCacheSeparatesModelEffortAndSourceText() async throws {
        let fixture = TranslationRoutingFixture(settings: staleTranslationSettings())
        addTeardownBlock { try await fixture.cleanUp() }
        let controller = fixture.makeController()
        let request = translationRequest()
        _ = try await controller.submitTranslation(request: request, configuration: .codex(model: "model-a", effort: "low"))
        _ = try await controller.submitTranslation(request: request, configuration: .codex(model: "model-b", effort: "low"))
        _ = try await controller.submitTranslation(request: request, configuration: .codex(model: "model-a", effort: "high"))
        let changed = ImageTranslationPrompt.fastRequest(regions: [
            ImageTranslationSourceRegion(id: "r001", sourceText: "Close settings", x: 0, y: 0, width: 0.5, height: 0.1)
        ])
        _ = try await controller.submitTranslation(request: changed, configuration: .codex(model: "model-a", effort: "low"))
        XCTAssertEqual(fixture.codex.calls.count, 4)
    }

    func testCodexTranslationDoesNotCacheMalformedResponses() async throws {
        let fixture = TranslationRoutingFixture(settings: staleTranslationSettings())
        addTeardownBlock { try await fixture.cleanUp() }
        fixture.codex.responseText = "Temporary upstream error"
        let controller = fixture.makeController()
        let configuration = try await controller.resolvedTranslationConfiguration()
        _ = try await controller.submitTranslation(request: translationRequest(), configuration: configuration)
        fixture.codex.responseText = TranslationCodexSpy.response
        let corrected = try await controller.submitTranslation(request: translationRequest(), configuration: configuration)
        XCTAssertEqual(corrected, TranslationCodexSpy.response)
        XCTAssertEqual(fixture.codex.calls.count, 2)
    }

    func testCodexConnectionProbeAlwaysContactsResponder() async throws {
        let fixture = TranslationRoutingFixture(settings: staleTranslationSettings())
        addTeardownBlock { try await fixture.cleanUp() }
        let controller = fixture.makeController()
        _ = try await controller.testTranslationConnection()
        _ = try await controller.testTranslationConnection()
        XCTAssertEqual(fixture.codex.calls.count, 2)
    }

    func testCodexFailureDoesNotFallBackToHTTP() async throws {
        let fixture = TranslationRoutingFixture(settings: staleTranslationSettings())
        addTeardownBlock { try await fixture.cleanUp() }
        fixture.codex.behavior = .fail
        let controller = fixture.makeController()
        let configuration = try await controller.resolvedTranslationConfiguration()
        do {
            _ = try await controller.submitTranslation(request: translationRequest(), configuration: configuration)
            XCTFail("The Codex failure must be returned to the caller")
        } catch {
            XCTAssertEqual(error as? TranslationRoutingTestError, .codexFailure)
        }
        XCTAssertEqual(fixture.codex.calls.count, 1)
        XCTAssertTrue(fixture.secrets.readAccounts.isEmpty)
        let requests = await fixture.http.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testCodexTranslationTimeoutCancelsResponderWithoutFallback() async throws {
        let fixture = TranslationRoutingFixture(settings: staleTranslationSettings())
        addTeardownBlock { try await fixture.cleanUp() }
        fixture.codex.behavior = .suspend
        let controller = fixture.makeController()
        let configuration = try await controller.resolvedTranslationConfiguration()
        do {
            _ = try await controller.submitTranslation(
                request: translationRequest(), configuration: configuration, requestTimeout: 0.03
            )
            XCTFail("The translation deadline must include the complete Codex operation")
        } catch {
            XCTAssertTrue(controller.userFacingMessage(for: error).contains("Translation exceeded"))
        }
        XCTAssertEqual(fixture.codex.cancelledCalls, 1)
        XCTAssertTrue(fixture.secrets.readAccounts.isEmpty)
        let requests = await fixture.http.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testCancellingCodexTranslationCancelsResponderWithoutNetworkError() async throws {
        let fixture = TranslationRoutingFixture(settings: staleTranslationSettings())
        addTeardownBlock { try await fixture.cleanUp() }
        fixture.codex.behavior = .suspend
        let started = expectation(description: "Codex translation started")
        fixture.codex.onStart = { started.fulfill() }
        let controller = fixture.makeController()
        let configuration = try await controller.resolvedTranslationConfiguration()
        let request = translationRequest()
        let operation = Task {
            try await controller.submitTranslation(request: request, configuration: configuration)
        }
        await fulfillment(of: [started], timeout: 1)
        operation.cancel()
        do {
            _ = try await operation.value
            XCTFail("A cancelled translation must not return a response")
        } catch {
            XCTAssertTrue(error is CancellationError, "Cancellation must not become a network error: \(error)")
        }
        XCTAssertEqual(fixture.codex.cancelledCalls, 1)
        XCTAssertTrue(fixture.secrets.readAccounts.isEmpty)
        let requests = await fixture.http.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testCodexConfigurationSnapshotSurvivesChangesWhileCatalogLoads() async throws {
        var settings = staleTranslationSettings()
        settings.translationCodexModel = "translation-codex"
        settings.translationCodexReasoningEffort = "high"
        let fixture = TranslationRoutingFixture(
            settings: settings,
            codexModels: [translationCodexModel(), translationCodexModel(id: "changed-codex")]
        )
        addTeardownBlock { try await fixture.cleanUp() }
        let controller = fixture.makeController()
        let started = expectation(description: "Translation catalog load started")
        fixture.catalog.onStart = { started.fulfill() }
        fixture.catalog.suspendsLoads = true
        let operation = Task { try await controller.resolvedTranslationConfiguration() }
        await fulfillment(of: [started], timeout: 1)
        controller.translationCodexModel = "changed-codex"
        controller.translationCodexReasoningEffort = "low"
        controller.translationUsesDedicatedConfiguration = true
        controller.translationProvider = .deepLX
        controller.translationDeepLXServerURL = "https://changed.example/translate"
        controller.translationModel = "changed-model"
        fixture.catalog.resume()

        let configuration = try await operation.value
        guard case .codex(let model, let effort) = configuration else {
            return XCTFail("The initial translation must resolve to Codex")
        }
        XCTAssertEqual(model, "translation-codex")
        XCTAssertEqual(effort, "high")

        _ = try await controller.submitTranslation(request: translationRequest(), configuration: configuration)
        let call = try XCTUnwrap(fixture.codex.calls.first)
        XCTAssertEqual(call.model, model)
        XCTAssertEqual(call.effort, effort)
        XCTAssertTrue(fixture.secrets.readAccounts.isEmpty)
        let requests = await fixture.http.requests
        XCTAssertTrue(requests.isEmpty, "An in-flight capture must keep its resolved provider")
    }

    private func translationCodexModel(id: String = "translation-codex") -> CodexModelOption {
        CodexModelOption(id: id, name: "Translation model", reasoningEfforts: ["low", "high"], defaultReasoningEffort: "low")
    }

    private func staleTranslationSettings() -> InferenceSettingsSnapshot {
        var settings = InferenceSettingsSnapshot.default
        settings.translationUsesDedicatedConfiguration = false
        settings.provider = .gateway
        settings.gatewayBaseURL = "invalid old gateway URL"
        settings.model = ""
        settings.translationProvider = .gateway
        settings.translationGatewayBaseURL = "invalid unused translation URL"
        return settings
    }

    private func translationRequest() -> VisionRequest {
        ImageTranslationPrompt.fastRequest(regions: [
            ImageTranslationSourceRegion(
                id: "r001", sourceText: "Open settings", x: 0.1, y: 0.1, width: 0.5, height: 0.1
            )
        ])
    }

    private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

@MainActor
private final class TranslationRoutingFixture {
    let repository: InferenceSettingsRepository
    let secrets: TranslationRoutingSecrets
    let http: TranslationRoutingHTTPTransport
    let codex = TranslationCodexSpy()
    let catalog: TranslationModelCatalogSpy
    private let historyResources = MarrHistoryTestResources(rootURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("Marr-TranslationRouting-\(UUID().uuidString)", isDirectory: true))

    init(
        settings: InferenceSettingsSnapshot,
        credentials: [String: String]? = nil,
        responseBody: String? = nil,
        codexModels: [CodexModelOption] = []
    ) {
        secrets = TranslationRoutingSecrets(credentials: credentials)
        http = TranslationRoutingHTTPTransport(responseBody: responseBody)
        catalog = TranslationModelCatalogSpy(additionalModels: codexModels)
        repository = InferenceSettingsRepository(values: TranslationRoutingValues(), secrets: secrets)
        repository.saveConfiguration(settings)
    }

    func makeController(usesCodex: Bool = true) -> MarrController {
        let codex = codex
        let catalog = catalog
        let controller = MarrController(
            client: InferenceClient(transport: http),
            usesCodexForConversation: usesCodex,
            deepLXClient: DeepLXTranslationClient(transport: http),
            historyStore: historyResources.makeStore(),
            tokenUsageStore: TokenUsageStore(rootURL: historyResources.rootURL),
            settingsRepository: repository,
            codexTranslationResponder: { request, model, effort in
                try await codex.respond(request: request, model: model, effort: effort)
            },
            codexTranslationModelCatalog: {
                await catalog.load()
            },
            codexWorkspace: RuntimeWorkspaceController(
                defaults: UserDefaults(suiteName: "Marr.TranslationRouting.\(UUID().uuidString)")!,
                outboundMessage: { _ in },
                attachmentDirectory: historyResources.rootURL.appendingPathComponent("WorkAttachments"),
                draftDirectory: historyResources.rootURL.appendingPathComponent("Drafts"),
                codexSyncEnabled: usesCodex)
        )
        catalog.conversationModelID = controller.codexWorkspace.selectedModel
        return controller
    }

    func cleanUp() async throws {
        try await historyResources.cleanUp()
    }
}

@MainActor
private final class TranslationModelCatalogSpy {
    var conversationModelID = ""
    let additionalModels: [CodexModelOption]
    private(set) var loadCount = 0
    var onStart: (() -> Void)?
    var suspendsLoads = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(additionalModels: [CodexModelOption]) {
        self.additionalModels = additionalModels
    }

    func load() async -> [CodexModelOption] {
        loadCount += 1
        onStart?()
        if suspendsLoads {
            await withCheckedContinuation { continuation = $0 }
        }
        // The inherited model deliberately has no default effort, preserving the
        // existing route's nil effort while allowing explicit translation overrides.
        return [CodexModelOption(id: conversationModelID, name: "Conversation model", reasoningEfforts: ["low", "high"])]
            + additionalModels
    }

    func resume() {
        suspendsLoads = false
        continuation?.resume()
        continuation = nil
    }
}

private enum TranslationRoutingTestError: Error, Equatable {
    case unexpectedHTTP
    case unexpectedCredentialRead
    case codexFailure
}

@MainActor
private final class TranslationCodexSpy {
    enum Behavior { case respond, fail, suspend }
    struct Call {
        let request: VisionRequest
        let model: String
        let effort: String?
    }
    static let response = #"{"replacements":[{"id":"r001","text":"打开设置"}]}"#
    var responseText = TranslationCodexSpy.response
    var behavior = Behavior.respond
    var calls: [Call] = []
    var cancelledCalls = 0
    var onStart: (() -> Void)?

    func respond(request: VisionRequest, model: String, effort: String?) async throws -> String {
        calls.append(Call(request: request, model: model, effort: effort))
        onStart?()
        switch behavior {
        case .respond:
            return responseText
        case .fail:
            throw TranslationRoutingTestError.codexFailure
        case .suspend:
            do {
                try await Task.sleep(for: .seconds(30))
                return Self.response
            } catch {
                if Task.isCancelled { cancelledCalls += 1 }
                throw error
            }
        }
    }
}

private actor TranslationRoutingHTTPTransport: HTTPTransport {
    private let responseBody: String?
    private(set) var requests: [URLRequest] = []

    init(responseBody: String?) {
        self.responseBody = responseBody
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard let responseBody, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        else { throw TranslationRoutingTestError.unexpectedHTTP }
        return (Data(responseBody.utf8), response)
    }
}

private final class TranslationRoutingValues: SettingsKeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var strings: [String: String] = [:]
    private var integers: [String: Int] = [:]

    func string(forKey key: String) -> String? { lock.withLock { strings[key] } }
    func integer(forKey key: String) -> Int? { lock.withLock { integers[key] } }
    func set(_ value: String, forKey key: String) { lock.withLock { strings[key] = value } }
    func set(_ value: Int, forKey key: String) { lock.withLock { integers[key] = value } }
}

private final class TranslationRoutingSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var credentials: [String: String]?
    private var recordedAccounts: [String] = []
    var readAccounts: [String] { lock.withLock { recordedAccounts } }

    init(credentials: [String: String]?) {
        self.credentials = credentials
    }

    func string(for account: String) throws -> String? {
        try lock.withLock {
            recordedAccounts.append(account)
            guard let credentials else { throw TranslationRoutingTestError.unexpectedCredentialRead }
            return credentials[account]
        }
    }

    func set(_ value: String, for account: String) throws {
        lock.withLock {
            if credentials == nil { credentials = [:] }
            credentials?[account] = value
        }
    }
}

@MainActor
private final class ScreenshotCompanionToolsFixture: ObservableObject {
    @Published var expanded = false
    @Published var selected: ScreenshotAnnotationTool?
    @Published var undoCount = 0
    @Published var translationCount = 0
}

private struct ScreenshotCompanionToolsPreview: View {
    @ObservedObject var state: ScreenshotCompanionToolsFixture
    private let selection = CGRect(x: 36, y: 40, width: 340, height: 340)

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(nsColor: .windowBackgroundColor)
            VStack(alignment: .leading, spacing: 18) {
                Text("A quieter way to work.").font(.system(size: 23, weight: .medium))
                Text("Capture a thought.\nMake room for what matters.")
                    .font(.system(size: 16)).foregroundStyle(.secondary).lineSpacing(8)
                Spacer()
                Text(state.selected?.title ?? "Select a tool with Marr")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .padding(28)
            .frame(width: selection.width, height: selection.height, alignment: .topLeading)
            .background(MarrUI.Surface.raised, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.secondary.opacity(0.25)))
            .offset(x: selection.minX, y: selection.minY)
            ScreenshotCompanionTools(
                frame: ScreenshotToolsLayout.resolve(selection: selection,
                    bounds: CGSize(width: 480, height: 430), expanded: state.expanded).frame,
                expanded: $state.expanded, selectedTool: state.selected,
                canUndo: state.undoCount == 0, gaze: CGPoint(x: -0.8, y: 0.2),
                onSelect: { state.selected = state.selected == $0 ? nil : $0 },
                onTranslate: { state.translationCount += 1 },
                onUndo: { state.undoCount += 1 })
        }
        .frame(width: 480, height: 430)
    }
}

@MainActor
final class ScreenshotAnnotationTests: XCTestCase {
    func testCompanionToolsRespondToClicksAndKeepSelectionWhenCollapsed() async throws {
        try MarrUITestSupport.requireVisibleWindows()
        guard #available(macOS 14.4, *) else { throw XCTSkip("Requires process-only capture") }
        let state = ScreenshotCompanionToolsFixture()
        let hosting = NSHostingView(rootView: AnyView(ScreenshotCompanionToolsPreview(state: state)))
        let window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 480, height: 430),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.appearance = NSAppearance(named: .aqua)
        defer { window.close() }
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
        window.center()
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(500))
        let shareable = try await SCShareableContent.currentProcess
        let capturedWindow = try XCTUnwrap(shareable.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
        let filter = SCContentFilter(desktopIndependentWindow: capturedWindow)
        let configuration = SCStreamConfiguration()
        configuration.width = 960
        configuration.height = 860
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true

        func click(topY: CGFloat) throws {
            let point = CGPoint(x: 413, y: 430 - topY)
            let events = try [NSEvent.EventType.leftMouseDown, .leftMouseUp].map { type in
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            }
            NSApp.postEvent(events[1], atStart: true)
            window.sendEvent(events[0])
            window.sendEvent(events[1])
        }

        let gif = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(gif, "com.compuserve.gif" as CFString, 64, nil))
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for frame in 0..<64 {
            switch frame {
            case 8: try click(topY: 65)
            case 16:
                XCTAssertTrue(state.expanded)
                try click(topY: 165)
            case 24:
                XCTAssertEqual(state.selected, .rectangle)
                try click(topY: 215)
            case 32:
                XCTAssertEqual(state.selected, .arrow)
                try click(topY: 65)
            case 40:
                XCTAssertFalse(state.expanded)
                XCTAssertEqual(state.selected, .arrow, "Collapsing keeps the active drawing tool")
                try click(topY: 65)
            case 48:
                XCTAssertTrue(state.expanded)
                try click(topY: 365)
            case 56:
                XCTAssertEqual(state.undoCount, 1)
                try click(topY: 115)
            default: break
            }
            try await Task.sleep(for: .milliseconds(65))
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            CGImageDestinationAddImage(destination, image,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
            if frame == 4 || frame == 28 || frame == 36 {
                let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = "rive-sidebar-\(frame)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        // The same native controls remain usable with all motion disabled.
        hosting.rootView = AnyView(ScreenshotCompanionToolsPreview(state: state)
            .environment(\.marrAccessibilityOverrides, MarrAccessibilityPreferences(
                reducesMotion: true, reducesTransparency: false, increasedContrast: false)))
        try await Task.sleep(for: .milliseconds(150))
        try click(topY: 365)
        XCTAssertEqual(state.undoCount, 1, "Disabled undo cannot fire again")
        try click(topY: 65)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(state.expanded)
        XCTAssertEqual(state.selected, .arrow)
        try click(topY: 65)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(state.expanded)
        XCTAssertEqual(state.translationCount, 1)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let attachment = XCTAttachment(data: gif as Data, uniformTypeIdentifier: "com.compuserve.gif")
        attachment.name = "rive-sidebar-interaction"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSelectionToolsRenderBesidePromptAndKeepContrastWithWhiteTint() async throws {
        try MarrUITestSupport.requireVisibleWindows()
        guard #available(macOS 14.4, *) else { throw XCTSkip("Capturing the test process without screen-recording permission requires macOS 14.4") }
        let suiteName = "Marr.ScreenshotTools.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(MarrBubbleColor.system.rawValue, forKey: MarrBubbleColor.storageKey)
        let bounds = CGSize(width: 657, height: 664)
        // Coordinates from the reported screenshot, converted from Retina pixels to points.
        let selection = CGRect(x: 211, y: 27, width: 250, height: 186)
        let prompt = CGRect(x: 86, y: 232, width: 500, height: 46)
        let layout = ScreenshotToolsLayout.resolve(selection: selection, bounds: bounds, expanded: true, avoiding: prompt)
        XCTAssertEqual(layout.frame.minY, selection.minY)
        XCTAssertLessThanOrEqual(layout.frame.maxY, prompt.minY - 8)

        for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            let content = ZStack(alignment: .topLeading) {
                (scheme == .light ? Color(white: 0.94) : Color(white: 0.10))
                Rectangle().fill(scheme == .light ? .white : Color(white: 0.16))
                    .overlay(Rectangle().stroke(.secondary, lineWidth: 1))
                    .frame(width: selection.width, height: selection.height)
                    .position(x: selection.midX, y: selection.midY)
                Text("What can I help you with today?")
                    .foregroundStyle(.primary)
                    .frame(width: prompt.width, height: prompt.height)
                    .background(.regularMaterial, in: Capsule())
                    .position(x: prompt.midX, y: prompt.midY)
                ScreenshotCompanionTools(frame: layout.frame, expanded: .constant(true),
                    selectedTool: .arrow, canUndo: false, gaze: CGPoint(x: -0.8, y: 0.1),
                    onSelect: { _ in }, onTranslate: {}, onUndo: {})
            }
            .frame(width: bounds.width, height: bounds.height)
            .tint(.white)
            .defaultAppStorage(defaults)
            .environment(\.colorScheme, scheme)
            let hosting = NSHostingView(rootView: content)
            hosting.frame = CGRect(origin: .zero, size: bounds)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
            window.contentView = hosting
            defer { window.close() }
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
            window.center()
            window.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(250))
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            // cacheDisplay omits the GPU-backed glass/scroll layer. Capture only
            // this test process's window: currentProcess never requires TCC
            // consent and cannot expose another app's private window content.
            let shareable = try await SCShareableContent.currentProcess
            let capturedWindow = try XCTUnwrap(shareable.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
            let filter = SCContentFilter(desktopIndependentWindow: capturedWindow)
            let configuration = SCStreamConfiguration()
            configuration.width = Int(bounds.width * 2)
            configuration.height = Int(bounds.height * 2)
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true
            let captured = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            let bitmap = NSBitmapImageRep(cgImage: captured)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "screenshot-tools-selection-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)

            let scale = CGFloat(bitmap.pixelsWide) / bounds.width
            let center = CGPoint(x: layout.frame.midX, y: layout.frame.minY + 75)
            let sampleCenters = [center, CGPoint(x: center.x, y: bounds.height - center.y)]
            var pixelCounts: [(readable: Int, background: Int)] = []
            for sampleCenter in sampleCenters {
                var readablePixels = 0
                var backgroundPixels = 0
                for y in Int((sampleCenter.y - 10) * scale)..<Int((sampleCenter.y + 10) * scale) {
                    for x in Int((sampleCenter.x - 10) * scale)..<Int((sampleCenter.x + 10) * scale) {
                        let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                        let channels = [color.redComponent, color.greenComponent, color.blueComponent]
                        if color.alphaComponent > 0.9, scheme == .light ? channels.max()! < 0.35 : channels.min()! > 0.75 {
                            readablePixels += 1
                        } else if color.alphaComponent > 0.9,
                                  scheme == .light ? channels.min()! > 0.65 : channels.max()! < 0.45 {
                            backgroundPixels += 1
                        }
                    }
                }
                pixelCounts.append((readablePixels, backgroundPixels))
            }
            let bestSample = pixelCounts.max {
                min($0.readable, $0.background) < min($1.readable, $1.background)
            } ?? (0, 0)
            let readablePixels = bestSample.readable
            let backgroundPixels = bestSample.background
            XCTAssertGreaterThan(readablePixels, 20, "The translate symbol must remain readable with an inherited white tint in \(name) mode")
            XCTAssertGreaterThan(backgroundPixels, 20, "The icon must contain visible strokes and surrounding background, not an unrendered solid rectangle")
            XCTAssertGreaterThan(backgroundPixels, readablePixels / 2, "A solid foreground block is not a rendered translate icon")
        }
    }

    func testWideComposerKeepsToolsBesideSelectionInsteadOfBelowPrompt() {
        let selection = CGRect(x: 600, y: 100, width: 250, height: 185)
        let prompt = CGRect(x: 475, y: 299, width: 500, height: 54)
        let layout = ScreenshotToolsLayout.resolve(selection: selection,
            bounds: CGSize(width: 1440, height: 900), expanded: true, avoiding: prompt)

        XCTAssertEqual(layout.frame.minX, selection.maxX + 12, accuracy: 0.01)
        XCTAssertEqual(layout.frame.minY, selection.minY, accuracy: 0.01)
        XCTAssertLessThanOrEqual(layout.frame.maxY, prompt.minY - 8)
        XCTAssertGreaterThan(layout.frame.height, 100, "The nearby lane must retain several tools and scroll the rest")
        XCTAssertLessThan(layout.frame.height, 350)
    }

    func testGrowingPromptDoesNotMoveToolsAwayFromSelection() {
        let selection = CGRect(x: 600, y: 100, width: 250, height: 185)
        var origins: [CGPoint] = []
        for promptHeight: CGFloat in [46, 54, 72, 94] {
            let prompt = CGRect(x: 475, y: selection.maxY + 14, width: 500, height: promptHeight)
            let layout = ScreenshotToolsLayout.resolve(selection: selection,
                bounds: CGSize(width: 1440, height: 900), expanded: true, avoiding: prompt)
            origins.append(layout.frame.origin)
            XCTAssertFalse(layout.frame.intersects(prompt.insetBy(dx: -7, dy: -7)))
        }
        XCTAssertTrue(origins.allSatisfy { $0 == origins.first })
    }

    func testToolsUseOppositeClearSideBeforeShorteningViewport() {
        let selection = CGRect(x: 500, y: 100, width: 250, height: 185)
        let prompt = CGRect(x: 700, y: 299, width: 500, height: 54)
        let layout = ScreenshotToolsLayout.resolve(selection: selection,
            bounds: CGSize(width: 1440, height: 900), expanded: true, avoiding: prompt)
        XCTAssertTrue(layout.isOnLeft)
        XCTAssertEqual(layout.frame.minY, selection.minY)
        XCTAssertEqual(layout.frame.height, 350)
        XCTAssertFalse(layout.frame.intersects(prompt))
    }

    func testCompanionToolAnchorStaysFixedWhenExpandingBesideSelection() {
        let bounds = CGSize(width: 1440, height: 900)
        for y: CGFloat in [100, 740] {
            for prompt in [CGRect.null, CGRect(x: 475, y: 299, width: 500, height: 54)] {
                let selection = CGRect(x: 500, y: y, width: 250, height: 120)
                let collapsed = ScreenshotToolsLayout.resolve(selection: selection, bounds: bounds, expanded: false, avoiding: prompt)
                let expanded = ScreenshotToolsLayout.resolve(selection: selection, bounds: bounds, expanded: true, avoiding: prompt)
                XCTAssertEqual(collapsed.frame.origin, expanded.frame.origin)
                XCTAssertEqual(collapsed.frame.size, CGSize(width: 50, height: 50))
                XCTAssertGreaterThan(expanded.frame.height, collapsed.frame.height)
            }
        }
    }

    func testToolsSwitchSidesAndStayWithinDisplay() {
        let bounds = CGSize(width: 1440, height: 900)
        let rightEdge = CGRect(x: 1100, y: 10, width: 330, height: 200)
        let layout = ScreenshotToolsLayout.resolve(selection: rightEdge, bounds: bounds, expanded: true)
        XCTAssertTrue(layout.isOnLeft)
        XCTAssertLessThan(layout.frame.maxX, rightEdge.minX)
        XCTAssertTrue(CGRect(origin: .zero, size: bounds).contains(layout.frame))

        let fullScreen = ScreenshotToolsLayout.resolve(selection: CGRect(origin: .zero, size: bounds), bounds: bounds, expanded: true)
        XCTAssertTrue(CGRect(origin: .zero, size: bounds).contains(fullScreen.frame))
        let collapsed = ScreenshotToolsLayout.resolve(selection: rightEdge, bounds: bounds, expanded: false)
        XCTAssertLessThan(collapsed.frame.height, layout.frame.height)
    }

    func testToolsAvoidComposerAcrossSelectionSizesAndScreenEdges() {
        let bounds = CGSize(width: 1440, height: 900)
        for x: CGFloat in [8, 500, 1200] {
            for y: CGFloat in [8, 300, 740] {
                for width: CGFloat in [40, 180] {
                    let selection = CGRect(x: x, y: y, width: width, height: 80)
                    let promptX = min(max(selection.midX - 250, 12), bounds.width - 512)
                    for promptY in [selection.maxY + 14, max(8, selection.minY - 90)] {
                        let prompt = CGRect(x: promptX, y: min(promptY, 816), width: 500, height: 72)
                        for expanded in [true, false] {
                            let layout = ScreenshotToolsLayout.resolve(selection: selection, bounds: bounds,
                                expanded: expanded, avoiding: prompt)
                            XCTAssertFalse(layout.frame.intersects(prompt.insetBy(dx: -7, dy: -7)), "\(selection), \(prompt)")
                            XCTAssertTrue(CGRect(origin: .zero, size: bounds).contains(layout.frame))
                            XCTAssertGreaterThan(layout.frame.height, 42)
                        }
                    }
                }
            }
        }
    }

    func testToolsUseScrollableLaneWhenComposerLeavesNoFullHeightSpace() {
        let bounds = CGSize(width: 500, height: 300)
        let prompt = CGRect(x: 10, y: 155, width: 480, height: 72)
        let layout = ScreenshotToolsLayout.resolve(selection: CGRect(x: 200, y: 70, width: 100, height: 70),
            bounds: bounds, expanded: true, avoiding: prompt)
        XCTAssertFalse(layout.frame.intersects(prompt))
        XCTAssertGreaterThan(layout.frame.height, 42)
        XCTAssertLessThan(layout.frame.height, 284)
    }

    func testAnnotationPickingUsesVisibleMarksAndScreenPointTolerance() {
        let size = CGSize(width: 400, height: 200)
        let box = ScreenshotAnnotation(tool: .rectangle, points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.5, y: 0.5)])
        XCTAssertTrue(box.interactionPath(in: size).contains(CGPoint(x: 44, y: 60)))
        XCTAssertFalse(box.interactionPath(in: size).contains(CGPoint(x: 120, y: 60)))
        let arrow = ScreenshotAnnotation(tool: .arrow, points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.5, y: 0.5)])
        XCTAssertTrue(arrow.interactionPath(in: size).contains(CGPoint(x: 120, y: 60)))
        XCTAssertFalse(arrow.interactionPath(in: size).contains(CGPoint(x: 120, y: 100)))
        let number = ScreenshotAnnotation(tool: .number, points: [.zero], number: 1)
        XCTAssertTrue(number.interactionPath(in: size).contains(CGPoint(x: 13, y: 13)))
    }

    func testMovingAnnotationClampsWholeShapeWithoutDistortingIt() {
        let original = ScreenshotAnnotation(tool: .rectangle, points: [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.4, y: 0.6)])
        let moved = original.translated(by: CGSize(width: 500, height: -300), in: CGSize(width: 400, height: 200))
        XCTAssertEqual(moved.points[0].x, 0.7, accuracy: 0.0001)
        XCTAssertEqual(moved.points[1].x, 1, accuracy: 0.0001)
        XCTAssertEqual(moved.points[0].y, 0, accuracy: 0.0001)
        XCTAssertEqual(moved.points[1].y, 0.4, accuracy: 0.0001)
        XCTAssertEqual(original.points[0], CGPoint(x: 0.1, y: 0.2))
    }

    func testAnnotatedAttachmentContainsMarksAtRetinaCoordinates() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 400, height: 200,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        let cgImage = try XCTUnwrap(context.makeImage())
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let source = PickedImage(data: data, mimeType: "image/png", fileName: "test.png",
                                 image: NSImage(cgImage: cgImage, size: CGSize(width: 400, height: 200)))
        let marks = [
            ScreenshotAnnotation(tool: .rectangle, points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.5, y: 0.5)]),
            ScreenshotAnnotation(tool: .arrow, points: [CGPoint(x: 0.55, y: 0.2), CGPoint(x: 0.9, y: 0.5)]),
            ScreenshotAnnotation(tool: .number, points: [CGPoint(x: 0.75, y: 0.75)], number: 1),
            ScreenshotAnnotation(tool: .pen, points: [CGPoint(x: 0.1, y: 0.8), CGPoint(x: 0.25, y: 0.65), CGPoint(x: 0.4, y: 0.85)])
        ]
        let result = try XCTUnwrap(ScreenCapture.annotating(source, with: marks, selectionSize: CGSize(width: 200, height: 100)))
        XCTAssertEqual(result.mimeType, "image/png")
        for (name, data) in [("source", source.data), ("annotated", result.data)] {
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 300, y: 150)?.usingColorSpace(.deviceRGB)).greenComponent, 0.9, "Source fixture must be white")
        let exported = try XCTUnwrap(NSBitmapImageRep(data: result.data))
        XCTAssertEqual(exported.pixelsWide, 400)
        XCTAssertEqual(exported.pixelsHigh, 200)
        for (x, y) in [(100, 20), (290, 70), (300, 130), (100, 130)] {
            let stroke = try XCTUnwrap(exported.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
            XCTAssertGreaterThan(stroke.redComponent, 0.8)
            XCTAssertLessThan(stroke.greenComponent, 0.5)
        }
        let untouched = try XCTUnwrap(exported.colorAt(x: 380, y: 190)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(untouched.greenComponent, 0.9)
        let original = try XCTUnwrap(ScreenCapture.annotating(source, with: [], selectionSize: CGSize(width: 200, height: 100)))
        XCTAssertEqual(original.data, source.data)
    }
}
