import AppKit
import Carbon
import SwiftUI

@MainActor
final class TranslationOverlayController: NSObject, NSWindowDelegate {
    var onClose: (() -> Void)?

    private let backdropWindow: TranslationBackdropWindow
    private let window: TranslationOverlayWindow
    private let anchorRect: CGRect
    private let model = ImageTranslationOverlayModel()
    private var toolWindow: TranslationToolWindow?
    private var originalWindow: TranslationOverlayWindow?
    private var originalImage: NSImage?
    private var translatedImage: NSImage?
    private var escapeMonitor: Any?
    private var isComparing = false
    private var hasPresented = false
    private var didClose = false
    private var companionLookTarget: (side: TranslationHighlightSide, point: CGPoint)?

    var isTranslationPinned: Bool { model.isTranslationPinned }
    var windowForTesting: NSWindow { window }
    var backdropWindowForTesting: NSWindow { backdropWindow }
    var toolWindowForTesting: NSWindow? { toolWindow }
    var originalWindowForTesting: NSWindow? { originalWindow }
    var companionPhaseForTesting: MarrCompanionPhase { model.companionPhase }
    var companionGazeForTesting: CGPoint { model.companionGaze }

    func showProcessing(_ phase: MarrCompanionPhase) {
        guard !didClose, case .loading = model.state,
              [.recognizing, .translating, .rendering].contains(phase) else { return }
        model.processingPhase = phase
    }

    init(anchorRect: CGRect, frozenSnapshot: ScreenCaptureSnapshot) {
        let rect = anchorRect.integral
        self.anchorRect = rect
        let createdBackdropWindow = TranslationBackdropWindow(
            contentRect: frozenSnapshot.screenFrame,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        createdBackdropWindow.title = "Marr Frozen Translation Backdrop"
        createdBackdropWindow.isOpaque = true
        createdBackdropWindow.backgroundColor = .black
        createdBackdropWindow.hasShadow = false
        createdBackdropWindow.animationBehavior = .none
        createdBackdropWindow.isReleasedWhenClosed = false
        createdBackdropWindow.level = .screenSaver
        createdBackdropWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        createdBackdropWindow.ignoresMouseEvents = false
        createdBackdropWindow.contentView = NSHostingView(
            rootView: TranslationFrozenBackdropView(
                image: NSImage(
                    cgImage: frozenSnapshot.image,
                    size: frozenSnapshot.screenFrame.size
                )
            )
        )

        backdropWindow = createdBackdropWindow
        let createdWindow = TranslationMovableWindow(
            contentRect: rect,
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        createdWindow.title = "Marr Translation"
        createdWindow.isOpaque = false
        createdWindow.backgroundColor = .clear
        createdWindow.hasShadow = false
        createdWindow.animationBehavior = .none
        createdWindow.isReleasedWhenClosed = false
        createdWindow.hidesOnDeactivate = false
        createdWindow.level = .screenSaver
        createdWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        createdWindow.ignoresMouseEvents = true
        createdWindow.isMovable = true

        window = createdWindow
        super.init()
        model.onLook = { [weak self] side, point in
            self?.companionLookTarget = point.map { (side, $0) }
            self?.updateCompanionGaze()
        }
        createdWindow.delegate = self
        createdWindow.contentView = NSHostingView(
            rootView: ImageTranslationOverlayView(model: model) { [weak self] in
                self?.toggleTranslationPin()
            }
                .marrPreferredColorScheme()
        )
    }

    func show() {
        guard !didClose else { return }
        hasPresented = true
        installEscapeMonitor()
        applyPresentationMode()
        window.makeKeyAndOrderFront(nil)
        if !model.isTranslationPinned {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func showTranslatedImage(
        _ image: NSImage,
        originalImage: NSImage,
        highlightPairs: [ImageTranslationHighlightPair] = []
    ) {
        guard !didClose else { return }
        closeOriginalWindow()
        self.originalImage = originalImage
        translatedImage = image
        isComparing = false
        model.isTranslationPinned = false
        window.hasShadow = false
        model.highlightPairs = highlightPairs
        model.clearHighlight()
        window.ignoresMouseEvents = false
        window.setFrame(anchorRect, display: true)
        model.state = .result(image)
        applyPresentationMode()
        showToolBubble()
    }

    func showError(_ message: String) {
        guard !didClose else { return }
        closeOriginalWindow()
        isComparing = false
        model.isTranslationPinned = false
        window.hasShadow = false
        window.ignoresMouseEvents = model.highlightPairs.isEmpty
        closeToolBubble()
        window.setFrame(anchorRect, display: true)
        model.state = .error(message)
        applyPresentationMode()
    }

    func updateHighlightPairs(_ highlightPairs: [ImageTranslationHighlightPair]) {
        guard !didClose else { return }
        model.highlightPairs = highlightPairs
        model.clearHighlight()
        window.ignoresMouseEvents = false
    }

    func updateTranslatedImage(
        _ image: NSImage,
        highlightPairs: [ImageTranslationHighlightPair]
    ) {
        guard !didClose else { return }
        translatedImage = image
        model.highlightPairs = highlightPairs
        model.clearHighlight()
        window.ignoresMouseEvents = false
        model.state = .result(image)
    }

    func close() {
        guard !didClose else {
            return
        }

        didClose = true
        removeEscapeMonitor()
        closeToolBubble()
        closeOriginalWindow()
        window.delegate = nil
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        backdropWindow.orderOut(nil)
        backdropWindow.contentView = nil
        backdropWindow.close()
        onClose?()
    }

    private func showToolBubble() {
        if toolWindow != nil {
            updateToolBubbleContent()
            updateToolBubblePosition()
            return
        }

        let createdWindow = TranslationToolWindow(
            contentRect: toolBubbleFrame(),
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        createdWindow.title = "Marr Translation Tools"
        createdWindow.isOpaque = false
        createdWindow.backgroundColor = .clear
        createdWindow.hasShadow = false
        createdWindow.animationBehavior = .none
        createdWindow.isReleasedWhenClosed = false
        configurePresentation(of: createdWindow)
        createdWindow.ignoresMouseEvents = false
        createdWindow.contentView = NSHostingView(
            rootView: TranslationToolBubbleView(model: model) { [weak self] in
                self?.toggleCompare()
            }
            .marrPreferredColorScheme()
        )

        toolWindow = createdWindow
        updateCompanionGaze()
        createdWindow.makeKeyAndOrderFront(nil)
    }

    private func closeToolBubble() {
        toolWindow?.orderOut(nil)
        toolWindow?.contentView = nil
        toolWindow?.close()
        toolWindow = nil
    }

    func toggleTranslationPin() {
        guard !didClose, case .result = model.state else { return }
        model.isTranslationPinned.toggle()
        model.clearHighlight()
        window.hasShadow = model.isTranslationPinned
        window.ignoresMouseEvents = false
        if !model.isTranslationPinned {
            window.setFrame(anchorRect, display: true)
        }
        applyPresentationMode()
        window.makeKeyAndOrderFront(nil)
        toolWindow?.orderFront(nil)
        updateToolBubblePosition()
        if !model.isTranslationPinned {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func configurePresentation(of panel: TranslationOverlayWindow) {
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = model.isTranslationPinned
        panel.level = model.isTranslationPinned ? .floating : .screenSaver
        panel.collectionBehavior = model.isTranslationPinned
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    private func applyPresentationMode() {
        configurePresentation(of: window)
        if let originalWindow { configurePresentation(of: originalWindow) }
        if let toolWindow { configurePresentation(of: toolWindow) }

        // A resident result owns only its small panels, never the live page.
        // Keep the snapshot available for explicitly returning to capture preview.
        backdropWindow.ignoresMouseEvents = model.isTranslationPinned
        if model.isTranslationPinned {
            backdropWindow.orderOut(nil)
        } else if hasPresented {
            backdropWindow.orderFront(nil)
        }
        guard hasPresented else { return }
        window.orderFront(nil)
        originalWindow?.orderFront(nil)
        toolWindow?.orderFront(nil)
    }

    func windowDidMove(_ notification: Notification) {
        guard !didClose else { return }
        updateToolBubblePosition()
    }

    func toggleCompare() {
        guard !didClose, case .result = model.state, let originalImage, let translatedImage else {
            return
        }

        if isComparing {
            showTranslationOnly(translatedImage)
        } else {
            showImageCompare(originalImage: originalImage, translatedImage: translatedImage)
        }
    }

    private func showTranslationOnly(_ translatedImage: NSImage) {
        closeOriginalWindow()
        isComparing = false
        window.ignoresMouseEvents = false
        model.state = .result(translatedImage)
        updateToolBubbleContent()
        updateToolBubblePosition()
    }

    private func showImageCompare(originalImage: NSImage, translatedImage: NSImage) {
        closeOriginalWindow()
        isComparing = true
        window.ignoresMouseEvents = false
        model.state = .result(translatedImage)
        let originalFrame = TranslationCompareLayout.originalFrame(
            anchorFrame: window.frame,
            visibleFrame: screenVisibleFrame()
        )
        showOriginalWindow(image: originalImage, frame: originalFrame)
        updateToolBubbleContent()
        updateToolBubblePosition()
    }

    private func showOriginalWindow(image: NSImage, frame: CGRect) {
        closeOriginalWindow()
        let createdWindow = TranslationMovableWindow(
            contentRect: frame,
            styleMask: [.borderless, .fullSizeContentView, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        createdWindow.contentAspectRatio = frame.size
        let minimumScale = min(1, 120 / max(frame.width, frame.height))
        createdWindow.contentMinSize = CGSize(width: frame.width * minimumScale, height: frame.height * minimumScale)
        createdWindow.title = "Marr Original Screenshot"
        createdWindow.isOpaque = false
        createdWindow.backgroundColor = .clear
        createdWindow.hasShadow = true
        createdWindow.animationBehavior = .none
        createdWindow.isReleasedWhenClosed = false
        configurePresentation(of: createdWindow)
        createdWindow.ignoresMouseEvents = false
        createdWindow.isMovableByWindowBackground = true
        createdWindow.contentView = TranslationDraggableHostingView(
            rootView: TranslationDockedOriginalView(
                image: image,
                model: model,
                onZoom: { [weak self] factor in self?.resizeOriginal(by: factor) },
                onReset: { [weak self] in self?.resizeOriginal(by: nil) }
            )
                .marrPreferredColorScheme(),
            selectableRects: model.highlightPairs.flatMap(\.sourceRects)
        )

        originalWindow = createdWindow
        createdWindow.orderFront(nil)
    }

    private func resizeOriginal(by factor: CGFloat?) {
        guard let originalWindow else { return }
        let scale = factor.map { originalWindow.frame.width / anchorRect.width * $0 } ?? 1
        let frame = TranslationCompareLayout.resizedOriginalFrame(
            currentFrame: originalWindow.frame,
            sourceSize: anchorRect.size,
            scale: scale,
            visibleFrame: screenVisibleFrame()
        )
        originalWindow.setFrame(frame, display: true)
    }

    private func closeOriginalWindow() {
        originalWindow?.orderOut(nil)
        originalWindow?.contentView = nil
        originalWindow?.close()
        originalWindow = nil
    }

    private func toolBubbleFrame() -> CGRect {
        toolBubbleFrame(near: window.frame)
    }

    private func updateToolBubblePosition() {
        toolWindow?.setFrame(toolBubbleFrame(), display: true)
        updateCompanionGaze()
    }

    private func updateCompanionGaze() {
        let target = companionLookTarget ?? (isComparing ? .source : .translated, CGPoint(x: 0.5, y: 0.5))
        let frame = target.side == .source ? originalWindow?.frame ?? window.frame : window.frame
        let point = CGPoint(x: frame.minX + min(1, max(0, target.point.x)) * frame.width,
                            y: frame.maxY - min(1, max(0, target.point.y)) * frame.height)
        let tools = toolWindow?.frame ?? toolBubbleFrame()
        // AppKit uses an upward Y axis; Rive's eye offsets point downward.
        let gaze = CGPoint(x: min(1, max(-1, (point.x - tools.minX - 30) / 180)),
                           y: min(1, max(-1, (tools.midY - point.y) / 180)))
        if model.companionGaze != gaze { model.companionGaze = gaze }
    }

    private func updateToolBubbleContent() {
        // Keep the native Rive view alive when switching comparison modes.
        model.isComparing = isComparing
        companionLookTarget = nil
        updateCompanionGaze()
    }

    private func toolBubbleFrame(near frame: CGRect) -> CGRect {
        let size = CGSize(width: 140, height: 38)
        let visibleFrame = screenVisibleFrame()
        let x = min(max(frame.midX - size.width / 2, visibleFrame.minX + 8), visibleFrame.maxX - size.width - 8)
        let preferredY = frame.minY - size.height - 10
        let y = preferredY >= visibleFrame.minY + 8
            ? preferredY
            : min(frame.maxY + 10, visibleFrame.maxY - size.height - 8)

        return CGRect(origin: CGPoint(x: x, y: y), size: size).integral
    }

    private func screenVisibleFrame() -> CGRect {
        let screen = NSScreen.screens.max { lhs, rhs in
            let left = lhs.frame.intersection(window.frame)
            let right = rhs.frame.intersection(window.frame)
            return max(0, left.width) * max(0, left.height) < max(0, right.width) * max(0, right.height)
        } ?? NSScreen.main
        return screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 900, height: 620)
    }

    private func installEscapeMonitor() {
        removeEscapeMonitor()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyEvent(event)
        }
    }

    func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        guard !didClose, event.type == .keyDown, event.keyCode == kVK_Escape,
              let owner = event.window,
              owner === window || owner === toolWindow || owner === originalWindow else {
            return event
        }
        close()
        return nil
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
    }
}

private class TranslationOverlayWindow: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }
}

private final class TranslationBackdropWindow: NSWindow {
    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }
}

private final class TranslationMovableWindow: TranslationOverlayWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        guard let visibleFrame = screen?.visibleFrame else {
            return frameRect
        }

        let minimumVisibleLength: CGFloat = 48
        var constrainedFrame = frameRect
        constrainedFrame.origin.x = min(
            max(constrainedFrame.minX, visibleFrame.minX - constrainedFrame.width + minimumVisibleLength),
            visibleFrame.maxX - minimumVisibleLength
        )
        constrainedFrame.origin.y = min(
            max(constrainedFrame.minY, visibleFrame.minY - constrainedFrame.height + minimumVisibleLength),
            visibleFrame.maxY - minimumVisibleLength
        )
        return constrainedFrame.integral
    }
}

private final class TranslationToolWindow: TranslationOverlayWindow {}

private final class TranslationDraggableHostingView<Content: View>: NSHostingView<Content> {
    private let selectableRects: [CGRect]

    init(rootView: Content, selectableRects: [CGRect]) {
        self.selectableRects = selectableRects
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init(rootView: Content) {
        fatalError("Use init(rootView:selectableRects:)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool {
        if NSEvent.modifierFlags.contains(.option) {
            return true
        }
        guard bounds.width > 0, bounds.height > 0, let window else {
            return true
        }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let normalizedPoint = CGPoint(
            x: point.x / bounds.width,
            y: isFlipped ? point.y / bounds.height : 1 - point.y / bounds.height
        )
        // Let the zoom buttons receive clicks instead of initiating window drags.
        if normalizedPoint.y * bounds.height < 42 { return false }
        return !selectableRects.contains { $0.contains(normalizedPoint) }
    }
}

@MainActor
private final class ImageTranslationOverlayModel: ObservableObject {
    @Published var state: ImageTranslationOverlayState = .loading
    @Published var processingPhase: MarrCompanionPhase = .recognizing
    @Published var isComparing = false
    @Published var isTranslationPinned = false
    @Published var highlightPairs: [ImageTranslationHighlightPair] = []
    @Published var selectedHighlightIDs: Set<String> = []
    @Published var companionGaze: CGPoint = .zero
    var onLook: ((TranslationHighlightSide, CGPoint?) -> Void)?

    var companionPhase: MarrCompanionPhase {
        switch state {
        case .loading: processingPhase
        case .error: .error
        case .result:
            selectedHighlightIDs.isEmpty
                ? .translationResult(comparing: isComparing, pinned: isTranslationPinned)
                : .selecting
        }
    }

    private var selectionStart: CGPoint?
    private var selectionSide: TranslationHighlightSide?

    func updateHighlightSelection(side: TranslationHighlightSide, point: CGPoint) {
        onLook?(side, point)
        if selectionStart == nil || selectionSide != side {
            selectionStart = point
            selectionSide = side
        }
        guard let selectionStart else { return }
        let selectionRect = CGRect(
            x: min(selectionStart.x, point.x),
            y: min(selectionStart.y, point.y),
            width: abs(point.x - selectionStart.x),
            height: abs(point.y - selectionStart.y)
        ).insetBy(dx: -0.004, dy: -0.004)
        selectedHighlightIDs = Set(highlightPairs.compactMap { pair in
            let rects = side == .source ? pair.sourceRects : pair.translatedRects
            return rects.contains(where: { $0.intersects(selectionRect) }) ? pair.id : nil
        })
    }

    func endHighlightSelection() {
        selectionStart = nil
        selectionSide = nil
    }

    func clearHighlight() {
        selectedHighlightIDs = []
        endHighlightSelection()
    }
}

private enum TranslationHighlightSide {
    case source
    case translated
}

private enum ImageTranslationOverlayState {
    case loading
    case result(NSImage)
    case error(String)
}

private struct ImageTranslationOverlayView: View {
    @ObservedObject var model: ImageTranslationOverlayModel
    let onTogglePin: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                switch model.state {
                case .loading:
                    loadingView(in: geometry.size)
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                case .result(let image):
                    TranslationInteractiveImageView(
                        image: image,
                        side: .translated,
                        model: model
                    )
                    .allowsHitTesting(!model.isTranslationPinned)
                    .overlay {
                        if model.isTranslationPinned {
                            TranslationWindowDragSurface()
                        }
                    }
                    .overlay(selectionHintBorder)
                    .overlay(alignment: .topTrailing) {
                        TranslationPinButton(isPinned: model.isTranslationPinned, action: onTogglePin)
                            .padding(6)
                    }
                case .error(let message):
                    errorView(message)
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private func loadingView(in size: CGSize) -> some View {
        HStack(spacing: 7) {
            MarrCompanion(phase: model.companionPhase, size: min(42, max(12, min(size.width, size.height) - 8)), form: .translate)
            if size.width >= 200, size.height >= 56 {
                Text(model.processingPhase.title)
                    .font(MarrTypography.font(.secondary, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
        }
            .padding(4)
            .background(.black.opacity(0.56), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.white.opacity(0.20), lineWidth: 0.8)
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.processingPhase.title)
    }

    private func errorView(_ message: String) -> some View {
        HStack(spacing: 8) {
            MarrCompanion(phase: .error, size: 36)
            Text(message)
        }
            .font(MarrTypography.font(.body, weight: .medium))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: 280)
            .background(.red.opacity(0.72), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.white.opacity(0.22), lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(0.20), radius: 10, x: 0, y: 5)
    }

    private var selectionHintBorder: some View {
        Rectangle()
            .strokeBorder(.white.opacity(0.90), lineWidth: 1.25)
            .overlay(
                Rectangle()
                    .strokeBorder(.black.opacity(0.22), lineWidth: 0.8)
                    .padding(1.25)
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

}

private struct TranslationPinButton: View {
    let isPinned: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            MarrIcon(isPinned ? "pin.fill" : "pin", size: MarrUI.Icon.inline)
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(.black.opacity(isHovering ? 0.84 : 0.70), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(isPinned ? 0.75 : 0.28), lineWidth: 1))
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityIdentifier("translation.pin")
        .accessibilityLabel(isPinned ? "Return to captured preview" : "Keep translation floating and release page")
        .accessibilityValue(isPinned ? "Pinned" : "Not pinned")
        .help(isPinned ? "Return to captured preview" : "Keep translation floating, release the page, and drag to move")
    }
}

private struct TranslationWindowDragSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> TranslationWindowDragView {
        TranslationWindowDragView()
    }

    func updateNSView(_ nsView: TranslationWindowDragView, context: Context) {}
}

private final class TranslationWindowDragView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        window.makeFirstResponder(self)
        NSCursor.closedHand.push()
        defer { NSCursor.pop() }
        window.performDrag(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard let window else { return }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        let delta: CGPoint
        switch Int(event.keyCode) {
        case kVK_LeftArrow: delta = CGPoint(x: -step, y: 0)
        case kVK_RightArrow: delta = CGPoint(x: step, y: 0)
        case kVK_DownArrow: delta = CGPoint(x: 0, y: -step)
        case kVK_UpArrow: delta = CGPoint(x: 0, y: step)
        default: super.keyDown(with: event); return
        }
        window.setFrameOrigin(CGPoint(x: window.frame.minX + delta.x, y: window.frame.minY + delta.y))
    }
}

private struct TranslationFrozenBackdropView: View {
    let image: NSImage

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .accessibilityHidden(true)
    }
}

private struct TranslationDockedOriginalView: View {
    let image: NSImage
    @ObservedObject var model: ImageTranslationOverlayModel
    let onZoom: (CGFloat) -> Void
    let onReset: () -> Void

    var body: some View {
        TranslationInteractiveImageView(
            image: image,
            side: .source,
            model: model
        )
            .background(MarrUI.Surface.content)
            .overlay(Rectangle().stroke(.primary.opacity(0.24), lineWidth: 1))
            .overlay(alignment: .bottomLeading) {
                Text("Original")
                    .font(MarrTypography.font(.secondary, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.62), in: Capsule())
                    .padding(8)
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 8) {
                    Button { onZoom(1 / 1.2) } label: { MarrIcon("minus.magnifyingglass") }
                        .help("Zoom out")
                        .accessibilityLabel("Zoom out original screenshot")
                    Button("1:1", action: onReset)
                        .help("Restore original size (fit to screen)")
                    Button { onZoom(1.2) } label: { MarrIcon("plus.magnifyingglass") }
                        .help("Zoom in")
                        .accessibilityLabel("Zoom in original screenshot")
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(7)
                .background(.black.opacity(0.72), in: Capsule())
                .padding(8)
            }
            .accessibilityLabel("Original screenshot")
    }
}

private struct TranslationInteractiveImageView: View {
    let image: NSImage
    let side: TranslationHighlightSide
    @ObservedObject var model: ImageTranslationOverlayModel

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()

                ForEach(model.highlightPairs) { pair in
                    let rects = side == .source ? pair.sourceRects : pair.translatedRects
                    ForEach(Array(rects.enumerated()), id: \.offset) { _, rect in
                        if model.selectedHighlightIDs.contains(pair.id) {
                            highlightShape(rect, in: geometry.size)
                        }
                    }
                }

                ForEach(model.highlightPairs) { pair in
                    let rects = side == .source ? pair.sourceRects : pair.translatedRects
                    ForEach(Array(rects.enumerated()), id: \.offset) { _, rect in
                        selectionTarget(rect, in: geometry.size)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .coordinateSpace(name: "translation-highlight-space")
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    model.onLook?(side, CGPoint(x: point.x / max(1, geometry.size.width),
                                               y: point.y / max(1, geometry.size.height)))
                case .ended: model.onLook?(side, nil)
                }
            }
        }
    }

    private func highlightShape(_ rect: CGRect, in size: CGSize) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Color.yellow.opacity(0.30))
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(Color.orange.opacity(0.55), lineWidth: 0.8)
            )
            .frame(width: rect.width * size.width, height: rect.height * size.height)
            .offset(x: rect.minX * size.width, y: rect.minY * size.height)
            .blendMode(.multiply)
            .allowsHitTesting(false)
    }

    private func selectionTarget(_ rect: CGRect, in size: CGSize) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(width: max(6, rect.width * size.width), height: max(6, rect.height * size.height))
            .offset(x: rect.minX * size.width, y: rect.minY * size.height)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("translation-highlight-space"))
                    .onChanged { value in
                        guard !NSEvent.modifierFlags.contains(.option) else { return }
                        model.updateHighlightSelection(
                            side: side,
                            point: CGPoint(
                                x: value.location.x / max(size.width, 1),
                                y: value.location.y / max(size.height, 1)
                            )
                        )
                    }
                    .onEnded { _ in
                        model.endHighlightSelection()
                    }
            )
    }
}

private struct TranslationToolBubbleView: View {
    @ObservedObject var model: ImageTranslationOverlayModel
    let onCompare: () -> Void
    private var isComparing: Bool { model.isComparing }

    @State private var isHovering = false

    var body: some View {
        Button(action: onCompare) {
            HStack(spacing: 6) {
                MarrCompanion(phase: model.companionPhase, size: 32, gaze: model.companionGaze)
                MarrIcon(isComparing ? "checkmark" : "rectangle.split.2x1", size: MarrUI.Icon.status)
                    .foregroundStyle(.primary.opacity(isHovering ? 0.94 : 0.78))
                    .frame(width: 20, height: 20)
                    .background(
                        Color.primary.opacity(isHovering ? 0.12 : 0.065),
                        in: Circle()
                    )
                Text(isComparing ? "Done" : "Compare")
                    .font(MarrTypography.font(.secondary, weight: .semibold))
            }
            .foregroundStyle(.primary.opacity(isHovering ? 0.92 : 0.78))
            .frame(width: 140, height: 38)
            .marrGlassSurface(cornerRadius: 16, isClear: true)
            .overlay(
                Capsule()
                    .fill(Color.primary.opacity(isHovering ? 0.045 : 0))
                    .allowsHitTesting(false)
            )
            .overlay(
                Capsule()
                    .stroke(.white.opacity(isHovering ? 0.28 : 0.20), lineWidth: 0.8)
                    .allowsHitTesting(false)
            )
            .shadow(color: .black.opacity(isHovering ? 0.14 : 0.09), radius: 7, x: 0, y: 4)
            .scaleEffect(isHovering ? 1.01 : 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help(isComparing ? "Return to translated image" : "Compare original and translation")
    }
}
