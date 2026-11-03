import AppKit
import MarrCore
import MarrNetworking
import MarrSettings
import SwiftUI
import Vision
import XCTest
@testable import Marr

@MainActor
final class AgentComposerViewTests: XCTestCase {
    func testComposerControlsExpandInPlaceAndPreserveDraftThroughMenuSwitches() throws {
        try MarrUITestSupport.requireVisibleWindows()
        try withDraftPanel(session: ConversationSession(), initialDestination: .codex, modelFixtures: true) { _, window, workspace in
            let editor = try XCTUnwrap(descendants(of: window.contentView).compactMap { $0 as? AgentInputTextView }.first)
            window.makeFirstResponder(editor)
            editor.insertText("Keep this draft while choosing tools", replacementRange: NSRange(location: NSNotFound, length: 0))
            settle(window)
            let draft = editor.string
            let editorFrame = editor.convert(editor.bounds, to: nil)
            let toolbarY = AnswerPanelConversationLayout.bottomInset + 12 + 14
            let plus = NSPoint(x: editorFrame.minX + 10, y: toolbarY)
            let windows = Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber))
            @MainActor func click(_ point: NSPoint, waitForAnimation: Bool = true) throws {
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    NSApp.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point,
                        modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
                }
                if waitForAnimation { settle(window) }
            }
            @MainActor func search(_ placeholder: String) -> NSSearchField? {
                descendants(of: window.contentView).compactMap { $0 as? NSSearchField }
                    .first { $0.placeholderString == placeholder }
            }
            @MainActor func escape() throws {
                NSApp.sendEvent(try key(53, characters: "\u{1b}"))
                settle(window)
            }
            @MainActor func snapshot(_ name: String) throws {
                let png = try XCTUnwrap(windowBitmap(window).representation(using: .png, properties: [:]))
                let path = FileManager.default.temporaryDirectory.appendingPathComponent("marr-morph-actual-" + name + ".png")
                try png.write(to: path)
                print("MARR_MORPH_SNAPSHOT: \(path.path)")
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = "marr-morph-actual-" + name
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            try snapshot("idle")
            try click(plus, waitForAnimation: false)
            for frame in 1...6 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.025))
                window.contentView?.layoutSubtreeIfNeeded()
                window.contentView?.displayIfNeeded()
                try snapshot(String(format: "plus-motion-%02d", frame))
            }
            settle(window)
            XCTAssertTrue(try renderedText(window).contains { $0.text.contains("Attach files") })
            XCTAssertNil(search("Search add context"), "Plus must reveal inline actions before any menu")
            XCTAssertEqual(editor.convert(editor.bounds, to: nil), editorFrame)
            XCTAssertEqual(editor.string, draft)
            try snapshot("plus")
            try click(plus)

            @MainActor func modelPoint() throws -> NSPoint {
                let label = try XCTUnwrap(try renderedText(window).first {
                    $0.text.contains("Fixture") && $0.bounds.midY < 0.25
                })
                let bounds = try XCTUnwrap(window.contentView).bounds
                return NSPoint(x: label.bounds.midX * bounds.width, y: label.bounds.midY * bounds.height)
            }
            // Resolve the actual right-aligned model label instead of an old
            // fixed toolbar position.
            try snapshot("motion-00")
            try click(try modelPoint(), waitForAnimation: false)
            for frame in 1...12 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.025))
                window.contentView?.layoutSubtreeIfNeeded()
                window.contentView?.displayIfNeeded()
                try snapshot(String(format: "motion-%02d", frame))
            }
            settle(window)
            let modelSearch = try XCTUnwrap(search("Search models"), "The model menu must mount in the answer window")
            XCTAssertTrue(modelSearch.window === window)
            XCTAssertEqual(Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber)), windows,
                           "Opening a model must not create a disconnected native popover window")
            let searchFrame = modelSearch.convert(modelSearch.bounds, to: nil)
            XCTAssertEqual(searchFrame.minY, toolbarY - 6, accuracy: 4,
                           "The menu footer must share the source button's bottom edge")
            XCTAssertEqual(editor.convert(editor.bounds, to: nil), editorFrame)
            XCTAssertEqual(editor.string, draft)
            try snapshot("model")

            let searchEditor = try XCTUnwrap(modelSearch.currentEditor() as? NSTextView,
                                            "Opening the model must focus its bottom search")
            searchEditor.insertText("Astra", replacementRange: NSRange(location: NSNotFound, length: 0))
            settle(window)
            XCTAssertEqual(modelSearch.stringValue, "Astra")
            try snapshot("filtered")
            NSApp.sendEvent(try key(36, characters: "\r"))
            for frame in 1...6 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.025))
                window.contentView?.layoutSubtreeIfNeeded()
                window.contentView?.displayIfNeeded()
                try snapshot(String(format: "close-motion-%02d", frame))
            }
            settle(window)
            try snapshot("selected")
            XCTAssertEqual(workspace.selectedModel, "fixture-astra")
            XCTAssertNil(search("Search models"))
            XCTAssertTrue(window.firstResponder === editor)
            XCTAssertEqual(editor.string, draft)
            try click(try modelPoint())

            // Switch directly from the open model to the plus entry.
            try click(plus)
            XCTAssertNil(search("Search models"))
            XCTAssertTrue(try renderedText(window).contains { $0.text.contains("Attach files") })
            try click(NSPoint(x: plus.x + 106, y: toolbarY))
            XCTAssertNotNil(search("Search add context"), "More context must grow from the expanded attachment entry")
            XCTAssertEqual(Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber)), windows)
            XCTAssertEqual(editor.string, draft)
            try snapshot("context")
            try escape()
            XCTAssertNil(search("Search add context"))
            XCTAssertTrue(window.firstResponder === editor)
            XCTAssertEqual(editor.string, draft)
        }
    }

    func testAnswerPanelComposerCompletesInPlaceAndOpensSkillSettings() throws {
        try MarrUITestSupport.requireVisibleWindows()
        let suite = "Marr.ComposerWindow.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let historyResources = MarrHistoryTestResources(rootURL: root)
        addTeardownBlock { try await historyResources.cleanUp() }
        defer {
            defaults.removePersistentDomain(forName: suite)
        }
        let store = WorkbenchStore(defaults: defaults)
        _ = store.upsertWorkspace(url: root, bookmark: Data())
        defaults.set(Data(), forKey: "codex.workspace.bookmark")
        var outbound: [[String: Any]] = []
        let workspace = RuntimeWorkspaceController(defaults: defaults, outboundMessage: { outbound.append($0) },
                                                  attachmentDirectory: root.appendingPathComponent("Attachments"), codexSyncEnabled: true)
        let history = historyResources.makeStore(at: root.appendingPathComponent("History"))
        let repository = InferenceSettingsRepository(values: UserDefaultsSettingsStore(defaults: defaults), secrets: ComposerFixtureSecrets())
        let controller = MarrController(client: ComposerFixtureClient(), usesCodexForConversation: true,
            historyStore: history, tokenUsageStore: TokenUsageStore(rootURL: root.appendingPathComponent("Usage")),
            settingsRepository: repository, codexWorkspace: workspace)
        let panel = AnswerPanelController(controller: controller, historyStore: history, session: ConversationSession(),
            anchorRect: .zero, persistImmediately: false, initialDestination: .codex)
        defer { panel.close() }
        let window = panel.windowForTesting
        panel.show(preservingFrame: NSRect(x: 100, y: 100, width: 420, height: 596))
        settle(window)

        var replied = Set<String>()
        func respondToDiscovery() {
            for message in outbound {
                guard let id = message["id"], let method = message["method"] as? String,
                      replied.insert(String(describing: id)).inserted else { continue }
                let result: [String: Any]
                switch method {
                case "skills/list":
                    result = ["data": [["skills": [["name": "research", "path": root.appendingPathComponent("skills/research/SKILL.md").path,
                        "description": "Find sources and prepare a cited research summary.", "scope": "user", "enabled": true]], "errors": []]]]
                case "plugin/list":
                    result = ["marketplaces": [["name": "test-market", "plugins": [["id": "docs@test-market", "name": "docs", "installed": true,
                        "enabled": true, "interface": ["displayName": "Documents", "shortDescription": "Create and edit documents"]]]]]]
                case "fuzzyFileSearch":
                    result = ["files": [["path": "Sources/Report.swift", "root": root.path, "file_name": "Report.swift", "score": 10]]]
                default: result = ["data": []]
                }
                workspace.receiveServerMessage(["id": id, "result": result])
            }
            settle(window)
        }
        respondToDiscovery()
        // CodexTaskDetailsView has dedicated rendering coverage. Avoid
        // synthetic AppKit mouse events for its transient popover here; this
        // integration test focuses on composer command completion.
        let editor = try XCTUnwrap(descendants(of: window.contentView).compactMap { $0 as? AgentInputTextView }.first)
        XCTAssertTrue(window.makeFirstResponder(editor))

        editor.insertText("/", replacementRange: NSRange(location: 0, length: 0))
        settle(window)
        try attachWindowSnapshots(window, name: "answer-panel-commands")
        attachGeometry(window, editor: editor)
        XCTAssertEqual(editor.string, "/")
        XCTAssertTrue(window.firstResponder === editor, "The native editor must retain focus while its completion overlay is visible: \(String(describing: window.firstResponder))")
        let commands = try renderedText(window)
        for command in ["Model", "Skills", "Code review", "Rename", "New chat"] {
            XCTAssertTrue(commands.contains { $0.text.contains(command) }, "The overlay must show all five leading rows inside the window: \(command); rendered: \(commands.map(\.text))")
        }
        let modelOption = try XCTUnwrap(commands.first { $0.text.contains("Model") }, "The actual window must render command completion rows: \(commands.map(\.text))")
        let content = try XCTUnwrap(window.contentView)
        let optionFrame = window.convertToScreen(content.convert(NSRect(x: modelOption.bounds.minX * content.bounds.width,
            y: modelOption.bounds.minY * content.bounds.height, width: modelOption.bounds.width * content.bounds.width,
            height: modelOption.bounds.height * content.bounds.height), to: nil))
        let editorFrame = window.convertToScreen(editor.convert(editor.bounds, to: nil))
        XCTAssertGreaterThan(optionFrame.midY, editorFrame.midY, "Completion rows should appear above the composer")

        editor.keyDown(with: try key(126, characters: "\u{F700}"))
        settle(window)
        try attachWindowSnapshots(window, name: "answer-panel-commands-wrapped")
        let wrappedLabels = try renderedText(window).map(\.text)
        XCTAssertTrue(wrappedLabels.contains { $0.contains("Exit plan") }, "Keyboard wrap must reveal the final command: \(wrappedLabels)")
        editor.keyDown(with: try key(48, characters: "\t"))
        settle(window)
        XCTAssertEqual(editor.string, "/default ", "The visible last row must also be the row accepted by the editor")
        editor.insertText("/", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        settle(window)
        editor.keyDown(with: try key(126, characters: "\u{F700}"))
        settle(window)
        editor.keyDown(with: try key(125, characters: "\u{F701}"))
        settle(window)
        XCTAssertTrue(try renderedText(window).contains { $0.text.contains("Model") }, "Returning to the first command must scroll back without centering every move")

        editor.insertText("/code", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        settle(window)
        editor.keyDown(with: try key(48, characters: "\t"))
        settle(window)
        XCTAssertEqual(editor.string, "/review ", "Friendly command titles must be searchable while preserving the actual invocation")

        editor.insertText("/ren Keep these arguments", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        editor.setSelectedRange(NSRange(location: 4, length: 0))
        settle(window)
        editor.keyDown(with: try key(48, characters: "\t"))
        settle(window)
        XCTAssertEqual(editor.string, "/rename Keep these arguments", "Tab completion must preserve the already written argument suffix")
        XCTAssertFalse(outbound.contains { ["thread/name/set", "turn/start"].contains($0["method"] as? String ?? "") }, "Tab must complete without dispatching")

        editor.insertText("Use $", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        settle(window)
        respondToDiscovery()
        XCTAssertTrue(try renderedText(window).contains { $0.text.localizedCaseInsensitiveContains("research") })
        try attachWindowSnapshots(window, name: "answer-panel-skills")
        editor.keyDown(with: try key(48, characters: "\t"))
        settle(window)
        XCTAssertEqual(editor.string, "Use $research ")

        editor.insertText("Inspect @NoSuchMatch", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        settle(window)
        editor.keyDown(with: try key(36, characters: "\r"))
        XCTAssertFalse(outbound.contains { $0["method"] as? String == "turn/start" }, "An empty/loading completion must consume Return")
        XCTAssertEqual(editor.string, "Inspect @NoSuchMatch")
        editor.keyDown(with: try key(53, characters: "\u{1b}"))
        settle(window)
        XCTAssertFalse(try renderedText(window).contains { $0.text.contains("No matching") })

        editor.insertText("@", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        settle(window)
        respondToDiscovery()
        let contextLabels = try renderedText(window).map(\.text).joined(separator: "\n")
        XCTAssertTrue(contextLabels.contains("Files and folders"))
        XCTAssertTrue(contextLabels.contains("Goal"))
        XCTAssertTrue(contextLabels.contains("Documents"))
        try attachWindowSnapshots(window, name: "answer-panel-context")
        editor.insertText("Use @Doc", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        settle(window)
        editor.keyDown(with: try key(48, characters: "\t"))
        settle(window)
        XCTAssertEqual(editor.string, "Use @Documents ")

        editor.insertText("Inspect @Report", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        settle(window)
        respondToDiscovery()
        XCTAssertTrue(try renderedText(window).contains { $0.text.contains("Report.swift") })
        try attachWindowSnapshots(window, name: "answer-panel-files")
        editor.keyDown(with: try key(48, characters: "\t"))
        settle(window)
        XCTAssertTrue(editor.string.contains("@Sources/Report.swift"))

        editor.insertText("/ski", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        settle(window)
        editor.keyDown(with: try key(36, characters: "\r"))
        settle(window)
        let settingsLabels = try renderedText(window).map(\.text).joined(separator: "\n")
        XCTAssertTrue(settingsLabels.localizedCaseInsensitiveContains("all setting"),
            "Return on /skills must navigate the real panel into Settings: \(settingsLabels)")
        XCTAssertTrue(settingsLabels.localizedCaseInsensitiveContains("earch skills"),
            "The Settings destination must select Work → Skills")
        XCTAssertTrue(settingsLabels.contains("research"))
        XCTAssertFalse(window.firstResponder is AgentInputTextView, "Opening Settings must release the Work editor's focus")
        XCTAssertFalse(outbound.contains { ["turn/start", "turn/steer", "skills/config/write"].contains($0["method"] as? String ?? "") })
        try attachWindowSnapshots(window, name: "answer-panel-skill-settings")
    }

    func testAnswerPanelPreservesDraftWhileAgentStreamsInBothAppearances() throws {
        try MarrUITestSupport.requireVisibleWindows()
        let appearanceKey = MarrAppearanceKeys.colorScheme
        let originalAppearance = UserDefaults.standard.object(forKey: appearanceKey)
        defer {
            if let originalAppearance {
                UserDefaults.standard.set(originalAppearance, forKey: appearanceKey)
            } else {
                UserDefaults.standard.removeObject(forKey: appearanceKey)
            }
        }
        let previews = FileManager.default.temporaryDirectory
            .appendingPathComponent("marr-agent-ui-preview", isDirectory: true)
        try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)

        for (theme, appearance) in [("Light", NSAppearance.Name.aqua), ("Dark", .darkAqua)] {
            UserDefaults.standard.set(theme, forKey: appearanceKey)
            let suite = "Marr.StreamingComposer.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
            let directory = root.appendingPathComponent("Workspace", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let historyResources = MarrHistoryTestResources(rootURL: root)
            addTeardownBlock { try await historyResources.cleanUp() }
            defer {
                defaults.removePersistentDomain(forName: suite)
            }
            let store = WorkbenchStore(defaults: defaults)
            _ = store.upsertWorkspace(url: directory, bookmark: Data())
            defaults.set(Data(), forKey: "codex.workspace.bookmark")
            var outbound: [[String: Any]] = []
            let workspace = RuntimeWorkspaceController(defaults: defaults, outboundMessage: { outbound.append($0) },
                attachmentDirectory: root.appendingPathComponent("Attachments"), codexSyncEnabled: true)
            let history = historyResources.makeStore(at: root.appendingPathComponent("History"))
            let repository = InferenceSettingsRepository(values: UserDefaultsSettingsStore(defaults: defaults),
                secrets: ComposerFixtureSecrets())
            let controller = MarrController(client: ComposerFixtureClient(), usesCodexForConversation: true,
                historyStore: history, tokenUsageStore: TokenUsageStore(rootURL: root.appendingPathComponent("Usage")),
                settingsRepository: repository, codexWorkspace: workspace)
            let panel = AnswerPanelController(controller: controller, historyStore: history, session: ConversationSession(),
                anchorRect: .zero, persistImmediately: false, initialDestination: .codex)
            defer { panel.close() }
            let window = panel.windowForTesting
            window.appearance = NSAppearance(named: appearance)
            panel.show(preservingFrame: NSRect(x: 100, y: 100, width: 420, height: 596))
            settle(window)
            // Finish discovery without starting a runtime, connecting an account,
            // or making an inference request.
            for message in outbound {
                guard let id = message["id"] else { continue }
                workspace.receiveServerMessage(["id": id, "result": ["data": []]])
            }
            settle(window)

            func snapshot(_ state: String) throws {
                let data = try XCTUnwrap(windowBitmap(window).representation(using: .png, properties: [:]))
                let name = "work-\(state)-\(theme.lowercased())-\(Int(window.frame.width))"
                try data.write(to: previews.appendingPathComponent(name + ".png"), options: .atomic)
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
                attachment.name = name
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            func response(_ method: String, result: [String: Any]) throws {
                let request = try XCTUnwrap(outbound.last { $0["method"] as? String == method })
                workspace.receiveServerMessage(["id": try XCTUnwrap(request["id"]), "result": result])
            }
            func notify(_ method: String, _ values: [String: Any]) {
                var params = values
                params["threadId"] = "streaming-thread"
                params["turnId"] = "streaming-turn"
                workspace.receiveServerMessage(["method": method, "params": params])
            }

            try snapshot("ready")
            let editor = try XCTUnwrap(descendants(of: window.contentView).compactMap { $0 as? AgentInputTextView }.first)
            XCTAssertTrue(window.makeFirstResponder(editor))
            editor.insertText("Review the agent interface.", replacementRange: NSRange(location: 0, length: 0))
            editor.keyDown(with: try key(36, characters: "\r"))
            try response("thread/start", result: ["thread": ["id": "streaming-thread", "cwd": directory.path,
                "name": "Agent interface", "status": ["type": "idle"], "turns": []]])
            try response("turn/start", result: ["turn": ["id": "streaming-turn"]])
            notify("item/completed", ["item": ["id": "input", "type": "userMessage",
                "content": [["type": "text", "text": "Review the agent interface."]]]])
            notify("item/started", ["item": ["id": "answer", "type": "agentMessage", "text": ""]])
            settle(window)
            XCTAssertEqual(editor.string, "", "An accepted submission clears the composer")

            let draft = "Please keep the keyboard shortcuts."
            let caret = NSRange(location: 12, length: 0)
            editor.insertText(draft, replacementRange: NSRange(location: 0, length: 0))
            editor.setSelectedRange(caret)
            let chunks = ["I checked the input and reply flow. ", "The composer stays available ", "while the answer arrives."]
            for chunk in chunks {
                notify("item/agentMessage/delta", ["itemId": "answer", "delta": chunk])
                settle(window)
                let liveEditor = descendants(of: window.contentView).compactMap { $0 as? AgentInputTextView }.first
                XCTAssertTrue(liveEditor === editor, "Streaming must preserve the native text editor")
                XCTAssertTrue(window.firstResponder === editor, "Streaming must preserve keyboard focus")
                XCTAssertEqual(editor.string, draft, "A new answer must not overwrite an unsent instruction")
                XCTAssertEqual(editor.selectedRange(), caret, "Streaming must not move the insertion point")
            }
            let streamingText = try renderedText(window).map(\.text).joined(separator: " ")
            XCTAssertTrue(streamingText.contains("Responding") || streamingText.contains("Writing a reply"), streamingText)
            try snapshot("responding")
            window.setFrame(NSRect(x: 100, y: 100, width: 720, height: 680), display: true)
            settle(window)
            try snapshot("responding")
            window.setFrame(NSRect(x: 100, y: 100, width: 420, height: 596), display: true)
            notify("item/completed", ["item": ["id": "answer", "type": "agentMessage", "text": chunks.joined()]])
            notify("turn/completed", ["turn": ["id": "streaming-turn", "status": "completed"]])
            settle(window)
            let completedText = try renderedText(window).map(\.text).joined(separator: " ")
            XCTAssertFalse(completedText.contains("Responding"), completedText)
            XCTAssertFalse(completedText.contains("Working"), completedText)
            XCTAssertTrue(completedText.contains("I checked the input"), completedText)
            XCTAssertEqual(editor.string, draft)
            XCTAssertEqual(editor.selectedRange(), caret)
            try snapshot("completed")

            // A failed thread start has no user-message group. Its diagnostic
            // must remain visible instead of returning to the welcome state.
            workspace.startNewTask()
            XCTAssertTrue(workspace.submit(prompt: "Start another task", images: []))
            let failedRequest = try XCTUnwrap(outbound.last { $0["method"] as? String == "thread/start" })
            workspace.receiveServerMessage(["id": try XCTUnwrap(failedRequest["id"]),
                "error": ["code": -32000, "message": "Fixture startup failed"]])
            settle(window)
            let failureText = try renderedText(window).map(\.text).joined(separator: " ")
            XCTAssertTrue(failureText.contains("Fixture startup failed"), failureText)
            XCTAssertFalse(failureText.contains("What would you like to work on"), failureText)
            try snapshot("startup-error")
        }
    }

    func testRunningComposerKeepsAttachmentsCompactAndControlsReachableWithLongModelName() throws {
        try MarrUITestSupport.requireVisibleWindows()
        let appearanceKey = MarrAppearanceKeys.colorScheme
        let originalAppearance = UserDefaults.standard.object(forKey: appearanceKey)
        defer {
            if let originalAppearance { UserDefaults.standard.set(originalAppearance, forKey: appearanceKey) }
            else { UserDefaults.standard.removeObject(forKey: appearanceKey) }
        }
        let previews = FileManager.default.temporaryDirectory
            .appendingPathComponent("marr-agent-ui-preview", isDirectory: true)
        try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)

        for (theme, appearance) in [("Light", NSAppearance.Name.aqua), ("Dark", .darkAqua)] {
            UserDefaults.standard.set(theme, forKey: appearanceKey)
            for width in [MarrPanelShellLayout.windowSize.width, 720 + MarrPanelShellLayout.railWidth] {
                let suite = "Marr.CompactRunningComposer.\(UUID().uuidString)"
                let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let historyResources = MarrHistoryTestResources(rootURL: root)
                addTeardownBlock { try await historyResources.cleanUp() }
                defer {
                    defaults.removePersistentDomain(forName: suite)
                }
                let store = WorkbenchStore(defaults: defaults)
                _ = store.upsertWorkspace(url: root, bookmark: Data())
                defaults.set(Data(), forKey: "codex.workspace.bookmark")
                var outbound: [[String: Any]] = []
                let workspace = RuntimeWorkspaceController(defaults: defaults, outboundMessage: { outbound.append($0) },
                    attachmentDirectory: root.appendingPathComponent("Attachments"), codexSyncEnabled: true)
                // The injected transport bypasses initialize. Establish it
                // before discovery, then explicitly request the model catalog.
                workspace.refreshCapabilities()
                workspace.refreshModels()
                let history = historyResources.makeStore(at: root.appendingPathComponent("History"))
                let repository = InferenceSettingsRepository(values: UserDefaultsSettingsStore(defaults: defaults),
                    secrets: ComposerFixtureSecrets())
                let controller = MarrController(client: ComposerFixtureClient(), usesCodexForConversation: true,
                    historyStore: history, tokenUsageStore: TokenUsageStore(rootURL: root.appendingPathComponent("Usage")),
                    settingsRepository: repository, codexWorkspace: workspace)
                let session = ConversationSession()
                let panel = AnswerPanelController(controller: controller, historyStore: history, session: session,
                    anchorRect: .zero, persistImmediately: false, initialDestination: .codex)
                defer { panel.close() }
                let window = panel.windowForTesting
                window.appearance = NSAppearance(named: appearance)
                panel.show(preservingFrame: NSRect(x: 100, y: 100, width: width, height: 596))
                settle(window)

                let modelName = "Fixture extended reasoning model for large project reviews with additional context"
                for message in outbound {
                    guard let id = message["id"] else { continue }
                    let result: [String: Any] = message["method"] as? String == "model/list"
                        ? ["data": [["model": "fixture-long-model", "displayName": modelName,
                            "supportedReasoningEfforts": [["reasoningEffort": "low"], ["reasoningEffort": "high"]],
                            "defaultReasoningEffort": "low"]]]
                        : ["data": []]
                    workspace.receiveServerMessage(["id": id, "result": result])
                }
                XCTAssertTrue(outbound.contains { $0["method"] as? String == "model/list" })
                _ = try XCTUnwrap(workspace.availableModels.first { $0.id == "fixture-long-model" },
                    "The catalog response must be consumed before selecting or starting a turn")
                workspace.selectModel("fixture-long-model")
                XCTAssertEqual(workspace.selectedModelName, modelName)
                func respond(_ method: String, result: [String: Any]) throws {
                    let request = try XCTUnwrap(outbound.last { $0["method"] as? String == method })
                    workspace.receiveServerMessage(["id": try XCTUnwrap(request["id"]), "result": result])
                }
                func click(_ point: NSPoint) throws {
                    window.makeKeyAndOrderFront(nil)
                    let location = try XCTUnwrap(window.contentView).convert(point, to: nil)
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        // Keep toolbar interaction on the application's event
                        // routing path rather than invoking a button callback.
                        NSApp.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location,
                            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
                    }
                    settle(window)
                }
                func snapshot(_ target: NSWindow, state: String) throws {
                    let data = try XCTUnwrap(windowBitmap(target).representation(using: .png, properties: [:]))
                    let name = "work-compact-\(state)-\(theme.lowercased())-\(Int(width))"
                    try data.write(to: previews.appendingPathComponent(name + ".png"), options: .atomic)
                    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
                    attachment.name = name
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }

                XCTAssertTrue(workspace.submit(prompt: "Review the interface", images: []))
                try respond("thread/start", result: ["thread": ["id": "compact-thread", "cwd": root.path,
                    "name": "Interface review", "status": ["type": "idle"], "turns": []]])
                try respond("turn/start", result: ["turn": ["id": "compact-turn"]])
                workspace.receiveServerMessage(["method": "item/completed", "params": [
                    "threadId": "compact-thread", "turnId": "compact-turn",
                    "item": ["id": "compact-input", "type": "userMessage",
                        "content": [["type": "text", "text": "Review the interface"]]]]])
                workspace.receiveServerMessage(["method": "item/started", "params": [
                    "threadId": "compact-thread", "turnId": "compact-turn",
                    "item": ["id": "compact-answer", "type": "agentMessage", "text": "Reviewing the interface."]]])
                settle(window)
                let editor = try XCTUnwrap(descendants(of: window.contentView).compactMap { $0 as? AgentInputTextView }.first)
                XCTAssertTrue(window.makeFirstResponder(editor))
                editor.insertText("Include the attached notes.", replacementRange: NSRange(location: 0, length: 0))
                settle(window)
                let transcript = try XCTUnwrap(descendants(of: window.contentView).compactMap { $0 as? NSScrollView }
                    .filter { $0 !== editor.enclosingScrollView }.max { $0.frame.height < $1.frame.height })
                let originalTranscriptHeight = transcript.frame.height
                let originalEditorFrame = editor.convert(editor.bounds, to: nil)
                for index in 1...4 {
                    _ = session.appendAttachment(PickedAttachment(data: Data("Context \(index)".utf8),
                        mimeType: "text/plain", fileName: "context-\(index)-project-review-notes.txt", image: nil))
                }
                settle(window)
                // Four files exceed both widths, so the native horizontal
                // viewport is identifiable without depending on private class names.
                let attachmentScroll = try XCTUnwrap(descendants(of: window.contentView).compactMap { $0 as? NSScrollView }
                    .first { scroll in
                        scroll !== editor.enclosingScrollView && scroll !== transcript
                            && (scroll.documentView?.frame.width ?? 0) > scroll.contentView.bounds.width + 20
                    }, "The attachments must have a horizontally scrollable viewport")
                XCTAssertLessThanOrEqual(attachmentScroll.contentView.bounds.height, 44,
                    "An attachment row must not absorb the transcript's spare height")
                XCTAssertGreaterThanOrEqual(attachmentScroll.contentView.bounds.height, 38,
                    "Attachment thumbnails and remove controls must remain fully visible")
                XCTAssertLessThanOrEqual(originalTranscriptHeight - transcript.frame.height, 56,
                    "Adding one attachment row should consume only one row plus its gap")
                XCTAssertEqual(editor.convert(editor.bounds, to: nil).minY, originalEditorFrame.minY, accuracy: 2,
                    "Attachments must not move the editor or bottom controls")
                XCTAssertTrue(window.firstResponder === editor)
                XCTAssertEqual(editor.string, "Include the attached notes.")
                let labels = try renderedText(window)
                XCTAssertTrue(labels.contains { $0.text.contains("Responding") || $0.text.contains("Writing a reply") }, "\(labels.map(\.text))")
                XCTAssertTrue(labels.contains { $0.text.contains("context-1") }, "\(labels.map(\.text))")
                try snapshot(window, state: "attachments-running")

                workspace.receiveServerMessage(["method": "thread/tokenUsage/updated", "params": [
                    "threadId": "compact-thread", "turnId": "compact-turn", "tokenUsage": [
                        "last": ["inputTokens": 80, "outputTokens": 20, "cachedInputTokens": 50, "totalTokens": 100],
                        "total": ["totalTokens": 100], "modelContextWindow": 1_000
                    ]]])
                XCTAssertEqual(workspace.activeTokenUsage?.lastTotalTokens, 100)

                // Open the actual model button while running. Its read-only
                // context information must stay reachable even though selection is locked.
                let content = try XCTUnwrap(window.contentView)
                let panelWidth = max(0, content.bounds.width - MarrPanelShellLayout.railWidth)
                let composerWidth = MarrChatLayout.columnWidth(in: panelWidth)
                let modelControlWidth = min(280, max(80, composerWidth - 238))
                let modelPoint = NSPoint(
                    x: content.bounds.width - MarrPanelShellLayout.railWidth - MarrUI.Spacing.medium
                        - MarrUI.Spacing.small - MarrUI.Control.compact - modelControlWidth / 2,
                    y: AnswerPanelConversationLayout.bottomInset + 12 + 14
                )
                let visibleWindows = Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber))
                try click(modelPoint)
                let search = try XCTUnwrap(descendants(of: window.contentView).compactMap { $0 as? NSSearchField }
                    .first { $0.placeholderString == "Search models" })
                XCTAssertTrue(search.window === window)
                XCTAssertEqual(Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber)), visibleWindows)
                let contextMenuText = try renderedText(window).map(\.text)
                XCTAssertTrue(contextMenuText.contains { $0 == "Context" }, contextMenuText.joined(separator: " | "))
                try snapshot(window, state: "model-context")
                // Synthetic mouse events do not perform WindowServer activation
                // when the test advances to its next window size.
                window.makeKeyAndOrderFront(nil)
                settle(window)
                NSApp.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)))
                settle(window)
                XCTAssertFalse(descendants(of: window.contentView).contains { ($0 as? NSSearchField)?.placeholderString == "Search models" })
                XCTAssertTrue(window.firstResponder === editor, "Dismissing the model menu must restore composer focus")

                // Exercise visible pixel locations through AppKit rather than
                // a keyboard shortcut or direct callback that could bypass clipping.
                let toolbarY = AnswerPanelConversationLayout.bottomInset + 12 + 14
                let steerCount = outbound.filter { $0["method"] as? String == "turn/steer" }.count
                try click(NSPoint(x: content.bounds.width - 92, y: toolbarY))
                XCTAssertEqual(outbound.filter { $0["method"] as? String == "turn/steer" }.count, steerCount + 1,
                    "The send control must remain visible and clickable beside a long model name")
                XCTAssertEqual(editor.string, "")
                try respond("turn/steer", result: [:])
                try click(NSPoint(x: content.bounds.width - 58, y: toolbarY))
                XCTAssertTrue(outbound.contains { $0["method"] as? String == "turn/interrupt" },
                    "The stop control must remain visible and clickable in the narrow running composer")
            }
        }
    }

    func testNativeEditorConsumesCompletionKeysBeforeSubmitting() throws {
        let editor = AgentInputTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
        var choices = 0
        var selection = 0
        var submissions = 0
        var completionKeys: [AgentComposerKey] = []
        editor.onKey = { key in
            switch key {
            case .down: selection += 1
            case .up: selection -= 1
            case .accept, .complete:
                choices += 1
                completionKeys.append(key)
            case .dismiss: break
            }
            return true
        }
        editor.onSubmit = { submissions += 1 }
        editor.string = "/pl"
        editor.keyDown(with: try key(125, characters: "\u{F701}"))
        editor.keyDown(with: try key(126, characters: "\u{F700}"))
        editor.keyDown(with: try key(48, characters: "\t"))
        editor.keyDown(with: try key(36, characters: "\r"))
        XCTAssertEqual(selection, 0)
        XCTAssertEqual(choices, 2)
        XCTAssertEqual(completionKeys, [.complete, .accept])
        XCTAssertEqual(submissions, 0)
        XCTAssertEqual(editor.string, "/pl")
        editor.keyDown(with: try key(36, characters: "\r", modifiers: .command))
        XCTAssertEqual(submissions, 1)
    }

    func testConversationReturnWhileBusyPreservesUnsentDraft() throws {
        try MarrUITestSupport.requireVisibleWindows()
        let session = ConversationSession()
        try withDraftPanel(session: session) { _, window, _ in
            let runningTurn = try XCTUnwrap(session.beginTurn(question: "Already running"))
            session.revealAssistant(for: runningTurn)
            settle(window)
            let content = try XCTUnwrap(window.contentView)
            let inputPoint = NSPoint(x: MarrPanelShellLayout.railWidth + 120,
                y: AnswerPanelConversationLayout.bottomInset + 12 + MarrUI.Control.compact + MarrUI.Spacing.regular + 15)
            let windowPoint = content.convert(inputPoint, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                NSApp.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: windowPoint,
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
            }
            settle(window)
            let editor = try XCTUnwrap(window.firstResponder as? NSTextView,
                "Conversation's busy follow-up TextField must install its native field editor")
            let draft = "Keep this follow-up until the answer finishes."
            editor.insertText(draft, replacementRange: NSRange(location: 0, length: 0))
            settle(window)
            XCTAssertEqual(editor.string, draft)
            editor.keyDown(with: try key(36, characters: "\r"))
            settle(window)

            XCTAssertEqual(session.turns.count, 1, "Return must not submit another turn while Conversation is busy")
            XCTAssertEqual(editor.string, draft, "A rejected submission must retain the draft")
        }
    }

    func testModeSwitchKeepsSeparateDraftsAndPendingAttachments() throws {
        try MarrUITestSupport.requireVisibleWindows()
        let session = ConversationSession()
        try withDraftPanel(session: session) { panel, window, _ in
            let conversationAttachment = session.appendAttachment(PickedAttachment(
                data: Data("Conversation notes".utf8), mimeType: "text/plain", fileName: "conversation.txt", image: nil))
            settle(window)
            let conversationEditor = try XCTUnwrap(window.firstResponder as? NSTextView)
            conversationEditor.insertText("Conversation draft", replacementRange: NSRange(location: 0, length: 0))
            settle(window)

            panel.show(.codex)
            settle(window)
            let workEditor = try XCTUnwrap(window.firstResponder as? AgentInputTextView,
                "Switching modes must focus the mounted Work editor, got \(String(describing: window.firstResponder))")
            XCTAssertEqual(workEditor.string, "", "Entering Work must not reuse a Conversation draft")
            XCTAssertEqual(session.pendingImageIDs, [conversationAttachment], "Changing modes must not move pending Conversation files")

            workEditor.insertText("Work draft", replacementRange: NSRange(location: 0, length: 0))
            let workSelection = NSRange(location: 4, length: 0)
            workEditor.setSelectedRange(workSelection)
            // Captures and files intentionally added while Work is active still
            // enter its composer, without taking an earlier Conversation file.
            let workAttachment = session.appendAttachment(PickedAttachment(
                data: Data("Work notes".utf8), mimeType: "text/plain", fileName: "work.txt", image: nil))
            settle(window)
            XCTAssertEqual(session.pendingImageIDs, [conversationAttachment])
            XCTAssertNil(session.images[workAttachment])
            XCTAssertNotNil(session.images[conversationAttachment])
            XCTAssertTrue(try renderedText(window).contains { $0.text.contains("work.txt") })

            showConversationMode(panel: panel, window: window)
            let restoredConversationEditor = try XCTUnwrap(window.firstResponder as? NSTextView)
            XCTAssertFalse(restoredConversationEditor is AgentInputTextView)
            XCTAssertEqual(restoredConversationEditor.string, "Conversation draft")
            XCTAssertEqual(session.pendingImageIDs, [conversationAttachment])
            XCTAssertFalse(try renderedText(window).contains { $0.text.contains("work.txt") })

            panel.show(.codex)
            settle(window)
            let restoredWorkEditor = try XCTUnwrap(window.firstResponder as? AgentInputTextView,
                "Returning to Work must restore keyboard focus, got \(String(describing: window.firstResponder))")
            XCTAssertEqual(restoredWorkEditor.string, "Work draft")
            XCTAssertEqual(restoredWorkEditor.selectedRange(), workSelection)
            XCTAssertTrue(try renderedText(window).contains { $0.text.contains("work.txt") })
        }
    }

    func testInitialScreenshotStillTransfersToWorkComposer() throws {
        try MarrUITestSupport.requireVisibleWindows()
        let image = PickedImage(data: Data([1]), mimeType: "image/png", fileName: "capture.png",
            image: NSImage(size: NSSize(width: 16, height: 16)))
        let session = ConversationSession(initialImage: image, initialQuestion: "Inspect this screenshot")
        try withDraftPanel(session: session, initialDestination: .codex) { _, window, _ in
            let editor = try XCTUnwrap(window.firstResponder as? AgentInputTextView)
            XCTAssertEqual(editor.string, "Inspect this screenshot")
            XCTAssertTrue(session.turns.isEmpty, "The initial request belongs to Work and must not also run as a Conversation")
            XCTAssertTrue(try renderedText(window).contains { $0.text.contains("capture.png") })
        }
    }

    func testTaskAndProjectSwitchRestoreNativeDraftSelectionAttachmentsAndContext() throws {
        try MarrUITestSupport.requireVisibleWindows()
        let session = ConversationSession()
        try withDraftPanel(session: session, initialDestination: .codex) { _, window, workspace in
            let projectA = try XCTUnwrap(workspace.workbench.selectedWorkspaceID)
            let root = try XCTUnwrap(workspace.workspaceURL)
            let taskA = workspace.workbench.createTask(workspaceID: projectA, prompt: "Task A")
            let taskB = workspace.workbench.createTask(workspaceID: projectA, prompt: "Task B")
            let otherRoot = root.appendingPathComponent("Project C", isDirectory: true)
            try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
            let projectC = workspace.workbench.ensureWorkspace(url: otherRoot)
            let taskC = workspace.workbench.createTask(workspaceID: projectC.id, prompt: "Task C")
            for task in [taskA, taskB, taskC] { workspace.workbench.updateTask(id: task.id, state: .completed) }
            @MainActor func select(_ id: UUID) throws {
                workspace.selectTask(try XCTUnwrap(workspace.workbench.tasks.first { $0.id == id }))
                settle(window)
            }

            try select(taskA.id)
            let editorA = try XCTUnwrap(window.firstResponder as? AgentInputTextView)
            workspace.bindFileMention(path: root.appendingPathComponent("Notes.md").path)
            editorA.insertText("Draft A @Notes.md", replacementRange: NSRange(location: 0, length: 0))
            settle(window)
            let selectionA = NSRange(location: 2, length: 3)
            editorA.setSelectedRange(selectionA)
            let attachmentA = session.appendAttachment(PickedAttachment(
                data: Data("File A".utf8), mimeType: "text/plain", fileName: "a.txt", image: nil))
            settle(window)
            let keyA = workspace.composerDraftKey
            let bindingA = workspace.composerBindings
            XCTAssertEqual(bindingA.count, 1)

            try select(taskB.id)
            let editorB = try XCTUnwrap(window.firstResponder as? AgentInputTextView)
            XCTAssertEqual(editorB.string, "")
            XCTAssertTrue(workspace.composerBindings.isEmpty)
            editorB.insertText("Draft B", replacementRange: NSRange(location: 0, length: 0))
            let attachmentB = session.appendAttachment(PickedAttachment(
                data: Data("File B".utf8), mimeType: "text/plain", fileName: "b.txt", image: nil))
            settle(window)
            let keyB = workspace.composerDraftKey

            try select(taskC.id)
            let editorC = try XCTUnwrap(window.firstResponder as? AgentInputTextView)
            XCTAssertEqual(editorC.string, "", "Another project must start with its own draft")
            editorC.insertText("Draft C", replacementRange: NSRange(location: 0, length: 0))
            settle(window)
            let keyC = workspace.composerDraftKey

            try select(taskA.id)
            let restoredA = try XCTUnwrap(window.firstResponder as? AgentInputTextView)
            XCTAssertEqual(restoredA.string, "Draft A @Notes.md")
            XCTAssertEqual(restoredA.selectedRange(), selectionA)
            XCTAssertEqual(workspace.composerBindings, bindingA)
            let restarted = ComposerDraftStore(rootURL: workspace.composerDraftStore.rootURL)
            XCTAssertEqual(restarted.draft(for: keyA).attachments.map(\.id), [attachmentA])
            XCTAssertEqual(restarted.draft(for: keyA).selection, selectionA)
            XCTAssertEqual(restarted.draft(for: keyB).text, "Draft B")
            XCTAssertEqual(restarted.draft(for: keyB).attachments.map(\.id), [attachmentB])
            XCTAssertEqual(restarted.draft(for: keyC).text, "Draft C")
            XCTAssertTrue(restarted.draft(for: keyC).attachments.isEmpty)
        }
    }

    func testNativeEditorNewlineAndUnmatchedReturnKeepTheirMeaning() throws {
        let editor = AgentInputTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
        var submissions = 0
        editor.onKey = { _ in false }
        editor.onSubmit = { submissions += 1 }
        editor.string = "First"
        editor.setSelectedRange(NSRange(location: 5, length: 0))
        editor.keyDown(with: try key(36, characters: "\r", modifiers: .shift))
        XCTAssertEqual(editor.string, "First\n")
        XCTAssertEqual(submissions, 0)
        editor.keyDown(with: try key(36, characters: "\r"))
        XCTAssertEqual(submissions, 1)
    }

    func testNativeEditorAppliesPendingFocusOnWindowAttachment() {
        let window = MarrOffscreenTestWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 160),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 160))
        window.contentView = content
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
        let editor = AgentInputTextView(frame: scroll.bounds)
        var wantsFocus = true
        editor.requestedFocus = { wantsFocus }
        scroll.documentView = editor
        editor.applyRequestedFocus() // SwiftUI can update before a window exists.
        content.addSubview(scroll)
        XCTAssertTrue(window.firstResponder === editor, "Attaching must honor an earlier focus request")

        wantsFocus = false
        editor.applyRequestedFocus()
        let otherField = NSTextField(frame: NSRect(x: 0, y: 100, width: 200, height: 24))
        content.addSubview(otherField)
        XCTAssertTrue(window.makeFirstResponder(otherField))
        let previousResponder = window.firstResponder
        scroll.removeFromSuperview()
        content.addSubview(scroll)
        XCTAssertTrue(window.firstResponder === previousResponder, "Remounting without a focus request must not steal another field's focus")

        scroll.removeFromSuperview()
        wantsFocus = true
        content.addSubview(scroll)
        XCTAssertTrue(window.firstResponder === editor, "A later mount must read the latest desired focus")
        XCTAssertFalse(window.isVisible)
    }

    func testMarkedInputDoesNotTriggerCompletionOrSubmission() throws {
        let editor = AgentInputTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
        var intercepted = false
        editor.onKey = { _ in intercepted = true; return true }
        editor.onSubmit = { intercepted = true }
        editor.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        editor.keyDown(with: try key(36, characters: "\r"))
        XCTAssertFalse(intercepted)
    }

    func testCompletionPanelsRenderInBothAppearances() throws {
        let variants: [(String, String, [AgentCompletionOption])] = [
            ("commands", "/", [
                .init(id: "plan", title: "Plan mode", detail: "Plan a task before making changes", symbol: "lightbulb"),
                .init(id: "goal", title: "Goal", detail: "Set or manage a persistent task goal", symbol: "target"),
                .init(id: "skills", title: "Skills", detail: "Manage skills in Settings", symbol: "square.stack.3d.up"),
                .init(id: "tui", title: "Terminal", detail: "Terminal-specific display setting", symbol: "terminal", enabled: false)
            ]),
            ("files", "@", [
                .init(id: "one", title: "RuntimeWorkspace.swift", detail: "Marr/Workspace/RuntimeWorkspace.swift", symbol: "doc.text"),
                .init(id: "two", title: "AgentComposerSupportTests.swift", detail: "MarrTests/Conversation/AgentComposerSupportTests.swift", symbol: "doc.text")
            ]),
            ("skills", "$", [
                .init(id: "chess", title: "Chess Analysis", detail: "Analyze PGN games with boards and engine notes", symbol: "shippingbox", source: "Local file"),
                .init(id: "documents", title: "Documents", detail: "Create and edit Word and Google Docs files", symbol: "shippingbox", source: "From Documents"),
                .init(id: "figma", title: "Figma: Figma Code Connect", detail: "Creates and maintains Figma Code Connect template files", symbol: "shippingbox", source: "From Figma")
            ]),
            ("context", "@", [
                .init(id: "files", title: "Files and folders", detail: "", symbol: "paperclip", section: "Add"),
                .init(id: "goal", title: "Goal", detail: "Set a goal to keep pursuing", symbol: "target", section: "Add"),
                .init(id: "plan", title: "Plan mode", detail: "Turn plan mode on", symbol: "lightbulb", section: "Add"),
                .init(id: "drive", title: "Google Drive", detail: "Drive, Docs, Sheets or Slides", symbol: "puzzlepiece.extension", section: "Plugins")
            ])
        ]
        for (name, prefix, options) in variants {
            for width: CGFloat in [356, 720] {
            for (appearance, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                let root = VStack(spacing: 10) {
                    AgentCompletionPanel(title: name.capitalized, options: options, selectedIndex: .constant(0), onSelect: { _ in })
                    HStack(spacing: 12) {
                        Image(systemName: "plus")
                        Text(prefix).frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "arrow.up.circle.fill")
                    }
                    .font(.system(size: 15)).padding(14)
                    .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
                }
                .padding(20).frame(width: width + 40, height: 400, alignment: .bottom)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, scheme)
                let hosting = NSHostingView(rootView: root)
                hosting.frame = NSRect(x: 0, y: 0, width: width + 40, height: 400)
                let window = MarrOffscreenTestWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                window.contentView = hosting
                hosting.layoutSubtreeIfNeeded()
                hosting.displayIfNeeded()
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = "composer-\(name)-\(appearance)-\(Int(width))"
                attachment.lifetime = .keepAlways
                add(attachment)
                XCTAssertFalse(window.isVisible)
                window.close()
            }
            }
        }
    }

    func testCompactRowsKeepStableHeightAndKeyboardSkipsDisabledItems() {
        let options: [AgentCompletionOption] = [
            .init(id: "files", title: "Files and folders", detail: "", symbol: "paperclip", section: "Add"),
            .init(id: "plan", title: "Plan", detail: "Busy", symbol: "lightbulb", enabled: false, section: "Add"),
            .init(id: "plugin", title: "Documents", detail: String(repeating: "Long description ", count: 200), symbol: "shippingbox", section: "Plugins")
        ]
        XCTAssertEqual(AgentCompletionLayout.contentHeight(options), 142)
        XCTAssertEqual(AgentCompletionLayout.nextIndex(from: 0, by: 1, options: options), 2)
        XCTAssertEqual(AgentCompletionLayout.nextIndex(from: 2, by: 1, options: options), 0)
        XCTAssertEqual(AgentCompletionLayout.nextIndex(from: 0, by: -1, options: options), 2)
    }

    func testSkillPresentationUsesMetadataAndKeepsCanonicalIdentityInHelp() throws {
        let skill = try XCTUnwrap(CodexSkill(json: ["name": "documents:documents", "path": "/skills/docs/SKILL.md",
            "description": "A very long runtime description", "interface": ["displayName": "Documents", "shortDescription": "Create **Word** files"]]))
        let option = AgentCompletionOption.skill(skill)
        XCTAssertEqual(option.title, "Documents")
        XCTAssertEqual(option.detail, "Create Word files")
        XCTAssertEqual(option.source, "From Documents")
        XCTAssertTrue(option.helpText.contains("$documents:documents"))
        XCTAssertTrue(option.helpText.contains(skill.path))
        XCTAssertEqual(AgentCompletionOption.readableName("figma:figma-code-connect"), "Figma: Figma Code Connect")
    }

    private func key(_ code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    private func withDraftPanel(
        session: ConversationSession,
        initialDestination: AnswerPanelUtilityDestination? = nil,
        modelFixtures: Bool = false,
        _ body: (AnswerPanelController, NSWindow, RuntimeWorkspaceController) throws -> Void
    ) throws {
        try MarrUITestSupport.requireVisibleWindows()
        let suite = "Marr.ComposerDrafts.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let historyResources = MarrHistoryTestResources(rootURL: root)
        addTeardownBlock { try await historyResources.cleanUp() }
        defer {
            defaults.removePersistentDomain(forName: suite)
        }
        let store = WorkbenchStore(defaults: defaults)
        _ = store.upsertWorkspace(url: root, bookmark: Data())
        defaults.set(Data(), forKey: "codex.workspace.bookmark")
        var outbound: [[String: Any]] = []
        let workspace = RuntimeWorkspaceController(defaults: defaults, outboundMessage: { outbound.append($0) },
            attachmentDirectory: root.appendingPathComponent("Attachments"), codexSyncEnabled: true)
        if modelFixtures {
            workspace.refreshCapabilities()
            workspace.refreshModels()
            let request = try XCTUnwrap(outbound.last { $0["method"] as? String == "model/list" })
            workspace.receiveServerMessage(["id": try XCTUnwrap(request["id"]), "result": ["data": [
                ["model": "fixture-sol", "displayName": "Fixture Sol",
                 "supportedReasoningEfforts": [["reasoningEffort": "low"], ["reasoningEffort": "medium"], ["reasoningEffort": "high"]],
                 "defaultReasoningEffort": "medium"],
                ["model": "fixture-astra", "displayName": "Fixture Astra",
                 "supportedReasoningEfforts": [["reasoningEffort": "low"], ["reasoningEffort": "high"]],
                 "defaultReasoningEffort": "high"]
            ]]])
            workspace.selectModel("fixture-sol")
        }
        let history = historyResources.makeStore(at: root.appendingPathComponent("History"))
        let repository = InferenceSettingsRepository(values: UserDefaultsSettingsStore(defaults: defaults),
            secrets: ComposerFixtureSecrets())
        let controller = MarrController(client: ComposerFixtureClient(), usesCodexForConversation: true,
            historyStore: history, tokenUsageStore: TokenUsageStore(rootURL: root.appendingPathComponent("Usage")),
            settingsRepository: repository, codexWorkspace: workspace)
        let panel = AnswerPanelController(controller: controller, historyStore: history, session: session,
            anchorRect: .zero, persistImmediately: false, initialDestination: initialDestination)
        defer { panel.close() }
        let window = panel.windowForTesting
        panel.show(preservingFrame: NSRect(x: 100, y: 100, width: 420, height: 596))
        settle(window)
        try body(panel, window, workspace)
    }

    private func showConversationMode(panel: AnswerPanelController, window: NSWindow) {
        let press = NSSelectorFromString("accessibilityPerformPress")
        let identifier = NSSelectorFromString("accessibilityIdentifier")
        if let tab = accessibilityElements(in: window).first(where: {
            $0.responds(to: identifier)
                && $0.value(forKey: "accessibilityIdentifier") as? String == "marr.mode.conversation"
                && $0.responds(to: press)
        }) {
            _ = tab.perform(press)
        } else {
            // SwiftUI may omit virtual AX nodes in an in-process test. The
            // panel's navigation API exercises the same mode-change lifecycle.
            panel.show(.conversation)
        }
        settle(window)
    }

    private func settle(_ window: NSWindow) {
        // The panel's navigation spring lasts longer than 240 ms. Snapshot only
        // after that transition, so OCR does not inspect a disappearing field.
        RunLoop.main.run(until: Date().addingTimeInterval(0.45))
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView?.displayIfNeeded()
    }

    private func descendants(of view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    private func accessibilityElements(in window: NSWindow) -> [NSObject] {
        var seen = Set<ObjectIdentifier>()
        var result: [NSObject] = []
        func visit(_ value: Any) {
            guard let element = value as? NSObject,
                  seen.insert(ObjectIdentifier(element)).inserted else { return }
            result.append(element)
            if element.responds(to: NSSelectorFromString("accessibilityChildren")),
               let children = element.value(forKey: "accessibilityChildren") as? [Any] {
                for child in children { visit(child) }
            }
            if let view = value as? NSView { for child in view.subviews { visit(child) } }
        }
        if let content = window.contentView { visit(content) }
        return result
    }

    private func accessibilityText(_ element: NSObject) -> String {
        ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].compactMap { attribute in
            element.responds(to: NSSelectorFromString(attribute)) ? element.value(forKey: attribute) as? String : nil
        }.joined(separator: " ")
    }

    private func attachWindowSnapshots(_ window: NSWindow, name: String) throws {
        let originalAppearance = window.appearance
        defer { window.appearance = originalAppearance }
        // Full-window navigation uses the app's SwiftUI theme. Changing only the
        // NSWindow to dark does not update that theme. Component fixtures below
        // explicitly set both environments for the light/dark comparison.
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua)] {
            window.appearance = NSAppearance(named: appearance)
            settle(window)
            let bitmap = try windowBitmap(window)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
            attachment.name = name + "-" + suffix
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func windowBitmap(_ window: NSWindow) throws -> NSBitmapImageRep {
        let content = try XCTUnwrap(window.contentView)
        let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let cachedImage = NSImage(cgImage: try XCTUnwrap(bitmap.cgImage), size: content.bounds.size)
        let image = NSImage(size: content.bounds.size)
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            image.lockFocus()
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(rect: NSRect(origin: .zero, size: content.bounds.size)).fill()
            cachedImage.draw(in: NSRect(origin: .zero, size: content.bounds.size), from: .zero,
                             operation: .sourceOver, fraction: 1)
            image.unlockFocus()
        }
        return try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
    }

    private func renderedText(_ window: NSWindow) throws -> [(text: String, bounds: CGRect)] {
        // SwiftUI's in-process AX tree can omit its virtual nodes when no AX client is attached.
        // Reading our own window pixels verifies that the completion is actually rendered.
        // Command names are English while their inline summaries are Chinese.
        // A bilingual pass segments mixed rows correctly; the English pass
        // preserves short labels and filenames that Chinese OCR can confuse.
        // Both passes inspect the same pixels without supplying expected words.
        let bitmap = try XCTUnwrap(windowBitmap(window).cgImage)
        var observations: [(text: String, bounds: CGRect)] = []
        for languages in [["zh-Hans", "en-US"], ["en-US"]] {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = languages
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: bitmap).perform([request])
            observations.append(contentsOf: (request.results ?? []).compactMap { observation in
                observation.topCandidates(1).first.map { ($0.string, observation.boundingBox) }
            })
        }
        return observations
    }

    private func attachGeometry(_ window: NSWindow, editor: NSView) {
        var lines = ["Window: \(window.frame)"]
        var current: NSView? = editor
        while let view = current {
            lines.append("\(type(of: view)): frame=\(view.frame), bounds=\(view.bounds)")
            current = view.superview
        }
        lines.append("AX: " + accessibilityElements(in: window).map(accessibilityText).joined(separator: " | "))
        let attachment = XCTAttachment(string: lines.joined(separator: "\n"))
        attachment.name = "answer-panel-composer-geometry"
        attachment.lifetime = .keepAlways
        add(attachment)
        print(lines.prefix(10).joined(separator: "\n"))
    }
}

private struct ComposerFixtureClient: VisionAIClient {
    func ask(request: MarrCore.VisionRequest, model: String, connection: InferenceConnection) async throws -> String {
        XCTFail("The composer integration fixture must never send a model request")
        return ""
    }
}

private struct ComposerFixtureSecrets: SecretStore {
    func string(for account: String) throws -> String? { nil }
    func set(_ value: String, for account: String) throws { XCTFail("The composer integration fixture must never save credentials") }
}
