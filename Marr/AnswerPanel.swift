import AppKit
import MarrCore
import SwiftUI

enum AnswerPanelUtilityDestination {
    case history
    case settings
    case work
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
            styleMask: [.borderless, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        createdWindow.title = "Marr"
        createdWindow.isOpaque = false
        createdWindow.backgroundColor = .clear
        createdWindow.hasShadow = false
        createdWindow.isMovable = true
        createdWindow.isMovableByWindowBackground = false
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
        createdHostingView.sizingOptions = [.minSize]
        createdWindow.contentView = createdHostingView

        window = createdWindow
        initialFrame = targetFrame
        presentationStartFrame = startFrame
        createdHostingView.layoutSubtreeIfNeeded()
        createdHostingView.displayIfNeeded()
        createdWindow.contentMinSize = AnswerPanelConversationLayout.panelSize
    }

    var frame: CGRect { window.frame }

    func show(preservingFrame: CGRect? = nil) {
        if let preservingFrame {
            window.setFrame(preservingFrame, display: false)
            window.alphaValue = 1
            hasPresented = true
        }
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
        // History replaces content in-place without changing the user-selected window size.
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
    static let windowPadding: CGFloat = 0
    static let surfaceWidth: CGFloat = panelSize.width - windowPadding * 2
    static let surfaceHeight: CGFloat = panelSize.height - windowPadding * 2
    static let composerWidth: CGFloat = surfaceWidth - 64
    static let composerHeight: CGFloat = 44
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
    @ObservedObject private var workSession: CodexWorkspaceController
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
    @State private var usesCodex = false
    @State private var showsCodexTaskBrowser = false
    @State private var historySearchText = ""
    @State private var panelControlsHovered = false
    @State private var conversationTitleHovered = false
    @State private var conversationScrollMinY: CGFloat = 0
    @State private var hoveredEditTurnID: UUID?
    @State private var selectedSlashCommandIndex = 0
    @State private var dismissedSlashMenuInput: String?
    @State private var attachmentErrorMessage: String?
    @State private var attachmentButtonHovered = false
    @Namespace private var modeSelection
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @Environment(\.accessibilityReduceTransparency) private var reducesTransparency
    @AppStorage(MarrAppearanceKeys.glassSurfaces) private var usesGlassSurfaces = true
    @AppStorage(MarrBubbleColor.storageKey) private var bubbleColor = MarrBubbleColor.system.rawValue
    @AppStorage(MarrAccentColor.storageKey) private var accentColor = MarrAccentColor.system.rawValue
    @FocusState private var questionFocused: Bool
    @FocusState private var historySearchFocused: Bool

    @State private var panelWidth = AnswerPanelConversationLayout.panelSize.width
    @State private var showsWorkModelPicker = false
    private var composerWidth: CGFloat { min(720, panelWidth - 64) }
    private let assistantRevealDelay = 0.30
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
        self.session = session
        self.requestCoordinator = requestCoordinator
        self.titleCoordinator = titleCoordinator
        self.navigation = navigation
        self.actions = actions
        _historyStore = ObservedObject(wrappedValue: historyStore)
        _showsHistoryPanel = State(initialValue: navigation.request.destination == .history)
        _showsSettingsPanel = State(initialValue: navigation.request.destination == .settings)
        _usesCodex = State(initialValue: navigation.request.destination == .work)
    }

    var body: some View {
        GeometryReader { geometry in
            fixedAnswerStack
                .padding(AnswerPanelConversationLayout.windowPadding)
                .onAppear { panelWidth = geometry.size.width }
                .onChange(of: geometry.size.width) { _, width in panelWidth = width }
        }
        .frame(minWidth: AnswerPanelConversationLayout.panelSize.width,
               minHeight: AnswerPanelConversationLayout.panelSize.height)
        .onAppear {
            DispatchQueue.main.async {
                questionFocused = true
                submitInitialQuestion()
                titleCoordinator.generateIfNeeded()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            workSession.refreshModelsIfNeeded()
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
        .background(TwoFingerBackGesture(
            isEnabled: showsSettingsPanel || showsHistoryPanel || showsCodexTaskBrowser,
            onBack: navigateBack
        ))
        .font(MarrTypography.font(.body))
        .onExitCommand(perform: handleEscape)
    }

    private var fixedAnswerStack: some View {
        primarySurface
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
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
                } else if showsHistoryPanel {
                    historyContent
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else if usesCodex {
                    if showsCodexTaskBrowser {
                        codexTaskBrowser
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    } else {
                        codexContent
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                } else {
                    conversationScroll
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !showsSettingsPanel, !(usesCodex && showsCodexTaskBrowser) {
                composerFooter
            }
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .top
        )
        .marrGlassSurface(
            cornerRadius: AnswerPanelConversationLayout.surfaceCornerRadius,
            isClear: true,
            drawsBorder: usesGlassSurfaces
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: AnswerPanelConversationLayout.surfaceCornerRadius,
                style: .continuous
            )
            .stroke(.white.opacity(usesGlassSurfaces ? 0.18 : 0), lineWidth: 0.8)
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
                .font(MarrTypography.font(.secondary))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            Group {
                if showsHistoryPanel {
                    historySearchComposer
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        composerModelToolbar
                            .padding(.horizontal, 12)
                            .padding(.top, 5)
                            .padding(.bottom, 3)
                        composer
                    }
                    .frame(width: composerWidth)
                    .marrGlassSurface(
                        cornerRadius: AnswerPanelConversationLayout.composerHeight / 2,
                        isClear: true,
                        tintOpacity: 0.08
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.top, 10)
        .padding(.bottom, AnswerPanelConversationLayout.bottomInset)
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
                    .font(MarrTypography.font(.pageTitle))
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
                    .font(MarrTypography.font(.pageTitle))
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

            AnswerPanelDragRegion()
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .accessibilityHidden(true)

            if !showsSettingsPanel {
                HStack(spacing: 2) {
                    modeTab("Conversation", isWork: false)
                    modeTab("Work", isWork: true)
                }
                .padding(3)
                .background(.primary.opacity(0.045), in: Capsule())
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
            }

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

    private func modeTab(_ title: String, isWork: Bool) -> some View {
        Button {
            withAnimation(reducesMotion ? nil : .spring(response: 0.38, dampingFraction: 0.82)) {
                usesCodex = isWork
                showsHistoryPanel = false
                showsSettingsPanel = false
                showsCodexTaskBrowser = false
            }
            questionFocused = true
        } label: {
            Text(title)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .font(MarrTypography.font(.body, weight: usesCodex == isWork ? .semibold : .regular))
                .foregroundStyle(usesCodex == isWork ? .primary : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background {
                    if usesCodex == isWork {
                        modeSelectionGlass
                            .matchedGeometryEffect(id: "modeSelection", in: modeSelection)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
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
            if showsSettingsPanel { hideSettings() }
            else if showsHistoryPanel { hideHistorySearch() }
            else if showsCodexTaskBrowser { showsCodexTaskBrowser = false }
        }
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

    private var codexHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            panelControls
            if !showsCodexTaskBrowser {
                conversationTitleControl
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(height: showsCodexTaskBrowser ? 48 : conversationHeaderHeight, alignment: .topLeading)
    }

    private var codexContent: some View {
        CodexActivityTimeline(workspace: workSession)
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
    }

    private var codexTaskBrowser: some View {
        CodexTaskBrowser(workspace: workSession) {
            withAnimation(.easeOut(duration: 0.16)) {
                showsCodexTaskBrowser = false
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
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
            if usesCodex {
                withAnimation(.easeOut(duration: 0.16)) { showsCodexTaskBrowser = true }
            } else {
                showHistorySearch()
            }
        } label: {
            HStack(spacing: 7) {
                Rectangle()
                    .fill(.secondary.opacity(0.28))
                    .frame(width: 1, height: 20)

                Text(conversationDisplayTitle)
                    .font(MarrTypography.font(.title))
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
        .help(usesCodex ? "Open projects" : "Open history")
    }

    private var historySearchComposer: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(MarrTypography.font(.body, weight: .semibold))
                .foregroundStyle(selectedAccent.color.opacity(0.88))

            TextField("Search history...", text: $historySearchText)
                .textFieldStyle(.plain)
                .font(MarrTypography.font(.body, weight: .medium))
                .focused($historySearchFocused)

            if !historySearchText.isEmpty {
                Button {
                    historySearchText = ""
                    historySearchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(MarrTypography.font(.body, weight: .semibold))
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
        usesCodex ? workSession.activeTaskTitle : session.displayTitle
    }

    private func turnView(_ turn: ConversationTurn, isCompact: Bool, showsUserMessage: Bool) -> some View {
        VStack(spacing: 10) {
            if showsUserMessage {
                HStack(alignment: .bottom) {
                    Spacer(minLength: 72)
                    VStack(alignment: .trailing, spacing: 8) {
                        turnScreenshotAttachments(turn)

                        UserMessageContent(source: turn.question)
                            .font(MarrTypography.font(.body, weight: .medium))
                            .textSelection(.enabled)
                            .padding(.horizontal, 10)
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
                    .font(MarrTypography.font(.secondary, weight: .semibold))
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
                    width: composerWidth - 8,
                    alignment: .leading
                )
                .padding(.vertical, 4)
        }
    }

    private func errorMessage(_ turn: ConversationTurn) -> some View {
        VStack(spacing: 8) {
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

    private func modelControlLabel(_ name: String) -> some View {
        HStack(spacing: 5) {
            Text(name.isEmpty ? "Choose model" : name)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
        }
        .font(MarrTypography.font(.body, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    private var composerModelToolbar: some View {
        HStack(spacing: 8) {
            workModelPicker
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var workModelPicker: some View {
        Button {
            workSession.refreshModelsIfNeeded()
            showsWorkModelPicker = true
        } label: {
            modelControlLabel(workSession.selectedModelName)
        }
        .buttonStyle(.plain)
        .disabled(workSession.isRunning)
        .popover(isPresented: $showsWorkModelPicker, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                if let error = workSession.modelLoadError {
                    Text(error).font(MarrTypography.font(.secondary)).foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(workSession.availableModels, id: \.id) { model in
                            Button {
                                workSession.selectModel(model.id)
                            } label: {
                                HStack {
                                    Text(model.name)
                                    Spacer()
                                    if workSession.selectedModel == model.id {
                                        Image(systemName: "checkmark")
                                    }
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(height: min(180, CGFloat(workSession.availableModels.count) * 28))
                if !reasoningEfforts.isEmpty {
                    Divider()
                    HStack {
                        Text("Reasoning")
                        Spacer()
                        Text((workSession.selectedReasoningEffort ?? reasoningEfforts[0]).capitalized)
                            .foregroundStyle(.secondary)
                    }
                    .font(MarrTypography.font(.secondary))
                    if reasoningEfforts.count > 1 {
                        Slider(value: Binding(
                            get: { Double(reasoningEfforts.firstIndex(of: workSession.selectedReasoningEffort ?? "") ?? 0) },
                            set: { workSession.selectReasoningEffort(reasoningEfforts[Int($0.rounded())]) }
                        ), in: 0...Double(reasoningEfforts.count - 1), step: 1)
                        .controlSize(.small)
                        .accessibilityLabel("Reasoning effort")
                        .accessibilityValue((workSession.selectedReasoningEffort ?? reasoningEfforts[0]).capitalized)
                        HStack {
                            Text(reasoningEfforts[0].capitalized)
                            Spacer()
                            Text(reasoningEfforts[reasoningEfforts.count - 1].capitalized)
                        }
                        .font(MarrTypography.font(.caption))
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .font(MarrTypography.font(.body))
            .padding(10)
            .frame(width: 230)
        }
        .onAppear { workSession.refreshModelsIfNeeded() }
        .help("Model for the next message")
    }

    private var reasoningEfforts: [String] {
        let order = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
        return workSession.availableReasoningEfforts.sorted {
            (order.firstIndex(of: $0) ?? order.count) < (order.firstIndex(of: $1) ?? order.count)
        }
    }

    private var composer: some View {
        composerInput
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
                .font(.system(size: 18, weight: .regular))
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary.opacity(editingTurnID == nil ? 0.84 : 0.38))
        .background(.primary.opacity(attachmentButtonHovered ? 0.14 : 0.07), in: Circle())
        .clipShape(Circle())
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
            attachmentButton
            if editingTurnID != nil {
                Image(systemName: "pencil")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
            }

            TextField(
                editingTurnID == nil
                    ? (usesCodex ? "Ask Codex" : "Ask a follow-up")
                    : "Edit latest message",
                text: $question,
                axis: .vertical
            )
                .textFieldStyle(.plain)
                .font(MarrTypography.font(.body))
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
        .padding(.leading, 7)
        .padding(.trailing, 5)
        .padding(.vertical, 4)
        .frame(width: composerWidth)
        .frame(minHeight: AnswerPanelConversationLayout.composerHeight)
        .background {
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: AnswerPanelConversationLayout.composerHeight / 2,
                bottomTrailingRadius: AnswerPanelConversationLayout.composerHeight / 2,
                topTrailingRadius: 0,
                style: .continuous
            )
            .fill(LinearGradient(
                colors: [.clear, .primary.opacity(0.035)],
                startPoint: .top,
                endPoint: .bottom
            ))
            .allowsHitTesting(false)
        }

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

        let completion: (NSApplication.ModalResponse) -> Void = { response in
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
        let parent = (NSApp.keyWindow as? AnswerPanelWindow)
            ?? NSApp.orderedWindows.first { $0 is AnswerPanelWindow && $0.isVisible }
        panel.level = NSWindow.Level(rawValue: (parent?.level ?? .screenSaver).rawValue + 1)
        panel.isMovable = true
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.begin(completionHandler: completion)
        panel.makeKeyAndOrderFront(nil)
    }

    private var slashCommandMenu: some View {
        VStack(spacing: 2) {
            ForEach(Array(slashCommandMatches.enumerated()), id: \.element.id) { index, command in
                Button {
                    chooseSlashCommand(command)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: command.symbol)
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
        (usesCodex ? workSession.canSubmit : !session.hasLoadingTurn)
            && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        case .work:
            showsHistoryPanel = false
            showsSettingsPanel = false
            usesCodex = true
            showsCodexTaskBrowser = false
            questionFocused = true
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
        if usesCodex {
            sendToCodex()
            return
        }
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

    private func sendToCodex() {
        let request = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, workSession.canSubmit else { return }
        question = ""
        controller.submitToCodex(request, images: Array(session.images.values))
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

private struct CodexTaskBrowser: View {
    @ObservedObject var workspace: CodexWorkspaceController
    let onSelectTask: () -> Void
    @State private var expandedProjectIDs: Set<UUID> = []
    @State private var collapsedProjectIDs: Set<UUID> = []
    @State private var hoveredProjectID: UUID?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button(action: onSelectTask) {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.plain)
                    .help("Back to Work")
                    Text("Projects")
                        .font(MarrTypography.font(.pageTitle))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                    Button {
                        workspace.loadAllTaskHistory()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .disabled(workspace.isRunning || workspace.isLoadingTaskHistory || workspace.isLoadingProjects)
                    .help("Refresh projects")
                    .accessibilityLabel("Refresh projects")
                    Button {
                        if workspace.chooseWorkspace() {
                            onSelectTask()
                        }
                    } label: {
                        Label("New workspace", systemImage: "plus")
                            .font(MarrTypography.font(.secondary, weight: .medium))
                    }
                    .buttonStyle(.plain)
                }

                if workspace.isLoadingTaskHistory || workspace.isLoadingProjects {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Refreshing…")
                            .font(MarrTypography.font(.secondary))
                            .foregroundStyle(.secondary)
                    }
                }

                if workspace.savedWorkspaces.isEmpty {
                    ContentUnavailableView(
                        "No projects",
                        systemImage: "folder",
                        description: Text("Add a project to start."))
                } else {
                    ForEach(workspace.savedWorkspaces) { project in
                        projectSection(project)
                    }
                }
            }
            .padding(.top, 0)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.automatic)
    }

    private func projectSection(_ project: CodexSavedWorkspace) -> some View {
        let tasks = workspace.savedTasks.filter { $0.workspaceID == project.id }
        let isCollapsed = collapsedProjectIDs.contains(project.id)
        let isExpanded = expandedProjectIDs.contains(project.id)
        let visibleTasks = isExpanded ? tasks : Array(tasks.prefix(5))
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeOut(duration: 0.16)) {
                        if isCollapsed {
                            collapsedProjectIDs.remove(project.id)
                        } else {
                            collapsedProjectIDs.insert(project.id)
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .font(.system(size: 13, weight: .medium))
                        Text(project.name)
                            .font(MarrTypography.font(.body, weight: .medium))
                    }
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                HStack(spacing: 3) {
                    Menu {
                        Button("Refresh", systemImage: "arrow.clockwise") {
                            workspace.loadTaskHistory(for: project)
                        }
                        .disabled(workspace.isRunning || workspace.isLoadingTaskHistory)
                        Button(project.isPinned ? "Unpin project" : "Pin project") {
                            workspace.toggleWorkspacePinned(project)
                        }
                        Button("Show in Finder") {
                            workspace.showWorkspaceInFinder(project)
                        }
                        Button("Archive chats") {
                            workspace.archiveChats(in: project)
                        }
                        Divider()
                        Button("Remove", role: .destructive) {
                            workspace.removeWorkspace(project)
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 22, height: 22)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .foregroundStyle(.secondary)

                    Button {
                        workspace.selectWorkspace(project)
                        onSelectTask()
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(workspace.isRunning)
                    .help("New chat in \(project.name)")
                }
                .opacity(hoveredProjectID == project.id ? 1 : 0)
                .allowsHitTesting(hoveredProjectID == project.id)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                hoveredProjectID == project.id ? Color.primary.opacity(0.08) : .clear,
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .onHover { isHovered in
                hoveredProjectID = isHovered ? project.id : nil
            }

            if !isCollapsed, tasks.isEmpty {
                Text("No chats")
                    .font(MarrTypography.font(.secondary))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 26)
            } else if !isCollapsed {
                ForEach(visibleTasks) { task in
                    taskRow(task)
                }
                if tasks.count > 5 {
                    Button(isExpanded ? "Show less" : "Show \(tasks.count - 5) more") {
                        withAnimation(.easeOut(duration: 0.16)) {
                            if isExpanded {
                                expandedProjectIDs.remove(project.id)
                            } else {
                                expandedProjectIDs.insert(project.id)
                            }
                        }
                    }
                    .font(MarrTypography.font(.secondary, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 26)
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func taskRow(_ task: CodexSavedTask) -> some View {
        let isSelected = workspace.workbench.selectedTaskID == task.id
        return Button {
            workspace.selectTask(task)
            onSelectTask()
        } label: {
            HStack(spacing: 8) {
                Text(task.title)
                    .font(MarrTypography.font(.body, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if task.state == .running {
                    Circle()
                        .fill(.blue)
                        .frame(width: 9, height: 9)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                isSelected ? Color.primary.opacity(0.09) : .clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 26)
    }
}

private struct CodexActivityTimeline: View {
    @ObservedObject var workspace: CodexWorkspaceController
    @State private var expandedActivityIDs: Set<UUID> = []
    @State private var expandedTurnIDs: Set<UUID> = []
    @State private var expandedFileChangeTurnIDs: Set<UUID> = []
    @State private var reviewedFileChangeTurnIDs: Set<UUID> = []
    @State private var revertedFileChangeTurnIDs: Set<UUID> = []
    @AppStorage(MarrAccentColor.storageKey) private var accentColor = MarrAccentColor.system.rawValue

    private struct TurnGroup: Identifiable {
        let id: UUID
        let userMessage: CodexActivity
        let activities: [CodexActivity]
    }

    private struct FileChangeSummary: Identifiable {
        let path: String
        let additions: Int
        let deletions: Int

        var id: String { path }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if workspace.isRemoteTaskActive {
                Text("Running in Codex").font(MarrTypography.font(.secondary)).foregroundStyle(.secondary)
            }
            if let approval = workspace.approvalRequest {
                approvalCard(approval)
            }

            if turnGroups.isEmpty, !workspace.isRunning {
                ContentUnavailableView(
                    "Ready",
                    systemImage: "hammer",
                    description: Text("What would you like to do?"))
                    .font(MarrTypography.font(.secondary))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if turnGroups.isEmpty, workspace.isRunning {
                            workingMessage
                        }

                        ForEach(turnGroups) { turn in
                            VStack(alignment: .leading, spacing: 9) {
                                userMessageBubble(turn.userMessage.detail)
                                processingDisclosure(for: turn)

                                if expandedTurnIDs.contains(turn.id) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        ForEach(thinkingMessages(in: turn)) { message in
                                            thinkingMessage(message)
                                        }

                                        ForEach(nonFileTraceActivities(in: turn)) { activity in
                                            activityRow(activity)
                                        }

                                        fileChangeSummary(for: turn)
                                    }
                                    .transition(.opacity)
                                }

                                if finalAgentMessage(in: turn) != nil || workspace.isRunning {
                                    Rectangle()
                                        .fill(.separator.opacity(0.55))
                                        .frame(height: 1)
                                        .padding(.top, 2)
                                }

                                if let finalMessage = finalAgentMessage(in: turn) {
                                    agentMessage(finalMessage)
                                    fileChangeReviewCard(for: turn)
                                }

                                if finalAgentMessage(in: turn) == nil,
                                   workspace.isRunning,
                                   turn.id == turnGroups.last?.id,
                                   !workspace.latestAgentMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    MarkdownResponseView(source: workspace.latestAgentMessage)
                                        .textSelection(.enabled)
                                        .padding(.horizontal, 2)
                                }

                                ForEach(errorActivities(in: turn)) { activity in
                                    errorCard(activity)
                                }
                            }
                        }

                        ForEach(unassignedErrors) { activity in
                            errorCard(activity)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.automatic)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var turnGroups: [TurnGroup] {
        var groups: [TurnGroup] = []
        var pendingActivities: [CodexActivity] = []
        var currentUserMessage: CodexActivity?
        var currentActivities: [CodexActivity] = []

        for activity in workspace.activities {
            if activity.kind == .user,
               !activity.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let currentUserMessage {
                    groups.append(TurnGroup(
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
            groups.append(TurnGroup(
                id: currentUserMessage.id,
                userMessage: currentUserMessage,
                activities: currentActivities
            ))
        }
        return groups
    }

    private func agentMessages(in turn: TurnGroup) -> [CodexActivity] {
        turn.activities.filter {
            $0.kind == .message && !$0.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Codex streams progress/commentary messages before its final answer. The final
    /// message is the last agent message in a turn; earlier messages belong to the
    /// turn's collapsible thinking trace.
    private func finalAgentMessage(in turn: TurnGroup) -> CodexActivity? {
        agentMessages(in: turn).last
    }

    private func traceActivities(in turn: TurnGroup) -> [CodexActivity] {
        let finalMessageID = finalAgentMessage(in: turn)?.id
        return turn.activities.filter { activity in
            activity.id != finalMessageID &&
                activity.kind != .user &&
                activity.kind != .error &&
                activity.title != "Codex task completed"
        }
    }

    private func thinkingMessages(in turn: TurnGroup) -> [CodexActivity] {
        traceActivities(in: turn).filter { $0.kind == .message }
    }

    private func nonFileTraceActivities(in turn: TurnGroup) -> [CodexActivity] {
        traceActivities(in: turn).filter {
            $0.kind != .message && $0.kind != .fileChange
        }
    }

    private func fileChanges(in turn: TurnGroup) -> [FileChangeSummary] {
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

        return totals
            .map { FileChangeSummary(path: $0.key, additions: $0.value.additions, deletions: $0.value.deletions) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func reversibleDiff(in turn: TurnGroup) -> String? {
        traceActivities(in: turn)
            .last(where: { $0.kind == .fileChange && $0.detail.contains("diff --git ") })?
            .detail
    }

    private func errorActivities(in turn: TurnGroup) -> [CodexActivity] {
        turn.activities.filter { $0.kind == .error }
    }

    private var unassignedErrors: [CodexActivity] {
        let assignedErrorIDs = Set(turnGroups.flatMap { errorActivities(in: $0).map(\.id) })
        return workspace.activities.filter { $0.kind == .error && !assignedErrorIDs.contains($0.id) }
    }

    private var workingMessage: some View {
        HStack(spacing: 9) {
            ProgressView().controlSize(.small)
            Text("Codex is inspecting the workspace and preparing a response…")
                .font(MarrTypography.font(.secondary))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    private func userMessageBubble(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 48)
            UserMessageContent(source: text)
                .font(MarrTypography.font(.body))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(selectedAccent.color.opacity(0.15), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    @ViewBuilder
    private func processingDisclosure(for turn: TurnGroup) -> some View {
        let trace = traceActivities(in: turn)
        if let processingSeconds = turn.activities.compactMap(\.processingSeconds).last {
            if trace.isEmpty {
                Text("Processed \(formattedDuration(processingSeconds))")
                    .font(MarrTypography.font(.secondary, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            } else {
                Button {
                    withAnimation(.easeOut(duration: 0.16)) {
                        if expandedTurnIDs.contains(turn.id) {
                            expandedTurnIDs.remove(turn.id)
                        } else {
                            expandedTurnIDs.insert(turn.id)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("Processed \(formattedDuration(processingSeconds))")
                            .font(MarrTypography.font(.secondary, weight: .medium))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(expandedTurnIDs.contains(turn.id) ? 90 : 0))
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } else if workspace.isRunning, turn.id == turnGroups.last?.id {
            HStack(spacing: 7) {
                ProgressView().controlSize(.mini)
                Text("Thinking…")
                    .font(MarrTypography.font(.secondary, weight: .medium))
                Spacer(minLength: 0)
                Button("Stop") { workspace.interrupt() }
                    .controlSize(.mini)
            }
            .foregroundStyle(.secondary)
            .padding(.leading, 2)
        }
    }

    private func agentMessage(_ message: CodexActivity) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            MarkdownResponseView(source: message.detail)
                .textSelection(.enabled)
                .padding(.horizontal, 2)
        }
    }

    private func thinkingMessage(_ message: CodexActivity) -> some View {
        MarkdownResponseView(source: message.detail)
            .textSelection(.enabled)
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
    }

    @ViewBuilder
    private func fileChangeSummary(for turn: TurnGroup) -> some View {
        let files = fileChanges(in: turn)
        if !files.isEmpty {
            let isExpanded = expandedFileChangeTurnIDs.contains(turn.id)
            let additions = files.reduce(0) { $0 + $1.additions }
            let deletions = files.reduce(0) { $0 + $1.deletions }
            VStack(alignment: .leading, spacing: 5) {
                Button {
                    withAnimation(.easeOut(duration: 0.16)) {
                        if isExpanded {
                            expandedFileChangeTurnIDs.remove(turn.id)
                        } else {
                            expandedFileChangeTurnIDs.insert(turn.id)
                        }
                    }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: "pencil")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 14)
                        Text("Edited \(files.count) file\(files.count == 1 ? "" : "s")")
                            .font(MarrTypography.font(.secondary, weight: .medium))
                        Text("+\(additions)")
                            .font(MarrTypography.font(.code, weight: .medium))
                            .foregroundStyle(.green)
                        Text("-\(deletions)")
                            .font(MarrTypography.font(.code, weight: .medium))
                            .foregroundStyle(.red)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isExpanded {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(files) { file in
                            HStack(spacing: 7) {
                                Text(file.path)
                                    .font(MarrTypography.font(.code))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                                Text("+\(file.additions)")
                                    .foregroundStyle(.green)
                                Text("-\(file.deletions)")
                                    .foregroundStyle(.red)
                            }
                            .font(MarrTypography.font(.code, weight: .medium))
                        }
                    }
                    .padding(.leading, 21)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
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
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 11) {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 46, height: 46)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Edited \(files.count) file\(files.count == 1 ? "" : "s")")
                            .font(MarrTypography.font(.body, weight: .semibold))
                        HStack(spacing: 6) {
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
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(files) { file in
                            HStack(spacing: 7) {
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
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.separator.opacity(0.58), lineWidth: 1)
            )
        }
    }

    private func formattedDuration(_ totalSeconds: Int) -> String {
        if totalSeconds < 60 { return "\(totalSeconds)s" }
        return "\(totalSeconds / 60)m \(totalSeconds % 60)s"
    }

    private func approvalCard(_ approval: CodexApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(approval.kind.title, systemImage: "hand.raised.fill")
                .font(MarrTypography.font(.secondary, weight: .semibold))
                .foregroundStyle(.orange)
            if let reason = approval.reason, !reason.isEmpty {
                Text(reason)
                    .font(MarrTypography.font(.secondary))
                    .foregroundStyle(.secondary)
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

    private func errorCard(_ activity: CodexActivity) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(activity.title, systemImage: "exclamationmark.triangle.fill")
                .font(MarrTypography.font(.secondary, weight: .semibold))
                .foregroundStyle(.red)
            if !activity.detail.isEmpty {
                Text(activity.detail)
                    .font(MarrTypography.font(.secondary))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func activityRow(_ activity: CodexActivity) -> some View {
        let isExpanded = expandedActivityIDs.contains(activity.id)
        return VStack(alignment: .leading, spacing: 5) {
            Button {
                if isExpanded {
                    expandedActivityIDs.remove(activity.id)
                } else {
                    expandedActivityIDs.insert(activity.id)
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: activity.kind.symbolName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(color(for: activity.kind))
                        .frame(width: 14)
                    Text(activity.kind == .message ? "Progress update" : activity.title)
                        .font(MarrTypography.font(.code, weight: .semibold))
                        .lineLimit(isExpanded ? nil : 1)
                    Spacer(minLength: 0)
                    if !activity.isComplete {
                        ProgressView().controlSize(.mini)
                    } else if !activity.detail.isEmpty {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded, !activity.detail.isEmpty {
                Group {
                    if activity.kind == .plan {
                        MarkdownResponseView(source: activity.detail)
                            .font(MarrTypography.font(.secondary))
                    } else {
                        Text(activity.detail)
                            .font(MarrTypography.font(.code))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 21)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
    }

    private func color(for kind: CodexActivity.Kind) -> Color {
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
                .font(MarrTypography.font(.body, weight: .semibold))
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
                    .font(MarrTypography.font(.body, weight: isCurrent ? .semibold : .medium))
                    .foregroundStyle(.primary.opacity(isCurrent ? 0.96 : 0.82))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 12)

                Text(dateLabel(for: conversation.updatedAt))
                    .font(MarrTypography.font(.body, weight: .medium))
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

private struct UserMessageContent: View {
    let source: String

    var body: some View {
        let presentation = UserMessagePresentation(source)
        VStack(alignment: .leading, spacing: 6) {
            if let details = presentation.attachmentDetails, !details.isEmpty {
                DisclosureGroup {
                    Text(verbatim: details)
                        .font(MarrTypography.font(.code))
                        .textSelection(.enabled)
                } label: {
                    Label("Attachments", systemImage: "paperclip")
                        .font(MarrTypography.font(.secondary))
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            MarkdownResponseView(source: presentation.body, compact: true)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct MarkdownResponseView: View {
    let source: String
    var compact = false

    private var blocks: [MarkdownBlock] {
        MarkdownBlockParser.parse(source)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 9) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: compact ? nil : .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, content):
            Text(inlineMarkdown(content))
                .font(.system(size: compact ? 13 : headingSize(level), weight: .semibold))
                .lineSpacing(2)
                .padding(.top, level == 1 ? 2 : 0)

        case let .paragraph(content):
            Text(inlineMarkdown(content))
                .font(MarrTypography.font(.body))
                .lineSpacing(compact ? 1 : 3)

        case let .unorderedList(items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .font(MarrTypography.font(.body))
                            .foregroundStyle(.secondary)
                        Text(inlineMarkdown(item))
                            .font(MarrTypography.font(.body))
                            .lineSpacing(compact ? 1 : 3)
                            .frame(maxWidth: compact ? nil : .infinity, alignment: .leading)
                    }
                }
            }

        case let .orderedList(items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).")
                            .font(MarrTypography.font(.body))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 17, alignment: .trailing)
                        Text(inlineMarkdown(item))
                            .font(MarrTypography.font(.body))
                            .lineSpacing(compact ? 1 : 3)
                            .frame(maxWidth: compact ? nil : .infinity, alignment: .leading)
                    }
                }
            }

        case let .quote(content):
            HStack(alignment: .top, spacing: 9) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(.secondary.opacity(0.45))
                    .frame(width: 3)
                Text(inlineMarkdown(content))
                    .font(MarrTypography.font(.body))
                    .foregroundStyle(.secondary)
                    .lineSpacing(compact ? 1 : 3)
                    .frame(maxWidth: compact ? nil : .infinity, alignment: .leading)
            }

        case let .code(content):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: content)
                    .font(MarrTypography.font(.code))
                    .lineSpacing(compact ? 1 : 3)
                    .padding(10)
            }
            .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

        case let .table(headers, rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
                    GridRow {
                        ForEach(headers.indices, id: \.self) { index in
                            Text(inlineMarkdown(headers[index]))
                                .font(MarrTypography.font(.body, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 7)
                        }
                    }
                    .background(.primary.opacity(0.055))

                    ForEach(rows.indices, id: \.self) { rowIndex in
                        let row = rows[rowIndex]
                        GridRow {
                            ForEach(headers.indices, id: \.self) { columnIndex in
                                Text(inlineMarkdown(columnIndex < row.count ? row[columnIndex] : ""))
                                    .font(MarrTypography.font(.body))
                                    .padding(.vertical, 7)
                            }
                        }
                        .background(rowIndex.isMultiple(of: 2) ? Color.primary.opacity(0.018) : .clear)
                    }
                }
                .padding(.horizontal, 10)
                .frame(minWidth: 260, alignment: .leading)
            }
            .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(.separator.opacity(0.6), lineWidth: 1)
            )

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
    case table(headers: [String], rows: [[String]])
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

            if index + 1 < lines.count,
               let headers = tableCells(from: lines[index]),
               isTableDivider(lines[index + 1]) {
                index += 2
                var rows: [[String]] = []
                while index < lines.count, let row = tableCells(from: lines[index]) {
                    rows.append(row)
                    index += 1
                }
                blocks.append(.table(headers: headers, rows: rows))
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
            || tableCells(from: line) != nil
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

    private static func tableCells(from line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return nil }
        let withoutOuterPipes = trimmed
            .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
        let cells = withoutOuterPipes
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return cells.count >= 2 ? cells : nil
    }

    private static func isTableDivider(_ line: String) -> Bool {
        guard let cells = tableCells(from: line) else { return false }
        return cells.allSatisfy { cell in
            let marker = cell.replacingOccurrences(of: ":", with: "")
            return marker.count >= 3 && marker.allSatisfy { $0 == "-" }
        }
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

/// Observes trackpad navigation without replacing vertical scrolling or mouse dragging.
private struct TwoFingerBackGesture: NSViewRepresentable {
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
private struct AnswerPanelDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}
