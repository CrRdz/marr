import AppKit
import Combine
import MarrCore
import QuartzCore
import SwiftUI

/// Date grouping and snippets are independent of the view and persistence layer.
/// Calendar-day boundaries (rather than elapsed 24-hour periods) also cover DST.
enum MarrHistorySidebarContent {
    enum DateGroup: String, CaseIterable, Identifiable {
        case future, today, yesterday, previous7Days, previous30Days, older

        var id: String { rawValue }
        var title: String {
            switch self {
            case .future: return "Future dates"
            case .today: return "Today"
            case .yesterday: return "Yesterday"
            case .previous7Days: return "Previous 7 days"
            case .previous30Days: return "Previous 30 days"
            case .older: return "Older"
            }
        }
    }

    struct Section: Identifiable {
        let group: DateGroup
        let conversations: [ConversationHistoryRecord]
        var id: DateGroup { group }
    }

    static func sections(for conversations: [ConversationHistoryRecord], searchText: String,
                         now: Date = Date(), calendar: Calendar = .current) -> [Section] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = conversations.filter { conversation in
            guard !query.isEmpty else { return true }
            // Retain full-content search without constructing a duplicate of every answer.
            if conversation.title.localizedCaseInsensitiveContains(query) { return true }
            return conversation.turns.contains { turn in
                turn.question.localizedCaseInsensitiveContains(query)
                    || turn.answer.localizedCaseInsensitiveContains(query)
                    || (turn.errorMessage?.localizedCaseInsensitiveContains(query) ?? false)
            }
        }.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        let grouped = Dictionary(grouping: matches) { dateGroup(for: $0.updatedAt, now: now, calendar: calendar) }
        return DateGroup.allCases.compactMap { group in
            guard let records = grouped[group] else { return nil }
            return Section(group: group, conversations: records)
        }
    }

    static func dateGroup(for date: Date, now: Date, calendar: Calendar) -> DateGroup {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                          to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<0: return .future
        case 0: return .today
        case 1: return .yesterday
        case 2..<7: return .previous7Days
        case 7..<30: return .previous30Days
        default: return .older
        }
    }

    static func summary(for conversation: ConversationHistoryRecord) -> String {
        if let latest = conversation.turns.last {
            // A failed latest turn must not preview an older successful answer.
            if latest.status == .failed, let error = latest.errorMessage {
                let snippet = compactSnippet(error)
                if !snippet.isEmpty { return "Error: " + snippet }
            }
            for text in [latest.answer, latest.question] {
                let snippet = compactSnippet(text)
                if !snippet.isEmpty { return snippet }
            }
        }
        let attachmentCount = Set(conversation.images.map(\.id) + conversation.pendingImageIDs).count
        if attachmentCount > 0 { return attachmentCount == 1 ? "1 attachment" : "\(attachmentCount) attachments" }
        return "Empty conversation"
    }

    static func compactSnippet(_ text: String, limit: Int = 160) -> String {
        guard limit > 0 else { return "" }
        var result = ""
        var pendingSpace = false
        var count = 0
        for character in text {
            if character.isWhitespace {
                if !result.isEmpty { pendingSpace = true }
                continue
            }
            let addedCount = pendingSpace ? 2 : 1
            guard count + addedCount <= limit else { return result + "…" }
            if pendingSpace { result.append(" ") }
            result.append(character)
            count += addedCount
            pendingSpace = false
        }
        return result
    }
}

/// Keep the projection alive independently of which lazy rows are on screen.
/// A hidden header must not suspend history updates while the reader scrolls.
@MainActor
final class MarrHistoryProjection: ObservableObject {
    @Published private(set) var sections: [MarrHistorySidebarContent.Section] = []
    private var records: [ConversationHistoryRecord] = []
    private var query: String
    private let standaloneOnly: Bool
    private(set) var referenceDate = Date()
    private var observations = Set<AnyCancellable>()

    init(store: ConversationHistoryStore, query: String, standaloneOnly: Bool = false) {
        self.query = query
        self.standaloneOnly = standaloneOnly
        store.$conversations.sink { [weak self] records in
            guard let self else { return }
            self.records = records
            self.rebuild()
        }.store(in: &observations)
        NotificationCenter.default.publisher(for: .NSCalendarDayChanged).sink { [weak self] _ in
            guard let self else { return }
            self.referenceDate = Date()
            self.rebuild()
        }.store(in: &observations)
    }

    func updateQuery(_ query: String) {
        guard self.query != query else { return }
        self.query = query
        rebuild()
    }

    private func rebuild() {
        sections = MarrHistorySidebarContent.sections(for: records.filter { !$0.isArchived && (!standaloneOnly || $0.workspaceID == nil) }, searchText: query, now: referenceDate)
    }
}

struct AnswerPanelHistoryView: View {
    @ObservedObject var store: ConversationHistoryStore
    let currentConversationID: UUID?
    let isEmbedded: Bool
    @Binding var searchText: String
    @Binding var visibleConversationID: UUID?
    let onOpen: (ConversationHistoryRecord) -> Void

    @StateObject private var projection: MarrHistoryProjection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(MarrAccentColor.storageKey) private var accentColor = MarrAccentColor.system.rawValue

    init(store: ConversationHistoryStore, currentConversationID: UUID?, searchText: Binding<String>,
         visibleConversationID: Binding<UUID?> = .constant(nil), isEmbedded: Bool = false,
         standaloneOnly: Bool = false, onOpen: @escaping (ConversationHistoryRecord) -> Void) {
        self.store = store
        self.currentConversationID = currentConversationID
        self.isEmbedded = isEmbedded
        _projection = StateObject(wrappedValue: MarrHistoryProjection(store: store, query: searchText.wrappedValue, standaloneOnly: standaloneOnly))
        _searchText = searchText
        _visibleConversationID = visibleConversationID
        self.onOpen = onOpen
    }

    var body: some View {
        let sections = projection.sections
        Group {
            ConversationHistoryErrorView(store: store)
            if sections.isEmpty {
                if store.lastErrorMessage == nil || !store.conversations.isEmpty { emptyState }
            } else if isEmbedded {
                rows(sections)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: MarrUI.Spacing.tight) {
                        rows(sections)
                    }
                    .scrollTargetLayout()
                }
                .scrollPosition(id: $visibleConversationID)
                .scrollIndicators(.automatic)
                .accessibilityLabel("Conversation history")
            }
        }
        .onChange(of: searchText, initial: true) { _, query in projection.updateQuery(query) }
    }

    private func rows(_ sections: [MarrHistorySidebarContent.Section]) -> some View {
        Group {
            ForEach(sections) { section in
                if !isEmbedded {
                    Text(section.group.title)
                        .marrTextStyle(.caption, weight: .medium)
                        .foregroundStyle(MarrPanelColors.secondary(for: colorScheme))
                        .padding(.horizontal, 10)
                        .padding(.top, MarrUI.Spacing.medium)
                        .padding(.bottom, 3)
                        .accessibilityAddTraits(.isHeader)
                }
                ForEach(section.conversations) { conversation in
                    historyRow(conversation).id(conversation.id)
                }
            }
        }
    }

    private var emptyState: some View {
        let isSearching = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(spacing: MarrUI.Spacing.regular) {
            MarrIcon(isSearching ? "magnifyingglass" : "clock.arrow.circlepath", size: MarrUI.Icon.hero)
                .foregroundStyle(MarrPanelColors.secondary(for: colorScheme))
                .accessibilityHidden(true)
            Text(isSearching ? "No matches" : "No history yet")
                .marrTextStyle(.body, weight: .semibold)
            Text(isSearching ? "Try another word from a title, question or answer." : "Saved conversations will appear here.")
                .marrTextStyle(.secondary)
                .foregroundStyle(MarrPanelColors.secondary(for: colorScheme))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(MarrUI.Spacing.medium)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .accessibilityElement(children: .combine)
    }

    private func historyRow(_ conversation: ConversationHistoryRecord) -> some View {
        let isCurrent = conversation.id == currentConversationID
        let title = AnswerPanelConversationTitle.make(from: conversation.title)
        let summary = MarrHistorySidebarContent.summary(for: conversation)
        return MarrHoverRegion { isHovered in
            Button {
                onOpen(conversation)
            } label: {
                VStack(alignment: .leading, spacing: MarrUI.Spacing.tight) {
                    HStack(alignment: .firstTextBaseline, spacing: MarrUI.Spacing.regular) {
                        Text(title)
                            .marrTextStyle(.body, weight: isCurrent ? .medium : .regular)
                            .foregroundStyle(MarrPanelColors.primary(for: colorScheme))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !isEmbedded { Text(dateLabel(for: conversation.updatedAt))
                            .marrTextStyle(.caption)
                            .foregroundStyle(MarrPanelColors.secondary(for: colorScheme))
                            .lineLimit(1)
                            .fixedSize() }
                    }
                    if !isEmbedded { Text(verbatim: summary)
                        .marrTextStyle(.secondary)
                        .foregroundStyle(MarrPanelColors.secondary(for: colorScheme))
                        .lineLimit(1)
                        .truncationMode(.tail) }
                }
                .padding(.leading, isEmbedded ? 49 : 10)
                .padding(.trailing, 9)
                .padding(.vertical, isEmbedded ? 0 : 9)
                .frame(maxWidth: .infinity, minHeight: isEmbedded ? MarrUI.Row.height : MarrUI.Row.detailHeight, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: MarrUI.Radius.control, style: .continuous)
                        .fill(MarrPanelColors.primary(for: colorScheme).opacity(isCurrent ? 0.08 : isHovered ? 0.04 : 0))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: MarrUI.Radius.control, style: .continuous)
                        .stroke(isCurrent ? selectedAccent.color.opacity(contrast == .increased ? 0.9 : 0.25) : .clear,
                                lineWidth: contrast == .increased ? 1.5 : 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: MarrUI.Radius.control, style: .continuous))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue("\(summary). Updated \(conversation.updatedAt.formatted(date: .abbreviated, time: .shortened))")
            .accessibilityHint("Open saved conversation")
            .accessibilityAddTraits(isCurrent ? .isSelected : [])
            .accessibilityIdentifier("history-conversation-\(conversation.id.uuidString)")
            .help("\(title)\n\(summary)")
        }
    }

    private func dateLabel(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: projection.referenceDate) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: projection.referenceDate) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.year().month(.abbreviated).day())
    }

    private var selectedAccent: MarrAccentColor {
        MarrAccentColor.resolve(accentColor)
    }
}

/// Search spans saved conversations without changing the navigation tree's filters.
enum MarrGlobalSearchContent {
    static func matches(_ record: ConversationHistoryRecord, query: String, workspaceName: String = "") -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !record.isArchived else { return false }
        return query.isEmpty || record.title.localizedCaseInsensitiveContains(query)
            || workspaceName.localizedCaseInsensitiveContains(query)
            || record.turns.contains {
                $0.question.localizedCaseInsensitiveContains(query) || $0.answer.localizedCaseInsensitiveContains(query)
            }
    }

    static func matches(_ task: SavedTask, query: String, workspaceName: String = "") -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || task.title.localizedCaseInsensitiveContains(query)
            || task.latestAgentMessage.localizedCaseInsensitiveContains(query)
            || workspaceName.localizedCaseInsensitiveContains(query)
    }
}

struct MarrGlobalConversationSearch: View {
    @ObservedObject var store: ConversationHistoryStore
    @ObservedObject var workspace: RuntimeWorkspaceController
    @ObservedObject private var workbench: WorkbenchStore
    let canOpenLocal: Bool
    let onOpenLocal: (ConversationHistoryRecord) -> Void
    let onOpenTask: (SavedTask) -> Bool
    @State private var query = ""
    @State private var openError: String?
    @FocusState private var searchFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(store: ConversationHistoryStore, workspace: RuntimeWorkspaceController, canOpenLocal: Bool,
         onOpenLocal: @escaping (ConversationHistoryRecord) -> Void,
         onOpenTask: @escaping (SavedTask) -> Bool) {
        self.store = store
        self.workspace = workspace
        self.workbench = workspace.workbench
        self.canOpenLocal = canOpenLocal
        self.onOpenLocal = onOpenLocal
        self.onOpenTask = onOpenTask
    }

    private func localContext(_ record: ConversationHistoryRecord) -> String {
        store.workspaces.first { $0.id == record.workspaceID }?.name ?? "Local conversations"
    }

    private func taskContext(_ task: SavedTask) -> String {
        workbench.workspaces.first { $0.id == workbench.sidebarWorkspaceID(for: task) }?.name ?? "Work"
    }

    private var localResults: [ConversationHistoryRecord] {
        store.conversations.filter { MarrGlobalSearchContent.matches($0, query: query, workspaceName: localContext($0)) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var taskResults: [SavedTask] {
        guard workspace.codexSyncEnabled else { return [] }
        return workbench.tasks.filter {
            !workbench.isTaskArchived($0.id) && MarrGlobalSearchContent.matches($0, query: query, workspaceName: taskContext($0))
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        let local = localResults
        let tasks = taskResults
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                MarrIcon("magnifyingglass", size: MarrUI.Icon.inline).foregroundStyle(.secondary)
                TextField("Search all conversations", text: $query)
                    .textFieldStyle(.plain).marrTextStyle(.body)
                    .focused($searchFocused)
                    .accessibilityLabel("Search all conversations")
                    .accessibilityIdentifier("marr.globalSearch.query")
                    .onSubmit {
                        if let first = local.first, canOpenLocal { onOpenLocal(first) }
                        else if let first = tasks.first { openTask(first) }
                    }
                if !query.isEmpty {
                    Button { query = ""; searchFocused = true } label: {
                        MarrIcon("xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain).accessibilityLabel("Clear search")
                }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(18)
            Divider()
            if let openError {
                Text(openError).marrTextStyle(.secondary).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Recent conversations" : "Search results")
                        .marrTextStyle(.caption, weight: .medium).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                    if local.isEmpty && tasks.isEmpty {
                        Text(query.isEmpty ? "No saved conversations yet." : "No conversations match your search.")
                            .marrTextStyle(.body).foregroundStyle(.secondary).padding(10)
                    }
                    ForEach(local) { record in
                        result(title: record.title, context: localContext(record), enabled: canOpenLocal) { onOpenLocal(record) }
                    }
                    ForEach(tasks) { task in
                        result(title: task.title, context: taskContext(task), enabled: workspace.canSubmit) { openTask(task) }
                    }
                }.padding(10)
            }
        }
        .frame(width: 440, height: 440)
        .onAppear { searchFocused = true }
        .onChange(of: query) { _, _ in openError = nil }
    }

    private func openTask(_ task: SavedTask) {
        guard workspace.canSubmit else {
            openError = "Wait for the current operation to finish before opening a conversation."
            return
        }
        if !onOpenTask(task) { openError = workspace.statusMessage }
    }

    private func result(title: String, context: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                MarrIcon("text.bubble", size: MarrUI.Icon.inline).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: title).marrTextStyle(.body).foregroundStyle(.primary).lineLimit(1)
                    Text(verbatim: context).marrTextStyle(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain).disabled(!enabled)
        .help(enabled ? title : "Wait for the current operation to finish.")
    }
}
