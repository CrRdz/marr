import Foundation
import MarrCore

/// Pure transcript decoding shared by socket ingestion and UI history loading.
enum RuntimeHistoryProjection {
    static func isDurableSnapshotTurnEnd(_ turn: [String: Any]) -> Bool {
        let status = turn["status"] as? String
        return status == "completed" || status == "failed"
            || (status == "interrupted" && turn["completedAt"] is NSNumber)
    }

    static func prepareHistory(_ thread: [String: Any]) -> CodexPreparedHistory {
        var activities: [WorkActivity] = []
        var answer = ""
        var diff = ""
        let runtimeStatus = (thread["status"] as? [String: Any])?["type"] as? String
        for turn in thread["turns"] as? [[String: Any]] ?? [] {
            let duration = Self.turnDurationSeconds(turn)
            let status = turn["status"] as? String
            for item in turn["items"] as? [[String: Any]] ?? [] {
                let activity = Self.makeActivity(item, complete: Self.historyItemIsComplete(item, turnStatus: status),
                    processingSeconds: duration, turnID: turn["id"] as? String, fallbackAnswer: answer)
                activities.append(activity)
                if activity.kind == .message, !activity.isProcessMessage { answer = activity.detail }
                if activity.kind == .fileChange, !activity.detail.isEmpty { diff = activity.detail }
            }
            if let status, status == "failed" || (status == "interrupted"
                && (runtimeStatus != "notLoaded" || RuntimeHistoryProjection.isDurableSnapshotTurnEnd(turn))) {
                let error = turn["error"] as? [String: Any]
                activities.append(WorkActivity(kind: .error, title: "Codex task \(status)",
                    detail: error?["message"] as? String ?? "", processingSeconds: duration, turnID: turn["id"] as? String))
            }
        }
        return CodexPreparedHistory(threadID: thread["id"] as? String ?? "", activities: activities,
            answer: answer, diff: diff, preparedOffMain: !Thread.isMainThread)
    }

    static func historyItemIsComplete(_ item: [String: Any], turnStatus: String?) -> Bool {
        let terminal = ["completed", "failed", "declined", "interrupted", "cancelled", "canceled"]
        // A completed tool can precede an unfinished turn. Conversely an
        // explicit active/unknown item must not inherit a successful turn state.
        if let status = item["status"] as? String { return terminal.contains(status) }
        if item["exitCode"] is Int || item["success"] is Bool { return true }
        return terminal.contains(turnStatus ?? "")
    }

    static func makeActivity(
        _ item: [String: Any],
        complete: Bool,
        processingSeconds: Int? = nil,
        turnID: String? = nil,
        id: UUID = UUID(),
        fallbackAnswer: String? = nil
    ) -> WorkActivity {
        let serverItemID = item["id"] as? String
        let type = item["type"] as? String ?? "activity"
        var activity: WorkActivity
        switch type {
        case "userMessage":
            // Keep the received text intact. Display projection handles attachments
            // and runtime context; protocol blocks must never become prose or JSON.
            let text = (item["content"] as? [[String: Any]] ?? []).compactMap { block -> String? in
                guard ["text", "inputText", "input_text"].contains(block["type"] as? String ?? "") else { return nil }
                return block["text"] as? String
            }.joined(separator: "\n\n")
            activity = WorkActivity(id: id, kind: .user, title: "You", detail: text, isComplete: complete, processingSeconds: processingSeconds, turnID: turnID)
        case "commandExecution":
            let command = item["command"] as? String ?? "Running command"
            let output = item["aggregatedOutput"] as? String ?? ""
            activity = WorkActivity(id: id, kind: .command, title: command, detail: output, isComplete: complete, processingSeconds: processingSeconds, turnID: turnID)
        case "fileChange":
            let changes = (item["changes"] as? [[String: Any]] ?? []).compactMap { change -> String? in
                let path = change["path"] as? String
                let diff = change["diff"] as? String
                return [path, diff].compactMap { $0 }.joined(separator: "\n")
            }.joined(separator: "\n\n")
            activity = WorkActivity(id: id, kind: .fileChange, title: "File changes", detail: changes, isComplete: complete, processingSeconds: processingSeconds, turnID: turnID)
        case "agentMessage":
            let text = item["text"] as? String ?? fallbackAnswer ?? ""
            activity = WorkActivity(id: id, kind: .message, title: "Codex", detail: text, isComplete: complete, processingSeconds: processingSeconds, turnID: turnID)
        case "reasoning":
            let summary = (item["summary"] as? [String])?.joined(separator: "\n\n")
                ?? (item["summary"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
                ?? ""
            activity = WorkActivity(id: id, kind: .message, title: "Thinking", detail: summary,
                isComplete: complete, processingSeconds: processingSeconds, turnID: turnID)
        case "plan":
            activity = WorkActivity(id: id, kind: .plan, title: "Plan", detail: item["text"] as? String ?? "", isComplete: complete, processingSeconds: processingSeconds, turnID: turnID)
        default:
            let title = item["tool"] as? String ?? item["name"] as? String ?? type
            activity = WorkActivity(id: id, kind: .status, title: title, detail: Self.itemPreview(item),
                                     isComplete: complete, processingSeconds: processingSeconds, turnID: turnID)
        }
        activity.serverItemID = serverItemID
        activity.rawJSON = CodexProtocolJSON.pretty(item)
        activity.messagePhase = type == "reasoning" ? "reasoning"
            : (type == "agentMessage" ? item["phase"] as? String ?? "legacy" : nil)
        return activity
    }

    static func itemPreview(_ item: [String: Any]) -> String {
        func summarize(_ value: Any) -> Any {
            if let string = value as? String {
                if string.hasPrefix("data:") || string.count > 16_000 { return "[Content omitted from preview: \(string.count) characters]" }
                return string
            }
            if let array = value as? [Any] { return array.map(summarize) }
            if let object = value as? [String: Any] {
                return object.mapValues { value in summarize(value) }
            }
            return value
        }
        return CodexProtocolJSON.pretty(summarize(item))
    }

    static func turnDurationSeconds(_ turn: [String: Any]) -> Int? {
        if let durationMs = (turn["durationMs"] as? NSNumber)?.doubleValue {
            return max(0, Int((durationMs / 1_000).rounded()))
        }
        guard let startedAt = (turn["startedAt"] as? NSNumber)?.doubleValue,
              let completedAt = (turn["completedAt"] as? NSNumber)?.doubleValue
        else { return nil }
        return max(0, Int((completedAt - startedAt).rounded()))
    }

}
