import Foundation
import AppKit
import Darwin
import MarrCore
import CryptoKit
import PDFKit
import CoreFoundation

@MainActor
final class RuntimeWorkspaceController: ObservableObject {
    static let codexSyncEnabledKey = "codex.sync.enabled"
    @Published private(set) var codexSyncEnabled = false
    @Published private(set) var codexSyncStatusMessage = "Codex sync is off. Your Marr work stays on this device."

    @Published private(set) var workspaceURL: URL?
    @Published private(set) var workspaceDisplayName = "No workspace selected"
    @Published private(set) var codexCLIURL: URL?
    @Published private(set) var codexCLIDisplayName = "Automatic"
    @Published private(set) var appServerURLString = ""
    @Published private(set) var instructionSources: [String] = []
    @Published private(set) var activities: [WorkActivity] = [] {
        didSet { activitiesRevision &+= 1 }
    }
    private(set) var activitiesRevision: UInt64 = 0
    #if DEBUG
    private(set) var historyPreparationWasOffMain = false
    #endif
    @Published private(set) var latestDiff = ""
    @Published private(set) var latestAgentMessage = ""
    @Published private(set) var statusMessage = "Choose a workspace to start a Codex task."
    @Published private(set) var isRunning = false
    @Published private(set) var isRemoteTaskActive = false
    @Published private(set) var isTaskStatusUncertain = false
    @Published private(set) var runtimeDescription = "Not connected"
    @Published private(set) var selectedReasoningEffort: String? = nil
    @Published private(set) var isReadingSelectedTask = false
    @Published private(set) var isLoadingTaskHistory = false
    @Published private(set) var isLoadingProjects = false
    @Published private(set) var lastProjectSyncAt: Date?
    @Published private(set) var taskStartedAt: Date?
    @Published private(set) var taskFinishedAt: Date?
    @Published private(set) var savedTasks: [SavedTask] = []
    @Published private(set) var pinnedTaskIDs: Set<UUID> = []
    @Published private(set) var isRenamingTask = false
    @Published private(set) var savedWorkspaces: [SavedWorkspace] = []
    @Published var approvalRequest: CodexApprovalRequest?
    @Published private(set) var gitWorkspaceSummary = "Git status unavailable"
    @Published private(set) var selectedModel = "gpt-5.6-terra"
    @Published private(set) var availableModels: [CodexModelOption] = []
    @Published private(set) var isLoadingModels = false
    @Published private(set) var modelLoadError: String?
    @Published private(set) var skills: [CodexSkill] = []
    @Published private(set) var extensions: [CodexExtensionEntry] = []
    @Published private(set) var capabilityErrors: [String: String] = [:]
    @Published private(set) var capabilityDiagnostics: [String: String] = [:]
    @Published private(set) var loadingCapabilityMethods: Set<String> = []
    @Published private(set) var fileSearchResults: [CodexFileSearchMatch] = []
    @Published private(set) var isSearchingFiles = false
    @Published private(set) var fileSearchError: String?
    @Published private(set) var commandOutput = ""
    @Published private(set) var threadGoal: CodexThreadGoal?
    @Published private(set) var isLoadingCapabilities = false
    @Published private(set) var pluginOperationsInFlight: Set<String> = []
    @Published private(set) var selectedSkillPaths: Set<String> = []
    @Published private(set) var composerBindings: [ComposerMentionBinding] = []
    @Published private(set) var collaborationModes: [CodexCollaborationMode] = []
    @Published private(set) var selectedCollaborationModeID: String?
    @Published private(set) var pendingInteractions: [CodexInteractionRequest] = []
    @Published private(set) var interactionErrors: [CodexRequestID: String] = [:]
    @Published private(set) var recoverableDrafts: [CodexSubmissionDraft] = []
    @Published private(set) var account: CodexAccount?
    @Published private(set) var requiresOpenAIAuth: Bool?
    @Published private(set) var accountLogin: CodexAccountLogin?
    @Published private(set) var accountStatusMessage = ""
    @Published private(set) var rateLimitBuckets: [CodexRateLimitBucket] = []
    @Published private var threadTokenUsage: [String: CodexThreadTokenUsage] = [:]
    private var tokenUsageModelsByTurn: [String: [String: String]] = [:]
    private var pendingTurnModel: String?
    private var confirmedThreadModel: String?
    var activeTokenUsage: CodexThreadTokenUsage? {
        guard let threadID, let usage = threadTokenUsage[threadID], usage.model == selectedModel else { return nil }
        return usage
    }
    @Published private(set) var ordinaryUsageAllowed: Bool?
    @Published private(set) var accountUsage: CodexAccountUsage?
    @Published private(set) var configuration: CodexConfiguration?
    @Published private(set) var configurationRequirements: CodexConfigurationRequirements?
    @Published private(set) var configurationStatusMessage = ""
    @Published private(set) var experimentalFeatures: [CodexExperimentalFeature] = []
    @Published private(set) var settingsLoadingMethods: Set<String> = []
    @Published private(set) var settingsErrors: [String: String] = [:]
    @Published private(set) var settingsDiagnostics: [String: String] = [:]
    @Published private(set) var archivingTaskIDs: Set<UUID> = []
    private var settingsRequestTokens: [String: UUID] = [:]
    private var requirementsLoaded = false
    private var rateLimitRows: [String: [String: Any]] = [:]
    private var featureRows: [CodexExperimentalFeature] = []
    private var featureCursors: Set<String> = []
    private var earlyLoginCompletions: [String: [String: Any]] = [:]
    private var pendingSubmissionDraft: CodexSubmissionDraft?
    private var pendingSubmissionSnapshot: SavedTask?
    private var listedModels: [CodexModelOption] = []
    private var connectionReady = false
    private var runtimeFingerprint: String?
    private var lastModelRefresh: Date?
    private var conversationRequests = 0
    let workbench: WorkbenchStore
    let composerDraftStore: ComposerDraftStore
    private let defaults: UserDefaults
    private let outboundMessage: (([String: Any]) -> Void)?
    private let requestTimeoutOverride: TimeInterval?
    private let initializeInjectedTransport: Bool
    private let attachmentDirectory: URL

    private enum PendingRequest {
        case initialize
        case listModels
        case listProjects
        case startThread
        case resumeThread
        case startTurn
        case listThreads
        case readThread(String)
        case resumeSavedHistory(SavedHistoryResume)
        case historySync(UUID, HistorySyncOperation)
        case sidebarMutation(String, String, [String: Any])
        case interruptTurn
        case steerTurn(CodexSubmissionDraft)
        case capability(String)
        case skillWrite
        case pluginMutation(String, String)
        case reloadMCP
        case loginMCP(String)
        case forkThread
        case archiveThread(UUID, Bool)
        case fileSearch(UUID)
        case command(String, String, [String: Any])
        case prepareCommandThread(String, [String: Any], UUID)
        case settings(String, UUID)
    }

    private enum ConnectionIntent {
        case listModels
        case listProjects
        case submit
        case listThreads
        case readThread(String)
        case historySync
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
    private var gitSummaryRequestID = UUID()
    private let runtimeExecutableOverride: [URL]?
    private(set) var managedServerProcess: Process?
    private var runtimeDiagnosticURL: URL?
    private var hasManagedBackgroundServer = false
    private var outputBuffer = Data()
    private var requestID = 0
    private var pendingRequests: [Int: PendingRequest] = [:]
    private var requestTimeoutTasks: [Int: Task<Void, Never>] = [:]
    private var commandSubmissionDrafts: [Int: CodexSubmissionDraft] = [:]
    private var threadID: String?
    private var activeTurnID: String?
    private var completedTurnIDs: Set<String> = []
    private var queuedPrompt: String?
    private var queuedImagePaths: [String] = []
    private var queuedInputs: [[String: Any]] = []
    private var cancellationRequested = false
    private var interruptRequestTurnID: String?
    private var connectionGeneration = UUID()
    private var outboundTask: Task<Void, Never>?
    private var requestedCapabilityMethods: Set<String> = []
    private var capabilityRefreshPending: Bool {
        get { !requestedCapabilityMethods.isEmpty }
        set {
            if newValue { requestedCapabilityMethods.formUnion(["skills/list", "collaborationMode/list"]) }
            else { requestedCapabilityMethods = [] }
        }
    }
    private var fileSearchGeneration = UUID()
    private var boundFilePaths: Set<String> = []
    private var boundExtensionMentions: [String: ComposerMentionBinding] = [:]
    private var commandGeneration = UUID()
    private var preparingCommandThread = false
    private var activeCommandMethod: String?
    private var awaitingGoalActivation = false
    private var goalRevision: UInt64 = 0
    private var capabilityRows: [String: [[String: Any]]] = [:]
    private var globalHistory = false
    private var historyArchived = false
    private var archivedHistoryPending = false
    private var archiveReconciliationCandidates: Set<UUID> = []
    private var isArchiveOnlyHistory = false
    private var pendingThreadActions: [(String, [String: Any], PendingRequest, CodexSubmissionDraft?)] = []
    private var activityIDsByServerItemID: [String: UUID] = [:]
    private var activeTaskID: UUID?
    private var needsThreadResume = false
    private var connectionIntent: ConnectionIntent?
    private var threadListCursor: String?
    private var listedThreads: [[String: Any]] = []
    private var historyWorkspace: SavedWorkspace?
    private var remainingHistoryWorkspaces: [SavedWorkspace] = []
    private var taskSnapshotTask: Task<Void, Never>?

    private struct SavedHistoryResume {
        let id = UUID()
        let threadID: String
        let taskID: UUID
        let workspaceID: UUID
    }
    @Published private(set) var isResumingSavedHistory = false
    private var savedHistoryResume: SavedHistoryResume?
    private var resumableSavedHistoryThreadID: String?

    var canResumeSavedHistory: Bool {
        guard codexSyncEnabled else { return false }
        guard isTaskStatusUncertain, !isRunning, !isReadingSelectedTask, !isResumingSavedHistory,
              !isReconcilingConnection, !preparingCommandThread, !awaitingGoalActivation,
              let threadID, threadID == resumableSavedHistoryThreadID,
              let activeTaskID, activeTaskID == workbench.selectedTaskID,
              pendingSubmissionDraft == nil, commandSubmissionDrafts.isEmpty,
              pendingThreadActions.isEmpty else { return false }
        guard !composerDraftStore.recoveries.contains(where: {
            $0.threadID == threadID || $0.taskID == activeTaskID
        }) else { return false }
        return pendingRequests.values.allSatisfy { if case .historySync = $0 { return true }; return false }
    }

    /// Only the explicit confirmation in the UI calls this. Loading a saved
    /// runtime thread never submits the composer, replays a command, or approves
    /// a tool. Background synchronization uses thread/read exclusively.
    func resumeSavedHistory() {
        guard canResumeSavedHistory, let threadID, let activeTaskID,
              let workspaceID = workbench.selectedWorkspaceID else { return }
        invalidateHistorySync()
        let context = SavedHistoryResume(threadID: threadID, taskID: activeTaskID, workspaceID: workspaceID)
        savedHistoryResume = context
        isResumingSavedHistory = true
        capabilityErrors.removeValue(forKey: "thread/resume")
        capabilityDiagnostics.removeValue(forKey: "thread/resume")
        enqueueOperation("thread/resume", params: ["threadId": threadID], pending: .resumeSavedHistory(context))
    }

    private func matchesSavedHistoryResume(_ context: SavedHistoryResume) -> Bool {
        savedHistoryResume?.id == context.id && context.threadID == threadID
            && context.taskID == activeTaskID && context.taskID == workbench.selectedTaskID
            && context.workspaceID == workbench.selectedWorkspaceID && !isRunning
    }

    private func cancelSavedHistoryResume() {
        savedHistoryResume = nil
        isResumingSavedHistory = false
        resumableSavedHistoryThreadID = nil
        for (id, pending) in pendingRequests {
            if case .resumeSavedHistory = pending {
                pendingRequests.removeValue(forKey: id)
                requestTimeoutTasks.removeValue(forKey: id)?.cancel()
            }
        }
        pendingThreadActions.removeAll { if case .resumeSavedHistory = $0.2 { return true }; return false }
    }

    private enum HistorySyncOperation {
        case projects(String?)
        case pinned(String?)
        case threads(archived: Bool, cursor: String?)
        case read(threadID: String, taskID: UUID, workspaceID: UUID)
    }
    private static let historySourceKinds = ["cli", "vscode", "appServer", "exec", "unknown"]
    private var historySyncVisible = false
    private var historySyncAppActive = false
    private var historySyncTask: Task<Void, Never>?
    private var historySyncEpoch = UUID()
    private var historySyncOperation: HistorySyncOperation?
    private var historySyncQueue: [HistorySyncOperation] = []
    private var historySyncCursors: Set<String> = []
    private var historySyncPageCount = 0
    private var historySyncNextRead = Date.distantPast
    private var historySyncNextDirectory = Date.distantPast
    private var historySyncRetryAfter = Date.distantPast
    private var historySyncFailures = 0
    @Published private(set) var sidebarMutationThreadIDs: Set<String> = []
    @Published private(set) var desktopSidebarSyncAvailable = false
    private let desktopSidebarReader = CodexDesktopSidebarReader()
    private var desktopSidebarReadTask: Task<Void, Never>?
    private var desktopSidebarLastRead = Date.distantPast
    private var desktopSidebarLastData: Data?
    private var historySyncPinnedIDs: [String] = []
    private var historySyncSectionsSupported = true
    private var historySyncProjectSupported = true
    private var historySyncRuntimeIdentity: String?
    private var historySyncReadOnlyConnection = false
    private var historySyncLastSnapshot: NSDictionary?
    private var historySyncUserScrolling = false
    private var oversizedHistoryThreadIDs: Set<String> = []
    private var historySyncObservedTurnID: String?
    private var historySyncObservedThreadID: String?
    private var historySyncConnectionStatus: String?
    private var historySyncReadRevision: UInt64 = 0
    private var historySyncRequestedReadRevision: UInt64 = 0

    /// A reconnect may inspect exactly one original task. It never replays a
    /// command, resumes a thread, or restores an approval decision.
    private struct ReadReconciliation {
        let id = UUID()
        let workspaceID: UUID
        let taskID: UUID
        let threadID: String
        let turnID: String?
        var attempts = 0
    }
    private var readReconciliation: ReadReconciliation?
    private var uncertainTaskTurnID: String?
    private var reconciliationTask: Task<Void, Never>?
    private static let reconciliationDelays: [Double] = [1, 2, 4]
    var isReconcilingConnection: Bool { readReconciliation != nil }

    init(defaults: UserDefaults = .standard, outboundMessage: (([String: Any]) -> Void)? = nil,
         attachmentDirectory: URL? = nil, draftDirectory: URL? = nil,
         requestTimeout: TimeInterval? = nil, initializeInjectedTransport: Bool = false,
         codexSyncEnabled: Bool? = nil, runtimeExecutables: [URL]? = nil) {
        self.runtimeExecutableOverride = runtimeExecutables
        self.defaults = defaults
        self.codexSyncEnabled = codexSyncEnabled ?? defaults.bool(forKey: Self.codexSyncEnabledKey)
        self.initializeInjectedTransport = initializeInjectedTransport
        self.outboundMessage = outboundMessage
        requestTimeoutOverride = requestTimeout.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let resolvedAttachmentDirectory = attachmentDirectory ?? MarrStorage.rootURL
            .appendingPathComponent("WorkAttachments", isDirectory: true)
        self.attachmentDirectory = resolvedAttachmentDirectory
        self.composerDraftStore = ComposerDraftStore(rootURL: draftDirectory
            ?? resolvedAttachmentDirectory.appendingPathComponent("ComposerDrafts", isDirectory: true))
        self.workbench = WorkbenchStore(defaults: defaults)
        appServerURLString = defaults.string(forKey: appServerURLKey) ?? ""
        appServerURLIsManual = defaults.bool(forKey: appServerURLIsManualKey)
        selectedModel = defaults.string(forKey: selectedModelKey) ?? "gpt-5.6-terra"
        if self.codexSyncEnabled {
            if let selected = workbench.selectedWorkspace {
                do { try activateWorkspace(selected) }
                catch { restoreWorkspaceAccess() }
            } else { restoreWorkspaceAccess() }
            restoreCodexCLIPath()
        } else if let selected = workbench.selectedWorkspace {
            // Cached Marr-owned metadata is safe to show while compatibility is off.
            // Do not resolve bookmarks, inspect Codex installations, or launch git.
            workspaceURL = URL(fileURLWithPath: selected.path)
            workspaceDisplayName = selected.name
        }
        savedTasks = workbench.tasks.filter { !workbench.isTaskArchived($0.id) }
        pinnedTaskIDs = workbench.pinnedTaskIDs
        savedWorkspaces = workbench.workspaces
        if let savedTask = workbench.selectedTask {
            restoreSavedTask(savedTask)
        }
        recoverableDrafts = composerDraftStore.recoveries
        loadComposerBindings()
        if !self.codexSyncEnabled {
            connectionIntent = nil
            isRemoteTaskActive = false
            isTaskStatusUncertain = false
            statusMessage = codexSyncStatusMessage
        } else { codexSyncStatusMessage = "Codex sync is on." }
    }

    deinit {
        securityScopedURL?.stopAccessingSecurityScopedResource()
        codexCLISecurityScopedURL?.stopAccessingSecurityScopedResource()
        webSocketReceiveTask?.cancel()
        webSocket?.cancel(with: .goingAway, reason: nil)
        delayedConnectionTask?.cancel()
        outboundTask?.cancel()
        taskSnapshotTask?.cancel()
        reconciliationTask?.cancel()
        historySyncTask?.cancel()
        desktopSidebarReadTask?.cancel()
        for task in requestTimeoutTasks.values { task.cancel() }
        process?.terminate()
        managedServerProcess?.terminate()
        if let runtimeDiagnosticURL { try? FileManager.default.removeItem(at: runtimeDiagnosticURL) }
    }

    /// Opt-in compatibility switch. Marr's local archives and credentials remain intact.
    @discardableResult
    func setCodexSyncEnabled(_ enabled: Bool) -> Bool {
        guard enabled != codexSyncEnabled else { return true }
        if !enabled {
            guard !isRunning, !isRemoteTaskActive, conversationRequests == 0,
                  !preparingCommandThread, !awaitingGoalActivation, !isResumingSavedHistory,
                  !isRenamingTask, archivingTaskIDs.isEmpty, sidebarMutationThreadIDs.isEmpty,
                  pluginOperationsInFlight.isEmpty, activeCommandMethod == nil,
                  pendingSubmissionDraft == nil, commandSubmissionDrafts.isEmpty,
                  accountLogin == nil, !hasPendingCodexMutation,
                  settingsLoadingMethods.isDisjoint(with: ["account/login/start", "account/login/cancel", "account/logout", "config/value/write"]) else {
                codexSyncStatusMessage = "Finish or stop active Codex work and pending account changes before turning sync off."
                return false
            }
            // Set the gate first so callbacks queued before disconnection cannot restart work.
            codexSyncEnabled = false
            MarrHistoryImageRecovery.cancelAll()
            stopManagedServer()
            historySyncTask?.cancel(); historySyncTask = nil
            desktopSidebarReadTask?.cancel(); desktopSidebarReadTask = nil
            desktopSidebarSyncAvailable = false
            desktopSidebarLastData = nil
            gitSummaryRequestID = UUID()
            stopAppServer()
            hasManagedBackgroundServer = false
            securityScopedURL?.stopAccessingSecurityScopedResource(); securityScopedURL = nil
            codexCLISecurityScopedURL?.stopAccessingSecurityScopedResource(); codexCLISecurityScopedURL = nil
            runtimeDescription = "Codex sync is off"
            codexSyncStatusMessage = "Codex sync is off. Saved Marr history and Codex credentials were kept."
            statusMessage = codexSyncStatusMessage
        } else {
            codexSyncEnabled = true
            if let selected = workbench.selectedWorkspace {
                do { try activateWorkspace(selected) }
                catch { restoreWorkspaceAccess() }
            } else { restoreWorkspaceAccess() }
            restoreCodexCLIPath()
            if let selected = workbench.selectedTask { restoreSavedTask(selected) }
            codexSyncStatusMessage = "Codex sync is on. Shared projects and chats refresh while their sidebar is visible."
            updateHistorySyncLifecycle()
        }
        defaults.set(enabled, forKey: Self.codexSyncEnabledKey)
        return true
    }

    private var hasPendingCodexMutation: Bool {
        func isMutation(_ request: PendingRequest) -> Bool {
            switch request {
            case .startThread, .resumeThread, .startTurn, .resumeSavedHistory,
                 .sidebarMutation, .interruptTurn, .steerTurn, .skillWrite,
                 .pluginMutation, .reloadMCP, .loginMCP, .forkThread, .archiveThread,
                 .command, .prepareCommandThread:
                return true
            case .settings(let method, _):
                return ["account/login/start", "account/login/cancel", "account/logout", "config/value/write"].contains(method)
            default: return false
            }
        }
        return pendingRequests.values.contains(where: isMutation)
            || pendingThreadActions.contains { isMutation($0.2) }
    }

    @discardableResult
    private func requireCodexSync() -> Bool {
        guard codexSyncEnabled else {
            statusMessage = "Enable Sync Codex work in Settings to use Codex compatibility."
            commandOutput = statusMessage
            return false
        }
        return true
    }

    var canSubmit: Bool {
        guard codexSyncEnabled else { return false }
        guard !isRunning, !isRemoteTaskActive, !isReadingSelectedTask, !isResumingSavedHistory, !preparingCommandThread,
              !isReconcilingConnection, !isTaskStatusUncertain else { return false }
        if case .readThread = connectionIntent { return false }
        return true
    }

    /// Browsing may supersede a read/refresh or a remote status check. Only
    /// locally owned mutations must finish before we replace their transport.
    var historySelectionBlockReason: String? {
        if isRunning { return "Finish or stop the current task before switching conversations." }
        if preparingCommandThread || isResumingSavedHistory || isRenamingTask
            || !archivingTaskIDs.isEmpty || activeCommandMethod != nil {
            return "Wait for the current conversation operation to finish."
        }
        return nil
    }

    var canSteer: Bool {
        codexSyncEnabled && isRunning && activeTurnID != nil && connectionReady && !cancellationRequested && activeCommandMethod == nil
    }

    var canRenameSelectedTask: Bool {
        guard codexSyncEnabled else { return false }
        guard let task = workbench.selectedTask, !isRenamingTask, !isReadingSelectedTask, !preparingCommandThread else { return false }
        return task.threadID == threadID && (task.threadID != nil || !isRunning)
    }

    var canForkSelectedTask: Bool { threadID != nil && canSubmit }

    func toggleTaskPinned(_ task: SavedTask) {
        guard requireCodexSync() else { return }
        guard let id = task.threadID else {
            workbench.toggleTaskPinned(task.id); refreshSavedTasks(); return
        }
        let section: Any = workbench.isTaskPinned(task.id) ? NSNull() : WorkbenchStore.pinnedSectionID
        sendSidebarMutation("thread/section/move", threadID: id, params: ["threadId": id, "sectionId": section])
    }

    func assignTask(_ task: SavedTask, to project: SavedWorkspace?) {
        guard requireCodexSync() else { return }
        guard let id = task.threadID, project == nil || project?.projectID != nil else { return }
        sendSidebarMutation("thread/metadata/update", threadID: id,
            params: ["threadId": id, "projectId": project?.projectID ?? ""])
    }

    private func sendSidebarMutation(_ method: String, threadID: String, params: [String: Any]) {
        guard !sidebarMutationThreadIDs.contains(threadID), historySelectionBlockReason == nil else { return }
        sidebarMutationThreadIDs.insert(threadID)
        capabilityErrors.removeValue(forKey: method)
        enqueueOperation(method, params: params, pending: .sidebarMutation(method, threadID, params))
    }

    var sidebarWorkspaces: [SavedWorkspace] { workbench.sidebarWorkspaces }

    private func refreshDesktopSidebarPreferences(now: Date) {
        guard codexSyncEnabled, outboundMessage == nil, !appServerURLIsManual,
              desktopSidebarReadTask == nil, now.timeIntervalSince(desktopSidebarLastRead) >= 2 else { return }
        desktopSidebarLastRead = now
        let home = CodexRuntime.homeURL
        let reader = desktopSidebarReader
        desktopSidebarReadTask = Task(priority: .utility) { [weak self] in
            let snapshot = try? await reader.read(codexHome: home)
            guard let self else { return }
            desktopSidebarReadTask = nil
            guard self.codexSyncEnabled, !Task.isCancelled, !appServerURLIsManual else { return }
            guard let snapshot, let data = try? JSONEncoder().encode(snapshot) else {
                desktopSidebarSyncAvailable = false
                return
            }
            desktopSidebarSyncAvailable = true
            guard data != desktopSidebarLastData else { return }
            desktopSidebarLastData = data
            workbench.applyDesktopSidebarPreferences(snapshot)
            refreshSavedWorkspaces(); refreshSavedTasks()
        }
    }

    @discardableResult
    func renameSelectedTask(_ name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { commandOutput = "Enter a chat name."; return false }
        guard canRenameSelectedTask, let task = workbench.selectedTask else {
            commandOutput = "Select a chat and wait for pending chat operations to finish before renaming it."
            return false
        }
        capabilityErrors.removeValue(forKey: "thread/name/set")
        capabilityDiagnostics.removeValue(forKey: "thread/name/set")
        if task.threadID == nil {
            guard workbench.renameTask(task.id, name: name) else { return false }
            refreshSavedTasks()
            commandOutput = "Renamed to \(name)."
            return true
        }
        isRenamingTask = true
        let accepted = enqueueCommand("thread/name/set", params: ["name": name, "_localTaskID": task.id.uuidString])
        if !accepted { isRenamingTask = false }
        return accepted
    }

    /// Export messages, not the event log. Tool output and protocol JSON never enter this string.
    var chatTranscript: String {
        activities.compactMap { activity -> String? in
            guard activity.isComplete, activity.kind == .user || activity.kind == .message else { return nil }
            var text = activity.detail
            if activity.kind == .user {
                let presentation = UserMessagePresentation(activity.detail, rawJSON: activity.rawJSON)
                let attachments = presentation.attachments.map { attachment in
                    Self.transcriptAttachment(path: attachment.source, label: attachment.label, image: attachment.isImage)
                        ?? "[\(attachment.isImage ? "Attached image" : "Attachment")]"
                }
                text = ([presentation.body] + attachments + presentation.references)
                    .filter { !$0.isEmpty }.joined(separator: "\n\n")
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return "## \(activity.kind == .user ? "You" : "Codex")\n\n\(text)"
        }.joined(separator: "\n\n")
    }

    private static func transcriptAttachment(path: String, label: String, image: Bool) -> String? {
        let isLocal = path.hasPrefix("/")
        let url = URL(string: path)
        guard isLocal || (["https", "http"].contains(url?.scheme?.lowercased() ?? "") && url?.host != nil) else { return nil }
        let target = path.replacingOccurrences(of: "<", with: "%3C").replacingOccurrences(of: ">", with: "%3E")
            .replacingOccurrences(of: "\n", with: "%0A").replacingOccurrences(of: "\r", with: "%0D")
        let label = label.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
        return "\(image ? "!" : "")[\(label)](<\(target)>)"
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
        guard codexSyncEnabled else { return }
        let changed = currentRuntimeFingerprint() != runtimeFingerprint
        guard !connectionReady || changed || lastModelRefresh == nil || Date().timeIntervalSince(lastModelRefresh!) > 300 else { return }
        refreshModels()
    }

    private func currentRuntimeFingerprint() -> String? {
        guard codexSyncEnabled else { return nil }
        guard let url = codexExecutableURLs().first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }),
              let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        else { return nil }
        return "\(url.path)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values.fileSize ?? 0)"
    }

    private func adoptUpdatedRuntimeIfIdle() {
        guard codexSyncEnabled else { return }
        guard !usesExternalAppServer, !isRunning, !isRemoteTaskActive, conversationRequests == 0,
              !isLoadingTaskHistory, !isLoadingProjects, !isReadingSelectedTask,
              settingsLoadingMethods.isEmpty, accountLogin == nil, delayedConnectionTask == nil,
              !pendingRequests.values.contains(where: { if case .initialize = $0 { return true }; return false }),
              let fingerprint = currentRuntimeFingerprint(), fingerprint != runtimeFingerprint else { return }
        let previousThread = threadID
        stopAppServer()
        threadID = previousThread
        needsThreadResume = previousThread != nil
        stopManagedServer()
        saveAppServerURL("", isManual: false)
        hasManagedBackgroundServer = false
        runtimeFingerprint = fingerprint
    }

    func conversationEndpoint() async throws -> URL {
        guard requireCodexSync() else { throw UserFacingError(statusMessage) }
        refreshModelsIfNeeded()
        for _ in 0..<300 {
            try Task.checkCancellation()
            guard codexSyncEnabled else { throw UserFacingError("Codex sync was turned off.") }
            if connectionReady, !isLoadingModels, let url = localAppServerURL {
                guard !availableModels.isEmpty else { throw UserFacingError(modelLoadError ?? "No Codex models available.") }
                return url
            }
            if let modelLoadError, !isLoadingModels { throw UserFacingError(modelLoadError) }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw UserFacingError("Codex connection timed out. Check the desktop login and try again.")
    }

    func conversationResponse(_ request: VisionRequest, onEvent: VisionResponseHandler? = nil) async throws -> String {
        let endpoint = try await conversationEndpoint()
        return try await conversationResponse(request, endpoint: endpoint, model: selectedModel, effort: selectedReasoningEffort, onEvent: onEvent)
    }

    /// Translation keeps its model selection stable across the initial request and refinements.
    func conversationResponse(_ request: VisionRequest, model: String, effort: String?, isTranslation: Bool = false) async throws -> String {
        let endpoint = try await conversationEndpoint()
        return try await conversationResponse(request, endpoint: endpoint, model: model, effort: effort, isTranslation: isTranslation)
    }

    private func conversationResponse(_ request: VisionRequest, endpoint: URL, model: String, effort: String?, isTranslation: Bool = false, onEvent: VisionResponseHandler? = nil) async throws -> String {
        conversationRequests += 1
        defer { conversationRequests -= 1 }
        return try await CodexConversationClient(endpoint: endpoint).respond(
            to: request, model: model, effort: effort, isTranslation: isTranslation, onEvent: onEvent)
    }

    func refreshModels() {
        guard codexSyncEnabled else { return }
        adoptUpdatedRuntimeIfIdle()
        refreshModelsOnCurrentConnection()
    }

    private func refreshModelsOnCurrentConnection() {
        guard codexSyncEnabled else { return }
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

    /// Default discovery stays local to skills and collaboration modes. Apps require an explicit visit.
    func refreshCapabilities() { requestCapabilities(["skills/list", "collaborationMode/list"]) }
    func refreshSkills() { requestCapabilities(["skills/list"]) }
    func refreshPlugins() { requestCapabilities(["plugin/list"]) }
    func refreshApps() { requestCapabilities(["app/list"]) }
    func refreshMCPServers() { requestCapabilities(["mcpServerStatus/list"]) }

    var canWriteConfiguration: Bool {
        !isRunning && !isRemoteTaskActive && requirementsLoaded && configuration?.userVersion?.isEmpty == false
            && configuration?.userFilePath?.hasPrefix("/") == true
            && settingsLoadingMethods.isDisjoint(with: ["config/read", "configRequirements/read", "config/value/write"])
    }

    func refreshAccount() { requestSetting("account/read", params: ["refreshToken": false]) }

    func startAccountLogin(deviceCode: Bool = false) {
        guard requireCodexSync() else { return }
        guard !isRunning, !isRemoteTaskActive, accountLogin == nil,
              settingsLoadingMethods.isDisjoint(with: ["account/login/start", "account/login/cancel", "account/logout"]) else { return }
        if let allowed = configurationRequirements?.allowedLoginMethods, !allowed.contains("chatgpt") {
            recordSettingsError("account/login/start", "ChatGPT sign-in is disabled by managed requirements.")
            return
        }
        accountStatusMessage = "Starting ChatGPT sign-in…"
        requestSetting("account/login/start", params: ["type": deviceCode ? "chatgptDeviceCode" : "chatgpt"])
    }

    func cancelAccountLogin() {
        guard requireCodexSync() else { return }
        guard let login = accountLogin else { return }
        requestSetting("account/login/cancel", params: ["loginId": login.id])
    }

    func logoutAccount() {
        guard requireCodexSync() else { return }
        guard !isRunning, !isRemoteTaskActive,
              settingsLoadingMethods.isDisjoint(with: ["account/login/start", "account/login/cancel", "account/logout"]) else { return }
        requestSetting("account/logout", params: [:])
    }

    func refreshRateLimits() { requestSetting("account/rateLimits/read", params: [:]) }
    func refreshAccountUsage() { requestSetting("account/usage/read", params: [:]) }

    func refreshConfiguration() {
        guard !settingsLoadingMethods.contains("config/value/write") else { return }
        var params: [String: Any] = ["includeLayers": true]
        if let workspaceURL { params["cwd"] = workspaceURL.path }
        requestSetting("config/read", params: params)
        requestSetting("configRequirements/read", params: [:])
    }

    func refreshExperimentalFeatures() {
        guard !settingsLoadingMethods.contains("experimentalFeature/list") else { return }
        featureRows = []
        featureCursors = []
        var params: [String: Any] = ["limit": 100]
        if let threadID, !needsThreadResume { params["threadId"] = threadID }
        requestSetting("experimentalFeature/list", params: params)
    }

    @discardableResult
    func setConfigurationValue(_ key: String, value: Any) -> Bool {
        guard requireCodexSync() else { return false }
        let options: [String: Set<String>] = ["web_search": ["disabled", "cached", "indexed", "live"],
            "model_verbosity": ["low", "medium", "high"], "model_reasoning_summary": ["auto", "concise", "detailed", "none"]]
        guard options[key] != nil || key == "analytics.enabled" else {
            recordSettingsError("config/value/write", "This setting is read-only in Marr.")
            return false
        }
        if !(value is NSNull) {
            if key == "analytics.enabled" {
                guard let bool = value as? NSNumber, CFGetTypeID(bool) == CFBooleanGetTypeID() else {
                    recordSettingsError("config/value/write", "Analytics must be a boolean."); return false
                }
            } else if let text = value as? String, options[key]?.contains(text) == true {
                if key == "web_search", let allowed = configurationRequirements?.allowedWebSearchModes, !allowed.contains(text) {
                    recordSettingsError("config/value/write", "This web search mode is disabled by managed requirements."); return false
                }
            } else { recordSettingsError("config/value/write", "Unsupported setting value."); return false }
        }
        guard canWriteConfiguration, let file = configuration?.userFilePath, let version = configuration?.userVersion else {
            recordSettingsError("config/value/write", "Refresh configuration and wait for active work to finish before changing settings.")
            return false
        }
        configurationStatusMessage = "Saving user configuration…"
        requestSetting("config/value/write", params: ["keyPath": key, "value": value, "mergeStrategy": "replace",
            "filePath": file, "expectedVersion": version])
        return true
    }

    private func requestSetting(_ method: String, params: [String: Any]) {
        guard codexSyncEnabled else {
            recordSettingsError(method, "Enable Sync Codex work in Settings first.")
            return
        }
        // Choose an updated runtime before queuing settings, never during an OAuth flow.
        if !connectionReady { adoptUpdatedRuntimeIfIdle() }
        guard !settingsLoadingMethods.contains(method) else { return }
        let token = UUID()
        settingsRequestTokens[method] = token
        settingsLoadingMethods.insert(method)
        settingsErrors.removeValue(forKey: method)
        settingsDiagnostics.removeValue(forKey: method)
        enqueueOperation(method, params: params, pending: .settings(method, token))
    }

    private func recordSettingsError(_ method: String, _ message: String) {
        // Authentication and config errors can contain credentials; retain a bounded, redacted diagnostic.
        let redacted = message.replacingOccurrences(of: #"(?i)(bearer\s+|(?:access[_-]?token|refresh[_-]?token|api[_-]?key|authorization|password|secret)\s*[\"']?\s*[=:]\s*[\"']?)[^\s\"',;<>]+"#,
            with: "$1[redacted]", options: .regularExpression)
        settingsDiagnostics[method] = String(redacted.prefix(16_384))
        settingsErrors[method] = Self.safeErrorSummary(redacted)
    }

    private func invalidateSetting(_ method: String) {
        settingsRequestTokens.removeValue(forKey: method)
        settingsLoadingMethods.remove(method)
    }

    private func consumeSetting(_ method: String, result: [String: Any], token: UUID) {
        switch method {
        case "account/read":
            account = (result["account"] as? [String: Any]).flatMap(CodexAccount.init(json:))
            requiresOpenAIAuth = result["requiresOpenaiAuth"] as? Bool
        case "account/login/start":
            accountLogin = CodexAccountLogin(json: result)
            guard let login = accountLogin else {
                recordSettingsError(method, "The runtime did not return a usable sign-in flow."); return
            }
            accountStatusMessage = "Complete sign-in in your browser."
            if let completed = earlyLoginCompletions.removeValue(forKey: login.id) { completeAccountLogin(completed) }
            earlyLoginCompletions = [:]
        case "account/login/cancel":
            accountLogin = nil
            earlyLoginCompletions = [:]
            accountStatusMessage = result["status"] as? String == "notFound" ? "The sign-in flow is no longer active." : "Sign-in cancelled."
            invalidateSetting("account/login/start")
        case "account/logout":
            account = nil
            accountLogin = nil
            requiresOpenAIAuth = nil
            accountStatusMessage = "Signed out of the connected Codex runtime."
            resetRateLimits()
            invalidateSetting("account/read")
            invalidateSetting("account/rateLimits/read")
            invalidateSetting("account/usage/read")
            refreshAccount()
        case "account/rateLimits/read":
            ordinaryUsageAllowed = result["ordinaryUsageAllowed"] as? Bool
            if let buckets = result["rateLimitsByLimitId"] as? [String: [String: Any]], !buckets.isEmpty {
                rateLimitRows = buckets
            } else if let legacy = result["rateLimits"] as? [String: Any] {
                rateLimitRows = [legacy["limitId"] as? String ?? "codex": legacy]
            } else { rateLimitRows = [:] }
            publishRateLimits()
        case "account/usage/read":
            accountUsage = CodexAccountUsage(json: result)
        case "config/read":
            configuration = CodexConfiguration(json: result)
            if configuration == nil { recordSettingsError(method, "The runtime did not return configuration.") }
        case "configRequirements/read":
            requirementsLoaded = true
            configurationRequirements = CodexConfigurationRequirements(json: result["requirements"] as? [String: Any] ?? [:])
        case "config/value/write":
            if result["status"] as? String == "okOverridden" {
                configurationStatusMessage = "Saved to user configuration, but a higher-priority layer overrides this value."
            } else { configurationStatusMessage = "User configuration saved. Effective values were refreshed; new defaults apply to new tasks." }
            refreshConfiguration()
        case "experimentalFeature/list":
            for feature in (result["data"] as? [[String: Any]] ?? []).compactMap(CodexExperimentalFeature.init(json:)) {
                if let index = featureRows.firstIndex(where: { $0.id == feature.id }) { featureRows[index] = feature }
                else { featureRows.append(feature) }
            }
            if let cursor = result["nextCursor"] as? String, !cursor.isEmpty {
                guard featureCursors.insert(cursor).inserted else {
                    recordSettingsError(method, "The runtime repeated an experimental feature page."); return
                }
                settingsLoadingMethods.insert(method)
                var params: [String: Any] = ["limit": 100, "cursor": cursor]
                if let threadID, !needsThreadResume { params["threadId"] = threadID }
                sendRequest(method: method, params: params, pending: .settings(method, token))
            } else { experimentalFeatures = featureRows }
        default: break
        }
    }

    private func publishRateLimits() {
        rateLimitBuckets = rateLimitRows.keys.sorted().map { CodexRateLimitBucket(id: $0, json: rateLimitRows[$0] ?? [:]) }
    }

    private func resetRateLimits() {
        threadTokenUsage = [:]
        tokenUsageModelsByTurn = [:]
        rateLimitRows = [:]
        rateLimitBuckets = []
        ordinaryUsageAllowed = nil
        accountUsage = nil
    }

    private func completeAccountLogin(_ params: [String: Any]) {
        guard let current = accountLogin else {
            if settingsLoadingMethods.contains("account/login/start"), let id = params["loginId"] as? String {
                earlyLoginCompletions[id] = params
            }
            return
        }
        guard params["loginId"] as? String == current.id else { return }
        accountLogin = nil
        invalidateSetting("account/login/cancel")
        if params["success"] as? Bool == true {
            accountStatusMessage = "Sign-in completed."
            invalidateSetting("account/read")
            invalidateSetting("account/rateLimits/read")
            invalidateSetting("account/usage/read")
            resetRateLimits()
            refreshAccount()
            refreshRateLimits()
            refreshAccountUsage()
            refreshModelsOnCurrentConnection()
        } else {
            accountStatusMessage = "Sign-in did not complete."
            recordSettingsError("account/login/start", params["error"] as? String ?? "Sign-in failed.")
        }
    }

    private func handleSettingsNotification(_ method: String, params: [String: Any]) -> Bool {
        switch method {
        case "account/login/completed": completeAccountLogin(params)
        case "account/updated":
            account = nil
            requiresOpenAIAuth = nil
            resetRateLimits()
            invalidateSetting("account/read")
            invalidateSetting("account/rateLimits/read")
            invalidateSetting("account/usage/read")
            refreshAccount()
            if params["authMode"] as? String != nil { refreshRateLimits(); refreshAccountUsage() }
        case "account/rateLimits/updated":
            guard let update = params["rateLimits"] as? [String: Any] else { return true }
            let hadPendingRead = settingsLoadingMethods.contains("account/rateLimits/read")
            if hadPendingRead { invalidateSetting("account/rateLimits/read") }
            guard let id = update["limitId"] as? String ?? (rateLimitRows.count == 1 ? rateLimitRows.keys.first : nil) else {
                refreshRateLimits(); return true
            }
            func merge(_ old: [String: Any], _ new: [String: Any], isSnapshot: Bool = false) -> [String: Any] {
                var output = old
                // The protocol treats null account metadata as unavailable. Explicitly null
                // quota windows/credits, however, must not keep showing an old balance.
                let metadataKeys: Set<String> = ["limitId", "limitName", "planType", "normalModelSlug"]
                for (key, value) in new {
                    if value is NSNull, isSnapshot && metadataKeys.contains(key) { continue }
                    if let nested = value as? [String: Any] { output[key] = merge(old[key] as? [String: Any] ?? [:], nested) }
                    else { output[key] = value }
                }
                return output
            }
            rateLimitRows[id] = merge(rateLimitRows[id] ?? [:], update, isSnapshot: true)
            publishRateLimits()
            if hadPendingRead { refreshRateLimits() }
        default: return false
        }
        return true
    }

    private func resetSettingsState() {
        settingsRequestTokens = [:]
        settingsLoadingMethods = []
        settingsErrors = [:]
        settingsDiagnostics = [:]
        account = nil
        accountLogin = nil
        requiresOpenAIAuth = nil
        accountStatusMessage = ""
        earlyLoginCompletions = [:]
        resetRateLimits()
        configuration = nil
        configurationRequirements = nil
        requirementsLoaded = false
        configurationStatusMessage = ""
        experimentalFeatures = []
        featureRows = []
        featureCursors = []
    }

    private func requestCapabilities(_ methods: Set<String>) {
        guard codexSyncEnabled else { return }
        requestedCapabilityMethods.formUnion(methods)
        if connectionReady { sendCapabilityRequests() }
        else {
            if connectionIntent == nil { connectionIntent = .listModels }
            connectForCurrentIntent()
        }
    }

    private func sendCapabilityRequests() {
        guard connectionReady else { return }
        let methods = requestedCapabilityMethods.subtracting(loadingCapabilityMethods)
        requestedCapabilityMethods.subtract(methods)
        loadingCapabilityMethods.formUnion(methods)
        isLoadingCapabilities = !loadingCapabilityMethods.isEmpty
        for method in methods.sorted() {
            capabilityRows[method] = []
            capabilityErrors.removeValue(forKey: method)
            capabilityDiagnostics.removeValue(forKey: method)
            sendCapabilityPage(method)
        }
    }

    private func recordCapabilityError(_ method: String, _ raw: String) {
        capabilityDiagnostics[method] = String(raw.prefix(131_072))
        capabilityErrors[method] = Self.safeErrorSummary(raw)
    }

    static func safeErrorSummary(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("403") || lower.contains("forbidden") || lower.contains("access denied") {
            return "Access denied (403). This capability is unavailable for the connected account."
        }
        if lower.contains("401") || lower.contains("unauthorized") {
            return "Authentication required (401). Check the connected Codex account."
        }
        if lower.contains("<!doctype") || lower.contains("<html") || lower.contains("<body") {
            return "The service returned a web error page. Open diagnostics for details."
        }
        var text = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        text = text.replacingOccurrences(of: #"(?i)(bearer\s+|(?:token|api[_-]?key|authorization|password|secret)\s*[=:]\s*)[^\s,;]+"#,
            with: "$1[redacted]", options: .regularExpression)
        return text.isEmpty ? "The capability request failed." : String(text.prefix(320))
    }

    private func sendCapabilityPage(_ method: String, cursor: String? = nil) {
        var params: [String: Any] = [:]
        switch method {
        case "skills/list":
            params["forceReload"] = true
            if let workspaceURL { params["cwds"] = [workspaceURL.path] }
        case "plugin/list", "plugin/installed":
            if let workspaceURL { params["cwds"] = [workspaceURL.path] }
        case "app/list", "mcpServerStatus/list":
            params["limit"] = 100
            if let cursor { params["cursor"] = cursor }
            if let threadID, !needsThreadResume { params["threadId"] = threadID }
            if method == "mcpServerStatus/list" { params["detail"] = "full" }
        default: break
        }
        sendRequest(method: method, params: params, pending: .capability(method))
    }

    func setSkillEnabled(_ skill: CodexSkill, enabled: Bool) {
        enqueueOperation("skills/config/write", params: ["path": skill.path, "enabled": enabled], pending: .skillWrite)
    }

    func installPlugin(_ entry: CodexExtensionEntry) {
        guard requireCodexSync() else { return }
        guard entry.canInstall, !pluginOperationsInFlight.contains(entry.id), let name = entry.pluginName else { return }
        var params: [String: Any] = ["pluginName": name]
        if let path = entry.marketplacePath { params["marketplacePath"] = path }
        else if let name = entry.remoteMarketplaceName { params["remoteMarketplaceName"] = name }
        else { capabilityErrors["plugin/install"] = "Marketplace identity is unavailable."; return }
        pluginOperationsInFlight.insert(entry.id)
        enqueueOperation("plugin/install", params: params, pending: .pluginMutation("plugin/install", entry.id))
    }

    func uninstallPlugin(_ entry: CodexExtensionEntry) {
        guard requireCodexSync() else { return }
        guard entry.kind == "Plugin", entry.installed == true, !pluginOperationsInFlight.contains(entry.id), let id = entry.rawPluginID else { return }
        pluginOperationsInFlight.insert(entry.id)
        enqueueOperation("plugin/uninstall", params: ["pluginId": id], pending: .pluginMutation("plugin/uninstall", entry.id))
    }

    func toggleSkillSelection(_ skill: CodexSkill) {
        guard skill.enabled else { return }
        if selectedSkillPaths.contains(skill.path) { removeComposerBinding("skill:\(skill.path)") }
        else { bindSkillMention(skill) }
    }

    func bindSkillMention(_ skill: CodexSkill) {
        guard skill.enabled else { return }
        var bindings = composerBindings.filter { $0.kind != .skill || $0.name != skill.name }
        bindings.append(ComposerMentionBinding(kind: .skill, name: skill.name, path: skill.path, reference: skill.name))
        updateComposerBindings(bindings)
    }

    func bindFileMention(path: String) {
        guard path.hasPrefix("/") else { return }
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        var bindings = composerBindings.filter { $0.id != "file:\(path)" }
        bindings.append(ComposerMentionBinding(kind: .file, name: URL(fileURLWithPath: path).lastPathComponent,
                                              path: path, reference: path))
        updateComposerBindings(bindings)
    }

    /// Bind an explicit selection to its exact protocol target. Merely typing a
    /// plugin-like name is not enough to attach an integration to a message.
    func bindExtensionMention(_ entry: CodexExtensionEntry) -> String? {
        guard entry.mentionPath != nil else { return nil }
        let duplicate = extensions.contains { $0.id != entry.id && $0.name == entry.name && $0.mentionPath != nil }
        let reference = duplicate ? entry.name + " · " + entry.id : entry.name
        var bindings = composerBindings.filter { $0.id != "integration:\(entry.mentionPath!)" }
        bindings.append(ComposerMentionBinding(kind: .integration, name: entry.name,
                                              path: entry.mentionPath!, reference: reference))
        updateComposerBindings(bindings)
        return reference
    }

    var composerDraftKey: ComposerDraftKey {
        .work(workspaceID: workbench.selectedWorkspaceID, taskID: activeTaskID)
    }

    func removeComposerBinding(_ id: String) {
        updateComposerBindings(composerBindings.filter { $0.id != id })
    }

    private func updateComposerBindings(_ bindings: [ComposerMentionBinding]) {
        applyComposerBindings(bindings)
        var draft = composerDraftStore.draft(for: composerDraftKey)
        draft.bindings = bindings
        composerDraftStore.save(draft, for: composerDraftKey)
    }

    private func applyComposerBindings(_ bindings: [ComposerMentionBinding]) {
        composerBindings = bindings
        selectedSkillPaths = Set(bindings.filter { $0.kind == .skill }.map(\.path))
        boundFilePaths = Set(bindings.filter { $0.kind == .file }.map(\.path))
        boundExtensionMentions = Dictionary(bindings.filter { $0.kind == .integration }
            .map { ($0.reference, $0) }, uniquingKeysWith: { _, latest in latest })
    }

    private func loadComposerBindings() {
        applyComposerBindings(composerDraftStore.draft(for: composerDraftKey).bindings)
    }

    func reloadComposerBindings() { loadComposerBindings() }

    /// Recovery changes context before exposing the draft. An unavailable or
    /// running origin leaves the recovery intact for a later attempt.
    @discardableResult
    func restoreRecoveredDraft(_ draft: CodexSubmissionDraft) -> Bool {
        guard requireCodexSync() else { return false }
        guard !isRunning, !isRemoteTaskActive else {
            commandOutput = "Finish or stop the active task before restoring another message."
            return false
        }
        guard let workspaceID = draft.workspaceID,
              let workspace = workbench.workspaces.first(where: { $0.id == workspaceID }) else {
            commandOutput = "The original project is unavailable. This message has been kept."
            return false
        }
        let originalTask = draft.taskID.flatMap { id in workbench.tasks.first { $0.id == id && $0.workspaceID == workspaceID } }
            ?? draft.threadID.flatMap { thread in workbench.tasks.first { $0.threadID == thread && $0.workspaceID == workspaceID } }
        if (draft.taskID != nil || draft.threadID != nil), originalTask == nil {
            commandOutput = "The original task is unavailable. This message has been kept."
            return false
        }
        if let task = originalTask, workbench.isTaskArchived(task.id) {
            commandOutput = "Unarchive the original task before restoring its message."
            return false
        }
        do {
            try activateWorkspace(workspace)
            if let task = originalTask {
                workbench.selectTask(task.id)
                restoreSavedTask(task)
                if let threadID = task.threadID { connectionIntent = .readThread(threadID) }
            } else {
                startNewTask()
            }
            let key = composerDraftKey
            let incoming = ComposerDraft(text: draft.prompt,
                selection: NSRange(location: draft.prompt.utf16.count, length: 0),
                attachments: draft.attachments, bindings: draft.bindings)
            guard composerDraftStore.save(ComposerDraftStore.merging(composerDraftStore.draft(for: key), with: incoming), for: key) else {
                commandOutput = composerDraftStore.lastErrorMessage ?? "The recovered draft could not be saved."
                return false
            }
            discardRecoverableDraft(draft.id)
            loadComposerBindings()
            if case .readThread = connectionIntent { connectForCurrentIntent() }
            return true
        } catch {
            commandOutput = "The original project could not be opened: \(error.localizedDescription)"
            return false
        }
    }

    func searchFiles(query: String) {
        guard requireCodexSync() else { return }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        clearFileSearch()
        guard !query.isEmpty, let workspaceURL else { return }
        isSearchingFiles = true
        let generation = fileSearchGeneration
        enqueueOperation("fuzzyFileSearch", params: ["query": query, "roots": [workspaceURL.path],
            "cancellationToken": generation.uuidString], pending: .fileSearch(generation))
    }

    func clearFileSearch() {
        fileSearchGeneration = UUID()
        fileSearchResults = []
        fileSearchError = nil
        isSearchingFiles = false
    }

    func selectCollaborationMode(_ id: String?) {
        guard !isRunning else { return }
        selectedCollaborationModeID = collaborationModes.contains(where: { $0.id == id }) ? id : nil
    }

    func reloadMCPServers() {
        enqueueOperation("config/mcpServer/reload", params: [:], pending: .reloadMCP)
    }

    func loginMCPServer(_ name: String) {
        var params: [String: Any] = ["name": name]
        if let threadID, !needsThreadResume { params["threadId"] = threadID }
        enqueueOperation("mcpServer/oauth/login", params: params, pending: .loginMCP(name))
    }

    func forkSelectedTask() {
        guard canForkSelectedTask, let threadID else { return }
        enqueueOperation("thread/fork", params: ["threadId": threadID], pending: .forkThread)
    }

    func archiveTask(_ task: SavedTask) {
        guard requireCodexSync() else { return }
        guard !(task.id == activeTaskID && isRunning), !archivingTaskIDs.contains(task.id) else { return }
        archiveReconciliationCandidates.remove(task.id)
        capabilityErrors.removeValue(forKey: "thread/archive")
        capabilityDiagnostics.removeValue(forKey: "thread/archive")
        guard let threadID = task.threadID else {
            workbench.archiveTask(task.id)
            if task.id == activeTaskID { startNewTask() }
            refreshSavedTasks()
            return
        }
        archivingTaskIDs.insert(task.id)
        enqueueOperation("thread/archive", params: ["threadId": threadID], pending: .archiveThread(task.id, true))
    }

    func unarchiveTask(_ task: SavedTask) {
        guard requireCodexSync() else { return }
        guard !archivingTaskIDs.contains(task.id) else { return }
        archiveReconciliationCandidates.remove(task.id)
        capabilityErrors.removeValue(forKey: "thread/unarchive")
        capabilityDiagnostics.removeValue(forKey: "thread/unarchive")
        guard let threadID = task.threadID else {
            workbench.unarchiveTask(task.id)
            refreshSavedTasks()
            return
        }
        archivingTaskIDs.insert(task.id)
        enqueueOperation("thread/unarchive", params: ["threadId": threadID], pending: .archiveThread(task.id, false))
    }

    private func enqueueOperation(_ method: String, params: [String: Any], pending: PendingRequest, draft: CodexSubmissionDraft? = nil) {
        guard requireCodexSync() else { return }
        if let draft { composerDraftStore.retainRecovery(draft) }
        if connectionReady { sendRequest(method: method, params: params, pending: pending, draft: draft) }
        else {
            pendingThreadActions.append((method, params, pending, draft))
            if connectionIntent == nil { connectionIntent = .listModels }
            connectForCurrentIntent()
        }
    }

    private func consumeCapability(_ method: String, result: [String: Any]) {
        if method == "plugin/installed" || method == "plugin/list" {
            let marketplaces = result["marketplaces"] as? [[String: Any]] ?? []
            capabilityRows[method] = marketplaces.flatMap { marketplace -> [[String: Any]] in
                (marketplace["plugins"] as? [[String: Any]] ?? []).map { original in
                    var row = original
                    row["marketplacePath"] = marketplace["path"] as? String
                    row["remoteMarketplaceName"] = marketplace["name"] as? String
                    return row
                }
            }
            let failures = result["marketplaceLoadErrors"] as? [[String: Any]] ?? []
            if !failures.isEmpty {
                recordCapabilityError(method, failures.compactMap { $0["message"] as? String }.joined(separator: "\n"))
            }
        } else {
            capabilityRows[method, default: []].append(contentsOf: result["data"] as? [[String: Any]] ?? [])
        }
        if let cursor = result["nextCursor"] as? String, !cursor.isEmpty {
            sendCapabilityPage(method, cursor: cursor)
            return
        }
        let rows = capabilityRows[method] ?? []
        switch method {
        case "skills/list":
            var seen = Set<String>()
            skills = rows.flatMap { $0["skills"] as? [[String: Any]] ?? [] }.compactMap(CodexSkill.init(json:))
                .filter { seen.insert($0.path).inserted }
            selectedSkillPaths.formIntersection(Set(skills.filter(\.enabled).map(\.path)))
            let errors = rows.flatMap { $0["errors"] as? [[String: Any]] ?? [] }
            if !errors.isEmpty { recordCapabilityError(method, errors.compactMap { $0["message"] as? String }.joined(separator: "\n")) }
        case "collaborationMode/list":
            collaborationModes = rows.compactMap(CodexCollaborationMode.init(json:))
        default:
            let kind = method == "app/list" ? "App" : (["plugin/list", "plugin/installed"].contains(method) ? "Plugin" : "MCP")
            extensions.removeAll { $0.kind == kind }
            for row in rows {
                let name = row["name"] as? String ?? row["id"] as? String ?? "Extension"
                let identifier = row["id"] as? String ?? name
                let interface = row["interface"] as? [String: Any] ?? [:]
                let enabled = row["enabled"] as? Bool ?? row["isEnabled"] as? Bool
                let status: String
                if kind == "MCP" {
                    status = row["authStatus"] as? String ?? "Unknown"
                } else if kind == "App" {
                    status = (row["isAccessible"] as? Bool == true) ? "Available" : "Unavailable"
                } else {
                    status = row["installed"] as? Bool == true ? "Installed" : "Not installed"
                }
                let toolCount = (row["tools"] as? [String: Any])?.count
                extensions.append(CodexExtensionEntry(
                    id: "\(kind):\(identifier)", name: interface["displayName"] as? String ?? name,
                    kind: kind,
                    detail: row["description"] as? String ?? interface["shortDescription"] as? String ?? toolCount.map { "\($0) tools" } ?? "",
                    status: status, enabled: enabled,
                    url: (row["installUrl"] as? String).flatMap(URL.init(string:)),
                    installed: row["installed"] as? Bool,
                    rawPluginID: kind == "Plugin" ? identifier : nil,
                    pluginName: kind == "Plugin" ? name : nil,
                    marketplacePath: row["marketplacePath"] as? String,
                    remoteMarketplaceName: row["remoteMarketplaceName"] as? String,
                    canInstall: kind == "Plugin" && row["installed"] as? Bool != true
                        && row["availability"] as? String == "AVAILABLE"
                        && ["AVAILABLE", "INSTALLED_BY_DEFAULT"].contains(row["installPolicy"] as? String ?? "")
                        && row["mustShowInstallationInterstitial"] as? Bool != true
                ))
            }
        }
        loadingCapabilityMethods.remove(method)
        isLoadingCapabilities = !loadingCapabilityMethods.isEmpty
        if capabilityRefreshPending { sendCapabilityRequests() }
    }

    func respondToInteraction(_ request: CodexInteractionRequest, action: CodexInteractionAction,
                              answers: [String: [String]] = [:], formValues: [String: String] = [:]) {
        guard pendingInteractions.contains(where: { $0.id == request.id }) else { return }
        do {
            let result = try request.response(action: action, answers: answers, formValues: formValues)
            interactionErrors.removeValue(forKey: request.id)
            sendResponse(id: request.id.rawValue, result: result)
            pendingInteractions.removeAll { $0.id == request.id }
            refreshLegacyApproval()
        } catch {
            interactionErrors[request.id] = error.localizedDescription
        }
    }

    func respondToApprovalDecision(_ request: CodexInteractionRequest, decision: CodexApprovalDecision) {
        guard pendingInteractions.contains(where: { $0.id == request.id }) else { return }
        do {
            let result = try request.approvalResponse(decision: decision)
            interactionErrors.removeValue(forKey: request.id)
            sendResponse(id: request.id.rawValue, result: result)
            pendingInteractions.removeAll { $0.id == request.id }
            refreshLegacyApproval()
        } catch {
            interactionErrors[request.id] = error.localizedDescription
        }
    }

    func discardRecoverableDraft(_ id: UUID) {
        guard composerDraftStore.removeRecovery(id) else { return }
        recoverableDrafts.removeAll { $0.id == id }
    }

    private func recoverDraft(_ draft: CodexSubmissionDraft, error: String) {
        guard !recoverableDrafts.contains(where: { $0.id == draft.id }) else { return }
        var recovered = draft
        recovered.error = error
        composerDraftStore.retainRecovery(recovered)
        recoverableDrafts.append(recovered)
    }

    private func refreshLegacyApproval() {
        // Kept for older views; the full queue is authoritative.
        guard let first = pendingInteractions.first, case .integer(let id) = first.id,
              ["item/commandExecution/requestApproval", "item/fileChange/requestApproval"].contains(first.method) else {
            approvalRequest = nil
            return
        }
        approvalRequest = CodexApprovalRequest(id: id,
            kind: first.method == "item/fileChange/requestApproval" ? .fileChange : .command,
            reason: first.message, preview: first.preview)
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
        guard !isRunning, !isRemoteTaskActive, availableModels.contains(where: { $0.id == model }) else { return }
        selectedModel = model
        defaults.set(model, forKey: selectedModelKey)
        selectedReasoningEffort = availableModels.first { $0.id == model }?.defaultReasoningEffort
    }

    var availableReasoningEfforts: [String] {
        availableModels.first { $0.id == selectedModel }?.reasoningEfforts ?? []
    }

    func selectReasoningEffort(_ effort: String) {
        guard !isRunning, !isRemoteTaskActive, availableReasoningEfforts.contains(effort) else { return }
        selectedReasoningEffort = effort
    }

    func useDesktopRuntime() {
        guard requireCodexSync() else { return }
        guard !isRunning, conversationRequests == 0 else { return }
        runtimeFingerprint = nil
        useAutomaticCodexCLIPath()
        saveAppServerURL("", isManual: false)
        hasManagedBackgroundServer = false
        refreshModels()
    }

    /// These gates are supplied by the visible Work/sidebar surface and the app
    /// lifecycle. Constructing/restoring a workspace never starts a connection.
    func setHistorySyncVisible(_ visible: Bool) {
        guard historySyncVisible != visible else { return }
        historySyncVisible = visible
        updateHistorySyncLifecycle()
    }

    func setHistorySyncAppActive(_ active: Bool) {
        guard historySyncAppActive != active else { return }
        historySyncAppActive = active
        updateHistorySyncLifecycle()
    }

    func setHistorySyncUserScrolling(_ scrolling: Bool) {
        historySyncUserScrolling = scrolling
    }

    private func updateHistorySyncLifecycle() {
        historySyncTask?.cancel()
        historySyncTask = nil
        guard codexSyncEnabled else { invalidateHistorySync(); return }
        if (!historySyncVisible || !historySyncAppActive), historySyncReadOnlyConnection, !connectionReady {
            let keepRemoteLock = isRemoteTaskActive
            let keepUncertainty = isTaskStatusUncertain
            let previousStatus = historySyncConnectionStatus
            stopAppServer()
            isRemoteTaskActive = keepRemoteLock
            isTaskStatusUncertain = keepUncertainty
            if let previousStatus { statusMessage = previousStatus }
            historySyncConnectionStatus = nil
        } else { invalidateHistorySync() }
        guard historySyncVisible, historySyncAppActive else { return }
        historySyncRetryAfter = .distantPast
        historySyncFailures = 0
        performHistorySyncTick()
        historySyncTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                self.performHistorySyncTick()
            }
        }
    }

    /// A deterministic entry point for timer tests. A single request is in
    /// flight, including connection setup; each reply is scoped to its epoch.
    func performHistorySyncTick(now: Date = Date()) {
        guard codexSyncEnabled else { return }
        if historySyncVisible && historySyncAppActive { refreshDesktopSidebarPreferences(now: now) }
        guard historySyncVisible, historySyncAppActive, historySyncOperation == nil,
              !historySyncUserScrolling,
              now >= historySyncRetryAfter, !isReadingSelectedTask, !isResumingSavedHistory,
              !isLoadingTaskHistory, !isLoadingProjects, !isReconcilingConnection,
              !preparingCommandThread, pendingThreadActions.isEmpty,
              pendingRequests.isEmpty, delayedConnectionTask == nil || connectionReady else { return }
        // A restored running task leaves a deferred read intent. The foreground
        // poll may satisfy it without loading models, resuming, or subscribing.
        if case .readThread(let id) = connectionIntent, id == threadID, !connectionReady {
            connectionIntent = nil
        }
        guard connectionIntent == nil else { return }
        let identity = "\(codexCLIURL?.path ?? "automatic")|\(appServerURLString)|\(appServerURLIsManual)"
        if historySyncRuntimeIdentity != identity {
            historySyncRuntimeIdentity = identity
            historySyncProjectSupported = true
            historySyncSectionsSupported = true
        }
        if !isRunning, now >= historySyncNextRead, let threadID, !oversizedHistoryThreadIDs.contains(threadID), let taskID = activeTaskID,
           taskID == workbench.selectedTaskID, let workspaceID = workbench.selectedWorkspaceID {
            historySyncOperation = .read(threadID: threadID, taskID: taskID, workspaceID: workspaceID)
            historySyncRequestedReadRevision = historySyncReadRevision
            historySyncNextRead = now.addingTimeInterval(3)
        } else {
            if historySyncQueue.isEmpty {
                guard now >= historySyncNextDirectory else { return }
                historySyncNextDirectory = now.addingTimeInterval(12)
                historySyncCursors = []
                historySyncPageCount = 0
                if historySyncProjectSupported { historySyncQueue.append(.projects(nil)) }
                historySyncQueue.append(contentsOf: [.threads(archived: false, cursor: nil), .threads(archived: true, cursor: nil)])
                if workbench.supportsSharedSections && historySyncSectionsSupported {
                    historySyncPinnedIDs = []
                    historySyncQueue.append(.pinned(nil))
                }
            }
            historySyncOperation = historySyncQueue.removeFirst()
        }
        connectionIntent = .historySync
        connectForCurrentIntent()
    }

    private func sendHistorySyncOperation() {
        guard codexSyncEnabled else { return }
        guard historySyncVisible, historySyncAppActive,
              let operation = historySyncOperation else {
            if case .historySync = connectionIntent { connectionIntent = nil }
            return
        }
        connectionIntent = nil
        if let previousStatus = historySyncConnectionStatus { statusMessage = previousStatus; historySyncConnectionStatus = nil }
        let method: String
        var params: [String: Any]
        switch operation {
        case .pinned(let cursor):
            method = "thread/list"
            params = ["limit": 100, "sectionId": WorkbenchStore.pinnedSectionID,
                "sortKey": "section_position", "sourceKinds": Self.historySourceKinds, "modelProviders": [String](), "archived": false]
            if let cursor { params["cursor"] = cursor }
        case .projects(let cursor):
            method = "project/list"
            params = [:]
            if let cursor { params["cursor"] = cursor }
        case .threads(let archived, let cursor):
            method = "thread/list"
            // Omitted sourceKinds only returns CLI/VSCode. No cwd, serviceName,
            // project or provider filter: discover the shared runtime catalog.
            params = ["limit": 100, "sortKey": "updated_at", "archived": archived,
                      "sourceKinds": Self.historySourceKinds, "modelProviders": [String]()]
            if let cursor { params["cursor"] = cursor }
        case .read(let threadID, _, _):
            guard !isRunning else { historySyncOperation = nil; return }
            method = "thread/read"
            params = ["threadId": threadID, "includeTurns": true]
        }
        sendRequest(method: method, params: params, pending: .historySync(historySyncEpoch, operation))
    }

    private func invalidateHistorySync() {
        historySyncEpoch = UUID()
        historySyncOperation = nil
        historySyncQueue = []
        historySyncLastSnapshot = nil
        historySyncNextRead = .distantPast
        historySyncNextDirectory = .distantPast
        for (id, pending) in pendingRequests {
            if case .historySync = pending {
                pendingRequests.removeValue(forKey: id)
                requestTimeoutTasks.removeValue(forKey: id)?.cancel()
            }
        }
        if case .historySync = connectionIntent { connectionIntent = nil }
    }

    private func failHistorySyncConnection() {
        let keepRemoteLock = isRemoteTaskActive
        let keepUncertainty = isTaskStatusUncertain || keepRemoteLock
        let previousStatus = historySyncConnectionStatus
        stopAppServer()
        isRemoteTaskActive = keepRemoteLock
        isTaskStatusUncertain = keepUncertainty
        if let previousStatus { statusMessage = previousStatus }
        historySyncConnectionStatus = nil
        hasManagedBackgroundServer = false
        backoffHistorySync()
    }

    private func backoffHistorySync() {
        historySyncOperation = nil
        historySyncQueue = []
        historySyncFailures = min(historySyncFailures + 1, 5)
        historySyncRetryAfter = Date().addingTimeInterval(min(60, 3 * pow(2, Double(historySyncFailures - 1))))
    }

    private func consumeHistorySync(epoch: UUID, operation: HistorySyncOperation, message: [String: Any], preparedHistory: CodexPreparedHistory? = nil) {
        guard codexSyncEnabled, epoch == historySyncEpoch, historySyncVisible, historySyncAppActive,
              !isReadingSelectedTask, !isReconcilingConnection else { return }
        historySyncOperation = nil
        if let error = message["error"] as? [String: Any] {
            let errorText = (error["message"] as? String ?? "").lowercased()
            let unsupportedProject = error["code"] as? Int == -32601
                || errorText.contains("not supported") || errorText.contains("not enabled")
                || errorText.contains("project store") || errorText.contains("experimental api")
            if case .pinned = operation, unsupportedProject {
                historySyncSectionsSupported = false
                historySyncPinnedIDs = []
            } else if case .projects = operation, unsupportedProject {
                // Experimental project discovery is optional. A runtime may
                // reject the method, feature gate, or backing store; thread cwd
                // still discovers workspaces. Probe only once per configuration.
                historySyncProjectSupported = false
                historySyncQueue.removeAll { if case .projects = $0 { return true }; return false }
            } else { backoffHistorySync() }
            return
        }
        guard let result = message["result"] as? [String: Any] else { backoffHistorySync(); return }
        switch operation {
        case .read(let requestedThreadID, let taskID, let workspaceID):
            historySyncNextRead = Date().addingTimeInterval(3)
            guard !isRunning, requestedThreadID == threadID, taskID == activeTaskID,
                  taskID == workbench.selectedTaskID, workspaceID == workbench.selectedWorkspaceID,
                  historySyncRequestedReadRevision == historySyncReadRevision else { return }
            guard let thread = result["thread"] as? [String: Any],
                  thread["id"] as? String == requestedThreadID, thread["turns"] is [[String: Any]],
                  let status = (thread["status"] as? [String: Any])?["type"] as? String,
                  ["notLoaded", "idle", "active", "systemError"].contains(status) else {
                backoffHistorySync()
                return
            }
            // Compare the already decoded snapshot. Re-encoding every tool
            // payload with sorted keys every three seconds stalls scrolling.
            let snapshot = thread as NSDictionary
            if snapshot != historySyncLastSnapshot {
                // Cross-process disk snapshots can expose an interrupted or
                // unfinished turn even while the originating client still runs.
                if status == "notLoaded", historySyncConfirmsObservedTurnEnded(thread) {
                    isRemoteTaskActive = false
                    resolveTaskStatusUncertainty()
                } else if status != "notLoaded", includesReconciledTurn(thread) {
                    resolveTaskStatusUncertainty()
                }
                hydrateSelectedTask(from: thread, requestedThreadID: requestedThreadID, backgroundSync: true, preparedHistory: preparedHistory)
                if let last = (thread["turns"] as? [[String: Any]])?.last,
                   last["status"] as? String == "inProgress"
                    || (status == "notLoaded" && last["status"] as? String == "interrupted" && !RuntimeHistoryProjection.isDurableSnapshotTurnEnd(last)) {
                    historySyncObservedTurnID = last["id"] as? String
                    historySyncObservedThreadID = requestedThreadID
                } else if !isRemoteTaskActive { historySyncObservedTurnID = nil }
                historySyncLastSnapshot = snapshot
            }
        case .pinned:
            guard let rows = result["data"] as? [[String: Any]] else { backoffHistorySync(); return }
            historySyncPinnedIDs.append(contentsOf: rows.compactMap { $0["id"] as? String })
            mergeHistorySyncThreads(rows, archived: false)
            enqueueHistorySyncPage(result, operation: operation)
            if result["nextCursor"] as? String == nil { workbench.setSharedPinnedOrder(historySyncPinnedIDs) }
        case .projects:
            guard let rows = result["data"] as? [[String: Any]] else { backoffHistorySync(); return }
            workbench.importProjects(rows)
            refreshSavedWorkspaces()
            enqueueHistorySyncPage(result, operation: operation)
        case .threads(let archived, _):
            guard let rows = result["data"] as? [[String: Any]] else { backoffHistorySync(); return }
            mergeHistorySyncThreads(rows, archived: archived)
            enqueueHistorySyncPage(result, operation: operation)
            lastProjectSyncAt = Date()
        }
        historySyncFailures = 0
        historySyncRetryAfter = .distantPast
        if historySyncQueue.isEmpty {
            switch operation {
            case .read: break
            default: historySyncNextDirectory = Date().addingTimeInterval(12)
            }
        }
    }

    private func historySyncConfirmsObservedTurnEnded(_ thread: [String: Any]) -> Bool {
        let observed = historySyncObservedThreadID == threadID ? historySyncObservedTurnID : nil
        guard let expected = observed ?? uncertainTaskTurnID,
              let turns = thread["turns"] as? [[String: Any]],
              let index = turns.firstIndex(where: { $0["id"] as? String == expected }) else { return false }
        // Disk-only reads can synthesize `interrupted`; only durable completed
        // or failed outcomes for the observed turn (and any later turn) unlock.
        return turns[index...].allSatisfy(RuntimeHistoryProjection.isDurableSnapshotTurnEnd)
    }

    private func enqueueHistorySyncPage(_ result: [String: Any], operation: HistorySyncOperation) {
        guard let cursor = result["nextCursor"] as? String, !cursor.isEmpty else { return }
        let key: String
        let next: HistorySyncOperation
        switch operation {
        case .projects: key = "projects:\(cursor)"; next = .projects(cursor)
        case .pinned: key = "pinned:\(cursor)"; next = .pinned(cursor)
        case .threads(let archived, _): key = "\(archived):\(cursor)"; next = .threads(archived: archived, cursor: cursor)
        case .read: return
        }
        // Bound work even for broken cursors or enormous stores. Partial pages
        // are additive; absence never deletes or archives a cached thread.
        guard historySyncPageCount < 20, historySyncCursors.insert(key).inserted else { return }
        historySyncPageCount += 1
        historySyncQueue.insert(next, at: 0)
    }

    private func mergeHistorySyncThreads(_ rows: [[String: Any]], archived: Bool) {
        var changed = false
        for thread in rows {
            guard let id = thread["id"] as? String, !id.isEmpty,
                  thread["parentThreadId"] as? String == nil,
                  let path = thread["cwd"] as? String, path.hasPrefix("/") else { continue }
            if isRunning, id == threadID { continue }
            let existing = workbench.tasks.first { $0.threadID == id }
            if let existing, archivingTaskIDs.contains(existing.id) { continue }
            let workspace = workbench.ensureWorkspace(url: URL(fileURLWithPath: path))
            // A lightweight directory page cannot move the current selection.
            // Its full thread/read will adopt cwd and preserve chat identity.
            let mergedWorkspaceID = existing.flatMap { $0.id == activeTaskID ? $0.workspaceID : nil } ?? workspace.id
            let name = (thread["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let preview = (thread["preview"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let title = name.isEmpty ? (preview.isEmpty ? existing?.title ?? "Untitled Codex task" : preview) : name
            let created = date(from: thread["createdAt"]) ?? existing?.createdAt ?? .distantPast
            let updated = date(from: thread["updatedAt"]) ?? existing?.updatedAt ?? created
            let runtime = (thread["status"] as? [String: Any])?["type"] as? String
            let state: SavedTaskState = runtime == "active" ? .running
                : (runtime == "systemError" ? .failed : existing?.state ?? .ready)
            let status = existing?.statusMessage ?? "Saved Codex history"
            let task: SavedTask
            if let existing, existing.workspaceID == mergedWorkspaceID, existing.title == title,
               existing.state == state, existing.updatedAt == updated {
                task = existing
            } else {
                task = workbench.upsertRemoteTask(workspaceID: mergedWorkspaceID, threadID: id, title: title,
                    state: state, statusMessage: status, createdAt: created, updatedAt: updated,
                    persistAsynchronously: true)
                changed = true
            }
            workbench.importThreadSidebarMetadata(thread)
            // Keep an open chat selected; an external archive changes its list
            // placement after navigation, never its current transcript/draft.
            if task.id != activeTaskID, workbench.isTaskArchived(task.id) != archived {
                if archived { workbench.archiveTask(task.id) } else { workbench.unarchiveTask(task.id) }
                changed = true
            }
        }
        refreshSavedWorkspaces()
        if changed || rows.contains(where: { $0.keys.contains("section") || $0.keys.contains("projectId") }) { refreshSavedTasks() }
    }

    private func invalidateHistorySyncForNotification(_ method: String, params: [String: Any]) {
        let directoryEvents: Set<String> = ["thread/started", "thread/name/updated", "thread/archived",
            "thread/unarchived", "thread/deleted", "thread/project/updated", "project/changed", "thread/status/changed", "thread/section/updated", "threadSection/changed"]
        if directoryEvents.contains(method) { historySyncNextDirectory = .distantPast }
        let eventThread = params["threadId"] as? String ?? (params["thread"] as? [String: Any])?["id"] as? String
        if eventThread == threadID, method.hasPrefix("thread/") || method.hasPrefix("turn/") || method.hasPrefix("item/") {
            historySyncReadRevision &+= 1
            historySyncLastSnapshot = nil
            historySyncNextRead = .distantPast
        }
    }

    func refreshSelectedTask() {
        guard requireCodexSync() else { return }
        guard !isRunning, !isReadingSelectedTask, !isResumingSavedHistory, let threadID else { return }
        oversizedHistoryThreadIDs.remove(threadID)
        cancelReadReconciliation()
        connectionIntent = .readThread(threadID)
        connectForCurrentIntent()
    }

    func setAppServerURL(_ value: String) {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedValue != appServerURLString else { return }
        stopAppServer()
        stopManagedServer()
        saveAppServerURL(trimmedValue, isManual: !trimmedValue.isEmpty)
        statusMessage = trimmedValue.isEmpty
            ? "Marr will start a background Codex app-server when needed."
            : "Marr will connect to the local Codex app-server."
    }

    /// Marr owns the local child. Independent WebSocket clients are shared by
    /// Work, screenshot conversations and translation.
    func startAppServerInBackground() {
        guard requireCodexSync(), delayedConnectionTask == nil else { return }
        if usesExternalAppServer, let url = localAppServerURL {
            connectToAppServer(at: url)
            return
        }
        if let child = managedServerProcess, child.isRunning, let url = localAppServerURL {
            connectToAppServer(at: url)
            return
        }
        let executables = codexExecutableURLs()
        guard !executables.isEmpty else {
            finishWithError("Codex CLI was not found. Choose its executable in Settings, then try again.")
            return
        }
        let generation = connectionGeneration
        statusMessage = "Starting Codex…"
        delayedConnectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.connectionGeneration == generation { self.delayedConnectionTask = nil } }
            var failures: [String] = []
            for executable in executables {
                guard !Task.isCancelled, self.codexSyncEnabled, self.connectionGeneration == generation else { return }
                let child = Process()
                let diagnostic = FileManager.default.temporaryDirectory.appendingPathComponent("Marr-Codex-\(UUID().uuidString).log")
                do {
                    let endpoint = try CodexRuntime.availableLocalEndpoint()
                    child.executableURL = executable
                    child.arguments = ["app-server", "--listen", endpoint.absoluteString]
                    child.environment = CodexRuntime.launchEnvironment(executables: executables)
                    child.currentDirectoryURL = self.workspaceURL ?? FileManager.default.homeDirectoryForCurrentUser
                    child.standardInput = FileHandle.nullDevice
                    child.standardOutput = FileHandle.nullDevice
                    guard FileManager.default.createFile(atPath: diagnostic.path, contents: nil,
                                                         attributes: [.posixPermissions: 0o600]) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    let log = try FileHandle(forWritingTo: diagnostic)
                    defer { try? log.close() }
                    child.standardError = log
                    self.runtimeDiagnosticURL = diagnostic
                    try child.run()
                    self.managedServerProcess = child
                    self.saveAppServerURL(endpoint.absoluteString, isManual: false)
                    var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
                    components.scheme = "http"; components.path = "/readyz"
                    let sessionConfiguration = URLSessionConfiguration.ephemeral
                    sessionConfiguration.connectionProxyDictionary = [:]
                    let session = URLSession(configuration: sessionConfiguration)
                    defer { session.invalidateAndCancel() }
                    for _ in 0..<40 {
                        try Task.checkCancellation()
                        guard self.codexSyncEnabled, self.connectionGeneration == generation else {
                            if child.isRunning { child.terminate() }
                            return
                        }
                        guard child.isRunning else { break }
                        var request = URLRequest(url: components.url!)
                        request.timeoutInterval = 0.5
                        if let (_, response) = try? await session.data(for: request),
                           (response as? HTTPURLResponse)?.statusCode == 200, child.isRunning {
                            self.hasManagedBackgroundServer = true
                            child.terminationHandler = { [weak self] finished in
                                Task { @MainActor in
                                    guard let self, self.managedServerProcess === finished else { return }
                                    self.managedServerProcess = nil
                                    self.hasManagedBackgroundServer = false
                                    self.handleTransportFailure("Codex app-server stopped (exit \(finished.terminationStatus)).")
                                }
                            }
                            self.connectToAppServer(at: endpoint)
                            return
                        }
                        try await Task.sleep(for: .milliseconds(250))
                    }
                    failures.append("\(executable.path): \(self.runtimeDiagnostic() ?? "startup timed out")")
                } catch {
                    if child.isRunning { child.terminate() }
                    if Task.isCancelled || self.connectionGeneration != generation { return }
                    failures.append("\(executable.path): \(error.localizedDescription)")
                }
                if child.isRunning { child.terminate() }
                if self.managedServerProcess === child { self.managedServerProcess = nil }
                try? FileManager.default.removeItem(at: diagnostic)
            }
            guard !Task.isCancelled, self.connectionGeneration == generation else { return }
            self.finishWithError("Could not start Codex. " + failures.joined(separator: "\n"))
        }
    }

    private func stopManagedServer() {
        managedServerProcess?.terminationHandler = nil
        if let child = managedServerProcess, child.isRunning { child.terminate() }
        managedServerProcess = nil
        hasManagedBackgroundServer = false
        if let runtimeDiagnosticURL { try? FileManager.default.removeItem(at: runtimeDiagnosticURL) }
        runtimeDiagnosticURL = nil
    }

    func shutdown() {
        MarrHistoryImageRecovery.cancelAll()
        historySyncTask?.cancel(); historySyncTask = nil
        desktopSidebarReadTask?.cancel(); desktopSidebarReadTask = nil
        stopAppServer()
        stopManagedServer()
    }

    private func saveAppServerURL(_ value: String, isManual: Bool) {
        if isManual {
            desktopSidebarReadTask?.cancel(); desktopSidebarReadTask = nil
            desktopSidebarSyncAvailable = false; desktopSidebarLastData = nil
            workbench.clearDesktopSidebarPreferences()
        }
        appServerURLString = value
        appServerURLIsManual = isManual
        defaults.set(value, forKey: appServerURLKey)
        defaults.set(isManual, forKey: appServerURLIsManualKey)
    }

    @discardableResult
    func chooseWorkspace() -> Bool {
        guard requireCodexSync() else { return false }
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
        startNewTask()
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
        workspaceURL = nil
        workspaceDisplayName = "No workspace selected"
        instructionSources = []
        defaults.removeObject(forKey: bookmarkKey)
        defaults.removeObject(forKey: bookmarkNameKey)
        statusMessage = "Workspace access removed."
    }

    @discardableResult
    func selectWorkspace(_ savedWorkspace: SavedWorkspace) -> Bool {
        guard requireCodexSync() else { return false }
        guard !isRunning else {
            statusMessage = "Finish or stop the current Codex task before switching workspaces."
            return false
        }
        do {
            try activateWorkspace(savedWorkspace)
            startNewTask()
            return true
        } catch {
            statusMessage = "Could not open \(savedWorkspace.name): \(error.localizedDescription)"
            return false
        }
    }

    func startNewTask(preservingComposerBindings: Bool = false) {
        guard !isRunning else {
            statusMessage = "Codex is still working on the current task."
            return
        }
        flushPendingTaskSnapshot()
        invalidateHistorySync()
        cancelSavedHistoryResume()
        capabilityErrors.removeValue(forKey: "thread/resume")
        cancelReadReconciliation()
        resolveTaskStatusUncertainty()
        if isReadingSelectedTask { stopAppServer() }
        if case .readThread = connectionIntent { connectionIntent = nil }
        let previousBindings = composerBindings
        activeTaskID = nil
        commandGeneration = UUID()
        preparingCommandThread = false
        threadGoal = nil
        awaitingGoalActivation = false
        completedTurnIDs = []
        workbench.clearSelectedTask()
        isRemoteTaskActive = false
        needsThreadResume = false
        threadID = nil
        activeTurnID = nil
        pendingTurnModel = nil
        confirmedThreadModel = nil
        latestAgentMessage = ""
        latestDiff = ""
        activities = []
        activityIDsByServerItemID = [:]
        approvalRequest = nil
        pendingInteractions = []
        interactionErrors = [:]
        cancellationRequested = false
        queuedInputs = []
        taskStartedAt = nil
        taskFinishedAt = nil
        statusMessage = "New Codex task ready."
        loadComposerBindings()
        if preservingComposerBindings { updateComposerBindings(previousBindings) }
    }

    func toggleWorkspacePinned(_ workspace: SavedWorkspace) {
        workbench.toggleWorkspacePinned(workspace.id)
        refreshSavedWorkspaces()
    }

    func followDesktopWorkspacePin(_ workspace: SavedWorkspace) {
        workbench.followDesktopWorkspacePin(workspace.id)
        refreshSavedWorkspaces()
    }

    func showWorkspaceInFinder(_ workspace: SavedWorkspace) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: workspace.path)])
    }

    func archiveChats(in workspace: SavedWorkspace) {
        guard requireCodexSync() else { return }
        guard !isRunning else { return }
        let tasks = workbench.tasks.filter { $0.workspaceID == workspace.id && !workbench.isTaskArchived($0.id) }
        for task in tasks { archiveTask(task) }
        statusMessage = "Requested archiving chats in \(workspace.name)."
    }

    func removeWorkspace(_ workspace: SavedWorkspace) {
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
        guard requireCodexSync() else { return }
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

    func loadTaskHistory(for workspace: SavedWorkspace) {
        guard requireCodexSync() else { return }
        guard !isRunning, !isLoadingTaskHistory else { return }
        beginHistoryLoad(for: [workspace])
    }

    func loadAllTaskHistory() {
        guard requireCodexSync() else { return }
        guard !isRunning, !isLoadingTaskHistory else { return }
        isArchiveOnlyHistory = false
        archiveReconciliationCandidates = []
        globalHistory = true
        historyArchived = false
        archivedHistoryPending = true
        isLoadingTaskHistory = true
        listedThreads = []
        threadListCursor = nil
        connectionIntent = .listThreads
        connectForCurrentIntent()
    }

    func loadArchivedTaskHistory() {
        guard requireCodexSync() else { return }
        guard !isRunning, !isLoadingTaskHistory else { return }
        isArchiveOnlyHistory = true
        archiveReconciliationCandidates = Set(workbench.tasks.filter {
            $0.threadID != nil && workbench.isTaskArchived($0.id) && !archivingTaskIDs.contains($0.id)
        }.map(\.id))
        globalHistory = true
        historyArchived = true
        archivedHistoryPending = false
        isLoadingTaskHistory = true
        historyWorkspace = nil
        remainingHistoryWorkspaces = []
        listedThreads = []
        threadListCursor = nil
        capabilityErrors.removeValue(forKey: "thread/list")
        capabilityDiagnostics.removeValue(forKey: "thread/list")
        connectionIntent = .listThreads
        connectForCurrentIntent()
    }

    private func sendProjectsPage(cursor: String? = nil) {
        var params: [String: Any] = [:]
        if let cursor { params["cursor"] = cursor }
        sendRequest(method: "project/list", params: params, pending: .listProjects)
    }

    private func beginHistoryLoad(for workspaces: [SavedWorkspace]) {
        guard !isLoadingTaskHistory else { return }
        isArchiveOnlyHistory = false
        archiveReconciliationCandidates = []
        guard let firstWorkspace = workspaces.first else {
            statusMessage = "Choose a Codex workspace first."
            return
        }

        globalHistory = false
        historyArchived = false
        archivedHistoryPending = true
        isLoadingTaskHistory = true
        statusMessage = "Loading Codex task history…"
        historyWorkspace = firstWorkspace
        remainingHistoryWorkspaces = Array(workspaces.dropFirst())
        threadListCursor = nil
        listedThreads = []
        connectionIntent = .listThreads
        connectForCurrentIntent()
    }

    @discardableResult
    func selectTask(_ task: SavedTask) -> Bool {
        guard requireCodexSync() else { return false }
        if workbench.selectedTaskID == task.id, isRunning || isReadingSelectedTask
            || (isRemoteTaskActive && connectionReady && !isTaskStatusUncertain) {
            return true
        }
        guard let task = workbench.tasks.first(where: { $0.id == task.id }) else {
            statusMessage = "This conversation is no longer available."
            return false
        }
        guard historySelectionBlockReason == nil else {
            statusMessage = historySelectionBlockReason ?? "Conversation is busy."
            return false
        }
        guard let savedWorkspace = workbench.workspaces.first(where: { $0.id == task.workspaceID }) else {
            statusMessage = "The workspace for this Codex task is no longer available."
            return false
        }
        do {
            commandGeneration = UUID()
            preparingCommandThread = false
            threadGoal = nil
            try activateWorkspace(savedWorkspace, forHistorySelection: true)
            workbench.selectTask(task.id, persistAsynchronously: true)
            restoreSavedTask(task)
            capabilityErrors.removeValue(forKey: "thread/read")
            loadComposerBindings()
            if let threadID = task.threadID {
                oversizedHistoryThreadIDs.remove(threadID)
                connectionIntent = .readThread(threadID)
                statusMessage = "Loading Codex task…"
                connectForCurrentIntent()
            }
            return true
        } catch {
            statusMessage = "Could not open this Codex task: \(error.localizedDescription)"
            return false
        }
    }

    func chooseCodexCLI() {
        guard requireCodexSync() else { return }
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
        stopManagedServer()
        codexCLISecurityScopedURL?.stopAccessingSecurityScopedResource()
        codexCLISecurityScopedURL = nil
        codexCLIURL = nil
        codexCLIDisplayName = "Automatic"
        defaults.removeObject(forKey: cliBookmarkKey)
        defaults.removeObject(forKey: cliBookmarkNameKey)
        statusMessage = "Codex CLI path set to automatic detection."
    }

    @discardableResult
    func submit(prompt rawPrompt: String, images: [ConversationImageAsset]) -> Bool {
        submitMessage(prompt: rawPrompt, images: images, interpretSlashCommands: true)
    }

    private func submitMessage(prompt rawPrompt: String, images: [ConversationImageAsset], interpretSlashCommands: Bool) -> Bool {
        guard requireCodexSync() else { return false }
        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty || !images.isEmpty else { return false }
        if interpretSlashCommands, prompt.hasPrefix("/") {
            return executeSlashCommand(prompt, images: images)
        }
        if isRunning { return steer(prompt: prompt, images: images) }
        guard canSubmit else {
            statusMessage = "Wait for the active task to finish, then refresh."
            return false
        }
        let sourceDraftKey = composerDraftKey
        let submittedBindings = composerBindings
        do {
            try ensureWorkDirectory()
            guard let workspaceURL, let workspaceID = workbench.selectedWorkspaceID else {
                throw CodexWorkspaceError.accessDenied
            }
            let inputs = try makeInputs(prompt: prompt, attachments: images)
            queuedPrompt = prompt
            queuedInputs = inputs
            if activeTaskID == nil {
                activeTaskID = workbench.createTask(workspaceID: workspaceID, prompt: prompt.isEmpty ? "Attachments" : prompt).id
                refreshSavedTasks()
                threadID = nil
                needsThreadResume = false
            }
            let sourceDraft = composerDraftStore.draft(for: sourceDraftKey)
            let sourceMatchesSubmission = sourceDraft.text.trimmingCharacters(in: .whitespacesAndNewlines) == prompt
                || (sourceDraft.text.isEmpty && sourceDraft.bindings == submittedBindings)
            if sourceMatchesSubmission,
               sourceDraft.attachments.map(\.id) == images.map(\.id) {
                composerDraftStore.move(from: sourceDraftKey, to: composerDraftKey)
            }
            let draft = CodexSubmissionDraft(prompt: prompt, attachments: images,
                workspaceID: workspaceID, taskID: activeTaskID, threadID: threadID, bindings: submittedBindings)
            guard composerDraftStore.retainRecovery(draft) else {
                statusMessage = composerDraftStore.lastErrorMessage ?? "The message could not be saved before sending."
                return false
            }
            pendingSubmissionDraft = draft
            pendingSubmissionSnapshot = workbench.selectedTask
            composerDraftStore.save(ComposerDraft(), for: composerDraftKey)
            applyComposerBindings([])
            latestAgentMessage = ""
            latestDiff = ""
            approvalRequest = nil
            pendingInteractions = []
            interactionErrors = [:]
            cancellationRequested = false
            interruptRequestTurnID = nil
            isRunning = true
            taskStartedAt = Date()
            taskFinishedAt = nil
            appendActivity(kind: .status, title: "Preparing Codex task", detail: workspaceURL.path, isComplete: false)
            syncActiveTask(state: .running)
            connectionIntent = .submit
            connectForCurrentIntent()
            return true
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func steer(prompt rawPrompt: String, images: [ConversationImageAsset]) -> Bool {
        if rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") {
            return executeSlashCommand(rawPrompt, images: images)
        }
        guard canSteer, let threadID, let activeTurnID else { return false }
        do {
            let input = try makeInputs(prompt: rawPrompt, attachments: images)
            guard !input.isEmpty else { return false }
            let draft = CodexSubmissionDraft(prompt: rawPrompt, attachments: images,
                workspaceID: workbench.selectedWorkspaceID, taskID: activeTaskID, threadID: threadID,
                bindings: composerBindings)
            guard composerDraftStore.retainRecovery(draft) else {
                capabilityErrors["turn/steer"] = composerDraftStore.lastErrorMessage
                return false
            }
            composerDraftStore.save(ComposerDraft(), for: composerDraftKey)
            applyComposerBindings([])
            sendRequest(method: "turn/steer", params: [
                "threadId": threadID, "expectedTurnId": activeTurnID, "input": input
            ], pending: .steerTurn(draft))
            return true
        } catch {
            capabilityErrors["turn/steer"] = error.localizedDescription
            return false
        }
    }

    func respondToApproval(accept: Bool) {
        guard let first = pendingInteractions.first else { return }
        respondToInteraction(first, action: accept ? .accept : .decline)
    }

    func interrupt() {
        guard isRunning else { return }
        cancellationRequested = true
        statusMessage = "Stopping Codex…"
        if let threadID, let activeTurnID {
            guard interruptRequestTurnID != activeTurnID else { return }
            interruptRequestTurnID = activeTurnID
            sendRequest(method: "turn/interrupt", params: ["threadId": threadID, "turnId": activeTurnID], pending: .interruptTurn)
        } else if activeCommandMethod == nil && !pendingRequests.values.contains(where: {
            switch $0 { case .startTurn: return true; default: return false }
        }) {
            // No turn exists yet. Invalidate pending initialization/start/resume replies.
            if let draft = pendingSubmissionDraft {
                recoverDraft(draft, error: "Cancelled before the task started.")
                pendingSubmissionDraft = nil
                pendingSubmissionSnapshot = nil
            }
            stopAppServer()
            queuedPrompt = nil
            queuedInputs = []
            statusMessage = "Codex task interrupted before it started."
            taskFinishedAt = Date()
            syncActiveTask(state: .interrupted)
        }
    }

    private func ensureWorkDirectory() throws {
        guard workspaceURL == nil else { return }
        let directory = MarrStorage.rootURL.appendingPathComponent("Work", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let workspace = workbench.ensureWorkspace(url: directory, name: "Work")
        workbench.selectWorkspace(workspace.id)
        workspaceURL = directory
        workspaceDisplayName = workspace.name
        refreshSavedWorkspaces()
    }

    private func setWorkspace(_ url: URL) throws {
        stopAppServer()
        securityScopedURL?.stopAccessingSecurityScopedResource()
        let normalizedURL = url.standardizedFileURL
        resetScopedCapabilities(ifChangingTo: normalizedURL)
        guard FileManager.default.isReadableFile(atPath: normalizedURL.path) else {
            throw CodexWorkspaceError.accessDenied
        }
        do {
            let bookmark = try normalizedURL.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(bookmark, forKey: bookmarkKey)
            defaults.set(normalizedURL.lastPathComponent, forKey: bookmarkNameKey)
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
        guard let bookmark = defaults.data(forKey: bookmarkKey) else { return }
        if bookmark.isEmpty, let selected = workbench.selectedWorkspace {
            workspaceURL = URL(fileURLWithPath: selected.path)
            workspaceDisplayName = selected.name
            return
        }
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                throw CodexWorkspaceError.accessDenied
            }
            securityScopedURL = url
            workspaceURL = url
            workspaceDisplayName = defaults.string(forKey: bookmarkNameKey) ?? url.lastPathComponent
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

    private func restoreSavedTask(_ task: SavedTask) {
        resolveTaskStatusUncertainty()
        // Thread history and token notifications do not identify a model.
        // A preference from this client cannot identify a remote active turn.
        pendingTurnModel = nil
        confirmedThreadModel = nil
        activeTaskID = task.id
        threadID = task.threadID
        needsThreadResume = task.threadID != nil
        latestAgentMessage = task.latestAgentMessage
        latestDiff = task.latestDiff
        activities = task.activities
        rebuildActivityIndex()
        approvalRequest = nil
        pendingInteractions = []
        interactionErrors = [:]
        taskStartedAt = task.createdAt
        taskFinishedAt = task.state == .running ? nil : task.updatedAt
        statusMessage = task.statusMessage
        if task.state == .running, let threadID = task.threadID {
            // A background turn may outlive this app. Defer verification until
            // the normal connection flow starts; initialization must stay local.
            isRemoteTaskActive = true
            isTaskStatusUncertain = true
            uncertainTaskTurnID = task.lastKnownTurnID ?? task.activities.last(where: { $0.turnID != nil })?.turnID
            connectionIntent = .readThread(threadID)
        }
    }

    private func activateWorkspace(_ savedWorkspace: SavedWorkspace, forHistorySelection: Bool = false) throws {
        resetScopedCapabilities(ifChangingTo: URL(fileURLWithPath: savedWorkspace.path))
        stopAppServer(preserveReadyConnection: forHistorySelection, waitForPersistence: !forHistorySelection)
        securityScopedURL?.stopAccessingSecurityScopedResource()
        if savedWorkspace.bookmark.isEmpty {
            securityScopedURL = nil
            workspaceURL = URL(fileURLWithPath: savedWorkspace.path)
            workspaceDisplayName = savedWorkspace.name
            workbench.selectWorkspace(savedWorkspace.id, persistAsynchronously: forHistorySelection)
            defaults.set(Data(), forKey: bookmarkKey)
            defaults.set(savedWorkspace.name, forKey: bookmarkNameKey)
            refreshSavedWorkspaces()
            gitWorkspaceSummary = ""
            return
        }
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: savedWorkspace.bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw CodexWorkspaceError.accessDenied
        }
        securityScopedURL = url
        workspaceURL = url
        workspaceDisplayName = savedWorkspace.name
        defaults.set(savedWorkspace.bookmark, forKey: bookmarkKey)
        defaults.set(savedWorkspace.name, forKey: bookmarkNameKey)
        workbench.selectWorkspace(savedWorkspace.id, persistAsynchronously: forHistorySelection)
        refreshSavedWorkspaces()
        if isStale {
            try setWorkspace(url)
        } else {
            refreshGitWorkspaceSummary()
        }
    }

    private func setCodexCLI(_ url: URL) throws {
        stopAppServer()
        stopManagedServer()
        codexCLISecurityScopedURL?.stopAccessingSecurityScopedResource()
        let normalizedURL = url.standardizedFileURL
        guard FileManager.default.isReadableFile(atPath: normalizedURL.path) else {
            throw CodexWorkspaceError.accessDenied
        }
        do {
            let bookmark = try normalizedURL.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(bookmark, forKey: cliBookmarkKey)
            defaults.set(normalizedURL.lastPathComponent, forKey: cliBookmarkNameKey)
            codexCLISecurityScopedURL = normalizedURL
            codexCLIURL = normalizedURL
            codexCLIDisplayName = normalizedURL.path
            hasManagedBackgroundServer = false
            runtimeFingerprint = nil
        } catch {
            normalizedURL.stopAccessingSecurityScopedResource()
            throw error
        }
    }

    private func restoreCodexCLIPath() {
        guard let bookmark = defaults.data(forKey: cliBookmarkKey) else { return }
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            guard FileManager.default.isReadableFile(atPath: url.path) else {
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
        guard codexSyncEnabled else { return }
        // Explicit UI work can arrive while a background initialize is pending.
        // Upgrade that same connection before initialize decides which queues to
        // drain; otherwise catalog loading flags would wait forever.
        if case .historySync = connectionIntent,
           isLoadingModels || capabilityRefreshPending || !pendingThreadActions.isEmpty {
            invalidateHistorySync()
            connectionIntent = .listModels
        }
        if case .historySync = connectionIntent {
            if !connectionReady, process == nil, webSocket == nil {
                historySyncReadOnlyConnection = true
                historySyncConnectionStatus = statusMessage
            }
        } else {
            historySyncReadOnlyConnection = false
            invalidateHistorySync()
        }
        if outboundMessage != nil {
            if initializeInjectedTransport, !connectionReady {
                if !pendingRequests.values.contains(where: { if case .initialize = $0 { return true }; return false }) {
                    sendInitializeRequest()
                }
                return
            }
            connectionReady = true
            if !usesExternalAppServer, runtimeFingerprint == nil { runtimeFingerprint = currentRuntimeFingerprint() }
            performConnectionIntent()
            if capabilityRefreshPending { sendCapabilityRequests() }
            let actions = pendingThreadActions
            pendingThreadActions = []
            for (method, params, pending, draft) in actions { sendRequest(method: method, params: params, pending: pending, draft: draft) }
            return
        }
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
        guard codexSyncEnabled else { return }
        switch connectionIntent {
        case .historySync:
            sendHistorySyncOperation()
        case .listModels:
            break // Model discovery is sent after initialization.
        case .listProjects:
            sendProjectsPage()
        case .listThreads:
            sendListThreads()
        case .readThread(let threadID):
            sendReadThread(threadID)
        case .submit:
            if needsThreadResume {
                sendResumeThread()
            } else if threadID == nil {
                sendStartThread()
            } else {
                sendStartTurn()
            }
        case nil: break
        }
    }

    private func launchAppServer(in workspaceURL: URL) throws {
        guard requireCodexSync() else { throw UserFacingError(statusMessage) }
        let generation = connectionGeneration
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
                Task { @MainActor in
                    guard self?.connectionGeneration == generation else { return }
                    self?.consumeOutput(data)
                }
            }
            errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                Task { @MainActor in
                    guard self?.connectionGeneration == generation else { return }
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
            sendInitializeRequest()
            return
        }
        throw CodexWorkspaceError.launchFailed("Codex CLI", failures.joined(separator: "\n"))
    }

    /// Connect to Marr's own child or an explicitly configured local server.
    private func connectToAppServer(at url: URL) {
        guard codexSyncEnabled else { return }
        let generation = connectionGeneration
        let socket = URLSession.shared.webSocketTask(with: url)
        socket.maximumMessageSize = CodexTransportLimits.maximumMessageSize
        socket.resume()
        webSocket = socket
        statusMessage = "Connecting to local Codex app-server…"

        webSocketReceiveTask = Task { @MainActor [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    let data: Data
                    switch message {
                    case .string(let text):
                        data = Data(text.utf8)
                    case .data(let value):
                        data = value
                    @unknown default:
                        continue
                    }
                    let decoded = await Task.detached(priority: .userInitiated) {
                        CodexDecodedSocketMessage.decode(data)
                    }.value
                    guard !Task.isCancelled, let self, self.connectionGeneration == generation else { return }
                    for entry in decoded {
                        if let object = entry.object { self.handleMessage(object, preparedHistory: entry.preparedHistory) }
                        else { self.appendActivity(kind: .error, title: "Invalid Codex event", detail: entry.invalidText ?? "") }
                    }
                }
            } catch {
                guard !Task.isCancelled, self?.webSocket === socket else { return }
                let oversized = (error as NSError).domain == NSPOSIXErrorDomain && (error as NSError).code == Int(EMSGSIZE)
                self?.handleTransportFailure(oversized
                    ? "This conversation exceeds the 64 MiB receive limit. Automatic retries are paused; open it in Codex or retry after reducing large tool output."
                    : "Codex app-server connection closed: \(error.localizedDescription)", retryable: !oversized)
            }
        }

        sendInitializeRequest()
    }

    private func sendInitializeRequest() {
        sendRequest(method: "initialize", params: [
            "clientInfo": ["name": "marr", "title": "Marr Visual Task Bridge",
                "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"],
            "capabilities": ["experimentalApi": true]
        ], pending: .initialize)
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

    /// Let actual launch errors diagnose each candidate and try the next runtime.
    private func codexExecutableURLs() -> [URL] {
        guard codexSyncEnabled else { return [] }
        return runtimeExecutableOverride ?? CodexRuntime.executableURLs(preferred: codexCLIURL)
    }

    private func sendStartThread() {
        guard let workspaceURL else { return }
        var params: [String: Any] = ["cwd": workspaceURL.path, "model": selectedModel,
                                     "serviceName": appServerServiceName]
        if let projectID = workbench.selectedWorkspace?.projectID { params["projectId"] = projectID }
        sendRequest(method: "thread/start", params: params, pending: .startThread)
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
        var params: [String: Any] = ["limit": 100, "sortKey": "updated_at", "archived": historyArchived,
                                   "sourceKinds": Self.historySourceKinds, "modelProviders": [String]()]
        if !globalHistory {
            guard let historyWorkspace else { isLoadingTaskHistory = false; return }
            params["cwd"] = historyWorkspace.path
        }
        if let threadListCursor { params["cursor"] = threadListCursor }
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
        guard !cancellationRequested, let threadID, queuedPrompt != nil else { return }
        var params: [String: Any] = ["threadId": threadID, "model": selectedModel, "input": queuedInputs]
        // Resumed threads retain the server's effective cwd, permissions and instructions.
        if let selectedReasoningEffort { params["effort"] = selectedReasoningEffort }
        if let mode = collaborationModes.first(where: { $0.id == selectedCollaborationModeID }) {
            params["collaborationMode"] = mode.input(model: selectedModel, effort: selectedReasoningEffort)
        }
        connectionIntent = nil
        statusMessage = "Codex is working in \(workspaceDisplayName)."
        pendingTurnModel = params["model"] as? String
        sendRequest(method: "turn/start", params: params, pending: .startTurn)
    }

    /// A true return means the command was accepted locally. Validation failures preserve the composer.
    @discardableResult
    func executeSlashCommand(_ text: String, images: [ConversationImageAsset] = []) -> Bool {
        guard requireCodexSync() else { return false }
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let first = parts.first, first.hasPrefix("/") else { return false }
        let rawCommand = String(first.dropFirst()).lowercased()
        let command = rawCommand.range(of: "^go+al$", options: .regularExpression) != nil ? "goal" : rawCommand
        let argument = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        func reject(_ message: String) -> Bool { commandOutput = message; return false }
        let commandDraft = CodexSubmissionDraft(prompt: text, attachments: images,
            workspaceID: workbench.selectedWorkspaceID, taskID: activeTaskID, threadID: threadID,
            bindings: composerBindings)
        switch command {
        case "plan", "default":
            guard canSubmit else { return reject("Wait for this turn to finish before changing collaboration mode.") }
            if command == "default", !argument.isEmpty { return reject("Usage: /default") }
            let mode = command == "default" ? "default" : "plan"
            if !collaborationModes.contains(where: { $0.mode == mode }),
               let option = CodexCollaborationMode(json: ["name": mode == "plan" ? "Plan" : "Default", "mode": mode]) {
                collaborationModes.append(option)
            }
            selectedCollaborationModeID = collaborationModes.first { $0.mode == mode }?.id
            commandOutput = mode == "plan" ? "Plan mode selected." : "Default mode selected."
            if command == "plan", !argument.isEmpty {
                return submitMessage(prompt: argument, images: images, interpretSlashCommands: false)
            }
            return true
        case "goal":
            let words = argument.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            let action = words.first.map(String.init) ?? "status"
            if argument.isEmpty { return refreshThreadGoal() }
            if action == "edit", words.count == 1 { return reject("Use /goal <new objective> to edit the current goal. The terminal goal editor is not available in this client.") }
            if ["pause", "resume", "clear"].contains(action), words.count == 1 {
                guard threadID != nil else { return reject("Create a goal first with /goal <objective>.") }
                if action == "clear" { return enqueueCommand("thread/goal/clear", params: ["origin": "user"], draft: commandDraft) }
                return enqueueCommand("thread/goal/set", params: ["origin": "user", "status": action == "pause" ? "paused" : "active"], draft: commandDraft)
            }
            return enqueueCommand("thread/goal/set", params: ["origin": "user", "status": "active", "objective": argument], createThread: true, draft: commandDraft)
        case "compact":
            guard argument.isEmpty else { return reject("Usage: /compact") }
            return enqueueCommand("thread/compact/start", requiresIdle: true)
        case "review":
            var target: [String: Any] = ["type": "uncommittedChanges"]
            if argument.hasPrefix("base ") {
                let branch = String(argument.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !branch.isEmpty else { return reject("Usage: /review base <branch>") }
                target = ["type": "baseBranch", "branch": branch]
            } else if argument.hasPrefix("commit ") {
                let sha = String(argument.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !sha.isEmpty else { return reject("Usage: /review commit <sha>") }
                target = ["type": "commit", "sha": sha]
            } else if !argument.isEmpty {
                let instructions = argument.hasPrefix("custom ") ? String(argument.dropFirst(7)) : argument
                target = ["type": "custom", "instructions": instructions]
            }
            return enqueueCommand("review/start", params: ["target": target, "delivery": "inline"], requiresIdle: true, createThread: true, draft: commandDraft)
        case "rename":
            guard !argument.isEmpty else { return reject("Usage: /rename <name>") }
            return renameSelectedTask(argument)
        case "status":
            guard argument.isEmpty else { return reject("Usage: /status") }
            guard threadID != nil else {
                commandOutput = "No thread selected.\nWorkspace: \(workspaceURL?.path ?? "None")\nModel: \(selectedModel)\nRuntime: \(runtimeDescription)"
                return true
            }
            return enqueueCommand("thread/read", params: ["includeTurns": false])
        case "pwd", "cwd":
            guard argument.isEmpty else { return reject("Usage: /pwd") }
            commandOutput = workspaceURL?.path ?? "No workspace selected."
            return true
        case "warnings":
            guard argument.isEmpty else { return reject("Usage: /warnings") }
            commandOutput = capabilityErrors.keys.sorted().map { "\($0): \(capabilityErrors[$0] ?? "")" }.joined(separator: "\n")
            if commandOutput.isEmpty { commandOutput = "No runtime warnings." }
            return true
        case "model":
            let values = argument.split(whereSeparator: \.isWhitespace).map(String.init)
            guard canSubmit else { return reject("Wait for this turn to finish before changing models.") }
            guard let model = values.first, let option = availableModels.first(where: { $0.id == model }), values.count <= 2 else {
                return reject("Choose a model returned by the connected runtime. Usage: /model <model-id> [reasoning-effort].")
            }
            if values.count == 2, !option.reasoningEfforts.contains(values[1]) { return reject("That reasoning effort is not supported by \(option.name).") }
            selectModel(model)
            if values.count == 2 { selectReasoningEffort(values[1]) }
            commandOutput = "Model selected: \(selectedModelName)."
            return true
        case "mcp":
            let values = argument.split(maxSplits: 1, whereSeparator: \.isWhitespace).map(String.init)
            guard values.count == 2, values[0] == "login", !values[1].isEmpty else { return reject("Usage: /mcp login <server-name>") }
            loginMCPServer(values[1])
            commandOutput = "Starting MCP sign-in for \(values[1])."
            return true
        case "diff":
            guard argument.isEmpty else { return reject("Usage: /diff") }
            commandOutput = latestDiff.isEmpty ? "No diff has been reported for this turn." : latestDiff
            return true
        default:
            return reject("/\(command) is not a runtime command supported by this client. Use the command menu for available actions.")
        }
    }

    /// Editors provide an objective directly; words such as "pause" are literal here.
    @discardableResult
    func setThreadGoal(objective: String) -> Bool {
        let objective = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !objective.isEmpty else { commandOutput = "A goal needs an objective."; return false }
        return enqueueCommand("thread/goal/set", params: ["origin": "user", "status": "active", "objective": objective], createThread: true)
    }

    @discardableResult
    func refreshThreadGoal() -> Bool {
        guard requireCodexSync() else { return false }
        guard threadID != nil else { threadGoal = nil; commandOutput = "No thread goal is set."; return true }
        return enqueueCommand("thread/goal/get")
    }

    @discardableResult
    private func enqueueCommand(_ method: String, params: [String: Any] = [:], requiresIdle: Bool = false, createThread: Bool = false, draft: CodexSubmissionDraft? = nil) -> Bool {
        guard requireCodexSync() else { return false }
        guard !preparingCommandThread, !isReadingSelectedTask, !requiresIdle || canSubmit else {
            commandOutput = "Wait for the current operation to finish before running this command."
            return false
        }
        guard threadID != nil || createThread else {
            commandOutput = "This command needs an existing Codex thread."
            return false
        }
        commandOutput = "Running \(method)…"
        let requiresLiveThread = ["review/start", "thread/compact/start"].contains(method)
            || (method == "thread/goal/set" && params["status"] as? String == "active")
        if threadID == nil || (needsThreadResume && requiresLiveThread) {
            do {
                try ensureWorkDirectory()
                guard let workspaceURL, let workspaceID = workbench.selectedWorkspaceID else { throw CodexWorkspaceError.accessDenied }
                if activeTaskID == nil {
                    activeTaskID = workbench.createTask(workspaceID: workspaceID,
                        prompt: params["objective"] as? String ?? (method == "review/start" ? "Code review" : "Codex task")).id
                    refreshSavedTasks()
                }
                preparingCommandThread = true
                commandGeneration = UUID()
                var prepareParams: [String: Any] = threadID.map { ["threadId": $0, "model": selectedModel] }
                    ?? ["cwd": workspaceURL.path, "model": selectedModel, "serviceName": appServerServiceName]
                if threadID == nil, let projectID = workbench.selectedWorkspace?.projectID {
                    prepareParams["projectId"] = projectID
                }
                // Allocate the local task before recording recovery provenance;
                // thread/start may fail before any remote identity exists.
                let scopedDraft = draft.map {
                    CodexSubmissionDraft(id: $0.id, prompt: $0.prompt, attachments: $0.attachments,
                        workspaceID: workspaceID, taskID: activeTaskID, threadID: threadID,
                        bindings: $0.bindings, error: $0.error)
                }
                enqueueOperation(threadID == nil ? "thread/start" : "thread/resume", params: prepareParams,
                    pending: .prepareCommandThread(method, params, commandGeneration), draft: scopedDraft)
                return true
            } catch {
                preparingCommandThread = false
                commandOutput = Self.safeErrorSummary(error.localizedDescription)
                return false
            }
        }
        sendThreadCommand(method, params: params, draft: draft)
        return true
    }

    private func sendThreadCommand(_ method: String, params: [String: Any], draft: CodexSubmissionDraft? = nil) {
        guard let threadID else { return }
        if ["review/start", "thread/compact/start"].contains(method)
            || (method == "thread/goal/set" && params["status"] as? String == "active" && !isRunning && !isRemoteTaskActive) {
            pendingTurnModel = confirmedThreadModel
        }
        var params = params
        params["threadId"] = threadID
        if ["thread/goal/set", "thread/goal/clear"].contains(method) { goalRevision &+= 1 }
        var responseContext = params
        params.removeValue(forKey: "_localTaskID")
        if method == "thread/goal/get" { responseContext["_goalReadRevision"] = goalRevision }
        if method == "thread/goal/set", params["status"] as? String == "active", !isRunning, !isRemoteTaskActive {
            awaitingGoalActivation = true
            isRemoteTaskActive = true
        }
        if ["review/start", "thread/compact/start"].contains(method) {
            activeCommandMethod = method
            isRunning = true
            taskStartedAt = Date()
            taskFinishedAt = nil
            cancellationRequested = false
            syncActiveTask(state: .running)
        }
        enqueueOperation(method, params: params, pending: .command(method, threadID, responseContext), draft: draft)
    }

    private func consumeCommand(_ method: String, thread expectedThread: String, params: [String: Any], result: [String: Any]) {
        guard threadID == expectedThread else { return }
        if method == "thread/goal/get", params["_goalReadRevision"] as? UInt64 != goalRevision { return }
        switch method {
        case "thread/goal/get", "thread/goal/set":
            if method == "thread/goal/set", isRunning { awaitingGoalActivation = false }
            threadGoal = (result["goal"] as? [String: Any]).flatMap(CodexThreadGoal.init(json:))
            commandOutput = threadGoal.map { "Goal (\($0.status)): \($0.objective)\nTokens: \($0.tokensUsed)\($0.tokenBudget.map { " / \($0)" } ?? "")" } ?? "No thread goal is set."
        case "thread/goal/clear":
            threadGoal = nil
            commandOutput = "Thread goal cleared."
        case "thread/name/set":
            isRenamingTask = false
            let name = params["name"] as? String ?? "Codex task"
            if let rawID = params["_localTaskID"] as? String, let id = UUID(uuidString: rawID),
               let task = workbench.tasks.first(where: { $0.id == id }), task.threadID == expectedThread {
                _ = workbench.renameTask(id, name: name)
                refreshSavedTasks()
            }
            capabilityErrors.removeValue(forKey: "thread/name/set")
            capabilityDiagnostics.removeValue(forKey: "thread/name/set")
            commandOutput = "Renamed to \(name)."
        case "thread/read":
            let thread = result["thread"] as? [String: Any] ?? [:]
            let status = (thread["status"] as? [String: Any])?["type"] as? String ?? (isRunning ? "active" : "idle")
            commandOutput = "Thread: \(expectedThread)\nStatus: \(status)\nWorkspace: \(thread["cwd"] as? String ?? workspaceURL?.path ?? "Unknown")\nModel: \(selectedModel)\nRuntime: \(runtimeDescription)"
        case "review/start":
            if let turn = result["turn"] as? [String: Any], let id = turn["id"] as? String {
                markTurnStarted(id)
                if cancellationRequested { interrupt() }
                commandOutput = "Code review started."
            } else { commandOutput = "Review accepted. Waiting for the runtime turn." }
        case "thread/compact/start": commandOutput = "Context compaction requested."
        default: commandOutput = "\(method) completed."
        }
    }

    private func explicitMentionInputs(_ prompt: String) throws -> (text: String, inputs: [[String: Any]]) {
        var result: [[String: Any]] = []
        var replacements: [(NSRange, String)] = []
        var includedSkills = Set<String>()
        var includedFiles = Set<String>()
        var includedExtensions = Set<String>()
        let text = prompt as NSString
        let sigils = try NSRegularExpression(pattern: #"[$@]"#)
        for match in sigils.matches(in: prompt, range: NSRange(location: 0, length: text.length)) {
            guard let token = AgentComposerCompletion.token(in: prompt, caretUTF16: NSMaxRange(match.range)),
                  token.replacementRange.location == match.range.location else { continue }
            if token.kind == .skill {
                let rawName = String(token.originalText.dropFirst())
                let name = skills.contains(where: { $0.name == rawName }) ? rawName : rawName.trimmingCharacters(in: CharacterSet(charactersIn: ".:!?"))
                let candidates = skills.filter { $0.name == name && $0.enabled }
                if skills.isEmpty, let binding = composerBindings.first(where: { $0.kind == .skill && $0.name == name }) {
                    if includedSkills.insert(binding.path).inserted {
                        result.append(["type": "skill", "name": binding.name, "path": binding.path])
                    }
                    continue
                }
                if !skills.contains(where: { $0.name == name }) { continue }
                guard !candidates.isEmpty else {
                    throw NSError(domain: "CodexInput", code: 1, userInfo: [NSLocalizedDescriptionKey: "Skill $\(name) is unavailable. Refresh Skills and choose an enabled skill from this workspace."])
                }
                let selected = candidates.filter { selectedSkillPaths.contains($0.path) }
                guard candidates.count == 1 || selected.count == 1 else {
                    throw NSError(domain: "CodexInput", code: 2, userInfo: [NSLocalizedDescriptionKey: "Multiple skills are named $\(name). Choose the intended path from the skill suggestions: " + candidates.map(\.path).joined(separator: ", ")])
                }
                let skill = selected.first ?? candidates[0]
                if includedSkills.insert(skill.path).inserted { result.append(skill.input) }
            } else if token.kind == .file {
                var reference = String(token.originalText.dropFirst())
                if reference.hasPrefix("\"") {
                    guard reference.count > 1, reference.hasSuffix("\"") else { continue }
                    reference = String(reference.dropFirst().dropLast())
                        .replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
                }
                if let entry = boundExtensionMentions[reference] {
                    if includedExtensions.insert(entry.path).inserted {
                        result.append(["type": "mention", "name": entry.name, "path": entry.path])
                    }
                    continue
                }
                guard !reference.isEmpty, let workspaceURL else { continue }
                let url = (reference.hasPrefix("/") ? URL(fileURLWithPath: reference) : workspaceURL.appendingPathComponent(reference)).standardizedFileURL
                guard boundFilePaths.contains(url.path) || FileManager.default.fileExists(atPath: url.path) else { continue }
                // The CLI inserts file paths into text; mention inputs bind apps/plugins.
                let needsQuotes = url.path.contains { $0.isWhitespace || "\"\\".contains($0) }
                let pathText = needsQuotes ? String(reflecting: url.path) : url.path
                replacements.append((token.replacementRange, pathText))
                if includedFiles.insert(url.path).inserted,
                   ["png", "jpg", "jpeg", "gif", "webp"].contains(url.pathExtension.lowercased()) {
                    result.append(["type": "localImage", "path": url.path])
                }
            }
        }
        let resolvedText = NSMutableString(string: prompt)
        for (range, replacement) in replacements.reversed() { resolvedText.replaceCharacters(in: range, with: replacement) }
        return (resolvedText as String, result)
    }

    private func makeInputs(prompt: String, attachments: [ConversationImageAsset]) throws -> [[String: Any]] {
        let mentions = try explicitMentionInputs(prompt)
        var input: [[String: Any]] = []
        if !mentions.text.isEmpty { input.append(["type": "text", "text": mentions.text]) }
        if !attachments.isEmpty {
            let directory = attachmentDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for asset in attachments {
                let safeName = URL(fileURLWithPath: asset.fileName).lastPathComponent
                let url = directory.appendingPathComponent("\(asset.id.uuidString)-\(safeName)")
                try asset.data.write(to: url, options: .atomic)
                if asset.isImage {
                    input.append(["type": "localImage", "path": url.path])
                } else {
                    input.append(["type": "text", "text": "Attached file: \(safeName) (\(asset.mimeType))\nLocal path: \(url.path)"])
                }
            }
        }
        input.append(contentsOf: mentions.inputs)
        return input
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

    func receiveServerMessage(_ message: [String: Any]) { handleMessage(message) }

    private func handleMessage(_ message: [String: Any], preparedHistory: CodexPreparedHistory? = nil) {
        guard codexSyncEnabled else { return }
        if let id = message["id"] as? Int, message["result"] != nil || message["error"] != nil {
            handleResponse(id: id, message: message, preparedHistory: preparedHistory)
            return
        }

        guard let method = message["method"] as? String else { return }
        let params = message["params"] as? [String: Any] ?? [:]
        if let rawID = message["id"], let id = CodexRequestID(rawID) {
            handleServerRequest(id: id, method: method, params: params)
        } else {
            handleNotification(method: method, params: params)
        }
    }

    private func handleResponse(id: Int, message: [String: Any], preparedHistory: CodexPreparedHistory? = nil) {
        requestTimeoutTasks.removeValue(forKey: id)?.cancel()
        guard let pending = pendingRequests.removeValue(forKey: id) else { return }
        if case .settings(let method, let token) = pending {
            guard settingsRequestTokens[method] == token else { return }
            settingsLoadingMethods.remove(method)
        }
        if case .historySync(let epoch, let operation) = pending {
            consumeHistorySync(epoch: epoch, operation: operation, message: message, preparedHistory: preparedHistory)
            return
        }
        if case .sidebarMutation(let method, let target, let params) = pending {
            sidebarMutationThreadIDs.remove(target)
            if let error = message["error"] as? [String: Any] {
                recordCapabilityError(method, error["message"] as? String ?? "Could not sync with Codex.")
                return
            }
            guard message["result"] != nil else {
                recordCapabilityError(method, "Codex did not acknowledge this change."); return
            }
            var metadata: [String: Any] = ["id": target]
            if method == "thread/section/move" {
                if let section = params["sectionId"] as? String { metadata["section"] = ["id": section] }
                else { metadata["section"] = NSNull() }
            } else {
                if let project = params["projectId"] as? String, !project.isEmpty { metadata["projectId"] = project }
                else { metadata["projectId"] = NSNull() }
            }
            if method == "thread/metadata/update" {
                metadata["marrExplicitProjectless"] = (params["projectId"] as? String ?? "").isEmpty
            }
            workbench.importThreadSidebarMetadata(metadata)
            capabilityErrors.removeValue(forKey: method)
            refreshSavedTasks(); historySyncNextDirectory = .distantPast
            return
        }
        let commandDraft = commandSubmissionDrafts.removeValue(forKey: id)
        if let error = message["error"] as? [String: Any] {
            let text = error["message"] as? String ?? "Codex app-server request failed."
            if let commandDraft { recoverDraft(commandDraft, error: Self.safeErrorSummary(text)) }
            switch pending {
            case .sidebarMutation: break // Handled above by stable thread identity.
            case .historySync: break // Handled with its visibility/selection token above.
            case .settings(let method, _):
                recordSettingsError(method, text)
                if method == "config/read" { configuration = nil }
                if method == "configRequirements/read" { requirementsLoaded = false; configurationRequirements = nil }
                if method == "config/value/write" {
                    configurationStatusMessage = "The change was not saved. Refresh configuration before retrying; no conflict was overwritten."
                    configuration = nil
                }
                if method == "account/login/start" { accountStatusMessage = "Sign-in could not be started."; earlyLoginCompletions = [:] }
            case .initialize:
                handleTransportFailure(text)
            case .resumeThread where CodexThreadWriterConflict.matches(text):
                rejectResumeForWriterConflict(text)
            case .startThread, .resumeThread, .startTurn:
                finishWithError(text)
            case .resumeSavedHistory(let context):
                guard matchesSavedHistoryResume(context) else { return }
                savedHistoryResume = nil
                isResumingSavedHistory = false
                recordCapabilityError("thread/resume", text)
            case .readThread:
                isReadingSelectedTask = false
                if case .readThread = connectionIntent { connectionIntent = nil }
                recordCapabilityError("thread/read", text)
                if !isRunning {
                    statusMessage = isRemoteTaskActive
                        ? "\(text)\nRefresh this chat from Projects to verify its state, or start a new chat."
                        : text
                }
                scheduleReadReconciliation(afterFailure: text)
            case .listProjects:
                isLoadingProjects = false
                recordCapabilityError("project/list", text)
            case .listThreads:
                isArchiveOnlyHistory = false
                archiveReconciliationCandidates = []
                isLoadingTaskHistory = false
                if case .listThreads = connectionIntent { connectionIntent = nil }
                recordCapabilityError("thread/list", text)
            case .listModels:
                isLoadingModels = false
                modelLoadError = text
                if case .submit = connectionIntent { performConnectionIntent() }
            case .capability(let method):
                recordCapabilityError(method, text)
                if method == "plugin/list" {
                    loadingCapabilityMethods.insert("plugin/installed")
                    sendCapabilityPage("plugin/installed")
                }
                loadingCapabilityMethods.remove(method)
                isLoadingCapabilities = !loadingCapabilityMethods.isEmpty
                if capabilityRefreshPending { sendCapabilityRequests() }
            case .interruptTurn:
                cancellationRequested = false
                interruptRequestTurnID = nil
                recordCapabilityError("turn/interrupt", text)
                statusMessage = "Codex could not stop: \(text)"
            case .steerTurn(let draft):
                recoverDraft(draft, error: text)
                recordCapabilityError("turn/steer", text)
            case .skillWrite: recordCapabilityError("skills/config/write", text)
            case .pluginMutation(let method, let id):
                pluginOperationsInFlight.remove(id)
                recordCapabilityError(method, text)
            case .reloadMCP: recordCapabilityError("config/mcpServer/reload", text)
            case .loginMCP(let name): recordCapabilityError("MCP \(name)", text)
            case .forkThread: recordCapabilityError("thread/fork", text)
            case .archiveThread(let id, let archived):
                archivingTaskIDs.remove(id)
                recordCapabilityError(archived ? "thread/archive" : "thread/unarchive", text)
            case .fileSearch(let generation):
                if generation == fileSearchGeneration { isSearchingFiles = false; fileSearchError = Self.safeErrorSummary(text) }
            case .prepareCommandThread(_, _, let generation):
                if generation == commandGeneration {
                    preparingCommandThread = false
                    commandOutput = Self.safeErrorSummary(text)
                }
            case .command(let method, let expectedThread, let context):
                if method == "thread/name/set" { isRenamingTask = false }
                guard threadID == expectedThread else { return }
                if method == "thread/goal/get", context["_goalReadRevision"] as? UInt64 != goalRevision { return }
                if method == "thread/goal/set", awaitingGoalActivation {
                    awaitingGoalActivation = false
                    pendingTurnModel = nil
                    if !isRunning { isRemoteTaskActive = false }
                }
                recordCapabilityError(method, text)
                commandOutput = "\(method): \(Self.safeErrorSummary(text))"
                if activeCommandMethod == method, activeTurnID == nil {
                    activeCommandMethod = nil
                    pendingTurnModel = nil
                    isRunning = false
                    syncActiveTask(state: .failed)
                }
            }
            return
        }
        let result = message["result"] as? [String: Any] ?? [:]
        if let commandDraft { composerDraftStore.removeRecovery(commandDraft.id) }
        if case .steerTurn(let draft) = pending { composerDraftStore.removeRecovery(draft.id) }

        switch pending {
        case .sidebarMutation: break // Handled above.
        case .historySync: break // Handled before ordinary request state.
        case .settings(let method, let token): consumeSetting(method, result: result, token: token)
        case .initialize:
            sendNotification(method: "initialized", params: [:])
            connectionReady = true
            if !usesExternalAppServer, runtimeFingerprint == nil { runtimeFingerprint = currentRuntimeFingerprint() }
            runtimeDescription = result["userAgent"] as? String ?? "Codex app-server"
            if historySyncReadOnlyConnection {
                performConnectionIntent()
                return
            }
            isLoadingModels = true
            listedModels = []
            sendModelsPage()
            requestedCapabilityMethods.formUnion(["skills/list", "collaborationMode/list"])
            sendCapabilityRequests()
            let actions = pendingThreadActions
            pendingThreadActions = []
            for (method, params, pending, draft) in actions { sendRequest(method: method, params: params, pending: pending, draft: draft) }
            if case .submit = connectionIntent {} else { performConnectionIntent() }
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
                    defaults.set(first.id, forKey: selectedModelKey)
                    selectedReasoningEffort = first.defaultReasoningEffort
                }
                if selectedReasoningEffort == nil {
                    selectedReasoningEffort = availableModels.first { $0.id == selectedModel }?.defaultReasoningEffort
                }
                isLoadingModels = false
                modelLoadError = availableModels.isEmpty ? "No models available." : nil
                if case .listModels = connectionIntent { connectionIntent = nil }
                if case .submit = connectionIntent { performConnectionIntent() }
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
            confirmedThreadModel = result["model"] as? String
            pendingSubmissionDraft?.threadID = id
            if let draft = pendingSubmissionDraft { composerDraftStore.retainRecovery(draft) }
            adoptThreadDirectory(thread)
            needsThreadResume = false
            syncActiveTask(threadID: id)
            workbench.importThreadSidebarMetadata(thread)
            refreshSavedTasks()
            instructionSources = result["instructionSources"] as? [String] ?? []
            if !instructionSources.isEmpty {
                appendActivity(kind: .status, title: "Loaded workspace instructions", detail: instructionSources.joined(separator: "\n"))
            }
            sendStartTurn()
        case .resumeSavedHistory(let context):
            guard matchesSavedHistoryResume(context) else { return }
            savedHistoryResume = nil
            isResumingSavedHistory = false
            guard let thread = result["thread"] as? [String: Any],
                  thread["id"] as? String == context.threadID, thread["turns"] is [[String: Any]],
                  let status = (thread["status"] as? [String: Any])?["type"] as? String,
                  ["notLoaded", "idle", "active", "systemError"].contains(status) else {
                recordCapabilityError("thread/resume", "Codex did not return the selected saved history. Refresh before trying again.")
                return
            }
            capabilityErrors.removeValue(forKey: "thread/resume")
            capabilityDiagnostics.removeValue(forKey: "thread/resume")
            resolveTaskStatusUncertainty()
            hydrateSelectedTask(from: thread, requestedThreadID: context.threadID, preparedHistory: preparedHistory)
            // thread/resume only establishes runtime state. The next message is
            // a separate user action, sent with the server's retained settings.
            needsThreadResume = status != "idle" && status != "active"
            confirmedThreadModel = result["model"] as? String
        case .resumeThread:
            guard let thread = result["thread"] as? [String: Any], let id = thread["id"] as? String else {
                finishWithError("Codex could not resume this task thread.")
                return
            }
            threadID = id
            confirmedThreadModel = result["model"] as? String
            pendingSubmissionDraft?.threadID = id
            if let draft = pendingSubmissionDraft { composerDraftStore.retainRecovery(draft) }
            adoptThreadDirectory(thread)
            for turn in thread["turns"] as? [[String: Any]] ?? [] {
                for item in turn["items"] as? [[String: Any]] ?? [] {
                    recordItem(item, complete: turn["status"] as? String != "inProgress",
                        processingSeconds: RuntimeHistoryProjection.turnDurationSeconds(turn), turnID: turn["id"] as? String)
                }
            }
            needsThreadResume = false
            syncActiveTask(threadID: id)
            workbench.importThreadSidebarMetadata(thread)
            refreshSavedTasks()
            sendStartTurn()
        case .startTurn:
            if let turn = result["turn"] as? [String: Any], let id = turn["id"] as? String {
                if let draft = pendingSubmissionDraft { composerDraftStore.removeRecovery(draft.id) }
                pendingSubmissionDraft = nil
                pendingSubmissionSnapshot = nil
                if isRunning { markTurnStarted(id) }
                if cancellationRequested { interrupt() }
            } else if activeTurnID == nil {
                finishWithError("Codex did not acknowledge the submitted turn.")
            }
        case .interruptTurn, .steerTurn:
            break
        case .fileSearch(let generation):
            guard generation == fileSearchGeneration else { return }
            fileSearchResults = (result["files"] as? [[String: Any]] ?? []).compactMap(CodexFileSearchMatch.init(json:))
            isSearchingFiles = false
        case .prepareCommandThread(let method, let params, let generation):
            guard generation == commandGeneration else { return }
            preparingCommandThread = false
            guard let thread = result["thread"] as? [String: Any], let id = thread["id"] as? String else {
                commandOutput = "The runtime did not return a thread for this command."
                if let commandDraft { recoverDraft(commandDraft, error: commandOutput) }
                return
            }
            threadID = id
            confirmedThreadModel = result["model"] as? String
            adoptThreadDirectory(thread)
            needsThreadResume = false
            syncActiveTask(threadID: id)
            workbench.importThreadSidebarMetadata(thread)
            refreshSavedTasks()
            var continuationDraft = commandDraft
            continuationDraft?.threadID = id
            sendThreadCommand(method, params: params, draft: continuationDraft)
        case .command(let method, let expectedThread, let params):
            consumeCommand(method, thread: expectedThread, params: params, result: result)
        case .capability(let method): consumeCapability(method, result: result)
        case .skillWrite: refreshSkills()
        case .reloadMCP: refreshMCPServers()
        case .pluginMutation(_, let id):
            pluginOperationsInFlight.remove(id)
            refreshPlugins()
            refreshSkills()
        case .loginMCP(let name):
            if let rawURL = result["authorizationUrl"] as? String, let url = URL(string: rawURL),
               ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                if outboundMessage == nil { NSWorkspace.shared.open(url) }
                capabilityErrors["MCP \(name)"] = "Complete sign-in in your browser, then refresh capabilities."
            }
        case .forkThread:
            if let thread = result["thread"] as? [String: Any], let id = thread["id"] as? String,
               let path = thread["cwd"] as? String, path.hasPrefix("/") {
                let workspace = workbench.ensureWorkspace(url: URL(fileURLWithPath: path))
                let task = workbench.upsertRemoteTask(workspaceID: workspace.id, threadID: id,
                    title: thread["name"] as? String ?? thread["preview"] as? String ?? "Forked task",
                    state: .ready, statusMessage: "Forked from Codex", createdAt: date(from: thread["createdAt"]) ?? Date(),
                    updatedAt: date(from: thread["updatedAt"]) ?? Date())
                refreshSavedWorkspaces()
                refreshSavedTasks()
                selectTask(task)
            }
        case .archiveThread(let id, let archived):
            archivingTaskIDs.remove(id)
            capabilityErrors.removeValue(forKey: archived ? "thread/archive" : "thread/unarchive")
            capabilityDiagnostics.removeValue(forKey: archived ? "thread/archive" : "thread/unarchive")
            if archived { workbench.archiveTask(id) } else { workbench.unarchiveTask(id) }
            if archived, id == activeTaskID { startNewTask() }
            refreshSavedTasks()
        case .listThreads:
            if isArchiveOnlyHistory, result["data"] as? [[String: Any]] == nil {
                isArchiveOnlyHistory = false
                archiveReconciliationCandidates = []
                isLoadingTaskHistory = false
                if case .listThreads = connectionIntent { connectionIntent = nil }
                recordCapabilityError("thread/list", "Codex did not return a complete archived history page.")
                return
            }
            capabilityErrors.removeValue(forKey: "thread/list")
            capabilityDiagnostics.removeValue(forKey: "thread/list")
            listedThreads.append(contentsOf: result["data"] as? [[String: Any]] ?? [])
            if let cursor = result["nextCursor"] as? String, !cursor.isEmpty {
                threadListCursor = cursor
                sendListThreads()
            } else {
                finishCurrentHistoryWorkspace()
            }
        case .readThread(let requestedThreadID):
            isReadingSelectedTask = false
            guard requestedThreadID == threadID else { return }
            guard let thread = result["thread"] as? [String: Any],
                  thread["id"] as? String == requestedThreadID,
                  thread["turns"] is [[String: Any]],
                  let status = (thread["status"] as? [String: Any])?["type"] as? String,
                  ["notLoaded", "idle", "active", "systemError"].contains(status),
                  !isTaskStatusUncertain || includesReconciledTurn(thread) else {
                capabilityErrors["thread/read"] = "Codex did not return the selected task history."
                connectionIntent = nil
                scheduleReadReconciliation(afterFailure: "Codex returned incomplete task history.")
                return
            }
            let wasReconciling = readReconciliation != nil
            cancelReadReconciliation()
            resolveTaskStatusUncertainty()
            hydrateSelectedTask(from: thread, requestedThreadID: requestedThreadID, preparedHistory: preparedHistory)
            connectionIntent = nil
            if wasReconciling, isRemoteTaskActive {
                statusMessage = "Connection restored. This task is still running; refresh to check its progress."
                syncActiveTask(state: .running)
            }
        }
    }

    private func handleServerRequest(id: CodexRequestID, method: String, params: [String: Any]) {
        // A catalog/read connection is never an approval or execution client.
        guard !historySyncReadOnlyConnection else { return }

        let request = CodexInteractionRequest(id: id, method: method, params: params)
        let supported = ["item/commandExecution/requestApproval", "item/fileChange/requestApproval",
                         "item/permissions/requestApproval", "item/tool/requestUserInput", "tool/requestUserInput",
                         "mcpServer/elicitation/request"]
        if method == "item/tool/call" {
            let response = try? request.response(action: .decline)
            sendResponse(id: id.rawValue, result: response ?? ["success": false, "contentItems": []])
            capabilityErrors[method] = "This host tool is not implemented by Marr."
        } else if supported.contains(method) {
            if let requestThread = request.threadID, requestThread != threadID {
                if let result = try? request.response(action: .cancel) { sendResponse(id: id.rawValue, result: result) }
                return
            }
            if let requestTurn = request.turnID, let activeTurnID, requestTurn != activeTurnID {
                if let result = try? request.response(action: .cancel) { sendResponse(id: id.rawValue, result: result) }
                return
            }
            guard !pendingInteractions.contains(where: { $0.id == id }) else { return }
            interactionErrors.removeValue(forKey: id)
            pendingInteractions.append(request)
            refreshLegacyApproval()
        } else {
            write(["id": id.rawValue, "error": ["code": -32601, "message": "Unsupported client request: \(method)"]])
            capabilityErrors[method] = "The connected runtime requested a client capability that Marr does not implement."
        }
    }

    private func handleNotification(method: String, params: [String: Any]) {
        invalidateHistorySyncForNotification(method, params: params)
        if historySyncReadOnlyConnection { return }
        if handleSettingsNotification(method, params: params) { return }
        if method == "skills/changed" { refreshSkills(); return }
        if method == "mcpServer/oauthLogin/completed" { refreshMCPServers(); return }
        if method == "serverRequest/resolved" {
            if let value = params["requestId"], let id = CodexRequestID(value) {
                pendingInteractions.removeAll { $0.id == id }
                interactionErrors.removeValue(forKey: id)
                refreshLegacyApproval()
            }
            return
        }
        if let eventThread = params["threadId"] as? String, eventThread != threadID { return }
        let eventTurnID = params["turnId"] as? String ?? (params["turn"] as? [String: Any])?["id"] as? String
        if isRunning, let activeTurnID, let eventTurnID, eventTurnID != activeTurnID { return }
        if let expectedTurn = readReconciliation?.turnID ?? uncertainTaskTurnID,
           let eventTurnID, eventTurnID != expectedTurn { return }
        if isTaskStatusUncertain, ["turn/started", "turn/completed"].contains(method) {
            // After a lost ACK, an unscoped or earlier turn cannot prove what
            // happened to this submission. Only its known turn or a full read can.
            guard params["threadId"] as? String == threadID,
                  let expectedTurn = uncertainTaskTurnID, eventTurnID == expectedTurn else { return }
        }
        switch method {
        case "thread/tokenUsage/updated":
            guard let id = params["threadId"] as? String, id == threadID,
                  let turnID = params["turnId"] as? String else { return }
            guard let model = tokenUsageModelsByTurn[id]?[turnID] else {
                threadTokenUsage.removeValue(forKey: id)
                return
            }
            guard let value = params["tokenUsage"] as? [String: Any],
                  let usage = CodexThreadTokenUsage(json: value, model: model) else { return }
            threadTokenUsage[id] = usage
        case "thread/goal/updated":
            goalRevision &+= 1
            threadGoal = (params["goal"] as? [String: Any]).flatMap(CodexThreadGoal.init(json:))
        case "thread/goal/cleared":
            goalRevision &+= 1
            threadGoal = nil
        case "thread/compacted":
            if activeCommandMethod == "thread/compact/start", activeTurnID == nil {
                activeCommandMethod = nil
                isRunning = false
                activeTurnID = nil
                taskFinishedAt = Date()
                cancellationRequested = false
                commandOutput = "Context compaction completed."
                syncActiveTask(state: .completed)
            }
        case "warning", "configWarning", "deprecationNotice":
            recordCapabilityError(method, params["message"] as? String ?? params["summary"] as? String ?? "The runtime reported a warning.")
        case "turn/started":
            if let turn = params["turn"] as? [String: Any], let id = turn["id"] as? String,
               !completedTurnIDs.contains(id) {
                cancelReadReconciliation()
                resolveTaskStatusUncertainty()
                markTurnStarted(id)
                isRunning = true
                awaitingGoalActivation = false
                isRemoteTaskActive = false
                if cancellationRequested { interrupt() }
            }
        case "thread/status/changed":
            guard !isTaskStatusUncertain else { return }
            let status = params["status"] as? [String: Any] ?? [:]
            awaitingGoalActivation = false
            isRemoteTaskActive = !isRunning && status["type"] as? String == "active"
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
                recordItem(item, complete: false, turnID: params["turnId"] as? String)
                syncActiveTask()
            }

        case "item/completed":
            if let item = params["item"] as? [String: Any] {
                recordItem(item, complete: true, turnID: params["turnId"] as? String)
                syncActiveTask()
            }

        case "item/agentMessage/delta":
            recordDelta(params, field: "text", type: "agentMessage")

        case "item/commandExecution/outputDelta":
            recordDelta(params, field: "aggregatedOutput", type: "commandExecution")

        case "turn/completed":
            if let operation = activeCommandMethod {
                for (id, pending) in pendingRequests {
                    if case .command(let method, _, _) = pending, method == operation {
                        if let draft = commandSubmissionDrafts.removeValue(forKey: id) {
                            composerDraftStore.removeRecovery(draft.id)
                        }
                        pendingRequests.removeValue(forKey: id)
                        requestTimeoutTasks.removeValue(forKey: id)?.cancel()
                    }
                }
            }
            activeCommandMethod = nil
            let turn = params["turn"] as? [String: Any]
            if let id = turn?["id"] as? String, !completedTurnIDs.insert(id).inserted { return }
            cancelReadReconciliation()
            resolveTaskStatusUncertainty()
            let status = turn?["status"] as? String ?? "completed"
            let completedTurnID = turn?["id"] as? String ?? activeTurnID
            if let turn, let processingSeconds = RuntimeHistoryProjection.turnDurationSeconds(turn) {
                for index in activities.indices where activities[index].turnID == completedTurnID {
                    activities[index].processingSeconds = processingSeconds
                }
            }
            for index in activities.indices where activities[index].turnID == completedTurnID {
                activities[index].isComplete = true
            }
            isRunning = false
            isRemoteTaskActive = false
            cancellationRequested = false
            pendingInteractions.removeAll { $0.turnID == completedTurnID || $0.threadID == threadID }
            let remainingInteractionIDs = Set(pendingInteractions.map(\.id))
            interactionErrors = interactionErrors.filter { remainingInteractionIDs.contains($0.key) }
            queuedInputs = []
            queuedPrompt = nil
            queuedImagePaths = []
            approvalRequest = nil
            taskFinishedAt = Date()
            statusMessage = status == "completed" ? "Codex task completed." : "Codex task \(status)."
            appendActivity(kind: status == "completed" ? .status : .error, title: "Codex task \(status)")
            activeTurnID = nil
            pendingTurnModel = nil
            syncActiveTask(state: status == "completed" ? .completed : (status == "failed" ? .failed : .interrupted))
            refreshGitWorkspaceSummary()

        case "error":
            let error = params["error"] as? [String: Any]
            let text = error?["message"] as? String ?? "Codex task failed."
            if params["willRetry"] as? Bool == true {
                statusMessage = "Codex is retrying: \(text)"
                appendActivity(kind: .status, title: "Retrying", detail: text)
            } else {
                // The terminal turn/completed event is authoritative. Keep its
                // turn ID until then so an old completion cannot finish a new turn.
                statusMessage = text
                appendActivity(kind: .error, title: "Codex error", detail: text)
            }

        default:
            break
        }
    }

    private func importListedThreads() {
        for thread in listedThreads {
            guard let threadID = thread["id"] as? String, !threadID.isEmpty,
                  let path = thread["cwd"] as? String, path.hasPrefix("/") else { continue }
            if isRunning, threadID == self.threadID { continue }
            let workspace = workbench.ensureWorkspace(url: URL(fileURLWithPath: path))
            let name = (thread["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let preview = (thread["preview"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let status = (thread["status"] as? [String: Any])?["type"] as? String
            let existing = workbench.tasks.first { $0.threadID == threadID }
            let createdAt = date(from: thread["createdAt"]) ?? existing?.createdAt ?? .distantPast
            let state: SavedTaskState = status == "active" ? .running
                : (status == "systemError" ? .failed : existing?.state ?? .ready)
            let task = workbench.upsertRemoteTask(workspaceID: workspace.id, threadID: threadID,
                title: name.isEmpty ? preview : name, state: state,
                statusMessage: "Imported from Codex history", createdAt: createdAt,
                updatedAt: date(from: thread["updatedAt"]) ?? existing?.updatedAt ?? createdAt)
            workbench.importThreadSidebarMetadata(thread)
            if historyArchived { workbench.archiveTask(task.id) }
            else { workbench.unarchiveTask(task.id) }
        }
        refreshSavedWorkspaces()
        refreshSavedTasks()
    }

    private func finishCurrentHistoryWorkspace() {
        importListedThreads()
        if isArchiveOnlyHistory {
            let remoteIDs = Set(listedThreads.compactMap { $0["id"] as? String })
            for task in workbench.tasks where archiveReconciliationCandidates.contains(task.id) {
                if let id = task.threadID, !remoteIDs.contains(id) { workbench.unarchiveTask(task.id) }
            }
            isArchiveOnlyHistory = false
            archiveReconciliationCandidates = []
            refreshSavedTasks()
        }
        threadListCursor = nil
        listedThreads = []
        if archivedHistoryPending {
            archivedHistoryPending = false
            historyArchived = true
            sendListThreads()
            return
        }
        if !globalHistory, let nextWorkspace = remainingHistoryWorkspaces.first {
            historyWorkspace = nextWorkspace
            remainingHistoryWorkspaces.removeFirst()
            historyArchived = false
            archivedHistoryPending = true
            sendListThreads()
            return
        }
        historyWorkspace = nil
        isLoadingTaskHistory = false
        lastProjectSyncAt = Date()
        if case .listThreads = connectionIntent { connectionIntent = nil }
        if !isRunning { statusMessage = "Synced."; refreshSelectedTask() }
    }

    private func hydrateSelectedTask(from thread: [String: Any], requestedThreadID: String, backgroundSync: Bool = false, preparedHistory: CodexPreparedHistory? = nil) {
        guard let returnedThreadID = thread["id"] as? String,
              returnedThreadID == requestedThreadID,
              returnedThreadID == threadID
        else {
            return
        }

        let preserveExternalUncertainty = backgroundSync
            && (isRemoteTaskActive || isTaskStatusUncertain)
            && (thread["status"] as? [String: Any])?["type"] as? String == "notLoaded"
        capabilityErrors.removeValue(forKey: "thread/read")
        capabilityDiagnostics.removeValue(forKey: "thread/read")
        adoptThreadDirectory(thread, readOnly: backgroundSync)
        workbench.importThreadSidebarMetadata(thread)
        refreshSavedTasks()
        rebuildActivityIndex()
        let turns = thread["turns"] as? [[String: Any]] ?? []
        let runtimeStatus = (thread["status"] as? [String: Any])?["type"] as? String
        let diskOnlyUnfinishedTurn = runtimeStatus == "notLoaded" && turns.last.map {
            $0["status"] as? String == "inProgress"
                || ($0["status"] as? String == "interrupted" && !RuntimeHistoryProjection.isDurableSnapshotTurnEnd($0))
        } == true
        resumableSavedHistoryThreadID = diskOnlyUnfinishedTurn ? requestedThreadID : nil
        let prepared = preparedHistory.flatMap { $0.threadID == requestedThreadID ? $0 : nil }
            ?? RuntimeHistoryProjection.prepareHistory(thread)
        #if DEBUG
        historyPreparationWasOffMain = prepared.preparedOffMain
        #endif
        let loadedActivities = prepared.activities.map { item -> WorkActivity in
            guard let serverItemID = item.serverItemID else { return item }
            let key = "\(item.turnID ?? "")|\(serverItemID)"
            let id = activityIDsByServerItemID[key] ?? item.id
            activityIDsByServerItemID[key] = id
            return WorkActivity(id: id, kind: item.kind, title: item.title, detail: item.detail,
                isComplete: item.isComplete, processingSeconds: item.processingSeconds,
                turnID: item.turnID, serverItemID: serverItemID, rawJSON: item.rawJSON, messagePhase: item.messagePhase)
        }
        activities = loadedActivities
        latestAgentMessage = prepared.answer
        latestDiff = prepared.diff
        let isRemoteActive = runtimeStatus == "active" || diskOnlyUnfinishedTurn
            || turns.last?["status"] as? String == "inProgress"
        let state: SavedTaskState
        if runtimeStatus == "systemError" { state = .failed }
        else if isRemoteActive { state = .running }
        else {
            switch turns.last?["status"] as? String {
            case "failed": state = .failed
            case "interrupted": state = .interrupted
            default: state = .completed
            }
        }
        taskStartedAt = date(from: thread["createdAt"]) ?? taskStartedAt
        taskFinishedAt = isRemoteActive ? nil : (date(from: thread["updatedAt"]) ?? taskFinishedAt)
        isRemoteTaskActive = isRemoteActive
        if runtimeStatus == "systemError",
           !["completed", "failed", "interrupted"].contains(turns.last?["status"] as? String ?? "") {
            isTaskStatusUncertain = true
        }
        isRunning = false
        needsThreadResume = true
        switch state {
        case .running: statusMessage = "This Codex task is active in another client."
        case .failed: statusMessage = runtimeStatus == "systemError"
            ? "Codex reported a runtime error. Refresh this task to verify its state."
            : "Codex task failed."
        case .interrupted: statusMessage = "Codex task interrupted."
        default: statusMessage = "Codex task history loaded."
        }
        if preserveExternalUncertainty || diskOnlyUnfinishedTurn {
            isTaskStatusUncertain = true
            isRemoteTaskActive = true
            statusMessage = "Showing saved history. The external task's current status is unknown."
        }
        syncActiveTask(state: runtimeStatus == "systemError" ? .failed
                       : (isTaskStatusUncertain && isRemoteTaskActive ? .running : state),
                       persistAsynchronously: true,
                       updatedAt: date(from: thread["updatedAt"]) ?? workbench.selectedTask?.updatedAt,
                       observedTurnID: turns.last?["id"] as? String)
    }

    private func resetScopedCapabilities(ifChangingTo directory: URL) {
        guard directory.standardizedFileURL.path != workspaceURL?.standardizedFileURL.path else { return }
        for method in ["config/read", "configRequirements/read", "config/value/write", "experimentalFeature/list"] { invalidateSetting(method) }
        configuration = nil
        configurationRequirements = nil
        requirementsLoaded = false
        configurationStatusMessage = ""
        experimentalFeatures = []
        featureRows = []
        featureCursors = []
        selectedSkillPaths = []
        boundFilePaths = []
        boundExtensionMentions = [:]
        clearFileSearch()
        skills = []
        extensions = []
        capabilityRows = [:]
        capabilityErrors = [:]
        capabilityDiagnostics = [:]
        requestedCapabilityMethods = []
        for (id, pending) in pendingRequests {
            if case .capability = pending {
                pendingRequests.removeValue(forKey: id)
                requestTimeoutTasks.removeValue(forKey: id)?.cancel()
            }
        }
        loadingCapabilityMethods = []
        isLoadingCapabilities = false
        capabilityRefreshPending = connectionReady && outboundMessage == nil
        queuedInputs.removeAll { $0["type"] as? String == "skill" }
    }

    private func adoptThreadDirectory(_ thread: [String: Any], readOnly: Bool = false) {
        guard let path = thread["cwd"] as? String, path.hasPrefix("/"),
              let id = thread["id"] as? String, path != workspaceURL?.path else { return }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let workspace = workbench.ensureWorkspace(url: url)
        resetScopedCapabilities(ifChangingTo: url)
        if readOnly { capabilityRefreshPending = false }
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
        workspaceURL = url
        workspaceDisplayName = workspace.name
        if let activeTaskID, let task = workbench.tasks.first(where: { $0.id == activeTaskID }) {
            _ = workbench.upsertRemoteTask(workspaceID: workspace.id, threadID: id, title: task.title,
                state: task.state, statusMessage: task.statusMessage, createdAt: task.createdAt, updatedAt: task.updatedAt)
            workbench.selectTask(activeTaskID)
        } else { workbench.selectWorkspace(workspace.id) }
        defaults.set(Data(), forKey: bookmarkKey)
        defaults.set(workspace.name, forKey: bookmarkNameKey)
        refreshSavedWorkspaces()
        if capabilityRefreshPending { sendCapabilityRequests() }
    }

    private func date(from value: Any?) -> Date? {
        guard let seconds = (value as? NSNumber)?.doubleValue else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private func recordItem(_ item: [String: Any], complete: Bool,
                            processingSeconds: Int? = nil, turnID: String? = nil) {
        let serverItemID = item["id"] as? String
        var activity = RuntimeHistoryProjection.makeActivity(item, complete: complete, processingSeconds: processingSeconds, turnID: turnID ?? activeTurnID, fallbackAnswer: latestAgentMessage)
        if activity.kind == .message, !activity.isProcessMessage { latestAgentMessage = activity.detail }
        if activity.kind == .fileChange, !activity.detail.isEmpty { latestDiff = activity.detail }
        let key = serverItemID.map { "\(turnID ?? activeTurnID ?? "")|\($0)" }
        let previousID = key.flatMap { activityIDsByServerItemID[$0] }
        if let previousID, let index = activities.firstIndex(where: { $0.id == previousID }) {
            activity = WorkActivity(id: previousID, kind: activity.kind, title: activity.title,
                detail: activity.detail, isComplete: complete,
                processingSeconds: processingSeconds ?? activities[index].processingSeconds,
                turnID: turnID ?? activities[index].turnID, serverItemID: serverItemID, rawJSON: activity.rawJSON,
                messagePhase: activity.messagePhase ?? activities[index].messagePhase)
            activities[index] = activity
        } else {
            if let previousID {
                activity = WorkActivity(id: previousID, kind: activity.kind, title: activity.title,
                    detail: activity.detail, isComplete: complete, processingSeconds: processingSeconds,
                    turnID: turnID ?? activeTurnID, serverItemID: serverItemID, rawJSON: activity.rawJSON, messagePhase: activity.messagePhase)
            }
            activities.append(activity)
            if let key { activityIDsByServerItemID[key] = activity.id }
        }
    }

    private func rebuildActivityIndex() {
        activityIDsByServerItemID = [:]
        for activity in activities {
            if let itemID = activity.serverItemID {
                activityIDsByServerItemID["\(activity.turnID ?? "")|\(itemID)"] = activity.id
            }
        }
    }

    private func markTurnStarted(_ id: String) {
        if let threadID, let model = pendingTurnModel {
            tokenUsageModelsByTurn[threadID, default: [:]][id] = model
            // turn/start's explicit model applies to subsequent turns too.
            confirmedThreadModel = model
        } else if let threadID, tokenUsageModelsByTurn[threadID]?[id] == nil {
            confirmedThreadModel = nil
        }
        pendingTurnModel = nil
        if let draft = pendingSubmissionDraft { composerDraftStore.removeRecovery(draft.id) }
        pendingSubmissionDraft = nil
        pendingSubmissionSnapshot = nil
        // The event itself proves acceptance, even if its RPC response is lost
        // or arrives after completion. Do not later recover an accepted draft.
        for (requestID, pending) in pendingRequests {
            if case .command(let method, _, let params) = pending,
               ["review/start", "thread/compact/start"].contains(method)
                || (method == "thread/goal/set" && params["status"] as? String == "active") {
                if let draft = commandSubmissionDrafts.removeValue(forKey: requestID) {
                    composerDraftStore.removeRecovery(draft.id)
                }
            }
            if case .startTurn = pending {
                pendingRequests.removeValue(forKey: requestID)
                requestTimeoutTasks.removeValue(forKey: requestID)?.cancel()
            }
        }
        activeTurnID = id
        for index in activities.indices where activities[index].turnID == nil && !activities[index].isComplete {
            activities[index].turnID = id
            if activities[index].kind == .status { activities[index].isComplete = true }
        }
        // Preserve the accepted turn identity even if the app closes before
        // the first item/delta; a later disk snapshot can verify this exact turn.
        syncActiveTask(state: .running)
    }

    private func recordDelta(_ params: [String: Any], field: String, type: String) {
        guard let itemID = params["itemId"] as? String else { return }
        let turnID = params["turnId"] as? String ?? activeTurnID
        let key = "\(turnID ?? "")|\(itemID)"
        let previous = activityIDsByServerItemID[key].flatMap { id in activities.first { $0.id == id } }
        var item: [String: Any] = ["id": itemID, "type": type]
        if let raw = previous?.rawJSON, let data = raw.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { item = parsed }
        item[field] = (item[field] as? String ?? "") + (params["delta"] as? String ?? "")
        recordItem(item, complete: false, turnID: turnID)
        scheduleTaskSnapshot()
    }

    private func appendActivity(kind: WorkActivity.Kind, title: String, detail: String = "", isComplete: Bool = true) {
        activities.append(WorkActivity(kind: kind, title: title, detail: detail, isComplete: isComplete, turnID: activeTurnID))
        syncActiveTask()
    }

    private func syncActiveTask(
        state: SavedTaskState? = nil,
        threadID: String? = nil,
        persistAsynchronously: Bool = false,
        updatedAt: Date? = nil,
        observedTurnID: String? = nil
    ) {
        taskSnapshotTask?.cancel()
        taskSnapshotTask = nil
        guard let activeTaskID else { return }
        let resolvedState = state ?? (isRunning ? .running : nil)
        workbench.updateTask(
            id: activeTaskID,
            threadID: threadID,
            state: resolvedState,
            statusMessage: statusMessage,
            latestAgentMessage: latestAgentMessage,
            latestDiff: latestDiff,
            activities: activities,
            persistAsynchronously: persistAsynchronously,
            updatedAt: updatedAt,
            lastKnownTurnID: observedTurnID ?? activeTurnID,
            clearKnownTurnID: isRunning && activeTurnID == nil && observedTurnID == nil
        )
        refreshSavedTasks()
    }

    private func scheduleTaskSnapshot() {
        guard taskSnapshotTask == nil else { return }
        let taskID = activeTaskID
        taskSnapshotTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard let self, self.activeTaskID == taskID else { return }
            self.taskSnapshotTask = nil
            self.syncActiveTask(persistAsynchronously: true)
        }
    }

    /// Used at context/connection boundaries and application shutdown. Terminal
    /// events call syncActiveTask directly, which also supersedes any batch.
    func flushPendingTaskSnapshot() {
        if taskSnapshotTask != nil { syncActiveTask() }
        workbench.flushPersistence()
    }

    private func refreshSavedTasks() {
        savedTasks = workbench.tasks.filter { !workbench.isTaskArchived($0.id) }
        pinnedTaskIDs = workbench.pinnedTaskIDs
    }

    private func refreshSavedWorkspaces() {
        savedWorkspaces = workbench.workspaces
    }

    /// A rejected resume never reached turn/start. Keep the existing answer and
    /// task outcome; do not reconcile, retry, fork, or interrupt the other owner.
    private func rejectResumeForWriterConflict(_ message: String) {
        let snapshot = pendingSubmissionSnapshot
        if let draft = pendingSubmissionDraft { recoverDraft(draft, error: message) }
        pendingSubmissionDraft = nil
        pendingSubmissionSnapshot = nil
        queuedPrompt = nil
        queuedInputs = []
        queuedImagePaths = []
        connectionIntent = nil
        isRunning = false
        activeTurnID = nil
        pendingTurnModel = nil
        needsThreadResume = true
        taskFinishedAt = Date()
        statusMessage = CodexThreadWriterConflict.explanation
        if let snapshot, snapshot.id == activeTaskID {
            activities = snapshot.activities
            rebuildActivityIndex()
            latestAgentMessage = snapshot.latestAgentMessage
            latestDiff = snapshot.latestDiff
            taskStartedAt = snapshot.createdAt
            taskFinishedAt = snapshot.state == .running ? nil : snapshot.updatedAt
            syncActiveTask(state: snapshot.state, updatedAt: snapshot.updatedAt,
                           observedTurnID: snapshot.lastKnownTurnID)
        } else {
            syncActiveTask(state: .ready)
        }
    }

    private func finishWithError(_ message: String) {
        if historySyncReadOnlyConnection {
            failHistorySyncConnection()
            return
        }
        isRenamingTask = false
        if !connectionReady, !settingsLoadingMethods.isEmpty {
            let methods = settingsLoadingMethods
            resetSettingsState()
            for method in methods { recordSettingsError(method, message) }
            pendingThreadActions.removeAll { if case .settings = $0.2 { return true }; return false }
        }
        recoverPendingCommandDrafts(error: message)
        if let draft = pendingSubmissionDraft {
            recoverDraft(draft, error: message)
            pendingSubmissionDraft = nil
            pendingSubmissionSnapshot = nil
        }
        let wasRunning = isRunning
        isLoadingProjects = false
        isLoadingModels = false
        if !connectionReady { modelLoadError = message }
        isReadingSelectedTask = false
        isRunning = false
        isLoadingTaskHistory = false
        connectionIntent = nil
        threadListCursor = nil
        listedThreads = []
        historyWorkspace = nil
        remainingHistoryWorkspaces = []
        queuedPrompt = nil
        queuedImagePaths = []
        queuedInputs = []
        pendingInteractions = []
        interactionErrors = [:]
        approvalRequest = nil
        taskFinishedAt = Date()
        // Startup logs are reported only for startup failures.
        statusMessage = message
        if activities.last?.kind != .error || activities.last?.detail != message {
            appendActivity(kind: .error, title: "Codex task failed", detail: message)
        }
        activeTurnID = nil
        pendingTurnModel = nil
        if wasRunning { syncActiveTask(state: .failed) }
        scheduleReadReconciliation(afterFailure: message)
    }

    private func runtimeDiagnostic() -> String? {
        guard let runtimeDiagnosticURL,
              let diagnostic = try? String(contentsOf: runtimeDiagnosticURL, encoding: .utf8),
              !diagnostic.isEmpty
        else {
            return nil
        }
        return String(diagnostic.suffix(4000))
    }

    func revertCodexChanges(diff: String) -> Bool {
        guard requireCodexSync() else { return false }
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
        guard codexSyncEnabled else { return }
        guard outboundMessage == nil else { return }
        let requestID = UUID()
        gitSummaryRequestID = requestID
        guard let workspaceURL else {
            gitWorkspaceSummary = "Git status unavailable"
            return
        }
        let path = workspaceURL.path
        Task { @MainActor [weak self] in
            let summary = await Task.detached(priority: .utility) {
                Self.readGitWorkspaceSummary(path: path)
            }.value
            guard let self, self.codexSyncEnabled, self.gitSummaryRequestID == requestID, self.workspaceURL?.path == path else { return }
            self.gitWorkspaceSummary = summary
        }
    }

    nonisolated private static func readGitWorkspaceSummary(path: String) -> String {
        guard let branch = gitOutput(["-C", path, "branch", "--show-current"]) else { return "Not a Git workspace" }
        let changes = (gitOutput(["-C", path, "status", "--porcelain"]) ?? "")
            .split(whereSeparator: \.isNewline).count
        let worktrees = (gitOutput(["-C", path, "worktree", "list", "--porcelain"]) ?? "")
            .split(whereSeparator: \.isNewline).filter { $0.hasPrefix("worktree ") }.count
        let branchName = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(branchName.isEmpty ? "detached HEAD" : branchName) · \(changes) change\(changes == 1 ? "" : "s") · \(worktrees) worktree\(worktrees == 1 ? "" : "s")"
    }

    nonisolated private static func gitOutput(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            // Drain before waiting: a large status can fill the pipe and block
            // the child forever if its parent waits for termination first.
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch { return nil }
    }

    private func handleProcessTermination(_ process: Process) {
        guard self.process === process else { return }
        handleTransportFailure("Codex app-server stopped (exit \(process.terminationStatus)).")
    }

    /// Kept internal so transport failure/retry races can be tested without a
    /// process, socket, app launch or timer delay.
    func handleTransportFailure(_ message: String, retryable: Bool = true) {
        guard codexSyncEnabled else { return }
        if !retryable {
            if let threadID { oversizedHistoryThreadIDs.insert(threadID) }
            cancelReadReconciliation()
            recordCapabilityError("thread/read", message)
        }
        if let context = savedHistoryResume, matchesSavedHistoryResume(context) {
            stopAppServer()
            isTaskStatusUncertain = true
            isRemoteTaskActive = true
            resumableSavedHistoryThreadID = context.threadID
            recordCapabilityError("thread/resume", message)
            return
        }
        if historySyncReadOnlyConnection || (historySyncOperation != nil && !isRunning && readReconciliation == nil) {
            failHistorySyncConnection()
            return
        }
        if isReadingSelectedTask, !isRunning, readReconciliation == nil {
            // Reading another client's history is not executing a task. Keep
            // its transcript and status, and expose one retryable read error.
            let remoteActive = isRemoteTaskActive
            let uncertain = isTaskStatusUncertain || remoteActive
            stopAppServer()
            hasManagedBackgroundServer = false
            isRemoteTaskActive = remoteActive
            isTaskStatusUncertain = uncertain
            recordCapabilityError("thread/read", message)
            statusMessage = "Could not load this conversation. Refresh to retry."
            backoffHistorySync()
            return
        }
        let settingsMethods = settingsLoadingMethods
        let wasRunning = isRunning || isRemoteTaskActive
        if wasRunning, threadID != nil {
            isTaskStatusUncertain = true
            uncertainTaskTurnID = activeTurnID ?? uncertainTaskTurnID
        }
        if retryable, readReconciliation == nil, wasRunning, let threadID, let activeTaskID,
           let workspaceID = workbench.selectedWorkspaceID {
            readReconciliation = ReadReconciliation(workspaceID: workspaceID, taskID: activeTaskID,
                                                    threadID: threadID, turnID: uncertainTaskTurnID)
        }
        let willReconcile = readReconciliation != nil
        if let draft = pendingSubmissionDraft {
            recoverDraft(draft, error: message)
            pendingSubmissionDraft = nil
            pendingSubmissionSnapshot = nil
        }
        for pending in pendingRequests.values {
            if case .steerTurn(let draft) = pending { recoverDraft(draft, error: message) }
        }
        stopAppServer(cancelReconciliation: false)
        for method in settingsMethods { recordSettingsError(method, message) }
        hasManagedBackgroundServer = false
        finishWithError(message)
        if wasRunning, threadID != nil, !willReconcile {
            isRemoteTaskActive = true
            statusMessage = "\(message)\nReconnect and refresh this task to verify its state."
            syncActiveTask(state: .running)
        }
    }

    private func matchesCurrentTask(_ context: ReadReconciliation) -> Bool {
        context.threadID == threadID && context.taskID == activeTaskID
            && context.taskID == workbench.selectedTaskID
            && context.workspaceID == workbench.selectedWorkspaceID
    }

    private func includesReconciledTurn(_ thread: [String: Any]) -> Bool {
        let turns = thread["turns"] as? [[String: Any]] ?? []
        // Runtime loading state is not a turn outcome. A disk-only notLoaded
        // snapshot can prove completion, but an empty history cannot. Active
        // snapshots can resolve uncertainty while retaining the remote send lock.
        let runtimeStatus = (thread["status"] as? [String: Any])?["type"] as? String
        func confirmsState(_ turn: [String: Any]) -> Bool {
            if runtimeStatus == "notLoaded" { return RuntimeHistoryProjection.isDurableSnapshotTurnEnd(turn) }
            let knownStatuses = runtimeStatus == "active"
                ? ["inProgress", "completed", "failed", "interrupted"] : ["completed", "failed", "interrupted"]
            return knownStatuses.contains(turn["status"] as? String ?? "")
        }
        guard let latestTurn = turns.last, confirmsState(latestTurn) else { return false }
        guard let expectedTurn = readReconciliation?.turnID ?? uncertainTaskTurnID else { return true }
        // An idle thread with missing/partial history cannot prove that the
        // previously acknowledged turn ended. Keep the send lock in that case.
        return turns.contains { $0["id"] as? String == expectedTurn && confirmsState($0) }
    }

    private func scheduleReadReconciliation(afterFailure message: String) {
        guard codexSyncEnabled else { return }
        guard let context = readReconciliation else { return }
        guard matchesCurrentTask(context) else { cancelReadReconciliation(); return }
        reconciliationTask?.cancel()
        reconciliationTask = nil
        isRemoteTaskActive = true
        if context.attempts >= Self.reconciliationDelays.count {
            cancelReadReconciliation()
            statusMessage = "\(message)\nAutomatic reconnection stopped after three attempts. Refresh this task to verify its state."
            syncActiveTask(state: .running)
            return
        }
        let delay = Self.reconciliationDelays[context.attempts]
        statusMessage = "Connection interrupted. Reconnecting to check this task (\(context.attempts + 1)/\(Self.reconciliationDelays.count))…"
        syncActiveTask(state: .running)
        reconciliationTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.readReconciliation?.id == context.id else { return }
            self.reconciliationTask = nil
            self.performScheduledReconciliation()
        }
    }

    /// Deterministic timer entry point. Only readThread can be enqueued here.
    func performScheduledReconciliation() {
        guard codexSyncEnabled else { return }
        guard var context = readReconciliation, matchesCurrentTask(context),
              context.attempts < Self.reconciliationDelays.count, !isReadingSelectedTask else { return }
        reconciliationTask?.cancel()
        reconciliationTask = nil
        context.attempts += 1
        readReconciliation = context
        connectionIntent = .readThread(context.threadID)
        connectForCurrentIntent()
    }

    private func cancelReadReconciliation() {
        reconciliationTask?.cancel()
        reconciliationTask = nil
        guard let context = readReconciliation else { return }
        readReconciliation = nil
        for (id, pending) in pendingRequests {
            if case .readThread(let thread) = pending, thread == context.threadID {
                pendingRequests.removeValue(forKey: id)
                requestTimeoutTasks.removeValue(forKey: id)?.cancel()
            }
        }
        if case .readThread(let thread) = connectionIntent, thread == context.threadID {
            connectionIntent = nil
            isReadingSelectedTask = false
        }
    }

    private func resolveTaskStatusUncertainty() {
        isTaskStatusUncertain = false
        uncertainTaskTurnID = nil
    }

    private func recoverPendingCommandDrafts(error: String) {
        for (id, draft) in commandSubmissionDrafts {
            recoverDraft(draft, error: Self.safeErrorSummary(error))
            pendingRequests.removeValue(forKey: id)
            requestTimeoutTasks.removeValue(forKey: id)?.cancel()
        }
        for (_, _, _, draft) in pendingThreadActions {
            if let draft { recoverDraft(draft, error: Self.safeErrorSummary(error)) }
        }
        pendingThreadActions.removeAll { $0.3 != nil }
        commandSubmissionDrafts = [:]
    }

    private func stopAppServer(cancelReconciliation: Bool = true, preserveReadyConnection: Bool = false, waitForPersistence: Bool = true) {
        let keepConnection = preserveReadyConnection && connectionReady
        cancelSavedHistoryResume()
        invalidateHistorySync()
        historySyncReadOnlyConnection = false
        if waitForPersistence { flushPendingTaskSnapshot() }
        else if taskSnapshotTask != nil { syncActiveTask(persistAsynchronously: true) }
        if cancelReconciliation { cancelReadReconciliation() }
        isRenamingTask = false
        resetSettingsState()
        archivingTaskIDs = []
        if !sidebarMutationThreadIDs.isEmpty {
            recordCapabilityError("thread/section/move", "Connection changed before sidebar sync was confirmed. Refresh and retry.")
            sidebarMutationThreadIDs = []
        }
        isArchiveOnlyHistory = false
        archiveReconciliationCandidates = []
        recoverPendingCommandDrafts(error: "Connection closed before the command was acknowledged.")
        if let draft = pendingSubmissionDraft {
            recoverDraft(draft, error: "Connection closed before the message was acknowledged.")
            pendingSubmissionDraft = nil
            pendingSubmissionSnapshot = nil
        }
        for pending in pendingRequests.values {
            if case .steerTurn(let draft) = pending {
                recoverDraft(draft, error: "Connection closed before the message was acknowledged.")
            }
        }
        if !keepConnection { connectionGeneration = UUID() }
        commandGeneration = UUID()
        preparingCommandThread = false
        activeCommandMethod = nil
        awaitingGoalActivation = false
        clearFileSearch()
        outboundTask?.cancel()
        outboundTask = nil
        pendingInteractions = []
        interactionErrors = [:]
        approvalRequest = nil
        loadingCapabilityMethods = []
        pluginOperationsInFlight = []
        pendingThreadActions = []
        isLoadingCapabilities = false
        isLoadingProjects = false
        isReadingSelectedTask = false
        isRemoteTaskActive = false
        if !keepConnection { connectionReady = false }
        isLoadingModels = false
        if delayedConnectionTask != nil { stopManagedServer() }
        delayedConnectionTask?.cancel()
        delayedConnectionTask = nil
        if !keepConnection {
            webSocketReceiveTask?.cancel()
            webSocketReceiveTask = nil
            webSocket?.cancel(with: .goingAway, reason: nil)
            webSocket = nil
            process?.standardOutput = nil
            process?.standardError = nil
            process?.terminate()
            process = nil
            standardInput = nil
        }
        needsThreadResume = threadID != nil
        activeTurnID = nil
        pendingTurnModel = nil
        confirmedThreadModel = nil
        if !keepConnection { outputBuffer = Data() }
        pendingRequests = [:]
        for task in requestTimeoutTasks.values { task.cancel() }
        requestTimeoutTasks = [:]
        connectionIntent = nil
        isLoadingTaskHistory = false
        historyWorkspace = nil
        remainingHistoryWorkspaces = []
        isRunning = false
    }

    private func sendRequest(method: String, params: [String: Any], pending: PendingRequest? = nil, draft: CodexSubmissionDraft? = nil) {
        guard codexSyncEnabled else { return }
        switch pending {
        case .historySync, .initialize: break
        default:
            historySyncReadOnlyConnection = false
            invalidateHistorySync()
        }
        requestID += 1
        let id = requestID
        if let draft {
            commandSubmissionDrafts[id] = draft
            composerDraftStore.retainRecovery(draft)
        }
        if let pending {
            pendingRequests[id] = pending
            if outboundMessage == nil {
                let generation = connectionGeneration
                let seconds: Double
                switch pending {
                case .historySync: seconds = 10
                case .pluginMutation: seconds = 180
                case .startThread, .resumeThread, .resumeSavedHistory, .forkThread: seconds = 90
                default: seconds = 45
                }
                requestTimeoutTasks[id] = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(self?.requestTimeoutOverride ?? seconds)) } catch { return }
                    guard let self, self.connectionGeneration == generation,
                          let pending = self.pendingRequests[id] else { return }
                    _ = pending
                    self.expireServerRequest(id)
                }
            }
        }
        write(["id": id, "method": method, "params": params])
    }

    /// Deterministic timeout entry point also used by the injected transport tests.
    func expireServerRequest(_ id: Int) {
        guard let pending = pendingRequests[id] else { return }
        switch pending {
        case .initialize:
            handleTransportFailure("Codex initialization timed out.")
        case .command(let method, _, _) where ["review/start", "thread/compact/start"].contains(method):
            if activeTurnID != nil {
                pendingRequests.removeValue(forKey: id)
                requestTimeoutTasks.removeValue(forKey: id)?.cancel()
            } else { handleTransportFailure("Codex has not acknowledged \(method).") }
        case .command(let method, _, let params) where method == "thread/goal/set" && params["status"] as? String == "active":
            let wasAwaiting = awaitingGoalActivation
            handleResponse(id: id, message: ["error": ["message": "Goal activation was not acknowledged. Refresh the thread before retrying."]])
            if wasAwaiting, !isRunning {
                isRemoteTaskActive = true
                isTaskStatusUncertain = true
            }
        case .startTurn:
            if activeTurnID != nil {
                pendingRequests.removeValue(forKey: id)
                requestTimeoutTasks.removeValue(forKey: id)?.cancel()
            } else {
                handleTransportFailure("Codex has not acknowledged the turn start.")
            }
        default:
            handleResponse(id: id, message: ["error": ["message": "Codex request timed out. Retry the operation."]])
        }
    }

    private func sendNotification(method: String, params: [String: Any]) {
        write(["method": method, "params": params])
    }

    private func sendResponse(id: Any, result: [String: Any]) {
        write(["id": id, "result": result])
    }

    private func write(_ message: [String: Any]) {
        guard codexSyncEnabled else { return }
        if let outboundMessage { outboundMessage(message); return }
        do {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(0x0A)
            if let webSocket {
                guard let text = String(data: data, encoding: .utf8) else {
                    finishWithError("Could not encode the Codex request.")
                    return
                }
                let previous = outboundTask
                let generation = connectionGeneration
                outboundTask = Task { @MainActor [weak self] in
                    await previous?.value
                    guard let self, !Task.isCancelled, self.connectionGeneration == generation else { return }
                    do {
                        try await webSocket.send(.string(text))
                    } catch {
                        guard !Task.isCancelled, self.connectionGeneration == generation else { return }
                        self.handleTransportFailure("Could not communicate with Codex: \(error.localizedDescription)")
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

enum CodexWorkspaceError: LocalizedError {
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
