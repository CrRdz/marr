import AppKit
import MarrCore
@testable import MarrNetworking
import MarrSettings
import QuartzCore
import SwiftUI
import XCTest
@testable import Marr

/// Exercises the real panel and sidebar without presenting, ordering or
/// activating a window. All persistence and transport dependencies are local.
@MainActor
final class MarrHistorySidebarRenderingTests: XCTestCase {
    func testWelcomeOpensAISettingsOnFirstPanelOffscreen() async throws {
        let previews = FileManager.default.temporaryDirectory.appendingPathComponent("marr-welcome-preview")
        try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
        try await renderFixture(conversationWidth: 720, theme: "light",
            appearance: XCTUnwrap(NSAppearance(named: .aqua)), previews: previews,
            rendersSettings: true, settingsDestination: .aiModels)
    }

    func testWelcomeWindowUsesConversationChromeWithoutPresenting() throws {
        let controller = try makeWelcomeController()
        let welcome = MarrWelcomeWindowController(controller: controller)
        let window = try XCTUnwrap(welcome.window)
        defer { window.contentView = nil; welcome.close() }
        XCTAssertTrue(window is AnswerPanelWindow)
        XCTAssertTrue(window.contentView is AnswerPanelContentView)
        XCTAssertEqual(window.styleMask, AnswerPanelWindow.standardStyleMask)
        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(window.backgroundColor, .clear)
        XCTAssertEqual(window.contentMinSize, NSSize(width: 540, height: 600))
        try assertOffscreen(window)
    }

    func testWelcomeCompletionRequiresExplicitFinish() throws {
        let suite = "MarrWelcomeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let progress = MarrWelcomeProgress(defaults: defaults)
        XCTAssertFalse(progress.isComplete)
        progress.back()
        XCTAssertEqual(progress.step, .welcome)
        progress.next()
        XCTAssertEqual(progress.step, .capture)
        progress.next()
        XCTAssertEqual(progress.step, .ask)
        progress.next()
        XCTAssertEqual(progress.step, .connect)
        progress.next()
        progress.next()
        XCTAssertEqual(progress.step, .ready)
        XCTAssertFalse(MarrWelcomeProgress(defaults: defaults).isComplete)
        progress.back()
        XCTAssertEqual(progress.step, .connect)
        progress.finish()
        XCTAssertTrue(MarrWelcomeProgress(defaults: defaults).isComplete)
    }

    func testWelcomeRendersAllStepsOffscreen() async throws {
        let controller = try makeWelcomeController()
        let previews = FileManager.default.temporaryDirectory.appendingPathComponent("marr-welcome-preview")
        try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
        for dark in [false, true] {
            for step in MarrWelcomeProgress.Step.allCases {
                let progress = MarrWelcomeProgress()
                progress.step = step
                let size = NSSize(width: dark ? 540 : 640, height: dark ? 600 : 680)
                let window = MarrOffscreenTestWindow(contentRect: NSRect(origin: .zero, size: size),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                defer { window.contentView = nil; window.close() }
                let host = NSHostingView(rootView: MarrWelcomeView(progress: progress, controller: controller,
                    refreshAccountsOnAppear: false, onFinish: {
                        XCTFail("Rendering must not complete onboarding")
                    })
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.marrAccessibilityOverrides, MarrAccessibilityPreferences(
                        reducesMotion: true, reducesTransparency: true, increasedContrast: false))
                    .frame(width: size.width, height: size.height))
                window.contentView = host
                host.frame = NSRect(origin: .zero, size: size)
                let bitmap = try stableOffscreenBitmap(host, window: window)
                let url = previews.appendingPathComponent("welcome-\(step.rawValue)-\(dark ? "dark" : "light").png")
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
                let attachment = XCTAttachment(contentsOfFile: url); attachment.lifetime = .keepAlways; add(attachment)
                XCTAssertEqual(host.fittingSize.width, size.width, accuracy: 1)
                try assertOffscreen(window)
                print("Welcome preview: \(url.path)")
            }
        }
    }

    func testWelcomeEmbeddedAPIEditorRendersOffscreen() async throws {
        let controller = try makeWelcomeController()
        let connection = AIConnectionProfile(id: "welcome-fixture", name: "My API",
            baseURL: "https://example.invalid/v1", models: ["example-model"])
        controller.saveAIConnection(connection)
        let size = NSSize(width: 540, height: 600)
        let window = MarrOffscreenTestWindow(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.appearance = NSAppearance(named: .aqua)
        let host = NSHostingView(rootView: ScrollView {
            AIConnectionEditor(controller: controller, connection: connection, isEmbedded: true, onDone: {})
                .padding(24)
        }.frame(width: size.width, height: size.height).background(MarrUI.Surface.canvas)
            .environment(\.colorScheme, .light))
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        let bitmap = try stableOffscreenBitmap(host, window: window)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("marr-welcome-preview/welcome-api-editor.png")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        let attachment = XCTAttachment(contentsOfFile: url); attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertEqual(host.fittingSize.width, size.width, accuracy: 1)
        XCTAssertFalse(controller.credentialState(for: connection.keyCredential).isConfigured ?? false)
        try assertOffscreen(window)
    }

    private func makeWelcomeController() throws -> MarrController {
        let suite = "Marr.Welcome.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let resources = MarrHistoryTestResources(rootURL: directory)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try await resources.cleanUp()
        }
        let workspace = RuntimeWorkspaceController(defaults: defaults, outboundMessage: { _ in
            XCTFail("Onboarding must not send runtime requests")
        }, attachmentDirectory: directory.appendingPathComponent("Attachments"),
           draftDirectory: directory.appendingPathComponent("Drafts"), codexSyncEnabled: false)
        return MarrController(client: HistorySidebarFixtureClient(),
            historyStore: resources.makeStore(at: directory.appendingPathComponent("History")),
            tokenUsageStore: TokenUsageStore(rootURL: directory.appendingPathComponent("Usage")),
            settingsRepository: InferenceSettingsRepository(values: UserDefaultsSettingsStore(defaults: defaults),
                secrets: HistorySidebarFixtureSecrets()), codexWorkspace: workspace,
            chatGPTSession: ChatGPTSession(store: WelcomeEmptyAccountStore(), transport: WelcomeNoNetwork(), verifier: WelcomeNoIdentity()))
    }

    func testAccountMenuRendersInBothAppearancesOffscreen() throws {
        let previews = FileManager.default.temporaryDirectory.appendingPathComponent("marr-agent-ui-preview")
        try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
        for dark in [false, true] {
            let size = NSSize(width: 240, height: 146)
            let window = MarrOffscreenTestWindow(contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            defer { window.contentView = nil; window.close() }
            let host = NSHostingView(rootView: MarrAccountMenuContent(entries: [
                .init(id: "plan", title: "ChatGPT Plan", detail: "user@example.com", iconName: "openai"),
                .init(id: "claude", title: "Anthropic · Claude", detail: "claude-sonnet", iconName: "anthropic", section: .conversation)
            ], onOpenEntry: { _ in }, onOpenSettings: {})
                .frame(width: size.width, height: size.height)
                .background(dark ? Color(white: 0.16) : .white)
                .environment(\.colorScheme, dark ? .dark : .light))
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: size)
            let bitmap = try stableOffscreenBitmap(host, window: window)
            let url = previews.appendingPathComponent("account-menu-\(dark ? "dark" : "light").png")
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
            let attachment = XCTAttachment(contentsOfFile: url); attachment.lifetime = .keepAlways; add(attachment)
            try assertOffscreen(window)
        }
    }

    func testAccountMenuIsAnchoredBesideAvatarOffscreen() throws {
        let size = NSSize(width: 484, height: 596)
        let window = MarrOffscreenTestWindow(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let host = NSHostingView(rootView: HStack(spacing: 0) {
            MarrNavigationRail(selection: .constant(.chats), showsAccountMenu: true)
            Color.clear
        }
        .overlayPreferenceValue(MarrAccountAnchorKey.self) { anchor in
            if let anchor {
                MarrAnchoredAccountMenu(anchor: anchor, entries: [
                    .init(id: "plan", title: "ChatGPT Plan", detail: "user@example.com", iconName: "openai")
                ], onDismiss: {}, onOpenEntry: { _ in }, onOpenSettings: {})
            }
        }
        .frame(width: size.width, height: size.height).background(Color.white)
        .environment(\.colorScheme, .light))
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        let bitmap = try stableOffscreenBitmap(host, window: window)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("marr-account-anchored.png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        let attachment = XCTAttachment(contentsOfFile: url); attachment.lifetime = .keepAlways; add(attachment)
        try assertOffscreen(window)
    }

    func testAccountUsageRendersWithTenThousandEventsOffscreen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let resources = MarrHistoryTestResources(rootURL: root)
        addTeardownBlock { try await resources.cleanUp() }
        let history = resources.makeStore(at: root.appendingPathComponent("History"))
        let now = Date()
        let events = (0..<10_000).map { index in
            TokenUsageEvent(id: UUID(), date: now.addingTimeInterval(-Double(index) * 1800),
                inputTokens: 100, outputTokens: 50)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(events).write(to: root.appendingPathComponent("token-usage.json"))
        let usage = TokenUsageStore(rootURL: root)
        XCTAssertEqual(usage.events.count, 10_000)
        let size = NSSize(width: 560, height: 420)
        let window = MarrOffscreenTestWindow(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let start = CACurrentMediaTime()
        let host = NSHostingView(rootView: CompactUsageSettingsPanel(usageStore: usage, historyStore: history)
            .padding(16).frame(width: size.width, height: size.height))
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        _ = try stableOffscreenBitmap(host, window: window)
        let duration = CACurrentMediaTime() - start
        print("Account usage render with 10000 events: \(duration) seconds")
        XCTAssertLessThan(duration, 3, "Account usage must not repeatedly aggregate history for each calendar cell")
        try assertOffscreen(window)
    }

    func testGlobalConversationSearchRendersOffscreen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let resources = MarrHistoryTestResources(rootURL: directory)
        addTeardownBlock { try await resources.cleanUp() }
        let store = resources.makeStore()
        for archive in try archives(now: Date()) { store.save(archive) }
        await store.waitForPendingOperations()
        let suite = "Marr.SearchPreview.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = RuntimeWorkspaceController(defaults: defaults, outboundMessage: { _ in
            XCTFail("Search must not send a model request")
        }, attachmentDirectory: directory.appendingPathComponent("Attachments"),
           draftDirectory: directory.appendingPathComponent("Drafts"), codexSyncEnabled: true)
        let project = workspace.workbench.ensureWorkspace(url: URL(fileURLWithPath: "/Projects/OpenLens"))
        _ = workspace.workbench.upsertRemoteTask(workspaceID: project.id, threadID: "search-fixture", title: "Polish the sidebar",
            state: .completed, statusMessage: "Saved", createdAt: Date(), updatedAt: Date())
        let previews = FileManager.default.temporaryDirectory.appendingPathComponent("marr-agent-ui-preview")
        try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
        for dark in [false, true] {
            let window = MarrOffscreenTestWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 440),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let host = NSHostingView(rootView: AnyView(MarrGlobalConversationSearch(store: store, workspace: workspace,
                canOpenLocal: true, onOpenLocal: { _ in }, onOpenTask: { _ in true })
                .environment(\.colorScheme, dark ? .dark : .light)
                .background(dark ? Color(white: 0.12) : Color.white)))
            window.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: 440, height: 440)
            let bitmap = try stableOffscreenBitmap(host, window: window)
            let url = previews.appendingPathComponent("global-search-\(dark ? "dark" : "light").png")
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
            let attachment = XCTAttachment(contentsOfFile: url); attachment.lifetime = .keepAlways; add(attachment)
            try assertOffscreen(window)
            host.rootView = AnyView(EmptyView())
            host.layoutSubtreeIfNeeded()
            window.contentView = nil
            window.close()
        }
    }

    func testThoughtTimelinePreviewAndExpansionRenderWithoutVisibleWindows() throws {
        let source = "I’m checking the conversation layout and how the saved images are restored.\n\n"
            + "The preview uses `HistoryImages` and preserves **the original message**. 正在检查正文与状态的层级。\n\n"
            + String(repeating: "The next step is to verify the result in both appearances.\n\n", count: 20)
        let previews = FileManager.default.temporaryDirectory.appendingPathComponent("marr-agent-ui-preview")
        try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
        for dark in [false, true] {
            for expanded in [false, true] {
                let width: CGFloat = expanded ? 340 : 600
                let height: CGFloat = expanded ? 650 : 340
                let window = MarrOffscreenTestWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                defer { window.contentView = nil; window.close() }
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let host = NSHostingView(rootView: ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Thought process").marrTextStyle(.secondary)
                            .foregroundStyle(MarrPanelColors.secondary(for: dark ? .dark : .light))
                            .padding(.bottom, 12)
                        MarrProcessTimelineRow(symbol: "clock") {
                            MarrThoughtText(source: source, initiallyExpanded: expanded)
                        }
                        MarrProcessTimelineRow(symbol: "checkmark.circle", connectsToNext: false) {
                            Text("Done").marrTextStyle(.body)
                                .foregroundStyle(MarrPanelColors.secondary(for: dark ? .dark : .light))
                        }
                    }.padding(24)
                }.frame(width: width, height: height)
                    .background(dark ? Color(white: 0.12) : Color.white)
                    .environment(\.colorScheme, dark ? .dark : .light))
                window.contentView = host
                host.frame = NSRect(x: 0, y: 0, width: width, height: height)
                let bitmap = try stableOffscreenBitmap(host, window: window)
                let file = previews.appendingPathComponent("thought-process-\(dark ? "dark" : "light")-\(expanded ? "expanded" : "preview").png")
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: file)
                let attachment = XCTAttachment(contentsOfFile: file)
                attachment.lifetime = .keepAlways
                add(attachment)
                try assertOffscreen(window)
            }
        }
    }

    func testSelectedWorkspaceAndPinnedGroupsRenderInBothAppearances() throws {
        let suite = "Marr.SidebarSelection.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(MarrAccentColor.system.rawValue, forKey: MarrAccentColor.storageKey)
        let workspace = RuntimeWorkspaceController(defaults: defaults, outboundMessage: { _ in }, codexSyncEnabled: true)
        let store = workspace.workbench
        let first = store.upsertWorkspace(url: URL(fileURLWithPath: "/tmp/OpenLens"), bookmark: Data())
        store.toggleWorkspacePinned(first.id)
        _ = store.upsertWorkspace(url: URL(fileURLWithPath: "/tmp/chess-replay-lab"), bookmark: Data())
        let now = Date()
        _ = store.upsertRemoteTask(workspaceID: UUID(), threadID: "mixed-preview", title: "Review conversation layout",
            state: .completed, statusMessage: "Done", createdAt: now, updatedAt: now.addingTimeInterval(-30))
        store.importThreadSidebarMetadata(["id": "mixed-preview", "marrExplicitProjectless": true])
        let localRecords = [
            ConversationHistoryRecord(id: UUID(), createdAt: now, updatedAt: now,
                generatedTitle: "Translate lecture notes", turns: [], images: [], pendingImageIDs: []),
            ConversationHistoryRecord(id: UUID(), createdAt: now, updatedAt: now.addingTimeInterval(-60),
                generatedTitle: "Explain this screenshot", turns: [], images: [], pendingImageIDs: [])
        ]
        let previews = FileManager.default.temporaryDirectory.appendingPathComponent("marr-agent-ui-preview")
        try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
        for dark in [false, true] {
            let window = MarrOffscreenTestWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 320),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.contentView = nil; window.close() }
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 4) {
                MarrWorkspaceSidebar(workspace: workspace, searchText: .constant(""),
                    collapsedWorkspaceIDs: .constant(Set(store.workspaces.map(\.id))), expandedWorkspaceIDs: .constant([]),
                    isWorkActive: false, onSelectTask: {}, onNewTask: {},
                    localConversations: localRecords, currentLocalID: localRecords[0].id)
                Spacer()
            }.padding(12).frame(width: 300, height: 320)
                .background(dark ? Color(white: 0.12) : Color.white)
                .defaultAppStorage(defaults).environment(\.colorScheme, dark ? .dark : .light))
            window.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: 300, height: 320)
            let bitmap = try stableOffscreenBitmap(host, window: window)
            let file = previews.appendingPathComponent("sidebar-pins-\(dark ? "dark" : "light").png")
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: file)
            print("Sidebar pins preview: \(file.path)")
            let attachment = XCTAttachment(contentsOfFile: file)
            attachment.lifetime = .keepAlways
            add(attachment)
            try assertOffscreen(window)
        }
    }

    func testUserAttachmentsRenderInsideTheirMessageInLightDarkAndNarrowLayouts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("marr-attachments-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for portrait in [false, true] {
        let imageHeight: CGFloat = portrait ? 480 : 200
        let screenshot = NSImage(size: NSSize(width: 360, height: imageHeight))
        screenshot.lockFocus()
        NSColor.systemIndigo.setFill()
        NSRect(x: 0, y: 0, width: 360, height: imageHeight).fill()
        ("Screenshot preview" as NSString).draw(at: NSPoint(x: 22, y: imageHeight / 2), withAttributes: [
            .font: NSFont.systemFont(ofSize: 26), .foregroundColor: NSColor.white
        ])
        screenshot.unlockFocus()
        let path = directory.appendingPathComponent(portrait ? "portrait.png" : "截图 2026-10-24.png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(screenshot.tiffRepresentation)))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: path)
        let envelope = "# Files mentioned by the user:\n## 截图.png: \(path.path)\nImage attachment: true\n## My request:\n还有这种东西 处理一下"
        let message = UserMessagePresentation("legacy Image: \(path.path)", rawJSON: CodexProtocolJSON.pretty([
            "type": "userMessage", "content": [
                ["type": "text", "text": envelope], ["type": "localImage", "path": path.path],
                ["type": "localImage", "path": directory.appendingPathComponent("missing.png").path]
            ]
        ]))
        XCTAssertEqual(message.attachments.count, 2, "Envelope and structured attachment must share one preview")
        XCTAssertEqual(message.body, "还有这种东西 处理一下")
        let previews = FileManager.default.temporaryDirectory.appendingPathComponent("marr-agent-ui-preview")
        try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
        for width in [340.0, 640.0] {
            for dark in [false, true] {
                let window = MarrOffscreenTestWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 540),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                defer { window.contentView = nil; window.close() }
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let host = NSHostingView(rootView:
                    HStack {
                        Spacer(minLength: 24)
                        UserMessageContent(presentation: message)
                            .marrTextStyle(.answer).padding(12)
                            .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background(dark ? Color(white: 0.12) : Color.white)
                    .environment(\.colorScheme, dark ? .dark : .light))
                window.contentView = host
                host.frame = NSRect(x: 0, y: 0, width: width, height: 540)
                let capture = try stableOffscreenBitmap(host, window: window)
                let url = previews.appendingPathComponent("user-attachments-\(Int(width))-\(dark ? "dark" : "light")\(portrait ? "-portrait" : "").png")
                try XCTUnwrap(capture.representation(using: .png, properties: [:])).write(to: url)
                let attachment = XCTAttachment(contentsOfFile: url)
                attachment.lifetime = .keepAlways
                add(attachment)
                try assertOffscreen(window)
            }
        }
        }
    }

    func testUserFacingTranscriptRendersCollapsedInLightDarkAndNarrowLayouts() throws {
        let suite = "Marr.TranscriptPresentation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkbenchStore(defaults: defaults)
        let project = store.upsertWorkspace(url: directory, bookmark: Data())
        let task = store.createTask(workspaceID: project.id, prompt: "Review the sidebar changes")
        store.updateTask(id: task.id, threadID: "presentation", state: .completed)
        var requests: [[String: Any]] = []
        let workspace = RuntimeWorkspaceController(defaults: defaults, outboundMessage: { requests.append($0) },
            attachmentDirectory: directory.appendingPathComponent("Attachments"), codexSyncEnabled: true)
        defer { workspace.flushPendingTaskSnapshot() }
        workspace.refreshSelectedTask()
        let read = try XCTUnwrap(requests.last { $0["method"] as? String == "thread/read" })
        let items: [[String: Any]] = [
            ["id": "user", "type": "userMessage", "content": [["type": "text", "text": "Review the sidebar changes and explain what is ready."]]],
            ["id": "progress", "type": "agentMessage", "phase": "commentary", "text": "I’m checking the implementation and tests."],
            ["id": "thought", "type": "reasoning", "summary": [String(repeating: "Reasoning summary. ", count: 500)]],
            ["id": "search", "type": "commandExecution", "command": "/bin/zsh -lc 'rg missing-pattern Sources'", "exitCode": 1,
             "aggregatedOutput": "No matches"],
            ["id": "tool", "type": "commandExecution", "command": "/bin/zsh -lc 'scripts/test-marr.sh -only-testing:MarrTests/Example'", "exitCode": 65,
             "aggregatedOutput": String(repeating: "Test output\n", count: 1500)],
            ["id": "retry", "type": "commandExecution", "command": "swift test", "exitCode": 0,
             "aggregatedOutput": "Tests passed after correction"],
            ["id": "final", "type": "agentMessage", "phase": "final_answer", "text": "The sidebar is ready.\n\n- Conversations stay grouped by project.\n- Collapsing the sidebar preserves your window width.\n- Keyboard navigation and saved selection passed validation.\n\nOpen a conversation to continue where you left off."]
        ]
        workspace.receiveServerMessage(["id": try XCTUnwrap(read["id"]), "result": ["thread": [
            "id": "presentation", "cwd": directory.path, "status": ["type": "idle"],
            "turns": [["id": "turn", "status": "completed", "durationMs": 12000, "items": items]]]]])
        let previews = FileManager.default.temporaryDirectory.appendingPathComponent("marr-agent-ui-preview")
        try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
        for width in [420.0, 820.0] {
            for dark in [false, true] {
                let window = MarrOffscreenTestWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 580),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                defer { window.contentView = nil; window.close() }
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let host = NSHostingView(rootView: WorkActivityTimeline(workspace: workspace)
                    .padding(20).background(dark ? Color(white: 0.12) : Color.white)
                    .environment(\.colorScheme, dark ? .dark : .light))
                window.contentView = host
                host.frame = NSRect(x: 0, y: 0, width: width, height: 580)
                let bitmap = try stableOffscreenBitmap(host, window: window)
                func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
                let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first)
                XCTAssertLessThan(try XCTUnwrap(scroll.documentView).frame.height, 700,
                    "Failed attempts and 1,500 tool-output lines must remain folded after recovery")
                let url = previews.appendingPathComponent("transcript-\(Int(width))-\(dark ? "dark" : "light").png")
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
                print("Transcript preview: \(url.path)")
                let attachment = XCTAttachment(contentsOfFile: url)
                attachment.lifetime = .keepAlways
                add(attachment)
                try assertOffscreen(window)
            }
        }
    }

    func testLoadedWorkTranscriptScrollReusesToolPresentationOffscreen() throws {
        let suite = "Marr.WorkScroll.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkbenchStore(defaults: defaults)
        let project = store.upsertWorkspace(url: directory, bookmark: Data())
        let task = store.createTask(workspaceID: project.id, prompt: "Work history fixture")
        store.updateTask(id: task.id, threadID: "work-scroll", state: .completed)
        defaults.set(Data(), forKey: "codex.workspace.bookmark")
        var requests: [[String: Any]] = []
        let workspace = RuntimeWorkspaceController(defaults: defaults, outboundMessage: { requests.append($0) },
            attachmentDirectory: directory.appendingPathComponent("Attachments"), codexSyncEnabled: true)
        defer { workspace.flushPendingTaskSnapshot() }
        workspace.refreshSelectedTask()
        let read = try XCTUnwrap(requests.last { $0["method"] as? String == "thread/read" })
        let turnCount = 80
        let toolCount = 12
        let turns: [[String: Any]] = (0..<turnCount).map { turn in
            var items: [[String: Any]] = [["id": "user", "type": "userMessage", "content": [
                ["type": "text", "text": "Review workspace change \(turn)"]]]]
            items += (0..<toolCount).map { tool in
                ["id": "tool-\(tool)", "type": "commandExecution", "command": "fixture-tool-\(tool)",
                 "exitCode": 0, "aggregatedOutput": String(repeating: "Historical tool output line.\n", count: 150)]
            }
            items.append(["id": "answer", "type": "agentMessage", "text": "## Result \(turn)\n\nReviewed **workspace changes** and preserved the conversation.\n\n- First finding\n- Second finding\n\nMore explanation with `inline code` and a [reference](https://example.com)."])
            return ["id": "turn-\(turn)", "status": "completed", "items": items]
        }
        workspace.receiveServerMessage(["id": try XCTUnwrap(read["id"]), "result": ["thread": [
            "id": "work-scroll", "cwd": directory.path, "status": ["type": "idle"], "turns": turns]]])
        XCTAssertEqual(workspace.activities.count, turnCount * (toolCount + 2))
        let window = MarrOffscreenTestWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let host = NSHostingView(rootView: WorkActivityTimeline(workspace: workspace).padding(16))
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 720, height: 560)
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first)
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(document.frame.height, scroll.contentView.bounds.height * 5)
        MarrWorkRenderDiagnostics.timelineEvaluations = 0
        let initialToolParses = MarrWorkRenderDiagnostics.toolParses
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        var durations: [Double] = []
        for step in 0..<80 {
            let started = CACurrentMediaTime()
            // Traverse the same range twice to exercise offscreen row reuse.
            let distance = CGFloat(step < 40 ? step : 79 - step) * 150
            let y = min(distance, max(0, document.frame.height - scroll.contentView.bounds.height))
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            RunLoop.main.run(until: Date().addingTimeInterval(0.002))
            host.layoutSubtreeIfNeeded()
            durations.append((CACurrentMediaTime() - started) * 1000)
        }
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        XCTAssertEqual(MarrWorkRenderDiagnostics.timelineEvaluations, 0, "Scrolling must not reevaluate the entire work timeline")
        XCTAssertLessThanOrEqual(MarrWorkRenderDiagnostics.toolParses - initialToolParses, turnCount * toolCount,
                                "A tool is parsed at most once while revisiting unchanged turns")
        let ordered = durations.sorted()
        let report = "Work transcript: \(turnCount) turns, \(turnCount * toolCount) tools, 80 scroll steps; median \(ordered[40]) ms; p95 \(ordered[76]) ms; timeline evaluations \(MarrWorkRenderDiagnostics.timelineEvaluations); new tool parses \(MarrWorkRenderDiagnostics.toolParses - initialToolParses)"
        print(report)
        let attachment = XCTAttachment(string: report)
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertFalse(requests.contains { ["turn/start", "thread/resume"].contains($0["method"] as? String ?? "") })
    }

    func testHistorySidebarRendersBesideConversationAndSurvivesPanelReplacementOffscreen() async throws {
        let appearanceKey = MarrAppearanceKeys.colorScheme
        let originalAppearance = UserDefaults.standard.object(forKey: appearanceKey)
        let glassKey = MarrAppearanceKeys.glassSurfaces
        let originalGlass = UserDefaults.standard.object(forKey: glassKey)
        // Native liquid glass needs the visible window-server compositor.
        // Use the app's supported material fallback for offscreen inspection.
        UserDefaults.standard.set(false, forKey: glassKey)
        defer {
            if let originalAppearance { UserDefaults.standard.set(originalAppearance, forKey: appearanceKey) }
            else { UserDefaults.standard.removeObject(forKey: appearanceKey) }
            if let originalGlass { UserDefaults.standard.set(originalGlass, forKey: glassKey) }
            else { UserDefaults.standard.removeObject(forKey: glassKey) }
        }
        let previews = FileManager.default.temporaryDirectory
            .appendingPathComponent("marr-agent-ui-preview", isDirectory: true)
        try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)

        for (theme, appearanceName) in [("Light", NSAppearance.Name.aqua), ("Dark", .darkAqua)] {
            UserDefaults.standard.set(theme, forKey: appearanceKey)
            for conversationWidth: CGFloat in [420, 680] {
                try await renderFixture(conversationWidth: conversationWidth, theme: theme.lowercased(),
                                        appearance: XCTUnwrap(NSAppearance(named: appearanceName)), previews: previews)
            }
        }
    }

    func testHistoryProjectionUpdatesWithoutAnyVisibleRows() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let resources = MarrHistoryTestResources(rootURL: directory)
        addTeardownBlock { try await resources.cleanUp() }
        let store = resources.makeStore()
        let projection = MarrHistoryProjection(store: store, query: "")
        let fixtures = try archives(now: Date())
        store.save(fixtures[0])
        await store.waitForPendingOperations()
        XCTAssertEqual(projection.sections.flatMap(\.conversations).count, 1)
        store.save(fixtures[1])
        await store.waitForPendingOperations()
        XCTAssertEqual(projection.sections.flatMap(\.conversations).count, 2)
        projection.updateQuery("a-query-that-does-not-match")
        XCTAssertTrue(projection.sections.isEmpty)
        projection.updateQuery("")
        XCTAssertEqual(projection.sections.flatMap(\.conversations).count, 2)
        store.delete(fixtures[0].id)
        await store.waitForPendingOperations()
        XCTAssertEqual(projection.sections.flatMap(\.conversations).map(\.id), [fixtures[1].id])
    }

    func testLongHistoryScrollRemainsIsolatedOffscreen() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("marr-agent-ui-preview")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await renderFixture(conversationWidth: 420, theme: "light",
            appearance: XCTUnwrap(NSAppearance(named: .aqua)), previews: folder, longHistory: true)
    }

    func testUnifiedSettingsScaleRendersOffscreenInBothThemes() async throws {
        let defaults = UserDefaults.standard
        let keys = [MarrAppearanceKeys.colorScheme, MarrAppearanceKeys.glassSurfaces]
        let originals = keys.map { defaults.object(forKey: $0) }
        defaults.set(false, forKey: MarrAppearanceKeys.glassSurfaces)
        defer {
            for (key, original) in zip(keys, originals) {
                if let original { defaults.set(original, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("marr-agent-ui-preview")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            defaults.set(theme == "dark" ? "Dark" : "Light", forKey: MarrAppearanceKeys.colorScheme)
            try await renderFixture(conversationWidth: 720, theme: theme,
                appearance: XCTUnwrap(NSAppearance(named: appearance)), previews: folder, rendersSettings: true)
        }
    }

    private func renderFixture(conversationWidth: CGFloat, theme: String, appearance: NSAppearance,
                               previews: URL, longHistory: Bool = false, rendersSettings: Bool = false,
                               settingsDestination: AnswerPanelUtilityDestination = .settings) async throws {
        let suite = "Marr.HistorySidebarRendering.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let resources = MarrHistoryTestResources(rootURL: directory)
        addTeardownBlock {
            // The real panel's hosting tree can be retained until SwiftUI's
            // deferred transaction completes, after this fixture leaves scope.
            try await Task.sleep(for: .milliseconds(250))
            try await resources.cleanUp()
        }
        let history = resources.makeStore(at: directory.appendingPathComponent("History", isDirectory: true))
        let fixtureArchives = try archives(now: Date())
        for archive in fixtureArchives { history.save(archive) }
        await history.waitForPendingOperations()
        XCTAssertNil(history.lastErrorMessage)
        XCTAssertEqual(history.conversations.count, 4)

        // Seed only the isolated archive: no workspace is activated and no
        // transport starts while rendering the real project/chat tree.
        let seededWorkbench = WorkbenchStore(defaults: defaults)
        let root = seededWorkbench.ensureWorkspace(url: URL(fileURLWithPath: "/Projects/OpenLens"))
        let notes = seededWorkbench.ensureWorkspace(url: URL(fileURLWithPath: "/Projects/StudyNotes"))
        let now = Date()
        let fixtureTitles = ["Rebuild the history sidebar", "Review screenshot quality", "Improve translation layout",
                                "Check reconnect behavior", "Polish the composer", "Add keyboard navigation"]
        let titles = longHistory ? (0..<300).map { "Saved conversation \($0)" } : fixtureTitles
        for (index, title) in titles.enumerated() {
            _ = seededWorkbench.upsertRemoteTask(workspaceID: root.id, threadID: "fixture-\(index)", title: title,
                state: index == 2 ? .running : .completed, statusMessage: "Saved", createdAt: now,
                updatedAt: now.addingTimeInterval(-Double(index) * 60))
        }
        _ = seededWorkbench.upsertRemoteTask(workspaceID: notes.id, threadID: "fixture-notes", title: "Organize lecture notes",
            state: .completed, statusMessage: "Done", createdAt: now, updatedAt: now.addingTimeInterval(-600))
        let workspace = RuntimeWorkspaceController(defaults: defaults, outboundMessage: { _ in
            XCTFail("An offscreen saved conversation must not send a Codex request")
        }, attachmentDirectory: directory.appendingPathComponent("Attachments", isDirectory: true),
           draftDirectory: directory.appendingPathComponent("Drafts", isDirectory: true), codexSyncEnabled: true)
        let settings = InferenceSettingsRepository(values: UserDefaultsSettingsStore(defaults: defaults),
                                                    secrets: HistorySidebarFixtureSecrets())
        let controller = MarrController(client: HistorySidebarFixtureClient(), usesCodexForConversation: false,
            historyStore: history, tokenUsageStore: TokenUsageStore(rootURL: directory.appendingPathComponent("Usage")),
            settingsRepository: settings, codexWorkspace: workspace,
            chatGPTSession: settingsDestination == .aiModels
                ? ChatGPTSession(store: WelcomeEmptyAccountStore(), transport: WelcomeNoNetwork(), verifier: WelcomeNoIdentity())
                : .shared)
        defer { if settingsDestination == .aiModels { controller.cancelChatGPTSignIn() } }
        let selected = try XCTUnwrap(history.conversations.first { $0.id == fixtureArchives[0].id })
        let session = ConversationSession(historyRecord: selected, imageAssets: [])
        XCTAssertFalse(session.hasLoadingTurn)
        XCTAssertFalse(try XCTUnwrap(session.generatedTitle).isEmpty)

        MarrScrollDiagnostics.taskEvaluations = 0
        let panel = AnswerPanelController(controller: controller, historyStore: history, session: session,
            anchorRect: .zero, persistImmediately: false,
            initialDestination: rendersSettings ? settingsDestination : nil,
            sidebarPresentation: longHistory ? AnswerPanelSidebarPresentation(layout: AnswerPanelSidebarLayout(),
                searchText: "", expandedWorkspaceIDs: [root.id]) : nil)
        defer { panel.close() }
        let window = panel.windowForTesting
        try assertOffscreen(window)
        window.appearance = appearance
        // Keep the fixture's content canvas stable beneath the native title bar.
        window.setFrame(window.frameRect(forContentRect: NSRect(
            x: 280, y: 100, width: conversationWidth + MarrPanelShellLayout.railWidth, height: 596)), display: false)
        if rendersSettings {
            let content = try XCTUnwrap(window.contentView)
            content.wantsLayer = true
            content.layer?.backgroundColor = (theme == "dark" ? NSColor(calibratedWhite: 0.12, alpha: 1)
                : NSColor(calibratedWhite: 0.97, alpha: 1)).cgColor
            let bitmap = try stableOffscreenBitmap(content, window: window)
            let url = previews.appendingPathComponent(settingsDestination == .aiModels
                ? "welcome-ai-settings.png" : "unified-settings-\(theme).png")
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
            let attachment = XCTAttachment(contentsOfFile: url); attachment.lifetime = .keepAlways; add(attachment)
            try assertOffscreen(window)
            return
        }
        if !longHistory {
            let content = try XCTUnwrap(window.contentView)
            content.wantsLayer = true
            content.layer?.backgroundColor = (theme == "dark" ? NSColor(calibratedWhite: 0.12, alpha: 1)
                : NSColor(calibratedWhite: 0.97, alpha: 1)).cgColor
            let bitmap = try stableOffscreenBitmap(content, window: window)
            let url = previews.appendingPathComponent("unified-toolbar-\(Int(conversationWidth))-\(theme).png")
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
            let attachment = XCTAttachment(contentsOfFile: url); attachment.lifetime = .keepAlways; add(attachment)
        }
        panel.setHistoryExpanded(true)
        XCTAssertTrue(panel.sidebarPresentation.layout.isExpanded)
        try assertOffscreen(window)

        if !longHistory {
            XCTAssertEqual(panel.sidebarPresentation.collapsedWorkspaceIDs, [root.id, notes.id])
            XCTAssertTrue(panel.sidebarPresentation.isLocalHistoryExpanded)
        }

        // The fixture's canvas is fixed even on a CI display narrower than 941
        // points. The layout state machine's screen clamping has separate tests.
        let expandedWidth = conversationWidth + AnswerPanelSidebarLayout.sidebarWidth + MarrPanelShellLayout.railWidth
        var expandedFrame = window.frame
        expandedFrame.size = window.frameRect(forContentRect: NSRect(
            x: 0, y: 0, width: expandedWidth, height: 596)).size
        window.setFrame(expandedFrame, display: false)
        await history.waitForPendingOperations()
        let content = try XCTUnwrap(window.contentView)
        // The window server's glass backdrop is intentionally absent from an
        // offscreen capture. Supply a neutral layer behind the real controls.
        content.wantsLayer = true
        content.layer?.backgroundColor = (theme == "dark"
            ? NSColor(calibratedWhite: 0.12, alpha: 1)
            : NSColor(calibratedWhite: 0.97, alpha: 1)).cgColor
        let bitmap = try stableOffscreenBitmap(content, window: window)
        XCTAssertEqual(content.bounds.width, expandedWidth, accuracy: 1)
        XCTAssertEqual(content.bounds.height, 596, accuracy: 1)
        XCTAssertEqual(content.bounds.width - AnswerPanelSidebarLayout.sidebarWidth - MarrPanelShellLayout.railWidth, conversationWidth, accuracy: 1)
        if longHistory {
            try measureHistoryScroll(content, window: window)
            return
        }
        panel.sectionForTesting = .personalAgent
        let agentBitmap = try stableOffscreenBitmap(content, window: window)
        let agentURL = previews.appendingPathComponent("personal-agent-\(Int(conversationWidth))-\(theme).png")
        try XCTUnwrap(agentBitmap.representation(using: .png, properties: [:])).write(to: agentURL)
        let agentAttachment = XCTAttachment(contentsOfFile: agentURL)
        agentAttachment.lifetime = .keepAlways
        add(agentAttachment)
        XCTAssertEqual(window.frame, expandedFrame, "Switching sections must not resize the chat canvas")
        XCTAssertEqual(session.id, fixtureArchives[0].id)
        panel.sectionForTesting = .chats
        _ = try stableOffscreenBitmap(content, window: window)
        XCTAssertEqual(try XCTUnwrap(panel.sidebarContentLayoutWidthsForTesting.last), conversationWidth, accuracy: 0.5)
        XCTAssertTrue(panel.sidebarPresentation.layout.isExpanded)
        try assertOffscreen(window)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1_000, "The fixture must capture rendered panel content")
        let name = "history-sidebar-\(Int(conversationWidth))-\(theme)"
        let url = previews.appendingPathComponent(name + ".png")
        try png.write(to: url, options: .atomic)
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try assertOffscreen(window)

        if conversationWidth == 420, theme == "light" {
            try diagnoseSidebarLayout(panel, content: content, window: window,
                                      expandedFrame: expandedFrame, conversationWidth: conversationWidth,
                                      previews: previews)
            try diagnoseNativeSidebarExpansion(panel, content: content, window: window,
                                                expandedFrame: expandedFrame, conversationWidth: conversationWidth)
            panel.setHistoryExpanded(false)
            _ = try stableOffscreenBitmap(content, window: window)
            XCTAssertEqual(window.frame, expandedFrame, "Collapsing must retain the window's expanded width")
            XCTAssertEqual(try XCTUnwrap(panel.sidebarContentLayoutWidthsForTesting.last), expandedWidth - MarrPanelShellLayout.railWidth,
                           accuracy: 0.5, "Collapsing must commit the wider conversation layout")
            panel.resetSidebarLayoutDiagnosticsForTesting()
            panel.setHistoryExpanded(true)
            _ = try stableOffscreenBitmap(content, window: window)
            XCTAssertEqual(window.frame, expandedFrame, "Reopening must reuse the existing width")
            XCTAssertEqual(try XCTUnwrap(panel.sidebarContentLayoutWidthsForTesting.last), conversationWidth,
                           accuracy: 0.5, "Reopening must commit the narrower conversation layout once")
            XCTAssertTrue(panel.sidebarContentLayoutWidthsForTesting.allSatisfy { abs($0 - conversationWidth) <= 0.5 },
                          "Reopening must measure the assigned canvas, without feedback from the old composer width")
            try assertOffscreen(window)
        }

        // Opening a history record builds a fresh panel. Transfer the exact
        // sidebar state and frame without taking its normal presentation path.
        let previousFrame = window.frame
        var presentation = panel.sidebarPresentation
        presentation.searchText = "screenshot"
        presentation.collapsedWorkspaceIDs = [root.id]
        // "Show all" is retained independently of whether its project is collapsed.
        presentation.expandedWorkspaceIDs = [root.id, notes.id]
        presentation.isLocalHistoryExpanded = true
        let replacementRecord = try XCTUnwrap(history.conversations.first { $0.id == fixtureArchives[1].id })
        let replacementSession = ConversationSession(historyRecord: replacementRecord, imageAssets: [])
        let replacement = AnswerPanelController(controller: controller, historyStore: history,
            session: replacementSession, anchorRect: .zero, persistImmediately: false,
            sidebarPresentation: presentation)
        defer { replacement.close() }
        let replacementWindow = replacement.windowForTesting
        try assertOffscreen(replacementWindow)
        XCTAssertEqual(replacement.sidebarPresentation.knownWorkspaceIDs, [root.id, notes.id])
        XCTAssertEqual(replacement.sidebarPresentation.visibleConversationID, presentation.visibleConversationID)
        XCTAssertEqual(replacement.sidebarPresentation.collapsedWorkspaceIDs, presentation.collapsedWorkspaceIDs)
        XCTAssertEqual(replacement.sidebarPresentation.expandedWorkspaceIDs, presentation.expandedWorkspaceIDs)
        XCTAssertTrue(replacement.sidebarPresentation.isLocalHistoryExpanded)
        replacementWindow.appearance = appearance
        replacementWindow.setFrame(previousFrame, display: false)
        let replacementBitmap = try stableOffscreenBitmap(XCTUnwrap(replacementWindow.contentView), window: replacementWindow)
        let replacementURL = previews.appendingPathComponent("sidebar-local-titles-\(Int(conversationWidth))-\(theme).png")
        try XCTUnwrap(replacementBitmap.representation(using: .png, properties: [:])).write(to: replacementURL)
        XCTAssertEqual(replacement.sidebarPresentation.layout, presentation.layout)
        XCTAssertTrue(replacement.sidebarPresentation.layout.isExpanded)
        XCTAssertEqual(replacement.sidebarPresentation.searchText, "screenshot")
        XCTAssertEqual(replacement.frame, previousFrame)
        XCTAssertEqual(replacementSession.id, replacementRecord.id)
        XCTAssertNotEqual(replacementSession.id, session.id)
        try assertOffscreen(window)
        try assertOffscreen(replacementWindow)
        await history.waitForPendingOperations()
    }

    private func diagnoseNativeSidebarExpansion(_ panel: AnswerPanelController, content: NSView,
                                               window: NSWindow, expandedFrame: CGRect,
                                               conversationWidth: CGFloat) throws {
        panel.setSidebarWindowMotionForTesting(AnswerPanelSidebarWindowMotion(
            fromWidth: conversationWidth + MarrPanelShellLayout.railWidth, toWidth: expandedFrame.width,
            fromRevealWidth: 0, toRevealWidth: AnswerPanelSidebarLayout.sidebarWidth))
        defer {
            window.setFrame(expandedFrame, display: false)
            panel.setSidebarWindowMotionForTesting(nil)
        }
        for progress: CGFloat in [0, 0.08, 0.35, 0.72, 1] {
            var frame = expandedFrame
            // NSWindow aligns requested frames to screen pixels. Use whole
            // point samples so this assertion checks layout rather than rounding.
            frame.size.width = (conversationWidth + MarrPanelShellLayout.railWidth + AnswerPanelSidebarLayout.sidebarWidth * progress).rounded()
            frame.origin.x = expandedFrame.maxX - frame.width
            panel.resetSidebarLayoutDiagnosticsForTesting()
            window.setFrame(frame, display: false)
            _ = try stableOffscreenBitmap(content, window: window)
            XCTAssertEqual(window.frame.width, frame.width, accuracy: 0.5)
            XCTAssertTrue(panel.sidebarContentLayoutWidthsForTesting.allSatisfy { abs($0 - conversationWidth) <= 0.5 },
                          "A native viewport update must not reflow the conversation canvas")
            try assertOffscreen(window)
        }
    }

    private func measureHistoryScroll(_ content: NSView, window: NSWindow) throws {
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        let scroll = try XCTUnwrap(scrollViews(content).first {
            $0.bounds.width <= AnswerPanelSidebarLayout.sidebarWidth && ($0.documentView?.bounds.height ?? 0) > 2_000
        })
        let document = try XCTUnwrap(scroll.documentView)
        print("History initial task evaluations: \(MarrScrollDiagnostics.taskEvaluations)")
        MarrScrollDiagnostics.panelEvaluations = 0
        MarrScrollDiagnostics.taskEvaluations = 0
        var samples: [Double] = []
        for step in 1...40 {
            let start = CFAbsoluteTimeGetCurrent()
            let distance = min(CGFloat(step) * 100, document.bounds.height - scroll.contentView.bounds.height)
            let y = document.isFlipped ? distance : document.bounds.height - scroll.contentView.bounds.height - distance
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
            content.layoutSubtreeIfNeeded()
            samples.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        let ordered = samples.sorted()
        let report = "History scroll: 300 chats, 40 steps; panel evaluations \(MarrScrollDiagnostics.panelEvaluations); median \(ordered[20]) ms; p95 \(ordered[38]) ms"
        print(report)
        print("History scrolling task evaluations: \(MarrScrollDiagnostics.taskEvaluations)")
        let attachment = XCTAttachment(string: report); attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertEqual(MarrScrollDiagnostics.panelEvaluations, 0, "Scrolling must not rebuild the conversation panel")
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
        try assertOffscreen(window)
    }

    /// Samples presentation-only reveal changes without measuring screenshot
    /// stabilization waits or PNG encoding. Width diagnostics come from the
    /// real conversation GeometryReader, rather than inferred window arithmetic.
    private func diagnoseSidebarLayout(_ panel: AnswerPanelController, content: NSView, window: NSWindow,
                                       expandedFrame: CGRect, conversationWidth: CGFloat, previews: URL) throws {
        panel.setSidebarRevealWidthForTesting(AnswerPanelSidebarLayout.sidebarWidth)
        _ = try stableOffscreenBitmap(content, window: window)
        let initialBodyWidth = try XCTUnwrap(panel.sidebarContentLayoutWidthsForTesting.last)
        XCTAssertEqual(initialBodyWidth, conversationWidth, accuracy: 0.5)
        panel.resetSidebarLayoutDiagnosticsForTesting()

        var durations: [TimeInterval] = []
        var sampleDescriptions: [String] = []
        for percentage in stride(from: 0, through: 100, by: 5) {
            try autoreleasepool {
                panel.setSidebarRevealWidthForTesting(
                    AnswerPanelSidebarLayout.sidebarWidth * CGFloat(percentage) / 100)
                // Give pending SwiftUI transactions a short turn, without the
                // stable-image helper's 350 ms minimum at every sample.
                RunLoop.main.run(until: Date().addingTimeInterval(0.002))
                let started = CACurrentMediaTime()
                _ = try layoutAndCacheOffscreenBitmap(content, window: window)
                let duration = CACurrentMediaTime() - started
                durations.append(duration)
                // Geometry callbacks can be delivered after the render pass.
                // Flush them outside the timing interval before asserting.
                RunLoop.main.run(until: Date().addingTimeInterval(0.002))
                let widths = panel.sidebarContentLayoutWidthsForTesting
                let bodyWidth = widths.last ?? initialBodyWidth
                XCTAssertEqual(bodyWidth, conversationWidth, accuracy: 0.5,
                               "Reveal \(percentage)% must not reflow the conversation")
                XCTAssertTrue(widths.allSatisfy { abs($0 - conversationWidth) <= 0.5 },
                              "Every observed body width must remain fixed during the reveal: \(widths)")
                XCTAssertLessThanOrEqual(widths.count, 1,
                                         "Presentation samples must not repeatedly update body layout")
                XCTAssertEqual(window.frame, expandedFrame)
                try assertOffscreen(window)
                sampleDescriptions.append(String(format: "%3d%%: %.3f ms, body %.2f pt, width updates %d",
                    percentage, duration * 1_000, Double(bodyWidth), widths.count))

                if percentage.isMultiple(of: 25) {
                    // Preview artifacts must wait for native controls to finish
                    // drawing; keep that stabilization outside the timed pass.
                    let bitmap = try stableOffscreenBitmap(content, window: window)
                    let settledWidths = panel.sidebarContentLayoutWidthsForTesting
                    XCTAssertEqual(settledWidths.last ?? initialBodyWidth, conversationWidth, accuracy: 0.5)
                    XCTAssertTrue(settledWidths.allSatisfy { abs($0 - conversationWidth) <= 0.5 })
                    XCTAssertLessThanOrEqual(settledWidths.count, 1)
                    let imageURL = previews.appendingPathComponent("history-sidebar-transition-\(percentage).png")
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        .write(to: imageURL, options: .atomic)
                    let attachment = XCTAttachment(contentsOfFile: imageURL)
                    attachment.name = "Sidebar revealed \(percentage)%"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
        // Leave the presentation at its expanded endpoint before the fixture
        // exercises a genuine collapse/reopen and their committed layout widths.
        panel.setSidebarRevealWidthForTesting(AnswerPanelSidebarLayout.sidebarWidth)
        RunLoop.main.run(until: Date().addingTimeInterval(0.002))
        XCTAssertLessThanOrEqual(panel.sidebarContentLayoutWidthsForTesting.count, 1)
        try assertOffscreen(window)

        let sorted = durations.sorted()
        let median = sorted[sorted.count / 2]
        let p95 = sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
        let report = String(format: "Offscreen sidebar layout/cacheDisplay: %d samples; total %.3f ms; median %.3f ms; P95 %.3f ms.\n",
            durations.count, durations.reduce(0, +) * 1_000, median * 1_000, p95 * 1_000)
            + "Run-loop waits, PNG encoding and file writes excluded. These diagnostics measure layout/render work, not display FPS.\n"
            + sampleDescriptions.joined(separator: "\n")
        print(report)
        let attachment = XCTAttachment(string: report)
        attachment.name = "Sidebar offscreen layout diagnostics"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func archives(now: Date) throws -> [ConversationArchive] {
        let calendar = Calendar.current
        let examples: [(Int, String, String, String)] = [
            (0, "Screenshot quality checklist", "How can I make this screenshot easier to read?", """
             Keep the original screenshot and use a crop that includes the whole question.

             - Preserve the source resolution for small text.
             - Leave a little space around diagrams and labels.
             - Open the image viewer to inspect details at 100%.

             A short follow-up can focus on one paragraph without losing the conversation.
             """),
            (1, "Translate a screenshot", "Translate the highlighted paragraph.",
             "The translation keeps the original terms and explains the key idea in plain language."),
            (4, "Compare two explanations", "Which explanation is more precise?",
             "The second explanation states the assumption explicitly and gives a concrete example."),
            (20, "Meeting notes and next steps", "Summarize the notes into a short checklist.",
             "Confirm the source, review the summary, and keep the unresolved questions together.")
        ]
        return try examples.map { daysAgo, title, question, answer in
            let date = try XCTUnwrap(calendar.date(byAdding: .day, value: -daysAgo, to: now))
            let turn = ConversationTurn(id: UUID(), question: question, imageIDs: [], answer: answer,
                                        errorMessage: nil, status: .completed, showsAssistant: true)
            return ConversationArchive(id: UUID(), createdAt: date, updatedAt: date, generatedTitle: title,
                                       turns: [turn], images: [], pendingImageIDs: [])
        }
    }

    private func assertOffscreen(_ window: NSWindow, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(window.isVisible, "A sidebar fixture must never become visible", file: file, line: line)
        XCTAssertFalse(window.isKeyWindow, "A sidebar fixture must never take keyboard focus", file: file, line: line)
        guard !window.isVisible, !window.isKeyWindow else { throw FixtureError.windowBecameVisibleOrKey }
    }

    private enum FixtureError: Error { case windowBecameVisibleOrKey }

    private func layoutAndCacheOffscreenBitmap(_ content: NSView, window: NSWindow) throws -> NSBitmapImageRep {
        try assertOffscreen(window)
        content.needsLayout = true
        content.layoutSubtreeIfNeeded()
        func invalidateDisplay(_ view: NSView) {
            view.needsDisplay = true
            view.subviews.forEach(invalidateDisplay)
        }
        invalidateDisplay(content)
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
        try assertOffscreen(window)
        return bitmap
    }

    /// Wait for repeated identical pixels after SwiftUI and AppKit each finish
    /// their render transactions. Never order a window in to obtain a bitmap.
    private func stableOffscreenBitmap(_ content: NSView, window: NSWindow) throws -> NSBitmapImageRep {
        try assertOffscreen(window)
        let start = Date()
        let deadline = start.addingTimeInterval(3)
        var previousPixels: Data?
        var consecutiveMatches = 0
        var result: NSBitmapImageRep?

        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            let bitmap = try layoutAndCacheOffscreenBitmap(content, window: window)
            let pixels = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            consecutiveMatches = pixels == previousPixels ? consecutiveMatches + 1 : 0
            previousPixels = pixels
            result = bitmap
            try assertOffscreen(window)
            if Date().timeIntervalSince(start) >= 0.35, consecutiveMatches >= 3 { return bitmap }
        } while Date() < deadline

        XCTFail("Offscreen history sidebar did not reach stable rendered pixels within three seconds")
        return try XCTUnwrap(result)
    }
}

private struct HistorySidebarFixtureClient: VisionAIClient {
    func ask(request: VisionRequest, model: String, connection: InferenceConnection) async throws -> String {
        XCTFail("Saved history rendering must not issue an inference or title-generation request")
        return ""
    }
}

private struct HistorySidebarFixtureSecrets: SecretStore {
    func string(for account: String) throws -> String? { nil }
    func set(_ value: String, for account: String) throws {
        XCTFail("Saved history rendering must not write credentials")
    }
}

private struct WelcomeEmptyAccountStore: ChatGPTCredentialStoring {
    func load() throws -> Data? { try JSONEncoder().encode(ChatGPTSavedState()) }
    func save(_ data: Data) throws { XCTFail("Welcome rendering must not write credentials") }
}

private struct WelcomeNoNetwork: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        XCTFail("Welcome rendering must not make account requests")
        throw URLError(.notConnectedToInternet)
    }
}

private struct WelcomeNoIdentity: ChatGPTIdentityVerifying {
    func verify(_ token: String, clientID: String, nonce: String?) async throws -> ChatGPTIdentity {
        XCTFail("Welcome rendering must not authenticate")
        throw URLError(.notConnectedToInternet)
    }
}
