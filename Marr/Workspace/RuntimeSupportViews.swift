import AppKit
import MarrCore
import SwiftUI
import ImageIO
import CryptoKit

/// Describes observable activity without treating a completed item as a
/// completed turn or attributing a new submission to an earlier turn.
enum CodexRunPresentation: Equatable {
    case working
    case responding
    case runningCommand
    case updatingFiles
    case needsInput

    var title: String {
        switch self {
        case .working: "Working…"
        case .responding: "Responding…"
        case .runningCommand: "Running command…"
        case .updatingFiles: "Updating files…"
        case .needsInput: "Needs your input"
        }
    }

    var isAnimating: Bool { self != .needsInput }

    static func resolve(
        isRunning: Bool,
        requiresInput: Bool,
        activities: [WorkActivity]
    ) -> Self? {
        if requiresInput { return .needsInput }
        guard isRunning else { return nil }
        guard let userIndex = activities.lastIndex(where: { $0.kind == .user }),
              let turnID = activities[userIndex].turnID else { return .working }

        let currentActivities = activities.suffix(from: userIndex + 1)
        // Before the server emits the next user item, preparation activity can
        // follow the previous turn. Missing or different IDs are ambiguous.
        guard currentActivities.allSatisfy({ $0.turnID == turnID }),
              let latest = currentActivities.last,
              latest.kind != .status, latest.kind != .error,
              let unfinished = currentActivities.last(where: { !$0.isComplete })
        else { return .working }

        switch unfinished.kind {
        case .message: return .responding
        case .command: return .runningCommand
        case .fileChange: return .updatingFiles
        default: return .working
        }
    }
}

struct CodexTaskChangeSummary: Equatable {
    let diff: String
    let files: [String]
    let additions: Int
    let deletions: Int

    init(diff: String) {
        self.diff = diff
        var paths: [String] = []
        var added = 0
        var deleted = 0
        var inHunk = false
        var oldPath: String?
        var previousLine = ""
        func path(_ header: String) -> String? {
            var value = header.components(separatedBy: "\t")[0]
            if value == "/dev/null" { return nil }
            if value.hasPrefix("\""), let decoded = try? JSONSerialization.jsonObject(with: Data(value.utf8), options: [.fragmentsAllowed]) as? String { value = decoded }
            if value.hasPrefix("a/") || value.hasPrefix("b/") { value = String(value.dropFirst(2)) }
            return value.isEmpty ? nil : value
        }
        for line in diff.components(separatedBy: .newlines) {
            if line.hasPrefix("diff --git ") { inHunk = false; oldPath = nil }
            else if !inHunk, line.hasPrefix("--- ") { oldPath = path(String(line.dropFirst(4))) }
            else if !inHunk, line.hasPrefix("+++ ") {
                if let value = path(String(line.dropFirst(4))) ?? oldPath { paths.append(value) }
            } else if line.hasPrefix("@@ ") || line.hasPrefix("@@@ ") {
                // fileChange items can contain `path\n@@ ...` without git headers.
                if !inHunk, !previousLine.hasPrefix("+++ "), !previousLine.hasPrefix("--- "),
                   !previousLine.hasPrefix("diff "), !previousLine.hasPrefix("index "),
                   !previousLine.contains(" "), previousLine.contains("/") || previousLine.contains(".") {
                    paths.append(previousLine)
                }
                inHunk = true
            } else if inHunk {
                if line.hasPrefix("+") { added += 1 }
                else if line.hasPrefix("-") { deleted += 1 }
                else if !line.isEmpty, !line.hasPrefix(" "), !line.hasPrefix("\\") { inHunk = false }
            }
            previousLine = line
        }
        var seen = Set<String>()
        files = paths.filter { seen.insert($0).inserted }
        additions = added
        deletions = deleted
    }
}

struct CodexTaskAgentSummary: Identifiable, Equatable {
    let id: String
    var status: String?
    var model: String?
    var message: String?
    var title: String { "Agent \(id)" }
    var isRunning: Bool { status == "pendingInit" || status == "running" }
    var isCompleted: Bool { status == "completed" }
    var statusLabel: String {
        switch status {
        case "pendingInit": "Starting"
        case "running": "Running"
        case "completed": "Completed"
        case "interrupted": "Interrupted"
        case "errored": "Failed"
        case "shutdown": "Stopped"
        case "notFound": "Unavailable"
        default: "Unknown"
        }
    }
}

struct CodexTaskSource: Identifiable, Equatable {
    let id: String
    let reference: String
    var isImage: Bool
    let label: String
    var allowsThumbnail: Bool

    init(reference: String, isImage: Bool, label: String, allowsThumbnail: Bool = false) {
        self.reference = reference
        self.isImage = isImage
        self.label = label
        self.allowsThumbnail = allowsThumbnail
        id = SHA256.hash(data: Data(reference.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    var url: URL? { CodexResourceAccess.url(for: reference) }
    var isEmbedded: Bool { reference.hasPrefix("data:image/") }
    var detail: String {
        if isEmbedded { return "Embedded image" }
        if let url { return url.isFileURL ? url.path : url.host ?? "Image" }
        return "Stored by Codex"
    }
}

/// Pure projection of recorded runtime items. It neither fetches resources nor
/// infers subagents from message titles or model-authored prose.
struct CodexTaskDetailsProjection: Equatable {
    let title: String
    let workspaceURL: URL?
    let changes: CodexTaskChangeSummary
    let agents: [CodexTaskAgentSummary]
    let sources: [CodexTaskSource]

    init(title: String, workspaceURL: URL?, latestDiff: String, activities: [WorkActivity], allowLocalThumbnails: Bool = true) {
        self.title = title
        self.workspaceURL = workspaceURL
        // Diff notifications are full snapshots. Summing activity snapshots
        // would count the same edits again every time the runtime updates them.
        let lastSnapshot = activities.last { $0.kind == .fileChange && $0.title == "Workspace diff updated" }
        let snapshot = latestDiff.isEmpty
            ? lastSnapshot?.detail ?? activities.last { $0.kind == .fileChange && $0.isComplete }?.detail ?? ""
            : latestDiff
        changes = CodexTaskChangeSummary(diff: snapshot)
        var agentOrder: [String] = []
        var agentMap: [String: CodexTaskAgentSummary] = [:]
        var foundSources: [CodexTaskSource] = []
        var sourceIndices: [String: Int] = [:]
        func appendSource(_ reference: String, image: Bool, label: String? = nil, allowsThumbnail: Bool = false) {
            let url = CodexResourceAccess.url(for: reference)
            guard url != nil || reference.hasPrefix("data:image/") || reference.hasPrefix("codex-image-id:") else { return }
            let canonical = url?.isFileURL == true ? url!.standardizedFileURL.path : reference
            if let index = sourceIndices[canonical] {
                // A later explicit attachment can authorize a thumbnail for an
                // earlier text reference to the same file, without duplication.
                if allowsThumbnail { foundSources[index].allowsThumbnail = true }
                if image { foundSources[index].isImage = true }
                return
            }
            let name = label ?? (url?.lastPathComponent.isEmpty == false ? url!.lastPathComponent : image ? "Image attachment" : "File")
            sourceIndices[canonical] = foundSources.count
            foundSources.append(CodexTaskSource(reference: canonical, isImage: image, label: name, allowsThumbnail: allowsThumbnail))
        }
        for activity in activities {
            guard let raw = activity.rawJSON, raw.utf8.count <= 80_000_000,
                  let item = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { continue }
            if item["type"] as? String == "collabAgentToolCall" {
                let states = item["agentsStates"] as? [String: [String: Any]] ?? [:]
                let sender = item["senderThreadId"] as? String
                let recipients = (item["receiverThreadIds"] as? [String] ?? []) + states.keys.sorted()
                for id in recipients where !id.isEmpty && id != sender {
                    if agentMap[id] == nil {
                        agentOrder.append(id)
                        agentMap[id] = CodexTaskAgentSummary(id: id)
                    }
                    if let state = states[id] {
                        if let status = state["status"] as? String { agentMap[id]?.status = status }
                        if let message = state["message"] as? String { agentMap[id]?.message = message }
                    }
                    if let model = item["model"] as? String, !model.isEmpty { agentMap[id]?.model = model }
                }
            } else if item["type"] as? String == "userMessage" {
                for input in item["content"] as? [[String: Any]] ?? [] {
                    switch input["type"] as? String {
                    case "localImage":
                        if let path = input["path"] as? String { appendSource(path, image: true, allowsThumbnail: allowLocalThumbnails) }
                    case "image":
                        if let url = input["url"] as? String { appendSource(url, image: true) }
                        else if let id = input["fileId"] as? String { appendSource("codex-image-id:" + id, image: true) }
                    case "text":
                        for url in Self.fileReferences(in: input["text"] as? String ?? "") {
                            appendSource(url.path, image: ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"].contains(url.pathExtension.lowercased()))
                        }
                    case "mention":
                        if let path = input["path"] as? String, let url = CodexResourceAccess.url(for: path), url.isFileURL {
                            appendSource(url.path, image: false, label: input["name"] as? String)
                        }
                    default: break
                    }
                }
            }
        }
        agents = agentOrder.compactMap { agentMap[$0] }
        sources = foundSources
    }

    static func fileReferences(in raw: String) -> [URL] {
        let text = String(raw.prefix(65_536))
        let nsText = text as NSString
        var candidates = CodexResourceAccess.links(in: text).filter(\.isFileURL).map(\.path)
        var protected: [NSRange] = []
        func capture(_ pattern: String, transform: (NSTextCheckingResult) -> String?) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
                guard !protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }), let value = transform(match) else { continue }
                candidates.append(value)
                protected.append(match.range)
            }
        }
        capture(#"(?m)^Local path:\s*(/[^\r\n]+)$"#) { nsText.substring(with: $0.range(at: 1)) }
        capture(#""/(?:[^"\\]|\\.)*""#) {
            try? JSONSerialization.jsonObject(with: Data(nsText.substring(with: $0.range).utf8), options: [.fragmentsAllowed]) as? String
        }
        capture(#"`(/[^`\r\n]+)`"#) { nsText.substring(with: $0.range(at: 1)) }
        capture(#"(?<!\S)(/[^\s<>\[\]()`\";,]+)"#) { match in
            let value = nsText.substring(with: match.range(at: 1))
            return value.dropFirst().contains("/") || value.contains(".") ? value : nil
        }
        var seen = Set<String>()
        return candidates.compactMap { value in
            guard let url = CodexResourceAccess.url(for: value), url.isFileURL,
                  seen.insert(url.standardizedFileURL.path).inserted else { return nil }
            return url.standardizedFileURL
        }
    }
}

struct CodexTaskDetailsInput: Equatable {
    let title: String
    let workspaceURL: URL?
    let latestDiff: String
    let activities: [WorkActivity]
    let allowLocalThumbnails: Bool

    init(title: String, workspaceURL: URL?, latestDiff: String, activities: [WorkActivity], allowLocalThumbnails: Bool) {
        self.title = title
        self.workspaceURL = workspaceURL
        self.latestDiff = latestDiff
        self.allowLocalThumbnails = allowLocalThumbnails
        self.activities = activities.filter { activity in
            if activity.kind == .user || activity.kind == .fileChange { return true }
            guard activity.kind == .status, let raw = activity.rawJSON, raw.utf8.count <= 2_000_000 else { return false }
            return raw.contains("\"collabAgentToolCall\"")
        }
    }

    var projection: CodexTaskDetailsProjection {
        CodexTaskDetailsProjection(title: title, workspaceURL: workspaceURL, latestDiff: latestDiff,
            activities: activities, allowLocalThumbnails: allowLocalThumbnails)
    }
}

struct CodexTaskDetailsView: View {
    @ObservedObject var workspace: RuntimeWorkspaceController
    @State private var cachedDetails: CodexTaskDetailsProjection?

    var body: some View {
        let input = CodexTaskDetailsInput(
            title: workspace.workbench.selectedTask?.title ?? "Current task",
            workspaceURL: workspace.workspaceURL, latestDiff: workspace.latestDiff, activities: workspace.activities,
            allowLocalThumbnails: !workspace.usesExternalAppServer)
        CodexTaskDetailsContent(details: cachedDetails ?? CodexTaskDetailsProjection(
            title: input.title, workspaceURL: input.workspaceURL, latestDiff: "", activities: []))
            // Message/output deltas are absent from the key. Unchanged raw
            // strings share storage; no base64 hash or JSON parsing per token.
            .onChange(of: input, initial: true) { _, next in cachedDetails = next.projection }
    }
}

struct CodexTaskDetailsContent: View {
    let details: CodexTaskDetailsProjection
    @State private var showsDiff = false
    @State private var showsAgents = false
    @State private var showsAllSources = false
    @State private var previewSource: CodexTaskSource?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MarrUI.Spacing.large) {
                VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
                    Label(details.workspaceURL?.lastPathComponent ?? "Task details", marrSymbol: "folder")
                        .font(MarrTypography.font(.body, weight: .semibold)).lineLimit(1)
                    Text(details.title).font(MarrTypography.font(.secondary)).foregroundStyle(.secondary).lineLimit(2)
                }
                Divider()
                changesSection
                Divider()
                agentsSection
                Divider()
                sourcesSection
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 224, maxHeight: 440)
        .font(MarrTypography.font(.secondary))
        .popover(item: $previewSource) { source in
            CodexMarkdownImageView(source: source.reference, label: source.label)
                .padding(10).frame(width: 300)
        }
    }

    private var changesSection: some View {
        VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
            if details.changes.diff.isEmpty {
                sectionLabel("Changes", icon: "square.and.pencil")
                empty("No changes reported yet.")
            } else {
                Button { showsDiff.toggle() } label: {
                    HStack(spacing: MarrUI.Spacing.regular) {
                        sectionLabel("Changes", icon: "square.and.pencil")
                        Spacer(minLength: 4)
                        Text("+\(details.changes.additions)").foregroundStyle(.green).monospacedDigit()
                        Text("−\(details.changes.deletions)").foregroundStyle(.red).monospacedDigit()
                        MarrIcon(showsDiff ? "chevron.down" : "chevron.right", size: MarrUI.Icon.disclosure).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Changes: \(details.changes.additions) additions, \(details.changes.deletions) deletions")
                .accessibilityValue(showsDiff ? "Expanded" : "Collapsed")
                if !details.changes.files.isEmpty {
                    Text("\(details.changes.files.count) \(details.changes.files.count == 1 ? "file" : "files") in the latest diff")
                        .foregroundStyle(.secondary)
                }
                if showsDiff {
                    MarrDiffView(source: details.changes.diff)
                }
            }
        }
    }

    private var agentsSection: some View {
        VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
            Button { showsAgents.toggle() } label: {
                HStack {
                    sectionLabel("Subagents", icon: "person.2")
                    Spacer()
                    Text("\(details.agents.count)").foregroundStyle(.secondary).monospacedDigit()
                    if !details.agents.isEmpty {
                        MarrIcon(showsAgents ? "chevron.down" : "chevron.right", size: MarrUI.Icon.disclosure).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(details.agents.isEmpty)
            .accessibilityLabel("Subagents: \(details.agents.count)")
            .accessibilityValue(showsAgents ? "Expanded" : "Collapsed")
            if details.agents.isEmpty { empty("No subagents reported yet.") }
            else {
                Text("Last reported: \(details.agents.filter(\.isRunning).count) running · \(details.agents.filter(\.isCompleted).count) completed")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if showsAgents { ForEach(details.agents) { agent in
                    HStack(alignment: .firstTextBaseline, spacing: MarrUI.Spacing.regular) {
                        VStack(alignment: .leading, spacing: MarrUI.Spacing.tight) {
                            Text(agent.title).lineLimit(1).truncationMode(.middle)
                            if let model = agent.model { Text(model).font(MarrTypography.font(.caption)).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        Spacer(minLength: 4)
                        Text(agent.statusLabel).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .help(([agent.id, agent.message].compactMap { $0 }).joined(separator: "\n"))
                } }
            }
        }
    }

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
            HStack {
                sectionLabel("Sources", icon: "paperclip")
                Spacer()
                Text("\(details.sources.count)").foregroundStyle(.secondary).monospacedDigit()
            }
            if details.sources.isEmpty { empty("No source attachments reported yet.") }
            else {
                VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
                    ForEach(showsAllSources ? details.sources : Array(details.sources.prefix(3))) { source in
                        Button {
                            if source.isImage, source.isEmbedded { previewSource = source }
                            else if let url = source.url {
                                if source.isImage, url.isFileURL { CodexResourceAccess.openImage(url) }
                                else { CodexResourceAccess.open(url) }
                            }
                        } label: {
                            HStack(spacing: MarrUI.Spacing.regular) {
                                CodexTaskSourceThumbnail(source: source).frame(width: 28, height: 28)
                                Text(source.label).lineLimit(1).truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(source.url == nil && !source.isEmbedded)
                        .help(source.detail)
                        .accessibilityLabel(source.label)
                    }
                    if details.sources.count > 3 {
                        Button(showsAllSources ? "Show less" : "Show all \(details.sources.count) sources") {
                            showsAllSources.toggle()
                        }
                        .buttonStyle(.link)
                    }
                }
            }
        }
    }

    private func sectionLabel(_ title: String, icon: String) -> some View {
        Label(title, marrSymbol: icon).font(MarrTypography.font(.secondary, weight: .medium))
    }

    private func empty(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

private struct CodexTaskSourceThumbnail: View {
    let source: CodexTaskSource
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.primary.opacity(0.045))
            if let image { Image(nsImage: image).resizable().scaledToFit().padding(3) }
            else { MarrIcon(source.isImage ? "photo" : "doc").foregroundStyle(.secondary) }
        }
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
        .task(id: source.id) {
            image = nil
            // Local thumbnails only. Opening the card never downloads a remote
            // image or sends a request to a URL embedded in the conversation.
            guard source.isImage, source.allowsThumbnail, let url = source.url, url.isFileURL,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, (values.fileSize ?? 0) <= 50_000_000,
                  let dataSource = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(dataSource, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 192,
                    kCGImageSourceCreateThumbnailWithTransform: true
                  ] as CFDictionary) else { return }
            image = NSImage(cgImage: thumbnail, size: .zero)
        }
    }
}

enum CodexDraftMerge {
    static func merge(currentPrompt: String, currentAttachments: [ConversationImageAsset],
                      recoveredPrompt: String, recoveredAttachments: [ConversationImageAsset]) -> (prompt: String, attachments: [ConversationImageAsset]) {
        let prompt: String
        if currentPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { prompt = recoveredPrompt }
        else if recoveredPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { prompt = currentPrompt }
        else { prompt = currentPrompt + "\n\n" + recoveredPrompt }
        var ids = Set(currentAttachments.map(\.id))
        return (prompt, currentAttachments + recoveredAttachments.filter { ids.insert($0.id).inserted })
    }
}

enum CodexCapabilitySection: String, CaseIterable, Identifiable {
    case skills, plugins, apps, mcp
    var id: String { rawValue }
    var title: String {
        switch self { case .skills: "Skills"; case .plugins: "Plugins"; case .apps: "Apps"; case .mcp: "MCP" }
    }
    func includes(_ method: String) -> Bool {
        let key = method.lowercased()
        switch self {
        case .skills: return key.hasPrefix("skills/")
        case .plugins: return key.hasPrefix("plugin/") || key.hasPrefix("marketplace/")
        case .apps: return key.hasPrefix("app/")
        case .mcp: return key.hasPrefix("mcpserver") || key.hasPrefix("mcp ") || key.hasPrefix("config/mcpserver/")
        }
    }
    func includes(_ entry: CodexExtensionEntry) -> Bool {
        let kind = entry.kind.lowercased()
        switch self {
        case .skills: return false
        case .plugins: return kind == "plugin"
        case .apps: return kind == "app"
        case .mcp: return kind == "mcp"
        }
    }
}

enum CodexCapabilityPresentation {
    static func errors(_ errors: [String: String], in section: CodexCapabilitySection) -> [(key: String, message: String)] {
        errors.keys.filter(section.includes).sorted().compactMap { key in errors[key].map { (key, $0) } }
    }

    /// A final display boundary for older runtimes that put HTTP response bodies in their error message.
    static func summary(_ message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("403") || lower.contains("forbidden") { return "This account does not have access to this capability (403)." }
        if lower.contains("401") || lower.contains("unauthorized") { return "Sign in again to access this capability (401)." }
        if lower.contains("<html") || lower.contains("<!doctype") { return "The service returned a page instead of capability data. Try refreshing or check the runtime connection." }
        let firstLine = message.components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? "This capability could not be loaded."
        return String(firstLine.prefix(260))
    }
}

private struct CodexCapabilityErrorView: View {
    let method: String
    let message: String
    let diagnostic: String?

    var body: some View {
        VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
            Label(CodexCapabilityPresentation.summary(message), marrSymbol: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
            DisclosureGroup("Details") {
                VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
                    Text(method).foregroundStyle(.secondary)
                    ScrollView([.horizontal, .vertical]) {
                        Text(verbatim: String((diagnostic ?? message).prefix(12_000)))
                            .font(MarrTypography.font(.code))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: true)
                    }
                    .frame(height: 120)
                    if (diagnostic ?? message).count > 12_000 {
                        Text("Showing the first 12,000 characters.").foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 5)
            }
        }
        .font(MarrTypography.font(.secondary))
        .padding(10)
        .background(.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct CodexCapabilitiesView: View {
    @ObservedObject var workspace: RuntimeWorkspaceController
    private let selection: Binding<CodexCapabilitySection>?
    private let embedded: Bool
    @State private var localSection: CodexCapabilitySection = .skills
    @State private var search = ""
    @State private var pluginToUninstall: CodexExtensionEntry?

    init(workspace: RuntimeWorkspaceController, section: Binding<CodexCapabilitySection>? = nil, embedded: Bool = false) {
        self.workspace = workspace
        self.selection = section
        self.embedded = embedded
    }

    private var currentSection: CodexCapabilitySection { selection?.wrappedValue ?? localSection }
    private var sectionBinding: Binding<CodexCapabilitySection> { selection ?? $localSection }
    private var isLoading: Bool { workspace.loadingCapabilityMethods.contains(where: currentSection.includes) }
    private var visibleErrors: [(key: String, message: String)] {
        CodexCapabilityPresentation.errors(workspace.capabilityErrors, in: currentSection)
    }
    private var entries: [CodexExtensionEntry] { workspace.extensions.filter(currentSection.includes) }
    private var matchingSkills: [CodexSkill] {
        workspace.skills.filter {
            search.isEmpty || "\($0.displayName) \($0.name) \($0.description) \($0.scope)".localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MarrUI.Spacing.medium) {
            HStack(spacing: MarrUI.Spacing.regular) {
                Picker("Work capabilities", selection: sectionBinding) {
                    ForEach(CodexCapabilitySection.allCases) { section in Text(section.title).tag(section) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if isLoading { ProgressView().controlSize(.small) }
                Button { refresh() } label: { MarrIcon("arrow.clockwise") }
                    .buttonStyle(.plain)
                    .disabled(isLoading)
                    .accessibilityLabel("Refresh \(currentSection.title)")
                    .help("Refresh \(currentSection.title)")
            }
            if currentSection == .skills {
                TextField("Search skills", text: $search).textFieldStyle(.roundedBorder)
                Text("Type $ in Work to find and invoke a skill. Manage which skills are enabled here.")
                    .font(MarrTypography.font(.secondary)).foregroundStyle(.secondary)
            }
            if embedded {
                capabilityList
            } else {
                ScrollView { capabilityList }
            }
            if currentSection == .mcp {
                Button("Reload MCP servers") { workspace.reloadMCPServers() }
                    .disabled(workspace.isRunning || isLoading)
            }
        }
        .font(MarrTypography.font(.body))
        .padding(embedded ? 0 : 16)
        .frame(width: embedded ? nil : 410, height: embedded ? nil : 450)
        .onAppear { loadIfNeeded() }
        .onChange(of: currentSection) { _, _ in loadIfNeeded() }
        .alert("Uninstall shared plugin?", isPresented: Binding(
            get: { pluginToUninstall != nil },
            set: { if !$0 { pluginToUninstall = nil } }
        ), presenting: pluginToUninstall) { entry in
            Button("Cancel", role: .cancel) { pluginToUninstall = nil }
            Button("Uninstall", role: .destructive) {
                workspace.uninstallPlugin(entry)
                pluginToUninstall = nil
            }
        } message: { entry in
            Text("Uninstalling \(entry.name) changes the shared Codex runtime and also affects the desktop app.")
        }
    }

    private var capabilityList: some View {
        LazyVStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
            ForEach(visibleErrors, id: \.key) { error in
                CodexCapabilityErrorView(method: error.key, message: error.message,
                                         diagnostic: workspace.capabilityDiagnostics[error.key])
            }
            if currentSection == .skills {
                if matchingSkills.isEmpty, !isLoading {
                    Text(search.isEmpty ? "No skills reported for this workspace." : "No matching skills.")
                        .foregroundStyle(.secondary)
                }
                ForEach(matchingSkills) { skill in skillRow(skill) }
            } else {
                if entries.isEmpty, !isLoading, visibleErrors.isEmpty {
                    Text("No \(currentSection.title.lowercased()) reported by this runtime.").foregroundStyle(.secondary)
                }
                ForEach(entries) { entry in extensionRow(entry) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func refresh() {
        switch currentSection {
        case .skills: workspace.refreshSkills()
        case .plugins: workspace.refreshPlugins()
        case .apps: workspace.refreshApps()
        case .mcp: workspace.refreshMCPServers()
        }
    }

    private func loadIfNeeded() {
        let hasContent = currentSection == .skills ? !workspace.skills.isEmpty : !entries.isEmpty
        if !isLoading, !hasContent, visibleErrors.isEmpty { refresh() }
    }

    private func skillRow(_ skill: CodexSkill) -> some View {
        VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
            HStack(alignment: .top, spacing: MarrUI.Spacing.regular) {
                VStack(alignment: .leading, spacing: MarrUI.Spacing.tight) {
                    Text(skill.displayName.isEmpty ? skill.name : skill.displayName)
                        .font(MarrTypography.font(.body, weight: .medium))
                    HStack(spacing: MarrUI.Spacing.regular) {
                        Text("$" + skill.name).font(MarrTypography.font(.code)).textSelection(.enabled)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("$" + skill.name, forType: .string)
                        } label: { MarrIcon("doc.on.doc") }
                        .buttonStyle(.plain)
                        .help("Copy skill invocation")
                        .accessibilityLabel("Copy $\(skill.name)")
                    }
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Toggle("Enabled", isOn: Binding(
                    get: { skill.enabled },
                    set: { workspace.setSkillEnabled(skill, enabled: $0) }
                ))
                .toggleStyle(.switch).controlSize(.mini)
                .disabled(workspace.isRunning || isLoading)
            }
            if !skill.description.isEmpty { Text(skill.description).foregroundStyle(.secondary) }
            DisclosureGroup("Details") {
                VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
                    Text("Scope: " + skill.scope)
                    Text(skill.path).font(MarrTypography.font(.code)).textSelection(.enabled)
                    if !skill.dependencySummary.isEmpty { Text(skill.dependencySummary) }
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            }
        }
        .font(MarrTypography.font(.secondary))
        .padding(12)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    private func extensionRow(_ entry: CodexExtensionEntry) -> some View {
        VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
            HStack {
                Text(entry.name).fontWeight(.medium)
                Spacer()
                Text(entry.status).font(MarrTypography.font(.caption)).foregroundStyle(.secondary)
            }
            if !entry.detail.isEmpty { Text(entry.detail).foregroundStyle(.secondary).textSelection(.enabled) }
            if let enabled = entry.enabled {
                Label(enabled ? "Enabled" : "Disabled", marrSymbol: enabled ? "checkmark.circle" : "minus.circle")
                    .foregroundStyle(.secondary)
            }
            HStack {
                if entry.kind.lowercased() == "mcp" {
                    Button("Connect account") { workspace.loginMCPServer(entry.name) }
                        .disabled(workspace.isRunning)
                }
                if let url = entry.url, CodexResourceAccess.isWebURL(url) {
                    Button("Open") { CodexResourceAccess.open(url) }
                }
                if entry.canInstall {
                    Button("Install") { workspace.installPlugin(entry) }
                        .disabled(workspace.pluginOperationsInFlight.contains(entry.id))
                }
                if entry.installed == true, entry.kind.lowercased() == "plugin" {
                    Button("Uninstall") { pluginToUninstall = entry }
                        .disabled(workspace.pluginOperationsInFlight.contains(entry.id))
                }
                if workspace.pluginOperationsInFlight.contains(entry.id) { ProgressView().controlSize(.small) }
            }
            .controlSize(.small)
        }
        .font(MarrTypography.font(.secondary))
        .padding(10)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct CodexInteractionCard: View {
    let request: CodexInteractionRequest
    @ObservedObject var workspace: RuntimeWorkspaceController
    @State private var answers: [String: String] = [:]
    @State private var formValues: [String: String] = [:]
    @State private var selectedApprovalID: String?

    private var selectedApproval: CodexApprovalDecision? {
        request.approvalDecisions.first { $0.id == selectedApprovalID }
    }

    private var canAccept: Bool {
        if request.isOperationApproval { return selectedApproval != nil }
        return request.supportsAcceptance
            && request.questions.allSatisfy { !(answers[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
            MarrStatusLabel(.needsInput, title: request.title)
            if let source = request.params["serverName"] as? String ?? request.params["tool"] as? String {
                Text(source).marrTextStyle(.secondary, weight: .medium).textSelection(.enabled)
            }
            if let target = request.params["cwd"] as? String ?? request.params["grantRoot"] as? String {
                Label(target, marrSymbol: "folder")
                    .marrTextStyle(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle).help(target)
            }
            if !request.message.isEmpty {
                Text(request.message).font(MarrTypography.font(.secondary)).textSelection(.enabled)
            }
            if !request.preview.isEmpty {
                ScrollView([.horizontal, .vertical]) {
                    Text(request.preview).font(MarrTypography.font(.code)).textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: min(110, max(24, CGFloat(request.preview.components(separatedBy: .newlines).count) * 17)))
            }
            ForEach(request.questions, id: \.id) { question in questionField(question) }
            ForEach(request.formFields, id: \.id) { field in formField(field) }
            if request.isOperationApproval, !request.approvalDecisions.isEmpty {
                Picker("Approval", selection: $selectedApprovalID) {
                    Text("Choose an option…").tag(String?.none)
                    ForEach(request.approvalDecisions) { decision in
                        Text(decision.title).tag(Optional(decision.id))
                    }
                }
                if let decision = selectedApproval {
                    Text(decision.detail).font(MarrTypography.font(.secondary)).textSelection(.enabled)
                }
            }
            if let url = request.url, CodexResourceAccess.isWebURL(url) {
                Button { CodexResourceAccess.open(url) } label: {
                    Label("Open \(url.host ?? "requested page")", marrSymbol: "arrow.up.right.square")
                }
                Text(url.absoluteString).font(MarrTypography.font(.caption)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if request.isOperationApproval ? request.approvalDecisions.isEmpty : !request.supportsAcceptance {
                Text("This request needs a client capability that is unavailable here. You can decline or cancel it.")
                    .font(MarrTypography.font(.secondary)).foregroundStyle(.secondary)
            }
            if let error = workspace.interactionErrors[request.id] {
                Label(error, marrSymbol: "exclamationmark.circle")
                    .font(MarrTypography.font(.secondary)).foregroundStyle(.red)
            }
            HStack {
                Button("Cancel") { respond(.cancel) }
                Button("Decline") { respond(.decline) }
                Spacer()
                Button(request.isOperationApproval ? "Confirm" : (request.questions.isEmpty && request.formFields.isEmpty ? "Allow" : "Submit")) { respond(.accept) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAccept)
            }
            .controlSize(.small)
        }
        .padding(12)
        .marrSurface(.card, cornerRadius: MarrUI.Radius.card, border: .standard,
                     tint: MarrUI.Status.needsInput.color())
        .onAppear {
            // A missing one-time option must never silently select a wider grant.
            if selectedApprovalID == nil {
                selectedApprovalID = request.approvalDecisions.first { $0.rawValue as? String == "accept" }?.id
            }
            for field in request.formFields where formValues[field.name] == nil {
                if !field.defaultValue.isEmpty { formValues[field.name] = field.defaultValue }
                else if field.type == "boolean" { formValues[field.name] = "false" }
                else if field.type == "array", !field.options.isEmpty { formValues[field.name] = "[]" }
                else { formValues[field.name] = "" }
            }
        }
    }

    private func questionField(_ question: CodexQuestion) -> some View {
        VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
            if !question.header.isEmpty { Text(question.header).fontWeight(.medium) }
            Text(question.question)
            ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                Button { answers[question.id] = option.label } label: {
                    HStack(alignment: .top, spacing: MarrUI.Spacing.regular) {
                        MarrIcon(answers[question.id] == option.label ? "largecircle.fill.circle" : "circle")
                        VStack(alignment: .leading, spacing: MarrUI.Spacing.tight) {
                            Text(option.label)
                            if !option.description.isEmpty { Text(option.description).foregroundStyle(.secondary) }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 3)
            }
            if question.options.isEmpty || question.isOther {
                if question.isSecret {
                    SecureField("Your answer", text: answerBinding(question.id)).textFieldStyle(.roundedBorder)
                } else {
                    TextField(question.options.isEmpty ? "Your answer" : "Or enter your own answer", text: Binding(
                        get: {
                            let value = answers[question.id] ?? ""
                            return question.options.contains { $0.label == value } ? "" : value
                        },
                        set: { answers[question.id] = $0 }
                    ))
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
        .font(MarrTypography.font(.secondary))
    }

    @ViewBuilder
    private func formField(_ field: CodexFormField) -> some View {
        VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
            Text(field.title + (field.required ? " *" : "")).fontWeight(.medium)
            if !field.description.isEmpty { Text(field.description).foregroundStyle(.secondary) }
            if field.type == "boolean" {
                Toggle(field.title, isOn: Binding(
                    get: { (formValues[field.name] ?? field.defaultValue) == "true" },
                    set: { formValues[field.name] = $0 ? "true" : "false" }
                ))
                .toggleStyle(.checkbox)
            } else if field.type == "array", !field.options.isEmpty {
                ForEach(field.options, id: \.self) { option in
                    Toggle(field.optionTitles[option] ?? option, isOn: Binding(
                        get: { selectedFormOptions(field).contains(option) },
                        set: { selected in
                            var values = selectedFormOptions(field)
                            if selected { values.insert(option) } else { values.remove(option) }
                            let ordered = field.options.filter { values.contains($0) }
                            if let data = try? JSONSerialization.data(withJSONObject: ordered) {
                                formValues[field.name] = String(decoding: data, as: UTF8.self)
                            }
                        }
                    ))
                    .toggleStyle(.checkbox)
                }
            } else if !field.options.isEmpty {
                Picker(field.title, selection: formBinding(field)) {
                    Text("Choose…").tag("")
                    ForEach(field.options, id: \.self) { Text(field.optionTitles[$0] ?? $0).tag($0) }
                }
                .labelsHidden()
            } else {
                TextField(field.type == "object" || field.type == "array" ? "JSON value" : field.title, text: formBinding(field))
                    .textFieldStyle(.roundedBorder)
            }
        }
        .font(MarrTypography.font(.secondary))
    }

    private func answerBinding(_ id: String) -> Binding<String> {
        Binding(get: { answers[id] ?? "" }, set: { answers[id] = $0 })
    }

    private func formBinding(_ field: CodexFormField) -> Binding<String> {
        Binding(get: { formValues[field.name] ?? field.defaultValue }, set: { formValues[field.name] = $0 })
    }

    private func selectedFormOptions(_ field: CodexFormField) -> Set<String> {
        let value = formValues[field.name] ?? field.defaultValue
        guard let array = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String] else { return [] }
        return Set(array)
    }

    private func respond(_ action: CodexInteractionAction) {
        if action == .accept, request.isOperationApproval {
            guard let decision = selectedApproval else { return }
            workspace.respondToApprovalDecision(request, decision: decision)
            return
        }
        workspace.respondToInteraction(request, action: action, answers: answers.mapValues { [$0] }, formValues: formValues)
    }
}

struct CodexAsyncQuestion: Identifiable, Equatable {
    let id: Int
    let title: String
    let options: [String]

    static func parse(_ rawJSON: String) -> [CodexAsyncQuestion] {
        guard rawJSON.utf8.count < 2_000_000,
              let item = try? JSONSerialization.jsonObject(with: Data(rawJSON.utf8)) as? [String: Any],
              item["type"] as? String == "agentMessage" else { return [] }
        return (item["questions"] as? [[String: Any]] ?? []).enumerated().compactMap { index, row in
            guard let title = row["title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return CodexAsyncQuestion(id: index, title: title, options: row["options"] as? [String] ?? [])
        }
    }
}

struct CodexAsyncQuestionsView: View {
    private let questions: [CodexAsyncQuestion]
    @ObservedObject var workspace: RuntimeWorkspaceController
    @State private var answers: [Int: String] = [:]
    @State private var submitted = false

    init(source: String, workspace: RuntimeWorkspaceController) {
        self.questions = CodexAsyncQuestion.parse(source)
        self.workspace = workspace
    }
    private var canSend: Bool {
        !submitted && (workspace.canSubmit || workspace.canSteer)
            && questions.allSatisfy { !(answers[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        if !questions.isEmpty {
            VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
                Label(submitted ? "Answers sent" : "Your input is welcome", marrSymbol: submitted ? "checkmark.circle" : "questionmark.bubble")
                    .fontWeight(.medium)
                ForEach(questions) { question in
                    VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
                        Text(question.title)
                        ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                            Button { answers[question.id] = option } label: {
                                Label(option, marrSymbol: answers[question.id] == option ? "largecircle.fill.circle" : "circle")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(submitted)
                        }
                        TextField("Your answer", text: Binding(
                            get: { answers[question.id] ?? "" },
                            set: { answers[question.id] = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .disabled(submitted)
                    }
                }
                HStack {
                    Spacer()
                    Button("Send answers") {
                        let prompt = "Answers to your questions:\n\n" + questions.map {
                            "\($0.title)\nAnswer: \(answers[$0.id] ?? "")"
                        }.joined(separator: "\n\n")
                        submitted = workspace.canSteer
                            ? workspace.steer(prompt: prompt, images: [])
                            : workspace.submit(prompt: prompt, images: [])
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSend)
                }
            }
            .font(MarrTypography.font(.secondary))
            .padding(12)
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

/// Resource access is always initiated by a click; model text never opens a URL or file itself.
enum CodexResourceAccess {
    static func isWebURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        return url.scheme?.lowercased() == "https" ||
            (url.scheme?.lowercased() == "http" && ["localhost", "127.0.0.1", "::1"].contains(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))))
    }

    static func url(for raw: String) -> URL? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("/") { return URL(fileURLWithPath: value) }
        guard let url = URL(string: value), url.isFileURL || isWebURL(url) else { return nil }
        if url.isFileURL, let host = url.host, !host.isEmpty, host.lowercased() != "localhost" { return nil }
        return url
    }

    static func open(_ url: URL) {
        if url.isFileURL {
            guard let local = self.url(for: url.absoluteString) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([local])
        } else if isWebURL(url) {
            NSWorkspace.shared.open(url)
        }
    }

    static func openImage(_ url: URL) {
        guard url.isFileURL else { open(url); return }
        guard let previewApp = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else {
            open(url)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: previewApp, configuration: NSWorkspace.OpenConfiguration())
    }

    static func links(in text: String) -> [URL] {
        let source = String(text.prefix(65_536))
        var candidates: [String] = []
        func capture(_ pattern: String, group: Int = 0) {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return }
            candidates += expression.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap {
                guard let range = Range($0.range(at: group), in: source) else { return nil }
                return String(source[range])
            }
        }
        capture(#"https://[^\s\"<>\)\]]+"#)
        capture(#"\]\(<((?:/|file://)[^>]+)>\)"#, group: 1)
        capture(#"\]\(((?:/|file://)[^\s\)]+)\)"#, group: 1)
        capture(#"\"(?:path|filePath|outputPath|resourceUri|uri|url)\"\s*:\s*\"((?:/|file://)[^\"]+)\""#, group: 1)
        candidates += source.components(separatedBy: .newlines).compactMap { line in
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.hasPrefix("/") && !value.contains(" ") ? value : nil
        }
        var seen = Set<String>()
        return candidates.compactMap { candidate in
            guard let url = url(for: candidate),
                  seen.insert(url.absoluteString).inserted else { return nil }
            return url
        }
    }
}

struct CodexResourceLinksView: View {
    let source: String

    var body: some View {
        let links = CodexResourceAccess.links(in: source)
        if !links.isEmpty {
            VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
                ForEach(links.prefix(20), id: \.absoluteString) { url in
                    Button { CodexResourceAccess.open(url) } label: {
                        Label(url.isFileURL ? "Show \(url.lastPathComponent) in Finder" : url.absoluteString,
                              marrSymbol: url.isFileURL ? "doc" : "arrow.up.right.square")
                            .lineLimit(2)
                    }
                    .buttonStyle(.link)
                }
            }
            .font(MarrTypography.font(.secondary))
        }
    }
}

/// User attachments belong to their message. Only local/data images load
/// automatically; remote resources still require an explicit user action.
struct MarrUserAttachmentView: View {
    let artifact: CodexArtifact
    @Environment(\.marrHistoryThreadID) private var historyThreadID
    @State private var preview: NSImage?
    @State private var unavailable = false
    @State private var requestedRemotePreview = false
    @State private var isLoading = false
    @State private var recoveryURL: URL?
    @State private var retryCount = 0

    private var item: MarrMediaItem? { MarrMediaItem(source: recoveryURL?.path ?? artifact.source, label: artifact.label, id: artifact.id) }
    private var resourceURL: URL? { recoveryURL ?? CodexResourceAccess.url(for: artifact.source) }
    private var canLoadAutomatically: Bool {
        item?.canLoadAutomatically == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MarrUI.Spacing.tight) {
            if artifact.isImage {
                if let preview {
                    Button(action: openViewer) {
                        MarrUserImagePreview(image: preview)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open \(artifact.label) in image viewer")
                } else if unavailable || item == nil {
                    Label("Original image unavailable", marrSymbol: "photo")
                        .marrTextStyle(.secondary).foregroundStyle(.secondary)
                    if historyThreadID != nil {
                        Button("Retry recovery") { retryCount += 1 }
                            .buttonStyle(.borderless).marrTextStyle(.caption)
                    }
                } else if canLoadAutomatically || isLoading {
                    ProgressView().controlSize(.small).frame(width: 160, height: 90)
                        .accessibilityLabel("Loading attached image")
                } else {
                    Button { requestedRemotePreview = true } label: {
                        Label("Load image", marrSymbol: "photo")
                    }
                    .buttonStyle(.borderless)
                }
            } else if let url = resourceURL {
                Button { CodexResourceAccess.open(url) } label: {
                    Label(artifact.label, marrSymbol: "doc")
                        .lineLimit(2).truncationMode(.middle)
                }
                .buttonStyle(.plain).marrTextStyle(.secondary)
                if !url.pathExtension.isEmpty {
                    Text(url.pathExtension.uppercased()).marrTextStyle(.caption).foregroundStyle(.secondary)
                }
            } else {
                Label(artifact.label, marrSymbol: "doc").marrTextStyle(.secondary)
                Text("Preview unavailable").marrTextStyle(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(artifact.isImage ? 0 : 8)
        .frame(maxWidth: MarrUserImagePreview.maximumWidth, alignment: .leading)
        .background(.primary.opacity(artifact.isImage ? 0 : 0.04), in: RoundedRectangle(cornerRadius: MarrUI.Radius.card))
        .contextMenu {
            if artifact.isImage, item != nil { Button("Open viewer", action: openViewer) }
            if let url = resourceURL {
                Button(url.isFileURL ? "Show in Finder" : "Open image") { CodexResourceAccess.open(url) }
                Button("Copy location") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.isFileURL ? url.path : url.absoluteString, forType: .string)
                }
            }
        }
        .task(id: "\(historyThreadID ?? "")-\(requestedRemotePreview)-\(retryCount)") {
            preview = nil
            recoveryURL = nil
            guard artifact.isImage, canLoadAutomatically || requestedRemotePreview, let item else { return }
            unavailable = false
            isLoading = true
            defer { isLoading = false }
            do {
                let decoded = try await MarrMediaLoader.load(item, maximumPixelDimension: 840)
                try Task.checkCancellation()
                preview = NSImage(cgImage: decoded.image, size: .zero)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                if let restored = await MarrHistoryImageRecovery.recover(source: artifact.source, threadID: historyThreadID,
                    retry: retryCount > 0), let recoveredItem = MarrMediaItem(source: restored.path, label: artifact.label) {
                    do {
                        let decoded = try await MarrMediaLoader.load(recoveredItem, maximumPixelDimension: 840)
                        try Task.checkCancellation()
                        recoveryURL = restored
                        preview = NSImage(cgImage: decoded.image, size: .zero)
                    } catch { if !Task.isCancelled { unavailable = true } }
                } else if !Task.isCancelled { unavailable = true }
            }
        }
    }

    private func openViewer() {
        guard let item else { return }
        MarrMediaViewer.show(items: [item])
    }
}

struct CodexArtifactView: View {
    let artifact: CodexArtifact

    var body: some View {
        if artifact.isImage {
            CodexMarkdownImageView(source: artifact.source, label: artifact.label)
        } else if let url = CodexResourceAccess.url(for: artifact.source) {
            Button { CodexResourceAccess.open(url) } label: {
                Label(artifact.label, marrSymbol: "doc")
            }
            .buttonStyle(.link)
        } else {
            VStack(alignment: .leading, spacing: MarrUI.Spacing.tight) {
                Label(artifact.label, marrSymbol: "doc")
                Text(artifact.source).lineLimit(3).textSelection(.enabled)
                Text("This resource needs a compatible application to preview.").foregroundStyle(.secondary)
            }
            .font(MarrTypography.font(.secondary))
        }
    }
}

struct CodexMarkdownImageView: View {
    let source: String
    let label: String

    var body: some View {
        // A streamed edit can replace an image in the same Markdown block.
        // Reset both preview state and any explicit network consent with it.
        MarrMarkdownImageContent(source: source, label: label).id(source)
    }
}

private struct MarrMarkdownImageContent: View {
    let source: String
    let label: String
    @State private var preview: NSImage?
    @State private var previewRequest: UUID?
    @State private var isLoading = false
    @State private var error: String?

    private var item: MarrMediaItem? { MarrMediaItem(source: source, label: label) }

    var body: some View {
        VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
            if let preview {
                Button(action: showViewer) {
                    Image(nsImage: preview).resizable().scaledToFit().frame(maxHeight: 320)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label.isEmpty ? "Open image viewer" : "Open \(label) in image viewer")
                .help("Open image viewer to zoom, pan and copy")
            } else if isLoading || (item?.canLoadAutomatically == true && error == nil) {
                ProgressView("Loading image…")
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
            ViewThatFits(in: .horizontal) {
                HStack { actions }
                VStack(alignment: .leading) { actions }
            }
            .controlSize(.small)
            if let error {
                Label(error, marrSymbol: "exclamationmark.triangle")
                    .foregroundStyle(.secondary).font(MarrTypography.font(.secondary))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .marrSurface(.card, cornerRadius: MarrUI.Radius.card, border: .subtle)
        .task(id: previewRequest) {
            guard let item else {
                error = MarrMediaLoadError.invalidSource.localizedDescription
                return
            }
            guard item.canLoadAutomatically || previewRequest != nil else { return }
            let request = previewRequest
            isLoading = true
            error = nil
            defer { if previewRequest == request { isLoading = false } }
            do {
                let decoded = try await MarrMediaLoader.load(item, maximumPixelDimension: 1600)
                try Task.checkCancellation()
                preview = NSImage(cgImage: decoded.image, size: .zero)
            } catch is CancellationError {
                // A removed or changed artifact must not update its old preview.
            } catch {
                if !Task.isCancelled {
                    self.error = (error as? MarrMediaLoadError)?.localizedDescription
                        ?? MarrMediaLoadError.unavailable.localizedDescription
                }
            }
        }
    }

    @ViewBuilder private var actions: some View {
        Button { previewRequest = UUID() } label: {
            Label(error != nil ? "Retry preview" : preview == nil ? (label.isEmpty ? "Preview image" : "Preview \(label)") : "Reload preview",
                  marrSymbol: "photo")
        }
        .disabled(isLoading || item == nil)
        Button("Open viewer", action: showViewer).disabled(item == nil)
        if isLoading { ProgressView().controlSize(.small) }
        if let url = CodexResourceAccess.url(for: source) {
            Button(url.isFileURL ? "Show in Finder" : "Open image") { CodexResourceAccess.open(url) }
        }
    }

    private func showViewer() {
        guard let item else { return }
        MarrMediaViewer.show(items: [item])
    }
}
