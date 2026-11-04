import AppKit
import MarrCore
@testable import MarrNetworking
import MarrSettings
import QuartzCore
import SwiftUI
import XCTest
@testable import Marr

/// Real storage views rendered in isolated, never-visible AppKit windows.
@MainActor
final class MarrStorageSettingsTests: XCTestCase {
    func testConversationAndWorkStartPagesRenderAtBothWidthsAndAppearances() async throws {
        let fixture = try await makeFixture(populated: false)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("marr-agent-ui-preview")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for width in [420.0, 760.0] {
            for dark in [false, true] {
                for isWork in [false, true] {
                    let session = ConversationSession()
                    let panel = AnswerPanelController(controller: fixture.controller,
                        historyStore: fixture.controller.historyStore, session: session,
                        anchorRect: .zero, persistImmediately: false,
                        initialDestination: isWork ? .work : .conversation)
                    let window = panel.windowForTesting
                    defer { window.contentView = nil; panel.close() }
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.setFrame(window.frameRect(forContentRect: NSRect(x: 0, y: 0,
                        width: width + MarrPanelShellLayout.railWidth, height: 600)), display: false)
                    let content = try XCTUnwrap(window.contentView)
                    content.wantsLayer = true
                    content.layer?.backgroundColor = (dark ? NSColor(calibratedWhite: 0.12, alpha: 1)
                        : NSColor(calibratedWhite: 0.97, alpha: 1)).cgColor
                    let bitmap = try stableOffscreenBitmap(content, window: window)
                    let name = "start-\(isWork ? "work" : "conversation")-\(Int(width))-\(dark ? "dark" : "light").png"
                    let path = directory.appendingPathComponent(name)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: path)
                    let attachment = XCTAttachment(contentsOfFile: path)
                    attachment.lifetime = .keepAlways
                    add(attachment)
                    XCTAssertFalse(window.isVisible)
                    XCTAssertTrue(session.turns.isEmpty)
                }
            }
        }
    }

    func testStorageBreakdownRendersAtNarrowAndRegularWidthsInBothAppearances() async throws {
        let fixture = try await makeFixture(populated: true)
        let report = try XCTUnwrap(fixture.controller.historyStore.storageReport)
        XCTAssertEqual(report.conversationCount, 2)
        XCTAssertEqual(report.archivedConversationCount, 1)
        XCTAssertEqual(report.workspaceCount, 1)
        XCTAssertTrue(report.categories.allSatisfy { $0.bytes > 0 })
        XCTAssertTrue(report.warnings.isEmpty)
        XCTAssertFalse(fixture.controller.codexWorkspace.codexSyncEnabled)

        for width in [360.0, 620.0] {
            for dark in [false, true] {
                try render(MarrStorageSettingsView(controller: fixture.controller),
                    width: width, height: 820, dark: dark, defaults: fixture.defaults,
                    name: "storage-\(Int(width))-\(dark ? "dark" : "light")")
            }
        }
    }

    func testArchivedAndEmptyChatListsRenderWithoutVisibleWindows() async throws {
        let populated = try await makeFixture(populated: true)
        try render(MarrLocalChatStorageView(controller: populated.controller, archivedOnly: true),
            width: 360, height: 420, dark: true, defaults: populated.defaults, name: "storage-archived-narrow-dark")

        let empty = try await makeFixture(populated: false)
        XCTAssertTrue(empty.controller.historyStore.conversations.isEmpty)
        try render(MarrLocalChatStorageView(controller: empty.controller, archivedOnly: false),
            width: 360, height: 420, dark: false, defaults: empty.defaults, name: "storage-empty-narrow-light")
    }

    func testNativeWorkspaceLandingAndSidebarRenderWithoutCodex() async throws {
        let populated = try await makeFixture(populated: true)
        let store = populated.controller.historyStore
        XCTAssertEqual(store.workspaces.count, 1)
        XCTAssertEqual(store.conversations.filter { !$0.isArchived }.count, 1)
        for dark in [false, true] {
            try render(MarrLocalWorkLanding(store: store, onSelect: { _ in }) {
                TextField("开始构建，让想法成为现实。", text: .constant(""))
                    .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                    .padding(.horizontal, 24)
            },
                width: 620, height: 460, dark: dark, defaults: populated.defaults,
                name: "native-work-landing-\(dark ? "dark" : "light")")
            try render(VStack(alignment: .leading, spacing: 4) {
                MarrLocalWorkspaceSidebar(store: store,
                    currentConversationID: store.conversations.first(where: { !$0.isArchived })?.id,
                    currentWorkspaceID: store.workspaces.first?.id, searchText: "",
                    canChangeConversation: true, onNewWorkspace: {}, onNewConversation: { _ in }, onOpen: { _ in })
                Spacer(minLength: 0)
            }, width: 260, height: 360, dark: dark, defaults: populated.defaults,
                name: "native-work-sidebar-\(dark ? "dark" : "light")")
        }
        let empty = try await makeFixture(populated: false)
        try render(MarrLocalWorkLanding(store: empty.controller.historyStore, onSelect: { _ in }) {
                TextField("开始构建，让想法成为现实。", text: .constant(""))
                    .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                    .padding(.horizontal, 24)
            },
            width: 620, height: 460, dark: false, defaults: empty.defaults, name: "native-work-landing-empty")
    }

    func testProviderSelectionRestoresEditsAndRendersBrandIcons() async throws {
        let fixture = try await makeFixture(populated: false)
        let controller = fixture.controller
        controller.selectProvider("anthropic")
        XCTAssertEqual(controller.gatewayKeyCredential, .providerAPIKey(.anthropic))
        XCTAssertEqual(controller.gatewayAuthScheme, .xAPIKey)
        controller.model = "my-claude-deployment"
        controller.gatewayBaseURL = "https://proxy.example/v1"
        controller.selectProvider("google")
        XCTAssertEqual(controller.gatewayKeyCredential, .providerAPIKey(.google))
        XCTAssertEqual(controller.gatewayAPIFormat, .openAIChatCompletions)
        controller.selectProvider("anthropic")
        XCTAssertEqual(controller.model, "my-claude-deployment")
        XCTAssertEqual(controller.gatewayBaseURL, "https://proxy.example/v1")
        for preset in GatewayPreset.allCases {
            if let icon = preset.iconName { XCTAssertNotNil(NSImage(named: "Provider-" + icon)) }
        }
        for dark in [false, true] {
            try render(CompactProviderSettingsPanel(controller: controller, page: .conversation, openAccount: {}, refreshAccountsOnAppear: false),
                width: 620, height: 820, dark: dark, defaults: fixture.defaults,
                name: "providers-\(dark ? "dark" : "light")")
        }
        controller.selectProvider("ollama")
        XCTAssertEqual(controller.gatewayAuthScheme, .none)
        XCTAssertEqual(controller.model, "")
    }

    func testConnectionsSeparateManagementFromDefaultsAndShareTranslationCredentials() async throws {
        let fixture = try await makeFixture(populated: false)
        let controller = fixture.controller
        let original = controller.aiConnections.conversation
        let a = AIConnectionProfile(name: "Personal API", preset: .anthropic, baseURL: "https://personal.example/v1", models: ["shared-model"])
        let b = AIConnectionProfile(name: "Company API", preset: .anthropic, baseURL: "https://company.example/v1", authScheme: .none, models: ["shared-model"])
        controller.saveAIConnection(a)
        controller.saveAIConnection(b)
        XCTAssertEqual(controller.aiConnections.conversation, original)
        controller.chooseAIModel(connectionID: a.id, modelID: "shared-model")
        XCTAssertEqual(controller.gatewayKeyCredential, a.keyCredential)
        controller.chooseAIModel(connectionID: b.id, modelID: "shared-model", translation: true)
        XCTAssertEqual(controller.aiConnections.conversation.connectionID, a.id)
        XCTAssertEqual(controller.aiConnections.translation?.connectionID, b.id)
        XCTAssertEqual(controller.gatewayBaseURL, a.baseURL)
        let resolved = try await controller.resolvedTranslationConfiguration()
        guard case .ai(let model, let connection) = resolved else { return XCTFail("Expected the shared API connection") }
        XCTAssertEqual(model, "shared-model")
        XCTAssertEqual(connection.baseURL, b.baseURL)
        controller.removeAIConnection(a.id)
        XCTAssertNotNil(controller.aiConnections.connection(a.id))
        controller.followConversationForTranslation()
        XCTAssertNil(controller.aiConnections.translation)
        XCTAssertFalse(controller.translationUsesDedicatedConfiguration)
        controller.removeAIConnection(b.id)
        XCTAssertNil(controller.aiConnections.connection(b.id))
        let reloaded = InferenceSettingsRepository(values: UserDefaultsSettingsStore(defaults: fixture.defaults), secrets: StorageFixtureSecrets())
        XCTAssertEqual(reloaded.loadAIConnections(), controller.aiConnections)
        XCTAssertEqual(reloaded.loadConfiguration().gatewayBaseURL, a.baseURL)
        for width in [360.0, 620.0] {
            for dark in [false, true] {
                try render(CompactProviderSettingsPanel(controller: controller, page: .conversation, openAccount: {}, refreshAccountsOnAppear: false),
                    width: width, height: 920, dark: dark, defaults: fixture.defaults,
                    name: "ai-connections-\(Int(width))-\(dark ? "dark" : "light")")
            }
        }
    }

    func testModelReferenceSurvivesRestartBeforeLegacyDebounce() async throws {
        let fixture = try await makeFixture(populated: false)
        let controller = fixture.controller
        let connection = AIConnectionProfile(name: "Local", baseURL: "http://localhost:11434/v1",
            authScheme: .none, models: ["first", "second"])
        controller.saveAIConnection(connection)
        controller.chooseAIModel(connectionID: connection.id, modelID: "first")
        controller.model = "second"
        let repository = InferenceSettingsRepository(values: UserDefaultsSettingsStore(defaults: fixture.defaults), secrets: StorageFixtureSecrets())
        let restored = MarrController(client: StorageFixtureClient(), historyStore: controller.historyStore,
            settingsRepository: repository, codexWorkspace: controller.codexWorkspace)
        XCTAssertEqual(restored.model, "second")
        XCTAssertEqual(restored.gatewayKeyCredential, connection.keyCredential)
        XCTAssertEqual(restored.gatewayBaseURL, connection.baseURL)
    }

    private struct Fixture {
        let controller: MarrController
        let defaults: UserDefaults
    }

    private func makeFixture(populated: Bool) async throws -> Fixture {
        let suite = "Marr.StorageRendering.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        let resources = MarrHistoryTestResources(rootURL: root)
        addTeardownBlock {
            try await Task.sleep(for: .milliseconds(250))
            try await resources.cleanUp()
            defaults.removePersistentDomain(forName: suite)
        }
        let store = resources.makeStore()
        if populated {
            let workspace = try await store.createWorkspace(name: "Research and writing", path: "/Projects/Research")
            for archived in [false, true] {
                let date = Date(timeIntervalSince1970: 1_790_000_000)
                let asset = ConversationImageAsset(id: UUID(), data: Data(repeating: 0x42, count: archived ? 65_536 : 131_072),
                    mimeType: "application/pdf", fileName: "Research notes.pdf")
                let turn = ConversationTurn(id: UUID(), question: "Review my research notes.", imageIDs: [asset.id],
                    answer: "The notes are saved with this conversation.", errorMessage: nil,
                    status: .completed, showsAssistant: true)
                store.save(ConversationArchive(id: UUID(), createdAt: date, updatedAt: date,
                    generatedTitle: archived ? "Archived research notes and next steps" : "Review research notes",
                    turns: [turn], images: [asset], pendingImageIDs: [], workspaceID: workspace.id,
                    archivedAt: archived ? date : nil))
            }
            await store.waitForPendingOperations()
            let ownedWorkspaceData = root.appendingPathComponent("Workspaces", isDirectory: true)
            try FileManager.default.createDirectory(at: ownedWorkspaceData, withIntermediateDirectories: true)
            try Data(repeating: 0x43, count: 32_768).write(to: ownedWorkspaceData.appendingPathComponent("fixture.data"))
            try Data(repeating: 0x44, count: 16_384).write(to: root.appendingPathComponent("fixture-cache.data"))
        }
        let codex = RuntimeWorkspaceController(defaults: defaults, outboundMessage: { _ in
            XCTFail("Local storage rendering must not start Codex or send a message")
        }, attachmentDirectory: root.appendingPathComponent("WorkAttachments", isDirectory: true),
            draftDirectory: root.appendingPathComponent("Drafts", isDirectory: true), codexSyncEnabled: false)
        let settings = InferenceSettingsRepository(values: UserDefaultsSettingsStore(defaults: defaults),
            secrets: StorageFixtureSecrets())
        let controller = MarrController(client: StorageFixtureClient(), usesCodexForConversation: false, historyStore: store,
            tokenUsageStore: TokenUsageStore(rootURL: root.appendingPathComponent("Usage", isDirectory: true)),
            settingsRepository: settings, codexWorkspace: codex,
            chatGPTSession: ChatGPTSession(store: StorageEmptyAccountStore(), transport: StorageNoNetwork(), verifier: StorageNoIdentity()))
        store.refreshStorage()
        await store.waitForPendingOperations()
        XCTAssertNil(store.lastErrorMessage)
        return Fixture(controller: controller, defaults: defaults)
    }

    private func render<Content: View>(_ content: Content, width: CGFloat, height: CGFloat,
                                      dark: Bool, defaults: UserDefaults, name: String) throws {
        let window = MarrOffscreenTestWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: ScrollView {
            content.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(width: width, height: height)
            .background(dark ? Color(white: 0.12) : Color.white)
            .environment(\.colorScheme, dark ? .dark : .light).defaultAppStorage(defaults))
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let bitmap = try stableOffscreenBitmap(host, window: window)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
        XCTAssertEqual(CGFloat(bitmap.pixelsWide) / CGFloat(bitmap.pixelsHigh), width / height, accuracy: 0.01)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("marr-agent-ui-preview", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(name + ".png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: path)
        let attachment = XCTAttachment(contentsOfFile: path)
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
    }

    private func stableOffscreenBitmap(_ content: NSView, window: NSWindow) throws -> NSBitmapImageRep {
        let start = Date()
        let deadline = start.addingTimeInterval(3)
        var previousPixels: Data?
        var consecutiveMatches = 0
        var result: NSBitmapImageRep?
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            XCTAssertFalse(window.isVisible)
            XCTAssertFalse(window.isKeyWindow)
            content.needsLayout = true
            content.layoutSubtreeIfNeeded()
            func invalidate(_ view: NSView) {
                view.needsDisplay = true
                view.subviews.forEach(invalidate)
            }
            invalidate(content)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            content.effectiveAppearance.performAsCurrentDrawingAppearance {
                window.displayIfNeeded()
                content.displayIfNeeded()
                content.layer?.layoutIfNeeded()
                content.layer?.displayIfNeeded()
            }
            CATransaction.commit()
            CATransaction.flush()
            let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.effectiveAppearance.performAsCurrentDrawingAppearance {
                content.cacheDisplay(in: content.bounds, to: bitmap)
            }
            let pixels = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            consecutiveMatches = pixels == previousPixels ? consecutiveMatches + 1 : 0
            previousPixels = pixels
            result = bitmap
            if Date().timeIntervalSince(start) >= 0.35, consecutiveMatches >= 3 { return bitmap }
        } while Date() < deadline
        XCTFail("Storage view did not reach stable offscreen pixels within three seconds")
        return try XCTUnwrap(result)
    }
}

private struct StorageFixtureClient: VisionAIClient {
    func ask(request: VisionRequest, model: String, connection: InferenceConnection) async throws -> String {
        XCTFail("Storage rendering must not issue inference requests")
        return ""
    }
}

private struct StorageFixtureSecrets: SecretStore {
    func string(for account: String) throws -> String? { nil }
    func set(_ value: String, for account: String) throws {
        XCTFail("Storage rendering must not write credentials")
    }
}

private struct StorageEmptyAccountStore: ChatGPTCredentialStoring {
    func load() throws -> Data? { try JSONEncoder().encode(ChatGPTSavedState()) }
    func save(_ data: Data) throws { XCTFail("Layout rendering must not write credentials") }
}
private struct StorageNoNetwork: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        XCTFail("Layout rendering must not make account requests")
        throw URLError(.notConnectedToInternet)
    }
}
private struct StorageNoIdentity: ChatGPTIdentityVerifying {
    func verify(_ token: String, clientID: String, nonce: String?) async throws -> ChatGPTIdentity {
        XCTFail("Layout rendering must not authenticate")
        throw URLError(.notConnectedToInternet)
    }
}
