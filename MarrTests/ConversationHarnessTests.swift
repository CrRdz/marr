import AppKit
import MarrCore
import MarrNetworking
import MarrSettings
import SwiftUI
import XCTest
@testable import Marr

@MainActor
final class ConversationHarnessTests: XCTestCase {
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

        XCTAssertTrue(request.systemPrompt.contains("summarizes the screenshot conversation"))
        XCTAssertEqual(request.messages.count, 1)
        XCTAssertEqual(imageCount(in: request.messages[0]), 0)
        XCTAssertTrue(try XCTUnwrap(text(in: request.messages[0])).contains("proxy mode"))
    }

    func testWindowCaptureQuestionRequestsAnalysisInsteadOfAnotherScreenshot() {
        let question = WindowCapture.analysisQuestion(
            appName: "Microsoft Edge",
            title: "Project status"
        )

        XCTAssertFalse(question.localizedCaseInsensitiveContains("send a screenshot"))
        XCTAssertTrue(question.localizedCaseInsensitiveContains("analyze this screenshot"))
        XCTAssertTrue(question.contains("Microsoft Edge — Project status"))
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
        try assertAnswerPanelDeliversWheelEvents(usesGlassSurfaces: true)
    }

    func testAnswerPanelDeliversWheelEventsWhenGlassSurfacesAreDisabled() throws {
        try assertAnswerPanelDeliversWheelEvents(usesGlassSurfaces: false)
    }

    func testDisabledGlassSelectsStandardMaterialMode() {
        XCTAssertEqual(
            MarrSurfaceMode.resolve(usesLiquidGlass: false, prefersClearGlass: true),
            .standardMaterial
        )
        XCTAssertEqual(
            MarrSurfaceMode.resolve(usesLiquidGlass: false, prefersClearGlass: false),
            .standardMaterial
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
        XCTAssertEqual(AnswerPanelConversationLayout.composerHeight, 40)
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

    func testAnswerPanelHistoryOpenAndCloseKeepsWindowAtAnswerSize() throws {
        let historyURL = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: historyURL) }

        let historyStore = ConversationHistoryStore(rootURL: historyURL)
        let controller = MarrController(
            client: AnswerPanelTestClient(),
            historyStore: historyStore
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
        let originalMinY = window.frame.minY

        XCTAssertEqual(window.frame.width, 420, accuracy: 1)
        XCTAssertEqual(window.frame.height, 596, accuracy: 1)
        XCTAssertTrue(window.isMovable)
        XCTAssertTrue(window.isMovableByWindowBackground)

        panel.setHistoryExpanded(true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        XCTAssertEqual(window.frame.height, 596, accuracy: 1)
        XCTAssertEqual(window.frame.minY, originalMinY, accuracy: 1)

        panel.setHistoryExpanded(false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        XCTAssertEqual(window.frame.height, 596, accuracy: 1)
        XCTAssertEqual(window.frame.minY, originalMinY, accuracy: 1)
    }

    private func assertAnswerPanelDeliversWheelEvents(usesGlassSurfaces: Bool) throws {
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
        defer { try? FileManager.default.removeItem(at: historyURL) }

        let historyStore = ConversationHistoryStore(rootURL: historyURL)
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

    func testHistoryStorePersistsTurnsAndImageDataAcrossReload() async throws {
        let rootURL = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let store = ConversationHistoryStore(rootURL: rootURL)
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

        let reloaded = ConversationHistoryStore(rootURL: rootURL)
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
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let store = ConversationHistoryStore(rootURL: rootURL)
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
        defer { try? FileManager.default.removeItem(at: rootURL) }

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

        let store = ConversationHistoryStore(rootURL: rootURL)
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
        let request = ImageTranslationPrompt.request(
            for: makeImage(name: "lines.png", byte: 10),
            regions: [
                ImageTranslationSourceRegion(
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
            ]
        )
        let userText = try XCTUnwrap(text(in: request.messages[0]))

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

        let blocks = ImageTranslationResponseParser.merge(replacements: replacements, regions: regions)

        XCTAssertEqual(blocks, [
            ImageTranslationBlock(
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

        let blocks = ImageTranslationResponseParser.merge(replacements: replacements, regions: regions)

        XCTAssertEqual(blocks, [
            ImageTranslationBlock(
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
            ImageTranslationRenderer.targetScriptFontScale(
                for: "只需询问 Siri AI，并获得相关答案。"
            ),
            0.88,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ImageTranslationRenderer.targetScriptFontScale(
                for: "Siri understands your personal context."
            ),
            1,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ImageTranslationRenderer.targetScriptFontScale(
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

        let blocks = ImageTranslationResponseParser.merge(replacements: replacements, regions: regions)

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

        let block = try XCTUnwrap(ImageTranslationResponseParser.merge(
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

        let block = try XCTUnwrap(ImageTranslationResponseParser.merge(
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

        let blocks = ImageTranslationResponseParser.merge(
            replacements: [replacement],
            regions: [region]
        )

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].text, "Rongqi Lu 的学术简介，展示其研究兴趣。")
        XCTAssertEqual(blocks[0].translationStrategy, .block)
        XCTAssertEqual(blocks[0].lineRects.count, 2)
    }

    func testBlockPromptDoesNotProtectOrdinarySentenceInitialCapitalizedWord() throws {
        let image = makeImage(name: "prompt.png", byte: 1)
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

        let request = ImageTranslationPrompt.request(for: image, regions: [region])
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
        XCTAssertTrue(promptText.contains("\"preserve\":false"))
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

        XCTAssertTrue(ImageTranslationResponseParser.merge(
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

        let blocks = ImageTranslationResponseParser.merge(
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

        let blocks = ImageTranslationResponseParser.merge(
            replacements: [ImageTranslationReplacement(id: "r001", text: "Rongqi Lu", kind: "list_item")],
            regions: regions
        )

        XCTAssertTrue(blocks.isEmpty)
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

        let blocks = ImageTranslationResponseParser.merge(
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

        let blocks = ImageTranslationResponseParser.merge(replacements: replacements, regions: regions)

        XCTAssertEqual(blocks.first?.text, "Marr 使用 `ConversationSession`")
    }

    func testTranslationReplacementsRestoreMissingSourceCodeMarkdown() throws {
        let regions = [
            ImageTranslationSourceRegion(
                id: "r001",
                sourceText: "VisionAIClient receives VisionRequest; OpenAIClient encodes it",
                x: 0.1,
                y: 0.2,
                width: 0.8,
                height: 0.05,
                codeRects: [
                    ImageTranslationTokenRect(text: "VisionAIClient", x: 0.1, y: 0.2, width: 0.16, height: 0.05),
                    ImageTranslationTokenRect(text: "VisionRequest", x: 0.4, y: 0.2, width: 0.15, height: 0.05),
                    ImageTranslationTokenRect(text: "OpenAIClient", x: 0.6, y: 0.2, width: 0.15, height: 0.05)
                ]
            )
        ]
        let replacements = [
            ImageTranslationReplacement(
                id: "r001",
                text: "VisionAIClient 接收 VisionRequest；OpenAIClient 对其编码",
                kind: "list_item"
            )
        ]

        let blocks = ImageTranslationResponseParser.merge(replacements: replacements, regions: regions)

        XCTAssertEqual(
            blocks.first?.text,
            "`VisionAIClient` 接收 `VisionRequest`；`OpenAIClient` 对其编码"
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

        let blocks = ImageTranslationResponseParser.merge(replacements: replacements, regions: regions)

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

        let blocks = ImageTranslationResponseParser.merge(replacements: replacements, regions: regions)

        XCTAssertEqual(blocks.first?.text, "`ConversationSession` 管理轮次")
    }

    func testMarkdownLineLayoutWrapsChineseToOriginalLineRects() throws {
        let lineRects = [
            CGRect(x: 0, y: 40, width: 30, height: 16),
            CGRect(x: 0, y: 20, width: 30, height: 16),
            CGRect(x: 0, y: 0, width: 30, height: 16)
        ]

        let lines = try XCTUnwrap(ImageTranslationMarkdownLineLayout.lines(
            for: "拥有轮次截图资源",
            lineRects: lineRects,
            codeRects: [],
            availableWidth: { $0.width },
            measuredWidth: { text, _ in CGFloat(text.count * 10) }
        ))

        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines.joined(), "拥有轮次截图资源")
        XCTAssertTrue(lines.allSatisfy { !$0.contains(" ") })
    }

    func testMarkdownLineLayoutUsesOnlyNeededLeadingSourceRows() throws {
        let lineRects = [
            CGRect(x: 0, y: 60, width: 50, height: 16),
            CGRect(x: 0, y: 40, width: 50, height: 16),
            CGRect(x: 0, y: 20, width: 50, height: 16),
            CGRect(x: 0, y: 0, width: 50, height: 16)
        ]

        let lines = try XCTUnwrap(ImageTranslationMarkdownLineLayout.lines(
            for: "翻译文字较短",
            lineRects: lineRects,
            codeRects: [],
            availableWidth: { $0.width },
            measuredWidth: { text, _ in CGFloat(text.count * 10) }
        ))

        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.joined(), "翻译文字较短")
    }

    func testMarkdownLineLayoutKeepsFixedListMarkerColumn() throws {
        let lineRects = [
            CGRect(x: 0, y: 20, width: 50, height: 16),
            CGRect(x: 12, y: 0, width: 38, height: 16)
        ]

        let lines = try XCTUnwrap(ImageTranslationMarkdownLineLayout.lines(
            for: "• 第一项内容较长",
            lineRects: lineRects,
            codeRects: [],
            availableWidth: { $0.width },
            measuredWidth: { text, _ in CGFloat(text.count * 9) }
        ))

        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("•\t"))
        XCTAssertFalse(lines[1].contains("•"))
    }

    func testMarkdownLineLayoutAnchorsCodeToSourceLine() throws {
        let lineRects = [
            CGRect(x: 0, y: 40, width: 44, height: 16),
            CGRect(x: 0, y: 20, width: 44, height: 16),
            CGRect(x: 0, y: 0, width: 44, height: 16)
        ]
        let codeRects = [
            CGRect(x: 4, y: 20, width: 34, height: 16)
        ]

        let lines = try XCTUnwrap(ImageTranslationMarkdownLineLayout.lines(
            for: "使用 `ConversationSession` 管理轮次和截图",
            lineRects: lineRects,
            codeRects: codeRects,
            availableWidth: { $0.width },
            measuredWidth: { text, _ in CGFloat(text.count * 6) }
        ))

        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0], "使用")
        XCTAssertEqual(lines[1], "`ConversationSession`")
        XCTAssertFalse(lines[0].contains("ConversationSession"))
        XCTAssertFalse(lines[2].contains("ConversationSession"))
    }

    func testMarkdownLineLayoutReflowsCodeWithoutSourceAnchors() throws {
        let lineRects = [
            CGRect(x: 0, y: 20, width: 90, height: 16),
            CGRect(x: 0, y: 0, width: 90, height: 16)
        ]

        let lines = try XCTUnwrap(ImageTranslationMarkdownLineLayout.lines(
            for: "使用 `ConversationSession` 管理轮次和截图",
            lineRects: lineRects,
            codeRects: [],
            availableWidth: { $0.width },
            measuredWidth: { text, _ in CGFloat(text.count * 6) }
        ))

        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.filter { $0.contains("ConversationSession") }.count, 1)
        XCTAssertEqual(
            lines.joined().replacingOccurrences(of: " ", with: ""),
            "使用`ConversationSession`管理轮次和截图"
        )
    }

    func testMarkdownLineLayoutReflowsMultipleCodeChipsInTranslatedOrder() throws {
        let lineRects = [
            CGRect(x: 0, y: 40, width: 126, height: 16),
            CGRect(x: 0, y: 20, width: 126, height: 16),
            CGRect(x: 0, y: 0, width: 126, height: 16)
        ]

        let lines = try XCTUnwrap(ImageTranslationMarkdownLineLayout.lines(
            for: "`VisionAIClient` 接收 `VisionRequest`，`OpenAIClient` 负责编码",
            lineRects: lineRects,
            codeRects: [],
            availableWidth: { $0.width },
            measuredWidth: { text, _ in CGFloat(text.count * 5) }
        ))

        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines.filter { $0.contains("VisionAIClient") }.count, 1)
        XCTAssertEqual(lines.filter { $0.contains("VisionRequest") }.count, 1)
        XCTAssertEqual(lines.filter { $0.contains("OpenAIClient") }.count, 1)
        let joined = lines.joined().replacingOccurrences(of: " ", with: "")
        XCTAssertLessThan(
            try XCTUnwrap(joined.range(of: "VisionAIClient")?.lowerBound),
            try XCTUnwrap(joined.range(of: "VisionRequest")?.lowerBound)
        )
        XCTAssertLessThan(
            try XCTUnwrap(joined.range(of: "VisionRequest")?.lowerBound),
            try XCTUnwrap(joined.range(of: "OpenAIClient")?.lowerBound)
        )
    }

    func testMarkdownLineLayoutRejectsUnmatchedCodeRects() throws {
        let lines = ImageTranslationMarkdownLineLayout.lines(
            for: "使用 `ConversationSession` 和 `VisionRequest`",
            lineRects: [
                CGRect(x: 0, y: 20, width: 100, height: 16),
                CGRect(x: 0, y: 0, width: 100, height: 16)
            ],
            codeRects: [
                CGRect(x: 4, y: 0, width: 34, height: 16)
            ],
            availableWidth: { $0.width },
            measuredWidth: { text, _ in CGFloat(text.count * 6) }
        )

        XCTAssertNil(lines)
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

    func testCompareLayoutFitsLargeCaptureInsideVisibleScreen() throws {
        let visibleFrame = CGRect(x: 0, y: 24, width: 900, height: 600)
        let frame = TranslationCompareLayout.imageFrame(
            anchorFrame: CGRect(x: -40, y: -20, width: 1400, height: 1000),
            visibleFrame: visibleFrame
        )

        XCTAssertTrue(visibleFrame.insetBy(dx: 12, dy: 12).contains(frame))
        XCTAssertEqual(frame.size, CGSize(width: 876, height: 576))
    }

    func testCompareLayoutDocksOriginalToLeftWhenSpaceAllows() throws {
        let frame = TranslationCompareLayout.dockedOriginalFrame(
            anchorFrame: CGRect(x: 700, y: 200, width: 300, height: 220),
            visibleFrame: CGRect(x: 0, y: 24, width: 1200, height: 760)
        )

        XCTAssertEqual(frame, CGRect(x: 392, y: 200, width: 300, height: 220))
    }

    func testCompareLayoutDocksOriginalToRightWhenLeftDoesNotFit() throws {
        let frame = TranslationCompareLayout.dockedOriginalFrame(
            anchorFrame: CGRect(x: 40, y: 200, width: 300, height: 220),
            visibleFrame: CGRect(x: 0, y: 24, width: 1200, height: 760)
        )

        XCTAssertEqual(frame, CGRect(x: 348, y: 200, width: 300, height: 220))
    }

    func testCompareLayoutFallsBackWhenNeitherSideFits() throws {
        let frame = TranslationCompareLayout.dockedOriginalFrame(
            anchorFrame: CGRect(x: 200, y: 150, width: 600, height: 400),
            visibleFrame: CGRect(x: 0, y: 24, width: 1000, height: 700)
        )

        XCTAssertNil(frame)
    }

    func testImageCompareLayoutExpandsSmallCaptureForReadableColumns() throws {
        let frame = TranslationCompareLayout.imageFrame(
            anchorFrame: CGRect(x: 300, y: 240, width: 260, height: 180),
            visibleFrame: CGRect(x: 0, y: 24, width: 1200, height: 760)
        )

        XCTAssertEqual(frame.size, CGSize(width: 760, height: 520))
        XCTAssertTrue(CGRect(x: 12, y: 36, width: 1176, height: 736).contains(frame))
    }

    func testImageCompareLayoutUsesTwoCaptureWidthsWhenSpaceAllows() throws {
        let frame = TranslationCompareLayout.imageFrame(
            anchorFrame: CGRect(x: 300, y: 240, width: 500, height: 400),
            visibleFrame: CGRect(x: 0, y: 24, width: 1400, height: 900)
        )

        XCTAssertEqual(frame.size, CGSize(width: 1001, height: 520))
    }

    func testImageCompareUsesOneCenteredDividerWithoutChangingPaneWidths() throws {
        XCTAssertEqual(TranslationCompareLayout.dividerWidth, 1)
        XCTAssertEqual(TranslationCompareLayout.paneWidth(containerWidth: 1000), 500)
        XCTAssertEqual(TranslationCompareLayout.dividerX(containerWidth: 1000), 500)
        XCTAssertEqual(TranslationCompareLayout.paneWidth(containerWidth: 1001), 500.5)
        XCTAssertEqual(TranslationCompareLayout.dividerX(containerWidth: 1001), 500.5)
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
        XCTAssertTrue(ImageTranslationCodeHeuristics.isStrongIdentifier("OpenAIClient"))
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
        var translatedRect = CGRect(origin: .zero, size: translatedImage.size)
        let translatedCGImage = try XCTUnwrap(
            translatedImage.cgImage(
                forProposedRect: &translatedRect,
                context: nil,
                hints: nil
            )
        )

        XCTAssertEqual(sourceImage.size.width, logicalSize.width, accuracy: 0.01)
        XCTAssertEqual(sourceImage.size.height, logicalSize.height, accuracy: 0.01)
        XCTAssertEqual(translatedImage.size.width, sourceImage.size.width, accuracy: 0.01)
        XCTAssertEqual(translatedImage.size.height, sourceImage.size.height, accuracy: 0.01)
        XCTAssertEqual(translatedCGImage.width, bitmap.pixelsWide)
        XCTAssertEqual(translatedCGImage.height, bitmap.pixelsHigh)
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

    func testTranslationRendererCentersShortTranslationInsideMultilineSourceRegion() throws {
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
            fileName: "short-centered-translation.png",
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
        XCTAssertGreaterThan(
            CGFloat(translatedRows.min() ?? 0),
            34 * backingScale
        )
        XCTAssertLessThan(
            CGFloat(translatedRows.max() ?? bitmap.pixelsHigh),
            84 * backingScale
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
