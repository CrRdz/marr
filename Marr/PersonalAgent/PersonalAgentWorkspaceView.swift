import AppKit
import SwiftUI

struct PersonalAgentNavigationRail: View {
    @Binding var selection: MarrPanelSection
    @ObservedObject var coordinator: PersonalAgentCoordinator
    var accountName = "Marr"
    var accountDetail = "Settings and accounts"
    var accountInitial: String?
    var onOpenSettings: () -> Void = {}
    var onOpenAccount: () -> Void = {}
    var onSelect: (MarrPanelSection) -> Void = { _ in }
    var showsAccountMenu = false
    var onToggleAccountMenu: () -> Void = {}
    var body: some View {
        MarrNavigationRail(selection: $selection, agentUnreadCount: coordinator.unreadCount,
            accountName: accountName, accountDetail: accountDetail, accountInitial: accountInitial,
            onOpenSettings: onOpenSettings, onOpenAccount: onOpenAccount, onSelect: onSelect,
            showsAccountMenu: showsAccountMenu, onToggleAccountMenu: onToggleAccountMenu)
    }
}

struct PersonalAgentWorkspaceView: View {
    @ObservedObject var coordinator: PersonalAgentCoordinator
    @ObservedObject var runtime: RuntimeWorkspaceController
    @ObservedObject var navigation: AnswerPanelNavigation
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @State private var tab: Section = .agents
    @State private var selectedAgentID: UUID?
    @State private var editor: PersonalAgentEditor?
    @State private var onlyNeedsAttention = false
    @State private var showsHosting = false
    @State private var contactQuery = ""
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    enum Section: String, CaseIterable, Identifiable {
        case agents = "Agents", routines = "Routines", activity = "Activity", skills = "Skills"
        var id: String { rawValue }
    }
    private var selectedAgent: PersonalAgentProfile? { coordinator.archive.agents.first { $0.id == selectedAgentID } }

    init(coordinator: PersonalAgentCoordinator, runtime: RuntimeWorkspaceController,
         section: Section? = nil, selectedAgentID: UUID? = nil, navigation: AnswerPanelNavigation? = nil) {
        self.coordinator = coordinator; self.runtime = runtime
        self.navigation = navigation ?? AnswerPanelNavigation(initialDestination: nil, sidebar: nil, workspaceIDs: [])
        _tab = State(initialValue: section ?? Section(rawValue: coordinator.savedSection) ?? .agents)
        _selectedAgentID = State(initialValue: selectedAgentID ?? coordinator.savedSelectedAgentID)
    }

    var body: some View {
        AnswerPanelSidebarMotionSurface(
            revealWidth: navigation.sidebarRevealWidth,
            isExpanded: navigation.isHistoryExpanded,
            canvasWidth: navigation.sidebarCanvasWidth.map { max(0, $0 - MarrPanelShellLayout.railWidth) },
            windowMotion: MarrPanelShellLayout.contentMotion(navigation.sidebarWindowMotion),
            animates: navigation.animatesSidebar && !reducesMotion,
            sidebar: agentSidebar
                .padding(.leading, 8).padding(.trailing, 4)
                .padding(.top, MarrPanelShellLayout.titleRowTop).padding(.bottom, 8),
            conversation: mainContent,
            onContentWidthChange: { _ in }
        )
        .foregroundStyle(MarrPanelColors.primary(for: colorScheme))
        .overlay(alignment: .top) { AnswerPanelDragRegion().frame(height: 48).accessibilityHidden(true) }
        .sheet(item: $editor) { item in
            PersonalAgentEditorView(editor: item, coordinator: coordinator)
        }
        .sheet(isPresented: $showsHosting) {
            VStack(alignment: .trailing) {
                Button("Done") { showsHosting = false }.keyboardShortcut(.cancelAction)
                ScrollView { PersonalAgentCloudSettings(coordinator: coordinator) }
            }.padding(24).frame(width: 400, height: 500)
        }
        .accessibilityIdentifier("marr.personalAgent.workspace")
        .onDisappear {
            coordinator.savedSection = tab.rawValue
            coordinator.savedSelectedAgentID = selectedAgentID
        }
    }

    private var activeAgent: PersonalAgentProfile? { selectedAgent ?? coordinator.archive.agents.first }

    private var mainContent: some View {
        VStack(spacing: 0) {
            header
            if let message = (coordinator.cloud.enabled ? coordinator.cloud.error : coordinator.store.errorMessage) ?? coordinator.errorMessage {
                Text(message).marrTextStyle(.secondary).foregroundStyle(.orange)
                    .textSelection(.enabled).padding(.horizontal, 14).padding(.bottom, 8)
            }
            GeometryReader { geometry in
                Group {
                    switch tab {
                    case .agents:
                        if let agent = activeAgent {
                            conversation(agent, contentWidth: geometry.size.width).id(agent.id)
                        } else {
                            VStack(spacing: 20) {
                                MarrAgentEmblem().frame(width: 64, height: 64)
                                Button("New agent", action: newAgent).buttonStyle(PersonalAgentButtonStyle())
                            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    case .routines: routineList
                    case .activity: activityList
                    case .skills: skillList
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
            Color.clear.frame(height: MarrPanelShellLayout.toolbarHeight).accessibilityHidden(true)
            HStack(spacing: 8) {
                Text(tab == .agents ? (activeAgent?.name ?? "Agents") : tab.rawValue)
                    .marrTextStyle(.title, weight: .medium).lineLimit(1)
                Spacer(minLength: 0)
                if tab == .agents, let agent = activeAgent {
                    Text(agentStatus(agent)).marrTextStyle(.caption).foregroundStyle(.secondary)
                }
                Menu {
                    if let agent = activeAgent {
                        Button("Agent details") { editor = .agent(agent) }
                        Button("New routine") { editor = .routine(PersonalAgentRoutine(agentID: agent.id)) }
                    }
                    Button("New agent", action: newAgent)
                    Divider()
                    Button("Hosting settings") { showsHosting = true }
                } label: { MarrIcon("ellipsis", size: 16).frame(width: 28, height: 28) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Agent options")
            }
        }
        .padding(.horizontal, 14).padding(.top, MarrPanelShellLayout.toolbarTop).padding(.bottom, 8)
    }

    private var agentSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text("Agents").marrTextStyle(.caption, weight: .medium).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button(action: newAgent) {
                    MarrIcon("plus", size: MarrUI.Icon.inline).frame(width: 28, height: 28)
                }.buttonStyle(.plain).help("New agent").accessibilityLabel("New agent")
                    .accessibilityIdentifier("marr.agent.new")
            }
            .foregroundStyle(MarrPanelColors.secondary(for: colorScheme))
            .padding(.leading, 19).padding(.trailing, 12).padding(.top, 10).padding(.bottom, 8)
            agentList
            Divider().padding(.horizontal, 16).padding(.vertical, 8)
            ForEach([Section.routines, .activity, .skills]) { section in
                Button { tab = section } label: {
                    HStack(spacing: 8) {
                        MarrIcon(section == .routines ? "clock" : section == .activity ? "clock.arrow.circlepath" : "sparkles", size: MarrUI.Icon.inline)
                        Text(section.rawValue).marrTextStyle(.body)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 9).frame(height: 32)
                    .background(tab == section ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain).padding(.horizontal, 10)
            }
            Button { showsHosting = true } label: {
                HStack(spacing: 8) {
                    Circle().fill(coordinator.isConnected ? Color.green : Color.secondary).frame(width: 5, height: 5)
                    Text(coordinator.cloud.enabled ? "Cloud" : "This Mac").marrTextStyle(.caption)
                    Spacer()
                    MarrIcon("gearshape", size: MarrUI.Icon.inline)
                }.padding(12).contentShape(Rectangle())
            }.buttonStyle(.plain).help("Agent hosting settings").padding(.horizontal, 6)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(MarrUI.Surface.canvas, in: RoundedRectangle(cornerRadius: MarrUI.Radius.panel))
        .clipShape(RoundedRectangle(cornerRadius: MarrUI.Radius.panel))
        .overlay {
            RoundedRectangle(cornerRadius: MarrUI.Radius.panel)
                .strokeBorder(MarrUI.Border.color(.subtle, increasedContrast: colorSchemeContrast == .increased),
                              lineWidth: colorSchemeContrast == .increased ? 1 : 0.5)
                .allowsHitTesting(false)
        }
        .accessibilityLabel("Agents sidebar").accessibilityIdentifier("marr.agent.sidebar")
    }

    private func newAgent() {
        editor = .agent(PersonalAgentProfile(name: "", role: "", instructions: ""))
    }

    private var agentList: some View {
        VStack(spacing: 8) {
            if coordinator.archive.agents.count > 5 {
                TextField("Find an agent", text: $contactQuery).textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 16).accessibilityLabel("Find an agent")
            }
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(coordinator.archive.agents.filter { contactQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(contactQuery) }) { agent in
                        contact(agent)
                    }
                    if coordinator.archive.agents.isEmpty {
                        Button("Add an agent") { editor = .agent(PersonalAgentProfile(name: "", role: "", instructions: "")) }
                            .buttonStyle(PersonalAgentButtonStyle()).padding(.top, 32)
                    }
                }.padding(.horizontal, 10)
            }
        }
    }

    private func contact(_ agent: PersonalAgentProfile) -> some View {
        let recent = coordinator.archive.runs.last { $0.agentID == agent.id }
        let unread = coordinator.archive.runs.filter { $0.agentID == agent.id && !$0.isRead && !$0.status.isInFlight }.count
        return Button { selectedAgentID = agent.id; tab = .agents } label: {
            HStack(spacing: 10) {
                MarrAgentEmblem().hueRotation(.degrees(Double(agent.tint)))
                    .frame(width: 24, height: 24).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(agent.name).marrTextStyle(.body, weight: .medium).lineLimit(1)
                        Spacer(minLength: 0)
                        if unread > 0 {
                            Text("\(unread)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                                .padding(4).background(Color.accentColor, in: Capsule())
                        }
                    }
                    Text(recent?.status.isInFlight == true ? recent!.status.title : agent.isPaused ? "Paused" : recent.map { $0.result.isEmpty ? $0.prompt : $0.result } ?? agent.role)
                        .marrTextStyle(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }.padding(.horizontal, 10).padding(.vertical, 8)
                .background(tab == .agents && activeAgent?.id == agent.id ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("marr.agent.\(agent.id)")
            .accessibilityLabel("\(agent.name), \(agentStatus(agent)), \(unread) unread")
            .contextMenu { Button("Agent details") { editor = .agent(agent) } }
    }

    private var runtimeStatus: some View {
        HStack(spacing: 8) {
            Text(coordinator.cloud.enabled ? (coordinator.cloud.connected ? "Your server is connected" : "Server offline") : "Local runtime is off")
                .marrTextStyle(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if coordinator.cloud.enabled {
                Button("Settings") { showsHosting = true }.buttonStyle(PersonalAgentButtonStyle())
            } else {
                Button("Connect") {
                    if runtime.setCodexSyncEnabled(true) { runtime.refreshModelsIfNeeded() }
                    else { coordinator.errorMessage = runtime.statusMessage }
                }.buttonStyle(PersonalAgentButtonStyle())
            }
        }.padding(12)
    }

    private func agentStatus(_ agent: PersonalAgentProfile) -> String {
        if agent.isPaused { return "Paused" }
        if let run = coordinator.archive.runs.last(where: { $0.agentID == agent.id && ($0.status.isInFlight || $0.status == .uncertain) }) {
            return run.status.title
        }
        return coordinator.isConnected ? "Ready" : "Offline"
    }

    private func conversation(_ agent: PersonalAgentProfile, contentWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    let runs = coordinator.archive.runs.filter { $0.agentID == agent.id }
                    if runs.isEmpty {
                        VStack(spacing: 12) {
                            MarrAgentEmblem().hueRotation(.degrees(Double(agent.tint))).frame(width: 64, height: 64)
                            Text(agent.name).marrTextStyle(.title, weight: .semibold)
                            Text(agent.role).marrTextStyle(.secondary).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 30)
                    }
                    ForEach(runs) { run in
                        PersonalAgentRunView(run: run, coordinator: coordinator, showsPrompt: true)
                            .onAppear { if !run.isRead && !run.status.isInFlight { coordinator.markRead(run.id) } }
                            .onChange(of: run.status) { _, status in if !status.isInFlight && !run.isRead { coordinator.markRead(run.id) } }
                    }
                }.frame(width: MarrChatLayout.columnWidth(in: contentWidth))
                    .padding(.vertical, 12).frame(maxWidth: .infinity)
            }.defaultScrollAnchor(.bottom)
            if !coordinator.isConnected { runtimeStatus.frame(width: MarrChatLayout.columnWidth(in: contentWidth)) }
            PersonalAgentChatComposer(agent: agent, coordinator: coordinator, onDetails: { editor = .agent(agent) })
                .frame(width: MarrChatLayout.columnWidth(in: contentWidth))
                .padding(.top, 10).padding(.bottom, AnswerPanelConversationLayout.bottomInset)
        }
    }

    private var routineList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeading("Routines", subtitle: "", action: "New routine") { newRoutine() }
                if coordinator.archive.routines.isEmpty {
                    emptyState("No routines yet", detail: "Test a useful task in chat, then give it a schedule.", symbol: "clock")
                }
                ForEach(coordinator.archive.routines) { routine in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(routine.name).marrTextStyle(.body, weight: .semibold)
                                Text(coordinator.archive.agents.first { $0.id == routine.agentID }?.name ?? "Agent unavailable")
                                    .marrTextStyle(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("Enabled", isOn: Binding(get: { routine.isEnabled }, set: { _ in coordinator.toggle(routine) }))
                                .toggleStyle(.switch).labelsHidden().accessibilityLabel("Enable \(routine.name)")
                        }
                        Text(routine.schedule.label).marrTextStyle(.secondary).foregroundStyle(.secondary)
                        if routine.isEnabled, let date = routine.nextRunAt {
                            Text("Next: \(routine.schedule.formatted(date))")
                                .marrTextStyle(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("Edit") { editor = .routine(routine) }
                            Button("Run now") { _ = coordinator.send(routine.instruction, to: routine.agentID, routineID: routine.id) }
                                .disabled(coordinator.activeRunID != nil)
                            Spacer()
                            Text(routine.isEnabled ? "Scheduled" : "Paused").marrTextStyle(.caption).foregroundStyle(.secondary)
                        }.buttonStyle(PersonalAgentButtonStyle()).controlSize(.small)
                    }.padding(14).personalAgentCard()
                }
            }.padding(.horizontal, 20).padding(.bottom, 20)
        }
    }

    private var activityList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                Text("What’s happening").marrTextStyle(.title, weight: .semibold)
                Toggle("Needs attention only", isOn: $onlyNeedsAttention).toggleStyle(.checkbox).marrTextStyle(.secondary)
                let runs = coordinator.archive.runs.reversed().filter {
                    !onlyNeedsAttention || [.needsInput, .uncertain, .failed].contains($0.status)
                }
                if runs.isEmpty { emptyState("All quiet", detail: "Results, approvals and failures will appear here.", symbol: "checkmark") }
                ForEach(Array(runs)) { run in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(coordinator.archive.agents.first { $0.id == run.agentID }?.name ?? "Agent")
                            .marrTextStyle(.caption, weight: .semibold).foregroundStyle(.secondary)
                        PersonalAgentRunView(run: run, coordinator: coordinator, showsPrompt: true, showsCompletionStatus: true)
                    }.padding(14).personalAgentCard()
                }
            }.padding(.horizontal, 20).padding(.bottom, 20)
        }
    }

    private var skillList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeading("Skills", subtitle: "", action: "New skill") { editor = .skill(PersonalAgentSkill()) }
                if coordinator.archive.skills.isEmpty {
                    emptyState("No skills yet", detail: "", symbol: "sparkles")
                }
                ForEach(coordinator.archive.skills) { skill in
                    Button { editor = .skill(skill) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(skill.name, marrSymbol: "sparkles").marrTextStyle(.body, weight: .semibold)
                            Text(skill.instructions).marrTextStyle(.secondary).foregroundStyle(.secondary).lineLimit(3)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(14).personalAgentCard()
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 20).padding(.bottom, 20)
        }
    }

    private func sectionHeading(_ title: String, subtitle: String, action: String, perform: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).marrTextStyle(.title, weight: .semibold)
            if !subtitle.isEmpty { Text(subtitle).marrTextStyle(.secondary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Button(action, action: perform).buttonStyle(PersonalAgentButtonStyle())
        }.padding(.bottom, 8)
    }

    private func emptyState(_ title: String, detail: String, symbol: String) -> some View {
        VStack(spacing: 12) {
            MarrIcon(symbol, size: 26).foregroundStyle(.secondary)
            Text(title).marrTextStyle(.body, weight: .semibold)
            if !detail.isEmpty { Text(detail).marrTextStyle(.secondary).foregroundStyle(.secondary).multilineTextAlignment(.center) }
        }.frame(maxWidth: .infinity).padding(.vertical, 32)
    }

    private func newRoutine() {
        guard let id = selectedAgentID ?? coordinator.archive.agents.first?.id else { return }
        editor = .routine(PersonalAgentRoutine(agentID: id))
    }
}

private struct PersonalAgentCard: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        content.background(MarrUI.Surface.card.opacity(reduceTransparency ? 1 : 0.50), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(MarrUI.Border.color(.subtle, increasedContrast: contrast == .increased)))
    }
}

extension View {
    func personalAgentCard() -> some View { modifier(PersonalAgentCard()) }
}

/// A stateless native Button style keeps hidden panel surfaces out of the
/// animation/hover lifecycle while preserving keyboard and focus semantics.
struct PersonalAgentButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .marrTextStyle(.secondary, weight: .medium)
            .padding(.horizontal, 10).frame(minHeight: MarrUI.Control.regular)
            .foregroundStyle(primary ? Color.white : MarrPanelColors.primary(for: scheme))
            .background(primary ? Color.accentColor : MarrPanelColors.primary(for: scheme).opacity(configuration.isPressed ? 0.16 : 0.07),
                        in: RoundedRectangle(cornerRadius: MarrUI.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: MarrUI.Radius.control)
                .strokeBorder(isFocused ? Color.accentColor : MarrUI.Border.color(.subtle, increasedContrast: contrast == .increased),
                              lineWidth: isFocused ? 2 : 1))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }
}

private struct PersonalAgentChatComposer: View {
    let agent: PersonalAgentProfile
    @ObservedObject var coordinator: PersonalAgentCoordinator
    let onDetails: () -> Void
    @FocusState private var focused: Bool
    @AppStorage(MarrAccentColor.storageKey) private var accent = MarrAccentColor.system.rawValue
    private var draft: Binding<String> {
        Binding(get: { coordinator.drafts[agent.id] ?? "" }, set: { coordinator.drafts[agent.id] = $0 })
    }
    private var run: PersonalAgentRun? { coordinator.activeRun(for: agent.id) }
    private var canSend: Bool {
        !draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !agent.isPaused && run == nil
            && (coordinator.cloud.enabled ? !coordinator.cloud.pendingAgents.contains(agent.id) : coordinator.activeRunID == nil)
    }
    private func send() {
        guard canSend else { return }
        if coordinator.send(draft.wrappedValue, to: agent.id) { draft.wrappedValue = "" }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
            TextField("Message \(agent.name)…", text: draft, axis: .vertical)
                .marrChatInput().focused($focused)
                .accessibilityLabel("Message \(agent.name)")
                .onSubmit(send)
                .padding(.horizontal, 4)
            HStack(spacing: MarrUI.Spacing.small) {
                Button(action: onDetails) {
                    HStack(spacing: 4) {
                        MarrIcon("slider.horizontal.3", size: MarrUI.Icon.inline).frame(width: 28, height: 28)
                        Text(agent.access == .readOnly ? "Read only" : "Agent folder").marrTextStyle(.secondary).lineLimit(1)
                    }
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Agent details and permissions").accessibilityLabel("Agent details and permissions")
                Spacer(minLength: MarrUI.Spacing.regular)
                if let run {
                    MarrChatStopButton { coordinator.stop(run) }.disabled(coordinator.isStopping)
                } else {
                    Button(action: send) { MarrIcon("arrow.up", size: MarrUI.Icon.inline).frame(width: 28, height: 28) }
                        .marrChatSendButton(isEnabled: canSend).disabled(!canSend)
                        .keyboardShortcut(.return, modifiers: [.command])
                        .help("Send message").accessibilityLabel("Send message")
                }
            }
        }
        .padding(MarrChatLayout.inputPadding)
        .background(MarrChatComposerSurface(isFocused: focused))
        .marrAmbientGlow(isRunning: run?.status == .running, tint: MarrAccentColor.resolve(accent).color)
    }
}
