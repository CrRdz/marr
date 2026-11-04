import AppKit
import MarrCore
import MarrNetworking
import MarrSettings
import SwiftUI
import Vision
import XCTest
@testable import Marr

@MainActor
final class AttachmentDropTests: XCTestCase {
    func testWindowDropSurfaceAddsActualFilesToWorkspaceAndCodexDrafts() throws {
        for destination in [AnswerPanelUtilityDestination.work, .codex] {
            let root = try temporaryDirectory()
            let suite = "Marr.DropIntegration.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let resources = MarrHistoryTestResources(rootURL: root)
            addTeardownBlock { try await resources.cleanUp() }
            let history = resources.makeStore(at: root.appendingPathComponent("History"))
            let workbench = WorkbenchStore(defaults: defaults)
            _ = workbench.upsertWorkspace(url: root, bookmark: Data())
            let runtime = RuntimeWorkspaceController(defaults: defaults, outboundMessage: { _ in },
                attachmentDirectory: root.appendingPathComponent("Attachments"),
                draftDirectory: root.appendingPathComponent("Drafts"), codexSyncEnabled: true)
            let controller = MarrController(client: DropFixtureClient(), usesCodexForConversation: true,
                historyStore: history, tokenUsageStore: TokenUsageStore(rootURL: root.appendingPathComponent("Usage")),
                settingsRepository: InferenceSettingsRepository(values: UserDefaultsSettingsStore(defaults: defaults),
                    secrets: DropFixtureSecrets()), codexWorkspace: runtime)
            let session = ConversationSession()
            session.setArchiveHandler(persistImmediately: false) { [weak history] in history?.save($0) }
            let key = destination == .codex ? runtime.composerDraftKey : .conversation(session.id)
            runtime.composerDraftStore.save(ComposerDraft(text: "Keep my existing question"), for: key)
            let navigation = AnswerPanelNavigation(initialDestination: destination, sidebar: nil, workspaceIDs: [])
            let view = AnswerPanelView(controller: controller, session: session, historyStore: history,
                requestCoordinator: ConversationRequestCoordinator(controller: controller, session: session),
                titleCoordinator: ConversationTitleCoordinator(controller: controller, session: session),
                navigation: navigation, actions: AnswerPanelActions(close: {}, openHistoryConversation: { _ in }))
            let hosting = NSHostingView(rootView: AnyView(view))
            let frame = NSRect(x: 0, y: 0, width: 720, height: 640)
            let window = MarrOffscreenTestWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = AnswerPanelContentView(frame: frame, hostedView: hosting)
            defer {
                navigation.persistDraft = nil
                hosting.rootView = AnyView(EmptyView())
                hosting.layoutSubtreeIfNeeded()
                window.contentView = nil
                window.close()
            }
            settle(window)
            let receiver = try XCTUnwrap(descendants(window.contentView).compactMap { $0 as? AttachmentDropTargetView }.first)
            let content = try XCTUnwrap(window.contentView as? AnswerPanelContentView)
            XCTAssertTrue(content.registeredDraggedTypes.contains(.fileURL))
            XCTAssertTrue(content.attachmentDropTarget === receiver)
            XCTAssertGreaterThan(receiver.bounds.width, 300)
            XCTAssertGreaterThan(receiver.bounds.height, 300)
            XCTAssertNil(receiver.hitTest(NSPoint(x: 100, y: 100)), "The drop surface must not block typing, scrolling or clicks")
            let file = try write("拖入 notes.txt", data: Data("Dropped file contents".utf8), in: root)
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            board.writeObjects([file as NSURL])
            let drag = AttachmentDraggingInfo(pasteboard: board)
            drag.draggingDestinationWindow = window
            drag.draggingLocation = receiver.convert(NSPoint(x: receiver.bounds.midX, y: receiver.bounds.midY), to: nil)
            // Resolve the destination from the real hit-test ancestor chain.
            // Calling the transparent marker directly concealed the original bug.
            var hit = content.hitTest(content.convert(drag.draggingLocation, from: nil))
            while let view = hit, !view.registeredDraggedTypes.contains(.fileURL) {
                hit = view.superview
            }
            let destinationView = try XCTUnwrap(hit)
            XCTAssertTrue(destinationView === content)
            XCTAssertEqual(destinationView.draggingEntered(drag), .copy)
            XCTAssertEqual(destinationView.draggingUpdated(drag), .copy)
            XCTAssertTrue(destinationView.prepareForDragOperation(drag))
            XCTAssertTrue(destinationView.performDragOperation(drag))
            destinationView.concludeDragOperation(drag)
            settle(window)
            let saved = runtime.composerDraftStore.draft(for: key)
            XCTAssertEqual(saved.text, "Keep my existing question")
            XCTAssertEqual(saved.attachments.map(\.fileName), ["拖入 notes.txt"])
            XCTAssertEqual(saved.attachments.first?.data, Data("Dropped file contents".utf8))
            if destination == .work {
                XCTAssertEqual(session.pendingImageIDs.count, 1, "The attachment must appear in the visible composer")
            }
            let restarted = ComposerDraftStore(rootURL: runtime.composerDraftStore.rootURL)
            XCTAssertEqual(restarted.draft(for: key).attachments, saved.attachments)
            navigation.show(.settings)
            settle(window)
            XCTAssertTrue(content.registeredDraggedTypes.isEmpty, "Settings must not accept files into a hidden conversation")
        }
    }

    func testNativeWorkspaceDropSurfaceRejectsNonFileDragsAndDisabledDrops() {
        let receiver = AttachmentDropTargetView()
        var targeted = false
        receiver.onDrop = { _ in XCTFail("A disabled or non-file drop must not import attachments"); return false }
        receiver.onTargetChanged = { targeted = $0 }
        receiver.isDropEnabled = true
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let drag = AttachmentDraggingInfo(pasteboard: board)
        board.setString("ordinary text", forType: .string)
        XCTAssertEqual(receiver.draggingEntered(drag), [])
        XCTAssertFalse(receiver.performDragOperation(drag))
        board.clearContents()
        board.writeObjects([URL(fileURLWithPath: "/tmp/notes.txt") as NSURL])
        XCTAssertEqual(receiver.draggingEntered(drag), .copy)
        XCTAssertTrue(targeted)
        receiver.draggingExited(drag)
        XCTAssertFalse(targeted)
        receiver.isDropEnabled = false
        XCTAssertTrue(receiver.registeredDraggedTypes.isEmpty)
        XCTAssertEqual(receiver.draggingEntered(drag), [])
        XCTAssertFalse(receiver.performDragOperation(drag))
    }

    func testDropPromptRendersInNarrowAndWideWorkspacesInBothAppearances() throws {
        for width: CGFloat in [356, 720] {
            for scheme in [ColorScheme.light, .dark] {
                let root = Color(nsColor: .windowBackgroundColor)
                    .frame(width: width, height: 400)
                    .modifier(AttachmentDropArea(isEnabled: true, isTargeted: .constant(true), tint: .accentColor, onDrop: { _ in true }))
                    .environment(\.colorScheme, scheme)
                let hosting = NSHostingView(rootView: root)
                hosting.frame = NSRect(x: 0, y: 0, width: width, height: 400)
                let window = MarrOffscreenTestWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                window.contentView = hosting
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                hosting.layoutSubtreeIfNeeded()
                hosting.displayIfNeeded()
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                let image = NSImage(size: hosting.bounds.size)
                window.effectiveAppearance.performAsCurrentDrawingAppearance {
                    image.lockFocus()
                    NSColor.windowBackgroundColor.setFill()
                    NSBezierPath(rect: hosting.bounds).fill()
                    NSImage(cgImage: bitmap.cgImage!, size: hosting.bounds.size).draw(in: hosting.bounds)
                    image.unlockFocus()
                }
                let rendered = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
                let recognition = VNRecognizeTextRequest()
                try VNImageRequestHandler(cgImage: try XCTUnwrap(rendered.cgImage)).perform([recognition])
                let text = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                XCTAssertTrue(text.contains("Drop files to attach"), "The drop prompt must remain legible in every theme and width")
                let data = try XCTUnwrap(rendered.representation(using: .png, properties: [:]))
                let name = "marr-attachment-drop-\(scheme)-\(Int(width)).png"
                let output = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                try data.write(to: output)
                print("MARR_DROP_SNAPSHOT: \(output.path)")
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
                attachment.name = name
                attachment.lifetime = .keepAlways
                add(attachment)
                window.contentView = nil
                window.close()
            }
        }
    }

    func testMixedFileImportPreservesExistingAttachmentsAndContinuesAfterFailures() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try write("学习 notes.txt", data: Data("First file".utf8), in: root)
        let unsupported = try write("installer.dmg", data: Data([0]), in: root)
        let missing = root.appendingPathComponent("missing.txt")
        let directory = root.appendingPathComponent("folder.txt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let last = try write("data.csv", data: Data("a,b\n1,2".utf8), in: root)
        let existing = ConversationImageAsset(data: Data("Draft".utf8), mimeType: "text/plain", fileName: "draft.txt")
        let imported = AttachmentFileImporter.append([first, unsupported, missing, directory, last], to: [existing])
        XCTAssertEqual(imported.attachments.map(\.fileName), ["draft.txt", "学习 notes.txt", "data.csv"])
        XCTAssertEqual(imported.attachments.first, existing)
        XCTAssertEqual(imported.attachments[1].data, Data("First file".utf8))
        XCTAssertEqual(imported.errors.count, 3)
    }

    func testCountLimitAppliesAcrossRepeatedDropsAndFailedFilesDoNotConsumeSlots() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write("note.txt", data: Data([1]), in: root)
        let existing = (0..<9).map { ConversationImageAsset(data: Data([0]), mimeType: "text/plain", fileName: "\($0).txt") }
        let result = AttachmentFileImporter.append([root.appendingPathComponent("missing.txt"), file, file], to: existing)
        XCTAssertEqual(result.attachments.count, AttachmentFileSupport.maximumAttachmentCount)
        XCTAssertEqual(result.errors.count, 2)
        let second = AttachmentFileImporter.append([file], to: result.attachments)
        XCTAssertEqual(second.attachments, result.attachments)
        XCTAssertEqual(second.errors.count, 1)
    }

    func testCombinedSizeLimitIncludesExistingDraftAndStillAllowsSmallerFile() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let large = try write("large.txt", data: Data(repeating: 1, count: 100), in: root)
        let small = try write("small.txt", data: Data([1]), in: root)
        let existing = ConversationImageAsset(data: Data(repeating: 0, count: AttachmentFileSupport.maximumRequestBytes - 100),
            mimeType: "text/plain", fileName: "existing.txt")
        let result = AttachmentFileImporter.append([large, small], to: [existing])
        XCTAssertEqual(result.attachments.map(\.fileName), ["existing.txt", "small.txt"])
        XCTAssertEqual(result.errors.count, 1)
    }

    func testSingleOversizedFileIsRejectedBeforeItIsAdded() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write("oversized.txt", data: Data(), in: root)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(AttachmentFileSupport.maximumFileBytes))
        try handle.close()
        let result = AttachmentFileImporter.append([file], to: [])
        XCTAssertTrue(result.attachments.isEmpty)
        XCTAssertEqual(result.errors.count, 1)
    }

    func testNativeEditorReceivesFilesAsAttachmentsWithoutChangingDraftText() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let urls = [URL(fileURLWithPath: "/tmp/one.txt"), URL(fileURLWithPath: "/tmp/图表.png")]
        board.writeObjects(urls as [NSURL])
        let drag = AttachmentDraggingInfo(pasteboard: board)
        let editor = AgentInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        editor.string = "Keep this question"
        editor.setSelectedRange(NSRange(location: 5, length: 4))
        var received: [URL] = []
        var targets: [Bool] = []
        editor.onFileDrop = { received = $0; return true }
        editor.onFileDragTargetChanged = { targets.append($0) }
        XCTAssertEqual(editor.draggingEntered(drag), .copy)
        XCTAssertEqual(editor.draggingUpdated(drag), .copy)
        XCTAssertTrue(editor.prepareForDragOperation(drag))
        XCTAssertTrue(editor.performDragOperation(drag))
        editor.concludeDragOperation(drag)
        XCTAssertEqual(received, urls)
        XCTAssertEqual(editor.string, "Keep this question")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 5, length: 4))
        XCTAssertEqual(targets.first, true)
        XCTAssertEqual(targets.last, false)
    }

    func testNativeEditorClearsDragHighlightOnExitAndRejectsMoveOnlyDrag() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.writeObjects([URL(fileURLWithPath: "/tmp/one.txt") as NSURL])
        let drag = AttachmentDraggingInfo(pasteboard: board)
        let editor = AgentInputTextView()
        var targeted = false
        editor.onFileDrop = { _ in XCTFail("A move-only drag must not be consumed"); return false }
        editor.onFileDragTargetChanged = { targeted = $0 }
        XCTAssertEqual(editor.draggingEntered(drag), .copy)
        XCTAssertTrue(targeted)
        editor.draggingExited(drag)
        XCTAssertFalse(targeted)
        drag.draggingSourceOperationMask = .move
        XCTAssertEqual(editor.draggingEntered(drag), [])
        XCTAssertFalse(editor.prepareForDragOperation(drag))
        XCTAssertFalse(editor.performDragOperation(drag))
    }

    private func descendants(_ view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap { descendants($0) }
    }

    private func settle(_ window: NSWindow) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView?.displayIfNeeded()
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MarrDropTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ name: String, data: Data, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
}

private struct DropFixtureClient: VisionAIClient {
    func ask(request: MarrCore.VisionRequest, model: String, connection: InferenceConnection) async throws -> String {
        XCTFail("A file drop must not submit a model request")
        return ""
    }
}

private struct DropFixtureSecrets: SecretStore {
    func string(for account: String) throws -> String? { nil }
    func set(_ value: String, for account: String) throws { XCTFail("The fixture must not save credentials") }
}

@MainActor
private final class AttachmentDraggingInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    var draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation = .copy
    var draggingLocation: NSPoint = .zero
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    init(pasteboard: NSPasteboard) { draggingPasteboard = pasteboard }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
        classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {
        var stop: ObjCBool = false
        for (index, item) in (draggingPasteboard.pasteboardItems ?? []).enumerated() {
            block(NSDraggingItem(pasteboardWriter: item), index, &stop)
            if stop.boolValue { break }
        }
    }
}
