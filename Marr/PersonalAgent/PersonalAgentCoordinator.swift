import AppKit
import Combine
import Foundation

@MainActor
final class PersonalAgentCoordinator: ObservableObject {
    let store: PersonalAgentStore
    let cloud: PersonalAgentCloud
    private var cloudObservation: AnyCancellable?
    private var scopeObservation: AnyCancellable?
    private var draftScope = "local"
    private var scopedDrafts: [String: [UUID: String]] = [:]
    @Published private(set) var activeRunID: UUID?
    @Published private(set) var liveText = ""
    @Published private(set) var interactions: [CodexInteractionRequest] = []
    @Published private(set) var isStopping = false
    @Published private(set) var checkingRunID: UUID?
    @Published private(set) var respondingRequestIDs = Set<CodexRequestID>()
    @Published var errorMessage: String?
    // Keep drafts and selection without mounting an invisible composer.
    var savedSection = "Agents"
    var savedSelectedAgentID: UUID?
    @Published var drafts: [UUID: String] = [:]
    private let endpoint: () async throws -> URL
    private let model: () -> String
    private let isReady: () -> Bool
    private let makeExecutor: @MainActor (URL) -> PersonalAgentExecuting
    private var executor: PersonalAgentExecuting?
    private var job: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var stopDeadline: Task<Void, Never>?
    private var timer: Timer?
    private var observation: AnyCancellable?

    convenience init(runtime: RuntimeWorkspaceController) {
        let isTest = ProcessInfo.processInfo.environment["MARR_TEST_HOST"] == "1" || NSClassFromString("XCTestCase") != nil
        self.init(store: isTest ? PersonalAgentStore(rootURL: nil) : PersonalAgentStore(),
                  endpoint: { try await runtime.conversationEndpoint() },
                  model: { runtime.selectedModel }, isReady: { runtime.codexSyncEnabled }, cloud: PersonalAgentCloud(persistent: !isTest))
    }

    init(store: PersonalAgentStore, endpoint: @escaping () async throws -> URL,
         model: @escaping () -> String, isReady: @escaping () -> Bool, cloud: PersonalAgentCloud? = nil,
         makeExecutor: @escaping @MainActor (URL) -> PersonalAgentExecuting = { PersonalAgentRuntime(endpoint: $0) }) {
        self.cloud = cloud ?? PersonalAgentCloud()
        self.store = store; self.endpoint = endpoint; self.model = model
        self.isReady = isReady; self.makeExecutor = makeExecutor
        cloudObservation = self.cloud.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        scopeObservation = self.cloud.$scope.removeDuplicates().sink { [weak self] scope in
            guard let self, scope != draftScope else { return }
            scopedDrafts[draftScope] = drafts
            draftScope = scope
            drafts = scopedDrafts[scope] ?? [:]
            savedSelectedAgentID = nil
        }
        observation = store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var isConnected: Bool { cloud.enabled ? cloud.connected : isReady() }
    var archive: PersonalAgentArchive { cloud.enabled ? cloud.archive : store.archive }
    var unreadCount: Int { archive.runs.filter { !$0.isRead && $0.status != .running }.count }

    func startScheduler() {
        cloud.start()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    func shutdown() {
        cloud.suspend()
        timer?.invalidate(); timer = nil
        deadline?.cancel(); stopDeadline?.cancel()
        if let id = activeRunID {
            try? store.updateRun(id) {
                $0.status = .uncertain
                $0.detail = "Marr closed while this run was active. Check its connection before continuing."
            }
        }
        executor?.close()
        job?.cancel()
    }

    func tick(now: Date = Date()) {
        guard !cloud.enabled, isReady(), activeRunID == nil, checkingRunID == nil, store.errorMessage == nil,
              let routine = store.dueRoutine(now: now) else { return }
        _ = send(routine.instruction, to: routine.agentID, routineID: routine.id, scheduled: true, now: now)
    }

    @discardableResult
    func send(_ prompt: String, to agentID: UUID, routineID: UUID? = nil,
              scheduled: Bool = false, now: Date = Date()) -> Bool {
        if cloud.enabled {
            guard !cloud.pendingAgents.contains(agentID) else { return false }
            Task {
                do {
                    try await cloud.send(prompt, agentID: agentID, routineID: routineID)
                    if drafts[agentID] == prompt { drafts[agentID] = "" }
                    errorMessage = nil
                } catch { errorMessage = error.localizedDescription }
            }
            return false // Keep the draft until the server confirms the durable submission.
        }
        guard isReady() else {
            errorMessage = "Connect the local runtime in Settings → Workspace → Sync Codex work, then try again."
            return false
        }
        guard activeRunID == nil, checkingRunID == nil else {
            errorMessage = "Another agent is working. You can keep browsing while it finishes."
            return false
        }
        do {
            let directory = try store.workspaceURL(for: agentID)
            let run = try store.begin(agentID: agentID, prompt: prompt, routineID: routineID, scheduled: scheduled, now: now)
            guard let agent = archive.agents.first(where: { $0.id == agentID }) else { return false }
            let selected = Set(agent.skillIDs + (archive.routines.first { $0.id == routineID }?.skillIDs ?? []))
            let skills = archive.skills.filter { selected.contains($0.id) }
            activeRunID = run.id; liveText = ""; interactions = []; errorMessage = nil; isStopping = false
            let execution = PersonalAgentExecution(agent: agent, run: run, skills: skills, directory: directory, model: model())
            deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(agent.maxRunMinutes * 60)) }
                catch { return }
                guard let self, activeRunID == run.id else { return }
                stop(reason: "The run reached its \(agent.maxRunMinutes)-minute time limit.")
            }
            job = Task { [weak self] in await self?.perform(execution) }
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    private func perform(_ execution: PersonalAgentExecution) async {
        let id = execution.run.id
        do {
            let url = try await endpoint()
            try Task.checkCancellation()
            guard !isStopping else { throw CancellationError() }
            let runner = makeExecutor(url)
            executor = runner
            var prepared = execution
            prepared.model = model() // Connection setup may refresh the model catalog.
            let result = try await runner.run(prepared) { [weak self] event in
                guard let self, activeRunID == id else { return }
                try receive(event, run: execution.run)
            }
            try finish(id, outcome: result)
        } catch {
            let uncertain = executor?.didSubmit == true
            let status: PersonalAgentRun.Status = uncertain ? .uncertain : (isStopping || error is CancellationError ? .cancelled : .failed)
            do { try finish(id, outcome: PersonalAgentOutcome(status: status, text: liveText,
                detail: uncertain ? "Connection lost. Work may still be running. Check connection before retrying. \(error.localizedDescription)" : error.localizedDescription)) }
            catch { errorMessage = error.localizedDescription }
        }
        executor?.close(); executor = nil
        deadline?.cancel(); deadline = nil
        stopDeadline?.cancel(); stopDeadline = nil
        activeRunID = nil; interactions = []; respondingRequestIDs = []; isStopping = false; job = nil
    }

    private func receive(_ event: PersonalAgentRuntimeEvent, run: PersonalAgentRun) throws {
        switch event {
        case .submitting: try store.updateRun(run.id) { $0.submissionAttempted = true }
        case .thread(let threadID):
            try store.update { data in
                if let index = data.runs.firstIndex(where: { $0.id == run.id }) { data.runs[index].threadID = threadID }
                if let routineID = run.routineID, let index = data.routines.firstIndex(where: { $0.id == routineID }) {
                    data.routines[index].threadID = threadID
                } else if let index = data.agents.firstIndex(where: { $0.id == run.agentID }) { data.agents[index].threadID = threadID }
            }
        case .turn(let id): try store.updateRun(run.id) { $0.turnID = id }
        case .text(let text): liveText = text
        case .trace(let trace):
            try store.updateRun(run.id) {
                $0.trace.append(trace)
                if $0.trace.count > 100 { $0.trace.removeFirst($0.trace.count - 100) }
            }
        case .interaction(let request):
            if !interactions.contains(where: { $0.id == request.id }) { interactions.append(request) }
            try store.updateRun(run.id) { $0.status = .needsInput }
        }
    }

    private func finish(_ id: UUID, outcome: PersonalAgentOutcome) throws {
        try store.updateRun(id) {
            $0.status = outcome.status
            if !outcome.text.isEmpty || $0.result.isEmpty { $0.result = outcome.text }
            $0.detail = outcome.detail
            if let turnID = outcome.turnID { $0.turnID = turnID }
            $0.finishedAt = outcome.status == .uncertain ? nil : Date()
            // Quiet no-op routines remain auditable, without an unread badge.
            $0.isRead = $0.routineID != nil && outcome.status == .succeeded && outcome.text.trimmingCharacters(in: .whitespacesAndNewlines) == "NO_UPDATE"
        }
    }

    func stop(reason: String = "Stopping at your request…") {
        guard activeRunID != nil, !isStopping else { return }
        isStopping = true
        let runner = executor
        Task { await runner?.stop() }
        stopDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            guard let self, activeRunID != nil else { return }
            executor?.close()
            job?.cancel()
        }
        if let id = activeRunID { try? store.updateRun(id) { $0.detail = reason } }
    }

    func respond(_ request: CodexInteractionRequest, action: CodexInteractionAction, answers: [String: String] = [:]) {
        guard let executor, let id = activeRunID, !respondingRequestIDs.contains(request.id),
              interactions.contains(where: { $0.id == request.id }) else { return }
        do {
            let result = try request.response(action: action, answers: answers.mapValues { [$0] })
            respondingRequestIDs.insert(request.id)
            Task { [weak self] in
                defer { self?.respondingRequestIDs.remove(request.id) }
                do {
                    try await executor.respond(request, result: result)
                    guard let self else { return }
                    interactions.removeAll { $0.id == request.id }
                    try store.updateRun(id) {
                        $0.status = self.interactions.isEmpty ? .running : .needsInput
                        $0.trace.append(PersonalAgentTrace(title: action == .accept ? "Approved once" : "Declined", detail: request.title))
                    }
                } catch { self?.errorMessage = error.localizedDescription }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func check(_ run: PersonalAgentRun, stopIfRunning: Bool = false) {
        if cloud.enabled {
            remoteAction(["action": "check", "runID": run.id.uuidString, "stopIfRunning": stopIfRunning])
            return
        }
        guard checkingRunID == nil, activeRunID == nil, run.status == .uncertain else { return }
        guard let threadID = run.threadID else {
            errorMessage = "No runtime thread was saved. This run did not submit work."
            try? finish(run.id, outcome: PersonalAgentOutcome(status: .failed, text: run.result, detail: "Interrupted before a thread was saved."))
            return
        }
        checkingRunID = run.id
        Task { [weak self] in
            guard let self else { return }
            defer { checkingRunID = nil }
            do {
                let runner = makeExecutor(try await endpoint())
                defer { runner.close() }
                if let result = try await runner.reconcile(threadID: threadID, turnID: run.turnID, clientID: run.id.uuidString, stopIfRunning: stopIfRunning) { try finish(run.id, outcome: result) }
                else { errorMessage = "This run is still active or cannot yet be confirmed. It has not been restarted." }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func markRead(_ id: UUID) {
        if cloud.enabled { remoteAction(["action": "read", "id": id.uuidString]); return }
        attempt { try store.updateRun(id) { $0.isRead = true } }
    }
    func toggle(_ routine: PersonalAgentRoutine) {
        var edited = routine; edited.isEnabled.toggle()
        Task { do { try await save(.routine(edited)) } catch { errorMessage = error.localizedDescription } }
    }
    func activeRun(for agentID: UUID) -> PersonalAgentRun? {
        archive.runs.last { $0.agentID == agentID && $0.status.isInFlight }
    }

    func requests(for run: PersonalAgentRun) -> [CodexInteractionRequest] {
        cloud.enabled ? (cloud.requests[run.id] ?? []) : (activeRunID == run.id ? interactions : [])
    }

    func stop(_ run: PersonalAgentRun) {
        if cloud.enabled { remoteAction(["action": "stop", "runID": run.id.uuidString]) }
        else { stop() }
    }

    func respond(_ request: CodexInteractionRequest, runID: UUID, action: CodexInteractionAction, answers: [String: String]) {
        guard cloud.enabled else { respond(request, action: action, answers: answers); return }
        do {
            let result = try request.response(action: action, answers: answers.mapValues { [$0] })
            remoteAction(["action": "respond", "runID": runID.uuidString, "id": request.id.rawValue, "result": result])
        } catch { errorMessage = error.localizedDescription }
    }

    private func remoteAction(_ body: [String: Any]) {
        Task { do { try await cloud.action(body); errorMessage = nil } catch { errorMessage = error.localizedDescription } }
    }

    func save(_ editor: PersonalAgentEditor) async throws {
        switch editor {
        case .agent(let item):
            if cloud.enabled { try await cloud.save(item, collection: "agents") } else { try store.save(item) }
        case .routine(let item):
            if cloud.enabled { try await cloud.save(item, collection: "routines") } else { try store.save(item) }
        case .skill(let item):
            if cloud.enabled { try await cloud.save(item, collection: "skills") } else { try store.save(item) }
        }
    }

    func remove(_ editor: PersonalAgentEditor) async throws {
        let collection: String
        switch editor { case .agent: collection = "agents"; case .routine: collection = "routines"; case .skill: collection = "skills" }
        if cloud.enabled {
            try await cloud.action(["action": "delete", "collection": collection, "id": editor.id.uuidString])
            return
        }
        try store.update { data in
            switch editor {
            case .agent:
                data.agents.removeAll { $0.id == editor.id }
                data.routines.removeAll { $0.agentID == editor.id }
            case .routine: data.routines.removeAll { $0.id == editor.id }
            case .skill:
                data.skills.removeAll { $0.id == editor.id }
                for index in data.agents.indices { data.agents[index].skillIDs.removeAll { $0 == editor.id } }
                for index in data.routines.indices { data.routines[index].skillIDs.removeAll { $0 == editor.id } }
            }
        }
    }

    func attempt(_ operation: () throws -> Void) {
        do { try operation(); errorMessage = nil } catch { errorMessage = error.localizedDescription }
    }
}
