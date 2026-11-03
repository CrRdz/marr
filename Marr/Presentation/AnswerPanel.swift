import AppKit
import Combine
import MarrCore
import QuartzCore
import SwiftUI

enum AnswerPanelUtilityDestination {
    case conversation
    case history
    case settings
    case aiModels
    case work
    case codex
}

struct AnswerPanelSidebarPresentation {
    var layout: AnswerPanelSidebarLayout
    var searchText: String
    var visibleConversationID: UUID? = nil
    var knownWorkspaceIDs: Set<UUID> = []
    var collapsedWorkspaceIDs: Set<UUID> = []
    var expandedWorkspaceIDs: Set<UUID> = []
    var isLocalHistoryExpanded = true
}

@MainActor
final class AnswerPanelNavigation: ObservableObject {
    @Published var isFullScreen = false
    struct Request: Equatable {
        let id = UUID()
        let destination: AnswerPanelUtilityDestination?
    }

    @Published private(set) var request: Request
    @Published private(set) var isHistoryExpanded: Bool
    @Published var historySearchText: String
    let historyScrollPosition = MarrHistoryScrollPosition()
    var historyVisibleConversationID: UUID? {
        get { historyScrollPosition.visibleID }
        set { historyScrollPosition.visibleID = newValue }
    }
    @Published var sidebarRevealWidth: CGFloat
    @Published var sidebarCanvasWidth: CGFloat? = nil
    @Published var sidebarWindowMotion: AnswerPanelSidebarWindowMotion? = nil
    @Published var animatesSidebar = false
    private(set) var knownWorkspaceIDs: Set<UUID>
    @Published var collapsedWorkspaceIDs: Set<UUID>
    @Published var expandedWorkspaceIDs: Set<UUID>
    @Published var isLocalHistoryExpanded: Bool
    @Published var isPresented = false
    @Published var section: MarrPanelSection = .chats
    var onHistoryExpansion: ((Bool) -> Void)?
    var persistDraft: (() -> Void)?
#if DEBUG
    var contentLayoutWidths: [CGFloat] = []
#endif

    func recordContentLayoutWidth(_ width: CGFloat) {
#if DEBUG
        if contentLayoutWidths.last != width { contentLayoutWidths.append(width) }
#endif
    }

    init(initialDestination: AnswerPanelUtilityDestination?, sidebar: AnswerPanelSidebarPresentation?, workspaceIDs: Set<UUID>) {
        request = Request(destination: initialDestination)
        isHistoryExpanded = sidebar?.layout.isExpanded ?? false
        historySearchText = sidebar?.searchText ?? ""
        sidebarRevealWidth = sidebar?.layout.isExpanded == true ? AnswerPanelSidebarLayout.sidebarWidth : 0
        knownWorkspaceIDs = workspaceIDs.union(sidebar?.knownWorkspaceIDs ?? [])
        collapsedWorkspaceIDs = (sidebar?.collapsedWorkspaceIDs ?? [])
            .union(workspaceIDs.subtracting(sidebar?.knownWorkspaceIDs ?? [])
                .subtracting(sidebar?.expandedWorkspaceIDs ?? []))
        expandedWorkspaceIDs = sidebar?.expandedWorkspaceIDs ?? []
        isLocalHistoryExpanded = sidebar?.isLocalHistoryExpanded ?? true
        historyVisibleConversationID = sidebar?.visibleConversationID
    }

    func registerWorkspaces(_ ids: Set<UUID>) {
        let added = ids.subtracting(knownWorkspaceIDs)
        knownWorkspaceIDs.formUnion(ids)
        if !added.isEmpty { collapsedWorkspaceIDs.formUnion(added) }
    }

    func setHistoryExpanded(_ expanded: Bool) {
        guard isHistoryExpanded != expanded else { return }
        isHistoryExpanded = expanded
        onHistoryExpansion?(expanded)
    }

    func show(_ destination: AnswerPanelUtilityDestination) {
        request = Request(destination: destination)
    }
}

@MainActor
final class AnswerPanelController {
    private let window: AnswerPanelWindow
    private var session: ConversationSession
    private var requestCoordinator: ConversationRequestCoordinator
    private var titleCoordinator: ConversationTitleCoordinator
    private let initialFrame: CGRect
    private let presentationStartFrame: CGRect
    private let navigation: AnswerPanelNavigation
    private var hasPresented = false
    private var didApplyInitialDestination = false
    private let collapsedPanelSize = MarrPanelShellLayout.windowSize
    private var sidebarLayout: AnswerPanelSidebarLayout
    private var sidebarCompletionTask: Task<Void, Never>?
    private var sidebarTransitionGeneration = 0
    private var sidebarTargetFrame: CGRect?
    private weak var workspace: RuntimeWorkspaceController?
    private var clearHostedContent: (() -> Void)?
    private weak var hostingView: NSHostingView<AnyView>?

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
        initialDestination: AnswerPanelUtilityDestination? = nil,
        sidebarPresentation: AnswerPanelSidebarPresentation? = nil
    ) {
        createdSession.setArchiveHandler(persistImmediately: persistImmediately) { [weak historyStore] archive in
            historyStore?.save(archive)
        }
        session = createdSession
        workspace = controller.codexWorkspace
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
        sidebarLayout = sidebarPresentation?.layout ?? AnswerPanelSidebarLayout()
        let createdNavigation = AnswerPanelNavigation(initialDestination: initialDestination, sidebar: sidebarPresentation,
            workspaceIDs: Set(controller.codexWorkspace.savedWorkspaces.map(\.id)))
        navigation = createdNavigation
        let panelSize = AnswerPanelWindow.frameRect(
            forContentRect: CGRect(origin: .zero, size: collapsedPanelSize),
            styleMask: AnswerPanelWindow.standardStyleMask
        ).size
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
        let startContentRect = AnswerPanelWindow.contentRect(
            forFrameRect: startFrame, styleMask: AnswerPanelWindow.standardStyleMask)
        let createdWindow = AnswerPanelWindow(contentRect: startContentRect)
        createdWindow.title = "Marr"
        createdWindow.isOpaque = false
        createdWindow.backgroundColor = .clear
        createdWindow.hasShadow = false
        createdWindow.isMovable = true
        createdWindow.isMovableByWindowBackground = false
        createdWindow.isReleasedWhenClosed = false
        createdWindow.acceptsMouseMovedEvents = true
        createdWindow.ignoresMouseEvents = false
        let createdHostingView = NSHostingView(
            rootView: AnyView(AnswerPanelView(
                controller: controller,
                session: createdSession,
                historyStore: historyStore,
                requestCoordinator: createdRequestCoordinator,
                titleCoordinator: createdTitleCoordinator,
                navigation: createdNavigation,
                actions: AnswerPanelActions(
                    close: { [weak controller] in controller?.dismissCaptureSession() },
                    openHistoryConversation: { [weak controller] conversation in
                        controller?.openHistoryConversation(conversation)
                    }
                )
            )
            .marrPreferredColorScheme().ignoresSafeArea())
        )
        hostingView = createdHostingView
        clearHostedContent = { [weak createdHostingView] in
            createdHostingView?.rootView = AnyView(EmptyView())
            createdHostingView?.layoutSubtreeIfNeeded()
        }
        createdHostingView.sizingOptions = [.minSize]
        createdWindow.contentView = AnswerPanelContentView(
            frame: CGRect(origin: .zero, size: startContentRect.size),
            hostedView: createdHostingView
        )

        window = createdWindow
        initialFrame = targetFrame
        presentationStartFrame = createdWindow.frame
        createdHostingView.layoutSubtreeIfNeeded()
        createdHostingView.displayIfNeeded()
        createdWindow.contentMinSize = MarrPanelShellLayout.windowSize
        createdNavigation.onHistoryExpansion = { [weak self] expanded in
            self?.resizeForHistory(expanded)
        }
        createdWindow.onFullScreenChanged = { [weak createdNavigation] isFullScreen in
            createdNavigation?.isFullScreen = isFullScreen
        }
        createdWindow.prepareForUserGeometryChange = { [weak self] in
            self?.finishSidebarTransition()
        }
        createdWindow.onCloseRequested = { [weak controller] in controller?.dismissCaptureSession() }
        createdWindow.onMiniaturize = { [weak self] in
            self?.navigation.isPresented = false
            self?.workspace?.setHistorySyncVisible(false)
        }
        createdWindow.onDeminiaturize = { [weak self] in
            self?.navigation.isPresented = true
            self?.session.requestFocus()
        }
    }

    /// Swap the conversation tree while retaining the native window and sidebar state.
    func replaceConversation(_ nextSession: ConversationSession, controller: MarrController,
                             historyStore: ConversationHistoryStore) {
        flushComposerDraft()
        requestCoordinator.cancel()
        titleCoordinator.cancel()
        navigation.persistDraft = nil
        window.makeFirstResponder(nil)
        // Retire the old SwiftUI graph before installing the next conversation;
        // otherwise pending transitions can retain its session and subscriptions.
        clearHostedContent?()
        navigation.persistDraft = nil
        nextSession.setArchiveHandler(persistImmediately: false) { [weak historyStore] archive in
            historyStore?.save(archive)
        }
        session = nextSession
        requestCoordinator = ConversationRequestCoordinator(controller: controller, session: nextSession)
        titleCoordinator = ConversationTitleCoordinator(controller: controller, session: nextSession)
        navigation.section = .chats
        navigation.show(.conversation)
        hostingView?.rootView = AnyView(AnswerPanelView(
            controller: controller, session: nextSession, historyStore: historyStore,
            requestCoordinator: requestCoordinator, titleCoordinator: titleCoordinator,
            navigation: navigation,
            actions: AnswerPanelActions(
                close: { [weak controller] in controller?.dismissCaptureSession() },
                openHistoryConversation: { [weak controller] in controller?.openHistoryConversation($0) }
            )
        ).id(nextSession.id).marrPreferredColorScheme().ignoresSafeArea())
        nextSession.requestFocus()
    }

    func invalidateDeletedConversations(_ ids: Set<UUID>) {
        guard ids.contains(session.id) else { return }
        session.markDeleted()
        requestCoordinator.cancel()
        titleCoordinator.cancel()
    }

    var frame: CGRect { window.frame }

    var sidebarPresentation: AnswerPanelSidebarPresentation {
        AnswerPanelSidebarPresentation(layout: sidebarLayout, searchText: navigation.historySearchText,
                                       visibleConversationID: navigation.historyVisibleConversationID,
                                       knownWorkspaceIDs: navigation.knownWorkspaceIDs,
                                       collapsedWorkspaceIDs: navigation.collapsedWorkspaceIDs,
                                       expandedWorkspaceIDs: navigation.expandedWorkspaceIDs,
                                       isLocalHistoryExpanded: navigation.isLocalHistoryExpanded)
    }

    func show(preservingFrame: CGRect? = nil) {
        if let preservingFrame {
            window.setFrame(preservingFrame, display: false)
            updateMinimumSize()
            window.alphaValue = 1
            hasPresented = true
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        navigation.isPresented = true
        guard !hasPresented else {
            applyInitialHistoryDestination()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        hasPresented = true
        window.alphaValue = 0
        window.setFrame(initialFrame, display: false)
        applyInitialHistoryDestination()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.allowsImplicitAnimation = true
            window.animator().alphaValue = 1
        }
    }

    func minimize() {
        window.performMiniaturize(nil)
    }

    func restore() {
        navigation.isPresented = true
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        session.requestFocus()
    }

    func show(_ destination: AnswerPanelUtilityDestination) {
        navigation.show(destination)
        restore()
    }

    func close() {
        navigation.isPresented = false
        workspace?.setHistorySyncVisible(false)
        flushComposerDraft()
        navigation.persistDraft = nil
        requestCoordinator.cancel()
        titleCoordinator.cancel()
        window.makeFirstResponder(nil)
        clearHostedContent?()
        clearHostedContent = nil
        window.close()
        // AppKit can retain a closed window for a run-loop pass.
        // Release its hosting tree now, including subscriptions to history.
        window.contentView = nil
        navigation.persistDraft = nil
    }

    func flushComposerDraft() {
        finishSidebarTransition()
        navigation.persistDraft?()
    }

    func setHistoryExpanded(_ expanded: Bool) {
        navigation.setHistoryExpanded(expanded)
    }

    private var visibleScreenFrame: CGRect {
        window.screen?.visibleFrame
            ?? NSScreen.screens.first(where: { $0.visibleFrame.intersects(window.frame) })?.visibleFrame
            ?? window.frame.insetBy(dx: -AnswerPanelSidebarLayout.sidebarWidth, dy: 0)
    }

    private func resizeForHistory(_ expanded: Bool) {
        (window.contentView as? AnswerPanelContentView)?.resizeOverlay.cancelResize()
        let logicalFrame = sidebarTargetFrame ?? window.frame
        let displayedReveal = navigation.sidebarWindowMotion?.revealWidth(at: window.frame.width)
            ?? navigation.sidebarRevealWidth
        sidebarCompletionTask?.cancel()
        sidebarTransitionGeneration += 1
        let generation = sidebarTransitionGeneration
        let proposedFrame = MarrPanelShellLayout.windowFrame(sidebarLayout.setExpanded(expanded,
            frame: MarrPanelShellLayout.contentFrame(logicalFrame),
            visibleFrame: MarrPanelShellLayout.contentFrame(visibleScreenFrame)))
        // Full-screen geometry belongs to AppKit; only reveal the sidebar inside it.
        let nextFrame = window.styleMask.contains(.fullScreen) ? window.frame : proposedFrame
        sidebarTargetFrame = nextFrame
        let animated = window.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        // Publish only the destination. Text, editor and scroll layout use this
        // fixed canvas while the system animates the lightweight translations.
        let changesWidth = abs(nextFrame.width - window.frame.width) > 0.5
        navigation.sidebarWindowMotion = animated && changesWidth
            ? AnswerPanelSidebarWindowMotion(fromWidth: window.frame.width, toWidth: nextFrame.width,
                fromRevealWidth: displayedReveal,
                toRevealWidth: expanded ? AnswerPanelSidebarLayout.sidebarWidth : 0)
            : nil
        navigation.animatesSidebar = animated && !changesWidth
        navigation.sidebarCanvasWidth = nextFrame.width
        navigation.sidebarRevealWidth = expanded ? AnswerPanelSidebarLayout.sidebarWidth : 0
        guard animated else {
            finishSidebarTransition()
            return
        }
        window.contentMinSize = collapsedPanelSize
        if nextFrame != window.frame {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = AnswerPanelSidebarMotion.duration
                context.timingFunction = AnswerPanelSidebarMotion.timingFunction
                window.animator().setFrame(nextFrame, display: false)
            } completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let self, generation == self.sidebarTransitionGeneration else { return }
                    self.finishSidebarTransition()
                }
            }
            return
        }
        // One completion, not a frame timer. Neither layout nor drawing is
        // forced during the transition; AppKit/SwiftUI own the display cadence.
        sidebarCompletionTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(AnswerPanelSidebarMotion.duration)) }
            catch { return }
            guard let self, generation == self.sidebarTransitionGeneration else { return }
            self.finishSidebarTransition()
        }
    }

    private func finishSidebarTransition() {
        sidebarCompletionTask?.cancel()
        sidebarCompletionTask = nil
        sidebarTransitionGeneration += 1
        guard let target = sidebarTargetFrame else { return }
        sidebarTargetFrame = nil
        // Replace any in-flight native resize when dragging, minimizing or
        // transferring a panel. Old completion tasks cannot finish a newer one.
        if window.frame != target {
            if window.isVisible {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    window.animator().setFrame(target, display: false)
                }
            } else {
                window.setFrame(target, display: false)
            }
        }
        navigation.animatesSidebar = false
        navigation.sidebarWindowMotion = nil
        navigation.sidebarCanvasWidth = nil
        updateMinimumSize()
    }

    private func updateMinimumSize() {
        window.contentMinSize = NSSize(
            width: sidebarLayout.minimumWidth(for: MarrPanelShellLayout.contentFrame(visibleScreenFrame)) + MarrPanelShellLayout.railWidth,
            height: AnswerPanelConversationLayout.panelSize.height
        )
    }

    private func applyInitialHistoryDestination() {
        guard !didApplyInitialDestination else { return }
        didApplyInitialDestination = true
        switch navigation.request.destination {
        case .history: setHistoryExpanded(true)
        case .work, .codex, .settings: setHistoryExpanded(false)
        default: break
        }
    }

    func appendScreenshot(_ image: PickedImage) {
        navigation.isPresented = true
        session.appendScreenshot(image)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

#if DEBUG
    var windowForTesting: NSWindow {
        window
    }

    var sidebarContentLayoutWidthsForTesting: [CGFloat] { navigation.contentLayoutWidths }
    var sectionForTesting: MarrPanelSection {
        get { navigation.section }
        set { navigation.section = newValue }
    }

    func resetSidebarLayoutDiagnosticsForTesting() { navigation.contentLayoutWidths.removeAll() }

    func setSidebarWindowMotionForTesting(_ motion: AnswerPanelSidebarWindowMotion?) {
        navigation.sidebarWindowMotion = motion
        navigation.sidebarCanvasWidth = motion?.toWidth
        if motion != nil { window.contentMinSize = collapsedPanelSize }
        else { updateMinimumSize() }
    }

    /// Inspect intermediate layouts without presenting a window or starting
    /// its display-driven transition in a test host.
    func setSidebarRevealWidthForTesting(_ width: CGFloat) {
        navigation.sidebarRevealWidth = min(AnswerPanelSidebarLayout.sidebarWidth, max(0, width))
        window.contentView?.layoutSubtreeIfNeeded()
    }
#endif

}

final class AnswerPanelWindow: NSWindow, NSWindowDelegate {
    static let standardStyleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    var prepareForUserGeometryChange: (() -> Void)?
    var onFullScreenChanged: ((Bool) -> Void)?
    var onCloseRequested: (() -> Void)?
    var onMiniaturize: (() -> Void)?
    var onDeminiaturize: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: Self.standardStyleMask,
                   backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        titlebarSeparatorStyle = .none
        // Let AppKit position and track the traffic lights as one native group.
        // An empty, transparent toolbar aligns them with our existing content toolbar.
        let nativeToolbar = NSToolbar(identifier: "MarrWindowChrome")
        nativeToolbar.displayMode = .iconOnly
        nativeToolbar.allowsUserCustomization = false
        toolbar = nativeToolbar
        toolbarStyle = .unified
        level = .normal
        // A primary, managed window participates in Stage Manager and Spaces.
        collectionBehavior = [.managed, .primary, .fullScreenPrimary]
        isReleasedWhenClosed = false
        delegate = self
        for (type, identifier) in [(NSWindow.ButtonType.closeButton, "close"),
                                   (.miniaturizeButton, "minimize"), (.zoomButton, "zoom")] {
            standardWindowButton(type)?.setAccessibilityIdentifier("marr.window.\(identifier)")
        }
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        prepareForUserGeometryChange?()
        updateFullScreenAppearance(true)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        updateFullScreenAppearance(false)
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        updateFullScreenAppearance(false)
    }

    private func updateFullScreenAppearance(_ isFullScreen: Bool) {
        backgroundColor = isFullScreen ? .white : .clear
        isOpaque = isFullScreen
        onFullScreenChanged?(isFullScreen)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let onCloseRequested else { return true }
        onCloseRequested()
        return false
    }

    func windowWillMiniaturize(_ notification: Notification) {
        prepareForUserGeometryChange?()
        onMiniaturize?()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        onDeminiaturize?()
    }

    override func zoom(_ sender: Any?) {
        prepareForUserGeometryChange?()
        super.zoom(sender)
    }

    override func toggleFullScreen(_ sender: Any?) {
        prepareForUserGeometryChange?()
        super.toggleFullScreen(sender)
    }

    override func orderOut(_ sender: Any?) {
        (contentView as? AnswerPanelContentView)?.resizeOverlay.cancelResize()
        super.orderOut(sender)
    }

    override func close() {
        (contentView as? AnswerPanelContentView)?.resizeOverlay.cancelResize()
        super.close()
    }
}

enum AnswerPanelResizeEdge: Equatable {
    case left
    case right
}

enum AnswerPanelResizeGeometry {
    static let hitWidth: CGFloat = 8
    static let cornerInset: CGFloat = 24

    static func edge(at point: CGPoint, in bounds: CGRect) -> AnswerPanelResizeEdge? {
        guard bounds.contains(point),
              point.y >= bounds.minY + cornerInset,
              point.y < bounds.maxY - cornerInset else { return nil }
        if point.x < bounds.minX + hitWidth { return .left }
        if point.x >= bounds.maxX - hitWidth { return .right }
        return nil
    }

    static func frame(
        startingAt initialFrame: CGRect,
        edge: AnswerPanelResizeEdge,
        screenTranslationX: CGFloat,
        minimumWidth: CGFloat,
        maximumWidth: CGFloat
    ) -> CGRect {
        let proposedWidth = initialFrame.width + (edge == .right ? screenTranslationX : -screenTranslationX)
        let width = min(max(proposedWidth, minimumWidth), max(minimumWidth, maximumWidth))
        return CGRect(
            x: edge == .left ? initialFrame.maxX - width : initialFrame.minX,
            y: initialFrame.minY,
            width: width,
            height: initialFrame.height
        )
    }
}

@MainActor
final class AnswerPanelContentView: AttachmentDropContentView {
    let resizeOverlay: AnswerPanelResizeOverlay

    init(frame: CGRect, hostedView: NSView) {
        resizeOverlay = AnswerPanelResizeOverlay(hostedView: hostedView)
        super.init(frame: frame)
        hostedView.frame = bounds
        hostedView.autoresizingMask = [.width, .height]
        addSubview(hostedView)
        resizeOverlay.frame = bounds
        resizeOverlay.autoresizingMask = [.width, .height]
        addSubview(resizeOverlay)
    }

    required init?(coder: NSCoder) { return nil }

    override func viewWillStartLiveResize() {
        (window as? AnswerPanelWindow)?.prepareForUserGeometryChange?()
        super.viewWillStartLiveResize()
    }
}

@MainActor
final class AnswerPanelResizeOverlay: NSView {
    private struct Drag {
        let edge: AnswerPanelResizeEdge
        let frame: CGRect
        let screenPoint: CGPoint
        let minimumWidth: CGFloat
        let maximumWidth: CGFloat
    }

    private weak var hostedView: NSView?
    private var drag: Drag?

    init(hostedView: NSView) {
        self.hostedView = hostedView
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { return nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        hitTarget(at: convert(point, from: superview), eventType: NSApp.currentEvent?.type)
    }

    // A narrow mouse-only grip leaves scrolling, context menus and native controls
    // in the hosted content on their normal AppKit event path.
    func hitTarget(at point: NSPoint, eventType: NSEvent.EventType?) -> NSView? {
        guard window?.styleMask.contains(.fullScreen) != true else { return nil }
        if let eventType {
            switch eventType {
            case .leftMouseDown, .leftMouseDragged, .leftMouseUp, .mouseMoved, .cursorUpdate:
                break
            default:
                return nil
            }
        }
        guard AnswerPanelResizeGeometry.edge(at: point, in: bounds) != nil else { return nil }
        if let hostedView {
            var target = hostedView.hitTest(convert(point, to: hostedView.superview))
            while let view = target, view !== hostedView {
                if view is NSControl || view is NSTextView { return nil }
                target = view.superview
            }
        }
        return self
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard window?.styleMask.contains(.fullScreen) != true else { return }
        let height = bounds.height - AnswerPanelResizeGeometry.cornerInset * 2
        guard height > 0 else { return }
        for x in [bounds.minX, bounds.maxX - AnswerPanelResizeGeometry.hitWidth] {
            addCursorRect(
                CGRect(x: x, y: bounds.minY + AnswerPanelResizeGeometry.cornerInset,
                       width: AnswerPanelResizeGeometry.hitWidth, height: height),
                cursor: .resizeLeftRight
            )
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window, !window.styleMask.contains(.fullScreen),
              let edge = AnswerPanelResizeGeometry.edge(at: convert(event.locationInWindow, from: nil), in: bounds)
        else { return }
        (window as? AnswerPanelWindow)?.prepareForUserGeometryChange?()
        let contentMinimum = window.frameRect(forContentRect: CGRect(origin: .zero, size: window.contentMinSize)).width
        drag = Drag(
            edge: edge,
            frame: window.frame,
            screenPoint: NSEvent.mouseLocation,
            minimumWidth: max(AnswerPanelConversationLayout.panelSize.width, max(window.minSize.width, contentMinimum)),
            maximumWidth: window.maxSize.width
        )
        NSCursor.resizeLeftRight.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag, let window else { return }
        let nextFrame = AnswerPanelResizeGeometry.frame(
            startingAt: drag.frame,
            edge: drag.edge,
            screenTranslationX: NSEvent.mouseLocation.x - drag.screenPoint.x,
            minimumWidth: drag.minimumWidth,
            maximumWidth: drag.maximumWidth
        )
        if nextFrame != window.frame {
            window.setFrame(nextFrame, display: true, animate: false)
        }
    }

    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        finishResize()
    }

    func cancelResize() {
        guard drag != nil else { return }
        finishResize()
        NSCursor.arrow.set()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { finishResize() }
        super.viewWillMove(toWindow: newWindow)
    }

    private func finishResize() {
        guard drag != nil else { return }
        drag = nil
        NSCursor.pop()
        window?.invalidateCursorRects(for: self)
        if let window,
           hitTarget(at: convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil), eventType: .mouseMoved) != nil {
            NSCursor.resizeLeftRight.set()
        } else {
            NSCursor.arrow.set()
        }
    }
}

struct AnswerPanelActions {
    let close: () -> Void
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

struct ConversationScrollMinYPreferenceKey: PreferenceKey {
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

struct ComposerTopPreference: PreferenceKey {
    static var defaultValue: CGFloat = 400
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

enum AnswerPanelSidebarMotion {
    static let duration = 0.24
    // The reference gallery uses this decelerating transform curve. The
    // content width itself is never interpolated by this animation.
    static var animation: Animation { .timingCurve(0.165, 0.84, 0.44, 1, duration: duration) }
    static var timingFunction: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.165, 0.84, 0.44, 1)
    }
}

/// Animates drawing position without changing the child's layout proposal.
/// SwiftUI owns presentation and retargeting; no frame progress is published.
struct AnswerPanelSidebarTranslation: GeometryEffect {
    var x: CGFloat
    var animatableData: CGFloat {
        get { x }
        set { x = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: x, y: 0))
    }
}

private struct AnswerPanelSidebarContentTranslation: GeometryEffect {
    let geometry: AnswerPanelSidebarMotionGeometry
    let viewportWidth: CGFloat
    var revealWidth: CGFloat
    var animatableData: CGFloat {
        get { revealWidth }
        set { revealWidth = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        // Interpolate reveal, not the derived origin. When the text width is
        // committed once, its visual center therefore stays continuous. The
        // viewport tracks a first native window expansion independently.
        ProjectionTransform(CGAffineTransform(
            translationX: geometry.contentOriginX(revealWidth: revealWidth, viewportWidth: viewportWidth), y: 0))
    }
}

struct AnswerPanelSidebarMotionSurface<Sidebar: View, Conversation: View>: View {
    let revealWidth: CGFloat
    let isExpanded: Bool
    let canvasWidth: CGFloat?
    let windowMotion: AnswerPanelSidebarWindowMotion?
    let animates: Bool
    let sidebar: Sidebar
    let conversation: Conversation
    let onContentWidthChange: (CGFloat) -> Void

    var body: some View {
        GeometryReader { available in
            let presentedReveal = windowMotion?.revealWidth(at: available.size.width) ?? revealWidth
            let geometry = AnswerPanelSidebarMotionGeometry(
                canvasWidth: canvasWidth ?? available.size.width,
                destinationRevealWidth: isExpanded ? AnswerPanelSidebarLayout.sidebarWidth : 0)
            ZStack(alignment: .topLeading) {
                conversation
                    .frame(width: geometry.contentWidth, height: available.size.height)
                    .background {
                        // Measure the assigned canvas, not the child's intrinsic
                        // size: the composer still uses the previous width until
                        // this callback arrives and can temporarily resist shrinking.
                        GeometryReader { content in
                            Color.clear
                                .onAppear { onContentWidthChange(content.size.width) }
                                .onChange(of: content.size.width) { _, width in onContentWidthChange(width) }
                        }
                    }
                    .transaction { if animates { $0.animation = nil } }
                    .modifier(AnswerPanelSidebarContentTranslation(geometry: geometry,
                        viewportWidth: available.size.width, revealWidth: presentedReveal))
                    .animation(animates ? AnswerPanelSidebarMotion.animation : nil, value: revealWidth)
                // Keep the sidebar mounted so opening does not rebuild its
                // native menus, search field and scroll hierarchy each time.
                sidebar
                    .frame(width: AnswerPanelSidebarLayout.sidebarWidth, height: available.size.height)
                    .modifier(AnswerPanelSidebarTranslation(x: geometry.sidebarOriginX(revealWidth: presentedReveal)))
                    .animation(animates ? AnswerPanelSidebarMotion.animation : nil, value: revealWidth)
                    .allowsHitTesting(isExpanded)
                    .accessibilityHidden(!isExpanded)
            }
            .frame(width: available.size.width, height: available.size.height, alignment: .topLeading)
            .clipped()
        }
    }
}

#if DEBUG
@MainActor
enum MarrScrollDiagnostics {
    static var panelEvaluations = 0
    static var taskEvaluations = 0
    static func recordTaskEvaluation() { taskEvaluations += 1 }
    static func recordPanelEvaluation() { panelEvaluations += 1 }
}
#endif
