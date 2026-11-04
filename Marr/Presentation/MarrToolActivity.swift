import Foundation
import SwiftUI

/// Presentation derives from protocol facts. A closed item without a result is
/// "Finished", never an invented successful execution.
struct MarrToolActivityPresentation: Equatable {
    enum State: Equatable, CaseIterable {
        case needsInput, running, unknown, succeeded, finished, failed, cancelled

        var title: String {
            switch self {
            case .needsInput: "Needs your input"
            case .running: "Running"
            case .unknown: "Status unknown"
            case .succeeded: "Succeeded"
            case .finished: "Finished"
            case .failed: "Failed"
            case .cancelled: "Cancelled"
            }
        }

        var status: MarrUI.Status {
            switch self {
            case .needsInput: .needsInput
            case .running: .running
            case .succeeded: .success
            case .failed: .error
            case .finished, .cancelled, .unknown: .idle
            }
        }

        var symbolName: String {
            switch self {
            case .unknown: "questionmark.circle"
            case .finished: "minus.circle"
            case .cancelled: "stop.circle"
            default: status.symbolName
            }
        }
    }

    let title: String
    let source: String?
    let target: String?
    let parameters: String?
    let state: State
    let durationMilliseconds: Double?

    init(activity: WorkActivity, awaitingInput: Bool = false, statusUncertain: Bool = false) {
        let json = CodexProtocolJSON.object(activity.rawJSON)
        title = (json["tool"] as? String) ?? (json["name"] as? String) ?? activity.title
        source = (json["server"] as? String) ?? (json["serverName"] as? String)
            ?? (json["namespace"] as? String)
            ?? (activity.kind == .command ? "Command" : nil)
        let paths = (json["changes"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
        target = (json["cwd"] as? String) ?? (json["path"] as? String)
            ?? (paths.isEmpty ? nil : paths.prefix(3).joined(separator: ", "))
        parameters = (json["arguments"] ?? json["input"] ?? json["inputParams"]).map { CodexProtocolJSON.pretty($0) }
        let milliseconds = (json["durationMs"] as? NSNumber)?.doubleValue
        durationMilliseconds = milliseconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let status = (json["status"] as? String ?? "").lowercased()
        let result = json["result"] as? [String: Any]
        let hasError = (json["error"] != nil && !(json["error"] is NSNull))
            || (result?["isError"] as? Bool == true)
            || (json["success"] as? Bool == false)
        let exitCode = (json["exitCode"] as? NSNumber)?.intValue
        if awaitingInput { state = .needsInput }
        else if ["interrupted", "cancelled", "canceled", "declined"].contains(status) { state = .cancelled }
        else if activity.kind == .error || hasError || ["failed", "error", "errored"].contains(status)
                    || (exitCode != nil && exitCode != 0) { state = .failed }
        else if exitCode == 0 || (json["success"] as? Bool == true)
                    || ["completed", "success", "succeeded"].contains(status) { state = .succeeded }
        else if !activity.isComplete { state = statusUncertain ? .unknown : .running }
        else { state = .finished }
    }

    static func matchingRequest(for activity: WorkActivity, in requests: [CodexInteractionRequest],
                                threadID: String?) -> CodexInteractionRequest? {
        guard let item = activity.serverItemID, !item.isEmpty,
              let turn = activity.turnID, !turn.isEmpty,
              let threadID, !threadID.isEmpty else { return nil }
        return requests.first {
            $0.threadID == threadID && $0.turnID == turn && $0.params["itemId"] as? String == item
        }
    }


}

/// A request stays in the subtree where it first appeared. Moving it to a later
/// steering message would recreate its form and discard the user's answers.
struct MarrInteractionPlacement {
    private var knownIDs: Set<CodexRequestID> = []
    private var groupIDs: [CodexRequestID: UUID] = [:]
    private var threadID: String?

    func groupID(for requestID: CodexRequestID) -> UUID? { groupIDs[requestID] }

    mutating func update(requests: [CodexInteractionRequest],
                         groups: [(id: UUID, activities: [WorkActivity])], threadID: String?) {
        if self.threadID != threadID { knownIDs = []; groupIDs = [:]; self.threadID = threadID }
        let currentIDs = Set(requests.map(\.id))
        groupIDs = groupIDs.filter { currentIDs.contains($0.key) }
        for request in requests where !knownIDs.contains(request.id) {
            guard let threadID, request.threadID == threadID,
                  let turn = request.turnID, let item = request.params["itemId"] as? String, !item.isEmpty else { continue }
            let matches = groups.filter { group in
                group.activities.contains { $0.turnID == turn && $0.serverItemID == item }
            }
            if matches.count == 1 { groupIDs[request.id] = matches[0].id }
        }
        knownIDs = currentIDs
    }
}

@MainActor
final class MarrToolPresentationCache {
    private var activity: WorkActivity?
    private var awaitingInput = false
    private var statusUncertain = false
    private var value: MarrToolActivityPresentation?

    func presentation(for activity: WorkActivity, awaitingInput: Bool, statusUncertain: Bool) -> MarrToolActivityPresentation {
        if self.activity == activity, self.awaitingInput == awaitingInput,
           self.statusUncertain == statusUncertain, let value { return value }
        let value = MarrToolActivityPresentation(activity: activity, awaitingInput: awaitingInput, statusUncertain: statusUncertain)
        self.activity = activity
        self.awaitingInput = awaitingInput
        self.statusUncertain = statusUncertain
        self.value = value
        return value
    }
}

struct MarrToolActivityCard: View {
    let activity: WorkActivity
    var awaitingInput = false
    var statusUncertain = false
    @State private var isExpanded = false
    @State private var showsParameters = false
    @State private var showsRawEvent = false
    @State private var presentationCache = MarrToolPresentationCache()
    @Environment(\.colorScheme) private var colorScheme

    private var presentation: MarrToolActivityPresentation {
        presentationCache.presentation(for: activity, awaitingInput: awaitingInput, statusUncertain: statusUncertain)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
                if let source = presentation.source, activity.kind != .command {
                    Text(source).marrTextStyle(.caption).foregroundStyle(.secondary)
                }
                if let target = presentation.target {
                    Text(target).marrTextStyle(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if activity.kind == .command {
                    detail(presentation.title)
                }
                if let parameters = presentation.parameters {
                    DisclosureGroup("Parameters", isExpanded: $showsParameters) { detail(parameters) }
                }
                if !activity.detail.isEmpty { detail(activity.detail) }
                CodexResourceLinksView(source: activity.detail)
                ForEach(CodexArtifact.extract(from: activity.rawJSON ?? "")) { artifact in
                    CodexArtifactView(artifact: artifact)
                }
                if let raw = activity.rawJSON {
                    DisclosureGroup("Event details", isExpanded: $showsRawEvent) { detail(raw) }
                }
            }
            .padding(.top, MarrUI.Spacing.regular)
            .disclosureGroupStyle(.automatic)
        } label: {
            HStack(spacing: MarrUI.Spacing.medium) {
                Text(activity.kind == .command ? "Command" : presentation.title)
                    .marrTextStyle(.secondary, weight: .medium)
                    .foregroundStyle(MarrPanelColors.primary(for: colorScheme))
                    .lineLimit(1)
                    .help(presentation.title)
                Spacer(minLength: 0)
                HStack(spacing: MarrUI.Spacing.tight) {
                    MarrIcon(presentation.state.symbolName, size: MarrUI.Icon.status)
                        .foregroundStyle(presentation.state.status.color())
                        .accessibilityHidden(true)
                    Text(presentation.state.title)
                        .marrTextStyle(.caption)
                        .foregroundStyle(MarrPanelColors.secondary(for: colorScheme))
                }
                .fixedSize()
                if let milliseconds = presentation.durationMilliseconds {
                    Text(String(format: "%.1f s", milliseconds / 1000))
                        .marrTextStyle(.caption).monospacedDigit()
                        .foregroundStyle(MarrPanelColors.secondary(for: colorScheme))
                        .fixedSize()
                }
            }
        }
        .disclosureGroupStyle(MarrToolDisclosureStyle())
        .marrSurface(.card, cornerRadius: MarrUI.Radius.control, border: .subtle)
    }

    private func detail(_ value: String) -> some View {
        VStack(alignment: .leading, spacing: MarrUI.Spacing.tight) {
            HStack {
                Spacer()
                MarrCopyButton(text: value, accessibilityName: "Copy complete tool details")
            }
            ScrollView([.horizontal, .vertical]) {
                Text(String(value.prefix(32_768))).font(MarrTypography.font(.code))
                    .textSelection(.enabled).fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxHeight: 240)
            if value.count > 32_768 {
                Text("Preview limited to 32,768 characters. Copy includes the complete text.")
                    .marrTextStyle(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// One compact summary row; the whole header remains a keyboard-accessible
/// disclosure. Diagnostics are only constructed when the user expands it.
private struct MarrToolDisclosureStyle: DisclosureGroupStyle {
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MarrHoverRegion { isHovered in
                Button {
                    withAnimation(MarrMotion.disclosure(reducesMotion: reducesMotion)) {
                        configuration.isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: MarrUI.Spacing.medium) {
                        configuration.label
                        MarrIcon("chevron.right", size: MarrUI.Icon.disclosure)
                            .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, MarrUI.Spacing.medium)
                    .frame(minHeight: MarrUI.Control.spacious)
                    .background(.primary.opacity(isHovered ? 0.04 : 0),
                                in: RoundedRectangle(cornerRadius: MarrUI.Radius.control))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
                .accessibilityHint("Show or hide tool details")
            }
            if configuration.isExpanded {
                Divider().padding(.horizontal, MarrUI.Spacing.medium)
                configuration.content
                    .padding(.horizontal, MarrUI.Spacing.medium)
                    .padding(.bottom, MarrUI.Spacing.medium)
            }
        }
    }
}

/// Failures remain visible, while full diagnostics require an explicit action.
/// Do not infer a recovery action from arbitrary server error text.
struct MarrAgentErrorCard: View {
    let activity: WorkActivity
    @State private var showsDetails = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
            Label(activity.title, marrSymbol: "exclamationmark.triangle")
                .marrTextStyle(.secondary, weight: .semibold)
                .foregroundStyle(MarrPanelColors.error(for: colorScheme))
            if !activity.detail.isEmpty {
                if !showsDetails {
                    Text(String(activity.detail.prefix(240)))
                        .marrTextStyle(.secondary).foregroundStyle(.secondary).lineLimit(2)
                }
                DisclosureGroup("Details", isExpanded: $showsDetails) {
                    VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
                        Text(String(activity.detail.prefix(32_768)))
                            .marrTextStyle(.secondary).textSelection(.enabled)
                        MarrCopyButton(text: activity.detail, accessibilityName: "Copy error details")
                    }
                }
                .marrTextStyle(.secondary)
            }
        }
        .padding(MarrUI.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MarrPanelColors.error(for: colorScheme).opacity(0.07),
                    in: RoundedRectangle(cornerRadius: MarrUI.Radius.card))
    }
}

/// A bounded preview avoids laying out an entire historical reasoning payload
/// just to show a few lines. The original remains available on explicit expand.
struct MarrThoughtPreview: Equatable {
    let text: String
    let isTruncated: Bool

    init(_ source: String) {
        let end = source.index(source.startIndex, offsetBy: 800, limitedBy: source.endIndex) ?? source.endIndex
        let prefix = String(source[..<end])
        let lines = prefix.components(separatedBy: "\n")
        text = lines.prefix(10).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        isTruncated = end != source.endIndex || lines.count > 10
    }
}

struct MarrThoughtText: View {
    let source: String
    @State private var isExpanded: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    init(source: String, initiallyExpanded: Bool = false) {
        self.source = source
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        let preview = MarrThoughtPreview(source)
        let limited = preview.isTruncated && !isExpanded
        VStack(alignment: .leading, spacing: 4) {
            MarkdownResponseView(source: limited ? preview.text : source, compact: true)
                .equatable()
                .foregroundStyle(MarrPanelColors.secondary(for: colorScheme))
                .textSelection(.enabled)
                .frame(maxHeight: limited ? 160 : nil, alignment: .topLeading)
                .clipped()
                .mask(alignment: .bottom) {
                    if limited {
                        VStack(spacing: 0) {
                            Rectangle()
                            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                                .frame(height: 28)
                        }
                    } else { Rectangle() }
                }
            if preview.isTruncated {
                Button(isExpanded ? "Show less" : "Show more") {
                    withAnimation(MarrMotion.disclosure(reducesMotion: reducesMotion)) { isExpanded.toggle() }
                }
                .buttonStyle(.plain)
                .marrTextStyle(.secondary)
                .foregroundStyle(MarrPanelColors.secondary(for: colorScheme))
                .frame(minHeight: 24, alignment: .leading)
                .accessibilityLabel(isExpanded ? "Show less thought process" : "Show full thought process")
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The rail follows intrinsic row height without measuring the scroll view or
/// attaching a nested scroller. The content, including tools, keeps its identity.
struct MarrProcessTimelineRow<Content: View>: View {
    let symbol: String
    var connectsToNext = true
    var symbolTopInset: CGFloat = 0
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            MarrIcon(symbol, size: 13)
                .foregroundStyle(MarrPanelColors.secondary(for: colorScheme))
                .frame(width: 16, height: 20)
                .padding(.top, symbolTopInset)
                .accessibilityHidden(true)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.bottom, connectsToNext ? 16 : 0)
        .overlay(alignment: .topLeading) {
            if connectsToNext {
                Rectangle().fill(MarrPanelColors.secondary(for: colorScheme).opacity(0.24))
                    .frame(width: 1).padding(.top, 24 + symbolTopInset).padding(.leading, 7.5)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }
}

struct MarrProcessEnding: Equatable {
    let title: String
    let symbol: String

    init(activities: [WorkActivity], active: Bool, needsInput: Bool, uncertain: Bool, hasAnswer: Bool) {
        if needsInput { title = "Needs your input"; symbol = "questionmark.circle" }
        else if uncertain { title = "Checking status"; symbol = "clock" }
        else if active { title = "Working"; symbol = "clock" }
        else if activities.contains(where: { ["Codex task interrupted", "Codex task cancelled"].contains($0.title) }) {
            title = "Interrupted"; symbol = "pause.circle"
        } else if activities.contains(where: { $0.kind == .error }) {
            title = "Stopped with an error"; symbol = "exclamationmark.circle"
        } else if hasAnswer || activities.contains(where: { $0.title == "Codex task completed" }) {
            title = "Done"; symbol = "checkmark.circle"
        } else { title = "Finished"; symbol = "clock" }
    }
}
