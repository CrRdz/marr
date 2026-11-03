import Foundation
import AppKit
import MarrCore
import MarrSettings
import SwiftUI
import Vision
import XCTest
@testable import Marr
@testable import MarrNetworking

@MainActor
final class MarrStandaloneWorkspaceTests: XCTestCase {
    func testCachedModelsRemainInteractiveDuringCoalescedBackgroundRefresh() async throws {
        let modelData = Data(#"[{"slug":"gpt-6.1-sol","display_name":"GPT-6.1 Sol","visibility":"list"}]"#.utf8)
        let models = try JSONDecoder().decode([ChatGPTModel].self, from: modelData)
        var saved = ChatGPTSavedState()
        saved.activeID = "fixture"
        saved.registrations = [.init(clientID: "fixture", label: "Personal",
            identity: .init(issuer: "https://auth.openai.com", subject: "test", email: "alex@example.com"),
            tokens: .init(accessToken: "fixture", refreshToken: "fixture", idToken: "fixture",
                          scopes: ["openid", "chatgpt.tokens.use.direct"], expiresAt: Date().addingTimeInterval(3600)),
            modelCatalog: .init(models: models, fetchedAt: Date().addingTimeInterval(-600)))]
        let transport = BackgroundCatalogTransport()
        let session = ChatGPTSession(store: BackgroundCatalogStore(data: try JSONEncoder().encode(saved)),
                                     transport: transport, verifier: BackgroundCatalogVerifier())
        let fixture = try await fixture(chatGPTSession: session)
        let controller = fixture.controller
        controller.provider = .chatGPT
        controller.model = "gpt-6.1-sol"
        controller.refreshChatGPTAccount()
        defer { Task { await transport.finish(modelData) } }
        for _ in 0..<100 {
            if await transport.requests == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(controller.chatGPTModels.map(\.slug), ["gpt-6.1-sol"])
        XCTAssertTrue(controller.chatGPTModelsLoading)
        XCTAssertFalse(controller.chatGPTBusy, "Catalog refresh must not lock account or model controls")
        controller.chatGPTReasoningEffort = "high"
        controller.chatGPTFastMode = true
        for _ in 0..<12 { controller.refreshChatGPTAccount() }
        let requestCount = await transport.requests
        XCTAssertEqual(requestCount, 1)
        await transport.finish(modelData)
        for _ in 0..<100 {
            if !controller.chatGPTModelsLoading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(controller.chatGPTModelsLoading)
        XCTAssertNil(controller.chatGPTModelError)
        XCTAssertEqual(controller.chatGPTReasoningEffort, "high")
        XCTAssertTrue(controller.chatGPTFastMode)
    }

    func testWorkspaceConversationUsesConfiguredInferenceWithCodexDisabled() async throws {
        let fixture = try await fixture()
        let store = fixture.controller.historyStore
        let workspace = try await store.createWorkspace(name: "Research", path: "/Projects/Research")
        let request = MarrCore.VisionRequest(systemPrompt: "Explain clearly.", messages: [
            VisionMessage(role: .user, content: [.text("Help me plan an experiment")])
        ])
        let response = try await fixture.controller.submit(request: request, workspaceID: workspace.id, onEvent: { _ in })
        XCTAssertEqual(response, "Local workspace answer")
        let captured = await fixture.client.requests
        XCTAssertEqual(captured.count, 1)
        XCTAssertTrue(captured[0].systemPrompt.contains("Research"))
        XCTAssertTrue(captured[0].systemPrompt.contains("/Projects/Research"))
        XCTAssertTrue(captured[0].systemPrompt.contains("do not claim file access"))
        XCTAssertFalse(fixture.controller.codexWorkspace.codexSyncEnabled)
        XCTAssertFalse(fixture.controller.usesCodexForConversation)
        XCTAssertEqual(fixture.controller.activeInferenceRequests, 0)
    }

    func testTextOnlyWorkspaceDraftIsDiscoverableAndRestoresAfterRestart() async throws {
        let fixture = try await fixture()
        let store = fixture.controller.historyStore
        let workspace = try await store.createWorkspace(name: "Writing")
        let session = ConversationSession(workspaceID: workspace.id)
        session.setArchiveHandler(persistImmediately: false) { store.save($0) }
        let key = ComposerDraftKey.conversation(session.id)
        let draftStore = fixture.controller.codexWorkspace.composerDraftStore
        XCTAssertTrue(draftStore.save(ComposerDraft(text: "An unsent question"), for: key))
        session.persistDraftIdentityIfNeeded()
        await store.waitForPendingOperations()
        let stored = try XCTUnwrap(store.conversations.first)
        XCTAssertEqual(stored.workspaceID, workspace.id)
        XCTAssertTrue(stored.turns.isEmpty)
        let restored = ConversationSession(historyRecord: stored, imageAssets: [])
        XCTAssertEqual(restored.workspaceID, workspace.id)
        XCTAssertEqual(ComposerDraftStore(rootURL: draftStore.rootURL).draft(for: key).text, "An unsent question")
    }

    func testDeletingConversationRemovesItsDraftAndCannotBeUndoneByLateSave() async throws {
        let fixture = try await fixture()
        let store = fixture.controller.historyStore
        let session = ConversationSession()
        session.setArchiveHandler { store.save($0) }
        let key = ComposerDraftKey.conversation(session.id)
        let drafts = fixture.controller.codexWorkspace.composerDraftStore
        let attachment = ConversationImageAsset(data: Data("draft attachment".utf8), mimeType: "text/plain", fileName: "notes.txt")
        XCTAssertTrue(drafts.save(ComposerDraft(text: "Draft", attachments: [attachment]), for: key))
        await store.waitForPendingOperations()
        store.delete(session.id)
        await store.waitForPendingOperations()
        XCTAssertTrue(drafts.draft(for: key).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: drafts.rootURL.appendingPathComponent("assets/\(attachment.id.uuidString)").path))
        session.setGeneratedTitle("A late result")
        await store.waitForPendingOperations()
        XCTAssertTrue(store.conversations.isEmpty)
        XCTAssertTrue(store.deletedConversationIDs.contains(session.id))
    }

    func testFreshSettingsUseIndependentChatGPTConnectionAndRetainSavedProvider() {
        let suite = "Marr.NativeDefaults.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = InferenceSettingsRepository(values: UserDefaultsSettingsStore(defaults: defaults), secrets: NativeSecrets())
        XCTAssertEqual(repository.loadConfiguration().provider, .chatGPT)
        var existing = repository.loadConfiguration()
        existing.provider = .gateway
        existing.model = "my-local-model"
        repository.saveConfiguration(existing)
        XCTAssertEqual(repository.loadConfiguration().provider, .gateway)
        XCTAssertEqual(repository.loadConfiguration().model, "my-local-model")
    }

    func testSettingsPageTitleRemainsVisibleWhileContentScrollsOffscreen() async throws {
        let fixture = try await fixture()
        for width: CGFloat in [414, 820] {
            for dark in [false, true] {
                let navigation = MarrSettingsNavigation()
                navigation.open(.conversation)
                let size = NSSize(width: width, height: 660)
                let host = NSHostingView(rootView: AnswerPanelSettingsView(controller: fixture.controller, navigation: navigation)
                    .frame(width: width, height: size.height)
                    .background(MarrUI.Surface.canvas)
                    .environment(\.colorScheme, dark ? .dark : .light))
                let window = MarrOffscreenTestWindow(contentRect: NSRect(origin: .zero, size: size),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                host.frame = NSRect(origin: .zero, size: size)
                defer { window.contentView = nil; window.close() }
                for _ in 0..<3 {
                    try await Task.sleep(for: .milliseconds(40))
                    host.layoutSubtreeIfNeeded()
                }
                func snapshot(_ suffix: String) throws -> CGFloat {
                    host.displayIfNeeded()
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let file = FileManager.default.temporaryDirectory.appendingPathComponent("marr-settings-page-\(Int(width))-\(dark ? "dark" : "light")\(suffix).png")
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: file)
                    let attachment = XCTAttachment(contentsOfFile: file); attachment.lifetime = .keepAlways; add(attachment)
                    print("MARR_SETTINGS_PREVIEW: \(file.path)")
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage)).perform([request])
                    let title = try XCTUnwrap(request.results?.filter {
                        $0.topCandidates(1).first?.string == "Conversation" && $0.boundingBox.minX > 0.14
                    }.max { $0.boundingBox.height < $1.boundingBox.height })
                    XCTAssertGreaterThan(title.boundingBox.minY, 0.75, "The page heading must stay above the scrollable settings")
                    return title.boundingBox.midY
                }
                let originalY = try snapshot("")
                func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
                if let scroll = descendants(host).compactMap({ $0 as? NSScrollView }).max(by: { $0.frame.width < $1.frame.width }),
                   let document = scroll.documentView {
                    document.scroll(NSPoint(x: 0, y: document.isFlipped ? document.bounds.height : 0))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    try await Task.sleep(for: .milliseconds(40))
                    host.layoutSubtreeIfNeeded()
                    XCTAssertEqual(try snapshot("-scrolled"), originalY, accuracy: 0.01)
                }
                XCTAssertFalse(window.isVisible)
            }
        }
    }

    private struct Fixture {
        let controller: MarrController
        let client: NativeClient
    }

    private func fixture(chatGPTSession: ChatGPTSession = .shared) async throws -> Fixture {
        let suite = "Marr.NativeWorkspace.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        let resources = MarrHistoryTestResources(rootURL: root)
        addTeardownBlock {
            try await resources.cleanUp()
            defaults.removePersistentDomain(forName: suite)
        }
        let store = resources.makeStore()
        await store.waitForPendingOperations()
        let repository = InferenceSettingsRepository(values: UserDefaultsSettingsStore(defaults: defaults), secrets: NativeSecrets())
        var settings = InferenceSettingsSnapshot.default
        settings.provider = .gateway
        settings.gatewayBaseURL = "http://127.0.0.1:1234/v1"
        settings.gatewayAuthScheme = .none
        settings.gatewayAPIFormat = .openAIChatCompletions
        settings.model = "local-model"
        repository.saveConfiguration(settings)
        let codex = RuntimeWorkspaceController(defaults: defaults, outboundMessage: { _ in
            XCTFail("Native workspace must not call Codex")
        }, attachmentDirectory: root.appendingPathComponent("WorkAttachments"),
            draftDirectory: root.appendingPathComponent("Drafts"))
        let client = NativeClient()
        let controller = MarrController(client: client, usesCodexForConversation: true,
            historyStore: store, tokenUsageStore: TokenUsageStore(rootURL: root),
            settingsRepository: repository, codexWorkspace: codex, chatGPTSession: chatGPTSession)
        return Fixture(controller: controller, client: client)
    }
}

private final class BackgroundCatalogStore: ChatGPTCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data
    init(data: Data) { self.data = data }
    func load() -> Data? { lock.withLock { data } }
    func save(_ data: Data) { lock.withLock { self.data = data } }
}

private actor BackgroundCatalogTransport: HTTPTransport {
    var requests = 0
    private var continuation: CheckedContinuation<Data, Never>?
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests += 1
        let data = await withCheckedContinuation { continuation = $0 }
        return (Data(#"{"models":\#(String(decoding: data, as: UTF8.self))}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func finish(_ data: Data) { continuation?.resume(returning: data); continuation = nil }
}

private struct BackgroundCatalogVerifier: ChatGPTIdentityVerifying {
    func verify(_ token: String, clientID: String, nonce: String?) async throws -> ChatGPTIdentity {
        .init(issuer: "https://auth.openai.com", subject: "test", email: "alex@example.com")
    }
}

private actor NativeClient: VisionAIClient {
    var requests: [MarrCore.VisionRequest] = []
    func ask(request: MarrCore.VisionRequest, model: String, connection: InferenceConnection) async throws -> String {
        requests.append(request)
        return "Local workspace answer"
    }
}

private struct NativeSecrets: SecretStore {
    func string(for account: String) throws -> String? { nil }
    func set(_ value: String, for account: String) throws {}
}
