import AppKit
import Combine
import MarrCore
import QuartzCore
import SwiftUI

/// Immutable turn inputs retain their derived presentation while a reader
/// scrolls. New streaming events only invalidate the turn that actually changed.
#if DEBUG
@MainActor
enum MarrWorkRenderDiagnostics {
    static var timelineEvaluations = 0
    static var toolParses = 0
}
#endif

@MainActor
final class MarrWorkTurnGroup: Identifiable {
    let id: UUID
    let userMessage: WorkActivity
    let activities: [WorkActivity]
    lazy var finalMessage = activities.last {
        $0.kind == .message && !$0.isProcessMessage && !$0.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    lazy var trace = activities.filter { $0.id != finalMessage?.id && $0.kind != .user && $0.kind != .error && $0.title != "Codex task completed" }
    lazy var userPresentation = UserMessagePresentation(userMessage.detail, rawJSON: userMessage.rawJSON)
    lazy var questionMessages = activities.filter { $0.kind == .message && !CodexAsyncQuestion.parse($0.rawJSON ?? "").isEmpty }
    /// An individual tool failure is execution history, not a failed request.
    /// Only a pending user decision promotes its tool out of the folded trace.
    func prominentActivities(requests: [CodexInteractionRequest], threadID: String?) -> [WorkActivity] {
        guard !requests.isEmpty else { return [] }
        return trace.filter {
            MarrToolActivityPresentation.matchingRequest(for: $0, in: requests, threadID: threadID) != nil
        }
    }

    func processTitle(isActive: Bool, requiresInput: Bool) -> String {
        if requiresInput { return "Needs your input" }
        if isActive {
            if finalMessage?.isComplete == false { return "Writing a reply…" }
            switch trace.last(where: { !$0.isComplete })?.kind {
            case .command: return "Running a command…"
            case .fileChange: return "Updating files…"
            case .message: return "Thinking…"
            default: return "Working…"
            }
        }
        return "Thinking & activity"
    }
    private var toolStates: [UUID: MarrToolActivityPresentation.State] = [:]
    private(set) var toolParseCount = 0

    init(id: UUID, userMessage: WorkActivity, activities: [WorkActivity]) {
        self.id = id; self.userMessage = userMessage; self.activities = activities
    }

    func toolState(for activity: WorkActivity) -> MarrToolActivityPresentation.State {
        if let value = toolStates[activity.id] { return value }
        let value = MarrToolActivityPresentation(activity: activity).state
        toolParseCount += 1
        #if DEBUG
        MarrWorkRenderDiagnostics.toolParses += 1
        #endif
        toolStates[activity.id] = value
        return value
    }
}

@MainActor
final class MarrWorkTimelineCache {
    private var cachedRevision: UInt64?
    private var cachedGroups: [MarrWorkTurnGroup] = []
    private var userPresentations: [UUID: (WorkActivity, UserMessagePresentation)] = [:]
    private(set) var rebuildCount = 0
    func groups(activities: [WorkActivity], revision: UInt64) -> [MarrWorkTurnGroup] {
        guard revision != cachedRevision else { return cachedGroups }
        cachedRevision = revision
        rebuildCount += 1
        var groups: [MarrWorkTurnGroup] = []
        var pendingActivities: [WorkActivity] = []
        var currentUserMessage: WorkActivity?
        var currentActivities: [WorkActivity] = []

        for activity in activities {
            if activity.kind == .user {
                let presentation: UserMessagePresentation
                if let cached = userPresentations[activity.id], cached.0 == activity {
                    presentation = cached.1
                } else {
                    presentation = UserMessagePresentation(activity.detail, rawJSON: activity.rawJSON)
                    userPresentations[activity.id] = (activity, presentation)
                }
                guard presentation.isVisible else { continue }
                if let currentUserMessage {
                    groups.append(MarrWorkTurnGroup(
                        id: currentUserMessage.id,
                        userMessage: currentUserMessage,
                        activities: currentActivities
                    ))
                }
                currentUserMessage = activity
                currentActivities = pendingActivities + [activity]
                pendingActivities = []
            } else if currentUserMessage != nil {
                currentActivities.append(activity)
            } else {
                pendingActivities.append(activity)
            }
        }

        if let currentUserMessage {
            groups.append(MarrWorkTurnGroup(
                id: currentUserMessage.id,
                userMessage: currentUserMessage,
                activities: currentActivities
            ))
        }
        let previous = Dictionary(uniqueKeysWithValues: cachedGroups.map { ($0.id, $0) })
        let userIDs = Set(activities.filter { $0.kind == .user }.map(\.id))
        userPresentations = userPresentations.filter { userIDs.contains($0.key) }
        cachedGroups = groups.map { group in
            if let presentation = userPresentations[group.userMessage.id]?.1 { group.userPresentation = presentation }
            if let old = previous[group.id], old.userMessage == group.userMessage,
               old.activities == group.activities { return old }
            return group
        }
        return cachedGroups
    }

}

struct WorkActivityTimeline: View {
    @ObservedObject var workspace: RuntimeWorkspaceController
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var expandedTurnIDs: Set<UUID> = []
    @State private var reviewedFileChangeTurnIDs: Set<UUID> = []
    @State private var revertedFileChangeTurnIDs: Set<UUID> = []
    @State private var showsResumeSavedHistory = false
    @State private var resumeSavedTaskID: UUID?
    @State private var interactionPlacement = MarrInteractionPlacement()
    @AppStorage(MarrAccentColor.storageKey) private var accentColor = MarrAccentColor.system.rawValue

    private typealias TurnGroup = MarrWorkTurnGroup
    @State private var timelineCache = MarrWorkTimelineCache()
    @State private var fileSummaryCache = FileSummaryCache()
    private final class FileSummaryCache {
        var values: [UUID: (group: TurnGroup, files: [FileChangeSummary])] = [:]
    }

    private struct FileChangeSummary: Identifiable {
        let path: String
        let additions: Int
        let deletions: Int

        var id: String { path }
    }

    var body: some View {
        #if DEBUG
        let _ = { MarrWorkRenderDiagnostics.timelineEvaluations += 1 }()
        #endif
        VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
            if turnGroups.isEmpty, let presentation = runPresentation {
                HStack(spacing: MarrUI.Spacing.regular) {
                    if presentation.isAnimating {
                        MarrCompanion(phase: .responding, size: 28)
                    } else {
                        MarrIcon("bubble.left.and.text.bubble.right")
                            .frame(width: 14, height: 14)
                            .accessibilityHidden(true)
                    }
                    Text(presentation.title)
                        .font(MarrTypography.font(.secondary, weight: .medium))
                        .contentTransition(.opacity)
                        .animation(MarrMotion.transition(reducesMotion: reducesMotion), value: presentation)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(MarrPanelColors.secondary(for: colorScheme))
                .padding(.vertical, 4)
                .transition(.opacity)
            }
            if workspace.isResumingSavedHistory {
                Text("Loading saved conversation…").marrTextStyle(.secondary)
                    .foregroundStyle(MarrPanelColors.secondary(for: colorScheme))
            } else if workspace.isReconcilingConnection {
                Text("Checking task status…").marrTextStyle(.secondary)
                    .foregroundStyle(MarrPanelColors.secondary(for: colorScheme))
            } else if workspace.isTaskStatusUncertain {
                VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
                    Text("Task status is unavailable.")
                        .marrTextStyle(.secondary)
                        .foregroundStyle(MarrPanelColors.secondary(for: colorScheme))
                    HStack(spacing: MarrUI.Spacing.regular) {
                        Button("Refresh status") { workspace.refreshSelectedTask() }
                            .disabled(workspace.isReadingSelectedTask)
                        if workspace.canResumeSavedHistory {
                            Button("Resume in Marr…") {
                                resumeSavedTaskID = workspace.workbench.selectedTaskID
                                showsResumeSavedHistory = true
                            }
                        }
                    }
                    .controlSize(.small)
                    if let error = workspace.capabilityErrors["thread/resume"] {
                        Text(verbatim: error).marrTextStyle(.secondary)
                            .foregroundStyle(MarrPanelColors.error(for: colorScheme))
                    }
                }
                .alert("Resume this saved conversation?", isPresented: $showsResumeSavedHistory) {
                    Button("Cancel", role: .cancel) { resumeSavedTaskID = nil }
                    Button("Resume in Marr") {
                        guard resumeSavedTaskID == workspace.workbench.selectedTaskID,
                              workspace.canResumeSavedHistory else { return }
                        workspace.resumeSavedHistory()
                        resumeSavedTaskID = nil
                    }
                } message: {
                    Text("Make sure this conversation has stopped in the other client. Marr will load it here without sending a new message.")
                }
            } else if workspace.isRemoteTaskActive {
                Text("Running in Codex").font(MarrTypography.font(.secondary)).foregroundStyle(MarrPanelColors.secondary(for: colorScheme))
            }
            if let error = workspace.capabilityErrors["thread/read"] {
                HStack(spacing: MarrUI.Spacing.regular) {
                    Text(error).marrTextStyle(.secondary).foregroundStyle(.secondary).lineLimit(2).help(error)
                    Spacer(minLength: 0)
                    Button("Retry") { workspace.refreshSelectedTask() }
                        .disabled(workspace.isReadingSelectedTask)
                }
            }
            if !unassignedInteractions.isEmpty {
                ScrollView {
                    VStack(spacing: MarrUI.Spacing.regular) {
                        ForEach(unassignedInteractions) { request in
                            CodexInteractionCard(request: request, workspace: workspace)
                        }
                    }
                }
                .frame(maxHeight: 300)
            }

            if turnGroups.isEmpty, !workspace.isRunning, !workspace.isRemoteTaskActive,
               workspace.pendingInteractions.isEmpty, workspace.approvalRequest == nil, unassignedErrors.isEmpty {
                VStack(spacing: MarrUI.Spacing.medium) {
                    MarrIcon("square.and.pencil", size: MarrUI.Icon.hero)
                        .foregroundStyle(MarrPanelColors.secondary(for: colorScheme))
                        .accessibilityHidden(true)
                    Text("What would you like to work on?")
                        .font(MarrTypography.font(.pageTitle, weight: .medium))
                        .foregroundStyle(MarrPanelColors.primary(for: colorScheme))
                    Text(workspace.workspaceURL == nil
                         ? "Ask a question, attach a file, or choose a project."
                         : "Ask a question or describe a task in \(workspace.workspaceDisplayName).")
                        .font(MarrTypography.font(.body))
                        .foregroundStyle(MarrPanelColors.secondary(for: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.center)
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MarrFollowingScrollView(identity: workspace.workbench.selectedTaskID?.uuidString ?? "new",
                    onLiveScrollChange: { workspace.setHistorySyncUserScrolling($0) }) {
                    LazyVStack(alignment: .leading, spacing: MarrUI.Spacing.section) {
                        ForEach(turnGroups) { turn in
                            let prominent = prominentActivities(in: turn)
                            VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
                                userMessageBubble(turn.userPresentation)
                                ForEach(prominent) { activity in
                                    activityRow(activity)
                                    if let request = matchingInteraction(for: activity, in: turn) {
                                        CodexInteractionCard(request: request, workspace: workspace).id(request.id)
                                    }
                                }
                                ForEach(standaloneInteractions(for: turn)) { request in
                                    CodexInteractionCard(request: request, workspace: workspace)
                                        .id(request.id)
                                }
                                processingDisclosure(for: turn)

                                if expandedTurnIDs.contains(turn.id) {
                                    let isLatest = turn.id == turnGroups.last?.id
                                    let ending = MarrProcessEnding(activities: turn.activities,
                                        active: isLatest && (workspace.isRunning || workspace.isRemoteTaskActive),
                                        needsInput: !interactions(for: turn).isEmpty,
                                        uncertain: isLatest && workspace.isTaskStatusUncertain,
                                        hasAnswer: finalAgentMessage(in: turn)?.isComplete == true)
                                    LazyVStack(alignment: .leading, spacing: 0) {
                                        ForEach(traceActivities(in: turn).filter { activity in
                                            !prominent.contains { $0.id == activity.id }
                                        }) { activity in
                                            MarrProcessTimelineRow(symbol: activity.kind == .message || activity.isProcessMessage
                                                ? "clock" : activity.kind.symbolName,
                                                symbolTopInset: activity.kind == .message || activity.isProcessMessage ? 0 : 8) {
                                                if activity.kind == .message || activity.isProcessMessage {
                                                    MarrThoughtText(source: activity.detail)
                                                } else {
                                                    activityRow(activity)
                                                }
                                            }
                                        }
                                        MarrProcessTimelineRow(symbol: ending.symbol, connectsToNext: false) {
                                            Text(ending.title).marrTextStyle(.body)
                                                .foregroundStyle(MarrPanelColors.secondary(for: colorScheme))
                                        }
                                    }
                                    .padding(.leading, 2)
                                    .transition(.opacity)
                                }

                                if let finalMessage = finalAgentMessage(in: turn) {
                                    agentMessage(finalMessage)
                                        .transition(.opacity)
                                }
                                fileChangeReviewCard(for: turn)

                                ForEach(errorActivities(in: turn)) { activity in
                                    errorCard(activity)
                                }
                                ForEach(turn.questionMessages) { message in
                                    CodexAsyncQuestionsView(source: message.rawJSON ?? "", workspace: workspace)
                                        .id(message.id)
                                }
                            }
                            .transition(.opacity)
                            // Animate a newly arriving message once. Its stable
                            // item ID keeps subsequent text deltas unanimated.
                            .animation(MarrMotion.transition(reducesMotion: reducesMotion),
                                       value: finalAgentMessage(in: turn)?.id)
                        }

                        ForEach(unassignedErrors) { activity in
                            errorCard(activity)
                        }
                    }
                    .frame(maxWidth: MarrTypography.Reading.columnWidth, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .animation(workspace.isRunning ? MarrMotion.transition(reducesMotion: reducesMotion) : nil, value: turnGroups.map(\.id))
                }
                .scrollIndicators(.automatic)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.marrHistoryThreadID, workspace.workbench.selectedTask?.threadID)
        .onChange(of: workspace.pendingInteractions.map(\.id), initial: true) { _, _ in
            updateInteractionPlacement()
        }
        .onChange(of: workspace.workbench.selectedTask?.threadID) { _, _ in
            expandedTurnIDs.removeAll()
            reviewedFileChangeTurnIDs.removeAll()
            revertedFileChangeTurnIDs.removeAll()
            fileSummaryCache.values.removeAll()
            updateInteractionPlacement()
        }
    }

    private func updateInteractionPlacement() {
        interactionPlacement.update(requests: workspace.pendingInteractions,
            groups: turnGroups.map { ($0.id, [$0.userMessage] + $0.activities) },
            threadID: workspace.workbench.selectedTask?.threadID)
    }

    private func interactions(for turn: TurnGroup) -> [CodexInteractionRequest] {
        workspace.pendingInteractions.filter { request in
            interactionPlacement.groupID(for: request.id) == turn.id
        }
    }

    private var unassignedInteractions: [CodexInteractionRequest] {
        let assigned = Set(turnGroups.flatMap { interactions(for: $0) }.map(\.id))
        return workspace.pendingInteractions.filter { !assigned.contains($0.id) }
    }

    private func matchingInteraction(for activity: WorkActivity, in turn: TurnGroup) -> CodexInteractionRequest? {
        MarrToolActivityPresentation.matchingRequest(for: activity, in: interactions(for: turn),
                                                     threadID: workspace.workbench.selectedTask?.threadID)
    }

    private func prominentActivities(in turn: TurnGroup) -> [WorkActivity] {
        turn.prominentActivities(requests: interactions(for: turn), threadID: workspace.workbench.selectedTask?.threadID)
    }

    private func standaloneInteractions(for turn: TurnGroup) -> [CodexInteractionRequest] {
        let attached = Set(prominentActivities(in: turn).compactMap { matchingInteraction(for: $0, in: turn)?.id })
        return interactions(for: turn).filter { !attached.contains($0.id) }
    }

    private var runPresentation: CodexRunPresentation? {
        CodexRunPresentation.resolve(
            isRunning: workspace.isRunning,
            requiresInput: !workspace.pendingInteractions.isEmpty || workspace.approvalRequest != nil,
            activities: workspace.activities
        )
    }

    private var turnGroups: [TurnGroup] {
        timelineCache.groups(activities: workspace.activities, revision: workspace.activitiesRevision)
    }

    /// Respect runtime phases. Legacy unlabelled messages retain last-message
    /// compatibility; explicit commentary never flashes as a final answer.
    private func finalAgentMessage(in turn: TurnGroup) -> WorkActivity? {
        turn.finalMessage
    }

    private func traceActivities(in turn: TurnGroup) -> [WorkActivity] {
        turn.trace
    }

    private func fileChanges(in turn: TurnGroup) -> [FileChangeSummary] {
        if let cached = fileSummaryCache.values[turn.id], cached.group === turn { return cached.files }
        // Keep only the active transcript's groups; released chats must not
        // accumulate raw tool payloads in a presentation cache.
        let currentIDs = Set(turnGroups.map(\.id))
        fileSummaryCache.values = fileSummaryCache.values.filter { currentIDs.contains($0.key) }
        let activities = traceActivities(in: turn).filter { $0.kind == .fileChange }
        guard !activities.isEmpty else { return [] }

        // A diff-updated event contains the complete latest diff, so prefer it over
        // individual file-change events to avoid counting the same edit twice.
        let sources = activities.last(where: { $0.title == "Workspace diff updated" }).map { [$0] } ?? activities
        var totals: [String: (additions: Int, deletions: Int)] = [:]

        for activity in sources {
            var currentPath: String?
            for rawLine in activity.detail.components(separatedBy: .newlines) {
                if rawLine.hasPrefix("diff --git ") {
                    let fragments = rawLine.split(separator: " ")
                    if fragments.count >= 4 {
                        currentPath = String(fragments[3]).replacingOccurrences(of: "b/", with: "", options: [.anchored])
                    }
                    continue
                }
                if rawLine.hasPrefix("+++ b/") {
                    currentPath = String(rawLine.dropFirst(6))
                    continue
                }
                if currentPath == nil,
                   !rawLine.hasPrefix("+") && !rawLine.hasPrefix("-"),
                   (rawLine.contains("/") || rawLine.contains(".")),
                   !rawLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    currentPath = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard let currentPath else { continue }
                let previous = totals[currentPath, default: (0, 0)]
                if rawLine.hasPrefix("+") && !rawLine.hasPrefix("+++") {
                    totals[currentPath] = (previous.additions + 1, previous.deletions)
                } else if rawLine.hasPrefix("-") && !rawLine.hasPrefix("---") {
                    totals[currentPath] = (previous.additions, previous.deletions + 1)
                } else if totals[currentPath] == nil {
                    totals[currentPath] = previous
                }
            }
        }

        let files = totals
            .map { FileChangeSummary(path: $0.key, additions: $0.value.additions, deletions: $0.value.deletions) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        fileSummaryCache.values[turn.id] = (turn, files)
        return files
    }

    private func reversibleDiff(in turn: TurnGroup) -> String? {
        traceActivities(in: turn)
            .last(where: { $0.kind == .fileChange && $0.detail.contains("diff --git ") })?
            .detail
    }

    private func errorActivities(in turn: TurnGroup) -> [WorkActivity] {
        turn.activities.filter { $0.kind == .error }
    }

    private var unassignedErrors: [WorkActivity] {
        let assignedErrorIDs = Set(turnGroups.flatMap { errorActivities(in: $0).map(\.id) })
        return workspace.activities.filter { $0.kind == .error && !assignedErrorIDs.contains($0.id) }
    }

    private func userMessageBubble(_ presentation: UserMessagePresentation) -> some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: MarrUI.Spacing.tight) {
                UserMessageContent(presentation: presentation)
                    .marrTextStyle(.answer)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(selectedAccent.color.opacity(0.15), in: RoundedRectangle(cornerRadius: MarrUI.Radius.card, style: .continuous))
                if !presentation.copyText.isEmpty {
                    MarrMessageActions(text: presentation.copyText, copyTitle: "Copy message")
                }
            }
        }
    }

    @ViewBuilder
    private func processingDisclosure(for turn: TurnGroup) -> some View {
        let trace = traceActivities(in: turn)
        let duration = turn.activities.compactMap(\.processingSeconds).last
        let isActive = turn.id == turnGroups.last?.id && (workspace.isRunning || workspace.isRemoteTaskActive)
        if !trace.isEmpty || isActive {
            let title = isActive || !interactions(for: turn).isEmpty
                ? turn.processTitle(isActive: isActive, requiresInput: !interactions(for: turn).isEmpty)
                : "Thought process"
            if trace.isEmpty {
                HStack(spacing: MarrUI.Spacing.regular) {
                    if isActive {
                        MarrCompanion(phase: .responding, size: 28)
                    }
                    Text(title).font(MarrTypography.font(.secondary, weight: .medium))
                }
                .foregroundStyle(MarrPanelColors.secondary(for: colorScheme))
                .frame(minHeight: 32)
            } else {
                Button {
                    withAnimation(MarrMotion.disclosure(reducesMotion: reducesMotion)) {
                        if expandedTurnIDs.contains(turn.id) {
                            expandedTurnIDs.remove(turn.id)
                        } else {
                            expandedTurnIDs.insert(turn.id)
                        }
                    }
                } label: {
                    HStack(spacing: MarrUI.Spacing.regular) {
                        if isActive, interactions(for: turn).isEmpty {
                            MarrCompanion(phase: .responding, size: 28)
                        }
                        Text(title)
                            .font(MarrTypography.font(.secondary, weight: .medium))
                        if let duration, !isActive {
                            Text(formattedDuration(duration)).marrTextStyle(.caption).monospacedDigit()
                        }
                        Spacer(minLength: 0)
                        MarrIcon("chevron.right", size: MarrUI.Icon.disclosure)
                            .rotationEffect(.degrees(expandedTurnIDs.contains(turn.id) ? 90 : 0))
                    }
                    .foregroundStyle(MarrPanelColors.secondary(for: colorScheme))
                    .frame(minHeight: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
                .accessibilityValue(expandedTurnIDs.contains(turn.id) ? "Expanded" : "Collapsed")
                .help("Show or hide thinking and activity")
            }
        }
    }

    private func agentMessage(_ message: WorkActivity) -> some View {
        VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
            MarkdownResponseView(source: message.detail)
                .equatable()
                .textSelection(.enabled)
                .padding(.horizontal, 2)
            if message.isComplete {
                MarrMessageActions(text: message.detail)
                    .padding(.leading, 2)
            }
        }
    }

    @ViewBuilder
    private func fileChangeReviewCard(for turn: TurnGroup) -> some View {
        let files = fileChanges(in: turn)
        if !files.isEmpty {
            let isReviewed = reviewedFileChangeTurnIDs.contains(turn.id)
            let isReverted = revertedFileChangeTurnIDs.contains(turn.id)
            let additions = files.reduce(0) { $0 + $1.additions }
            let deletions = files.reduce(0) { $0 + $1.deletions }
            let reversibleDiff = reversibleDiff(in: turn)
            VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
                HStack(spacing: MarrUI.Spacing.medium) {
                    MarrIcon("doc.badge.plus", size: MarrUI.Icon.toolbar)
                        .foregroundStyle(MarrPanelColors.secondary(for: colorScheme))
                        .frame(width: 46, height: 46)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    VStack(alignment: .leading, spacing: MarrUI.Spacing.tight) {
                        Text("Edited \(files.count) file\(files.count == 1 ? "" : "s")")
                            .font(MarrTypography.font(.body, weight: .semibold))
                        HStack(spacing: MarrUI.Spacing.regular) {
                            Text("+\(additions)").foregroundStyle(.green)
                            Text("-\(deletions)").foregroundStyle(.red)
                        }
                        .font(MarrTypography.font(.code, weight: .medium))
                    }
                    Spacer(minLength: 0)
                    Button("Undo") {
                        guard let reversibleDiff,
                              workspace.revertCodexChanges(diff: reversibleDiff)
                        else { return }
                        revertedFileChangeTurnIDs.insert(turn.id)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(isReverted || reversibleDiff == nil ? .tertiary : .primary)
                    .disabled(isReverted || reversibleDiff == nil)

                    Button("Review") {
                        withAnimation(.easeOut(duration: 0.16)) {
                            if isReviewed {
                                reviewedFileChangeTurnIDs.remove(turn.id)
                            } else {
                                reviewedFileChangeTurnIDs.insert(turn.id)
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if isReviewed {
                    VStack(alignment: .leading, spacing: MarrUI.Spacing.tight) {
                        ForEach(files) { file in
                            HStack(spacing: MarrUI.Spacing.regular) {
                                Text(file.path)
                                    .font(MarrTypography.font(.code))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                                Text("+\(file.additions)").foregroundStyle(.green)
                                Text("-\(file.deletions)").foregroundStyle(.red)
                            }
                            .font(MarrTypography.font(.code, weight: .medium))
                        }
                    }
                    .padding(.leading, 57)
                }
            }
            .padding(12)
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: MarrUI.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: MarrUI.Radius.card, style: .continuous)
                    .stroke(.separator.opacity(0.58), lineWidth: 1)
            )
        }
    }

    private func formattedDuration(_ totalSeconds: Int) -> String {
        if totalSeconds < 60 { return "\(totalSeconds)s" }
        return "\(totalSeconds / 60)m \(totalSeconds % 60)s"
    }

    private func approvalCard(_ approval: CodexApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
            Label(approval.kind.title, marrSymbol: "hand.raised.fill")
                .font(MarrTypography.font(.secondary, weight: .semibold))
                .foregroundStyle(.orange)
            if let reason = approval.reason, !reason.isEmpty {
                Text(reason)
                    .font(MarrTypography.font(.secondary))
                    .foregroundStyle(MarrPanelColors.secondary(for: colorScheme))
            }
            if let preview = approval.preview, !preview.isEmpty {
                Text(preview)
                    .font(MarrTypography.font(.code))
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            HStack {
                Button("Decline") { workspace.respondToApproval(accept: false) }
                    .controlSize(.small)
                Button("Allow") { workspace.respondToApproval(accept: true) }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.11), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func errorCard(_ activity: WorkActivity) -> some View {
        MarrAgentErrorCard(activity: activity)
    }

    @ViewBuilder
    private func activityRow(_ activity: WorkActivity) -> some View {
        if activity.kind == .plan {
            DisclosureGroup {
                MarkdownResponseView(source: activity.detail, compact: true)
                    .padding(.top, MarrUI.Spacing.regular)
            } label: {
                Label(activity.title, marrSymbol: activity.kind.symbolName)
                    .marrTextStyle(.secondary, weight: .medium)
            }
            .padding(MarrUI.Spacing.medium)
            .marrSurface(.card, cornerRadius: MarrUI.Radius.card, border: .subtle)
        } else {
            MarrToolActivityCard(activity: activity,
                awaitingInput: MarrToolActivityPresentation.matchingRequest(
                    for: activity, in: workspace.pendingInteractions, threadID: workspace.workbench.selectedTask?.threadID) != nil,
                statusUncertain: workspace.isTaskStatusUncertain)
        }
    }

    private func color(for kind: WorkActivity.Kind) -> Color {
        switch kind {
        case .status: .blue
        case .plan: .purple
        case .command: .blue
        case .fileChange: .green
        case .user: selectedAccent.color
        case .message: .primary
        case .error: .red
        }
    }

    private var selectedAccent: MarrAccentColor {
        MarrAccentColor.resolve(accentColor)
    }
}
