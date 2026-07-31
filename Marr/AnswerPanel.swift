import AppKit
import MarrCore
import SwiftUI

enum AnswerPanelUtilityDestination {
    case history
    case settings
}

@MainActor
private final class AnswerPanelNavigation: ObservableObject {
    struct Request: Equatable {
        let id = UUID()
        let destination: AnswerPanelUtilityDestination?
    }

    @Published private(set) var request: Request

    init(initialDestination: AnswerPanelUtilityDestination?) {
        request = Request(destination: initialDestination)
    }

    func show(_ destination: AnswerPanelUtilityDestination) {
        request = Request(destination: destination)
    }
}

@MainActor
final class AnswerPanelController {
    private let window: AnswerPanelWindow
    private let session: ConversationSession
    private let requestCoordinator: ConversationRequestCoordinator
    private let titleCoordinator: ConversationTitleCoordinator
    private let initialFrame: CGRect
    private let presentationStartFrame: CGRect
    private let navigation: AnswerPanelNavigation
    private(set) var isMinimized = false
    private var hasPresented = false
    private let collapsedPanelSize = AnswerPanelConversationLayout.panelSize

    convenience init(
        controller: MarrController,
        historyStore: ConversationHistoryStore,
        image: PickedImage,
        anchorRect: CGRect,
        initialQuestion: String
    ) {
        let createdSession = ConversationSession(initialImage: image, initialQuestion: initialQuestion)
        self.init(
            controller: controller,
            historyStore: historyStore,
            session: createdSession,
            anchorRect: anchorRect,
            persistImmediately: true
        )
    }

    init(
        controller: MarrController,
        historyStore: ConversationHistoryStore,
        session createdSession: ConversationSession,
        anchorRect: CGRect,
        persistImmediately: Bool,
        initialDestination: AnswerPanelUtilityDestination? = nil
    ) {
        createdSession.setArchiveHandler(persistImmediately: persistImmediately) { [weak historyStore] archive in
            historyStore?.save(archive)
        }
        session = createdSession
        let createdRequestCoordinator = ConversationRequestCoordinator(
            controller: controller,
            session: createdSession
        )
        requestCoordinator = createdRequestCoordinator
        let createdTitleCoordinator = ConversationTitleCoordinator(
            controller: controller,
            session: createdSession
        )
        titleCoordinator = createdTitleCoordinator
        let createdNavigation = AnswerPanelNavigation(initialDestination: initialDestination)
        navigation = createdNavigation
        let panelSize = collapsedPanelSize
        let screen = NSScreen.screens.first { $0.frame.intersects(anchorRect) } ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let targetFrame = AnswerPanelPlacement.initialFrame(
            panelSize: panelSize,
            anchorRect: anchorRect,
            visibleFrame: visibleFrame
        )
        let startFrame = AnswerPanelPlacement.presentationStartFrame(
            targetFrame: targetFrame,
            anchorRect: anchorRect
        )
        let createdWindow = AnswerPanelWindow(
            contentRect: startFrame,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        createdWindow.title = "Marr"
        createdWindow.isOpaque = false
        createdWindow.backgroundColor = .clear
        createdWindow.hasShadow = false
        createdWindow.isMovable = true
        createdWindow.isMovableByWindowBackground = true
        createdWindow.animationBehavior = .none
        createdWindow.isReleasedWhenClosed = false
        createdWindow.level = .screenSaver
        createdWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        createdWindow.acceptsMouseMovedEvents = true
        createdWindow.ignoresMouseEvents = false
        let createdHostingView = NSHostingView(
            rootView: AnswerPanelView(
                controller: controller,
                session: createdSession,
                historyStore: historyStore,
                requestCoordinator: createdRequestCoordinator,
                titleCoordinator: createdTitleCoordinator,
                navigation: createdNavigation,
                actions: AnswerPanelActions(
                    close: { [weak controller] in controller?.dismissCaptureSession() },
                    minimize: { [weak controller] in controller?.minimizeAnswerPanel() },
                    openHistoryConversation: { [weak controller] conversation in
                        controller?.openHistoryConversation(conversation)
                    }
                )
            )
            .marrPreferredColorScheme()
        )
        createdHostingView.sizingOptions = []
        createdWindow.contentView = createdHostingView

        window = createdWindow
        initialFrame = targetFrame
        presentationStartFrame = startFrame
        createdHostingView.layoutSubtreeIfNeeded()
        createdHostingView.displayIfNeeded()
    }

    func show() {
        isMinimized = false
        guard !hasPresented else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        hasPresented = true
        window.alphaValue = 0
        window.setFrame(presentationStartFrame, display: false)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.allowsImplicitAnimation = true
            window.animator().alphaValue = 1
            window.animator().setFrame(initialFrame, display: true)
        }
    }

    func minimize() {
        isMinimized = true
        window.orderOut(nil)
    }

    func restore() {
        isMinimized = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        session.requestFocus()
    }

    func show(_ destination: AnswerPanelUtilityDestination) {
        navigation.show(destination)
        restore()
    }

    func close() {
        requestCoordinator.cancel()
        titleCoordinator.cancel()
        window.close()
    }

    func setHistoryExpanded(_: Bool) {
        // History replaces the conversation content in-place; the panel remains fixed-size.
    }

    func appendScreenshot(_ image: PickedImage) {
        session.appendScreenshot(image)
        isMinimized = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

#if DEBUG
    var windowForTesting: NSWindow {
        window
    }
#endif

}

private final class AnswerPanelWindow: NSWindow {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }
}

private struct AnswerPanelActions {
    let close: () -> Void
    let minimize: () -> Void
    let openHistoryConversation: (ConversationHistoryRecord) -> Void
}

enum AnswerPanelConversationLayout {
    static let panelSize = NSSize(width: 420, height: 596)
    static let windowPadding: CGFloat = 12
    static let surfaceWidth: CGFloat = panelSize.width - windowPadding * 2
    static let surfaceHeight: CGFloat = panelSize.height - windowPadding * 2
    static let composerWidth: CGFloat = surfaceWidth - 64
    static let composerHeight: CGFloat = 40
    static let assistantTextWidth: CGFloat = composerWidth - 8
    static let surfaceCornerRadius: CGFloat = 24
    static let bottomInset: CGFloat = 16
}

enum AnswerPanelPlacement {
    private enum Direction: Int, CaseIterable {
        case right
        case left
        case above
        case below
    }

    private struct Candidate {
        let direction: Direction
        let score: CGFloat
        let frame: CGRect
    }

    static let gap: CGFloat = 14
    static let screenMargin: CGFloat = 12
    static let presentationOffset: CGFloat = 14

    static func initialFrame(
        panelSize: CGSize,
        anchorRect: CGRect,
        visibleFrame: CGRect
    ) -> CGRect {
        let safeFrame = visibleFrame.insetBy(dx: screenMargin, dy: screenMargin)
        guard panelSize.width > 0, panelSize.height > 0, !safeFrame.isEmpty else {
            return CGRect(origin: visibleFrame.origin, size: panelSize)
        }

        let candidates = Direction.allCases.map { direction in
            Candidate(
                direction: direction,
                score: availableSpace(
                    for: direction,
                    anchorRect: anchorRect,
                    safeFrame: safeFrame
                ) / requiredSpace(for: direction, panelSize: panelSize),
                frame: rawFrame(
                    for: direction,
                    panelSize: panelSize,
                    anchorRect: anchorRect
                )
            )
        }
        let best = candidates.max { lhs, rhs in
            if abs(lhs.score - rhs.score) > 0.001 {
                return lhs.score < rhs.score
            }
            return lhs.direction.rawValue > rhs.direction.rawValue
        } ?? candidates[0]

        return clamped(best.frame, to: safeFrame)
    }

    static func presentationStartFrame(
        targetFrame: CGRect,
        anchorRect: CGRect
    ) -> CGRect {
        let deltaX = anchorRect.midX - targetFrame.midX
        let deltaY = anchorRect.midY - targetFrame.midY
        let distance = hypot(deltaX, deltaY)
        guard distance > 0 else { return targetFrame }

        return targetFrame.offsetBy(
            dx: deltaX / distance * presentationOffset,
            dy: deltaY / distance * presentationOffset
        )
    }

    private static func availableSpace(
        for direction: Direction,
        anchorRect: CGRect,
        safeFrame: CGRect
    ) -> CGFloat {
        switch direction {
        case .right:
            safeFrame.maxX - anchorRect.maxX - gap
        case .left:
            anchorRect.minX - safeFrame.minX - gap
        case .above:
            safeFrame.maxY - anchorRect.maxY - gap
        case .below:
            anchorRect.minY - safeFrame.minY - gap
        }
    }

    private static func requiredSpace(
        for direction: Direction,
        panelSize: CGSize
    ) -> CGFloat {
        switch direction {
        case .right, .left:
            panelSize.width
        case .above, .below:
            panelSize.height
        }
    }

    private static func rawFrame(
        for direction: Direction,
        panelSize: CGSize,
        anchorRect: CGRect
    ) -> CGRect {
        let origin: CGPoint
        switch direction {
        case .right:
            origin = CGPoint(
                x: anchorRect.maxX + gap,
                y: anchorRect.midY - panelSize.height / 2
            )
        case .left:
            origin = CGPoint(
                x: anchorRect.minX - gap - panelSize.width,
                y: anchorRect.midY - panelSize.height / 2
            )
        case .above:
            origin = CGPoint(
                x: anchorRect.midX - panelSize.width / 2,
                y: anchorRect.maxY + gap
            )
        case .below:
            origin = CGPoint(
                x: anchorRect.midX - panelSize.width / 2,
                y: anchorRect.minY - gap - panelSize.height
            )
        }
        return CGRect(origin: origin, size: panelSize)
    }

    private static func clamped(_ frame: CGRect, to safeFrame: CGRect) -> CGRect {
        CGRect(
            x: min(
                max(frame.minX, safeFrame.minX),
                max(safeFrame.minX, safeFrame.maxX - frame.width)
            ),
            y: min(
                max(frame.minY, safeFrame.minY),
                max(safeFrame.minY, safeFrame.maxY - frame.height)
            ),
            width: frame.width,
            height: frame.height
        )
    }
}

enum AnswerPanelTitleFade {
    static func opacity(forScrollDistance distance: CGFloat) -> Double {
        Double(max(0.18, 1 - max(0, distance) / 72))
    }
}

private enum ConversationScrollAnchor: Hashable {
    case bottom
}

private struct ConversationScrollMinYPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

enum AnswerPanelEscapeAction: Equatable {
    case closeSettings
    case closeHistory
    case cancelEditing
    case closePanel

    static func resolve(
        showsSettings: Bool,
        showsHistory: Bool,
        isEditing: Bool
    ) -> AnswerPanelEscapeAction {
        if showsSettings {
            return .closeSettings
        }
        if showsHistory {
            return .closeHistory
        }
        if isEditing {
            return .cancelEditing
        }
        return .closePanel
    }
}

enum AnswerPanelConversationTitle {
    static func make(from question: String) -> String {
        let normalized = question
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return "Untitled conversation"
        }

        let analysisPrefix = "Analyze this screenshot of "
        let candidate: String
        if normalized.hasPrefix(analysisPrefix) {
            let remainder = String(normalized.dropFirst(analysisPrefix.count))
            candidate = remainder.components(separatedBy: ". Explain").first ?? remainder
        } else {
            candidate = normalized
        }

        let maximumLength = 72
        guard candidate.count > maximumLength else {
            return candidate
        }
        return String(candidate.prefix(maximumLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

private struct AnswerPanelView: View {
    @ObservedObject var controller: MarrController
    @ObservedObject var session: ConversationSession
    @ObservedObject private var historyStore: ConversationHistoryStore
    let requestCoordinator: ConversationRequestCoordinator
    let titleCoordinator: ConversationTitleCoordinator
    @ObservedObject var navigation: AnswerPanelNavigation
    let actions: AnswerPanelActions

    @State private var question = ""
    @State private var lastAutoScrolledTurnCount = 0
    @State private var hasSubmittedInitialQuestion = false
    @State private var hoveredQuestionTurnID: UUID?
    @State private var editingTurnID: UUID?
    @State private var showsHistoryPanel = false
    @State private var showsSettingsPanel = false
    @State private var historySearchText = ""
    @State private var panelControlsHovered = false
    @State private var conversationTitleHovered = false
    @State private var conversationScrollMinY: CGFloat = 0
    @State private var hoveredEditTurnID: UUID?
    @State private var selectedSlashCommandIndex = 0
    @State private var dismissedSlashMenuInput: String?
    @State private var attachmentErrorMessage: String?
    @State private var attachmentButtonHovered = false
    @AppStorage(MarrBubbleColor.storageKey) private var bubbleColor = MarrBubbleColor.system.rawValue
    @AppStorage(MarrAccentColor.storageKey) private var accentColor = MarrAccentColor.system.rawValue
    @FocusState private var questionFocused: Bool
    @FocusState private var historySearchFocused: Bool

    private let composerWidth = AnswerPanelConversationLayout.composerWidth
    private let assistantRevealDelay = 0.30
    private let conversationHeaderHeight: CGFloat = 78
    private let primarySurfaceHeight = AnswerPanelConversationLayout.surfaceHeight

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
        self.session = session
        self.requestCoordinator = requestCoordinator
        self.titleCoordinator = titleCoordinator
        self.navigation = navigation
        self.actions = actions
        _historyStore = ObservedObject(wrappedValue: historyStore)
        _showsHistoryPanel = State(initialValue: navigation.request.destination == .history)
        _showsSettingsPanel = State(initialValue: navigation.request.destination == .settings)
    }

    var body: some View {
        fixedAnswerStack
        .frame(width: AnswerPanelConversationLayout.surfaceWidth)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .padding(AnswerPanelConversationLayout.windowPadding)
        .onAppear {
            DispatchQueue.main.async {
                questionFocused = true
                submitInitialQuestion()
                titleCoordinator.generateIfNeeded()
            }
        }
        .onChange(of: session.turns) { _, _ in
            titleCoordinator.generateIfNeeded()
        }
        .onChange(of: session.focusRequestID) { _, _ in
            if !showsHistoryPanel, !showsSettingsPanel {
                questionFocused = true
            }
        }
        .onChange(of: navigation.request) { _, request in
            showUtilityDestination(request.destination)
        }
        .onChange(of: question) { _, nextQuestion in
            selectedSlashCommandIndex = 0
            if dismissedSlashMenuInput != nextQuestion {
                dismissedSlashMenuInput = nil
            }
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
        .onExitCommand(perform: handleEscape)
    }

    private var fixedAnswerStack: some View {
        primarySurface
        .frame(
            width: AnswerPanelConversationLayout.surfaceWidth,
            height: AnswerPanelConversationLayout.surfaceHeight,
            alignment: .bottom
        )
        .animation(.spring(response: 0.30, dampingFraction: 0.88), value: showsHistoryPanel)
        .animation(.spring(response: 0.30, dampingFraction: 0.88), value: showsSettingsPanel)
    }

    private var primarySurface: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if showsSettingsPanel {
                    settingsHeader
                        .transition(.opacity)
                } else if showsHistoryPanel {
                    historyHeader
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
                } else if showsHistoryPanel {
                    historyContent
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    conversationScroll
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !showsSettingsPanel {
                composerFooter
            }
        }
        .frame(
            width: AnswerPanelConversationLayout.surfaceWidth,
            height: primarySurfaceHeight,
            alignment: .top
        )
        .marrGlassSurface(cornerRadius: AnswerPanelConversationLayout.surfaceCornerRadius, isClear: true)
        .overlay(
            RoundedRectangle(
                cornerRadius: AnswerPanelConversationLayout.surfaceCornerRadius,
                style: .continuous
            )
            .stroke(.white.opacity(0.18), lineWidth: 0.8)
            .allowsHitTesting(false)
        )
        .clipped()
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var composerFooter: some View {
        VStack(spacing: 7) {
            if !showsHistoryPanel, !session.pendingImageIDs.isEmpty {
                Label(
                    "\(session.pendingImageIDs.count) attachment\(session.pendingImageIDs.count == 1 ? "" : "s") ready for the next question",
                    systemImage: "paperclip"
                )
                .font(MarrTypography.caption())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            Group {
                if showsHistoryPanel {
                    historySearchComposer
                } else {
                    composer
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.top, 8)
        .padding(.bottom, AnswerPanelConversationLayout.windowPadding)
        .frame(maxWidth: .infinity)
        .zIndex(showsSlashCommandMenu ? 10 : 1)
    }

    private var settingsHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            panelControls

            HStack(spacing: 8) {
                Button {
                    hideSettings()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary.opacity(0.86))
                .help("Back to conversation")

                Text("Settings")
                    .font(.system(size: 18, weight: .regular, design: .default))
                    .foregroundStyle(.primary)

                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(height: conversationHeaderHeight, alignment: .topLeading)
    }

    private var settingsContent: some View {
        AnswerPanelSettingsView(controller: controller)
    }

    private var historyHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            panelControls

            HStack(spacing: 8) {
                Button {
                    hideHistorySearch()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary.opacity(0.86))
                .help("Back to conversation")

                Text("History")
                    .font(.system(size: 18, weight: .regular, design: .default))
                    .foregroundStyle(.primary)

                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(height: conversationHeaderHeight, alignment: .topLeading)
    }

    private var historyContent: some View {
        AnswerPanelHistoryView(
            store: historyStore,
            currentConversationID: session.id,
            searchText: $historySearchText,
            onOpen: actions.openHistoryConversation
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private var panelControls: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                PanelControlButton(
                    symbol: "xmark",
                    showsSymbol: panelControlsHovered,
                    color: Color(red: 1.0, green: 0.36, blue: 0.34),
                    borderColor: Color(red: 0.82, green: 0.20, blue: 0.19)
                ) {
                    actions.close()
                }
                .help("Close")

                PanelControlButton(
                    symbol: "minus",
                    showsSymbol: panelControlsHovered,
                    color: Color(red: 1.0, green: 0.78, blue: 0.13),
                    borderColor: Color(red: 0.82, green: 0.58, blue: 0.02)
                ) {
                    actions.minimize()
                }
                .help("Minimize")
            }
            .onHover { isHovering in
                withAnimation(.easeOut(duration: 0.10)) {
                    panelControlsHovered = isHovering
                }
            }

            Spacer(minLength: 0)

            Button {
                if showsSettingsPanel {
                    hideSettings()
                } else {
                    showSettings()
                }
            } label: {
                PanelUtilityButtonLabel(symbol: showsSettingsPanel ? "gearshape.fill" : "gearshape")
            }
            .buttonStyle(.plain)
            .help(showsSettingsPanel ? "Back to conversation" : "Settings")
        }
        .frame(maxWidth: .infinity)
    }

    private var conversationHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            panelControls
            conversationTitleControl
                .opacity(AnswerPanelTitleFade.opacity(forScrollDistance: max(0, -conversationScrollMinY)))
                .offset(y: -min(5, max(0, -conversationScrollMinY) * 0.07))
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(height: conversationHeaderHeight, alignment: .topLeading)
    }

    private var conversationScroll: some View {
        ScrollViewReader { proxy in
            GeometryReader { availableSpace in
                ScrollView {
                    VStack(spacing: 0) {
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: ConversationScrollMinYPreferenceKey.self,
                                value: geometry.frame(in: .named("AnswerPanelConversationScroll")).minY
                            )
                        }
                        .frame(height: 0)

                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(session.turns) { turn in
                                turnView(turn, isCompact: false, showsUserMessage: true)
                                    .id(turn.id)
                            }
                        }

                        Color.clear
                            .frame(height: AnswerPanelConversationLayout.bottomInset)
                            .id(ConversationScrollAnchor.bottom)
                    }
                    .padding(.top, 14)
                    .frame(width: composerWidth, alignment: .topLeading)
                    .frame(minHeight: availableSpace.size.height, alignment: .bottom)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .coordinateSpace(name: "AnswerPanelConversationScroll")
                .onPreferenceChange(ConversationScrollMinYPreferenceKey.self) { nextMinY in
                    conversationScrollMinY = nextMinY
                }
                .onAppear {
                    guard !session.turns.isEmpty else { return }
                    lastAutoScrolledTurnCount = session.turns.count
                    DispatchQueue.main.async {
                        proxy.scrollTo(ConversationScrollAnchor.bottom, anchor: .bottom)
                    }
                }
                .onChange(of: session.turns.count) { _, nextCount in
                    guard nextCount > lastAutoScrolledTurnCount else { return }
                    lastAutoScrolledTurnCount = nextCount
                    DispatchQueue.main.async {
                        proxy.scrollTo(ConversationScrollAnchor.bottom, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var conversationTitleControl: some View {
        Button {
            showHistorySearch()
        } label: {
            HStack(spacing: 7) {
                Rectangle()
                    .fill(.secondary.opacity(0.28))
                    .frame(width: 1, height: 20)

                Text(conversationDisplayTitle)
                    .font(.system(size: 16.5, weight: .regular, design: .default))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .opacity(conversationTitleHovered ? 0.78 : 0)

                Spacer(minLength: 0)
            }
            .foregroundStyle(.primary.opacity(0.82))
            .frame(width: composerWidth - 28, height: 30, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            withAnimation(.easeOut(duration: 0.12)) {
                conversationTitleHovered = isHovering
            }
        }
        .help("Open history")
    }

    private var historySearchComposer: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(selectedAccent.color.opacity(0.88))

            TextField("Search history...", text: $historySearchText)
                .textFieldStyle(.plain)
                .font(MarrTypography.body(size: 13.5, weight: .medium))
                .focused($historySearchFocused)

            if !historySearchText.isEmpty {
                Button {
                    historySearchText = ""
                    historySearchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear search")
            }

        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .frame(width: composerWidth)
        .frame(minHeight: AnswerPanelConversationLayout.composerHeight)
        .marrGlassSurface(
            cornerRadius: AnswerPanelConversationLayout.composerHeight / 2,
            isClear: true,
            tintOpacity: 0.06
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: AnswerPanelConversationLayout.composerHeight / 2,
                style: .continuous
            )
                .stroke(.white.opacity(0.18), lineWidth: 0.8)
                .allowsHitTesting(false)
        )
        .shadow(color: .white.opacity(0.10), radius: 1, x: 0, y: -1)
        .animation(.easeOut(duration: 0.16), value: historySearchText.isEmpty)
    }

    private var conversationDisplayTitle: String {
        session.displayTitle
    }

    private func turnView(_ turn: ConversationTurn, isCompact: Bool, showsUserMessage: Bool) -> some View {
        VStack(spacing: 10) {
            if showsUserMessage {
                HStack(alignment: .bottom) {
                    Spacer(minLength: 72)
                    VStack(alignment: .trailing, spacing: 8) {
                        turnScreenshotAttachments(turn)

                        Text(turn.question)
                            .font(MarrTypography.body(size: 12.5, weight: .medium))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 7)
                            .background(bubbleTint.opacity(0.92), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .foregroundStyle(bubbleForegroundColor)
                            .shadow(color: .black.opacity(0.10), radius: 6, x: 0, y: 3)

                        if canEdit(turn) {
                            questionActions(for: turn)
                                .opacity(hoveredQuestionTurnID == turn.id ? 1 : 0)
                                .allowsHitTesting(hoveredQuestionTurnID == turn.id)
                        }
                    }
                    .contentShape(Rectangle())
                    .onHover { isHovering in
                        withAnimation(.easeOut(duration: 0.12)) {
                            hoveredQuestionTurnID = isHovering ? turn.id : nil
                        }
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .opacity
                ))
            }

            if turn.showsAssistant {
                if turn.errorMessage != nil {
                    errorMessage(turn)
                        .transition(.opacity)
                } else {
                    assistantMessage(turn, isCompact: isCompact)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .opacity
                        ))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func turnScreenshotAttachments(_ turn: ConversationTurn) -> some View {
        let attachments = turn.imageIDs.compactMap { session.images[$0] }
        if !attachments.isEmpty {
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(attachments) { asset in
                    if asset.isImage, let image = NSImage(data: asset.data) {
                        let size = screenshotThumbnailSize(for: image)
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fill)
                            .frame(width: size.width, height: size.height)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(.white.opacity(0.22), lineWidth: 0.8)
                                    .allowsHitTesting(false)
                            )
                            .shadow(color: .black.opacity(0.11), radius: 6, x: 0, y: 3)
                    } else {
                        fileAttachmentView(asset)
                    }
                }
            }
        }
    }

    private func fileAttachmentView(_ asset: ConversationImageAsset) -> some View {
        HStack(spacing: 9) {
            Image(systemName: AttachmentFileSupport.symbolName(for: asset.fileName))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(selectedAccent.color)
                .frame(width: 30, height: 30)
                .background(selectedAccent.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(asset.fileName)
                    .font(MarrTypography.body(size: 12.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(
                    ByteCountFormatter.string(
                        fromByteCount: Int64(asset.data.count),
                        countStyle: .file
                    )
                )
                .font(MarrTypography.body(size: 10.5))
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

    private func screenshotThumbnailSize(for image: NSImage) -> CGSize {
        let maximum = CGSize(width: 220, height: 96)
        guard image.size.width > 0, image.size.height > 0 else { return maximum }
        let scale = min(maximum.width / image.size.width, maximum.height / image.size.height, 1)
        return CGSize(width: image.size.width * scale, height: image.size.height * scale)
    }

    private func questionActions(for turn: ConversationTurn) -> some View {
        Button {
            beginEditing(turn)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "pencil")
                    .font(.system(size: 11, weight: .semibold))
                Text("Edit")
                    .font(MarrTypography.body(size: 12, weight: .semibold))
            }
            .foregroundStyle(.primary.opacity(0.82))
            .padding(.horizontal, 11)
            .frame(minWidth: 70, minHeight: 30)
            .background(
                hoveredEditTurnID == turn.id
                    ? selectedAccent.color.opacity(0.16)
                    : Color.primary.opacity(0.075),
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .stroke(.white.opacity(0.16), lineWidth: 0.7)
                    .allowsHitTesting(false)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(minWidth: 70, minHeight: 30)
        .onHover { isHovering in
            withAnimation(.easeOut(duration: 0.10)) {
                hoveredEditTurnID = isHovering ? turn.id : nil
            }
        }
        .help("Edit and regenerate")
    }

    @ViewBuilder
    private func assistantMessage(_ turn: ConversationTurn, isCompact: Bool) -> some View {
        if turn.isLoading {
            TypingIndicatorView()
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .marrGlassSurface(cornerRadius: 15, isClear: true)
            .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 3)
        } else {
            MarkdownResponseView(source: turn.answer.isEmpty ? " " : turn.answer)
                .textSelection(.enabled)
                .frame(
                    width: AnswerPanelConversationLayout.assistantTextWidth,
                    alignment: .leading
                )
                .padding(.vertical, 4)
        }
    }

    private func errorMessage(_ turn: ConversationTurn) -> some View {
        VStack(spacing: 8) {
            Text(turn.errorMessage ?? "")
                .font(MarrTypography.body(size: 12.5, weight: .medium))
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.86)
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

    private var composer: some View {
        HStack(spacing: 8) {
            attachmentButton
            composerInput
        }
        .frame(width: composerWidth)
        .overlay(alignment: .top) {
            if showsSlashCommandMenu {
                slashCommandMenu
                    .offset(y: AnswerPanelConversationLayout.composerHeight + 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .zIndex(showsSlashCommandMenu ? 10 : 0)
        .animation(.easeOut(duration: 0.16), value: showsSlashCommandMenu)
    }

    private var attachmentButton: some View {
        Button {
            showAttachmentPicker()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .regular))
                .frame(
                    width: AnswerPanelConversationLayout.composerHeight,
                    height: AnswerPanelConversationLayout.composerHeight
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary.opacity(editingTurnID == nil ? 0.84 : 0.38))
        .marrGlassSurface(
            cornerRadius: AnswerPanelConversationLayout.composerHeight / 2,
            isClear: true,
            tintOpacity: 0.06
        )
        .overlay(
            Circle()
                .fill(selectedAccent.color.opacity(attachmentButtonHovered ? 0.10 : 0))
                .allowsHitTesting(false)
        )
        .overlay(
            Circle()
                .stroke(.white.opacity(0.20), lineWidth: 0.8)
                .allowsHitTesting(false)
        )
        .shadow(color: .black.opacity(0.10), radius: 7, x: 0, y: 3)
        .disabled(editingTurnID != nil)
        .onHover { isHovering in
            withAnimation(.easeOut(duration: 0.12)) {
                attachmentButtonHovered = isHovering
            }
        }
        .help(editingTurnID == nil ? "Add attachments" : "Finish editing before adding attachments")
    }

    private var composerInput: some View {
        HStack(spacing: 8) {
            if editingTurnID != nil {
                Image(systemName: "pencil")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
            }

            TextField(editingTurnID == nil ? "Ask a follow-up" : "Edit latest message", text: $question, axis: .vertical)
                .textFieldStyle(.plain)
                .font(MarrTypography.body(size: 13.5))
                .lineLimit(1...2)
                .foregroundStyle(.primary)
                .focused($questionFocused)
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

            if editingTurnID != nil {
                Button {
                    cancelEditing()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Cancel editing")
            }

            Button {
                sendCurrentQuestion()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13.5, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .sendCircleButton(isEnabled: canSend, color: bubbleTint, foregroundColor: bubbleForegroundColor)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!canSend)
            .help("Send")
        }
        .padding(.leading, 12)
        .padding(.trailing, 5)
        .padding(.vertical, 4)
        .frame(
            width: composerWidth - AnswerPanelConversationLayout.composerHeight - 8
        )
        .frame(minHeight: AnswerPanelConversationLayout.composerHeight)
        .marrGlassSurface(
            cornerRadius: AnswerPanelConversationLayout.composerHeight / 2,
            isClear: true,
            tintOpacity: 0.06
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: AnswerPanelConversationLayout.composerHeight / 2,
                style: .continuous
            )
                .stroke(.white.opacity(0.18), lineWidth: 0.8)
        )
        .shadow(color: .white.opacity(0.10), radius: 1, x: 0, y: -1)
    }

    private func showAttachmentPicker() {
        let panel = NSOpenPanel()
        panel.title = "Add Attachments"
        panel.message = "Choose images, PDFs, documents, spreadsheets, presentations, text, or code files."
        panel.prompt = "Attach"
        panel.allowedContentTypes = AttachmentFileSupport.allowedContentTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false

        panel.begin { response in
            guard response == .OK else {
                DispatchQueue.main.async {
                    questionFocused = true
                }
                return
            }

            let selectedURLs = panel.urls
            DispatchQueue.main.async {
                var failedFiles: [String] = []
                let attachmentLimit = AttachmentFileSupport.maximumAttachmentCount
                let remainingCapacity = max(0, attachmentLimit - session.pendingImageIDs.count)
                if selectedURLs.count > remainingCapacity {
                    failedFiles.append(
                        "You can attach up to \(attachmentLimit) files to one question."
                    )
                }

                var attachedBytes = session.pendingImageIDs.reduce(into: 0) { total, attachmentID in
                    total += session.images[attachmentID]?.data.count ?? 0
                }
                for url in selectedURLs.prefix(remainingCapacity) {
                    do {
                        let attachment = try PickedAttachment.attachment(from: url)
                        guard attachedBytes + attachment.data.count < AttachmentFileSupport.maximumRequestBytes else {
                            failedFiles.append(
                                "\"\(attachment.fileName)\" would make the combined attachments exceed 50 MB."
                            )
                            continue
                        }
                        session.appendAttachment(attachment)
                        attachedBytes += attachment.data.count
                    } catch {
                        failedFiles.append(error.localizedDescription)
                    }
                }

                if !failedFiles.isEmpty {
                    attachmentErrorMessage = failedFiles.joined(separator: "\n")
                }
                questionFocused = true
            }
        }
    }

    private var slashCommandMenu: some View {
        VStack(spacing: 2) {
            ForEach(Array(slashCommandMatches.enumerated()), id: \.element.id) { index, command in
                Button {
                    chooseSlashCommand(command)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: command.symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(selectedAccent.color)
                            .frame(width: 26, height: 26)
                            .background(selectedAccent.color.opacity(0.11), in: RoundedRectangle(cornerRadius: 7))

                        Text(command.invocation)
                            .font(MarrTypography.mono(size: 12.5, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 82, alignment: .leading)

                        Text(command.summary)
                            .font(MarrTypography.body(size: 12.5))
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

    private var showsSlashCommandMenu: Bool {
        !slashCommandMatches.isEmpty && dismissedSlashMenuInput != question
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
        questionFocused = true
    }

    private var canSend: Bool {
        !session.hasLoadingTurn && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    private func showHistorySearch() {
        historyStore.reload()
        questionFocused = false
        historySearchFocused = false
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            showsSettingsPanel = false
            showsHistoryPanel = true
        }
        DispatchQueue.main.async {
            guard showsHistoryPanel else { return }
            historySearchFocused = true
        }
    }

    private func hideHistorySearch() {
        historySearchFocused = false
        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
            showsHistoryPanel = false
            historySearchText = ""
        }
        DispatchQueue.main.async {
            guard !showsHistoryPanel else { return }
            questionFocused = true
        }
    }

    private func showSettings() {
        questionFocused = false
        historySearchFocused = false
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            showsHistoryPanel = false
            historySearchText = ""
            showsSettingsPanel = true
        }
    }

    private func showUtilityDestination(_ destination: AnswerPanelUtilityDestination?) {
        switch destination {
        case .history:
            showHistorySearch()
        case .settings:
            showSettings()
        case nil:
            break
        }
    }

    private func hideSettings() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
            showsSettingsPanel = false
        }
        DispatchQueue.main.async {
            guard !showsSettingsPanel else { return }
            questionFocused = true
        }
    }

    private func handleEscape() {
        switch AnswerPanelEscapeAction.resolve(
            showsSettings: showsSettingsPanel,
            showsHistory: showsHistoryPanel,
            isEditing: editingTurnID != nil
        ) {
        case .closeSettings:
            hideSettings()
        case .closeHistory:
            hideHistorySearch()
        case .cancelEditing:
            cancelEditing()
        case .closePanel:
            actions.close()
        }
    }

    private func sendCurrentQuestion() {
        let current = question
        if let editingTurnID {
            reviseAndResend(current, turnID: editingTurnID)
        } else {
            question = ""
            send(current)
        }
    }

    private func send(_ rawQuestion: String) {
        let trimmedQuestion = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty, !session.hasLoadingTurn else {
            return
        }

        guard let turnID = session.beginTurn(question: trimmedQuestion) else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + assistantRevealDelay) {
            withAnimation(.easeOut(duration: 0.20)) {
                session.revealAssistant(for: turnID)
            }
        }
        submit(turnID)
    }

    private func beginEditing(_ turn: ConversationTurn) {
        guard canEdit(turn) else { return }
        editingTurnID = turn.id
        question = turn.question
        questionFocused = true
    }

    private func cancelEditing() {
        editingTurnID = nil
        question = ""
        questionFocused = true
    }

    private func canEdit(_ turn: ConversationTurn) -> Bool {
        session.latestEditableTurnID == turn.id
    }

    private func reviseAndResend(_ rawQuestion: String, turnID: UUID) {
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

    private func submitInitialQuestion() {
        guard
            !hasSubmittedInitialQuestion,
            let turn = session.turns.first,
            turn.isLoading
        else {
            return
        }

        hasSubmittedInitialQuestion = true
        submit(turn.id)
    }

    private func retry(_ turnID: UUID) {
        guard session.prepareRetry(turnID) else { return }
        submit(turnID)
    }

    private func submit(_ turnID: UUID) {
        requestCoordinator.submit(turnID)
    }
}

private struct AnswerPanelHistoryView: View {
    @ObservedObject var store: ConversationHistoryStore
    let currentConversationID: UUID
    @Binding var searchText: String
    let onOpen: (ConversationHistoryRecord) -> Void

    @State private var hoveredConversationID: UUID?
    @AppStorage(MarrAccentColor.storageKey) private var accentColor = MarrAccentColor.system.rawValue

    var body: some View {
        Group {
            if filteredConversations.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredConversations) { conversation in
                            historyRow(conversation)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            store.reload()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "clock.arrow.circlepath" : "magnifyingglass")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.secondary)
            Text(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No history yet" : "No matches")
                .font(MarrTypography.body(size: 13, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.86))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.bottom, 8)
    }

    private func historyRow(_ conversation: ConversationHistoryRecord) -> some View {
        let isHovered = hoveredConversationID == conversation.id
        let isCurrent = conversation.id == currentConversationID
        return Button {
            onOpen(conversation)
        } label: {
            HStack(spacing: 12) {
                Text(AnswerPanelConversationTitle.make(from: conversation.title))
                    .font(MarrTypography.body(size: 14, weight: isCurrent ? .semibold : .medium))
                    .foregroundStyle(.primary.opacity(isCurrent ? 0.96 : 0.82))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 12)

                Text(dateLabel(for: conversation.updatedAt))
                    .font(MarrTypography.body(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 48)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        isHovered
                            ? selectedAccent.color.opacity(0.12)
                            : isCurrent ? selectedAccent.color.opacity(0.07) : .clear
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .onHover { isHovering in
            withAnimation(.easeOut(duration: 0.12)) {
                hoveredConversationID = isHovering ? conversation.id : nil
            }
        }
    }

    private var filteredConversations: [ConversationHistoryRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return store.conversations
        }

        return store.conversations.filter {
            searchCorpus(for: $0).localizedCaseInsensitiveContains(query)
        }
    }

    private func searchCorpus(for conversation: ConversationHistoryRecord) -> String {
        var parts = [conversation.title]
        for turn in conversation.turns {
            parts.append(turn.question)
            parts.append(turn.answer)
            if let errorMessage = turn.errorMessage {
                parts.append(errorMessage)
            }
        }
        return parts.joined(separator: " ")
    }

    private func dateLabel(for date: Date) -> String {
        let calendar = Calendar.current
        let now = Date()
        if calendar.isDateInToday(date) {
            return "Today"
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 {
            return "\(max(1, days))d"
        }

        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter.string(from: date)
    }

    private var selectedAccent: MarrAccentColor {
        MarrAccentColor.resolve(accentColor)
    }
}

private struct PanelControlButton: View {
    let symbol: String
    let showsSymbol: Bool
    let color: Color
    let borderColor: Color
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .overlay(
                    Circle()
                        .stroke(borderColor.opacity(0.72), lineWidth: 0.7)
                )
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: 7, weight: .black))
                        .foregroundStyle(.black.opacity(0.68))
                        .opacity(showsSymbol ? 1 : 0)
                }
                .shadow(color: .black.opacity(isHovering ? 0.16 : 0.08), radius: isHovering ? 3 : 2, x: 0, y: 1)
                .frame(width: 13, height: 13)
                .scaleEffect(isHovering ? 1.05 : 1)
        }
        .buttonStyle(.plain)
        .frame(width: 18, height: 18)
        .contentShape(Circle())
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.10), value: showsSymbol)
    }
}

private struct PanelUtilityButtonLabel: View {
    let symbol: String

    @State private var isHovering = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.primary.opacity(isHovering ? 0.92 : 0.68))
            .frame(width: 26, height: 26)
            .background(
                Color.primary.opacity(isHovering ? 0.13 : 0.07),
                in: Circle()
            )
            .overlay(
                Circle()
                    .stroke(.white.opacity(0.14), lineWidth: 0.7)
                    .allowsHitTesting(false)
            )
            .contentShape(Circle())
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.10), value: isHovering)
    }
}

private struct MarkdownResponseView: View {
    let source: String

    private var blocks: [MarkdownBlock] {
        MarkdownBlockParser.parse(source)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, content):
            Text(inlineMarkdown(content))
                .font(MarrTypography.display(size: headingSize(level), weight: .semibold))
                .lineSpacing(2)
                .padding(.top, level == 1 ? 2 : 0)

        case let .paragraph(content):
            Text(inlineMarkdown(content))
                .font(MarrTypography.body(size: 13))
                .lineSpacing(3)

        case let .unorderedList(items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .font(MarrTypography.body(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(inlineMarkdown(item))
                            .font(MarrTypography.body(size: 13))
                            .lineSpacing(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

        case let .orderedList(items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).")
                            .font(MarrTypography.mono(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 17, alignment: .trailing)
                        Text(inlineMarkdown(item))
                            .font(MarrTypography.body(size: 13))
                            .lineSpacing(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

        case let .quote(content):
            HStack(alignment: .top, spacing: 9) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(.secondary.opacity(0.45))
                    .frame(width: 3)
                Text(inlineMarkdown(content))
                    .font(MarrTypography.body(size: 13))
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        case let .code(content):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: content)
                    .font(MarrTypography.mono(size: 12))
                    .lineSpacing(3)
                    .padding(10)
            }
            .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

        case .divider:
            Rectangle()
                .fill(.separator.opacity(0.65))
                .frame(height: 1)
                .padding(.vertical, 2)
        }
    }

    private func inlineMarkdown(_ content: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: content, options: options)) ?? AttributedString(content)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 18
        case 2: 16
        default: 14
        }
    }
}

private enum MarkdownBlock {
    case heading(level: Int, content: String)
    case paragraph(String)
    case unorderedList([String])
    case orderedList([String])
    case quote(String)
    case code(String)
    case divider
}

private enum MarkdownBlockParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.components(separatedBy: .newlines)
        var blocks: [MarkdownBlock] = []
        var index = 0

        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                index += 1
                continue
            }

            if trimmed.hasPrefix("```") {
                index += 1
                var codeLines: [String] = []
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[index])
                    index += 1
                }
                if index < lines.count {
                    index += 1
                }
                blocks.append(.code(codeLines.joined(separator: "\n")))
                continue
            }

            if let heading = heading(from: trimmed) {
                blocks.append(.heading(level: heading.level, content: heading.content))
                index += 1
                continue
            }

            if isDivider(trimmed) {
                blocks.append(.divider)
                index += 1
                continue
            }

            if unorderedItem(from: trimmed) != nil {
                var items: [String] = []
                while index < lines.count, let item = unorderedItem(from: lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append(item)
                    index += 1
                }
                blocks.append(.unorderedList(items))
                continue
            }

            if orderedItem(from: trimmed) != nil {
                var items: [String] = []
                while index < lines.count, let item = orderedItem(from: lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append(item)
                    index += 1
                }
                blocks.append(.orderedList(items))
                continue
            }

            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while index < lines.count {
                    let line = lines[index].trimmingCharacters(in: .whitespaces)
                    guard line.hasPrefix(">") else { break }
                    quoteLines.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quoteLines.joined(separator: "\n")))
                continue
            }

            var paragraphLines: [String] = []
            while index < lines.count {
                let line = lines[index].trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, !startsBlock(line) else { break }
                paragraphLines.append(line)
                index += 1
            }
            blocks.append(.paragraph(paragraphLines.joined(separator: " ")))
        }

        return blocks
    }

    private static func startsBlock(_ line: String) -> Bool {
        line.hasPrefix("```")
            || line.hasPrefix(">")
            || heading(from: line) != nil
            || unorderedItem(from: line) != nil
            || orderedItem(from: line) != nil
            || isDivider(line)
    }

    private static func heading(from line: String) -> (level: Int, content: String)? {
        let level = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level) else { return nil }
        let content = line.dropFirst(level)
        guard content.first?.isWhitespace == true else { return nil }
        return (level, content.trimmingCharacters(in: .whitespaces))
    }

    private static func unorderedItem(from line: String) -> String? {
        for prefix in ["- ", "* ", "+ "] where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        return nil
    }

    private static func orderedItem(from line: String) -> String? {
        guard let period = line.firstIndex(of: ".") else { return nil }
        let number = line[..<period]
        let remainder = line[line.index(after: period)...]
        guard Int(number) != nil, remainder.first?.isWhitespace == true else { return nil }
        return remainder.trimmingCharacters(in: .whitespaces)
    }

    private static func isDivider(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let marker = compact.first else { return false }
        return ["-", "*", "_"].contains(String(marker)) && compact.allSatisfy { $0 == marker }
    }
}

private struct TypingIndicatorView: View {
    @State private var activeDot = 0
    @State private var timer: Timer?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(.primary.opacity(index == activeDot ? 0.72 : 0.28))
                    .frame(width: 5, height: 5)
                    .offset(y: index == activeDot ? -1 : 0)
            }
        }
        .frame(height: 16)
        .onAppear {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.22, repeats: true) { _ in
                activeDot = (activeDot + 1) % 3
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }
}

private extension View {
    @ViewBuilder
    func sendCircleButton(isEnabled: Bool, color: Color, foregroundColor: Color) -> some View {
        self
            .buttonStyle(.plain)
            .foregroundStyle(isEnabled ? foregroundColor : .white)
            .background(isEnabled ? color : Color.secondary.opacity(0.46), in: Circle())
            .shadow(color: .black.opacity(isEnabled ? 0.18 : 0.06), radius: 8, x: 0, y: 4)
    }
}
