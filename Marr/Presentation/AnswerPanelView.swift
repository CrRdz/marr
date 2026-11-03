import AppKit
import Combine
import MarrCore
import QuartzCore
import SwiftUI

struct AnswerPanelView: View {
    private struct CompletionContext: Hashable {
        let token: AgentComposerToken?
        let workspacePath: String?
    }
    @ObservedObject var controller: MarrController
    @ObservedObject var workSession: RuntimeWorkspaceController
    @ObservedObject private var composerDraftStore: ComposerDraftStore
    @ObservedObject var session: ConversationSession
    @ObservedObject var historyStore: ConversationHistoryStore
    let requestCoordinator: ConversationRequestCoordinator
    let titleCoordinator: ConversationTitleCoordinator
    @ObservedObject var navigation: AnswerPanelNavigation
    let actions: AnswerPanelActions

    @State var question = ""
    @State var loadedDraftKey: ComposerDraftKey?
    @State var hasSubmittedInitialQuestion = false
    @State var editingTurnID: UUID?
    var showsHistoryPanel: Bool { navigation.isHistoryExpanded }
    private var hasSidebarColumn: Bool { showsHistoryPanel || navigation.sidebarRevealWidth > 0 }
    @State var showsSettingsPanel = false
    @State var showsAccountMenu = false
    @State var settingsReturnSection: MarrPanelSection?
    @StateObject var settingsNavigation = MarrSettingsNavigation()
    @State var usesCodex = false
    @State private var localWorkMode = false
    @State private var showsGlobalSearch = false
    @State private var showsNewWorkspace = false
    private var isWorkMode: Bool { usesCodex || localWorkMode }
    private var localWorkspace: LocalWorkspaceRecord? { historyStore.workspaces.first { $0.id == session.workspaceID } }
    @State private var showsCodexTaskBrowser = false
    @State var showsChatDetails = false
    @State var showsRenameChat = false
    @State private var renamingTaskID: UUID?
    @State private var renamedChatTitle = ""
    @State private var conversationTitleHovered = false
    @StateObject private var conversationScrollChrome = MarrConversationScrollChrome()
    @State private var selectedSlashCommandIndex = 0
    @State var dismissedSlashMenuInput: String?
    @State private var attachmentErrorMessage: String?
    @State private var isAttachmentDropTargeted = false
    @State var workAttachments: [ConversationImageAsset] = []
    @State private var composerSelection = NSRange(location: 0, length: 0)
    @State var dismissedCompletion: AgentComposerToken?
    @State private var commandFeedback: String?
    @State private var showsGoalEditor = false
    @State private var workEditorFocused = false
    @State private var completionAvailableHeight: CGFloat = 320
    @State private var mentionCapabilitiesWorkspace: String?
    @State private var pendingFileQuery: String?
    @Namespace private var modeSelection
    @Environment(\.accessibilityReduceMotion) var reducesMotion
    @Environment(\.accessibilityReduceTransparency) private var reducesTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(MarrAppearanceKeys.glassSurfaces) private var usesGlassSurfaces = true
    @AppStorage(MarrBubbleColor.storageKey) private var bubbleColor = MarrBubbleColor.system.rawValue
    @AppStorage(MarrAccentColor.storageKey) private var accentColor = MarrAccentColor.system.rawValue
    @FocusState private var questionFocused: Bool

    @State private var panelWidth = AnswerPanelConversationLayout.panelSize.width
    @State var activeComposerMenu: MarrComposerMenuKind?
    @State private var morphMenu: MarrComposerMenuKind?
    @State private var menuExpansion: CGFloat = 0
    @State private var menuTransitionID = UUID()
    @State private var composerControlFrames: [MarrComposerMenuKind: CGRect] = [:]
    @State private var composerBounds: CGRect = .zero
    @State private var composerSendBounds: CGRect = .zero
    private var isModelMenuActive: Bool { activeComposerMenu == .workModel || activeComposerMenu == .planModel }
    @State private var measuredMenuHeight: CGFloat = 0
    @State private var attachmentActionsExpanded = false
    @StateObject private var composerMenuState = MarrComposerMenuState()
    private var showsWorkModelPicker: Bool {
        get { activeComposerMenu == .workModel }
        nonmutating set { setComposerMenu(newValue ? .workModel : nil) }
    }
    private var showsChatGPTModelPicker: Bool {
        get { activeComposerMenu == .planModel }
        nonmutating set { setComposerMenu(newValue ? .planModel : nil) }
    }
    private var showsLocalWorkLanding: Bool {
        localWorkMode && session.turns.isEmpty
    }
    private var showsComposerLanding: Bool { !usesCodex && session.turns.isEmpty && !session.isDeleted }
    private var composerWidth: CGFloat {
        let column = MarrChatLayout.columnWidth(in: panelWidth)
        return showsComposerLanding ? min(MarrChatLayout.landingMaximumWidth, column) : column
    }
    private var activeComposerBindings: [ComposerMentionBinding] {
        guard usesCodex else { return [] }
        return workSession.composerBindings.filter {
            !$0.ranges(in: question, workspaceURL: workSession.workspaceURL).isEmpty
        }
    }
    private let conversationHeaderHeight: CGFloat = 78

    init(
        controller: MarrController,
        session: ConversationSession,
        historyStore: ConversationHistoryStore,
        requestCoordinator: ConversationRequestCoordinator,
        titleCoordinator: ConversationTitleCoordinator,
        navigation: AnswerPanelNavigation,
        actions: AnswerPanelActions
    ) {
        self.controller = controller
        _workSession = ObservedObject(wrappedValue: controller.codexWorkspace)
        _composerDraftStore = ObservedObject(wrappedValue: controller.codexWorkspace.composerDraftStore)
        self.session = session
        self.requestCoordinator = requestCoordinator
        self.titleCoordinator = titleCoordinator
        self.navigation = navigation
        self.actions = actions
        _historyStore = ObservedObject(wrappedValue: historyStore)
        _showsSettingsPanel = State(initialValue: navigation.request.destination == .settings
            || navigation.request.destination == .aiModels)
        if navigation.request.destination == .aiModels {
            let settings = MarrSettingsNavigation()
            settings.open(.conversation)
            _settingsNavigation = StateObject(wrappedValue: settings)
        }
        let startsInCodex = navigation.request.destination == .codex && controller.codexWorkspace.codexSyncEnabled
        _usesCodex = State(initialValue: startsInCodex)
        _localWorkMode = State(initialValue: !startsInCodex && (navigation.request.destination == .work || session.workspaceID != nil))
    }

    private var panelWithDraftEvents: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                fixedAnswerStack
                    .padding(AnswerPanelConversationLayout.windowPadding)
                    .accessibilityHidden(activeComposerMenu != nil && !isModelMenuActive)
                    .allowsHitTesting(activeComposerMenu == nil || isModelMenuActive)
                composerMenuOverlay(in: geometry.size)
            }
            .contentShape(Rectangle())
            .simultaneousGesture(SpatialTapGesture().onEnded { event in
                if activeComposerMenu != nil { return }
                guard activeComposerMenu == nil, attachmentActionsExpanded,
                      let frame = composerControlFrames[.attachments], !frame.contains(event.location) else { return }
                withAnimation(composerMenuAnimation) { attachmentActionsExpanded = false }
            })
        }
        .coordinateSpace(name: "answer-panel")
        .onPreferenceChange(MarrComposerControlFrames.self) { composerControlFrames = $0 }
        .onPreferenceChange(MarrComposerBounds.self) { composerBounds = $0 }
        .onPreferenceChange(MarrComposerSendBounds.self) { composerSendBounds = $0 }
        .onPreferenceChange(MarrComposerMenuHeight.self) { height in
            if activeComposerMenu != nil, height > 0, abs(height - measuredMenuHeight) > 0.5 {
                withAnimation(composerMenuAnimation) { measuredMenuHeight = height }
            }
        }
        .onChange(of: activeComposerMenu) { _, menu in animateComposerMenu(menu) }
        .onPreferenceChange(ComposerTopPreference.self) { top in
            completionAvailableHeight = max(40, min(320, top - conversationHeaderHeight - 12))
        }
        .frame(minWidth: MarrPanelShellLayout.windowSize.width,
               minHeight: AnswerPanelConversationLayout.panelSize.height)
        .onAppear {
            navigation.persistDraft = { persistComposerDraft() }
            workSession.setHistorySyncAppActive(NSApp.isActive)
            updateHistorySyncVisibility()
            if loadedDraftKey == nil { loadComposerDraft(for: currentComposerDraftKey) }
            DispatchQueue.main.async {
                setQuestionFocus(true)
                if usesCodex {
                    let existing = Set(composerDraftStore.draft(for: .conversation(session.id)).attachments.map(\.id))
                    movePendingAttachmentsToWork(ids: Set(session.pendingImageIDs).subtracting(existing))
                    workSession.refreshSkills()
                }
                submitInitialQuestion()
                titleCoordinator.generateIfNeeded()
            }
        }
        .onDisappear { persistComposerDraft() }
        .sheet(isPresented: $showsGlobalSearch) {
            MarrGlobalConversationSearch(store: historyStore, workspace: workSession,
                canOpenLocal: !session.hasLoadingTurn && !workSession.isRunning && !workSession.isRemoteTaskActive,
                onOpenLocal: { conversation in
                    showsGlobalSearch = false
                    if conversation.id == session.id { selectMode(isWork: false) }
                    else { persistComposerDraft(); actions.openHistoryConversation(conversation) }
                }, onOpenTask: { task in
                    guard workSession.selectTask(task) else { return false }
                    showsGlobalSearch = false
                    selectSidebarTask()
                    return true
                })
        }
        .sheet(isPresented: $showsNewWorkspace) {
            MarrWorkspaceCreationSheet(store: historyStore) { workspace in
                persistComposerDraft()
                controller.startWorkspaceConversation(workspace)
            }
        }
        .onChange(of: workSession.codexSyncEnabled) { _, enabled in
            if !enabled && usesCodex {
                usesCodex = false
                localWorkMode = true
                showsCodexTaskBrowser = false
            }
            updateHistorySyncVisibility()
        }
        .onChange(of: historyStore.deletedConversationIDs) { _, deletedIDs in
            guard deletedIDs.contains(session.id) else { return }
            requestCoordinator.cancel()
            titleCoordinator.cancel()
            session.markDeleted()
        }
        .onChange(of: historyStore.conversations) { _, records in
            if let record = records.first(where: { $0.id == session.id }) {
                let previousWorkspaceID = session.workspaceID
                session.updateStorageMetadata(from: record)
                if !usesCodex, previousWorkspaceID != record.workspaceID { localWorkMode = record.workspaceID != nil }
            }
        }
        .onChange(of: workSession.composerDraftKey) { _, key in
            activeComposerMenu = nil
            if usesCodex, loadedDraftKey != key { switchComposerDraft(to: key) }
        }
        .onChange(of: session.id) { _, id in
            activeComposerMenu = nil
            if !usesCodex { switchComposerDraft(to: .conversation(id)) }
        }
        .onChange(of: composerSelection) { _, _ in persistComposerDraft() }
        .onChange(of: editingTurnID) { _, _ in persistComposerDraft() }
        .onChange(of: workAttachments) { _, _ in persistComposerDraft() }
    }

    private var panelWithComposerEvents: some View {
        panelWithDraftEvents
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            workSession.setHistorySyncAppActive(true)
            if navigation.isPresented && usesCodex && workSession.codexSyncEnabled { workSession.refreshModelsIfNeeded() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            workSession.setHistorySyncAppActive(false)
        }
        .onChange(of: navigation.isPresented) { _, _ in updateHistorySyncVisibility() }
        .onChange(of: showsHistoryPanel) { _, _ in updateHistorySyncVisibility() }
        .onChange(of: showsSettingsPanel) { _, shown in
            if shown { activeComposerMenu = nil }
            updateHistorySyncVisibility()
        }
        .onChange(of: controller.provider) { _, _ in activeComposerMenu = nil }
        .onChange(of: session.turns) { _, _ in
            titleCoordinator.generateIfNeeded()
        }
        .onChange(of: session.focusRequestID) { _, _ in
            if !showsSettingsPanel {
                setQuestionFocus(true)
            }
        }
        .onChange(of: session.pendingImageIDs) { previous, current in
            if usesCodex {
                movePendingAttachmentsToWork(ids: Set(current).subtracting(previous))
            }
            persistComposerDraft()
        }
        .onChange(of: usesCodex) { _, isWork in
            activeComposerMenu = nil
            updateHistorySyncVisibility()
            restoreComposerMode(isWork: isWork)
            // The old field must release focus before the replacement editor
            // joins its window. Otherwise AppKit can keep a detached responder.
            setQuestionFocus(false)
            DispatchQueue.main.async {
                guard usesCodex == isWork, !showsSettingsPanel, !showsCodexTaskBrowser else { return }
                setQuestionFocus(true)
            }
            if !isWork { showsChatDetails = false }
            if isWork {
                workSession.refreshSkills()
            }
        }
        .onChange(of: navigation.request) { _, request in
            showUtilityDestination(request.destination)
        }
        .onChange(of: question) { _, nextQuestion in
            selectedSlashCommandIndex = 0
            if dismissedSlashMenuInput != nextQuestion { dismissedSlashMenuInput = nil }
            persistComposerDraft()
        }
        .task(id: CompletionContext(token: workCompletionToken, workspacePath: workSession.workspaceURL?.path)) {
            guard usesCodex, let token = workCompletionToken else {
                pendingFileQuery = nil
                workSession.clearFileSearch()
                return
            }
            if token.kind == .skill, workSession.skills.isEmpty,
               !workSession.loadingCapabilityMethods.contains("skills/list") { workSession.refreshSkills() }
            if token.kind == .file {
                let path = workSession.workspaceURL?.path ?? ""
                if mentionCapabilitiesWorkspace != path {
                    mentionCapabilitiesWorkspace = path
                    workSession.refreshPlugins()
                    workSession.refreshApps()
                }
                pendingFileQuery = token.query
                workSession.clearFileSearch()
                do { try await Task.sleep(for: .milliseconds(140)) } catch { return }
                guard !Task.isCancelled else { return }
                workSession.searchFiles(query: token.query)
                pendingFileQuery = nil
            } else {
                pendingFileQuery = nil
                workSession.clearFileSearch()
            }
        }
        .onChange(of: workCompletionToken) { _, _ in selectedSlashCommandIndex = 0 }
        .onChange(of: workCompletionOptions.map(\.id)) { old, new in
            let selectedID = old.indices.contains(selectedSlashCommandIndex) ? old[selectedSlashCommandIndex] : nil
            selectedSlashCommandIndex = selectedID.flatMap { new.firstIndex(of: $0) } ?? 0
        }
    }

    var body: some View {
#if DEBUG
        let _ = MarrScrollDiagnostics.recordPanelEvaluation()
#endif
        panelWithComposerEvents
        .onChange(of: workSession.commandOutput) { _, value in
            if !value.isEmpty { commandFeedback = value }
        }
        .onChange(of: showsChatDetails) { _, presented in
            if !presented, usesCodex, !showsSettingsPanel, !showsCodexTaskBrowser { setQuestionFocus(true) }
        }
        .onChange(of: workSession.capabilityErrors) { previous, current in
            for method in ["thread/fork", "thread/archive"] {
                if let error = current[method], error != previous[method] { commandFeedback = error }
            }
        }
        .sheet(isPresented: $showsGoalEditor, onDismiss: { setQuestionFocus(true) }) {
            ThreadGoalEditor(workspace: workSession)
        }
        .sheet(isPresented: $showsRenameChat, onDismiss: { setQuestionFocus(true) }) {
            renameChatSheet
        }
        .alert(
            "Couldn’t Add Attachment",
            isPresented: Binding(
                get: { attachmentErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        attachmentErrorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(attachmentErrorMessage ?? "")
        }
        .background(TwoFingerBackGesture(
            isEnabled: navigation.section == .personalAgent || showsSettingsPanel || showsHistoryPanel || showsCodexTaskBrowser,
            onBack: navigateBack
        ))
        .background {
            if navigation.isFullScreen { Color.white.ignoresSafeArea() }
        }
        .environment(\.colorScheme, navigation.isFullScreen ? .light : colorScheme)
        .font(MarrTypography.font(.body))
        .transaction { transaction in
            if reducesMotion {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        .onExitCommand(perform: handleEscape)
    }

    private var fixedAnswerStack: some View {
        HStack(spacing: 0) {
            if !showsSettingsPanel {
                PersonalAgentNavigationRail(selection: $navigation.section, coordinator: controller.personalAgent,
                accountName: railAccountName, accountDetail: railAccountDetail, accountInitial: railAccountInitial,
                onOpenSettings: { showSettings() },
                onOpenAccount: { settingsNavigation.open(.account); showSettings() },
                onSelect: { section in
                    if section == .personalAgent { navigation.setHistoryExpanded(true) }
                    showsSettingsPanel = false
                    settingsReturnSection = nil
                    settingsNavigation.query = ""
                }, showsAccountMenu: showsAccountMenu, onToggleAccountMenu: { showsAccountMenu.toggle() })
            }
            primarySurface
        }
        .marrGlassSurface(
            cornerRadius: AnswerPanelConversationLayout.surfaceCornerRadius,
            frostsTop: true,
            frostOpacity: 0.80,
            drawsBorder: !navigation.isFullScreen,
            solidBackground: navigation.isFullScreen ? .white : nil
        )
        .clipShape(RoundedRectangle(cornerRadius: AnswerPanelConversationLayout.surfaceCornerRadius))
        .overlay(alignment: .topLeading) { sharedWindowControls }
        .overlayPreferenceValue(MarrAccountAnchorKey.self) { anchor in
            if showsAccountMenu, let anchor {
                MarrAnchoredAccountMenu(anchor: anchor, entries: accountMenuEntries,
                    onDismiss: { showsAccountMenu = false },
                    onOpenEntry: { entry in
                        showsAccountMenu = false
                        settingsNavigation.open(entry.section)
                        showSettings()
                    }, onOpenSettings: { showsAccountMenu = false; showSettings() })
            }
        }
        .onChange(of: showsSettingsPanel) { _, shown in if shown { showsAccountMenu = false } }
        .onChange(of: navigation.section) { _, section in
            persistComposerDraft()
            activeComposerMenu = nil
            setQuestionFocus(section == .chats && !showsSettingsPanel && !showsCodexTaskBrowser)
            updateHistorySyncVisibility()
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .bottom
        )
        .animation(MarrMotion.sheet(reducesMotion: reducesMotion), value: showsSettingsPanel)
    }

    private var primarySurface: some View {
        ZStack {
            AnswerPanelSidebarMotionSurface(
                revealWidth: navigation.sidebarRevealWidth,
                isExpanded: showsHistoryPanel,
                canvasWidth: navigation.sidebarCanvasWidth.map { max(0, $0 - visibleNavigationRailWidth) },
                windowMotion: MarrPanelShellLayout.contentMotion(navigation.sidebarWindowMotion, railWidth: visibleNavigationRailWidth),
                animates: navigation.animatesSidebar && !reducesMotion,
                sidebar: historySidebar
                    .padding(.leading, 8)
                    .padding(.trailing, 4)
                    .padding(.top, MarrPanelShellLayout.titleRowTop)
                    .padding(.bottom, 8),
                conversation: conversationSurface,
                onContentWidthChange: updateConversationLayoutWidth
            )
            .opacity(navigation.section == .chats ? 1 : 0)
            .allowsHitTesting(navigation.section == .chats)
            .accessibilityHidden(navigation.section != .chats)
            if navigation.section == .personalAgent {
                PersonalAgentWorkspaceView(coordinator: controller.personalAgent, runtime: workSession, navigation: navigation)
            }
        }
    }

    private var visibleNavigationRailWidth: CGFloat {
        showsSettingsPanel ? 0 : MarrPanelShellLayout.railWidth
    }

    private func updateConversationLayoutWidth(_ width: CGFloat) {
        navigation.recordContentLayoutWidth(width)
        guard panelWidth != width else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { panelWidth = width }
    }

    private var sharedWindowControls: some View {
        HStack(alignment: .center, spacing: 10) {
            // Reserve the native traffic lights' space; AppKit owns their views and hover regions.
            Color.clear.frame(width: 70, height: 30)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            if navigation.section == .chats {
                if !showsSettingsPanel || hasSidebarColumn { historyToggleButton }
                panelControls
            } else {
                Button { navigation.setHistoryExpanded(!showsHistoryPanel) } label: {
                    MarrIcon("sidebar.left", size: MarrUI.Icon.navigation)
                        .foregroundStyle(MarrPanelColors.secondary(for: colorScheme)).frame(width: 30, height: 30)
                }
                .buttonStyle(MarrButtonStyle(.ghost, size: .icon))
                .help(showsHistoryPanel ? "Hide agents sidebar" : "Show agents sidebar")
                .accessibilityLabel(showsHistoryPanel ? "Hide agents sidebar" : "Show agents sidebar")
                .accessibilityIdentifier("marr.agent.sidebar.toggle")
                .keyboardShortcut("s", modifiers: [.command, .control])
                AnswerPanelDragRegion().frame(maxWidth: .infinity, minHeight: 30)
                    .accessibilityHidden(true)
            }
        }
        .frame(height: MarrPanelShellLayout.toolbarHeight)
        .padding(.horizontal, 12)
        .padding(.top, MarrPanelShellLayout.toolbarTop)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Window toolbar")
        .accessibilityIdentifier("marr.window.toolbar")
    }

    private var conversationSurface: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if showsSettingsPanel {
                    settingsHeader
                        .transition(.opacity)
                } else if usesCodex {
                    codexHeader
                        .transition(.opacity)
                } else {
                    conversationHeader
                        .transition(.opacity)
                }
            }

            Group {
                if showsSettingsPanel {
                    settingsContent
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else if usesCodex {
                    if showsCodexTaskBrowser {
                        codexTaskBrowser
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    } else {
                        codexContent
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                } else if session.isDeleted {
                    VStack(spacing: 16) {
                        Text("This conversation was deleted").marrTextStyle(.title, weight: .semibold)
                        Button("New conversation") { controller.startNewConversation() }.buttonStyle(.borderedProminent)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if showsLocalWorkLanding {
                    MarrLocalWorkLanding(store: historyStore, selectedWorkspace: localWorkspace,
                        composerWidth: composerWidth, onNewWorkspace: { showsNewWorkspace = true }, onSelect: {
                        persistComposerDraft()
                        controller.startWorkspaceConversation($0)
                    }) {
                        composerFooter
                    }
                } else if showsComposerLanding {
                    MarrComposerLanding { composerFooter }
                } else {
                    conversationScroll
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !showsSettingsPanel, !session.isDeleted || usesCodex, !(usesCodex && showsCodexTaskBrowser), !showsComposerLanding {
                composerFooter
            }
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .top
        )
        .frame(maxWidth: .infinity, alignment: .center)
        .modifier(AttachmentDropArea(isEnabled: canAcceptAttachments,
            isTargeted: $isAttachmentDropTargeted, tint: selectedAccent.color, onDrop: receiveAttachmentFiles))
    }

    private var composerFooter: some View {
        VStack(spacing: MarrUI.Spacing.regular) {
            if let error = composerDraftStore.lastErrorMessage {
                Label(error, marrSymbol: "exclamationmark.triangle")
                    .font(MarrTypography.font(.secondary))
                    .foregroundStyle(.orange)
                    .frame(width: composerWidth, alignment: .leading)
                    .textSelection(.enabled)
            }
            if usesCodex, let commandFeedback {
                HStack(alignment: .top, spacing: MarrUI.Spacing.regular) {
                    ScrollView {
                        Text(commandFeedback).font(MarrTypography.font(.secondary)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 125)
                    Button { self.commandFeedback = nil } label: { MarrIcon("xmark") }
                        .buttonStyle(.plain).accessibilityLabel("Dismiss command result")
                }
                .padding(10).frame(width: composerWidth)
                .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            }
            if usesCodex, !workSession.recoverableDrafts.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
                        ForEach(workSession.recoverableDrafts) { draft in
                            VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
                                VStack(alignment: .leading, spacing: MarrUI.Spacing.tight) {
                                    Label(draft.recoveryTitle, marrSymbol: "exclamationmark.circle")
                                        .fontWeight(.medium)
                                    Text(recoveryDestination(draft))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                    Text(draft.prompt.isEmpty ? "\(draft.attachments.count) attachments" : draft.prompt).lineLimit(2)
                                    if let error = draft.recoveryExplanation {
                                        Text(error)
                                            .foregroundStyle(MarrPanelColors.secondary(for: colorScheme))
                                            .lineLimit(draft.hasWriterConflict ? nil : 2)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .foregroundStyle(MarrPanelColors.primary(for: colorScheme))
                                HStack {
                                    if draft.hasWriterConflict {
                                        Button("Copy question") {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(draft.prompt, forType: .string)
                                        }
                                        .disabled(draft.prompt.isEmpty)
                                    }
                                    Button("Restore draft") { restoreWorkDraft(draft) }
                                        .disabled(workSession.isRunning || workSession.isRemoteTaskActive)
                                    Spacer(minLength: 0)
                                    Button("Discard") { workSession.discardRecoverableDraft(draft.id) }
                                }
                            }
                            .font(MarrTypography.font(.secondary))
                            .controlSize(.small)
                            .padding(9)
                            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
                .frame(width: composerWidth)
                .frame(maxHeight: 140)
            }
            if usesCodex ? (!workAttachments.isEmpty || !activeComposerBindings.isEmpty) : !session.pendingImageIDs.isEmpty {
                ComposerContextStrip(
                    attachments: usesCodex ? workAttachments : session.pendingImageIDs.compactMap { session.images[$0] },
                    bindings: activeComposerBindings,
                    onRemoveAttachment: { id in
                        if usesCodex { workAttachments.removeAll { $0.id == id } }
                        else { session.removePendingAttachment(id) }
                        persistComposerDraft()
                    },
                    onRemoveBinding: removeContextBinding
                )
                .frame(width: composerWidth, height: 42, alignment: .topLeading)
            }

            Group {
                    composer
                    .frame(width: composerWidth)
                    .background(composerSurface)
                    .marrAmbientGlow(isRunning: usesCodex
                        ? (workSession.isRunning && workSession.pendingInteractions.isEmpty && workSession.approvalRequest == nil)
                        : session.turns.contains { $0.isLoading && $0.retryAt == nil }, tint: selectedAccent.color)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: ComposerTopPreference.self,
                                value: geometry.frame(in: .named("answer-panel")).minY)
                        }
                    }
                    .overlay(alignment: .top) {
                        Group {
                            if usesCodex, showsWorkCompletion {
                                workCompletionPanel
                            } else if !usesCodex, showsSlashCommandMenu {
                                slashCommandMenu
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .alignmentGuide(.top) { $0[.bottom] + 8 }
                    }
                    .zIndex(20)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.top, showsComposerLanding ? 0 : 10)
        .padding(.bottom, showsComposerLanding ? 0 : AnswerPanelConversationLayout.bottomInset)
        .frame(maxWidth: .infinity)
        .zIndex(showsSlashCommandMenu || showsWorkCompletion ? 20 : 1)
    }

    private var composerSurface: some View {
        MarrChatComposerSurface(isFocused: usesCodex ? workEditorFocused : questionFocused, isLanding: showsComposerLanding)
    }

    private var settingsHeader: some View {
        // The shared window toolbar owns the searchable header.
        Color.clear.frame(height: 49).accessibilityHidden(true)
    }

    private var settingsContent: some View {
        AnswerPanelSettingsView(controller: controller, navigation: settingsNavigation)
            .foregroundStyle(MarrPanelColors.primary(for: colorScheme))
    }

    private var historySidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text("Workspaces").marrTextStyle(.caption, weight: .medium)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button { showsGlobalSearch = true } label: {
                    MarrIcon("magnifyingglass", size: MarrUI.Icon.inline).frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Search all conversations")
                .accessibilityLabel("Search all conversations")
                .accessibilityIdentifier("marr.history.globalSearch")
                .keyboardShortcut("f", modifiers: [.command, .shift])
                Menu {
                    Button("New workspace", marrSymbol: "plus") { showsNewWorkspace = true }
                        .disabled(session.hasLoadingTurn)
                    if workSession.codexSyncEnabled {
                        Button("Add workspace folder", marrSymbol: "folder.badge.plus") {
                            if workSession.chooseWorkspace() { selectCodexMode() }
                        }.disabled(!workSession.canSubmit || workSession.isRunning || workSession.isRemoteTaskActive)
                    }
                } label: {
                    MarrIcon("plus", size: MarrUI.Icon.inline).frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .help("Add workspace").accessibilityLabel("Add workspace")
            }
            .foregroundStyle(MarrPanelColors.secondary(for: colorScheme))
            .padding(.leading, 19).padding(.trailing, 12)
            .padding(.top, 10).padding(.bottom, 8)
            if controller.loadingHistoryConversationID != nil {
                HStack(spacing: MarrUI.Spacing.regular) {
                    ProgressView().controlSize(.small)
                    Text("Opening conversation…").font(MarrTypography.font(.secondary))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            MarrHistoryScrollView(position: navigation.historyScrollPosition) {
                LazyVStack(alignment: .leading, spacing: MarrUI.Spacing.tight) {
                    MarrLocalWorkspaceSidebar(store: historyStore,
                        currentConversationID: usesCodex ? nil : session.id,
                        currentWorkspaceID: usesCodex ? nil : session.workspaceID,
                        searchText: "",
                        showsHeader: false,
                        canChangeConversation: !session.hasLoadingTurn && !workSession.isRunning,
                        onNewWorkspace: { showsNewWorkspace = true },
                        onNewConversation: { persistComposerDraft(); controller.startWorkspaceConversation($0) },
                        onOpen: { persistComposerDraft(); actions.openHistoryConversation($0) })
                    MarrWorkspaceSidebar(workspace: workSession, searchText: .constant(""),
                        collapsedWorkspaceIDs: $navigation.collapsedWorkspaceIDs,
                        expandedWorkspaceIDs: $navigation.expandedWorkspaceIDs,
                        isWorkActive: usesCodex, showsHeader: false,
                        onSelectTask: { selectSidebarTask() }, onNewTask: { selectSidebarTask() },
                        localConversations: historyStore.conversations, currentLocalID: usesCodex ? nil : session.id,
                        conversationsExpanded: $navigation.isLocalHistoryExpanded,
                        canOpenLocal: !session.hasLoadingTurn && !workSession.isRunning && !workSession.isRemoteTaskActive,
                        onOpenLocal: { conversation in
                            if conversation.id == session.id { selectMode(isWork: false) }
                            else { persistComposerDraft(); actions.openHistoryConversation(conversation) }
                        })
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
                .scrollTargetLayout()
            }
            .scrollIndicators(.automatic)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(MarrPanelColors.primary(for: colorScheme))
        .background {
            RoundedRectangle(cornerRadius: MarrUI.Radius.panel, style: .continuous)
                .fill(MarrUI.Surface.canvas)
        }
        .clipShape(RoundedRectangle(cornerRadius: MarrUI.Radius.panel, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: MarrUI.Radius.panel, style: .continuous)
                .strokeBorder(MarrUI.Border.color(.subtle, increasedContrast: colorSchemeContrast == .increased),
                              lineWidth: colorSchemeContrast == .increased ? 1 : 0.5)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .onChange(of: workSession.savedWorkspaces.map(\.id)) { _, ids in
            navigation.registerWorkspaces(Set(ids))
        }
        .accessibilityLabel("Conversation history sidebar")
        .accessibilityIdentifier("marr.history.sidebar")
    }

    private func selectSidebarTask() {
        selectCodexMode()
    }

    private func updateHistorySyncVisibility() {
        // The controller pauses synchronously before hiding/closing. Ignore
        // deferred SwiftUI events from an old panel after its replacement shows.
        guard navigation.isPresented else { return }
        workSession.setHistorySyncVisible(navigation.section == .chats && workSession.codexSyncEnabled && !showsSettingsPanel && (showsHistoryPanel || usesCodex))
    }

    private var historyToggleButton: some View {
        Button {
            if showsHistoryPanel { hideHistorySearch() }
            else { showHistorySearch() }
        } label: {
            MarrIcon("sidebar.left", size: MarrUI.Icon.navigation)
                .foregroundStyle(MarrPanelColors.secondary(for: colorScheme))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(MarrButtonStyle(.ghost, size: .icon))
        .help(showsHistoryPanel ? "Hide history sidebar" : "Show history sidebar")
        .accessibilityLabel(showsHistoryPanel ? "Hide history sidebar" : "Show history sidebar")
        .accessibilityValue(showsHistoryPanel ? "Expanded" : "Collapsed")
        .accessibilityIdentifier("marr.history.toggle")
        .keyboardShortcut("s", modifiers: [.command, .control])
    }

    private var panelControls: some View {
        HStack(spacing: MarrUI.Spacing.regular) {
            if showsSettingsPanel {
                MarrSettingsSearchField(navigation: settingsNavigation)
            } else {
                AnswerPanelDragRegion()
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .accessibilityHidden(true)
            }

            if !showsSettingsPanel {
                HStack(spacing: MarrUI.Spacing.tight) {
                    modeTab("Conversation", isWork: false)
                    modeTab("Work", isWork: true)
                }
                .padding(3)
                .background(.primary.opacity(0.045), in: Capsule())
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
            }

            if showsSettingsPanel {
                Button { hideSettings() } label: {
                    PanelUtilityButtonLabel(symbol: "arrow.uturn.backward")
                }
                .buttonStyle(.plain)
                .help("Back")
                .accessibilityLabel("Back from settings")
            }

        }
        .frame(maxWidth: .infinity)
    }

    private func modeTab(_ title: String, isWork: Bool) -> some View {
        Button {
            selectMode(isWork: isWork)
        } label: {
            Text(title)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .font(MarrTypography.font(.body, weight: isWorkMode == isWork ? .semibold : .regular))
                .foregroundStyle(isWorkMode == isWork
                                 ? MarrPanelColors.primary(for: colorScheme)
                                 : MarrPanelColors.secondary(for: colorScheme))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background {
                    if isWorkMode == isWork {
                        modeSelectionGlass
                            .matchedGeometryEffect(id: "modeSelection", in: modeSelection)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(MarrButtonStyle(.ghost, size: .icon))
        .accessibilityLabel(title)
        .accessibilityIdentifier(isWork ? "marr.mode.work" : "marr.mode.conversation")
        .accessibilityValue(isWorkMode == isWork ? "Selected" : "Not selected")
        .onKeyPress(.leftArrow) { selectMode(isWork: false); return .handled }
        .onKeyPress(.rightArrow) { selectMode(isWork: true); return .handled }
    }

    func selectMode(isWork: Bool) {
        guard !session.hasLoadingTurn else { return }
        persistComposerDraft()
        if !isWork, session.workspaceID != nil || session.isDeleted {
            controller.startNewConversation()
            return
        }
        controller.cancelPendingHistoryLoad()
        withAnimation(MarrMotion.selection(reducesMotion: reducesMotion)) {
            usesCodex = false
            localWorkMode = isWork
            showsSettingsPanel = false
            showsCodexTaskBrowser = false
        }
        setQuestionFocus(true)
    }

    func selectCodexMode() {
        guard workSession.codexSyncEnabled else { return }
        controller.cancelPendingHistoryLoad()
        usesCodex = true
        localWorkMode = false
        showsSettingsPanel = false
        showsCodexTaskBrowser = false
        setQuestionFocus(true)
    }

    @ViewBuilder
    private var modeSelectionGlass: some View {
        if #available(macOS 26.0, *), usesGlassSurfaces, !reducesTransparency {
            Capsule().fill(.clear)
                .glassEffect(.regular.interactive(), in: Capsule())
        } else {
            Capsule().fill(.primary.opacity(0.10))
        }
    }

    private func navigateBack() {
        withAnimation(.easeOut(duration: 0.2)) {
            if navigation.section == .personalAgent { navigation.section = .chats }
            else if showsSettingsPanel { backFromSettings() }
            else if showsHistoryPanel { hideHistorySearch() }
            else if showsCodexTaskBrowser { showsCodexTaskBrowser = false }
        }
    }

    private var conversationHeader: some View {
        VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
            Color.clear.frame(height: MarrPanelShellLayout.toolbarHeight).accessibilityHidden(true)
            HStack(spacing: 8) {
                conversationTitleControl
                    .modifier(MarrConversationTitleScrollEffect(chrome: conversationScrollChrome))
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, MarrPanelShellLayout.toolbarTop)
        .padding(.bottom, 8)
        .frame(height: conversationHeaderHeight, alignment: .topLeading)
    }

    private var codexHeader: some View {
        VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
            Color.clear.frame(height: MarrPanelShellLayout.toolbarHeight).accessibilityHidden(true)
            if !showsCodexTaskBrowser {
                HStack(spacing: MarrUI.Spacing.tight) {
                    conversationTitleControl
                    chatActionsMenu
                    Button { showsChatDetails.toggle() } label: {
                        MarrIcon("list.bullet.rectangle")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color(white: colorScheme == .dark ? 0.82 : 0.35))
                    .help("Chat details")
                    .accessibilityLabel("Chat details")
                    .popover(isPresented: $showsChatDetails, arrowEdge: .bottom) {
                        CodexTaskDetailsView(workspace: workSession)
                            .frame(width: min(360, max(280, panelWidth - 60)))
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, MarrPanelShellLayout.toolbarTop)
        .padding(.bottom, 8)
        .frame(height: showsCodexTaskBrowser ? 48 : conversationHeaderHeight, alignment: .topLeading)
    }

    private var chatActionsMenu: some View {
        Menu {
            Button("Rename", marrSymbol: "pencil") { beginRenamingChat() }
                .disabled(!workSession.canRenameSelectedTask)
            if let task = workSession.workbench.selectedTask {
                Button(workSession.pinnedTaskIDs.contains(task.id) ? "Unpin chat" : "Pin chat", marrSymbol: "pin") {
                    workSession.toggleTaskPinned(task)
                }
            }
            Divider()
            Button("Fork chat", marrSymbol: "arrow.triangle.branch") { workSession.forkSelectedTask() }
                .disabled(!workSession.canForkSelectedTask)
            Menu("Copy", marrSymbol: "doc.on.doc") {
                Button("Chat") { copyChatValue(workSession.chatTranscript) }
                    .disabled(!workSession.activities.contains { $0.isComplete && ($0.kind == .user || $0.kind == .message) })
                Button("Thread ID") { copyChatValue(workSession.workbench.selectedTask?.threadID ?? "") }
                    .disabled(workSession.workbench.selectedTask?.threadID == nil)
                Button("Project path") { copyChatValue(workSession.workspaceURL?.path ?? "") }
                    .disabled(workSession.workspaceURL == nil)
            }
            if let project = workSession.workbench.selectedWorkspace {
                Button("Show project in Finder", marrSymbol: "folder") { workSession.showWorkspaceInFinder(project) }
            }
            Divider()
            Button("Archive chat", marrSymbol: "archivebox") {
                if let task = workSession.workbench.selectedTask { workSession.archiveTask(task) }
            }
            .disabled(workSession.workbench.selectedTask == nil || !workSession.canSubmit
                      || workSession.workbench.selectedTaskID.map { workSession.archivingTaskIDs.contains($0) } == true)
        } label: {
            MarrIcon("ellipsis").frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(Color(white: colorScheme == .dark ? 0.82 : 0.35))
        .help("Chat actions")
        .accessibilityLabel("Chat actions")
    }

    private var renameChatSheet: some View {
        VStack(alignment: .leading, spacing: MarrUI.Spacing.large) {
            Text("Rename chat").font(MarrTypography.font(.pageTitle))
            TextField("Chat title", text: $renamedChatTitle)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Chat title")
                .onSubmit { saveChatName() }
            HStack {
                Button("Cancel", role: .cancel) { showsRenameChat = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { saveChatName() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSaveChatName)
            }
        }
        .padding(20)
        .frame(width: 300)
    }

    private var canSaveChatName: Bool {
        renamingTaskID != nil && renamingTaskID == workSession.workbench.selectedTaskID
            && !renamedChatTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && workSession.canRenameSelectedTask
    }

    private func beginRenamingChat() {
        guard let task = workSession.workbench.selectedTask, workSession.canRenameSelectedTask else { return }
        renamingTaskID = task.id
        renamedChatTitle = task.title
        showsRenameChat = true
    }

    private func saveChatName() {
        guard canSaveChatName else { return }
        if workSession.renameSelectedTask(renamedChatTitle) { showsRenameChat = false }
    }

    private func copyChatValue(_ value: String) {
        guard !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private var codexContent: some View {
        WorkActivityTimeline(workspace: workSession)
            .frame(width: composerWidth)
            .frame(maxWidth: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded {
                if showsWorkCompletion { dismissedCompletion = workCompletionToken }
            })
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
    }

    private var codexTaskBrowser: some View {
        WorkspaceTaskBrowser(workspace: workSession) {
            withAnimation(.easeOut(duration: 0.16)) {
                showsCodexTaskBrowser = false
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private var conversationScroll: some View {
        GeometryReader { availableSpace in
            MarrFollowingScrollView(identity: session.id.uuidString) {
                VStack(spacing: 0) {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: ConversationScrollMinYPreferenceKey.self,
                            value: geometry.frame(in: .named("AnswerPanelConversationScroll")).minY
                        )
                    }
                    .frame(height: 0)

                    LazyVStack(alignment: .leading, spacing: MarrUI.Spacing.large) {
                        ForEach(session.turns) { turn in
                            turnView(turn, isCompact: false, showsUserMessage: true)
                                .id(turn.id)
                        }
                    }
                    .animation(MarrMotion.transition(reducesMotion: reducesMotion), value: session.turns.map(\.id))

                    Color.clear
                        .frame(height: AnswerPanelConversationLayout.bottomInset)
                }
                .padding(.top, 14)
                .frame(width: composerWidth, alignment: .topLeading)
                .frame(minHeight: availableSpace.size.height, alignment: .bottom)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .coordinateSpace(name: "AnswerPanelConversationScroll")
            .onPreferenceChange(ConversationScrollMinYPreferenceKey.self) { nextMinY in
                conversationScrollChrome.update(origin: nextMinY)
            }
        }
    }

    private var conversationTitleControl: some View {
        Button {
            if showsHistoryPanel { hideHistorySearch() }
            else { showHistorySearch() }
        } label: {
            HStack(spacing: MarrUI.Spacing.regular) {
                Rectangle()
                    .fill(.secondary.opacity(0.28))
                    .frame(width: 1, height: 20)

                Text(conversationDisplayTitle)
                    .font(MarrTypography.font(.title))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)
            }
            .foregroundStyle(MarrPanelColors.primary(for: colorScheme))
            .frame(width: usesCodex ? nil : composerWidth - 28, height: 30, alignment: .leading)
            .frame(maxWidth: usesCodex ? .infinity : nil, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            withAnimation(.easeOut(duration: 0.12)) {
                conversationTitleHovered = isHovering
            }
        }
        .help(showsHistoryPanel ? "Hide history sidebar" : "Show history sidebar")
    }

    private var conversationDisplayTitle: String {
        usesCodex ? workSession.activeTaskTitle : session.displayTitle
    }

    private func turnView(_ turn: ConversationTurn, isCompact: Bool, showsUserMessage: Bool) -> some View {
        VStack(spacing: MarrUI.Spacing.regular) {
            if showsUserMessage {
                HStack(alignment: .bottom) {
                    Spacer(minLength: 72)
                    VStack(alignment: .trailing, spacing: MarrUI.Spacing.tight) {
                        VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
                            turnScreenshotAttachments(turn)
                            UserMessageContent(source: turn.question)
                        }
                            .frame(maxWidth: turn.imageIDs.contains { session.images[$0]?.isImage == true }
                                ? MarrUserImagePreview.maximumWidth : nil, alignment: .leading)
                            .marrChatBubble()

                        questionActions(for: turn)
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .opacity
                ))
            }

            if turn.showsAssistant {
                assistantMessage(turn, isCompact: isCompact)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
                if turn.errorMessage != nil { errorMessage(turn) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func turnScreenshotAttachments(_ turn: ConversationTurn) -> some View {
        let attachments = turn.imageIDs.compactMap { session.images[$0] }
        if !attachments.isEmpty {
            VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
                ForEach(attachments) { asset in
                    if asset.isImage, let image = NSImage(data: asset.data) {
                        MarrAttachmentPreviewButton(attachment: asset, gallery: attachments) {
                            MarrUserImagePreview(image: image)
                        }
                    } else {
                        MarrAttachmentPreviewButton(attachment: asset, gallery: attachments) { fileAttachmentView(asset) }
                    }
                }
            }
        }
    }

    private func fileAttachmentView(_ asset: ConversationImageAsset) -> some View {
        HStack(spacing: MarrUI.Spacing.regular) {
            MarrIcon(AttachmentFileSupport.symbolName(for: asset.fileName), size: MarrUI.Icon.navigation)
                .foregroundStyle(selectedAccent.color)
                .frame(width: 30, height: 30)
                .background(selectedAccent.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: MarrUI.Spacing.tight) {
                Text(asset.fileName)
                    .font(MarrTypography.font(.body, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(
                    ByteCountFormatter.string(
                        fromByteCount: Int64(asset.data.count),
                        countStyle: .file
                    )
                )
                .font(MarrTypography.font(.secondary))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(width: 220)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 0.8)
                .allowsHitTesting(false)
        )
    }

    private func questionActions(for turn: ConversationTurn) -> some View {
        MarrMessageActions(text: turn.question, copyTitle: "Copy message",
                           onEdit: canEdit(turn) ? { beginEditing(turn) } : nil)
    }

    @ViewBuilder
    private func assistantMessage(_ turn: ConversationTurn, isCompact: Bool) -> some View {
        if !turn.answer.isEmpty {
            MarkdownResponseView(source: turn.answer)
                .textSelection(.enabled)
                .frame(width: composerWidth - 8, alignment: .leading)
                .padding(.vertical, 4)
            MarrMessageActions(text: turn.answer)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 4)
        }
        if turn.isLoading {
            HStack(spacing: MarrUI.Spacing.regular) {
                if let retryAt = turn.retryAt {
                    MarrIcon("clock").accessibilityHidden(true)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let seconds = max(0, Int(ceil(retryAt.timeIntervalSince(context.date))))
                        Text(seconds > 0 ? "Retrying in \(seconds)s…" : "Retrying…")
                            .monospacedDigit()
                    }
                } else {
                    MarrCompanion(phase: .responding, size: 28)
                    Text(turn.answer.isEmpty ? "Preparing a response…" : "Responding…")
                }
            }
            .font(MarrTypography.font(.secondary))
            .foregroundStyle(MarrPanelColors.secondary(for: colorScheme))
            .padding(.horizontal, 4)
            .padding(.vertical, 10)
            .transition(.opacity)
        }
    }

    private func errorMessage(_ turn: ConversationTurn) -> some View {
        VStack(spacing: MarrUI.Spacing.regular) {
            MarrCompanion(phase: .error, size: 36)
            Text(turn.errorMessage ?? "")
                .font(MarrTypography.font(.body, weight: .medium))
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Button("Retry") {
                retry(turn.id)
            }
            .controlSize(.small)
            .disabled(session.hasLoadingTurn)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var modelControlSummary: String {
        let name = workSession.selectedModelName
        guard !name.isEmpty else { return "Choose model" }
        guard !reasoningEfforts.isEmpty else { return name }
        return "\(name) · \(MarrReasoningOptions.label(workSession.selectedReasoningEffort))"
    }

    private var canChangeModel: Bool {
        !workSession.isRunning && !workSession.isRemoteTaskActive && !session.hasLoadingTurn
    }

    private var workModelPicker: some View {
        Button {
            workSession.refreshModelsIfNeeded()
            toggleComposerMenu(.workModel)
        } label: {
            MarrModelControlLabel(name: workSession.selectedModelName,
                                  effort: reasoningEfforts.isEmpty ? nil : workSession.selectedReasoningEffort,
                                  isExpanded: showsWorkModelPicker)
                .foregroundStyle(MarrPanelColors.secondary(for: colorScheme))
        }
        .buttonStyle(.plain)
        .composerControlAnchor(.workModel)
        .frame(maxWidth: min(280, max(80, composerWidth - (usesCodex ? 238 : 164))), alignment: .trailing)
        .layoutPriority(-1)
        .opacity(morphMenu == .workModel ? 0 : 1)
        .onAppear { workSession.refreshModelsIfNeeded() }
        .help("Model for the next message: \(modelControlSummary)")
        .accessibilityLabel("Model for the next message")
        .accessibilityValue(modelControlSummary)
    }

    private var reasoningEfforts: [String] {
        MarrReasoningOptions.ordered(workSession.availableReasoningEfforts)
    }

    private var chatGPTModelPicker: some View {
        let selected = controller.provider == .chatGPT ? controller.selectedChatGPTModel : nil
        let summary = selected?.displayName ?? (controller.model.isEmpty ? "Choose model" : controller.model)
        return Button {
            controller.refreshChatGPTAccount()
            toggleComposerMenu(.planModel)
        } label: {
            MarrModelControlLabel(name: summary,
                                  effort: controller.chatGPTReasoningEffort.isEmpty ? nil : controller.chatGPTReasoningEffort,
                                  fastMode: controller.chatGPTFastMode, isExpanded: showsChatGPTModelPicker)
                .foregroundStyle(MarrPanelColors.secondary(for: colorScheme))
        }
        .buttonStyle(.plain)
        .composerControlAnchor(.planModel)
        .frame(maxWidth: min(250, max(96, composerWidth - 136)), alignment: .trailing)
        .layoutPriority(-1)
        .opacity(morphMenu == .planModel ? 0 : 1)
        .onAppear { controller.refreshChatGPTAccount() }
        .help("Model for the next message: \(summary) · \(MarrReasoningOptions.label(controller.chatGPTReasoningEffort))")
        .accessibilityLabel("Model, reasoning and speed for the next message")
        .accessibilityValue("\(summary), \(MarrReasoningOptions.label(controller.chatGPTReasoningEffort)), \(controller.chatGPTFastMode ? "Fast" : "Standard")")
    }

    private var workModelMenu: some View {
        MarrComposerMenu(title: "Models", options: workSession.availableModels.map {
            AgentCompletionOption(id: $0.id, title: $0.name, detail: "", symbol: "square.stack", helpText: $0.description)
        }, selectedID: workSession.selectedModel, isEnabled: canChangeModel,
            emptyMessage: workSession.isLoadingModels ? "Loading models…" : "No models available",
            state: composerMenuState, onSelect: { option in
                if option.id != workSession.selectedModel { workSession.selectModel(option.id) }
                dismissComposerMenu()
            }, onDismiss: dismissComposerMenu) {
            Divider().padding(.horizontal, 12)
            MarrModelConfigurationPanel(models: workSession.availableModels,
                selectedModel: workSession.selectedModel, efforts: reasoningEfforts,
                effort: workSession.selectedReasoningEffort, includesAutomatic: false,
                isEnabled: canChangeModel, offersModelSelection: false,
                onSelectModel: workSession.selectModel, onSelectEffort: workSession.selectReasoningEffort)
            if let error = workSession.modelLoadError {
                Text(error).marrTextStyle(.secondary).foregroundStyle(.secondary).padding(12)
            }
            if usesCodex, let usage = workSession.activeTokenUsage {
                HStack {
                    Text("Context")
                    Spacer()
                    if let capacity = usage.contextWindow {
                        Text("\(usage.lastTotalTokens.formatted()) / \(capacity.formatted())")
                    } else { Text("\(usage.lastTotalTokens.formatted()) tokens") }
                }
                .marrTextStyle(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.bottom, 8)
                .help("Last request · \(usage.lastCachedInputTokens.formatted()) cached input tokens")
            }
        }
    }

    private var chatGPTModelMenu: some View {
        let selected = controller.provider == .chatGPT ? controller.selectedChatGPTModel : nil
        let options = controller.aiConnections.connections.filter(\.supportsConversation).flatMap { connection in
            connection.models.map { model in
                AgentCompletionOption(id: connection.id + "::" + model, title: model,
                    detail: "", symbol: "square.stack", helpText: connection.name,
                    providerIconName: connection.iconName,
                    providerTag: connection.kind == .chatGPT ? "OpenAI" : connection.preset?.title ?? "Custom")
            }
        }
        return MarrComposerMenu(title: "Models", options: options,
            selectedID: controller.aiConnections.conversation.connectionID + "::" + controller.model,
            isEnabled: canChangePlanModel, emptyMessage: "Add a connection and its models in AI & Models",
            state: composerMenuState, onSelect: { option in
                for connection in controller.aiConnections.connections {
                    if let model = connection.models.first(where: { connection.id + "::" + $0 == option.id }) {
                        controller.chooseAIModel(connectionID: connection.id, modelID: model)
                        break
                    }
                }
                dismissComposerMenu()
            }, onDismiss: dismissComposerMenu) {
            Button("Manage AI connections") {
                activeComposerMenu = nil
                settingsNavigation.open(.conversation)
                showSettings()
            }.buttonStyle(.link).padding(12)
            if controller.provider == .chatGPT, selected != nil {
                Divider().padding(.horizontal, 12)
                MarrModelConfigurationPanel(
                    models: controller.chatGPTModels.map { CodexModelOption(id: $0.slug, name: $0.displayName) },
                    selectedModel: controller.model,
                    efforts: selected?.reasoningEfforts ?? [], effort: controller.chatGPTReasoningEffort,
                    fastMode: controller.chatGPTFastMode, supportsFastMode: selected?.supportsFastMode == true,
                    isEnabled: canChangePlanModel, offersModelSelection: false,
                    onSelectModel: controller.selectChatGPTModel,
                    onSelectEffort: { controller.chatGPTReasoningEffort = $0 },
                    onToggleSpeed: { controller.chatGPTFastMode.toggle() })
            }
        }
    }

    private var composerModeMenu: some View {
        VStack(spacing: 2) {
            ForEach([("plan", "Plan", "lightbulb"), ("default", "Work", "hammer")], id: \.0) { mode in
                Button {
                    if mode.0 != currentComposerMode { _ = dispatchWorkCommand(mode.0 == "plan" ? "/plan" : "/default") }
                    dismissComposerMenu()
                } label: {
                    HStack(spacing: 8) {
                        MarrIcon(mode.2, size: MarrUI.Icon.inline)
                        Text(mode.1).marrTextStyle(.body)
                        Spacer()
                        MarrIcon("checkmark", size: MarrUI.Icon.status)
                            .opacity(mode.0 == currentComposerMode ? 1 : 0)
                    }
                    .padding(.horizontal, 6).frame(height: 32).contentShape(Rectangle())
                }
                .buttonStyle(MarrButtonStyle(.ghost, size: .icon)).disabled(!canChangeModel)
                .accessibilityAddTraits(mode.0 == currentComposerMode ? .isSelected : [])
            }
        }
        .padding(6).onExitCommand(perform: dismissComposerMenu)
    }

    private var composerAddMenu: some View {
        MarrComposerMenu(title: "Add context", options: composerAddOptions,
            state: composerMenuState, onSelect: chooseComposerAddition, onDismiss: dismissComposerMenu) { EmptyView() }


    }

    private var canChangePlanModel: Bool {
        !session.hasLoadingTurn && controller.activeInferenceRequests == 0 && !controller.chatGPTBusy
    }

    private var composer: some View {
        composerInput.frame(width: composerWidth)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: MarrComposerBounds.self,
                        value: geometry.frame(in: .named("answer-panel")))
                }
            }
    }

    private var composerMenuAnimation: Animation? {
        reducesMotion ? nil : .spring(response: 0.3, dampingFraction: 0.88)
    }

    private func animateComposerMenu(_ menu: MarrComposerMenuKind?) {
        let transitionID = UUID()
        menuTransitionID = transitionID
        if let menu {
            let wasClosed = morphMenu == nil
            withAnimation(wasClosed ? nil : composerMenuAnimation) {
                morphMenu = menu
                measuredMenuHeight = 0
            }
            // Mount at the real control bounds before starting the reveal.
            // A newer action invalidates this work, including a rapid dismissal.
            Task { @MainActor in
                await Task.yield()
                guard menuTransitionID == transitionID, activeComposerMenu == menu else { return }
                withAnimation(composerMenuAnimation) { menuExpansion = 1 }
            }
        } else {
            withAnimation(reducesMotion ? nil : .easeOut(duration: 0.16), completionCriteria: .removed) {
                menuExpansion = 0
            } completion: {
                guard menuTransitionID == transitionID, activeComposerMenu == nil else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    morphMenu = nil
                    measuredMenuHeight = 0
                }
                restoreComposerFocus()
            }
        }
    }

    @ViewBuilder
    private func composerMenuOverlay(in size: CGSize) -> some View {
        if let menu = morphMenu, let source = composerControlFrames[menu] {
            let destination = composerMenuDestination(menu, source: source, canvas: size)
            if activeComposerMenu != nil {
                MarrComposerMenuBackdrop(menuFrame: destination,
                    passthroughFrame: isModelMenuActive ? composerSendBounds : .zero,
                    onClick: handleComposerMenuBackdrop)
                    .frame(width: size.width, height: size.height)
                    .accessibilityHidden(true)
                    .zIndex(50)
            }
            MarrComposerMorphSurface(progress: menuExpansion, source: source, destination: destination,
                isInteractive: activeComposerMenu != nil, isClear: menu == .workModel || menu == .planModel) {
                composerMenuCompactLabel(menu)
            } content: {
                composerMenuContent(menu)
                    .frame(width: destination.width)
                    .fixedSize(horizontal: false, vertical: true)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: MarrComposerMenuHeight.self, value: geometry.size.height)
                        }
                    }
            }
            .onExitCommand(perform: dismissComposerMenu)
            .zIndex(100)
        }
    }

    private func composerMenuDestination(_ menu: MarrComposerMenuKind, source: CGRect, canvas: CGSize) -> CGRect {
        let height = measuredMenuHeight > 0 ? measuredMenuHeight : menu == .mode ? 80 : 240
        let width: CGFloat = menu == .mode ? 160 : menu == .attachments ? 256 : 240
        let isModel = menu == .workModel || menu == .planModel
        // Grow up and left from the model's trailing edge. The send control
        // and the gap beside it remain outside every interpolated frame.
        let leading = composerBounds.isEmpty ? CGFloat(12) : composerBounds.minX
        let trailing = isModel ? source.maxX : (composerBounds.isEmpty ? canvas.width - 12 : composerBounds.maxX)
        return MarrComposerMorphLayout.destination(source: source, canvas: canvas,
            preferred: CGSize(width: width, height: height), horizontalBounds: leading...max(leading, trailing))
    }

    @ViewBuilder
    private func composerMenuContent(_ menu: MarrComposerMenuKind) -> some View {
        switch menu {
        case .workModel: workModelMenu
        case .planModel: chatGPTModelMenu
        case .mode: composerModeMenu
        case .attachments: composerAddMenu
        }
    }

    @ViewBuilder
    private func composerMenuCompactLabel(_ menu: MarrComposerMenuKind) -> some View {
        switch menu {
        case .workModel:
            MarrModelControlLabel(name: workSession.selectedModelName,
                effort: reasoningEfforts.isEmpty ? nil : workSession.selectedReasoningEffort)
                .foregroundStyle(MarrPanelColors.secondary(for: colorScheme))
        case .planModel:
            MarrModelControlLabel(name: (controller.provider == .chatGPT ? controller.selectedChatGPTModel?.displayName : nil)
                    ?? (controller.model.isEmpty ? "Choose model" : controller.model),
                effort: controller.chatGPTReasoningEffort.isEmpty ? nil : controller.chatGPTReasoningEffort,
                fastMode: controller.chatGPTFastMode)
                .foregroundStyle(MarrPanelColors.secondary(for: colorScheme))
        case .mode:
            HStack(spacing: 4) {
                MarrIcon(currentComposerMode == "plan" ? "lightbulb" : "hammer", size: MarrUI.Icon.status)
                Text(currentComposerMode == "plan" ? "Plan" : "Work").marrTextStyle(.secondary)
                MarrIcon("chevron.down", size: MarrUI.Icon.disclosure)
            }.padding(.horizontal, 8)
        case .attachments:
            HStack(spacing: 6) {
                MarrIcon("plus", size: MarrUI.Icon.toolbar).frame(width: 28, height: 28)
                Text("Attach files").marrTextStyle(.secondary)
            }
        }
    }

    private func handleComposerMenuBackdrop(_ point: CGPoint) {
        if let other = composerControlFrames.first(where: { $0.key != activeComposerMenu && $0.value.contains(point) })?.key {
            switch other {
            case .attachments:
                dismissComposerMenu()
                withAnimation(composerMenuAnimation) { attachmentActionsExpanded = true }
            case .mode:
                if canChangeModel { setComposerMenu(.mode) }
            case .workModel:
                workSession.refreshModelsIfNeeded()
                setComposerMenu(.workModel)
            case .planModel:
                controller.refreshChatGPTAccount()
                setComposerMenu(.planModel)
            }
        } else { dismissComposerMenu() }
    }

    private func setComposerMenu(_ menu: MarrComposerMenuKind?) {
        if menu != activeComposerMenu { composerMenuState.reset() }
        activeComposerMenu = menu
        if let menu {
            if menu != .attachments {
                withAnimation(composerMenuAnimation) { attachmentActionsExpanded = false }
            }
            dismissedCompletion = workCompletionToken
            setQuestionFocus(false)
        }
    }

    private func toggleComposerMenu(_ menu: MarrComposerMenuKind) {
        if activeComposerMenu == menu { dismissComposerMenu() }
        else { setComposerMenu(menu) }
    }

    func dismissComposerMenu() {
        activeComposerMenu = nil
        if morphMenu == nil { restoreComposerFocus() }
    }

    private func restoreComposerFocus() {
        DispatchQueue.main.async {
            guard activeComposerMenu == nil, !showsSettingsPanel, !showsGoalEditor,
                  !showsCodexTaskBrowser, !showsHistoryPanel else { return }
            setQuestionFocus(true)
        }
    }

    private var currentComposerMode: String {
        workSession.collaborationModes.first { $0.id == workSession.selectedCollaborationModeID }?.mode ?? "default"
    }

    private var composerModePicker: some View {
        let mode = currentComposerMode
        let planning = mode == "plan"
        return Button { toggleComposerMenu(.mode) } label: {
            HStack(spacing: 4) {
                MarrIcon(planning ? "lightbulb" : "hammer", size: MarrUI.Icon.status).accessibilityHidden(true)
                if !attachmentActionsExpanded {
                    Text(planning ? "Plan" : "Work").marrTextStyle(.secondary, weight: .medium)
                }
                MarrIcon("chevron.down", size: MarrUI.Icon.disclosure)
                    .rotationEffect(.degrees(activeComposerMenu == .mode ? 180 : 0)).accessibilityHidden(true)
            }
            .padding(.horizontal, 8).frame(height: 28)
            .background(.primary.opacity(activeComposerMenu == .mode ? 0.08 : 0.035),
                        in: RoundedRectangle(cornerRadius: MarrUI.Radius.control))
        }
        .buttonStyle(.plain)
        .foregroundStyle(MarrPanelColors.primary(for: colorScheme))
        .disabled(!canChangeModel)
        .animation(MarrMotion.transition(reducesMotion: reducesMotion), value: activeComposerMenu == .mode)
        .composerControlAnchor(.mode)
        .opacity(morphMenu == .mode ? 0 : 1)
        .help("Working mode: \(planning ? "Plan" : "Work")")
        .accessibilityLabel("Working mode")
        .accessibilityValue(planning ? "Plan" : "Work")
    }

    private var composerAddOptions: [AgentCompletionOption] {
        var options: [AgentCompletionOption] = [
            .init(id: "attachments", title: "Attach files", detail: "Images, documents and code", symbol: "paperclip")
        ]
        if usesCodex {
            options += [
                .init(id: "context", title: "Workspace context", detail: "Files, folders and connected tools", symbol: "at", showsDisclosure: true),
                .init(id: "skills", title: "Skills", detail: "Choose a skill for this request", symbol: "sparkles", showsDisclosure: true),
                .init(id: "goal", title: "Goal", detail: "Set a goal to keep pursuing", symbol: "target",
                      enabled: canChangeModel),
                .init(id: "tools", title: "Manage tools", detail: "Manage connected plugins", symbol: "puzzlepiece.extension", showsDisclosure: true)
            ]
        }
        return options
    }

    private func chooseComposerAddition(_ option: AgentCompletionOption) {
        guard editingTurnID == nil else { return }
        activeComposerMenu = nil
        switch option.id {
        case "attachments": showAttachmentPicker()
        case "context": insertComposerTrigger("@")
        case "skills": insertComposerTrigger("$")
        case "goal": _ = dispatchWorkCommand("/goal")
        case "tools": _ = dispatchWorkCommand("/plugins")
        default: break
        }
    }

    private func insertComposerTrigger(_ trigger: String) {
        let draft = question as NSString
        let location = min(max(0, composerSelection.location), draft.length)
        let length = min(max(0, composerSelection.length), draft.length - location)
        let prefix = draft.substring(to: location)
        let suffix = draft.substring(from: location + length)
        let insertion = (prefix.last.map { $0.isWhitespace ? "" : " " } ?? "") + trigger
        let separator = suffix.first.map { $0.isWhitespace ? "" : " " } ?? ""
        question = draft.replacingCharacters(in: NSRange(location: location, length: length), with: insertion + separator)
        composerSelection = NSRange(location: location + insertion.utf16.count, length: 0)
        dismissedCompletion = nil
        setQuestionFocus(true)
    }

    private var attachmentButton: some View {
        MarrComposerAttachmentEntry(expanded: $attachmentActionsExpanded, offersContext: usesCodex,
            isEnabled: editingTurnID == nil, onAttach: {
                attachmentActionsExpanded = false
                showAttachmentPicker()
            }, onContext: { toggleComposerMenu(.attachments) })
            .composerControlAnchor(.attachments)
            .opacity(morphMenu == .attachments ? 0 : 1)
    }

    private var composerInput: some View {
        VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
            HStack(alignment: .top, spacing: MarrUI.Spacing.regular) {
                if editingTurnID != nil {
                    MarrIcon("pencil")
                        .foregroundStyle(.secondary)
                        .padding(.top, 7)
                        .accessibilityHidden(true)
                }
                if usesCodex {
                    AgentComposerEditor(text: $question, selection: $composerSelection,
                        focused: $workEditorFocused,
                        placeholder: workSession.isRunning ? "Add an instruction" : "Ask Codex",
                        onKey: handleComposerKey, onSubmit: sendCurrentQuestion,
                        onFileDrop: receiveAttachmentFiles,
                        onFileDragTargetChanged: { isAttachmentDropTargeted = $0 })
                        .help("Type / for commands, @ for workspace files, and $ for skills")
                } else {
                    TextField(
                        editingTurnID == nil
                            ? (showsComposerLanding ? (localWorkMode ? "What would you like to work on?" : "How can I help you today?") : "Ask a follow-up")
                            : "Edit latest message",
                        text: $question,
                        axis: .vertical
                    )
                    .marrChatInput()
                    .focused($questionFocused)
                    .accessibilityLabel(editingTurnID == nil ? "Message" : "Edit latest message")
                    .onSubmit {
                        sendCurrentQuestion()
                    }
                    .onKeyPress(.upArrow) {
                        moveSlashCommandSelection(by: -1)
                    }
                    .onKeyPress(.downArrow) {
                        moveSlashCommandSelection(by: 1)
                    }
                    .onKeyPress(.return) {
                        selectHighlightedSlashCommand()
                    }
                    .onKeyPress(.escape) {
                        dismissSlashCommandMenu()
                    }
                }
            }
            .padding(.horizontal, 4)
            .frame(minHeight: showsComposerLanding ? MarrChatLayout.landingEditorHeight(in: composerWidth) : 30, alignment: .topLeading)

            HStack(spacing: MarrUI.Spacing.small) {
                attachmentButton
                if usesCodex { composerModePicker }
                Spacer(minLength: MarrUI.Spacing.regular)
                if usesCodex || (controller.usesCodexForConversation && session.workspaceID == nil) {
                    workModelPicker
                } else {
                    chatGPTModelPicker
                }
                if editingTurnID != nil {
                    Button {
                        cancelEditing()
                    } label: {
                        MarrIcon("xmark", size: MarrUI.Icon.status)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Cancel editing")
                    .accessibilityLabel("Cancel editing")
                }
                // Retain the send shortcut and editor while the primary action
                // changes in place. A steerable draft also keeps Stop available.
                ZStack {
                    Button {
                        if isModelMenuActive { dismissComposerMenu() }
                        sendCurrentQuestion()
                    } label: {
                        MarrIcon("arrow.up", size: MarrUI.Icon.inline).frame(width: 28, height: 28)
                    }
                    .marrChatSendButton(isEnabled: canSend)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!canSend || (activeComposerMenu != nil && !isModelMenuActive))
                    .opacity(composerIsRunning && !canSend ? 0 : 1)
                    .allowsHitTesting(!(composerIsRunning && !canSend))
                    .accessibilityHidden(composerIsRunning && !canSend)
                    .help(usesCodex && workSession.isRunning ? "Send instruction" : "Send message")
                    .accessibilityLabel(usesCodex && workSession.isRunning ? "Send instruction" : "Send message")
                    if composerIsRunning && !canSend { composerStopButton }
                }
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: MarrComposerSendBounds.self,
                            value: geometry.frame(in: .named("answer-panel")))
                    }
                }
                .animation(MarrMotion.transition(reducesMotion: reducesMotion), value: composerIsRunning && !canSend)
                if composerIsRunning && canSend { composerStopButton }

            }
        }
        .padding(showsComposerLanding ? MarrChatLayout.landingInputPadding : MarrChatLayout.inputPadding)
        .frame(width: composerWidth)
    }

    private var composerIsRunning: Bool { usesCodex ? workSession.isRunning : session.hasLoadingTurn }

    private var composerStopButton: some View {
        MarrChatStopButton {
            if usesCodex { workSession.interrupt() }
            else { requestCoordinator.cancel() }
        }
    }

    private func showAttachmentPicker() {
        persistComposerDraft()
        let destination = currentComposerDraftKey
        AttachmentFilePicker.present { urls in
            guard let urls else { setQuestionFocus(true); return }
            addAttachmentFiles(urls, to: destination)
        }
    }

    private var canAcceptAttachments: Bool {
        navigation.section == .chats && !showsSettingsPanel && !showsCodexTaskBrowser
            && !showsGoalEditor && !showsRenameChat && editingTurnID == nil && (!session.isDeleted || usesCodex)
    }

    private func receiveAttachmentFiles(_ urls: [URL]) -> Bool {
        guard canAcceptAttachments, !urls.isEmpty else { return false }
        activeComposerMenu = nil
        attachmentActionsExpanded = false
        addAttachmentFiles(urls, to: currentComposerDraftKey)
        return true
    }

    private func addAttachmentFiles(_ urls: [URL], to destination: ComposerDraftKey, errors: [String] = []) {
        if let id = destination.conversationID, historyStore.deletedConversationIDs.contains(id) { return }
        if loadedDraftKey == destination { persistComposerDraft() }
        var draft = composerDraftStore.draft(for: destination)
        let imported = AttachmentFileImporter.append(urls, to: draft.attachments)
        draft.attachments = imported.attachments
        let failures = errors + imported.errors
        if !failures.isEmpty { attachmentErrorMessage = failures.joined(separator: "\n") }
        composerDraftStore.save(draft, for: destination)
        if loadedDraftKey == destination {
            loadComposerDraft(for: destination)
            setQuestionFocus(true)
        }
    }

    var workCompletionToken: AgentComposerToken? {
        guard usesCodex, composerSelection.length == 0 else { return nil }
        return AgentComposerCompletion.token(in: question, caretUTF16: composerSelection.location)
    }

    var showsWorkCompletion: Bool {
        guard usesCodex, workEditorFocused, !showsSettingsPanel, !showsCodexTaskBrowser,
              activeComposerMenu == nil, !showsGoalEditor, let token = workCompletionToken else { return false }
        return token != dismissedCompletion
    }

    private var workCompletionCandidates: [AgentComposerCandidate] {
        guard let token = workCompletionToken else { return [] }
        let skills = workSession.skills.filter(\.enabled).map { skill in
            var candidate = AgentComposerCandidate.skill(name: skill.name, path: skill.path, description: skill.shortDescription)
            candidate.searchTerms += [skill.displayName, skill.description]
            return candidate
        }
        let files = workSession.fileSearchResults.map {
            AgentComposerCandidate.file(path: $0.path, displayPath: $0.displayPath)
        }
        let commands = AgentComposerCatalog.commands.filter(\.isSupported)
        if token.kind == .slash {
            let all = AgentComposerToken(kind: .slash, query: "", replacementRange: token.replacementRange, originalText: token.originalText)
            let candidates = AgentComposerCompletion.candidates(for: all, commands: commands,
                isRunning: workSession.isRunning || workSession.isRemoteTaskActive, limit: 80).map { candidate in
                    var result = candidate
                    result.searchTerms += [AgentCompletionOption.command(candidate).title, candidate.detail]
                    return result
                }
            return AgentComposerCompletion.rankedCandidates(query: token.query, candidates: candidates, limit: 80)
        }
        return AgentComposerCompletion.candidates(for: token, commands: commands, skills: skills, files: files,
            isRunning: workSession.isRunning || workSession.isRemoteTaskActive, limit: token.kind == .slash ? 80 : 40)
    }

    private var workCompletionOptions: [AgentCompletionOption] {
        guard let token = workCompletionToken else { return [] }
        if token.kind == .slash { return workCompletionCandidates.map(AgentCompletionOption.command) }
        if token.kind == .skill {
            return workCompletionCandidates.compactMap { candidate in
                workSession.skills.first(where: { $0.path == candidate.id }).map(AgentCompletionOption.skill)
            }
        }
        let query = token.query
        let actions: [AgentCompletionOption] = [
            .init(id: "add:files", title: "Files and folders", detail: "", symbol: "paperclip", section: "Add"),
            .init(id: "add:goal", title: "Goal", detail: "Set a goal to keep pursuing", symbol: "target", section: "Add"),
            .init(id: "add:plan", title: "Plan mode", detail: "Plan before making changes", symbol: "lightbulb",
                  enabled: !(workSession.isRunning || workSession.isRemoteTaskActive), section: "Add")
        ].filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
        var names = Set<String>()
        let extensions = workSession.extensions.filter { $0.mentionPath != nil }
            .sorted { $0.kind == $1.kind ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.kind == "Plugin" }
            .filter { names.insert($0.name.lowercased()).inserted }
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.detail.localizedCaseInsensitiveContains(query) }
            .map { entry in
                AgentCompletionOption(id: entry.id, title: entry.name, detail: AgentCompletionOption.summary(entry.detail),
                    symbol: entry.kind == "Plugin" ? "puzzlepiece.extension" : "square.grid.2x2", section: "Plugins")
            }
        let files = (pendingFileQuery != nil ? [] : workCompletionCandidates).map { candidate in
            AgentCompletionOption(id: candidate.id, title: (candidate.label as NSString).lastPathComponent,
                detail: (candidate.label as NSString).deletingLastPathComponent, symbol: "doc.text", section: "Files",
                helpText: candidate.id)
        }
        return actions + extensions + files
    }

    private var workCompletionPanel: some View {
        let token = workCompletionToken
        let loading = token?.kind == .file ? (pendingFileQuery != nil || workSession.isSearchingFiles || workSession.loadingCapabilityMethods.contains("plugin/list"))
            : token?.kind == .skill && workSession.loadingCapabilityMethods.contains("skills/list")
        let empty: String
        if token?.kind == .file {
            empty = workSession.fileSearchError ?? "No matching files or plugins"
        } else if token?.kind == .skill {
            empty = workSession.capabilityErrors["skills/list"] ?? "No matching skills. Manage skills in Settings → Work."
        } else { empty = "No matching commands. /help lists command support." }
        return AgentCompletionPanel(title: token?.kind == .slash ? "Commands" : token?.kind == .skill ? "Skills" : "Add context",
            options: workCompletionOptions, selectedIndex: $selectedSlashCommandIndex,
            isLoading: loading, emptyMessage: empty, maxHeight: completionAvailableHeight,
            onSelect: { chooseWorkOption($0, executeCommand: true) })
            .frame(width: composerWidth)
    }

    private func handleComposerKey(_ key: AgentComposerKey) -> Bool {
        guard showsWorkCompletion else {
            if case .dismiss = key { handleEscape(); return true }
            return false
        }
        let options = workCompletionOptions
        switch key {
        case .dismiss: dismissedCompletion = workCompletionToken
        case .up, .down:
            selectedSlashCommandIndex = AgentCompletionLayout.nextIndex(from: selectedSlashCommandIndex,
                by: key == .up ? -1 : 1, options: options)
        case .accept, .complete:
            // Loading/empty menus still own Return: never send a partial mention.
            guard options.indices.contains(selectedSlashCommandIndex) else { return true }
            let option = options[selectedSlashCommandIndex]
            if option.enabled { chooseWorkOption(option, executeCommand: key == .accept) }
        }
        return true
    }

    private func chooseWorkOption(_ option: AgentCompletionOption, executeCommand: Bool) {
        guard option.enabled, let token = workCompletionToken else { return }
        if option.id == "add:files" {
            dismissedCompletion = token
            showWorkMentionPicker(token: token)
        } else if option.id == "add:goal" || option.id == "add:plan" {
            if dispatchWorkCommand(option.id == "add:goal" ? "/goal" : "/plan"),
               let range = Range(token.replacementRange, in: question) {
                question.removeSubrange(range)
                composerSelection = NSRange(location: token.replacementRange.location, length: 0)
            }
        } else if let entry = workSession.extensions.first(where: { $0.id == option.id }),
                  let reference = workSession.bindExtensionMention(entry),
                  let edit = AgentComposerCompletion.replacing(token: token, in: question,
                      with: AgentComposerCandidate.file(path: reference, displayPath: reference).insertion) {
            question = edit.text
            composerSelection = NSRange(location: edit.caretUTF16, length: 0)
            dismissedCompletion = nil
            setQuestionFocus(true)
        } else if let candidate = workCompletionCandidates.first(where: { $0.id == option.id }) {
            chooseWorkCompletion(candidate, executeCommand: executeCommand)
        }
    }

    private func showWorkMentionPicker(token: AgentComposerToken) {
        persistComposerDraft()
        let destination = currentComposerDraftKey
        let panel = NSOpenPanel()
        panel.title = "Add files and folders"
        panel.prompt = "Add"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = workSession.workspaceURL
        let parent = (NSApp.keyWindow as? AnswerPanelWindow)
            ?? NSApp.orderedWindows.first { $0 is AnswerPanelWindow && $0.isVisible }
        setQuestionFocus(false)
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK {
                let insertion = panel.urls.map { AgentComposerCandidate.file(path: $0.path).insertion }.joined(separator: " ")
                var draft = composerDraftStore.draft(for: destination)
                if let edit = AgentComposerCompletion.replacing(token: token, in: draft.text, with: insertion) {
                    draft.text = edit.text
                    draft.selection = NSRange(location: edit.caretUTF16, length: 0)
                    for url in panel.urls {
                        let binding = ComposerMentionBinding(kind: .file, name: url.lastPathComponent,
                                                             path: url.path, reference: url.path)
                        if !draft.bindings.contains(where: { $0.id == binding.id }) { draft.bindings.append(binding) }
                    }
                    composerDraftStore.save(draft, for: destination)
                    if loadedDraftKey == destination {
                        workSession.reloadComposerBindings()
                        loadComposerDraft(for: destination)
                    }
                }
            }
            setQuestionFocus(true)
        }
        if let parent {
            panel.beginSheetModal(for: parent, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private func chooseWorkCompletion(_ candidate: AgentComposerCandidate, executeCommand: Bool = false) {
        guard candidate.isEnabled, let token = workCompletionToken,
              let edit = AgentComposerCompletion.replacing(token: token, in: question, with: candidate.insertion) else { return }
        if candidate.kind == .skill, let skill = workSession.skills.first(where: { $0.path == candidate.id }) {
            workSession.bindSkillMention(skill)
        } else if candidate.kind == .file { workSession.bindFileMention(path: candidate.id) }
        question = edit.text
        composerSelection = NSRange(location: edit.caretUTF16, length: 0)
        dismissedCompletion = nil
        selectedSlashCommandIndex = 0
        setQuestionFocus(true)
        if executeCommand, candidate.kind == .slash {
            let hasArgument = edit.text.split(maxSplits: 1, whereSeparator: \.isWhitespace).count > 1
            if candidate.id == "rename", !hasArgument { return }
            if dispatchWorkCommand(edit.text) { finishAcceptedWorkCommand() }
        }
    }

    func setComposerText(_ text: String) {
        question = text
        composerSelection = NSRange(location: text.utf16.count, length: 0)
        dismissedCompletion = nil
    }

    func finishAcceptedWorkCommand() {
        setComposerText("")
        persistComposerDraft()
        if loadedDraftKey != workSession.composerDraftKey {
            loadComposerDraft(for: workSession.composerDraftKey)
        }
    }

    private func restoreComposerMode(isWork: Bool) {
        switchComposerDraft(to: isWork ? workSession.composerDraftKey : .conversation(session.id))
    }

    private var currentComposerDraftKey: ComposerDraftKey {
        usesCodex ? workSession.composerDraftKey : .conversation(session.id)
    }

    private func removeContextBinding(_ binding: ComposerMentionBinding) {
        let text = NSMutableString(string: question)
        for range in binding.ranges(in: question, workspaceURL: workSession.workspaceURL).reversed() {
            text.replaceCharacters(in: range, with: "")
        }
        workSession.removeComposerBinding(binding.id)
        setComposerText(text as String)
        persistComposerDraft()
    }

    func persistComposerDraft() {
        guard let key = loadedDraftKey else { return }
        if let id = key.conversationID, historyStore.deletedConversationIDs.contains(id) { return }
        var draft = composerDraftStore.draft(for: key)
        draft.text = question
        draft.selection = composerSelection
        draft.editingTurnID = key.isWork ? nil : editingTurnID
        if key.isWork {
            draft.attachments = workAttachments
            if key == workSession.composerDraftKey { draft.bindings = workSession.composerBindings }
        } else if key.conversationID == session.id {
            draft.attachments = session.pendingImageIDs.compactMap { session.images[$0] }
        }
        if key.conversationID == session.id, !draft.isEmpty { session.persistDraftIdentityIfNeeded() }
        composerDraftStore.save(draft, for: key)
    }

    private func switchComposerDraft(to key: ComposerDraftKey) {
        guard loadedDraftKey != key else { return }
        persistComposerDraft()
        loadComposerDraft(for: key)
    }

    func loadComposerDraft(for key: ComposerDraftKey) {
        var incoming = composerDraftStore.draft(for: key)
        if !key.isWork {
            let pending = session.pendingImageIDs.compactMap { session.images[$0] }
            let known = Set(incoming.attachments.map(\.id))
            incoming.attachments.append(contentsOf: pending.filter { !known.contains($0.id) })
        }
        loadedDraftKey = key
        question = incoming.text
        composerSelection = incoming.selection
        editingTurnID = !key.isWork && incoming.editingTurnID == session.latestEditableTurnID
            ? incoming.editingTurnID : nil
        if key.isWork { workAttachments = incoming.attachments }
        else { session.replacePendingAttachments(incoming.attachments) }
        dismissedCompletion = nil
        dismissedSlashMenuInput = nil
        selectedSlashCommandIndex = 0
        persistComposerDraft()
    }

    private func recoveryDestination(_ draft: CodexSubmissionDraft) -> String {
        let project = workSession.workbench.workspaces.first { $0.id == draft.workspaceID }?.name ?? "Unavailable project"
        let task = workSession.workbench.tasks.first {
            $0.id == draft.taskID || (draft.threadID != nil && $0.threadID == draft.threadID)
        }?.title ?? "New task"
        return "\(project) · \(task)"
    }

    func setQuestionFocus(_ focused: Bool) {
        questionFocused = focused && navigation.section == .chats && !usesCodex
        workEditorFocused = focused && navigation.section == .chats && usesCodex
    }

    private func dismissWorkModelPicker() { dismissComposerMenu() }

    /// Commands are client actions. Never leak an unknown or unsupported command
    /// into a model request as if it had been handled by the terminal frontend.
    func dispatchWorkCommand(_ input: String) -> Bool {
        let parts = input.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let name = parts.first, let command = AgentComposerCatalog.command(named: String(name)) else {
            commandFeedback = "Unknown command. Type / to browse commands, or /help to see support details."
            return false
        }
        guard command.isSupported else {
            commandFeedback = "\(command.invocation) is not available in Marr yet. Your draft has been kept."
            return false
        }
        guard command.allowedWhileRunning || !(workSession.isRunning || workSession.isRemoteTaskActive) else {
            commandFeedback = "Wait for the current task to finish before using \(command.invocation)."
            return false
        }
        let argument = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        func noArguments() -> Bool {
            if argument.isEmpty { return true }
            commandFeedback = "Use \(command.invocation) without arguments in this client."
            return false
        }
        commandFeedback = nil
        switch command.name {
        case "goal" where argument.isEmpty || argument == "edit":
            _ = workSession.refreshThreadGoal()
            setQuestionFocus(false)
            showsGoalEditor = true
            return true
        case "model" where argument.isEmpty:
            workSession.refreshModelsIfNeeded()
            showsWorkModelPicker = true
            return true
        case "skills", "plugins", "apps", "mcp":
            if command.name == "mcp", !argument.isEmpty, argument != "verbose" {
                let accepted = workSession.executeSlashCommand(input)
                commandFeedback = workSession.commandOutput
                return accepted
            }
            guard command.name == "mcp" || noArguments() else { return false }
            let section: CodexCapabilitySection = command.name == "skills" ? .skills
                : command.name == "plugins" ? .plugins : command.name == "apps" ? .apps : .mcp
            settingsNavigation.openCapabilities(section)
            showSettings()
            return true
        case "config", "theme":
            guard noArguments() else { return false }
            settingsNavigation.open(command.name == "theme" ? .appearance : .advanced)
            showSettings()
            return true
        case "new", "clear":
            workSession.startNewTask(preservingComposerBindings: !argument.isEmpty)
            if !argument.isEmpty {
                let accepted = workSession.submit(prompt: argument, images: workAttachments)
                if accepted { workAttachments = [] }
                return accepted
            }
            commandFeedback = "New task ready."
            return true
        case "resume":
            guard noArguments() else { return false }
            showHistorySearch()
            workSession.loadAllTaskHistory()
            return true
        case "fork":
            guard noArguments(), workSession.workbench.selectedTask?.threadID != nil else {
                commandFeedback = "Select an existing task before forking it."
                return false
            }
            workSession.forkSelectedTask()
            return true
        case "archive":
            guard noArguments(), let task = workSession.workbench.selectedTask else { return false }
            workSession.archiveTask(task)
            return true
        case "mention":
            guard noArguments() else { return false }
            setComposerText("@")
            setQuestionFocus(true)
            return false // Keep the replacement in the editor.
        case "copy":
            guard noArguments() else { return false }
            guard !workSession.latestAgentMessage.isEmpty else { commandFeedback = "No reply to copy yet."; return false }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(workSession.latestAgentMessage, forType: .string)
            commandFeedback = "Last reply copied."
            return true
        case "export":
            guard noArguments() else { return false }
            exportWorkConversation()
            return true
        case "help":
            guard noArguments() else { return false }
            commandFeedback = "Use / for commands, @ for files, and $ for skills. Tab completes a command; Return runs it. File and skill selections are inserted into the message.\n\n"
                + AgentComposerCatalog.commands.filter(\.isSupported).map { "\($0.invocation) — \($0.summary)" }.joined(separator: "\n")
                + "\n\n/default is a Marr extension for leaving Plan mode. Commands not yet supported by Marr are shown as unavailable."
            return true
        default:
            let accepted = workSession.executeSlashCommand(input, images: workAttachments)
            if accepted, command.name == "plan", !argument.isEmpty { workAttachments = [] }
            if !workSession.commandOutput.isEmpty { commandFeedback = workSession.commandOutput }
            return accepted
        }
    }

    private func exportWorkConversation() {
        let content = workSession.activities.map { activity in
            "## \(activity.title)\n\n\(activity.detail)"
        }.joined(separator: "\n\n")
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Codex conversation.md"
        panel.allowedContentTypes = [.plainText]
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do { try content.write(to: url, atomically: true, encoding: .utf8) }
            catch { commandFeedback = "Could not export: \(error.localizedDescription)" }
        }
        if let parent = (NSApp.keyWindow as? AnswerPanelWindow)
            ?? NSApp.orderedWindows.first(where: { $0 is AnswerPanelWindow && $0.isVisible }) {
            panel.beginSheetModal(for: parent, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private var slashCommandMenu: some View {
        VStack(spacing: MarrUI.Spacing.tight) {
            ForEach(Array(slashCommandMatches.enumerated()), id: \.element.id) { index, command in
                Button {
                    chooseSlashCommand(command)
                } label: {
                    HStack(spacing: MarrUI.Spacing.regular) {
                        MarrIcon(command.symbol)
                            .font(MarrTypography.font(.body, weight: .semibold))
                            .foregroundStyle(selectedAccent.color)
                            .frame(width: 26, height: 26)
                            .background(selectedAccent.color.opacity(0.11), in: RoundedRectangle(cornerRadius: 7))

                        Text(command.invocation)
                            .font(MarrTypography.font(.codeControl, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 82, alignment: .leading)

                        Text(command.summary)
                            .font(MarrTypography.font(.body))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 40)
                    .background(
                        index == selectedSlashCommandIndex
                            ? selectedAccent.color.opacity(0.14)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isHovering in
                    if isHovering {
                        selectedSlashCommandIndex = index
                    }
                }
                .accessibilityLabel("\(command.invocation), \(command.summary)")
            }
        }
        .padding(6)
        .frame(width: composerWidth)
        .marrGlassSurface(cornerRadius: 16, isClear: true, tintOpacity: 0.06)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.20), lineWidth: 0.8)
                .allowsHitTesting(false)
        )
        .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 9)
    }

    private var slashCommandMatches: [ConversationSlashCommand] {
        ConversationSlashCommand.matching(question)
    }

    var showsSlashCommandMenu: Bool {
        !usesCodex && activeComposerMenu == nil && !slashCommandMatches.isEmpty && dismissedSlashMenuInput != question
    }

    private func moveSlashCommandSelection(by offset: Int) -> KeyPress.Result {
        guard showsSlashCommandMenu else { return .ignored }
        let count = slashCommandMatches.count
        selectedSlashCommandIndex = (selectedSlashCommandIndex + offset + count) % count
        return .handled
    }

    private func selectHighlightedSlashCommand() -> KeyPress.Result {
        guard showsSlashCommandMenu else { return .ignored }
        let index = min(selectedSlashCommandIndex, slashCommandMatches.count - 1)
        chooseSlashCommand(slashCommandMatches[index])
        return .handled
    }

    private func dismissSlashCommandMenu() -> KeyPress.Result {
        guard showsSlashCommandMenu else { return .ignored }
        dismissedSlashMenuInput = question
        return .handled
    }

    private func chooseSlashCommand(_ command: ConversationSlashCommand) {
        question = command.invocation + " "
        dismissedSlashMenuInput = nil
        setQuestionFocus(true)
    }

    private var canSend: Bool {
        let hasText = !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if usesCodex {
            if question.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") { return hasText }
            return (workSession.canSubmit || workSession.canSteer) && (hasText || !workAttachments.isEmpty)
        }
        return !session.hasLoadingTurn && hasText
    }

    private var bubbleTint: Color {
        selectedBubbleColor.color
    }

    private var bubbleForegroundColor: Color {
        selectedBubbleColor.foregroundColor
    }

    private var selectedBubbleColor: MarrBubbleColor {
        MarrBubbleColor.resolve(bubbleColor)
    }

    private var selectedAccent: MarrAccentColor {
        MarrAccentColor.resolve(accentColor)
    }
}
