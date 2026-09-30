import Foundation
import AppKit
import Darwin
import MarrCore
import CryptoKit
import PDFKit

struct CodexActivity: Identifiable, Equatable, Codable {
    enum Kind: String, Codable, Equatable {
        case status
        case plan
        case command
        case fileChange
        case user
        case message
        case error

        var symbolName: String {
            switch self {
            case .status: "circle.fill"
            case .plan: "list.bullet.clipboard"
            case .command: "terminal"
            case .fileChange: "doc.badge.gearshape"
            case .user: "person.fill"
            case .message: "text.bubble"
            case .error: "exclamationmark.triangle.fill"
            }
        }
    }

    let id: UUID
    let kind: Kind
    var title: String
    var detail: String
    var isComplete: Bool
    var processingSeconds: Int?
    var turnID: String?

    init(
        id: UUID = UUID(),
        kind: Kind,
        title: String,
        detail: String = "",
        isComplete: Bool = true,
        processingSeconds: Int? = nil,
        turnID: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.isComplete = isComplete
        self.processingSeconds = processingSeconds
        self.turnID = turnID
    }
}

struct CodexApprovalRequest: Identifiable, Equatable {
    enum Kind: Equatable {
        case command
        case fileChange

        var title: String {
            switch self {
            case .command: "Allow Codex command?"
            case .fileChange: "Allow Codex file changes?"
            }
        }
    }

    let id: Int
    let kind: Kind
    let reason: String?
    let preview: String?
}

struct CodexModelOption: Identifiable, Equatable {
    let id: String
    let name: String
    var reasoningEfforts: [String] = []
    var defaultReasoningEffort: String? = nil

    static func parse(_ rows: [[String: Any]]) -> [Self] {
        var seen = Set<String>()
        return rows.compactMap { row in
            guard let id = (row["model"] as? String ?? row["id"] as? String),
                  !id.isEmpty, seen.insert(id).inserted else { return nil }
            let name = (row["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return Self(
                id: id,
                name: name.flatMap { $0.isEmpty ? nil : $0 } ?? id,
                reasoningEfforts: (row["supportedReasoningEfforts"] as? [[String: Any]] ?? [])
                    .compactMap { $0["reasoningEffort"] as? String },
                defaultReasoningEffort: row["defaultReasoningEffort"] as? String
            )
        }
    }
}

enum CodexRuntime {
    // Desktop builds can carry protocol/history capabilities that older npm CLIs lack.
    static let automaticPaths = [
        "/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex",
        "/Applications/Codex.app/Contents/Resources/codex",
        "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
        "/Applications/ChatGPT.app/Contents/Resources/codex",
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
        "/usr/bin/codex"
    ]

    static func executableURLs(preferred: URL?) -> [URL] {
        var seen = Set<String>()
        return ([preferred].compactMap { $0 } + automaticPaths.map(URL.init(fileURLWithPath:)))
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}

@MainActor
final class CodexWorkspaceController: ObservableObject {
    @Published private(set) var workspaceURL: URL?
    @Published private(set) var workspaceDisplayName = "No workspace selected"
    @Published private(set) var codexCLIURL: URL?
    @Published private(set) var codexCLIDisplayName = "Automatic"
    @Published private(set) var appServerURLString = ""
    @Published private(set) var instructionSources: [String] = []
    @Published private(set) var activities: [CodexActivity] = []
    @Published private(set) var latestDiff = ""
    @Published private(set) var latestAgentMessage = ""
    @Published private(set) var statusMessage = "Choose a workspace to start a Codex task."
    @Published private(set) var isRunning = false
    @Published private(set) var isRemoteTaskActive = false
    @Published private(set) var runtimeDescription = "Not connected"
    @Published private(set) var selectedReasoningEffort: String? = nil
    @Published private(set) var isReadingSelectedTask = false
    @Published private(set) var isLoadingTaskHistory = false
    @Published private(set) var isLoadingProjects = false
    @Published private(set) var lastProjectSyncAt: Date?
    @Published private(set) var taskStartedAt: Date?
    @Published private(set) var taskFinishedAt: Date?
    @Published private(set) var savedTasks: [CodexSavedTask] = []
    @Published private(set) var savedWorkspaces: [CodexSavedWorkspace] = []
    @Published var approvalRequest: CodexApprovalRequest?
    @Published private(set) var gitWorkspaceSummary = "Git status unavailable"
    @Published private(set) var selectedModel = "gpt-5.6-terra"
    @Published private(set) var availableModels: [CodexModelOption] = []
    @Published private(set) var isLoadingModels = false
    @Published private(set) var modelLoadError: String?
    private var listedModels: [CodexModelOption] = []
    private var connectionReady = false
    private var runtimeFingerprint: String?
    private var lastModelRefresh: Date?
    private var conversationRequests = 0
    let workbench = CodexWorkbenchStore()

    private enum PendingRequest {
        case initialize
        case listModels
        case listProjects
        case startThread
        case resumeThread
        case startTurn
        case listThreads
        case readThread(String)
    }

    private enum ConnectionIntent {
        case listModels
        case listProjects
        case submit
        case listThreads
        case readThread(String)
    }

    private let bookmarkKey = "codex.workspace.bookmark"
    private let bookmarkNameKey = "codex.workspace.name"
    private let cliBookmarkKey = "codex.cli.bookmark"
    private let cliBookmarkNameKey = "codex.cli.name"
    private let appServerURLKey = "codex.app-server.url"
    private let appServerURLIsManualKey = "codex.app-server.url.is-manual"
    private let selectedModelKey = "codex.task.model"
    private let appServerServiceName = "marr_visual_task_bridge"
    private var securityScopedURL: URL?
    private var appServerURLIsManual = false
    private var codexCLISecurityScopedURL: URL?
    private var process: Process?
    private var standardInput: FileHandle?
    private var webSocket: URLSessionWebSocketTask?
    private var webSocketReceiveTask: Task<Void, Never>?
    private var delayedConnectionTask: Task<Void, Never>?
    private var helperDiagnosticURL: URL?
    private var hasManagedBackgroundServer = false
    private var outputBuffer = Data()
    private var requestID = 0
    private var pendingRequests: [Int: PendingRequest] = [:]
    private var threadID: String?
    private var activeTurnID: String?
    private var queuedPrompt: String?
    private var queuedImagePaths: [String] = []
    private var activityIDsByServerItemID: [String: UUID] = [:]
    private var activeTaskID: UUID?
    private var needsThreadResume = false
    private var connectionIntent: ConnectionIntent?
    private var threadListCursor: String?
    private var listedThreads: [[String: Any]] = []
    private var historyWorkspace: CodexSavedWorkspace?
    private var remainingHistoryWorkspaces: [CodexSavedWorkspace] = []

    init() {
        appServerURLString = UserDefaults.standard.string(forKey: appServerURLKey) ?? ""
        appServerURLIsManual = UserDefaults.standard.bool(forKey: appServerURLIsManualKey)
        selectedModel = UserDefaults.standard.string(forKey: selectedModelKey) ?? "gpt-5.6-terra"
        restoreWorkspaceAccess()
        restoreCodexCLIPath()
        savedTasks = workbench.tasks.filter { !workbench.isTaskArchived($0.id) }
        savedWorkspaces = workbench.workspaces
        if let savedTask = workbench.selectedTask {
            restoreSavedTask(savedTask)
        }
    }

    deinit {
        securityScopedURL?.stopAccessingSecurityScopedResource()
        codexCLISecurityScopedURL?.stopAccessingSecurityScopedResource()
        webSocketReceiveTask?.cancel()
        webSocket?.cancel(with: .goingAway, reason: nil)
        delayedConnectionTask?.cancel()
        process?.terminate()
    }

    var canSubmit: Bool {
        guard !isRunning, !isRemoteTaskActive, !isReadingSelectedTask else { return false }
        if case .readThread = connectionIntent { return false }
        return true
    }

    var hasWorkspace: Bool {
        workspaceURL != nil
    }

    var usesExternalAppServer: Bool {
        appServerURLIsManual && !appServerURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var usesManagedBackgroundServer: Bool {
        !appServerURLIsManual && !appServerURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func refreshModelsIfNeeded() {
        let changed = currentRuntimeFingerprint() != runtimeFingerprint
        guard !connectionReady || changed || lastModelRefresh == nil || Date().timeIntervalSince(lastModelRefresh!) > 300 else { return }
        refreshModels()
    }

    private func currentRuntimeFingerprint() -> String? {
        guard let url = codexExecutableURLs().first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }),
              let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        else { return nil }
        return "\(url.path)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values.fileSize ?? 0)"
    }

    private func adoptUpdatedRuntimeIfIdle() {
        guard !usesExternalAppServer, !isRunning, !isRemoteTaskActive, conversationRequests == 0,
              !isLoadingTaskHistory, !isLoadingProjects, !isReadingSelectedTask,
              let fingerprint = currentRuntimeFingerprint(), fingerprint != runtimeFingerprint else { return }
        let previousThread = threadID
        stopAppServer()
        threadID = previousThread
        needsThreadResume = previousThread != nil
        let digest = Array(SHA256.hash(data: Data(fingerprint.utf8)))
        let value = Int(digest[0]) * 256 + Int(digest[1])
        let port = 20000 + value % 20000
        saveAppServerURL("ws://127.0.0.1:\(port)", isManual: false)
        hasManagedBackgroundServer = false
        runtimeFingerprint = fingerprint
    }

    func conversationEndpoint() async throws -> URL {
        refreshModelsIfNeeded()
        for _ in 0..<300 {
            try Task.checkCancellation()
            if connectionReady, !isLoadingModels, let url = localAppServerURL {
                guard !availableModels.isEmpty else { throw UserFacingError(modelLoadError ?? "No Codex models available.") }
                return url
            }
            if let modelLoadError, !isLoadingModels { throw UserFacingError(modelLoadError) }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw UserFacingError("Codex connection timed out. Check the desktop login and try again.")
    }

    func conversationResponse(_ request: VisionRequest) async throws -> String {
        let endpoint = try await conversationEndpoint()
        conversationRequests += 1
        defer { conversationRequests -= 1 }
        return try await CodexConversationClient(endpoint: endpoint).respond(
            to: request, model: selectedModel, effort: selectedReasoningEffort)
    }

    func refreshModels() {
        adoptUpdatedRuntimeIfIdle()
        guard !isLoadingModels else { return }
        isLoadingModels = true
        modelLoadError = nil
        listedModels = []
        if connectionReady {
            sendModelsPage()
        } else {
            if connectionIntent == nil { connectionIntent = .listModels }
            connectForCurrentIntent()
        }
    }

    private func sendModelsPage(cursor: String? = nil) {
        var params: [String: Any] = ["limit": 100, "includeHidden": false]
        if let cursor { params["cursor"] = cursor }
        sendRequest(method: "model/list", params: params, pending: .listModels)
    }

    var activeTaskTitle: String {
        guard let activeTaskID,
              let task = savedTasks.first(where: { $0.id == activeTaskID }),
              !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return "New Work" }
        return task.title
    }

    var selectedModelName: String {
        availableModels.first { $0.id == selectedModel }?.name ?? selectedModel
    }

    func selectModel(_ model: String) {
        guard !isRunning, availableModels.contains(where: { $0.id == model }) else { return }
        selectedModel = model
        UserDefaults.standard.set(model, forKey: selectedModelKey)
        selectedReasoningEffort = availableModels.first { $0.id == model }?.defaultReasoningEffort
    }

    var availableReasoningEfforts: [String] {
        availableModels.first { $0.id == selectedModel }?.reasoningEfforts ?? []
    }

    func selectReasoningEffort(_ effort: String) {
        guard !isRunning, availableReasoningEfforts.contains(effort) else { return }
        selectedReasoningEffort = effort
    }

    func useDesktopRuntime() {
        guard !isRunning, conversationRequests == 0 else { return }
        runtimeFingerprint = nil
        useAutomaticCodexCLIPath()
        saveAppServerURL("", isManual: false)
        hasManagedBackgroundServer = false
        refreshModels()
    }

    func refreshSelectedTask() {
        guard !isRunning, !isReadingSelectedTask, let threadID else { return }
        connectionIntent = .readThread(threadID)
        connectForCurrentIntent()
    }

    func setAppServerURL(_ value: String) {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedValue != appServerURLString else { return }
        stopAppServer()
        saveAppServerURL(trimmedValue, isManual: !trimmedValue.isEmpty)
        statusMessage = trimmedValue.isEmpty
            ? "Marr will start a background Codex app-server when needed."
            : "Marr will connect to the local Codex app-server."
    }

    /// Launch an embedded, LSBackgroundOnly helper. Unlike a child Process, the
    /// helper has its own entitlement boundary and can use the normal Codex CLI
    /// login without displaying Terminal or requesting Automation permission.
    func startAppServerInBackground() {
        let serverURL: URL
        if appServerURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            serverURL = URL(string: "ws://127.0.0.1:4511")!
        } else if let configuredURL = localAppServerURL {
            serverURL = configuredURL
        } else {
            statusMessage = CodexWorkspaceError.invalidAppServerURL.localizedDescription
            finishWithError(statusMessage)
            return
        }

        if hasManagedBackgroundServer {
            statusMessage = "Connecting to the background Codex app-server…"
            connectToAppServer(at: serverURL)
            return
        }

        let executableURLs = codexExecutableURLs()
        guard !executableURLs.isEmpty
        else {
            let message = "Codex CLI was not found. Choose its executable in Settings, then try again."
            statusMessage = message
            finishWithError(message)
            return
        }

        let helperURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LoginItems/MarrCodexServer.app")
        guard FileManager.default.fileExists(atPath: helperURL.path) else {
            let message = "The Marr Codex background helper is missing. Rebuild Marr and try again."
            statusMessage = message
            finishWithError(message)
            return
        }

        saveAppServerURL(serverURL.absoluteString, isManual: appServerURLIsManual)
        statusMessage = "Starting the background Codex app-server…"
        let helperDirectory = FileManager.default.temporaryDirectory
        let helperConfigurationURL = helperDirectory.appendingPathComponent("MarrCodexServer.json")
        let diagnosticURL = helperDirectory.appendingPathComponent("MarrCodexServer.log")
        let helperConfiguration: [String: Any] = [
            "codexPaths": executableURLs.map(\.path),
            "listenURL": serverURL.absoluteString,
            "diagnosticPath": diagnosticURL.path
        ]
        do {
            let configurationData = try JSONSerialization.data(withJSONObject: helperConfiguration)
            try configurationData.write(to: helperConfigurationURL, options: .atomic)
            try? FileManager.default.removeItem(at: diagnosticURL)
        } catch {
            let message = "Could not prepare the Codex background helper: \(error.localizedDescription)"
            statusMessage = message
            finishWithError(message)
            return
        }
        helperDiagnosticURL = diagnosticURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--configuration", helperConfigurationURL.path]
        NSWorkspace.shared.openApplication(at: helperURL, configuration: configuration) { [weak self] application, error in
            Task { @MainActor in
                guard let self else { return }
                if let error, !self.connectionReady {
                    let message = "Could not start the Codex background helper: \(error.localizedDescription)"
                    self.statusMessage = message
                    self.finishWithError(message)
                    return
                }
                if let launchedURL = application?.bundleURL, launchedURL.standardizedFileURL != helperURL.standardizedFileURL {
                    self.finishWithError("macOS launched a different Marr helper: \(launchedURL.path)")
                    return
                }
            }
        }
        // A windowless Foundation helper may never send LaunchServices' app-ready
        // notification. Its HTTP readiness endpoint is the actual launch signal.
        connectToNewLocalAppServer(at: serverURL)
    }

    private func saveAppServerURL(_ value: String, isManual: Bool) {
        appServerURLString = value
        appServerURLIsManual = isManual
        UserDefaults.standard.set(value, forKey: appServerURLKey)
        UserDefaults.standard.set(isManual, forKey: appServerURLIsManualKey)
    }

    @discardableResult
    func chooseWorkspace() -> Bool {
        let panel = NSOpenPanel()
        panel.title = "Choose a workspace for Codex"
        panel.message = "Codex can read and modify files only in this folder."
        panel.prompt = "Use Workspace"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else {
            return false
        }

        do {
            try setWorkspace(url)
            startNewTask()
            return true
        } catch {
            statusMessage = "Could not save workspace access: \(error.localizedDescription)"
            appendActivity(kind: .error, title: "Workspace access failed", detail: error.localizedDescription)
            return false
        }
    }

    func clearWorkspace() {
        stopAppServer()
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
        workspaceURL = nil
        workspaceDisplayName = "No workspace selected"
        instructionSources = []
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        UserDefaults.standard.removeObject(forKey: bookmarkNameKey)
        statusMessage = "Workspace access removed."
    }

    func selectWorkspace(_ savedWorkspace: CodexSavedWorkspace) {
        guard !isRunning else {
            statusMessage = "Finish or stop the current Codex task before switching workspaces."
            return
        }
        do {
            try activateWorkspace(savedWorkspace)
            startNewTask()
        } catch {
            statusMessage = "Could not open \(savedWorkspace.name): \(error.localizedDescription)"
        }
    }

    func startNewTask() {
        guard !isRunning else {
            statusMessage = "Codex is still working on the current task."
            return
        }
        activeTaskID = nil
        isRemoteTaskActive = false
        needsThreadResume = false
        threadID = nil
        activeTurnID = nil
        latestAgentMessage = ""
        latestDiff = ""
        activities = []
        activityIDsByServerItemID = [:]
        approvalRequest = nil
        taskStartedAt = nil
        taskFinishedAt = nil
        statusMessage = "New Codex task ready."
    }

    func toggleWorkspacePinned(_ workspace: CodexSavedWorkspace) {
        workbench.toggleWorkspacePinned(workspace.id)
        refreshSavedWorkspaces()
    }

    func showWorkspaceInFinder(_ workspace: CodexSavedWorkspace) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: workspace.path)])
    }

    func archiveChats(in workspace: CodexSavedWorkspace) {
        workbench.archiveTasks(in: workspace.id)
        refreshSavedTasks()
        statusMessage = "Archived chats in \(workspace.name)."
    }

    func removeWorkspace(_ workspace: CodexSavedWorkspace) {
        guard !isRunning else {
            statusMessage = "Finish the active Codex task before removing a workspace."
            return
        }
        if workbench.selectedWorkspaceID == workspace.id {
            clearWorkspace()
        }
        workbench.removeWorkspace(workspace.id)
        refreshSavedWorkspaces()
        refreshSavedTasks()
        statusMessage = "Removed \(workspace.name)."
    }

    func loadTaskHistory() {
        guard !isRunning else {
            statusMessage = "Finish or stop the current Codex task before loading history."
            return
        }
        guard workspaceURL != nil else {
            statusMessage = "Choose a Codex workspace first."
            return
        }

        guard let workspace = workbench.selectedWorkspace else { return }
        beginHistoryLoad(for: [workspace])
    }

    func loadTaskHistory(for workspace: CodexSavedWorkspace) {
        guard !isRunning, !isLoadingTaskHistory else { return }
        beginHistoryLoad(for: [workspace])
    }

    func loadAllTaskHistory() {
        guard !isRunning, !isLoadingTaskHistory, !isLoadingProjects else { return }
        isLoadingProjects = true
        connectionIntent = .listProjects
        connectForCurrentIntent()
    }

    private func sendProjectsPage(cursor: String? = nil) {
        var params: [String: Any] = [:]
        if let cursor { params["cursor"] = cursor }
        sendRequest(method: "project/list", params: params, pending: .listProjects)
    }

    private func beginHistoryLoad(for workspaces: [CodexSavedWorkspace]) {
        guard !isLoadingTaskHistory else { return }
        guard let firstWorkspace = workspaces.first else {
            statusMessage = "Choose a Codex workspace first."
            return
        }

        isLoadingTaskHistory = true
        statusMessage = "Loading Codex task history…"
        historyWorkspace = firstWorkspace
        remainingHistoryWorkspaces = Array(workspaces.dropFirst())
        threadListCursor = nil
        listedThreads = []
        connectionIntent = .listThreads
        connectForCurrentIntent()
    }

    func selectTask(_ task: CodexSavedTask) {
        guard !isRunning else {
            statusMessage = "Finish or stop the current Codex task before switching tasks."
            return
        }
        guard let savedWorkspace = workbench.workspaces.first(where: { $0.id == task.workspaceID }) else {
            statusMessage = "The workspace for this Codex task is no longer available."
            return
        }
        do {
            try activateWorkspace(savedWorkspace)
            workbench.selectTask(task.id)
            restoreSavedTask(task)
            if let threadID = task.threadID {
                connectionIntent = .readThread(threadID)
                statusMessage = "Loading Codex task…"
                connectForCurrentIntent()
            }
        } catch {
            statusMessage = "Could not open this Codex task: \(error.localizedDescription)"
        }
    }

    func chooseCodexCLI() {
        let panel = NSOpenPanel()
        panel.title = "Choose the Codex CLI executable"
        panel.message = "Select the codex command installed on this Mac."
        panel.prompt = "Use Codex CLI"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try setCodexCLI(url)
            statusMessage = "Using Codex CLI at \(url.path)"
        } catch {
            statusMessage = "Could not save Codex CLI access: \(error.localizedDescription)"
        }
    }

    func useAutomaticCodexCLIPath() {
        stopAppServer()
        codexCLISecurityScopedURL?.stopAccessingSecurityScopedResource()
        codexCLISecurityScopedURL = nil
        codexCLIURL = nil
        codexCLIDisplayName = "Automatic"
        UserDefaults.standard.removeObject(forKey: cliBookmarkKey)
        UserDefaults.standard.removeObject(forKey: cliBookmarkNameKey)
        statusMessage = "Codex CLI path set to automatic detection."
    }

    func submit(prompt rawPrompt: String, images: [ConversationImageAsset]) {
        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        guard let workspaceURL else {
            statusMessage = "Choose a Codex workspace first."
            chooseWorkspace()
            return
        }
        guard canSubmit else {
            statusMessage = "Wait for the active task to finish, then refresh."
            return
        }

        do {
            queuedPrompt = prompt
            queuedImagePaths = try persistImageInputs(images)
            if activeTaskID == nil {
                guard let workspaceID = workbench.selectedWorkspaceID else {
                    throw CodexWorkspaceError.accessDenied
                }
                activeTaskID = workbench.createTask(workspaceID: workspaceID, prompt: prompt).id
                refreshSavedTasks()
                threadID = nil
                needsThreadResume = false
            }
            latestAgentMessage = ""
            latestDiff = ""
            activities = []
            activityIDsByServerItemID = [:]
            approvalRequest = nil
            isRunning = true
            taskStartedAt = Date()
            taskFinishedAt = nil
            appendActivity(kind: .status, title: "Preparing Codex task", detail: workspaceURL.path, isComplete: false)
            syncActiveTask(state: .running)
            connectionIntent = .submit
            connectForCurrentIntent()
        } catch {
            finishWithError(error.localizedDescription)
        }
    }

    func respondToApproval(accept: Bool) {
        guard let approvalRequest else { return }
        sendResponse(
            id: approvalRequest.id,
            result: ["decision": accept ? "accept" : "decline"]
        )
        appendActivity(
            kind: .status,
            title: accept ? "Approval granted" : "Approval declined",
            detail: approvalRequest.preview ?? approvalRequest.reason ?? ""
        )
        self.approvalRequest = nil
    }

    func interrupt() {
        guard let threadID, isRunning else { return }
        sendRequest(method: "turn/interrupt", params: ["threadId": threadID])
        statusMessage = "Stopping Codex…"
    }

    private func setWorkspace(_ url: URL) throws {
        stopAppServer()
        securityScopedURL?.stopAccessingSecurityScopedResource()
        let normalizedURL = url.standardizedFileURL
        guard normalizedURL.startAccessingSecurityScopedResource() else {
            throw CodexWorkspaceError.accessDenied
        }
        do {
            let bookmark = try normalizedURL.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
            UserDefaults.standard.set(normalizedURL.lastPathComponent, forKey: bookmarkNameKey)
            securityScopedURL = normalizedURL
            workspaceURL = normalizedURL
            workspaceDisplayName = normalizedURL.lastPathComponent
            _ = workbench.upsertWorkspace(url: normalizedURL, bookmark: bookmark)
            refreshSavedWorkspaces()
            refreshGitWorkspaceSummary()
        } catch {
            normalizedURL.stopAccessingSecurityScopedResource()
            throw error
        }
    }

    private func restoreWorkspaceAccess() {
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        if bookmark.isEmpty, let selected = workbench.selectedWorkspace {
            workspaceURL = URL(fileURLWithPath: selected.path)
            workspaceDisplayName = selected.name
            return
        }
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            guard url.startAccessingSecurityScopedResource() else {
                throw CodexWorkspaceError.accessDenied
            }
            securityScopedURL = url
            workspaceURL = url
            workspaceDisplayName = UserDefaults.standard.string(forKey: bookmarkNameKey) ?? url.lastPathComponent
            _ = workbench.upsertWorkspace(url: url, bookmark: bookmark)
            refreshSavedWorkspaces()
            refreshGitWorkspaceSummary()
            if isStale {
                try setWorkspace(url)
            }
        } catch {
            statusMessage = "Choose the Codex workspace again to restore access."
        }
    }

    private func restoreSavedTask(_ task: CodexSavedTask) {
        activeTaskID = task.id
        threadID = task.threadID
        needsThreadResume = task.threadID != nil
        latestAgentMessage = task.latestAgentMessage
        latestDiff = task.latestDiff
        activities = task.activities
        activityIDsByServerItemID = [:]
        approvalRequest = nil
        taskStartedAt = task.createdAt
        taskFinishedAt = task.state == .running ? nil : task.updatedAt
        statusMessage = task.statusMessage
    }

    private func activateWorkspace(_ savedWorkspace: CodexSavedWorkspace) throws {
        stopAppServer()
        securityScopedURL?.stopAccessingSecurityScopedResource()
        if savedWorkspace.bookmark.isEmpty {
            securityScopedURL = nil
            workspaceURL = URL(fileURLWithPath: savedWorkspace.path)
            workspaceDisplayName = savedWorkspace.name
            workbench.selectWorkspace(savedWorkspace.id)
            UserDefaults.standard.set(Data(), forKey: bookmarkKey)
            UserDefaults.standard.set(savedWorkspace.name, forKey: bookmarkNameKey)
            refreshSavedWorkspaces()
            gitWorkspaceSummary = ""
            return
        }
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: savedWorkspace.bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        guard url.startAccessingSecurityScopedResource() else {
            throw CodexWorkspaceError.accessDenied
        }
        securityScopedURL = url
        workspaceURL = url
        workspaceDisplayName = savedWorkspace.name
        UserDefaults.standard.set(savedWorkspace.bookmark, forKey: bookmarkKey)
        UserDefaults.standard.set(savedWorkspace.name, forKey: bookmarkNameKey)
        workbench.selectWorkspace(savedWorkspace.id)
        refreshSavedWorkspaces()
        if isStale {
            try setWorkspace(url)
        } else {
            refreshGitWorkspaceSummary()
        }
    }

    private func setCodexCLI(_ url: URL) throws {
        stopAppServer()
        codexCLISecurityScopedURL?.stopAccessingSecurityScopedResource()
        let normalizedURL = url.standardizedFileURL
        guard normalizedURL.startAccessingSecurityScopedResource() else {
            throw CodexWorkspaceError.accessDenied
        }
        do {
            let bookmark = try normalizedURL.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: cliBookmarkKey)
            UserDefaults.standard.set(normalizedURL.lastPathComponent, forKey: cliBookmarkNameKey)
            codexCLISecurityScopedURL = normalizedURL
            codexCLIURL = normalizedURL
            codexCLIDisplayName = normalizedURL.path
        } catch {
            normalizedURL.stopAccessingSecurityScopedResource()
            throw error
        }
    }

    private func restoreCodexCLIPath() {
        guard let bookmark = UserDefaults.standard.data(forKey: cliBookmarkKey) else { return }
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            guard url.startAccessingSecurityScopedResource() else {
                throw CodexWorkspaceError.accessDenied
            }
            codexCLISecurityScopedURL = url
            codexCLIURL = url
            codexCLIDisplayName = url.path
            if isStale {
                try setCodexCLI(url)
            }
        } catch {
            codexCLIDisplayName = "Automatic (saved path unavailable)"
        }
    }

    private func connectForCurrentIntent() {
        if process != nil || webSocket != nil {
            if connectionReady { performConnectionIntent() }
            return
        }

        let configuredURL = appServerURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        if appServerURLIsManual, !configuredURL.isEmpty {
            guard let url = localAppServerURL else {
                finishWithError(CodexWorkspaceError.invalidAppServerURL.localizedDescription)
                return
            }
            connectToAppServer(at: url)
        } else {
            startAppServerInBackground()
        }
    }

    private func performConnectionIntent() {
        switch connectionIntent {
        case .listModels:
            break // Model discovery is sent after initialization.
        case .listProjects:
            sendProjectsPage()
        case .listThreads:
            sendListThreads()
        case .readThread(let threadID):
            sendReadThread(threadID)
        case .submit, nil:
            if needsThreadResume {
                sendResumeThread()
            } else if threadID == nil {
                sendStartThread()
            } else {
                sendStartTurn()
            }
        }
    }

    private func launchAppServer(in workspaceURL: URL) throws {
        var failures: [String] = []
        for executableURL in codexExecutableURLs() {
            let process = Process()
            process.executableURL = executableURL
            process.arguments = ["app-server", "--listen", "stdio://"]
            process.currentDirectoryURL = workspaceURL
            let input = Pipe()
            let output = Pipe()
            let errors = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errors

            output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                Task { @MainActor in self?.consumeOutput(data) }
            }
            errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                Task { @MainActor in
                    self?.appendActivity(kind: .error, title: "Codex app-server", detail: text.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
            process.terminationHandler = { [weak self] finishedProcess in
                Task { @MainActor in self?.handleProcessTermination(finishedProcess) }
            }

            do {
                try process.run()
            } catch {
                output.fileHandleForReading.readabilityHandler = nil
                errors.fileHandleForReading.readabilityHandler = nil
                failures.append("\(executableURL.path): \(error.localizedDescription)")
                continue
            }

            self.process = process
            standardInput = input.fileHandleForWriting
            statusMessage = "Connecting to Codex…"
            sendRequest(
                method: "initialize",
                params: [
                    "clientInfo": [
                        "name": "marr",
                        "title": "Marr Visual Task Bridge",
                        "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
                    ],
                    "capabilities": ["experimentalApi": true]
                ],
                pending: .initialize
            )
            return
        }
        throw CodexWorkspaceError.launchFailed("Codex CLI", failures.joined(separator: "\n"))
    }

    /// Connect to a Codex app-server started outside the App Sandbox. This is
    /// useful because the local CLI's ChatGPT credentials normally live in
    /// places that a sandboxed GUI app cannot read.
    private func connectToAppServer(at url: URL) {
        let socket = URLSession.shared.webSocketTask(with: url)
        socket.resume()
        webSocket = socket
        statusMessage = "Connecting to local Codex app-server…"

        webSocketReceiveTask = Task { @MainActor [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    guard let self else { return }
                    switch message {
                    case .string(let text):
                        self.consumeWebSocketMessage(Data(text.utf8))
                    case .data(let data):
                        self.consumeWebSocketMessage(data)
                    @unknown default:
                        break
                    }
                }
            } catch {
                guard !Task.isCancelled, self?.webSocket === socket else { return }
                self?.connectionReady = false
                self?.webSocket = nil
                self?.finishWithError("Codex app-server connection closed: \(error.localizedDescription)")
            }
        }

        sendRequest(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "marr",
                    "title": "Marr Visual Task Bridge",
                    "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
                ],
                "capabilities": ["experimentalApi": true]
            ],
            pending: .initialize
        )
    }

    /// The background helper needs a brief moment to bind the socket after it
    /// launches the CLI. Delay the first connection so setup stays invisible.
    private func connectToNewLocalAppServer(at url: URL) {
        delayedConnectionTask?.cancel()
        statusMessage = "Starting Codex…"
        delayedConnectionTask = Task { @MainActor [weak self] in
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
            components.scheme = url.scheme == "wss" ? "https" : "http"
            components.path = "/readyz"
            guard let healthURL = components.url else { return }
            for _ in 0..<40 {
                guard !Task.isCancelled, let self, self.connectionIntent != nil,
                      self.webSocket == nil, self.process == nil else { return }
                var request = URLRequest(url: healthURL)
                request.timeoutInterval = 1
                if let (_, response) = try? await URLSession.shared.data(for: request),
                   (response as? HTTPURLResponse)?.statusCode == 200 {
                    self.hasManagedBackgroundServer = true
                    self.connectToAppServer(at: url)
                    return
                }
                do { try await Task.sleep(for: .milliseconds(250)) }
                catch { return }
            }
            guard let self, !Task.isCancelled else { return }
            self.hasManagedBackgroundServer = false
            self.finishWithError("Codex did not become ready. \(self.helperDiagnostic() ?? "Retry connection.")")
        }
    }

    private var localAppServerURL: URL? {
        let rawValue = appServerURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: rawValue),
              ["ws", "wss"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(),
              ["localhost", "127.0.0.1", "::1"].contains(host)
        else {
            return nil
        }
        return url
    }

    /// `FileManager.isExecutableFile(atPath:)` can return false for Homebrew
    /// paths from inside an App Sandbox, even though `Process` can launch the
    /// user-installed executable. Let the actual launch provide the diagnosis.
    private func codexExecutableURLs() -> [URL] {
        CodexRuntime.executableURLs(preferred: codexCLIURL)
    }

    private func sendStartThread() {
        guard let workspaceURL else { return }
        sendRequest(
            method: "thread/start",
            params: [
                "cwd": workspaceURL.path,
                "model": selectedModel,
                "approvalPolicy": "on-request",
                "sandbox": "workspace-write",
                "serviceName": appServerServiceName
            ],
            pending: .startThread
        )
    }

    private func sendResumeThread() {
        guard let threadID else {
            sendStartThread()
            return
        }
        sendRequest(
            method: "thread/resume",
            params: ["threadId": threadID, "model": selectedModel],
            pending: .resumeThread
        )
    }

    private func sendListThreads() {
        guard let historyWorkspace else {
            isLoadingTaskHistory = false
            return
        }
        var params: [String: Any] = [
            "cwd": historyWorkspace.path,
            "limit": 100,
            "sortKey": "updated_at",
            "sourceKinds": ["vscode", "cli", "appServer"]
        ]
        if let threadListCursor {
            params["cursor"] = threadListCursor
        }
        sendRequest(method: "thread/list", params: params, pending: .listThreads)
    }

    private func sendReadThread(_ threadID: String) {
        guard !isReadingSelectedTask else { return }
        isReadingSelectedTask = true
        sendRequest(
            method: "thread/read",
            params: ["threadId": threadID, "includeTurns": true],
            pending: .readThread(threadID)
        )
    }

    private func sendStartTurn() {
        guard let workspaceURL, let threadID, let prompt = queuedPrompt else { return }
        // Keep the user's message intact; Codex supplies its own harness and repo instructions.
        var input: [[String: Any]] = [["type": "text", "text": prompt]]
        input.append(contentsOf: queuedImagePaths.map { ["type": "localImage", "path": $0] })

        var params: [String: Any] = [
                "threadId": threadID,
                "cwd": workspaceURL.path,
                "model": selectedModel,
                "input": input,
                "approvalPolicy": "on-request",
                "sandboxPolicy": [
                    "type": "workspaceWrite",
                    "writableRoots": [workspaceURL.path],
                    "networkAccess": false
                ]
            ]
        if let selectedReasoningEffort { params["effort"] = selectedReasoningEffort }
        sendRequest(method: "turn/start", params: params, pending: .startTurn)
        statusMessage = "Codex is working in \(workspaceDisplayName)."
    }

    private func persistImageInputs(_ images: [ConversationImageAsset]) throws -> [String] {
        let imageAssets = images.filter(\.isImage)
        guard !imageAssets.isEmpty else { return [] }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Marr-Codex-Inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        return try imageAssets.map { asset in
            let extensionName = URL(fileURLWithPath: asset.fileName).pathExtension.isEmpty
                ? "png"
                : URL(fileURLWithPath: asset.fileName).pathExtension
            let url = directory.appendingPathComponent("\(asset.id.uuidString).\(extensionName)")
            try asset.data.write(to: url, options: .atomic)
            return url.path
        }
    }

    private func consumeOutput(_ data: Data) {
        outputBuffer.append(data)
        while let newlineIndex = outputBuffer.firstIndex(of: 0x0A) {
            let lineData = outputBuffer.prefix(upTo: newlineIndex)
            outputBuffer.removeSubrange(...newlineIndex)
            guard !lineData.isEmpty else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: lineData),
                  let message = object as? [String: Any]
            else {
                appendActivity(kind: .error, title: "Invalid Codex event", detail: String(data: lineData, encoding: .utf8) ?? "")
                continue
            }
            handleMessage(message)
        }
    }

    private func consumeWebSocketMessage(_ data: Data) {
        var newlineDelimitedData = data
        if newlineDelimitedData.last != 0x0A {
            newlineDelimitedData.append(0x0A)
        }
        consumeOutput(newlineDelimitedData)
    }

    private func handleMessage(_ message: [String: Any]) {
        if let id = message["id"] as? Int, message["result"] != nil || message["error"] != nil {
            handleResponse(id: id, message: message)
            return
        }

        guard let method = message["method"] as? String else { return }
        let params = message["params"] as? [String: Any] ?? [:]
        if let id = message["id"] as? Int {
            handleServerRequest(id: id, method: method, params: params)
        } else {
            handleNotification(method: method, params: params)
        }
    }

    private func handleResponse(id: Int, message: [String: Any]) {
        if let error = message["error"] as? [String: Any] {
            let pending = pendingRequests.removeValue(forKey: id)
            if case .readThread = pending {
                isReadingSelectedTask = false
                statusMessage = "Could not read Codex history. Use Desktop Codex in Settings or update your external server."
                connectionIntent = nil
                return // Reading history must not mark a real Codex task as failed.
            }
            if case .listProjects = pending {
                isLoadingProjects = false
                connectionIntent = nil
                statusMessage = "Project sync failed. Check the connected Codex runtime."
                if !workbench.workspaces.isEmpty { beginHistoryLoad(for: workbench.workspaces) }
                return
            }
            if case .listThreads = pending {
                isLoadingTaskHistory = false
                connectionIntent = nil
                statusMessage = error["message"] as? String ?? "Could not refresh history."
                return
            }
            if case .listModels = pending {
                isLoadingModels = false
                modelLoadError = error["message"] as? String ?? "Could not load models."
                return
            }
            finishWithError(error["message"] as? String ?? "Codex app-server request failed.")
            return
        }
        guard let pending = pendingRequests.removeValue(forKey: id),
              let result = message["result"] as? [String: Any]
        else { return }

        switch pending {
        case .initialize:
            sendNotification(method: "initialized", params: [:])
            connectionReady = true
            runtimeDescription = result["userAgent"] as? String ?? "Codex app-server"
            isLoadingModels = true
            listedModels = []
            sendModelsPage()
            performConnectionIntent()
        case .listModels:
            let page = CodexModelOption.parse(result["data"] as? [[String: Any]] ?? [])
            for model in page where !listedModels.contains(where: { $0.id == model.id }) {
                listedModels.append(model)
            }
            if let cursor = result["nextCursor"] as? String, !cursor.isEmpty {
                sendModelsPage(cursor: cursor)
            } else {
                availableModels = listedModels
                lastModelRefresh = Date()
                if !availableModels.contains(where: { $0.id == selectedModel }), let first = availableModels.first {
                    selectedModel = first.id
                    UserDefaults.standard.set(first.id, forKey: selectedModelKey)
                    selectedReasoningEffort = first.defaultReasoningEffort
                }
                if selectedReasoningEffort == nil {
                    selectedReasoningEffort = availableModels.first { $0.id == selectedModel }?.defaultReasoningEffort
                }
                isLoadingModels = false
                modelLoadError = availableModels.isEmpty ? "No models available." : nil
                if case .listModels = connectionIntent { connectionIntent = nil }
            }
        case .listProjects:
            workbench.importProjects(result["data"] as? [[String: Any]] ?? [])
            refreshSavedWorkspaces()
            if let cursor = result["nextCursor"] as? String, !cursor.isEmpty {
                sendProjectsPage(cursor: cursor)
            } else {
                isLoadingProjects = false
                lastProjectSyncAt = Date()
                connectionIntent = nil
                if !workbench.workspaces.isEmpty { beginHistoryLoad(for: workbench.workspaces) }
            }
        case .startThread:
            guard let thread = result["thread"] as? [String: Any], let id = thread["id"] as? String else {
                finishWithError("Codex did not return a thread id.")
                return
            }
            threadID = id
            needsThreadResume = false
            syncActiveTask(threadID: id)
            instructionSources = result["instructionSources"] as? [String] ?? []
            if !instructionSources.isEmpty {
                appendActivity(kind: .status, title: "Loaded workspace instructions", detail: instructionSources.joined(separator: "\n"))
            }
            sendStartTurn()
        case .resumeThread:
            guard let thread = result["thread"] as? [String: Any], let id = thread["id"] as? String else {
                finishWithError("Codex could not resume this task thread.")
                return
            }
            threadID = id
            needsThreadResume = false
            syncActiveTask(threadID: id)
            sendStartTurn()
        case .startTurn:
            if let turn = result["turn"] as? [String: Any] {
                activeTurnID = turn["id"] as? String
            }
        case .listThreads:
            listedThreads.append(contentsOf: result["data"] as? [[String: Any]] ?? [])
            if let cursor = result["nextCursor"] as? String, !cursor.isEmpty {
                threadListCursor = cursor
                sendListThreads()
            } else {
                finishCurrentHistoryWorkspace()
            }
        case .readThread(let requestedThreadID):
            isReadingSelectedTask = false
            guard let thread = result["thread"] as? [String: Any] else {
                finishWithError("Codex did not return the selected task history.")
                return
            }
            hydrateSelectedTask(from: thread, requestedThreadID: requestedThreadID)
            connectionIntent = nil
        }
    }

    private func handleServerRequest(id: Int, method: String, params: [String: Any]) {
        switch method {
        case "item/commandExecution/requestApproval":
            approvalRequest = CodexApprovalRequest(
                id: id,
                kind: .command,
                reason: params["reason"] as? String,
                preview: params["command"] as? String
            )
        case "item/fileChange/requestApproval":
            approvalRequest = CodexApprovalRequest(
                id: id,
                kind: .fileChange,
                reason: params["reason"] as? String,
                preview: params["grantRoot"] as? String
            )
        default:
            sendResponse(id: id, result: ["decision": "decline"])
            appendActivity(kind: .status, title: "Declined unsupported Codex request", detail: method)
        }
    }

    private func handleNotification(method: String, params: [String: Any]) {
        if let eventThread = params["threadId"] as? String, eventThread != threadID { return }
        switch method {
        case "turn/plan/updated":
            let plan = (params["plan"] as? [[String: Any]] ?? []).compactMap { step in
                guard let title = step["step"] as? String else { return nil }
                let status = step["status"] as? String ?? "pending"
                return "[\(status)] \(title)"
            }.joined(separator: "\n")
            appendActivity(kind: .plan, title: "Plan", detail: plan)

        case "turn/diff/updated":
            latestDiff = params["diff"] as? String ?? latestDiff
            appendActivity(kind: .fileChange, title: "Workspace diff updated", detail: latestDiff)
            syncActiveTask()

        case "item/started":
            if let item = params["item"] as? [String: Any] {
                recordItem(item, complete: false)
            }

        case "item/completed":
            if let item = params["item"] as? [String: Any] {
                recordItem(item, complete: true)
            }

        case "item/agentMessage/delta":
            let delta = params["delta"] as? String ?? ""
            latestAgentMessage += delta
            syncActiveTask()

        case "item/commandExecution/outputDelta":
            let delta = params["delta"] as? String ?? ""
            if !delta.isEmpty {
                appendActivity(kind: .command, title: "Command output", detail: delta)
            }

        case "turn/completed":
            let turn = params["turn"] as? [String: Any]
            let status = turn?["status"] as? String ?? "completed"
            let completedTurnID = turn?["id"] as? String ?? activeTurnID
            if let turn, let processingSeconds = turnDurationSeconds(turn) {
                for index in activities.indices where activities[index].turnID == completedTurnID {
                    activities[index].processingSeconds = processingSeconds
                }
            }
            isRunning = false
            queuedPrompt = nil
            queuedImagePaths = []
            approvalRequest = nil
            taskFinishedAt = Date()
            statusMessage = status == "completed" ? "Codex task completed." : "Codex task \(status)."
            appendActivity(kind: status == "completed" ? .status : .error, title: "Codex task \(status)")
            activeTurnID = nil
            syncActiveTask(state: status == "completed" ? .completed : .interrupted)
            refreshGitWorkspaceSummary()

        case "error":
            let error = params["error"] as? [String: Any]
            finishWithError(error?["message"] as? String ?? "Codex task failed.")

        default:
            break
        }
    }

    private func importListedThreads(for workspace: CodexSavedWorkspace) {
        let workspaceID = workspace.id

        for thread in listedThreads {
            guard let threadID = thread["id"] as? String, !threadID.isEmpty else { continue }
            let name = (thread["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let preview = (thread["preview"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let title = name.isEmpty ? preview : name
            let statusType = ((thread["status"] as? [String: Any])?["type"] as? String) ?? "notLoaded"
            let state: CodexSavedTaskState = statusType == "active" ? .running : .completed
            let createdAt = date(from: thread["createdAt"]) ?? Date()
            let updatedAt = date(from: thread["updatedAt"]) ?? createdAt
            _ = workbench.upsertRemoteTask(
                workspaceID: workspaceID,
                threadID: threadID,
                title: title,
                state: state,
                statusMessage: "Imported from Codex history",
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        }
        refreshSavedTasks()
    }

    private func finishCurrentHistoryWorkspace() {
        if let historyWorkspace {
            importListedThreads(for: historyWorkspace)
        }
        threadListCursor = nil
        listedThreads = []
        if let nextWorkspace = remainingHistoryWorkspaces.first {
            historyWorkspace = nextWorkspace
            remainingHistoryWorkspaces.removeFirst()
            sendListThreads()
            return
        }

        historyWorkspace = nil
        isLoadingTaskHistory = false
        connectionIntent = nil
        statusMessage = "Synced."
        refreshSelectedTask()
    }

    private func hydrateSelectedTask(from thread: [String: Any], requestedThreadID: String) {
        guard let returnedThreadID = thread["id"] as? String,
              returnedThreadID == requestedThreadID,
              returnedThreadID == threadID
        else {
            return
        }

        activities = []
        activityIDsByServerItemID = [:]
        latestAgentMessage = ""
        latestDiff = ""
        for turn in thread["turns"] as? [[String: Any]] ?? [] {
            let duration = turnDurationSeconds(turn)
            for item in turn["items"] as? [[String: Any]] ?? [] {
                recordItem(item, complete: true, processingSeconds: duration, turnID: turn["id"] as? String)
            }
        }

        let isRemoteActive = ((thread["status"] as? [String: Any])?["type"] as? String) == "active"
        taskStartedAt = date(from: thread["createdAt"]) ?? taskStartedAt
        taskFinishedAt = isRemoteActive ? nil : (date(from: thread["updatedAt"]) ?? taskFinishedAt)
        isRemoteTaskActive = isRemoteActive
        isRunning = false
        needsThreadResume = true
        statusMessage = isRemoteActive
            ? "This Codex task is active in another client."
            : "Codex task history loaded."
        syncActiveTask(state: isRemoteActive ? .running : .completed)
    }

    private func date(from value: Any?) -> Date? {
        guard let seconds = (value as? NSNumber)?.doubleValue else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private func recordItem(
        _ item: [String: Any],
        complete: Bool,
        processingSeconds: Int? = nil,
        turnID: String? = nil
    ) {
        let serverItemID = item["id"] as? String
        let type = item["type"] as? String ?? "activity"
        let activity: CodexActivity
        switch type {
        case "userMessage":
            let text = (item["content"] as? [[String: Any]] ?? []).compactMap { content -> String? in
                guard (content["type"] as? String) == "text" else { return nil }
                return content["text"] as? String
            }.joined(separator: "\n")
            activity = CodexActivity(kind: .user, title: "You", detail: userMessageText(from: text), isComplete: complete, processingSeconds: processingSeconds, turnID: turnID ?? activeTurnID)
        case "commandExecution":
            let command = item["command"] as? String ?? "Running command"
            let output = item["aggregatedOutput"] as? String ?? ""
            activity = CodexActivity(kind: .command, title: command, detail: output, isComplete: complete, processingSeconds: processingSeconds, turnID: turnID ?? activeTurnID)
        case "fileChange":
            let changes = (item["changes"] as? [[String: Any]] ?? []).compactMap { change -> String? in
                let path = change["path"] as? String
                let diff = change["diff"] as? String
                return [path, diff].compactMap { $0 }.joined(separator: "\n")
            }.joined(separator: "\n\n")
            if !changes.isEmpty {
                latestDiff = changes
            }
            activity = CodexActivity(kind: .fileChange, title: "File changes", detail: changes, isComplete: complete, processingSeconds: processingSeconds, turnID: turnID ?? activeTurnID)
        case "agentMessage":
            let text = item["text"] as? String ?? latestAgentMessage
            latestAgentMessage = text
            activity = CodexActivity(kind: .message, title: "Codex", detail: text, isComplete: complete, processingSeconds: processingSeconds, turnID: turnID ?? activeTurnID)
        case "plan":
            activity = CodexActivity(kind: .plan, title: "Plan", detail: item["text"] as? String ?? "", isComplete: complete, processingSeconds: processingSeconds, turnID: turnID ?? activeTurnID)
        default:
            return
        }

        if let serverItemID, let existingID = activityIDsByServerItemID[serverItemID],
           let index = activities.firstIndex(where: { $0.id == existingID }) {
            activities[index] = CodexActivity(
                id: existingID,
                kind: activity.kind,
                title: activity.title,
                detail: activity.detail,
                isComplete: complete,
                processingSeconds: processingSeconds ?? activities[index].processingSeconds,
                turnID: turnID ?? activities[index].turnID
            )
        } else {
            activities.append(activity)
            if let serverItemID {
                activityIDsByServerItemID[serverItemID] = activity.id
            }
        }
    }

    private func userMessageText(from text: String) -> String {
        guard let markerRange = text.range(of: "User request:\n") else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(text[markerRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func turnDurationSeconds(_ turn: [String: Any]) -> Int? {
        if let durationMs = (turn["durationMs"] as? NSNumber)?.doubleValue {
            return max(0, Int((durationMs / 1_000).rounded()))
        }
        guard let startedAt = (turn["startedAt"] as? NSNumber)?.doubleValue,
              let completedAt = (turn["completedAt"] as? NSNumber)?.doubleValue
        else { return nil }
        return max(0, Int((completedAt - startedAt).rounded()))
    }

    private func appendActivity(kind: CodexActivity.Kind, title: String, detail: String = "", isComplete: Bool = true) {
        activities.append(CodexActivity(kind: kind, title: title, detail: detail, isComplete: isComplete, turnID: activeTurnID))
        syncActiveTask()
    }

    private func syncActiveTask(
        state: CodexSavedTaskState? = nil,
        threadID: String? = nil
    ) {
        guard let activeTaskID else { return }
        let resolvedState = state ?? (isRunning ? .running : nil)
        workbench.updateTask(
            id: activeTaskID,
            threadID: threadID,
            state: resolvedState,
            statusMessage: statusMessage,
            latestAgentMessage: latestAgentMessage,
            latestDiff: latestDiff,
            activities: activities
        )
        refreshSavedTasks()
    }

    private func refreshSavedTasks() {
        savedTasks = workbench.tasks.filter { !workbench.isTaskArchived($0.id) }
    }

    private func refreshSavedWorkspaces() {
        savedWorkspaces = workbench.workspaces
    }

    private func finishWithError(_ message: String) {
        let wasRunning = isRunning
        isLoadingProjects = false
        isLoadingModels = false
        modelLoadError = message
        isRunning = false
        isLoadingTaskHistory = false
        connectionIntent = nil
        threadListCursor = nil
        listedThreads = []
        historyWorkspace = nil
        remainingHistoryWorkspaces = []
        queuedPrompt = nil
        queuedImagePaths = []
        approvalRequest = nil
        taskFinishedAt = Date()
        let diagnostic = helperDiagnostic()
        let detailedMessage = [message, diagnostic].compactMap { $0 }.joined(separator: "\n")
        statusMessage = detailedMessage
        appendActivity(kind: .error, title: "Codex task failed", detail: detailedMessage)
        activeTurnID = nil
        if wasRunning { syncActiveTask(state: .failed) }
    }

    private func helperDiagnostic() -> String? {
        guard let helperDiagnosticURL,
              let diagnostic = try? String(contentsOf: helperDiagnosticURL, encoding: .utf8),
              !diagnostic.isEmpty
        else {
            return nil
        }
        return "Background helper: \(diagnostic)"
    }

    func revertCodexChanges(diff: String) -> Bool {
        guard !isRunning else {
            statusMessage = "Finish the active Codex task before reverting changes."
            return false
        }
        guard let workspaceURL, diff.contains("diff --git ") else {
            statusMessage = "This change does not have a reversible Git diff."
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", workspaceURL.path, "apply", "--reverse", "--whitespace=nowarn", "-"]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            input.fileHandleForWriting.write(Data(diff.utf8))
            input.fileHandleForWriting.closeFile()
            process.waitUntilExit()
        } catch {
            statusMessage = "Could not revert Codex changes: \(error.localizedDescription)"
            return false
        }

        guard process.terminationStatus == 0 else {
            statusMessage = "Could not revert changes because the workspace has diverged."
            return false
        }

        latestDiff = ""
        statusMessage = "Reverted the selected Codex change."
        appendActivity(kind: .status, title: "Reverted Codex changes")
        syncActiveTask()
        refreshGitWorkspaceSummary()
        return true
    }

    private func refreshGitWorkspaceSummary() {
        guard let workspaceURL else {
            gitWorkspaceSummary = "Git status unavailable"
            return
        }
        guard let branch = gitOutput(["-C", workspaceURL.path, "branch", "--show-current"]) else {
            gitWorkspaceSummary = "Not a Git workspace"
            return
        }
        let changes = (gitOutput(["-C", workspaceURL.path, "status", "--porcelain"]) ?? "")
            .split(whereSeparator: \.isNewline).count
        let worktrees = (gitOutput(["-C", workspaceURL.path, "worktree", "list", "--porcelain"]) ?? "")
            .split(whereSeparator: \.isNewline)
            .filter { $0.hasPrefix("worktree ") }
            .count
        let branchName = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        gitWorkspaceSummary = "\(branchName.isEmpty ? "detached HEAD" : branchName) · \(changes) change\(changes == 1 ? "" : "s") · \(worktrees) worktree\(worktrees == 1 ? "" : "s")"
    }

    private func gitOutput(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        } catch {
            return nil
        }
    }

    private func handleProcessTermination(_ process: Process) {
        guard self.process === process else { return }
        self.process = nil
        standardInput = nil
        outputBuffer = Data()
        threadID = nil
        if isRunning {
            finishWithError("Codex app-server stopped (exit \(process.terminationStatus)).")
        }
    }

    private func stopAppServer() {
        isLoadingProjects = false
        isReadingSelectedTask = false
        isRemoteTaskActive = false
        connectionReady = false
        isLoadingModels = false
        delayedConnectionTask?.cancel()
        delayedConnectionTask = nil
        webSocketReceiveTask?.cancel()
        webSocketReceiveTask = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        process?.standardOutput = nil
        process?.standardError = nil
        process?.terminate()
        process = nil
        standardInput = nil
        threadID = nil
        activeTurnID = nil
        outputBuffer = Data()
        pendingRequests = [:]
        connectionIntent = nil
        isLoadingTaskHistory = false
        historyWorkspace = nil
        remainingHistoryWorkspaces = []
        isRunning = false
    }

    private func sendRequest(method: String, params: [String: Any], pending: PendingRequest? = nil) {
        requestID += 1
        let id = requestID
        if let pending {
            pendingRequests[id] = pending
        }
        write(["id": id, "method": method, "params": params])
    }

    private func sendNotification(method: String, params: [String: Any]) {
        write(["method": method, "params": params])
    }

    private func sendResponse(id: Int, result: [String: Any]) {
        write(["id": id, "result": result])
    }

    private func write(_ message: [String: Any]) {
        do {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(0x0A)
            if let webSocket {
                guard let text = String(data: data, encoding: .utf8) else {
                    finishWithError("Could not encode the Codex request.")
                    return
                }
                Task { @MainActor [weak self] in
                    do {
                        try await webSocket.send(.string(text))
                    } catch {
                        guard !Task.isCancelled else { return }
                        self?.finishWithError("Could not communicate with Codex: \(error.localizedDescription)")
                    }
                }
                return
            }
            guard let standardInput else {
                finishWithError("Codex app-server is not connected.")
                return
            }
            try standardInput.write(contentsOf: data)
        } catch {
            finishWithError("Could not communicate with Codex: \(error.localizedDescription)")
        }
    }
}

private enum CodexWorkspaceError: LocalizedError {
    case accessDenied
    case launchFailed(String, String)
    case invalidAppServerURL

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            "Marr could not access the selected workspace."
        case .launchFailed(let path, let message):
            "Could not start Codex at \(path): \(message)"
        case .invalidAppServerURL:
            "The Codex app-server URL must be ws://127.0.0.1:<port> (or localhost)."
        }
    }
}

/// A separate connection keeps screenshot conversations out of the Work task state.
@MainActor
final class CodexConversationClient {
    private let socket: URLSessionWebSocketTask
    private var requestID = 0
    private var notifications: [[String: Any]] = []

    init(endpoint: URL) {
        socket = URLSession.shared.webSocketTask(with: endpoint)
    }

    static func input(for request: VisionRequest) throws -> [[String: Any]] {
        var input: [[String: Any]] = []
        for message in request.messages {
            input.append(["type": "text", "text": "\n[\(message.role.rawValue)]\n"])
            for content in message.content {
                switch content {
                case .text(let text):
                    input.append(["type": "text", "text": text])
                case .image(let asset):
                    input.append(["type": "image", "url": "data:\(asset.mimeType);base64,\(asset.data.base64EncodedString())"])
                case .file(let asset):
                    let text: String?
                    if asset.mimeType == "application/pdf", let pdf = PDFDocument(data: asset.data) {
                        text = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n")
                    } else {
                        text = String(data: asset.data, encoding: .utf8)
                    }
                    guard let text, !text.isEmpty else {
                        throw UserFacingError("\(asset.fileName): this conversation supports images, text files and text-based PDFs. Export this file to one of those formats first.")
                    }
                    input.append(["type": "text", "text": "Attachment: \(asset.fileName)\n\(text)"])
                }
            }
        }
        return input
    }

    func respond(to request: VisionRequest, model: String, effort: String?) async throws -> String {
        let input = try Self.input(for: request)
        socket.resume()
        let timeout = Task { [socket] in
            do {
                try await Task.sleep(for: .seconds(180))
                socket.cancel(with: .goingAway, reason: nil)
            } catch {}
        }
        defer {
            timeout.cancel()
            socket.cancel(with: .normalClosure, reason: nil)
        }
        return try await withTaskCancellationHandler {
            _ = try await rpc("initialize", [
                "clientInfo": ["name": "marr_conversation", "title": "Marr Conversation", "version": "0.1.0"],
                "capabilities": ["experimentalApi": true]
            ])
            try await send(["method": "initialized", "params": [:]])
            let effective = try await rpc("config/read", ["includeLayers": false])
            let current = effective["config"] as? [String: Any] ?? [:]
            var config: [String: Any] = [
                "features.shell_tool": false, "features.unified_exec": false,
                "features.apply_patch_freeform": false, "features.apps": false,
                "features.plugins": false, "features.multi_agent": false,
                "web_search": "disabled", "project_doc_max_bytes": 0,
                "hooks": [:] as [String: Any]
            ]
            for name in (current["mcp_servers"] as? [String: Any] ?? [:]).keys {
                config["mcp_servers.\(name).enabled"] = false
            }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Marr-Conversation", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let result = try await rpc("thread/start", [
                "model": model, "modelProvider": "openai", "cwd": directory.path,
                "ephemeral": true, "approvalPolicy": "never", "sandbox": "read-only",
                "baseInstructions": request.systemPrompt,
                "developerInstructions": "You are a conversational OpenAI assistant. Answer using the supplied conversation and attachments. Do not execute commands, change files, or invoke external tools. The [user] and [assistant] labels delimit conversation history; answer the final user message.",
                "config": config
            ])
            guard let thread = result["thread"] as? [String: Any], let threadID = thread["id"] as? String else {
                throw UserFacingError("Codex did not create the conversation.")
            }
            var turn: [String: Any] = ["threadId": threadID, "model": model, "input": input]
            if let effort { turn["effort"] = effort }
            _ = try await rpc("turn/start", turn)
            var answer = ""
            var completedMessages: [String] = []
            while true {
                try Task.checkCancellation()
                let event = try await nextEvent()
                let params = event["params"] as? [String: Any] ?? [:]
                guard params["threadId"] as? String == threadID else { continue }
                switch event["method"] as? String {
                case "item/agentMessage/delta":
                    answer += params["delta"] as? String ?? ""
                case "item/completed":
                    if let item = params["item"] as? [String: Any], item["type"] as? String == "agentMessage",
                       let text = item["text"] as? String { completedMessages.append(text) }
                case "turn/completed":
                    let turn = params["turn"] as? [String: Any] ?? [:]
                    guard turn["status"] as? String == "completed" else {
                        let error = turn["error"] as? [String: Any]
                        throw UserFacingError(error?["message"] as? String ?? "Codex conversation did not complete.")
                    }
                    let text = completedMessages.isEmpty ? answer : completedMessages.joined(separator: "\n\n")
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw UserFacingError("Codex returned an empty response.")
                    }
                    return text
                case "error":
                    if params["willRetry"] as? Bool != true {
                        let error = params["error"] as? [String: Any]
                        throw UserFacingError(error?["message"] as? String ?? "Codex request failed.")
                    }
                default: break
                }
            }
        } onCancel: { [socket] in
            socket.cancel(with: .goingAway, reason: nil)
        }
    }

    private func send(_ value: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: value)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func receive() async throws -> [String: Any] {
        try Task.checkCancellation()
        let data: Data
        switch try await socket.receive() {
        case .data(let value): data = value
        case .string(let value): data = Data(value.utf8)
        @unknown default: throw UserFacingError("Unknown Codex response.")
        }
        guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UserFacingError("Invalid Codex response.")
        }
        // Conversation never grants tool execution requests.
        if let id = event["id"], event["method"] != nil {
            try await send(["id": id, "error": ["code": -32601, "message": "Tools are disabled in Conversation."]])
        }
        return event
    }

    private func rpc(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        requestID += 1
        let id = requestID
        try await send(["id": id, "method": method, "params": params])
        while true {
            let response = try await receive()
            if response["id"] as? Int == id, response["method"] == nil {
                if let error = response["error"] as? [String: Any] {
                    throw UserFacingError(error["message"] as? String ?? "Codex request failed.")
                }
                return response["result"] as? [String: Any] ?? [:]
            }
            if response["id"] == nil { notifications.append(response) }
        }
    }

    private func nextEvent() async throws -> [String: Any] {
        if !notifications.isEmpty { return notifications.removeFirst() }
        return try await receive()
    }
}
