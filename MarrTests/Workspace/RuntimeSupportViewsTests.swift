import AppKit
import MarrCore
import MarrNetworking
import SwiftUI
import Vision
import XCTest
@testable import Marr

@MainActor
final class CodexSupportViewsTests: XCTestCase {
    func testEmptyAndShortTranscriptsKeepFollowingThroughScrollGestures() {
        final class Document: NSView { override var isFlipped: Bool { true } }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 300))
        let document = Document(frame: NSRect(x: 0, y: 0, width: 420, height: 0))
        scroll.documentView = document
        let follower = MarrScrollFollower()
        defer { follower.detach() }
        follower.update(identity: "empty", jumpRequest: 0)
        follower.attach(to: scroll)
        var followingStates: [Bool] = []
        follower.onFollowingChange = { followingStates.append($0) }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.25)) }

        for height: CGFloat in [0, 120, 300] {
            document.setFrameSize(NSSize(width: 420, height: height))
            settle()
            for towardEarlier in [true, false] {
                NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
                follower.userDidScroll(towardEarlier: towardEarlier)
                XCTAssertTrue(follower.isFollowing)
                NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
                settle()
                XCTAssertTrue(follower.isFollowing)
            }
        }
        XCTAssertFalse(followingStates.contains(false), "Empty-state gestures must never offer a jump")

        document.setFrameSize(NSSize(width: 420, height: 900))
        settle()
        XCTAssertEqual(scroll.contentView.bounds.minY, 600, accuracy: 1)
        follower.userDidScroll(towardEarlier: true)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 120))
        settle()
        XCTAssertFalse(follower.isFollowing)
        document.setFrameSize(NSSize(width: 420, height: 120))
        settle()
        XCTAssertTrue(follower.isFollowing, "Clearing a transcript must discard the paused follow state")
    }

    func testScrollingUpNearBottomCannotBePulledBackByLazyHeightChanges() throws {
        final class Document: NSView { override var isFlipped: Bool { true } }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 300))
        let document = Document(frame: NSRect(x: 0, y: 0, width: 420, height: 1200))
        scroll.documentView = document
        let follower = MarrScrollFollower()
        defer { follower.detach() }
        follower.update(identity: "history", jumpRequest: 0)
        follower.attach(to: scroll)
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
        settle()
        let bottom = document.frame.height - scroll.contentView.bounds.height
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom - 4))
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        settle()
        XCTAssertFalse(follower.isFollowing, "A small upward gesture must not rearm the old 48-point threshold")
        XCTAssertEqual(scroll.contentView.bounds.minY, bottom - 4, accuracy: 0.5)
        // Lazy rows revise the estimate after the gesture ends.
        document.setFrameSize(NSSize(width: 420, height: 1800))
        settle()
        XCTAssertEqual(scroll.contentView.bounds.minY, bottom - 4, accuracy: 0.5)
        follower.update(identity: "history", jumpRequest: 1)
        settle()
        XCTAssertEqual(scroll.contentView.bounds.minY, 1500, accuracy: 1)
        // A phase-less mouse wheel/momentum event arrives before bounds change,
        // and must cancel an already queued bottom follow.
        document.setFrameSize(NSSize(width: 420, height: 1900))
        follower.userDidScroll(towardEarlier: true)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 1496))
        settle()
        XCTAssertFalse(follower.isFollowing)
        XCTAssertEqual(scroll.contentView.bounds.minY, 1496, accuracy: 0.5)
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        XCTAssertEqual(scroll.contentView.bounds.minY, 1496, accuracy: 0.5)
        follower.userDidScroll(towardEarlier: false)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 1600))
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        XCTAssertTrue(follower.isFollowing, "Deliberately scrolling back to the latest edge restores following")
    }

    func testReplyScrollFollowsGrowthButPreservesReaderPositionUntilJumpOrTaskChange() throws {
        final class Document: NSView {
            override var isFlipped: Bool { true }
        }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 300))
        let document = Document(frame: NSRect(x: 0, y: 0, width: 420, height: 900))
        scroll.documentView = document
        let follower = MarrScrollFollower()
        var scrollingStates: [Bool] = []
        follower.onLiveScrollChange = { scrollingStates.append($0) }
        defer { follower.detach() }
        follower.update(identity: "first-task", jumpRequest: 0)
        follower.attach(to: scroll)
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
        func bottom() -> CGFloat { document.frame.height - scroll.contentView.bounds.height }
        settle()
        XCTAssertEqual(scroll.contentView.bounds.minY, bottom(), accuracy: 1)

        document.setFrameSize(NSSize(width: 420, height: 1200))
        settle()
        XCTAssertEqual(scroll.contentView.bounds.minY, bottom(), accuracy: 1)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 240))
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        XCTAssertEqual(scrollingStates, [true, false])
        settle()
        XCTAssertFalse(follower.isFollowing)

        document.setFrameSize(NSSize(width: 420, height: 1800))
        settle()
        XCTAssertEqual(scroll.contentView.bounds.minY, 240, accuracy: 1, "Streaming must not steal reading position")
        follower.update(identity: "first-task", jumpRequest: 1)
        settle()
        XCTAssertTrue(follower.isFollowing)
        XCTAssertEqual(scroll.contentView.bounds.minY, bottom(), accuracy: 1)

        scroll.contentView.scroll(to: NSPoint(x: 0, y: 120))
        settle()
        XCTAssertFalse(follower.isFollowing)
        follower.update(identity: "second-task", jumpRequest: 1)
        settle()
        XCTAssertEqual(scroll.contentView.bounds.minY, bottom(), accuracy: 1)

        document.setFrameSize(NSSize(width: 420, height: 2100))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 120))
        settle()
        XCTAssertFalse(follower.isFollowing)
        XCTAssertEqual(scroll.contentView.bounds.minY, 120, accuracy: 1,
                       "Keyboard scrolling must win over a pending automatic follow")
        follower.update(identity: "second-task", jumpRequest: 2)
        settle()
        scroll.setFrameSize(NSSize(width: 420, height: 180))
        settle()
        XCTAssertTrue(follower.isFollowing)
        XCTAssertEqual(scroll.contentView.bounds.minY, bottom(), accuracy: 1,
                       "Shrinking the viewport must keep the latest output visible")
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        follower.detach()
        XCTAssertEqual(scrollingStates, [true, false, true, false], "Closing mid-scroll must release the poll gate")
    }

    func testFollowingScrollViewTracksActualSwiftUIReplyLayoutAndOffersJump() throws {
        try MarrUITestSupport.requireVisibleWindows()
        final class Reply: ObservableObject {
            @Published var text = String(repeating: "An answer paragraph with enough text to wrap across multiple lines.\n\n", count: 18)
        }
        struct Transcript: View {
            @ObservedObject var reply: Reply
            var body: some View {
                MarrFollowingScrollView(identity: "streaming-task") {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(0..<6) { index in
                            Text("Earlier message \(index)").frame(height: 90)
                        }
                        Text(reply.text).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(12)
                }
            }
        }
        let reply = Reply()
        let window = try sliderWindow(Transcript(reply: reply), size: NSSize(width: 420, height: 300))
        defer { window.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let scroll = try XCTUnwrap(descendants(try XCTUnwrap(window.contentView)).compactMap { $0 as? NSScrollView }.first)
        let document = try XCTUnwrap(scroll.documentView)
        func settle() {
            for _ in 0..<3 { settleSlider(window) }
        }
        func distanceFromBottom() -> CGFloat { document.frame.height - scroll.contentView.bounds.maxY }
        settle()
        XCTAssertLessThanOrEqual(abs(distanceFromBottom()), 2)
        reply.text += String(repeating: "More streamed content arriving at the end of this response.\n\n", count: 12)
        settle()
        XCTAssertLessThanOrEqual(abs(distanceFromBottom()), 2)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 120))
        scroll.reflectScrolledClipView(scroll.contentView)
        settle()
        let readingPosition = scroll.contentView.bounds.minY
        reply.text += String(repeating: "Another update.\n\n", count: 12)
        settle()
        XCTAssertEqual(scroll.contentView.bounds.minY, readingPosition, accuracy: 2)
        let hosting = try XCTUnwrap(window.contentView)
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let preview = FileManager.default.temporaryDirectory.appendingPathComponent("marr-agent-ui-preview", isDirectory: true)
        try FileManager.default.createDirectory(at: preview, withIntermediateDirectories: true)
        try bitmap.representation(using: .png, properties: [:])?.write(to: preview.appendingPathComponent("jump-to-latest.png"))
        // In-process SwiftUI hosting does not always expose virtual AX
        // children. Locate the rendered control and exercise its native click.
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: try XCTUnwrap(bitmap.cgImage)).perform([request])
        let label = try XCTUnwrap(request.results?.first {
            $0.topCandidates(1).first?.string.contains("Jump to latest") == true
        })
        let rect = label.boundingBox
        let click = hosting.convert(NSPoint(
            x: rect.midX * hosting.bounds.width,
            y: (hosting.isFlipped ? 1 - rect.midY : rect.midY) * hosting.bounds.height
        ), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: click,
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
        }
        settle()
        XCTAssertLessThanOrEqual(abs(distanceFromBottom()), 2)
    }

    func testRunPresentationUsesTurnLifecycleInsteadOfMessageCompletion() {
        let user = WorkActivity(kind: .user, title: "You", turnID: "turn-1")
        var response = WorkActivity(kind: .message, title: "Codex", detail: "Checking the workspace",
                                     isComplete: false, turnID: "turn-1")
        XCTAssertEqual(CodexRunPresentation.resolve(isRunning: true, requiresInput: false,
                                                    activities: [user, response]), .responding)

        response.isComplete = true
        XCTAssertEqual(CodexRunPresentation.resolve(isRunning: true, requiresInput: false,
                                                    activities: [user, response]), .working,
                       "A completed commentary item does not complete its turn")
        XCTAssertNil(CodexRunPresentation.resolve(isRunning: false, requiresInput: false,
                                                  activities: [user, response]))
        response.isComplete = false
        XCTAssertNil(CodexRunPresentation.resolve(isRunning: false, requiresInput: false,
                                                  activities: [user, response]),
                     "Cached unfinished items must not restart an idle indicator")
    }

    func testRunPresentationPausesAnimationWhileInputIsRequired() {
        let activities = [
            WorkActivity(kind: .user, title: "You", turnID: "turn-1"),
            WorkActivity(kind: .command, title: "Run tests", isComplete: false, turnID: "turn-1")
        ]
        for isRunning in [true, false] {
            let presentation = CodexRunPresentation.resolve(isRunning: isRunning, requiresInput: true,
                                                             activities: activities)
            XCTAssertEqual(presentation, .needsInput)
            XCTAssertEqual(presentation?.title, "Needs your input")
            XCTAssertEqual(presentation?.isAnimating, false)
        }
        XCTAssertEqual(CodexRunPresentation.resolve(isRunning: true, requiresInput: false,
                                                    activities: activities), .runningCommand)
    }

    func testRunPresentationDescribesOnlyUnfinishedCurrentItems() {
        let user = WorkActivity(kind: .user, title: "You", turnID: "turn-1")
        let cases: [(WorkActivity.Kind, CodexRunPresentation, String)] = [
            (.message, .responding, "Responding…"),
            (.command, .runningCommand, "Running command…"),
            (.fileChange, .updatingFiles, "Updating files…"),
            (.plan, .working, "Working…"),
            (.status, .working, "Working…")
        ]
        for (kind, expected, title) in cases {
            let item = WorkActivity(kind: kind, title: "Activity", isComplete: false, turnID: "turn-1")
            let presentation = CodexRunPresentation.resolve(isRunning: true, requiresInput: false,
                                                             activities: [user, item])
            XCTAssertEqual(presentation, expected)
            XCTAssertEqual(presentation?.title, title)
            XCTAssertEqual(presentation?.isAnimating, true)
        }
        XCTAssertEqual(CodexRunPresentation.resolve(isRunning: true, requiresInput: false,
                                                    activities: []), .working)
    }

    func testRunPresentationDoesNotReuseUnfinishedHistoryForANewUserMessage() {
        let history = [
            WorkActivity(kind: .user, title: "Earlier request", turnID: "turn-0"),
            WorkActivity(kind: .command, title: "Earlier command", isComplete: false, turnID: "turn-0")
        ]
        let nextUser = WorkActivity(kind: .user, title: "Next request", turnID: "turn-1")
        XCTAssertEqual(CodexRunPresentation.resolve(isRunning: true, requiresInput: false,
                                                    activities: history + [nextUser]), .working)
        let nextResponse = WorkActivity(kind: .message, title: "Codex", isComplete: false, turnID: "turn-1")
        XCTAssertEqual(CodexRunPresentation.resolve(isRunning: true, requiresInput: false,
                                                    activities: history + [nextUser, nextResponse]), .responding)
    }

    func testRunPresentationKeepsPreparationAndUncertainTurnOwnershipGeneric() {
        let previous = [
            WorkActivity(kind: .user, title: "Previous request", turnID: "turn-0"),
            WorkActivity(kind: .message, title: "Previous response", isComplete: false, turnID: "turn-0")
        ]
        for turnID in [nil, "turn-1"] as [String?] {
            let preparing = WorkActivity(kind: .status, title: "Preparing Codex task",
                                          isComplete: false, turnID: turnID)
            XCTAssertEqual(CodexRunPresentation.resolve(isRunning: true, requiresInput: false,
                                                        activities: previous + [preparing]), .working)
        }
        let unmatched = WorkActivity(kind: .command, title: "New command",
                                      isComplete: false, turnID: "turn-1")
        XCTAssertEqual(CodexRunPresentation.resolve(isRunning: true, requiresInput: false,
                                                    activities: previous + [unmatched]), .working)
        let legacy = [
            WorkActivity(kind: .user, title: "Unknown turn"),
            WorkActivity(kind: .message, title: "Unknown response", isComplete: false)
        ]
        XCTAssertEqual(CodexRunPresentation.resolve(isRunning: true, requiresInput: false,
                                                    activities: legacy), .working)
    }

    func testRunPresentationDoesNotClaimResponseStreamingAfterRetryOrError() {
        let activities = [
            WorkActivity(kind: .user, title: "You", turnID: "turn-1"),
            WorkActivity(kind: .message, title: "Codex", isComplete: false, turnID: "turn-1")
        ]
        for kind in [WorkActivity.Kind.status, .error] {
            let update = WorkActivity(kind: kind, title: "Runtime update", turnID: "turn-1")
            XCTAssertEqual(CodexRunPresentation.resolve(isRunning: true, requiresInput: false,
                                                        activities: activities + [update]), .working)
        }
    }

    func testTaskDetailsCountLatestDiffSnapshotOnceAndRespectExplicitClear() throws {
        let diff = """
        diff --git a/Sources/Feature.swift b/Sources/Feature.swift
        --- a/Sources/Feature.swift
        +++ b/Sources/Feature.swift
        @@ -1,2 +1,3 @@
        -old
        +++literal
        +second
         unchanged
        diff --git a/Deleted.swift b/Deleted.swift
        --- a/Deleted.swift
        +++ /dev/null
        @@ -1 +0,0 @@
        -gone
        """
        var activities = [
            WorkActivity(kind: .fileChange, title: "Workspace diff updated", detail: diff),
            WorkActivity(kind: .fileChange, title: "Workspace diff updated", detail: diff)
        ]
        let details = CodexTaskDetailsProjection(title: "Task", workspaceURL: nil, latestDiff: diff, activities: activities)
        XCTAssertEqual(details.changes.additions, 2, "Full diff snapshots must not be accumulated")
        XCTAssertEqual(details.changes.deletions, 2)
        XCTAssertEqual(details.changes.files, ["Sources/Feature.swift", "Deleted.swift"])
        activities.append(WorkActivity(kind: .fileChange, title: "Workspace diff updated", detail: ""))
        let cleared = CodexTaskDetailsProjection(title: "Task", workspaceURL: nil, latestDiff: "", activities: activities)
        XCTAssertTrue(cleared.changes.diff.isEmpty)
        XCTAssertEqual(cleared.changes.additions, 0)
        XCTAssertTrue(cleared.changes.files.isEmpty)
    }

    func testTaskDetailsDeriveAgentIdentityAndStateOnlyFromCollaborationItems() throws {
        let activities = [
            WorkActivity(kind: .status, title: "spawnAgent", detail: "3 agents completed"),
            try taskDetailActivity(["type": "collabAgentToolCall", "id": "spawn", "senderThreadId": "parent", "tool": "spawnAgent",
                "receiverThreadIds": ["agent-one", "agent-two"], "status": "completed", "model": "fixture-model",
                "agentsStates": ["agent-one": ["status": "running"], "parent": ["status": "running"]]]),
            try taskDetailActivity(["type": "collabAgentToolCall", "id": "wait", "senderThreadId": "parent", "tool": "wait",
                "receiverThreadIds": ["agent-one"], "status": "completed",
                "agentsStates": ["agent-one": ["status": "completed", "message": "Reviewed changes"]]])
        ]
        let details = CodexTaskDetailsProjection(title: "Task", workspaceURL: nil, latestDiff: "", activities: activities)
        XCTAssertEqual(details.agents.map(\.id), ["agent-one", "agent-two"])
        XCTAssertEqual(details.agents.first?.statusLabel, "Completed")
        XCTAssertEqual(details.agents.first?.model, "fixture-model")
        XCTAssertEqual(details.agents.first?.message, "Reviewed changes")
        XCTAssertEqual(details.agents.last?.statusLabel, "Unknown", "The tool call finishing does not imply its agent completed")
        XCTAssertEqual(details.agents.filter(\.isCompleted).count, 1)
        XCTAssertFalse(details.agents.contains { $0.id == "parent" })
    }

    func testTaskDetailsSourcesPreserveUserAttachmentsAndRejectUnsafeReferences() throws {
        let activities = [try taskDetailActivity(["type": "userMessage", "id": "input", "content": [
            ["type": "localImage", "path": "/tmp/reference.png"],
            ["type": "localImage", "path": "/tmp/./reference.png"],
            ["type": "image", "url": "https://example.com/image.png"],
            ["type": "image", "fileId": "file-reference"],
            ["type": "image", "url": "javascript:alert(1)"],
            ["type": "image", "url": "file://remote.example/private.png"],
            ["type": "text", "text": "Attached file: Report.pdf (application/pdf)\nLocal path: /tmp/Long report.pdf\nInspect \"/tmp/quoted document.md\" and /tmp/Source.swift plus [notes](</tmp/my notes.txt>). /goal stays a command."],
            ["type": "mention", "path": "plugin://documents@marketplace", "name": "Documents"],
            ["type": "mention", "path": "/tmp/legacy.txt", "name": "Legacy reference"]
        ]]), try taskDetailActivity(["type": "agentMessage", "id": "output", "text": "[Not a source](/tmp/generated.txt)"])]
        let details = CodexTaskDetailsProjection(title: "Task", workspaceURL: nil, latestDiff: "", activities: activities)
        let sources = Set(details.sources.map(\.reference))
        XCTAssertEqual(sources, Set(["/tmp/reference.png", "https://example.com/image.png", "codex-image-id:file-reference",
            "/tmp/Long report.pdf", "/tmp/quoted document.md", "/tmp/Source.swift", "/tmp/my notes.txt", "/tmp/legacy.txt"]))
        XCTAssertEqual(details.sources.filter { $0.reference == "/tmp/reference.png" }.count, 1)
        XCTAssertNil(details.sources.first { $0.reference.hasPrefix("codex-image-id:") }?.url)
        XCTAssertTrue(details.sources.first { $0.reference == "https://example.com/image.png" }?.isImage == true)
        XCTAssertFalse(sources.contains("/goal"))
    }

    func testTaskDetailsThumbnailPermissionAndCacheExcludeStreamingMessages() throws {
        let item: [String: Any] = ["type": "userMessage", "id": "input", "content": [
            ["type": "text", "text": "Compare /tmp/attachment.png and /tmp/mentioned.png"],
            ["type": "localImage", "path": "/tmp/attachment.png"]
        ]]
        let raw = try JSONSerialization.data(withJSONObject: item)
        let user = WorkActivity(kind: .user, title: "You", rawJSON: String(decoding: raw, as: UTF8.self))
        let message = WorkActivity(kind: .message, title: "Codex", detail: "A streaming reply", rawJSON: "{\"type\":\"agentMessage\"}")
        let input = CodexTaskDetailsInput(title: "Task", workspaceURL: nil, latestDiff: "", activities: [user, message], allowLocalThumbnails: true)
        var updatedMessage = message
        updatedMessage.detail += " continues"
        updatedMessage.rawJSON = "{\"type\":\"agentMessage\",\"text\":\"Changed\"}"
        let streamed = CodexTaskDetailsInput(title: "Task", workspaceURL: nil, latestDiff: "", activities: [user, updatedMessage], allowLocalThumbnails: true)
        XCTAssertEqual(input, streamed, "Token deltas must not reparse unchanged attachment JSON")
        let local = input.projection.sources
        XCTAssertEqual(local.count, 2)
        XCTAssertTrue(local.first { $0.reference == "/tmp/attachment.png" }?.allowsThumbnail == true)
        XCTAssertFalse(local.first { $0.reference == "/tmp/mentioned.png" }?.allowsThumbnail == true)
        let external = CodexTaskDetailsInput(title: "Task", workspaceURL: nil, latestDiff: "", activities: [user], allowLocalThumbnails: false)
        XCTAssertTrue(external.projection.sources.allSatisfy { !$0.allowsThumbnail }, "External runtime paths must not trigger local file reads")
        XCTAssertNotEqual(input, external)
    }

    func testTaskDetailsRenderCompactSourcesAndEmptyStatesInBothAppearances() throws {
        try MarrUITestSupport.requireVisibleWindows()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Marr.TaskDetails.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let preview = NSImage(size: NSSize(width: 120, height: 80))
        preview.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 120, height: 80).fill()
        NSColor.systemBlue.setFill(); NSRect(x: 8, y: 54, width: 104, height: 18).fill()
        NSColor.lightGray.setFill(); NSRect(x: 8, y: 10, width: 80, height: 5).fill()
        preview.unlockFocus()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(preview.tiffRepresentation)))
        let imageURL = folder.appendingPathComponent("Reference screenshot.png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: imageURL)
        let activities = [
            try taskDetailActivity(["type": "userMessage", "id": "input", "content": [
                ["type": "localImage", "path": imageURL.path],
                ["type": "text", "text": "Local path: /tmp/A long requirements document with important details.pdf"],
                ["type": "image", "url": "https://example.com/Reference.png"],
                ["type": "text", "text": "Local path: /tmp/Implementation.swift"]]]),
            try taskDetailActivity(["type": "collabAgentToolCall", "id": "spawn", "senderThreadId": "parent", "tool": "spawnAgent",
                "receiverThreadIds": ["agent-one", "agent-two"], "status": "completed",
                "agentsStates": ["agent-one": ["status": "completed"], "agent-two": ["status": "running"]]])
        ]
        let details = CodexTaskDetailsProjection(title: "Improve settings and task details", workspaceURL: URL(fileURLWithPath: "/tmp/Marr"),
            latestDiff: "Sources/Settings.swift\n@@ -1 +1,2 @@\n-old\n+new\n+extra", activities: activities)
        for width: CGFloat in [256, 360] {
            for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                let content = CodexTaskDetailsContent(details: details)
                    .frame(width: width, height: 440)
                    .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme)
                try renderSnapshot(content, name: "marr-task-details-\(Int(width))-\(name)",
                    size: NSSize(width: width, height: 440), scheme: scheme, afterLayout: {})
            }
        }
        let empty = CodexTaskDetailsProjection(title: "New task", workspaceURL: nil, latestDiff: "", activities: [])
        let window = try sliderWindow(CodexTaskDetailsContent(details: empty), size: NSSize(width: 256, height: 440))
        defer { window.close() }
        let text = try renderedText(window)
        for label in ["No changes reported", "No subagents reported", "No source attachments"] {
            XCTAssertTrue(text.contains(label), text)
        }
    }

    private func taskDetailActivity(_ item: [String: Any]) throws -> WorkActivity {
        let raw = try JSONSerialization.data(withJSONObject: item, options: [.sortedKeys])
        let kind: WorkActivity.Kind
        switch item["type"] as? String {
        case "userMessage": kind = .user
        case "agentMessage": kind = .message
        case "fileChange": kind = .fileChange
        default: kind = .status
        }
        return WorkActivity(kind: kind, title: "Fixture", rawJSON: String(decoding: raw, as: UTF8.self))
    }

    func testComposerReasoningSegmentsMapAdvertisedLevelsAndRespectDisabledStateOffscreen() throws {
        let state = ComposerPickerFixtureState(efforts: ["high", "low", "medium", "low", ""], selection: "high")
        let window = offscreenPickerWindow(ComposerReasoningPickerFixture(state: state), size: NSSize(width: 260, height: 120))
        defer { window.close() }
        let control = try XCTUnwrap(accessibilityElements(in: window).compactMap { $0 as? NSSegmentedControl }.first)
        XCTAssertEqual(control.segmentCount, 3, "Duplicate and empty catalog values must not create extra levels")
        XCTAssertEqual((0..<control.segmentCount).map { control.label(forSegment: $0) }, ["Low", "Medium", "High"])
        XCTAssertEqual(control.selectedSegment, 2)

        control.selectedSegment = 1
        XCTAssertTrue(control.sendAction(try XCTUnwrap(control.action), to: control.target))
        settleSlider(window)
        XCTAssertEqual(state.selection, "medium", "The native segment must send the supported protocol value")
        XCTAssertEqual(state.selections, ["medium"])

        XCTAssertTrue(window.makeFirstResponder(control))
        try pressPickerKey(control, in: window, keyCode: 124, characters: "\u{F703}")
        try pressPickerKey(control, in: window, keyCode: 49, characters: " ")
        XCTAssertEqual(state.selection, "high", "Right Arrow and Space must choose the next advertised level")

        state.isEnabled = false
        settleSlider(window)
        XCTAssertFalse(control.isEnabled, "An active turn must disable the native reasoning control")
        XCTAssertFalse(window.isVisible)
    }

    func testComposerReasoningPreservesAutomaticAndUnavailableUntilExplicitSelectionOffscreen() throws {
        let state = ComposerPickerFixtureState(efforts: ["low", "medium", "high"], selection: nil)
        let window = offscreenPickerWindow(ComposerReasoningPickerFixture(state: state), size: NSSize(width: 260, height: 130))
        defer { window.close() }
        func segments() throws -> NSSegmentedControl {
            try XCTUnwrap(accessibilityElements(in: window).compactMap { $0 as? NSSegmentedControl }.first)
        }
        XCTAssertEqual(try segments().selectedSegment, -1)
        XCTAssertTrue(try renderedText(window).contains("Automatic"))
        XCTAssertNil(state.selection)

        state.selection = "ultra"
        settleSlider(window)
        XCTAssertEqual(try segments().selectedSegment, -1)
        XCTAssertTrue(try renderedText(window).contains("Unavailable"))
        XCTAssertEqual(state.selection, "ultra")

        state.efforts = ["none", "minimal", "low", "medium", "high", "xhigh"]
        state.selection = nil
        settleSlider(window)
        XCTAssertTrue(accessibilityElements(in: window).compactMap { $0 as? NSSlider }.isEmpty,
            "An unspecified effort must not be represented by a slider selecting its first tick")
        XCTAssertTrue(try renderedText(window).contains("Automatic"))
        XCTAssertNil(state.selection)
        XCTAssertTrue(state.selections.isEmpty, "Rendering and catalog changes must not write an effort preference")
        XCTAssertFalse(window.isVisible)
    }

    func testComposerReasoningSliderHasOneTickPerSupportedLevelOffscreen() throws {
        let state = ComposerPickerFixtureState(
            efforts: ["xhigh", "high", "medium", "low", "minimal", "none", "high"], selection: "high")
        let window = offscreenPickerWindow(ComposerReasoningPickerFixture(state: state), size: NSSize(width: 260, height: 150))
        defer { window.close() }
        let control = try XCTUnwrap(accessibilityElements(in: window).compactMap { $0 as? NSSlider }.first)
        XCTAssertEqual(control.numberOfTickMarks, 6)
        XCTAssertTrue(control.allowsTickMarkValuesOnly)
        XCTAssertEqual(control.minValue, 0)
        XCTAssertEqual(control.maxValue, 5)
        XCTAssertEqual(control.doubleValue, 4)

        control.doubleValue = 2
        XCTAssertTrue(control.sendAction(try XCTUnwrap(control.action), to: control.target))
        settleSlider(window)
        XCTAssertEqual(state.selection, "low")
        XCTAssertEqual(state.selections, ["low"])

        XCTAssertTrue(window.makeFirstResponder(control))
        try pressPickerKey(control, in: window, keyCode: 124, characters: "\u{F703}")
        XCTAssertEqual(state.selection, "medium", "Right Arrow must advance exactly one advertised tick")
        XCTAssertEqual(control.doubleValue, 3)
        try pressPickerKey(control, in: window, keyCode: 123, characters: "\u{F702}")
        XCTAssertEqual(state.selection, "low", "Left Arrow must move back exactly one advertised tick")
        XCTAssertEqual(control.doubleValue, 2)
        state.isEnabled = false
        settleSlider(window)
        XCTAssertFalse(control.isEnabled)
        XCTAssertFalse(window.isVisible)
    }

    func testModelPickerRevealsSelectedRowAfterCatalogAndSelectionChangesOffscreen() throws {
        let state = ComposerPickerFixtureState(selectedModel: "model-17")
        let window = offscreenPickerWindow(ComposerModelListFixture(state: state), size: NSSize(width: 260, height: 210))
        defer { window.close() }
        state.models = (0..<18).map { CodexModelOption(id: "model-\($0)", name: "Model \($0)") }
        for _ in 0..<3 { settleSlider(window) }
        let scroll = try XCTUnwrap(accessibilityElements(in: window).compactMap { $0 as? NSScrollView }.first)
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(document.bounds.height, scroll.contentView.bounds.height * 2)
        func distanceFromTop() -> CGFloat {
            document.isFlipped ? scroll.contentView.bounds.minY
                : document.bounds.height - scroll.contentView.bounds.maxY
        }
        let distanceFromBottom = document.isFlipped
            ? document.bounds.height - scroll.contentView.bounds.maxY : scroll.contentView.bounds.minY
        XCTAssertLessThanOrEqual(abs(distanceFromBottom), 2,
            "A catalog received after opening must reveal the complete selected final row")

        state.selectedModel = "model-0"
        for _ in 0..<3 { settleSlider(window) }
        XCTAssertLessThanOrEqual(abs(distanceFromTop()), 2, "Changing the selection must reveal the new first row")
        XCTAssertTrue(state.selections.isEmpty, "Scrolling and catalog updates must not select a model")
        XCTAssertFalse(window.isVisible)
    }

    func testComposerModelPickerRendersCompactControlsInBothAppearances() throws {
        let models = (0..<12).map { CodexModelOption(id: "model-\($0)", name: "Review model \($0)") }
        for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            let compactMenu = VStack(alignment: .leading, spacing: 8) {
                MarrModelOptionsList(models: models, selectedModel: "model-10", isEnabled: true, onSelect: { _ in })
                    .frame(height: 210)
                Divider()
                MarrReasoningPicker(efforts: ["low", "medium", "high"], selection: "high", onSelect: { _ in })
            }
            .font(MarrTypography.font(.body))
            .padding(10)
            .frame(width: 260, height: 310, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme)
            try renderSnapshot(compactMenu, name: "marr-composer-model-menu-\(name)",
                size: NSSize(width: 260, height: 310), scheme: scheme, afterLayout: {})

            let menu = VStack(alignment: .leading, spacing: 12) {
                MarrModelOptionsList(models: models, selectedModel: "model-10", isEnabled: true, onSelect: { _ in })
                    .frame(height: 210)
                Divider()
                MarrReasoningPicker(efforts: ["low", "medium", "high"], selection: "high", onSelect: { _ in })
                Divider()
                MarrReasoningPicker(efforts: ["none", "minimal", "low", "medium", "high", "xhigh"],
                    selection: "high", onSelect: { _ in })
                Divider()
                MarrReasoningPicker(efforts: ["low", "medium", "high"], selection: nil, onSelect: { _ in })
                Divider()
                MarrReasoningPicker(efforts: ["low", "medium", "high"], selection: "ultra", onSelect: { _ in })
            }
            .font(MarrTypography.font(.body))
            .padding(10)
            .frame(width: 260, height: 620, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme)
            try renderSnapshot(menu, name: "marr-composer-model-picker-260-\(name)",
                size: NSSize(width: 260, height: 620), scheme: scheme, afterLayout: {})

            let labels = VStack(alignment: .leading, spacing: 16) {
                MarrModelControlLabel(name: "Review", effort: "high").frame(width: 192, alignment: .leading)
                MarrModelControlLabel(name: "Extended reasoning model for large project reviews", effort: "high")
                    .frame(width: 192, alignment: .leading)
                MarrModelControlLabel(name: "Review", effort: "high").frame(width: 280, alignment: .leading)
                MarrModelControlLabel(name: "Extended reasoning model for large project reviews", effort: "high")
                    .frame(width: 280, alignment: .leading)
            }
            .padding(16)
            .frame(width: 312, height: 200, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme)
            try renderSnapshot(labels, name: "marr-composer-model-labels-\(name)",
                size: NSSize(width: 312, height: 200), scheme: scheme, afterLayout: {})
        }
    }

    func testReasoningSliderUsesDiscreteSupportedEffortsAndPreservesAutomatic() throws {
        try MarrUITestSupport.requireVisibleWindows()
        let state = ReasoningSliderFixtureState(selection: "")
        let root = ReasoningSliderFixture(state: state, efforts: ["high", "low", "medium", "low"])
            .padding(.horizontal, 16)
        let window = try sliderWindow(root, size: NSSize(width: 256, height: 160))
        defer { window.close() }
        // NSHostingView exposes the AppKit slider cell in this in-process test,
        // not SwiftUI's separate VoiceOver node. Exercise the real keyboard
        // control and inspect the rendered value instead of treating the cell's
        // nil AX label or false action return as the SwiftUI semantics.
        func slider() throws -> NSSlider {
            try XCTUnwrap(accessibilityElements(in: window).compactMap { $0 as? NSSlider }.first)
        }
        func press(_ code: UInt16, characters: String) throws {
            let control = try slider()
            XCTAssertTrue(window.makeFirstResponder(control))
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            control.keyDown(with: event)
            settleSlider(window)
        }
        XCTAssertTrue(try renderedText(window).contains("Automatic"))
        for (value, spokenValue) in [("low", "Low"), ("medium", "Medium"), ("high", "High")] {
            try press(124, characters: "\u{F703}")
            XCTAssertEqual(state.selection, value, "A keyboard step must select one advertised effort")
            XCTAssertTrue(try renderedText(window).contains(spokenValue), "The selected effort must remain visible")
        }
        try press(124, characters: "\u{F703}")
        XCTAssertEqual(state.selection, "high", "The slider must not move beyond the strongest supported effort")
        for value in ["medium", "low", ""] {
            try press(123, characters: "\u{F702}")
            XCTAssertEqual(state.selection, value)
        }
        XCTAssertTrue(try renderedText(window).contains("Automatic"))
    }

    func testReasoningSliderDoesNotRewriteUnavailableSavedValueOnDisplay() throws {
        try MarrUITestSupport.requireVisibleWindows()
        let state = ReasoningSliderFixtureState(selection: "ultra")
        let window = try sliderWindow(
            ReasoningSliderFixture(state: state, efforts: ["low", "medium", "high"])
                .padding(.horizontal, 16),
            size: NSSize(width: 256, height: 160)
        )
        defer { window.close() }
        XCTAssertEqual(state.selection, "ultra", "Opening Settings must preserve a stale preference until the user changes it")
        XCTAssertTrue(try renderedText(window).contains("Unavailable"))
    }

    func testReasoningSliderRendersAtNarrowSettingsWidthInBothAppearances() throws {
        for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            let root = VStack(alignment: .leading, spacing: 10) {
                Text("Translation model").font(MarrTypography.font(.body, weight: .semibold))
                CodexReasoningSlider("Translation reasoning effort", efforts: ["low", "medium", "high"],
                    includesAutomatic: true, selection: .constant("low"))
                Divider()
                CodexReasoningSlider("Translation reasoning effort", efforts: ["low", "medium", "high"],
                    includesAutomatic: true, selection: .constant(""))
                Divider()
                CodexReasoningSlider("Translation reasoning effort", efforts: ["low", "medium", "high"],
                    includesAutomatic: true, selection: .constant("ultra"))
            }
            .font(MarrTypography.font(.body))
            .padding(16)
            .frame(width: 256, height: 410, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme)
            try renderSnapshot(root, name: "marr-reasoning-slider-256-\(name)",
                size: NSSize(width: 256, height: 410), scheme: scheme)
        }
    }

    func testAutomaticReasoningKeepsTheNativeSliderAndKeyboardStepsOffscreen() throws {
        let state = ReasoningSliderFixtureState(selection: "")
        let window = offscreenPickerWindow(
            ReasoningSliderFixture(state: state, efforts: ["low", "medium", "high", "xhigh", "max"])
                .padding(.horizontal, 16), size: NSSize(width: 280, height: 150))
        defer { window.close() }
        let slider = try XCTUnwrap(accessibilityElements(in: window).compactMap { $0 as? NSSlider }.first)
        XCTAssertEqual(slider.numberOfTickMarks, 6, "Automatic is a real first tick, followed by the supported levels")
        XCTAssertTrue(slider.allowsTickMarkValuesOnly)
        XCTAssertEqual(slider.doubleValue, 0)
        XCTAssertEqual(state.selection, "", "Opening the slider must preserve Automatic")
        XCTAssertTrue(window.makeFirstResponder(slider))
        try pressPickerKey(slider, in: window, keyCode: 124, characters: "\u{F703}")
        XCTAssertEqual(state.selection, "low")
        try pressPickerKey(slider, in: window, keyCode: 123, characters: "\u{F702}")
        XCTAssertEqual(state.selection, "")
    }

    func testChatGPTSettingsAlignmentInNarrowAndWideLayoutsOffscreen() throws {
        let models = try JSONDecoder().decode([ChatGPTModel].self, from: Data(#"[{"slug":"gpt-6.1-sol","display_name":"GPT-6.1 Sol","visibility":"list"}]"#.utf8))
        let profiles = [ChatGPTProfile(id: "fixture", label: "Personal account", email: "alex@example.com", isSignedIn: true, canUsePlan: true)]
        for width: CGFloat in [300, 560] {
            for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
                let modelPanel = VStack(alignment: .leading, spacing: 24) {
                    Text("Conversation").marrTextStyle(.pageTitle)
                    MarrChatGPTModelSettings(models: models, model: .constant("gpt-6.1-sol"),
                        reasoning: .constant(""), fastMode: .constant(true))
                }
                .padding(20).frame(width: width, height: 340, alignment: .topLeading)
                .marrTextStyle(.body).background(MarrUI.Surface.content)
                .environment(\.colorScheme, scheme)
                try renderSnapshot(modelPanel, name: "marr-settings-model-\(Int(width))-\(name)",
                    size: NSSize(width: width, height: 340), scheme: scheme)

                let accountPanel = VStack(alignment: .leading, spacing: 24) {
                    Text("Account").marrTextStyle(.pageTitle)
                    MarrChatGPTAccountSettings(profiles: profiles, activeProfileID: "fixture") { _ in
                        XCTFail("Rendering must not perform account actions")
                    }
                }
                .padding(20).frame(width: width, height: 300, alignment: .topLeading)
                .marrTextStyle(.body).background(MarrUI.Surface.content)
                .environment(\.colorScheme, scheme)
                try renderSnapshot(accountPanel, name: "marr-settings-account-\(Int(width))-\(name)",
                    size: NSSize(width: width, height: 300), scheme: scheme)
            }
        }
    }

    func testUnifiedModelPanelKeepsNativeKeyboardStepsAndTracksThumbOffscreen() throws {
        let state = UnifiedModelFixtureState()
        let window = offscreenPickerWindow(UnifiedModelFixture(state: state), size: NSSize(width: 268, height: 148))
        defer { window.close() }
        let slider = try XCTUnwrap(accessibilityElements(in: window).compactMap { $0 as? NSSlider }.first)
        let cell = try XCTUnwrap(slider.cell as? NSSliderCell)
        XCTAssertTrue(type(of: slider) == NSSlider.self, "Keep the original system slider, including its glass treatment")
        XCTAssertEqual(slider.numberOfTickMarks, 6)
        XCTAssertTrue(slider.allowsTickMarkValuesOnly)
        XCTAssertTrue(window.makeFirstResponder(slider))
        let initialX = cell.knobRect(flipped: slider.isFlipped).midX
        try pressPickerKey(slider, in: window, keyCode: 124, characters: "\u{F703}")
        XCTAssertEqual(state.effort, "max")
        XCTAssertGreaterThan(cell.knobRect(flipped: slider.isFlipped).midX, initialX)
        XCTAssertTrue(slider.bounds.contains(cell.knobRect(flipped: slider.isFlipped)),
                      "The thumb must fit inside its native view: \(slider.bounds), thumb: \(cell.knobRect(flipped: slider.isFlipped))")
        try pressPickerKey(slider, in: window, keyCode: 123, characters: "\u{F702}")
        XCTAssertEqual(state.effort, "xhigh")
        state.isEnabled = false
        settleSlider(window)
        XCTAssertFalse(slider.isEnabled)
    }

    func testUnifiedModelPanelSpeedTogglePreservesReasoningAndModelDisclosure() throws {
        // SwiftUI's virtual button accessibility nodes are not published by an
        // offscreen NSHostingView. This interaction check needs a visible host.
        try MarrUITestSupport.requireVisibleWindows()
        let state = UnifiedModelFixtureState()
        let window = try sliderWindow(UnifiedModelFixture(state: state), size: NSSize(width: 268, height: 300))
        defer { window.close() }
        func press(_ label: String) throws {
            let selector = NSSelectorFromString("accessibilityPerformPress")
            let elements = accessibilityElements(in: window)
            if let button = elements.first(where: { element in
                ["accessibilityLabel", "accessibilityTitle", "accessibilityHelp"].contains {
                    accessibilityString(element, attribute: $0) == label
                } && element.responds(to: selector)
            }) {
                _ = button.perform(selector)
            } else {
                // SwiftUI buttons are virtual accessibility nodes and aren't
                // published in this in-process AppKit view tree. Click the
                // visible controls relative to the native reasoning slider.
                let slider = try XCTUnwrap(elements.compactMap { $0 as? NSSlider }.first)
                let sliderFrame = slider.convert(slider.bounds, to: window.contentView)
                let x: CGFloat = label == "Speed mode" ? window.contentView!.bounds.maxX - 24 : 100
                let point = NSPoint(x: x, y: sliderFrame.minY - 50)
                let location = window.contentView!.convert(point, to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    NSApp.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location,
                        modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
                }
            }
            settleSlider(window)
        }
        try press("Speed mode")
        XCTAssertTrue(state.fast)
        XCTAssertEqual(state.effort, "xhigh")
        try press("Speed mode")
        XCTAssertFalse(state.fast)
        XCTAssertEqual(state.effort, "xhigh")
        XCTAssertFalse(accessibilityElements(in: window).contains {
            accessibilityString($0, attribute: "accessibilityLabel") == "Reset reasoning and speed"
        })
        try press("Choose model")
        XCTAssertTrue(try renderedText(window).contains("GPT-6 Astra"))
    }

    func testModelMenuNeverCoversSendDuringItsTransition() {
        for width: CGFloat in [356, 560, 720] {
            let send = CGRect(x: width - 44, y: 526, width: 28, height: 28)
            let source = CGRect(x: send.minX - 136, y: 526, width: 128, height: 28)
            let destination = MarrComposerMorphLayout.destination(source: source,
                canvas: CGSize(width: width, height: 596), preferred: CGSize(width: 240, height: 300),
                horizontalBounds: 12...source.maxX)
            for step in 0...20 {
                let frame = MarrComposerMorphLayout.frame(source: source, destination: destination,
                    progress: CGFloat(step) / 20)
                XCTAssertLessThanOrEqual(frame.maxX, send.minX - 8)
                XCTAssertFalse(frame.intersects(send))
            }
        }
        let backdrop = MarrComposerBackdropView(frame: CGRect(x: 0, y: 0, width: 560, height: 596))
        let parent = NSView(frame: backdrop.frame)
        parent.addSubview(backdrop)
        backdrop.menuFrame = CGRect(x: 240, y: 250, width: 240, height: 300)
        backdrop.passthroughFrame = CGRect(x: 500, y: 526, width: 28, height: 28)
        XCTAssertNil(backdrop.hitTest(backdrop.convert(CGPoint(x: 514, y: 540), to: parent)), "Send clicks pass through the dismissal backdrop")
        XCTAssertNotNil(backdrop.hitTest(CGPoint(x: 100, y: 100)))
    }

    func testComposerMorphKeepsTheControlBaselineAndFitsNarrowWindows() {
        for width: CGFloat in [420, 720] {
            for source in [CGRect(x: 44, y: 526, width: 28, height: 28),
                           CGRect(x: 160, y: 526, width: 118, height: 28),
                           CGRect(x: width - 140, y: 526, width: 96, height: 28)] {
                let destination = MarrComposerMorphLayout.destination(source: source,
                    canvas: CGSize(width: width, height: 596), preferred: CGSize(width: 288, height: 370))
                XCTAssertEqual(destination.maxY, source.maxY)
                XCTAssertGreaterThanOrEqual(destination.minX, 12)
                XCTAssertLessThanOrEqual(destination.maxX, width - 12)
                XCTAssertEqual(MarrComposerMorphLayout.frame(source: source, destination: destination, progress: 0), source)
                XCTAssertEqual(MarrComposerMorphLayout.frame(source: source, destination: destination, progress: 1), destination)
                for progress: CGFloat in [0.1, 0.3, 0.6, 0.9] {
                    let frame = MarrComposerMorphLayout.frame(source: source, destination: destination, progress: progress)
                    XCTAssertEqual(frame.maxY, source.maxY, accuracy: 0.01,
                                   "Opening and closing must keep the control's toolbar baseline")
                    XCTAssertGreaterThan(frame.height, source.height)
                    XCTAssertLessThan(frame.height, destination.height)
                }
            }
        }
    }

    func testComposerMenuSearchKeepsSelectionValidAcrossFilteringAndCatalogUpdates() {
        let state = MarrComposerMenuState()
        let options: [AgentCompletionOption] = [
            .init(id: "sol", title: "GPT Sol", detail: "Fast general model", symbol: "square.stack"),
            .init(id: "blocked", title: "GPT Preview", detail: "Unavailable", symbol: "square.stack", enabled: false),
            .init(id: "astra", title: "GPT Astra", detail: "Deep reasoning", symbol: "square.stack")
        ]
        state.reconcile(options, selectedID: "sol")
        state.move(by: 1, in: options)
        XCTAssertEqual(state.highlightedID, "astra", "Arrow navigation must skip disabled results")
        state.move(by: 1, in: options)
        XCTAssertEqual(state.highlightedID, "sol")
        state.query = " GPT   reasoning "
        state.reconcile(options, selectedID: "sol")
        XCTAssertEqual(state.results(in: options).map(\.id), ["astra"])
        XCTAssertEqual(state.highlightedID, "astra", "Hidden rows cannot remain keyboard targets")
        state.query = "missing"
        state.reconcile(options, selectedID: "sol")
        state.move(by: -1, in: options)
        XCTAssertNil(state.highlightedID)
        state.reset()
        state.reconcile(options, selectedID: "astra")
        state.reconcile(Array(options.prefix(1)), selectedID: "astra")
        XCTAssertEqual(state.highlightedID, "sol", "A catalog refresh must repair a removed selection")
    }

    func testComposerMenuPinsNativeSearchAndHandlesKeysWithoutSubmittingAnEmptyResult() throws {
        let state = MarrComposerMenuState()
        let options = (0..<8).map { AgentCompletionOption(id: "model-\($0)", title: "Model \($0)", detail: "", symbol: "square.stack") }
        var selected: [String] = []
        var dismissals = 0
        let content = MarrComposerMenu(title: "Models", options: options, selectedID: "model-0",
            state: state, onSelect: { selected.append($0.id) }, onDismiss: { dismissals += 1 }) { EmptyView() }
        let window = offscreenPickerWindow(content, size: NSSize(width: 304, height: 256))
        defer { window.close() }
        let search = try XCTUnwrap(accessibilityElements(in: window).compactMap { $0 as? NSSearchField }.first)
        let originalFrame = search.convert(search.bounds, to: window.contentView)
        let delegate = try XCTUnwrap(search.delegate)
        let editor = NSTextView()
        func searchFor(_ query: String) {
            search.stringValue = query
            delegate.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: search))
            settleSlider(window)
        }
        func key(_ selector: Selector) {
            XCTAssertEqual(delegate.control?(search, textView: editor, doCommandBy: selector), true)
            settleSlider(window)
        }
        searchFor("Model 7")
        XCTAssertEqual(state.query, "Model 7")
        XCTAssertEqual(state.highlightedID, "model-7")
        XCTAssertEqual(search.convert(search.bounds, to: window.contentView), originalFrame)
        key(#selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(selected, ["model-7"])
        searchFor("no result")
        key(#selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(selected, ["model-7"], "Return in an empty menu must be consumed without sending")
        XCTAssertEqual(search.convert(search.bounds, to: window.contentView), originalFrame)
        searchFor("")
        key(#selector(NSResponder.moveDown(_:)))
        key(#selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(selected.last, "model-1")
        key(#selector(NSResponder.cancelOperation(_:)))
        XCTAssertEqual(dismissals, 1)
        editor.setMarkedText("模型", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(delegate.control?(search, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))) ?? true,
                       "Return must commit marked text before it can choose a model")
        XCTAssertFalse(window.isVisible)
    }

    func testComposerMenuFlowRendersWithBottomSearchAndGlassSliderOffscreen() throws {
        let suite = "Marr.ComposerFlowPreview.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for (name, scheme, accent, query) in [("light", ColorScheme.light, "system", ""),
                                            ("dark", .dark, "system", ""),
                                            ("filtered", .light, "green", "Astra")] {
            defaults.set(accent, forKey: MarrAccentColor.storageKey)
            let state = MarrComposerMenuState()
            state.query = query
            let controls = UnifiedModelFixtureState()
            controls.fast = accent != "system"
            for width: CGFloat in [360, 560] {
                let root = VStack(alignment: .leading, spacing: 12) {
                    ComposerFlowMenuFixture(state: state, controls: controls)
                        .frame(width: 304).marrSurface(.input, cornerRadius: MarrUI.Radius.panel)
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Ask a follow-up").marrTextStyle(.answer).foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            MarrIcon("plus", size: 18).frame(width: 28, height: 28)
                            MarrModelControlLabel(name: "GPT-6.1 Sol", effort: "xhigh", fastMode: controls.fast, isExpanded: true)
                                .frame(maxWidth: 250, alignment: .leading).layoutPriority(-1)
                            Spacer(minLength: 8)
                            MarrIcon("arrow.up", size: 14).frame(width: 28, height: 28)
                        }
                    }
                    .padding(12).marrSurface(.input, cornerRadius: MarrUI.Radius.composer)
                }
                .padding(16).frame(width: width, height: 560, alignment: .bottomLeading)
                .background(MarrUI.Surface.content).environment(\.colorScheme, scheme).defaultAppStorage(defaults)
                try renderSnapshot(root, name: "marr-composer-flow-\(Int(width))-\(name)",
                    size: NSSize(width: width, height: 560), scheme: scheme, afterLayout: {})
            }
        }
    }

    func testUnifiedModelControlsRenderInBothAppearancesOffscreen() throws {
        let suite = "Marr.ModelControlsPreview.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for (name, scheme, accent) in [("light", ColorScheme.light, "system"), ("dark", .dark, "system"),
                                       ("green", .light, "green")] {
            defaults.set(accent, forKey: MarrAccentColor.storageKey)
            let state = UnifiedModelFixtureState()
            state.fast = accent != "system"
            for width: CGFloat in [360, 560] {
            let root = VStack(alignment: .leading, spacing: 16) {
                UnifiedModelFixture(state: state)
                    .frame(width: 268).marrSurface(.input, cornerRadius: MarrUI.Radius.panel)
                VStack(alignment: .leading, spacing: 16) {
                    Text("Ask a follow-up").marrTextStyle(.body).foregroundStyle(.secondary)
                    HStack(spacing: MarrUI.Spacing.small) {
                        MarrIcon("plus", size: 16).frame(width: 28, height: 28)
                        MarrModelControlLabel(name: "GPT-6.1 Sol", effort: "xhigh", fastMode: state.fast)
                            .frame(maxWidth: 250, alignment: .leading).layoutPriority(-1)
                        Spacer(minLength: MarrUI.Spacing.regular)
                        MarrIcon("arrow.up", size: 14).frame(width: 28, height: 28)
                    }
                }
                .padding(12).marrSurface(.input, cornerRadius: MarrUI.Radius.panel)
            }
            .padding(16).frame(width: width, height: 280, alignment: .topLeading)
            .background(MarrUI.Surface.content).environment(\.colorScheme, scheme)
            .defaultAppStorage(defaults)
            try renderSnapshot(root, name: "marr-composer-icon-layout-\(Int(width))-\(name)",
                               size: NSSize(width: width, height: 280), scheme: scheme, afterLayout: {})
            }
        }
    }

    func testNewRuntimeSettingsCanBeFoundInEnglishAndChinese() throws {
        let navigation = MarrSettingsNavigation()
        let searches: [(String, MarrSettingsSection)] = [
            ("account", .account), ("账户", .account), ("archives", .archives), ("归档", .archives),
            ("sandbox", .configuration), ("权限", .configuration), ("analytics", .configuration),
            ("额度", .usage), ("reset", .usage)
        ]
        for (query, section) in searches {
            navigation.open(.general)
            navigation.query = query
            let result = try XCTUnwrap(MarrSettingsSearchResult.search(query).first { $0.section == section }, query)
            navigation.open(result)
            XCTAssertEqual(navigation.selection, section.navigationSection, query)
            XCTAssertTrue(navigation.query.isEmpty, "Selecting a result must reveal the selected page")
        }
    }

    func testAccountAndLimitsRenderAtNarrowWidthWithoutInventingMissingUsage() throws {
        try MarrUITestSupport.requireVisibleWindows()
        let suite = "Marr.CodexAccountSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var outbound: [[String: Any]] = []
        let workspace = RuntimeWorkspaceController(defaults: defaults, outboundMessage: { outbound.append($0) }, codexSyncEnabled: true)
        let fixtures: [String: [String: Any]] = ["account/read": [
                "account": ["type": "chatgpt", "email": "researcher@example.com", "planType": "pro"],
                "requiresOpenaiAuth": true
            ], "account/rateLimits/read": [
            "rateLimitsByLimitId": [
                "codex": ["limitId": "codex", "limitName": "Codex", "planType": "pro",
                    "primary": ["usedPercent": 30, "windowDurationMins": 300, "resetsAt": 1_792_300_000],
                    "secondary": NSNull(), "credits": NSNull()],
                "unavailable": ["limitId": "unavailable", "limitName": "Additional usage",
                    "primary": ["usedPercent": NSNull(), "windowDurationMins": 10080],
                    "secondary": NSNull(), "credits": NSNull()]
            ]
        ], "account/usage/read": ["summary": ["lifetimeTokens": 125_000, "peakDailyTokens": 12_000,
            "currentStreakDays": 3, "longestStreakDays": 7, "longestRunningTurnSec": NSNull()]]]
        var responded = Set<Int>()
        func replyToSettings() {
            for request in outbound {
                guard let method = request["method"] as? String, let result = fixtures[method],
                      let id = request["id"] as? Int, responded.insert(id).inserted else { continue }
                workspace.receiveServerMessage(["id": id, "result": result])
            }
        }
        workspace.refreshAccount()
        workspace.refreshRateLimits()
        replyToSettings()
        XCTAssertEqual(workspace.account?.email, "researcher@example.com")
        XCTAssertEqual(workspace.rateLimitBuckets.first { $0.id == "codex" }?.primary?.remainingPercent, 70)
        let unavailable = try XCTUnwrap(workspace.rateLimitBuckets.first { $0.id == "unavailable" })
        XCTAssertNil(unavailable.primary)
        XCTAssertNil(unavailable.secondary)
        XCTAssertNil(unavailable.creditsBalance)

        let limitsWindow = try sliderWindow(CodexAccountUsageSettings(workspace: workspace)
            .padding(16), size: NSSize(width: 256, height: 640))
        defer { limitsWindow.close() }
        replyToSettings()
        settleSlider(limitsWindow)
        let text = try renderedText(limitsWindow)
        XCTAssertTrue(text.contains("No usage window is available"), text)
        XCTAssertFalse(text.contains(" 0% remaining") || text.contains("100% remaining"), text)
        XCTAssertFalse(text.contains("Credits: 0"), text)

        for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            try renderSnapshot(CodexAccountSettings(workspace: workspace)
                .font(MarrTypography.font(.body)).padding(16)
                .frame(width: 256, height: 420, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme),
                name: "marr-account-settings-256-\(name)", size: NSSize(width: 256, height: 420), scheme: scheme,
                afterLayout: replyToSettings)
            try renderSnapshot(CodexAccountUsageSettings(workspace: workspace)
                .font(MarrTypography.font(.body)).padding(16)
                .frame(width: 256, height: 640, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme),
                name: "marr-account-limits-256-\(name)", size: NSSize(width: 256, height: 640), scheme: scheme,
                afterLayout: replyToSettings)
        }
        XCTAssertTrue(workspace.settingsLoadingMethods.isEmpty)
        XCTAssertTrue(outbound.allSatisfy { ($0["method"] as? String)?.hasSuffix("/write") != true })
    }

    func testConfigurationControlsRemainWithinNarrowAndWideSettingsPages() throws {
        try MarrUITestSupport.requireVisibleWindows()
        let suite = "Marr.CodexConfigurationSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var outbound: [[String: Any]] = []
        let workspace = RuntimeWorkspaceController(defaults: defaults, outboundMessage: { outbound.append($0) }, codexSyncEnabled: true)
        let fixtures: [String: [String: Any]] = [
            "config/read": ["config": ["web_search": "cached", "model_verbosity": "medium", "model_reasoning_summary": "auto",
                "analytics": ["enabled": true], "model_provider": "openai", "sandbox_mode": "workspace-write", "approval_policy": "on-request"],
                "layers": [["name": ["type": "user", "file": "/tmp/fixture/.codex/config.toml"], "version": "fixture-version", "config": [:]]],
                "origins": ["web_search": ["name": ["type": "user", "file": "/tmp/fixture/.codex/config.toml"], "version": "fixture-version"]]],
            "configRequirements/read": ["requirements": ["allowedWebSearchModes": ["disabled", "cached", "live"],
                "allowedSandboxModes": ["read-only", "workspace-write"], "allowBrowserAndComputerUse": false]],
            "experimentalFeature/list": ["data": [["name": "sample_feature", "displayName": "Sample runtime feature",
                "description": "Runtime-reported availability.", "stage": "beta", "enabled": true, "defaultEnabled": false]]]
        ]
        var responded = Set<Int>()
        func replyToSettings() {
            for request in outbound {
                guard let method = request["method"] as? String, let result = fixtures[method],
                      let id = request["id"] as? Int, responded.insert(id).inserted else { continue }
                workspace.receiveServerMessage(["id": id, "result": result])
            }
        }
        for width: CGFloat in [256, 560] {
            let root = CodexRuntimeConfigurationSettings(workspace: workspace)
                .font(MarrTypography.font(.body)).padding(16)
                .frame(width: width, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, .light)
            let window = try sliderWindow(root, size: NSSize(width: width, height: 1400))
            replyToSettings()
            settleSlider(window)
            XCTAssertTrue(workspace.canWriteConfiguration)
            let roles: Set<String> = [NSAccessibility.Role.button.rawValue, NSAccessibility.Role.popUpButton.rawValue]
            let controls = accessibilityElements(in: window).filter {
                roles.contains(accessibilityString($0, attribute: "accessibilityRole"))
            }
            XCTAssertFalse(controls.isEmpty)
            for control in controls where control.responds(to: NSSelectorFromString("accessibilityFrame")) {
                guard let frame = (control.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue, !frame.isEmpty else { continue }
                XCTAssertGreaterThanOrEqual(frame.minX, window.frame.minX - 1)
                XCTAssertLessThanOrEqual(frame.maxX, window.frame.maxX + 1, "The \(Int(width))-point page must keep settings controls reachable")
            }
            try renderSnapshot(root, name: "marr-runtime-configuration-\(Int(width))-light",
                size: NSSize(width: width, height: 1400), scheme: .light, afterLayout: replyToSettings)
            window.close()
        }
        XCTAssertTrue(workspace.settingsLoadingMethods.isEmpty)
        XCTAssertFalse(outbound.contains { ($0["method"] as? String)?.hasSuffix("/write") == true },
            "Viewing configuration must never mutate the runtime")
    }

    func testPendingAttachmentsTransferOnceWithoutReusingHistory() throws {
        let session = ConversationSession()
        let historicalID = session.appendScreenshot(image("earlier.png"))
        let historicalTurn = try XCTUnwrap(session.beginTurn(question: "Earlier question"))
        session.complete(historicalTurn, answer: "Earlier answer")
        let pendingID = session.appendScreenshot(image("next.png"))

        let workDraft = session.takePendingAttachments()
        XCTAssertEqual(workDraft.map(\.id), [pendingID])
        XCTAssertTrue(session.pendingImageIDs.isEmpty)
        XCTAssertTrue(session.takePendingAttachments().isEmpty)
        XCTAssertNotNil(session.images[historicalID])
        XCTAssertNil(session.images[pendingID])
        XCTAssertEqual(session.turns.first?.imageIDs, [historicalID])
        XCTAssertEqual(session.turns.first?.answer, "Earlier answer")
    }

    func testExplicitInitialWorkDraftKeepsScreenshotAndPrompt() throws {
        let session = ConversationSession(initialImage: image("capture.png"), initialQuestion: "Explain this screenshot")
        let initialTurn = try XCTUnwrap(session.turns.first)
        let draft = try XCTUnwrap(session.takeUnsubmittedInitialTurn(initialTurn.id))
        XCTAssertEqual(draft.question, "Explain this screenshot")
        XCTAssertEqual(draft.attachments.map(\.fileName), ["capture.png"])
        XCTAssertTrue(session.turns.isEmpty)
        XCTAssertTrue(session.images.isEmpty)
        XCTAssertNil(session.takeUnsubmittedInitialTurn(initialTurn.id))
    }

    func testCompletedScreenshotCannotBecomeInitialWorkDraft() throws {
        let session = ConversationSession(initialImage: image("history.png"), initialQuestion: "Existing request")
        let initialTurn = try XCTUnwrap(session.turns.first)
        session.complete(initialTurn.id, answer: "Already answered")
        XCTAssertNil(session.takeUnsubmittedInitialTurn(initialTurn.id))
        XCTAssertEqual(session.turns.count, 1)
        XCTAssertNotNil(session.images[try XCTUnwrap(initialTurn.imageIDs.first)])
    }

    func testResourceLocationsRejectExecutableSchemesAndRemoteFileHosts() {
        XCTAssertNotNil(CodexResourceAccess.url(for: "/tmp/my image.png"))
        XCTAssertNotNil(CodexResourceAccess.url(for: "https://example.com/figure.png"))
        XCTAssertNotNil(CodexResourceAccess.url(for: "http://127.0.0.1:4321/oauth"))
        XCTAssertNotNil(CodexResourceAccess.url(for: "http://[::1]:4321/oauth"))
        for source in ["javascript:alert(1)", "data:text/html,<script/>", "file://remote-host/shared/payload",
                       "codex://execute/something", "http://example.com/image.png", "relative/path.png", "https:relative"] {
            XCTAssertNil(CodexResourceAccess.url(for: source), source)
        }
        // Embedded generated images can be previewed, but must never become openable URLs.
        XCTAssertNil(CodexResourceAccess.url(for: "data:image/png;base64,AA=="))
    }

    func testResourceLinksUseExplicitPathsAndDeduplicateURLs() {
        let source = #"""
        Tool: mcp/tool. A/B and owner/repository are ordinary text.
        [Download](https://example.com/results/figure.png)
        {"path":"/tmp/figure.png","url":"https://example.com/results/figure.png"}
        [Local figure](</tmp/figure with spaces.png>)
        """#
        let links = CodexResourceAccess.links(in: source)
        XCTAssertEqual(links.count, 3)
        XCTAssertEqual(links.filter { !$0.isFileURL }.map(\.absoluteString), ["https://example.com/results/figure.png"])
        XCTAssertEqual(Set(links.filter(\.isFileURL).map(\.path)), Set(["/tmp/figure.png", "/tmp/figure with spaces.png"]))
        XCTAssertTrue(CodexResourceAccess.links(in: "Use foo/bar or /path inside a sentence, and httpsx://invalid.").isEmpty)
    }

    func testAsyncQuestionsPreserveOptionsAndIgnoreUnrelatedItems() {
        let source = #"{"type":"agentMessage","questions":[{"title":"Choose a format","options":["Markdown","PDF"]},{"title":"Any constraints?"},{"title":"  "}]}"#
        let questions = CodexAsyncQuestion.parse(source)
        XCTAssertEqual(questions.map(\.title), ["Choose a format", "Any constraints?"])
        XCTAssertEqual(questions.first?.options, ["Markdown", "PDF"])
        XCTAssertEqual(questions.last?.options, [])
        XCTAssertTrue(CodexAsyncQuestion.parse(#"{"type":"mcpToolCall","questions":[{"title":"Untrusted tool payload"}]}"#).isEmpty)
        XCTAssertTrue(CodexAsyncQuestion.parse("invalid json").isEmpty)
    }

    func testRecoveringRejectedMessagePreservesNewDraftAndDeduplicatesAttachments() {
        let first = ConversationImageAsset(image: image("first.png"))
        let second = ConversationImageAsset(image: image("second.png"))
        let restored = CodexDraftMerge.merge(currentPrompt: "New draft", currentAttachments: [first],
                                            recoveredPrompt: "Rejected message", recoveredAttachments: [first, second])
        XCTAssertEqual(restored.prompt, "New draft\n\nRejected message")
        XCTAssertEqual(restored.attachments.map(\.id), [first.id, second.id])
        let attachmentsOnly = CodexDraftMerge.merge(currentPrompt: "Keep this", currentAttachments: [],
                                                   recoveredPrompt: "", recoveredAttachments: [second])
        XCTAssertEqual(attachmentsOnly.prompt, "Keep this")
        XCTAssertEqual(attachmentsOnly.attachments.map(\.id), [second.id])
    }

    func testCapabilityErrorsOnlyAppearInTheirOwnSettingsSection() {
        let errors = [
            "app/list": "403 Forbidden", "skills/list": "Skill unavailable", "skills/config/write": "Cannot change skill",
            "plugin/install": "Plugin unavailable", "mcpServerStatus/list": "MCP unavailable",
            "config/mcpServer/reload": "Reload failed", "MCP Library": "Sign in required",
            "thread/read": "History unavailable", "interaction": "Answer required"
        ]
        XCTAssertEqual(CodexCapabilityPresentation.errors(errors, in: .skills).map(\.key), ["skills/config/write", "skills/list"])
        XCTAssertEqual(CodexCapabilityPresentation.errors(errors, in: .apps).map(\.key), ["app/list"])
        XCTAssertEqual(CodexCapabilityPresentation.errors(errors, in: .plugins).map(\.key), ["plugin/install"])
        XCTAssertEqual(Set(CodexCapabilityPresentation.errors(errors, in: .mcp).map(\.key)),
                       Set(["MCP Library", "config/mcpServer/reload", "mcpServerStatus/list"]))
    }

    func testCapabilityErrorSummaryDoesNotExposeServerPageInMainContent() {
        let forbiddenPage = "HTTP 403 Forbidden\n<!doctype html><html><body>" + String(repeating: "server diagnostic ", count: 10_000)
        let summary = CodexCapabilityPresentation.summary(forbiddenPage)
        XCTAssertTrue(summary.contains("403"))
        XCTAssertLessThan(summary.count, 150)
        XCTAssertFalse(summary.contains("<html"))
        XCTAssertFalse(summary.contains("server diagnostic"))
        XCTAssertLessThanOrEqual(CodexCapabilityPresentation.summary(String(repeating: "x", count: 10_000)).count, 260)
        XCTAssertFalse(CodexCapabilityPresentation.summary("<!doctype html><html>Error</html>").contains("<html"))
    }

    func testCapabilitySettingsDeepLinksAndSearchPreserveNavigation() throws {
        let navigation = MarrSettingsNavigation()
        for section in CodexCapabilitySection.allCases {
            navigation.query = "previous search"
            navigation.openCapabilities(section)
            XCTAssertEqual(navigation.selection, .work)
            XCTAssertEqual(navigation.capabilitySection, section)
            XCTAssertTrue(navigation.query.isEmpty)
            XCTAssertFalse(navigation.back())
            let result = try XCTUnwrap(MarrSettingsSearchResult.search(section.title).first { $0.capabilitySection == section })
            navigation.open(.general)
            navigation.query = section.title
            navigation.open(result)
            XCTAssertEqual(navigation.selection, .work)
            XCTAssertEqual(navigation.capabilitySection, section)
            XCTAssertTrue(navigation.query.isEmpty)
        }
        navigation.open(.appearance)
        XCTAssertEqual(navigation.selection, .general)
        XCTAssertEqual(navigation.capabilitySection, .mcp, "Other settings should retain the last Work capability tab")
    }

    func testCapabilitySettingsKeepSkillsVisibleWhenAppsAreForbidden() throws {
        let suite = "Marr.CodexCapabilitySettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var outbound: [[String: Any]] = []
        let workspace = RuntimeWorkspaceController(defaults: defaults, outboundMessage: { outbound.append($0) }, codexSyncEnabled: true)
        workspace.refreshSkills()
        let skillsRequest = try XCTUnwrap(outbound.last { $0["method"] as? String == "skills/list" })
        workspace.receiveServerMessage(["id": try XCTUnwrap(skillsRequest["id"]), "result": ["data": [["skills": [
            ["name": "research", "path": "/tmp/fixture/skills/research/SKILL.md", "description": "Find sources and prepare a cited research summary.", "scope": "user", "enabled": true],
            ["name": "figure", "path": "/tmp/fixture/skills/figure/SKILL.md", "description": "Create publication figures from selected data.", "scope": "project", "enabled": true],
            ["name": "legacy", "path": "/tmp/fixture/skills/legacy/SKILL.md", "description": "An optional skill currently disabled.", "scope": "user", "enabled": false]
        ], "errors": []]]]])
        workspace.refreshApps()
        let appRequest = try XCTUnwrap(outbound.last { $0["method"] as? String == "app/list" })
        let diagnostic = "HTTP 403 Forbidden\n<!doctype html><html><body>" + String(repeating: "Access denied. ", count: 20_000) + "</body></html>"
        workspace.receiveServerMessage(["id": try XCTUnwrap(appRequest["id"]), "error": ["code": 403, "message": diagnostic]])
        XCTAssertEqual(workspace.skills.map(\.name), ["research", "figure", "legacy"])
        XCTAssertTrue(CodexCapabilityPresentation.errors(workspace.capabilityErrors, in: .skills).isEmpty)
        XCTAssertEqual(CodexCapabilityPresentation.errors(workspace.capabilityErrors, in: .apps).count, 1)
        XCTAssertTrue(workspace.loadingCapabilityMethods.isEmpty)
        XCTAssertLessThanOrEqual(try XCTUnwrap(workspace.capabilityDiagnostics["app/list"]).count, 131_072)

        guard ProcessInfo.processInfo.environment["MARR_RENDER_HELPER_UI"] == "1" else { return }
        for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            let root = HStack(alignment: .top, spacing: 20) {
                ForEach([CodexCapabilitySection.skills, .apps]) { section in
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Work").font(MarrTypography.font(.title, weight: .semibold))
                        Text("Manage skills, plugins, apps, and connected tools.")
                            .font(MarrTypography.font(.secondary)).foregroundStyle(.secondary)
                        ScrollView {
                            CodexCapabilitiesView(workspace: workspace, section: .constant(section), embedded: true)
                        }
                    }
                    .padding(16)
                    .frame(width: 420, height: 610, alignment: .topLeading)
                    .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 18))
                }
            }
            .padding(20)
            .frame(width: 900, height: 650, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme)
            try renderSnapshot(root, name: "marr-capability-settings-\(name)", size: NSSize(width: 900, height: 650), scheme: scheme)
        }
    }

    func testCapabilityAndInteractionViewsRenderWithIsolatedFixtures() throws {
        // Set TEST_RUNNER_MARR_RENDER_HELPER_UI=1 when invoking xcodebuild to opt in.
        guard ProcessInfo.processInfo.environment["MARR_RENDER_HELPER_UI"] == "1" else { return }
        let suite = "Marr.CodexSupportViewsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var outbound: [[String: Any]] = []
        let workspace = RuntimeWorkspaceController(defaults: defaults, outboundMessage: { outbound.append($0) }, codexSyncEnabled: true)
        workspace.refreshCapabilities()
        for message in outbound {
            guard let id = message["id"], let method = message["method"] as? String else { continue }
            let result: [String: Any]
            switch method {
            case "skills/list":
                result = ["data": [["skills": [
                    ["name": "research", "path": "/tmp/fixture/skills/research/SKILL.md", "description": "Find sources and prepare a cited research summary.", "scope": "user", "enabled": true],
                    ["name": "figure", "path": "/tmp/fixture/skills/figure/SKILL.md", "description": "Create publication figures from the selected data.", "scope": "project", "enabled": true],
                    ["name": "legacy", "path": "/tmp/fixture/skills/legacy/SKILL.md", "description": "An optional skill currently disabled.", "scope": "user", "enabled": false]
                ], "errors": []]]]
            case "mcpServerStatus/list":
                result = ["data": [["name": "Research library", "authStatus": "oAuth", "tools": [:]]]]
            case "app/list":
                result = ["data": [["id": "fixture-app", "name": "Library", "isAccessible": true]]]
            case "plugin/installed":
                result = ["marketplaces": [], "marketplaceLoadErrors": []]
            case "collaborationMode/list":
                result = ["data": [["name": "Plan", "mode": "plan"]]]
            default: result = ["data": []]
            }
            workspace.receiveServerMessage(["id": id, "result": result])
        }
        XCTAssertEqual(workspace.skills.count, 3)
        let question = CodexInteractionRequest(id: .string("fixture-question"), method: "item/tool/requestUserInput", params: [
            "questions": [["id": "format", "header": "Output format", "question": "Which format should the report use?", "isOther": true,
                "options": [["label": "Markdown", "description": "Keep the result easy to edit."], ["label": "PDF", "description": "Prepare a document for sharing."]]]]
        ])
        let permission = CodexInteractionRequest(id: .string("fixture-permission"), method: "item/permissions/requestApproval", params: [
            "reason": "Save the generated report in the selected output directory.",
            "permissions": ["fileSystem": ["write": ["/tmp/fixture/reports"]]]
        ])
        let form = CodexInteractionRequest(id: .string("fixture-form"), method: "mcpServer/elicitation/request", params: [
            "serverName": "Research library", "mode": "form", "message": "Choose the report content.",
            "requestedSchema": ["type": "object", "required": ["sections"], "properties": [
                "sections": ["type": "array", "title": "Sections", "items": ["type": "string", "anyOf": [
                    ["const": "summary", "title": "Executive summary"], ["const": "sources", "title": "Verified sources"]
                ]]]
            ]]
        ])
        let command = CodexInteractionRequest(id: .string("fixture-command"), method: "item/commandExecution/requestApproval", params: [
            "command": "python3 render_report.py", "reason": "Render the report in the workspace.",
            "availableDecisions": ["accept", "acceptForSession"]
        ])
        for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            let root = HStack(alignment: .top, spacing: 20) {
                CodexCapabilitiesView(workspace: workspace)
                VStack(alignment: .leading, spacing: 14) {
                    Text("Work · Needs your input").font(.headline)
                    CodexInteractionCard(request: question, workspace: workspace)
                    CodexInteractionCard(request: form, workspace: workspace)
                    CodexInteractionCard(request: command, workspace: workspace)
                    CodexInteractionCard(request: permission, workspace: workspace)
                }
                .frame(width: 420)
                .padding(.top, 16)
            }
            .padding(20)
            .frame(width: 890, height: 1120, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme)
            try renderSnapshot(root, name: "marr-helper-ui-\(name)", size: NSSize(width: 890, height: 1120), scheme: scheme)
        }
    }

    private func pressPickerKey(_ control: NSControl, in window: NSWindow, keyCode: UInt16, characters: String) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
        control.keyDown(with: event)
        settleSlider(window)
    }

    private func offscreenPickerWindow<Content: View>(_ content: Content, size: NSSize) -> NSWindow {
        let hosting = NSHostingView(rootView: content
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = MarrOffscreenTestWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        for _ in 0..<3 { settleSlider(window) }
        return window
    }

    private func sliderWindow<Content: View>(_ content: Content, size: NSSize) throws -> NSWindow {
        try MarrUITestSupport.requireVisibleWindows()
        let hosting = NSHostingView(rootView: content
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        window.orderFrontRegardless()
        settleSlider(window)
        return window
    }

    private func settleSlider(_ window: NSWindow) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView?.displayIfNeeded()
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
                children.forEach(visit)
            }
            if let view = element as? NSView { view.subviews.forEach(visit) }
        }
        if let content = window.contentView { visit(content) }
        return result
    }

    private func accessibilityString(_ element: NSObject, attribute: String) -> String {
        guard element.responds(to: NSSelectorFromString(attribute)) else { return "" }
        return element.value(forKey: attribute) as? String ?? ""
    }

    private func renderedText(_ window: NSWindow) throws -> String {
        let hosting = try XCTUnwrap(window.contentView)
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: try XCTUnwrap(bitmap.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    private func renderSnapshot<Content: View>(_ content: Content, name: String, size: NSSize, scheme: ColorScheme,
                                             afterLayout: (() -> Void)? = nil) throws {
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = MarrOffscreenTestWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        if let afterLayout {
            settleSlider(window)
            afterLayout()
            settleSlider(window)
        }
        hosting.displayIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".png")
        try png.write(to: output)
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertFalse(window.isVisible)
        print("MARR_HELPER_UI_SNAPSHOT: \(output.path)")
    }

    private func image(_ name: String) -> PickedImage {
        PickedImage(data: Data([1]), mimeType: "image/png", fileName: name, image: NSImage(size: NSSize(width: 1, height: 1)))
    }
}

@MainActor
private final class ComposerPickerFixtureState: ObservableObject {
    @Published var efforts: [String]
    @Published var selection: String?
    @Published var isEnabled = true
    @Published var models: [CodexModelOption] = []
    @Published var selectedModel: String
    var selections: [String] = []

    init(efforts: [String] = [], selection: String? = nil, selectedModel: String = "") {
        self.efforts = efforts
        self.selection = selection
        self.selectedModel = selectedModel
    }
}

private struct ComposerReasoningPickerFixture: View {
    @ObservedObject var state: ComposerPickerFixtureState

    var body: some View {
        MarrReasoningPicker(efforts: state.efforts, selection: state.selection) {
            state.selections.append($0)
            state.selection = $0
        }
        .disabled(!state.isEnabled)
        .padding(10)
    }
}

private struct ComposerModelListFixture: View {
    @ObservedObject var state: ComposerPickerFixtureState

    var body: some View {
        MarrModelOptionsList(models: state.models, selectedModel: state.selectedModel, isEnabled: state.isEnabled) {
            state.selections.append($0)
            state.selectedModel = $0
        }
        .frame(height: 210)
    }
}

@MainActor
private final class ReasoningSliderFixtureState: ObservableObject {
    @Published var selection: String
    init(selection: String) { self.selection = selection }
}

private struct ReasoningSliderFixture: View {
    @ObservedObject var state: ReasoningSliderFixtureState
    let efforts: [String]

    var body: some View {
        CodexReasoningSlider("Translation reasoning effort", efforts: efforts,
            includesAutomatic: true, selection: $state.selection)
    }
}

@MainActor
private final class UnifiedModelFixtureState: ObservableObject {
    @Published var effort = "xhigh"
    @Published var fast = false
    @Published var model = "gpt-6.1-sol"
    @Published var isEnabled = true
}

private struct UnifiedModelFixture: View {
    @ObservedObject var state: UnifiedModelFixtureState
    private let efforts = ["low", "medium", "high", "xhigh", "max"]
    var body: some View {
        MarrModelConfigurationPanel(models: [
            CodexModelOption(id: "gpt-6.1-sol", name: "GPT-6.1 Sol", reasoningEfforts: efforts),
            CodexModelOption(id: "gpt-6-astra", name: "GPT-6 Astra", reasoningEfforts: efforts)
        ], selectedModel: state.model, efforts: efforts, effort: state.effort,
            fastMode: state.fast, supportsFastMode: true, isEnabled: state.isEnabled,
            onSelectModel: { state.model = $0 }, onSelectEffort: { state.effort = $0 },
            onToggleSpeed: { state.fast.toggle() })
    }
}

private struct ComposerFlowMenuFixture: View {
    @ObservedObject var state: MarrComposerMenuState
    @ObservedObject var controls: UnifiedModelFixtureState
    let models = [CodexModelOption(id: "gpt-6.1-sol", name: "GPT-6.1 Sol"),
                  CodexModelOption(id: "gpt-6-astra", name: "GPT-6 Astra"),
                  CodexModelOption(id: "gpt-6-sol", name: "GPT-6 Sol"),
                  CodexModelOption(id: "gpt-6-luna", name: "GPT-6 Luna")]
    var body: some View {
        MarrComposerMenu(title: "Models", options: models.map {
            AgentCompletionOption(id: $0.id, title: $0.name, detail: "", symbol: "square.stack")
        }, selectedID: controls.model, state: state,
            onSelect: { controls.model = $0.id }, onDismiss: {}) {
            Divider().padding(.horizontal, 12)
            MarrModelConfigurationPanel(models: models, selectedModel: controls.model,
                efforts: ["low", "medium", "high", "xhigh", "max"], effort: controls.effort,
                fastMode: controls.fast, supportsFastMode: true, offersModelSelection: false,
                onSelectModel: { controls.model = $0 }, onSelectEffort: { controls.effort = $0 },
                onToggleSpeed: { controls.fast.toggle() })
        }
    }
}
