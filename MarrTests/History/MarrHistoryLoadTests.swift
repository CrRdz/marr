import AppKit
import Combine
import MarrCore
import MarrNetworking
import MarrSettings
import XCTest
@testable import Marr

/// Cancellation occurs synchronously on the main actor, before the load task
/// can resume. No test takes the successful history/panel presentation path.
@MainActor
final class MarrHistoryLoadTests: XCTestCase {
    func testExplicitCancellationClearsLoadingAndCannotLaterPresentHistory() async throws {
        let fixture = try await makeFixture(recordCount: 1)
        let visibleWindows = visibleWindowIDs
        let controller = fixture.controller
        var selectedIDs: [UUID] = []
        let observation = controller.$loadingHistoryConversationID.compactMap { $0 }
            .sink { selectedIDs.append($0) }
        defer {
            observation.cancel()
            controller.cancelPendingHistoryLoad()
        }

        controller.openHistoryConversation(fixture.records[0])
        controller.cancelPendingHistoryLoad()

        XCTAssertEqual(selectedIDs, [fixture.records[0].id])
        XCTAssertNil(controller.loadingHistoryConversationID)
        XCTAssertNil(controller.statusMessage)
        try await assertCancelledLoadRemainsInactive(controller, expectedStatus: nil,
                                                     visibleWindows: visibleWindows)
    }

    func testDismissalWinsOverPendingHistoryAndPreservesReadyStatus() async throws {
        let fixture = try await makeFixture(recordCount: 1)
        let visibleWindows = visibleWindowIDs
        let controller = fixture.controller
        var selectedIDs: [UUID] = []
        let observation = controller.$loadingHistoryConversationID.compactMap { $0 }
            .sink { selectedIDs.append($0) }
        defer {
            observation.cancel()
            controller.cancelPendingHistoryLoad()
        }

        controller.openHistoryConversation(fixture.records[0])
        controller.dismissCaptureSession()

        XCTAssertEqual(selectedIDs, [fixture.records[0].id])
        let expectedStatus = "Ready. Press \(controller.hotKeyConfiguration.displayString) to capture."
        XCTAssertNil(controller.loadingHistoryConversationID)
        XCTAssertEqual(controller.statusMessage, expectedStatus)
        try await assertCancelledLoadRemainsInactive(controller, expectedStatus: expectedStatus,
                                                     visibleWindows: visibleWindows)
    }

    func testMinimizeCancelsBothRapidHistorySelectionsWithoutPresentingEither() async throws {
        let fixture = try await makeFixture(recordCount: 2)
        let visibleWindows = visibleWindowIDs
        let controller = fixture.controller
        var selectedIDs: [UUID] = []
        let observation = controller.$loadingHistoryConversationID.compactMap { $0 }
            .sink { selectedIDs.append($0) }
        defer {
            observation.cancel()
            controller.cancelPendingHistoryLoad()
        }
        XCTAssertNotEqual(fixture.records[0].id, fixture.records[1].id)

        // There is deliberately no suspension between selections and minimize:
        // the second selection cancels the first, and minimize cancels the second.
        controller.openHistoryConversation(fixture.records[0])
        controller.openHistoryConversation(fixture.records[1])
        controller.minimizeAnswerPanel()

        XCTAssertEqual(selectedIDs, fixture.records.map(\.id))
        let expectedStatus = "Answer panel minimized. Press \(controller.hotKeyConfiguration.displayString) to restore it."
        XCTAssertNil(controller.loadingHistoryConversationID)
        XCTAssertEqual(controller.statusMessage, expectedStatus)
        try await assertCancelledLoadRemainsInactive(controller, expectedStatus: expectedStatus,
                                                     visibleWindows: visibleWindows)
    }

    func testReplacingConversationKeepsNativeWindowFrameAndSidebarState() async throws {
        let fixture = try await makeFixture(recordCount: 2)
        let controller = fixture.controller
        let first = ConversationSession(historyRecord: fixture.records[0], imageAssets: [])
        let next = ConversationSession(historyRecord: fixture.records[1], imageAssets: [])
        let panel = AnswerPanelController(controller: controller, historyStore: controller.historyStore,
            session: first, anchorRect: .zero, persistImmediately: false)
        defer { panel.close() }
        let window = panel.windowForTesting
        let frame = window.frame
        let sidebar = panel.sidebarPresentation
        let visible = visibleWindowIDs
        panel.replaceConversation(next, controller: controller, historyStore: controller.historyStore)
        XCTAssertTrue(panel.windowForTesting === window)
        XCTAssertEqual(panel.frame, frame)
        XCTAssertEqual(panel.sidebarPresentation.layout, sidebar.layout)
        XCTAssertEqual(panel.sidebarPresentation.collapsedWorkspaceIDs, sidebar.collapsedWorkspaceIDs)
        XCTAssertEqual(visibleWindowIDs, visible)
        panel.invalidateDeletedConversations([next.id])
        XCTAssertTrue(next.isDeleted)
        XCTAssertFalse(first.isDeleted)
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        panel.close()
        try await Task.sleep(for: .milliseconds(100))
    }

    private var visibleWindowIDs: Set<ObjectIdentifier> {
        Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
    }

    private func assertCancelledLoadRemainsInactive(
        _ controller: MarrController, expectedStatus: String?, visibleWindows: Set<ObjectIdentifier>,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        // Give the cancelled main-actor task and its detached image-reader
        // multiple executor turns to complete. Check every turn, not only the
        // final state, to catch late status changes or presentation during settling.
        for _ in 0..<8 {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(15))
            XCTAssertNil(controller.loadingHistoryConversationID, file: file, line: line)
            XCTAssertEqual(controller.statusMessage, expectedStatus, file: file, line: line)
            XCTAssertTrue(visibleWindowIDs.subtracting(visibleWindows).isEmpty,
                          "Cancelled history must not add a visible window", file: file, line: line)
        }
    }

    private func makeFixture(recordCount: Int) async throws -> HistoryLoadFixture {
        let suite = "Marr.HistoryLoadCancellation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let resources = MarrHistoryTestResources(rootURL: directory)
        addTeardownBlock {
            try await resources.cleanUp()
            defaults.removePersistentDomain(forName: suite)
        }
        let history = resources.makeStore(at: directory.appendingPathComponent("History", isDirectory: true))
        // Supply real saved image URLs to the pending reader, rather than
        // an empty record or nonexistent files that would bypass image loading.
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6vT8AAAAASUVORK5CYII="))
        var recordIDs: [UUID] = []
        for index in 0..<recordCount {
            let image = ConversationImageAsset(data: png, mimeType: "image/png", fileName: "Saved-\(index).png")
            let turn = ConversationTurn(id: UUID(), question: "Saved question \(index)", imageIDs: [image.id],
                answer: "Saved answer", errorMessage: nil, status: .completed, showsAssistant: true)
            let id = UUID()
            let date = Date().addingTimeInterval(TimeInterval(index))
            history.save(ConversationArchive(id: id, createdAt: date, updatedAt: date,
                generatedTitle: "Saved conversation \(index)", turns: [turn], images: [image], pendingImageIDs: []))
            recordIDs.append(id)
        }
        await history.waitForPendingOperations()
        XCTAssertNil(history.lastErrorMessage)
        let records = try recordIDs.map { id in
            try XCTUnwrap(history.conversations.first { $0.id == id })
        }
        for record in records {
            let image = try XCTUnwrap(record.images.first)
            let url = try XCTUnwrap(history.imageFileURLs(conversationID: record.id, imageID: image.id)
                .first { FileManager.default.fileExists(atPath: $0.path) })
            XCTAssertEqual(try Data(contentsOf: url), png)
        }

        let workspace = RuntimeWorkspaceController(defaults: defaults, outboundMessage: { _ in
            XCTFail("Cancelling history must not issue a Codex request")
        }, attachmentDirectory: directory.appendingPathComponent("Attachments", isDirectory: true),
           draftDirectory: directory.appendingPathComponent("Drafts", isDirectory: true), codexSyncEnabled: true)
        let settings = InferenceSettingsRepository(values: UserDefaultsSettingsStore(defaults: defaults),
                                                    secrets: HistoryLoadSecrets())
        let controller = MarrController(client: HistoryLoadClient(), usesCodexForConversation: false,
            deepLXClient: DeepLXTranslationClient(transport: HistoryLoadHTTPTransport()),
            historyStore: history, tokenUsageStore: TokenUsageStore(rootURL: directory.appendingPathComponent("Usage")),
            settingsRepository: settings,
            codexTranslationResponder: { _, _, _ in
                XCTFail("Cancelling history must not request a Codex translation")
                throw HistoryLoadUnexpectedRequest.request
            }, codexTranslationModelCatalog: {
                XCTFail("Cancelling history must not request Codex models")
                return []
            }, codexWorkspace: workspace)
        return HistoryLoadFixture(controller: controller, records: records)
    }
}

private struct HistoryLoadFixture {
    let controller: MarrController
    let records: [ConversationHistoryRecord]
}

private enum HistoryLoadUnexpectedRequest: Error { case request }

private struct HistoryLoadClient: VisionAIClient {
    func ask(request: VisionRequest, model: String, connection: InferenceConnection) async throws -> String {
        XCTFail("Cancelling saved history must not issue inference or title-generation requests")
        throw HistoryLoadUnexpectedRequest.request
    }
}

private struct HistoryLoadHTTPTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        XCTFail("Cancelling saved history must not issue HTTP requests")
        throw HistoryLoadUnexpectedRequest.request
    }
}

private struct HistoryLoadSecrets: SecretStore {
    func string(for account: String) throws -> String? { nil }
    func set(_ value: String, for account: String) throws {
        XCTFail("Cancelling saved history must not write credentials")
    }
}
