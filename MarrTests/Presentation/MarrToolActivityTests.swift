import MarrText
import XCTest
import AppKit
import SwiftUI
@testable import Marr

final class MarrToolActivityTests: XCTestCase {
    @MainActor
    func testToolStateAtlasRendersAllStatesAtCompactAndReadingWidths() throws {
        let samples: [(MarrToolActivityPresentation.State, String, WorkActivity)] = [
            (.needsInput, "等待输入 · 需要你的审批或补充信息", .init(kind: .command, title: "swift test", isComplete: false)),
            (.running, "运行中 · 正在执行", .init(kind: .command, title: "swift test", isComplete: false)),
            (.unknown, "状态未知 · 暂时无法确认执行状态", .init(kind: .command, title: "swift test", isComplete: false)),
            (.succeeded, "成功 · 已确认执行成功", .init(kind: .command, title: "swift test", rawJSON: #"{"exitCode":0,"durationMs":3600}"#)),
            (.finished, "已结束 · 未提供明确成功或失败结果", .init(kind: .command, title: "swift test")),
            (.failed, "失败 · 返回错误或非零退出码", .init(kind: .command, title: "swift test", rawJSON: #"{"exitCode":1,"durationMs":1200}"#)),
            (.cancelled, "已取消 · 执行被取消、中断或拒绝", .init(kind: .command, title: "swift test", rawJSON: #"{"status":"cancelled"}"#))
        ]
        XCTAssertEqual(samples.map { $0.0 }, MarrToolActivityPresentation.State.allCases)
        for sample in samples {
            XCTAssertEqual(MarrToolActivityPresentation(activity: sample.2,
                awaitingInput: sample.0 == .needsInput, statusUncertain: sample.0 == .unknown).state, sample.0)
        }
        for scheme in [ColorScheme.light, .dark] {
            for width in [CGFloat(360), CGFloat(720)] {
                let root = VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("命令活动 · 7 种状态").marrTextStyle(.brand)
                        Text("真实组件预览 / \(scheme == .dark ? "深色" : "浅色")")
                            .marrTextStyle(.secondary).foregroundStyle(.secondary)
                    }
                    ForEach(Array(samples.indices), id: \.self) { (index: Int) in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(String(format: "%02d", index + 1) + "  " + samples[index].1)
                                .marrTextStyle(.caption).foregroundStyle(.secondary)
                            MarrProcessTimelineRow(symbol: "terminal", connectsToNext: false, symbolTopInset: 8) {
                                MarrToolActivityCard(activity: samples[index].2,
                                    awaitingInput: samples[index].0 == .needsInput,
                                    statusUncertain: samples[index].0 == .unknown)
                            }
                        }
                    }
                    Text("展开 / 收起是交互形态，不计入执行状态。")
                        .marrTextStyle(.caption).foregroundStyle(.secondary)
                }
                .padding(24)
                .frame(width: width, alignment: .topLeading)
                .foregroundStyle(MarrPanelColors.primary(for: scheme))
                .background(MarrUI.Surface.canvas)
                .environment(\.colorScheme, scheme)
                let host = NSHostingView(rootView: root)
                let size = host.fittingSize
                XCTAssertEqual(size.width, width, accuracy: 1)
                XCTAssertLessThan(size.height, 760, "Collapsed statuses must remain compact")
                let frame = NSRect(origin: .zero, size: size)
                host.frame = frame
                let window = MarrOffscreenTestWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                window.contentView = host
                defer { window.contentView = nil; window.close() }
                for _ in 0..<5 {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                    host.layoutSubtreeIfNeeded()
                    host.needsDisplay = true
                    window.displayIfNeeded()
                    host.displayIfNeeded()
                    CATransaction.flush()
                }
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.effectiveAppearance.performAsCurrentDrawingAppearance {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                }
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("marr-tool-states")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appendingPathComponent("states-\(Int(width))-\(scheme == .dark ? "dark" : "light").png")
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
                print("Tool state preview: \(url.path)")
                let attachment = XCTAttachment(contentsOfFile: url)
                attachment.lifetime = .keepAlways
                add(attachment)
                XCTAssertFalse(window.isVisible)
                XCTAssertFalse(window.isKeyWindow)
            }
        }
    }

    @MainActor
    func testCommentaryAndThinkingStayInChronologicalTraceWithoutReplacingAnswer() throws {
        let thread: [String: Any] = ["id": "thread", "turns": [["id": "turn", "status": "completed", "items": [
            ["id": "user", "type": "userMessage", "content": [["type": "text", "text": "Review this"]]],
            ["id": "progress", "type": "agentMessage", "phase": "commentary", "text": "Checking files"],
            ["id": "tool", "type": "commandExecution", "command": "swift test", "exitCode": 0],
            ["id": "thought", "type": "reasoning", "summary": ["Compare the results."]],
            ["id": "final", "type": "agentMessage", "phase": "final_answer", "text": "Everything passed."],
            ["id": "late", "type": "agentMessage", "phase": "commentary", "text": "Background cleanup"]
        ]]]]
        let prepared = RuntimeHistoryProjection.prepareHistory(thread)
        XCTAssertEqual(prepared.answer, "Everything passed.")
        let group = try XCTUnwrap(MarrWorkTimelineCache().groups(activities: prepared.activities, revision: 1).first)
        XCTAssertEqual(group.finalMessage?.serverItemID, "final")
        XCTAssertEqual(group.trace.compactMap(\.serverItemID), ["progress", "tool", "thought", "late"])
        XCTAssertEqual(group.trace.first { $0.serverItemID == "thought" }?.detail, "Compare the results.")
        XCTAssertTrue(group.prominentActivities(requests: [], threadID: "thread").isEmpty)
        XCTAssertEqual(group.processTitle(isActive: false, requiresInput: false), "Thinking & activity")
        let restored = try JSONDecoder().decode([WorkActivity].self, from: JSONEncoder().encode(prepared.activities))
        XCTAssertEqual(restored, prepared.activities, "Phase survives cache persistence")
    }

    @MainActor
    func testToolFailuresStayInProcessUnlessTheyHaveAPendingUserDecision() {
        let user = WorkActivity(kind: .user, title: "You", detail: "Go")
        let running = WorkActivity(kind: .command, title: "Build", isComplete: false)
        let failed = WorkActivity(kind: .command, title: "/bin/zsh -lc 'rg missing'", detail: "No matches",
            turnID: "turn", serverItemID: "tool", rawJSON: #"{"exitCode":1}"#)
        let commentary = WorkActivity(kind: .message, title: "Codex", detail: "Checking",
            rawJSON: #"{"type":"agentMessage","phase":"commentary"}"#)
        let group = MarrWorkTurnGroup(id: user.id, userMessage: user, activities: [user, commentary, running, failed])
        XCTAssertNil(group.finalMessage)
        XCTAssertTrue(group.prominentActivities(requests: [], threadID: "thread").isEmpty)
        XCTAssertEqual(group.trace.last, failed, "Full command and error remain available inside the process")
        XCTAssertEqual(group.toolState(for: failed), .failed, "Folding must not relabel a failed tool as successful")
        let approval = CodexInteractionRequest(id: .integer(1), method: "item/commandExecution/requestApproval",
            params: ["threadId": "thread", "turnId": "turn", "itemId": "tool"])
        XCTAssertEqual(group.prominentActivities(requests: [approval], threadID: "thread").map(\.id), [failed.id])
        XCTAssertTrue(group.prominentActivities(requests: [approval], threadID: "other-thread").isEmpty)
        let terminal = WorkActivity(kind: .error, title: "Task failed", detail: "Unable to continue")
        let failedTurn = MarrWorkTurnGroup(id: user.id, userMessage: user, activities: [user, failed, terminal])
        XCTAssertFalse(failedTurn.trace.contains(terminal), "Task errors remain outside the process disclosure")
        XCTAssertEqual(group.processTitle(isActive: true, requiresInput: false), "Running a command…")
        XCTAssertEqual(group.processTitle(isActive: true, requiresInput: true), "Needs your input")
        let legacy = WorkActivity(kind: .message, title: "Codex", detail: "Existing saved answer")
        let older = MarrWorkTurnGroup(id: user.id, userMessage: user, activities: [user, legacy])
        XCTAssertEqual(older.finalMessage?.id, legacy.id)
    }

    @MainActor
    func testScrollProjectionReusesUnchangedTurnsAndInvalidatesChangedToolResults() {
        let first = WorkActivity(kind: .user, title: "You", detail: "First")
        let tool = WorkActivity(kind: .command, title: "Build", isComplete: false,
            rawJSON: #"{"status":"inProgress","aggregatedOutput":"output"}"#)
        let second = WorkActivity(kind: .user, title: "You", detail: "Second")
        var answer = WorkActivity(kind: .message, title: "Codex", detail: "Streaming", isComplete: false)
        let cache = MarrWorkTimelineCache()
        let activities = [first, tool, second, answer]
        let initial = cache.groups(activities: activities, revision: 1)
        for _ in 0..<100 {
            let groups = cache.groups(activities: activities, revision: 1)
            XCTAssertTrue(groups[0] === initial[0])
            XCTAssertEqual(groups[0].toolState(for: tool), .running)
        }
        XCTAssertEqual(cache.rebuildCount, 1)
        XCTAssertEqual(initial[0].toolParseCount, 1)
        answer.detail = "Final answer"
        answer.isComplete = true
        let updated = cache.groups(activities: [first, tool, second, answer], revision: 2)
        XCTAssertTrue(updated[0] === initial[0])
        XCTAssertFalse(updated[1] === initial[1])
        XCTAssertEqual(updated[1].finalMessage?.detail, "Final answer")
        var failed = tool
        failed.rawJSON = #"{"status":"completed","exitCode":1}"#
        failed.isComplete = true
        let terminal = cache.groups(activities: [first, failed, second, answer], revision: 3)
        XCTAssertEqual(terminal[0].toolState(for: failed), .failed)
        XCTAssertTrue(terminal[1] === updated[1])
        XCTAssertTrue(cache.groups(activities: [], revision: 4).isEmpty)
    }

    @MainActor
    func testMarkdownParsingIsReusedDuringLayoutAndInvalidatedByStreamingText() {
        let cache = MarrMarkdownRenderCache()
        let source = "## Result\n\nA **bold** answer.\n\n```swift\nlet x = 1\n```"
        for _ in 0..<100 {
            XCTAssertEqual(cache.blocks(for: source), MarkdownBlockParser.parse(source))
            XCTAssertEqual(String(cache.inline("A **bold** answer.").characters), "A bold answer.")
        }
        XCTAssertEqual(cache.blockParseCount, 1)
        XCTAssertEqual(cache.inlineParseCount, 1)
        XCTAssertEqual(cache.blocks(for: "New answer"), [.paragraph("New answer")])
        XCTAssertEqual(cache.blockParseCount, 2)
        _ = cache.inline("New answer")
        XCTAssertEqual(cache.inlineParseCount, 2)
    }

    @MainActor
    func testToolPresentationCacheRespondsToApprovalAndUncertaintyWithoutStaleState() {
        let cache = MarrToolPresentationCache()
        var activity = WorkActivity(kind: .command, title: "Build", isComplete: false)
        XCTAssertEqual(cache.presentation(for: activity, awaitingInput: false, statusUncertain: false).state, .running)
        XCTAssertEqual(cache.presentation(for: activity, awaitingInput: true, statusUncertain: false).state, .needsInput)
        XCTAssertEqual(cache.presentation(for: activity, awaitingInput: false, statusUncertain: true).state, .unknown)
        activity.rawJSON = #"{"exitCode":0}"#
        XCTAssertEqual(cache.presentation(for: activity, awaitingInput: false, statusUncertain: true).state, .succeeded)
    }

    func testUncertainTransportDoesNotInventContinuedExecutionOrEraseConfirmedResults() {
        let unfinished = WorkActivity(kind: .command, title: "Build", isComplete: false)
        XCTAssertEqual(MarrToolActivityPresentation(activity: unfinished, statusUncertain: true).state, .unknown)
        let confirmed = WorkActivity(kind: .command, title: "Build", isComplete: false,
                                      rawJSON: #"{"status":"completed","exitCode":0}"#)
        XCTAssertEqual(MarrToolActivityPresentation(activity: confirmed, statusUncertain: true).state, .succeeded)
    }

    func testRequestPlacementNeverMovesFormsToLaterSteeringGroupsOrLateItems() {
        let first = UUID(), second = UUID()
        let activity = WorkActivity(kind: .command, title: "Build", turnID: "turn", serverItemID: "item")
        let request = CodexInteractionRequest(id: .integer(1), method: "item/commandExecution/requestApproval",
            params: ["threadId": "thread", "turnId": "turn", "itemId": "item"])
        var placement = MarrInteractionPlacement()
        placement.update(requests: [request], groups: [(first, [activity])], threadID: "thread")
        XCTAssertEqual(placement.groupID(for: request.id), first)
        placement.update(requests: [request], groups: [(first, [activity]), (second, [activity])], threadID: "thread")
        XCTAssertEqual(placement.groupID(for: request.id), first, "A later steering group cannot reset a pending form")

        placement.update(requests: [], groups: [], threadID: "thread")
        placement.update(requests: [request], groups: [], threadID: "thread")
        placement.update(requests: [request], groups: [(first, [activity])], threadID: "thread")
        XCTAssertNil(placement.groupID(for: request.id), "An initially independent request remains in the fixed area")
        placement.update(requests: [request], groups: [(first, [activity])], threadID: "another-thread")
        XCTAssertNil(placement.groupID(for: request.id))
    }

    func testTerminalItemsDoNotInventSuccessAndExplicitResultsWin() {
        func state(_ raw: String?, complete: Bool = true, awaiting: Bool = false) -> MarrToolActivityPresentation.State {
            MarrToolActivityPresentation(activity: WorkActivity(kind: .command, title: "Build",
                isComplete: complete, rawJSON: raw), awaitingInput: awaiting).state
        }
        XCTAssertEqual(state(nil), .finished)
        XCTAssertEqual(state(nil, complete: false), .running)
        XCTAssertEqual(state(#"{"status":"completed","exitCode":1}"#), .failed)
        XCTAssertEqual(state(#"{"status":"completed","result":{"isError":true}}"#), .failed)
        XCTAssertEqual(state(#"{"type":"dynamicToolCall","status":"completed","success":false}"#), .failed)
        XCTAssertEqual(state(#"{"type":"dynamicToolCall","success":true}"#), .succeeded)
        XCTAssertEqual(state(#"{"type":"dynamicToolCall","success":true}"#, complete: false), .succeeded)
        XCTAssertEqual(state(#"{"status":"completed","exitCode":0}"#, complete: false), .succeeded)
        XCTAssertEqual(state(#"{"status":"completed","error":null,"exitCode":0}"#), .succeeded)
        XCTAssertEqual(state(#"{"status":"interrupted"}"#), .cancelled)
        XCTAssertEqual(state(nil, complete: false, awaiting: true), .needsInput)
    }

    func testApprovalCorrelationRequiresThreadTurnAndItemIdentity() {
        let item = WorkActivity(kind: .command, title: "Same title", turnID: "turn", serverItemID: "item")
        func request(thread: String = "thread", turn: String = "turn", item: String = "item") -> CodexInteractionRequest {
            CodexInteractionRequest(id: .integer(1), method: "item/commandExecution/requestApproval",
                params: ["threadId": thread, "turnId": turn, "itemId": item])
        }
        XCTAssertNotNil(MarrToolActivityPresentation.matchingRequest(for: item, in: [request()], threadID: "thread"))
        for other in [request(thread: "other"), request(turn: "other"), request(item: "other")] {
            XCTAssertNil(MarrToolActivityPresentation.matchingRequest(for: item, in: [other], threadID: "thread"))
        }
        XCTAssertNil(MarrToolActivityPresentation.matchingRequest(for: item, in: [request()], threadID: nil))
        let anonymous = WorkActivity(kind: .command, title: "Same title")
        XCTAssertNil(MarrToolActivityPresentation.matchingRequest(for: anonymous, in: [request()], threadID: "thread"))
    }

    func testToolMetadataUsesActualItemDurationNotTurnDuration() {
        let activity = WorkActivity(kind: .status, title: "tool", processingSeconds: 600,
            rawJSON: #"{"tool":"lookup","server":"Docs","arguments":{"query":"hello"},"durationMs":1250}"#)
        let display = MarrToolActivityPresentation(activity: activity)
        XCTAssertEqual(display.title, "lookup")
        XCTAssertEqual(display.source, "Docs")
        XCTAssertEqual(display.durationMilliseconds, 1250)
        XCTAssertTrue(display.parameters?.contains("hello") == true)
        XCTAssertNil(MarrToolActivityPresentation(activity: WorkActivity(kind: .status, title: "tool", processingSeconds: 600)).durationMilliseconds)
    }
}
