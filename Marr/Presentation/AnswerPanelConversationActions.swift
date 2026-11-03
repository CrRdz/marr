import AppKit
import Combine
import MarrCore
import QuartzCore
import SwiftUI

extension AnswerPanelView {
    func showHistorySearch() {
        historyStore.reload()
        showsSettingsPanel = false
        navigation.setHistoryExpanded(true)
    }

    func hideHistorySearch() {
        navigation.setHistoryExpanded(false)
        DispatchQueue.main.async {
            guard !showsHistoryPanel else { return }
            setQuestionFocus(true)
        }
    }

    var accountMenuEntries: [MarrAccountMenuEntry] {
        let entries = controller.aiConnections.connections.map { connection in
            MarrAccountMenuEntry(id: connection.id, title: connection.name,
                detail: connection.kind == .deepLX ? "Translation connection" : "AI connection",
                iconName: connection.iconName, section: .conversation)
        }
        return entries.isEmpty ? [.init(id: "setup", title: "Add connection", detail: "AI & Models",
            iconName: nil, section: .conversation)] : entries
    }

    var railAccountName: String {
        if controller.usesCodexForConversation { return "Codex" }
        return controller.defaultAIConnection?.name ?? "Marr"
    }

    var railAccountDetail: String {
        if controller.usesCodexForConversation { return "Work integration" }
        return controller.model.isEmpty ? "Choose a model" : controller.model
    }

    var railAccountInitial: String? {
        guard controller.activeChatGPTProfile?.isSignedIn == true
            || (workSession.codexSyncEnabled && workSession.account?.email != nil) else { return nil }
        return railAccountName.first.map { String($0).uppercased() }
    }

    func showSettings() {
        if !showsSettingsPanel { settingsReturnSection = navigation.section }
        navigation.section = .chats
        controller.cancelPendingHistoryLoad()
        setQuestionFocus(false)
        navigation.setHistoryExpanded(false)
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            showsSettingsPanel = true
        }
    }

    func showUtilityDestination(_ destination: AnswerPanelUtilityDestination?) {
        controller.cancelPendingHistoryLoad()
        if destination != nil { navigation.section = .chats }
        switch destination {
        case .history:
            showHistorySearch()
        case .settings:
            showSettings()
        case .aiModels:
            settingsNavigation.open(.conversation)
            showSettings()
        case .codex:
            guard workSession.codexSyncEnabled else { return }
            navigation.setHistoryExpanded(false)
            selectCodexMode()
        case .conversation, .work:
            navigation.setHistoryExpanded(false)
            showsSettingsPanel = false
            selectMode(isWork: destination == .work)
        case nil:
            break
        }
    }

    func hideSettings() {
        settingsNavigation.query = ""
        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
            showsSettingsPanel = false
            if let section = settingsReturnSection { navigation.section = section }
            settingsReturnSection = nil
        }
        DispatchQueue.main.async {
            guard !showsSettingsPanel, navigation.section == .chats else { return }
            setQuestionFocus(true)
        }
    }

    func backFromSettings() {
        if !settingsNavigation.back() { hideSettings() }
    }

    func handleEscape() {
        if showsAccountMenu { showsAccountMenu = false; return }
        if navigation.section == .personalAgent { navigation.section = .chats; return }
        if activeComposerMenu != nil { dismissComposerMenu(); return }
        if showsChatDetails { showsChatDetails = false; return }
        if showsRenameChat { showsRenameChat = false; return }
        if showsWorkCompletion { dismissedCompletion = workCompletionToken; return }
        if showsSlashCommandMenu { dismissedSlashMenuInput = question; return }
        switch AnswerPanelEscapeAction.resolve(
            showsSettings: showsSettingsPanel,
            showsHistory: showsHistoryPanel,
            isEditing: editingTurnID != nil
        ) {
        case .closeSettings:
            backFromSettings()
        case .closeHistory:
            hideHistorySearch()
        case .cancelEditing:
            cancelEditing()
        case .closePanel:
            actions.close()
        }
    }

    func sendCurrentQuestion() {
        if usesCodex {
            sendToCodex()
            return
        }
        let current = question
        if let editingTurnID {
            reviseAndResend(current, turnID: editingTurnID)
        } else {
            send(current)
        }
    }

    func send(_ rawQuestion: String) {
        let trimmedQuestion = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty, !session.hasLoadingTurn else {
            return
        }

        guard let turnID = session.beginTurn(question: trimmedQuestion) else { return }
        question = ""

        withAnimation(MarrMotion.transition(reducesMotion: reducesMotion)) {
            session.revealAssistant(for: turnID)
        }
        submit(turnID)
    }

    func sendToCodex() {
        persistComposerDraft()
        let request = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty || !workAttachments.isEmpty else { return }
        if request.hasPrefix("/") {
            if dispatchWorkCommand(request) { finishAcceptedWorkCommand() }
            return
        }
        let accepted: Bool
        if workSession.canSteer {
            accepted = workSession.steer(prompt: request, images: workAttachments)
        } else {
            guard workSession.canSubmit else { return }
            accepted = controller.submitToCodex(request, images: workAttachments)
        }
        if accepted {
            loadedDraftKey = workSession.composerDraftKey
            setComposerText("")
            workAttachments = []
            persistComposerDraft()
        }
    }

    func movePendingAttachmentsToWork(ids: Set<UUID>? = nil) {
        let existingIDs = Set(workAttachments.map(\.id))
        workAttachments.append(contentsOf: session.takePendingAttachments(ids: ids).filter { !existingIDs.contains($0.id) })
    }

    func restoreWorkDraft(_ draft: CodexSubmissionDraft) {
        persistComposerDraft()
        guard workSession.restoreRecoveredDraft(draft) else { return }
        loadComposerDraft(for: workSession.composerDraftKey)
        setQuestionFocus(true)
    }

    func beginEditing(_ turn: ConversationTurn) {
        guard canEdit(turn) else { return }
        editingTurnID = turn.id
        question = turn.question
        setQuestionFocus(true)
    }

    func cancelEditing() {
        editingTurnID = nil
        question = ""
        setQuestionFocus(true)
    }

    func canEdit(_ turn: ConversationTurn) -> Bool {
        session.latestEditableTurnID == turn.id
    }

    func reviseAndResend(_ rawQuestion: String, turnID: UUID) {
        let trimmedQuestion = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty, !session.hasLoadingTurn else {
            question = rawQuestion
            return
        }

        guard session.reviseLatestTurn(turnID, question: trimmedQuestion) else {
            question = rawQuestion
            return
        }

        editingTurnID = nil
        question = ""
        submit(turnID)
    }

    func submitInitialQuestion() {
        guard
            !hasSubmittedInitialQuestion,
            let turn = session.turns.first,
            turn.isLoading
        else {
            return
        }

        hasSubmittedInitialQuestion = true
        if usesCodex, let draft = session.takeUnsubmittedInitialTurn(turn.id) {
            workAttachments.append(contentsOf: draft.attachments)
            if question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { setComposerText(draft.question) }
            return
        }
        submit(turn.id)
    }

    func retry(_ turnID: UUID) {
        guard session.prepareRetry(turnID) else { return }
        submit(turnID)
    }

    func submit(_ turnID: UUID) {
        requestCoordinator.submit(turnID)
    }
}

/// Observes trackpad navigation without replacing vertical scrolling or mouse dragging.
struct TwoFingerBackGesture: NSViewRepresentable {
    let isEnabled: Bool
    let onBack: () -> Void

    func makeNSView(context: Context) -> BackGestureView { BackGestureView() }

    func updateNSView(_ view: BackGestureView, context: Context) {
        view.isEnabled = isEnabled
        view.onBack = onBack
    }

    final class BackGestureView: NSView {
        var isEnabled = false
        var onBack: (() -> Void)?
        private var monitor: Any?
        private var horizontal: CGFloat = 0
        private var vertical: CGFloat = 0
        private var didNavigate = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, self.isEnabled, event.window === self.window,
                      event.hasPreciseScrollingDeltas,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil))
                else { return event }
                if event.phase.contains(.began) {
                    self.horizontal = 0
                    self.vertical = 0
                    self.didNavigate = false
                }
                guard !event.phase.isEmpty, !self.didNavigate else { return event }
                self.horizontal += event.scrollingDeltaX
                self.vertical += event.scrollingDeltaY
                if self.horizontal > 70 && self.horizontal > abs(self.vertical) * 2 {
                    self.didNavigate = true
                    self.onBack?()
                    return nil
                }
                return event
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

/// Only the empty header area moves the window; selectable content keeps mouse drags.
struct AnswerPanelDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
        override func mouseDown(with event: NSEvent) {
            (window as? AnswerPanelWindow)?.prepareForUserGeometryChange?()
            window?.performDrag(with: event)
        }
    }
}
