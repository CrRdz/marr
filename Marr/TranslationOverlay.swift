import AppKit
import Carbon
import SwiftUI

@MainActor
final class TranslationOverlayController {
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
    private var didClose = false

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
        let createdWindow = TranslationOverlayWindow(
            contentRect: rect,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        createdWindow.title = "Marr Translation"
        createdWindow.isOpaque = false
        createdWindow.backgroundColor = .clear
        createdWindow.hasShadow = false
        createdWindow.animationBehavior = .none
        createdWindow.isReleasedWhenClosed = false
        createdWindow.level = .screenSaver
        createdWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        createdWindow.ignoresMouseEvents = true

        window = createdWindow
        createdWindow.contentView = NSHostingView(
            rootView: ImageTranslationOverlayView(model: model)
                .marrPreferredColorScheme()
        )
    }

    func show() {
        installEscapeMonitor()
        backdropWindow.orderFront(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showTranslatedImage(
        _ image: NSImage,
        originalImage: NSImage,
        highlightPairs: [ImageTranslationHighlightPair] = []
    ) {
        closeOriginalWindow()
        self.originalImage = originalImage
        translatedImage = image
        isComparing = false
        model.highlightPairs = highlightPairs
        model.clearHighlight()
        window.ignoresMouseEvents = highlightPairs.isEmpty
        window.setFrame(anchorRect, display: true)
        model.state = .result(image)
        showToolBubble()
    }

    func showError(_ message: String) {
        closeOriginalWindow()
        isComparing = false
        window.ignoresMouseEvents = model.highlightPairs.isEmpty
        closeToolBubble()
        window.setFrame(anchorRect, display: true)
        model.state = .error(message)
    }

    func close() {
        guard !didClose else {
            return
        }

        didClose = true
        removeEscapeMonitor()
        closeToolBubble()
        closeOriginalWindow()
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
            return
        }

        let createdWindow = TranslationToolWindow(
            contentRect: toolBubbleFrame(),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        createdWindow.title = "Marr Translation Tools"
        createdWindow.isOpaque = false
        createdWindow.backgroundColor = .clear
        createdWindow.hasShadow = false
        createdWindow.animationBehavior = .none
        createdWindow.isReleasedWhenClosed = false
        createdWindow.level = .screenSaver
        createdWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        createdWindow.ignoresMouseEvents = false
        createdWindow.contentView = NSHostingView(
            rootView: TranslationToolBubbleView { [weak self] in
                self?.toggleCompare()
            }
            .marrPreferredColorScheme()
        )

        toolWindow = createdWindow
        createdWindow.makeKeyAndOrderFront(nil)
    }

    private func closeToolBubble() {
        toolWindow?.orderOut(nil)
        toolWindow?.contentView = nil
        toolWindow?.close()
        toolWindow = nil
    }

    private func toggleCompare() {
        guard let originalImage, let translatedImage else {
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
        window.ignoresMouseEvents = model.highlightPairs.isEmpty
        window.setFrame(anchorRect, display: true)
        model.state = .result(translatedImage)
        updateToolBubblePosition()
    }

    private func showImageCompare(originalImage: NSImage, translatedImage: NSImage) {
        closeOriginalWindow()
        isComparing = true
        window.ignoresMouseEvents = true
        window.setFrame(anchorRect, display: true)
        model.state = .result(translatedImage)
        let originalFrame = TranslationCompareLayout.originalFrame(
            anchorFrame: anchorRect,
            visibleFrame: screenVisibleFrame()
        )
        showOriginalWindow(image: originalImage, frame: originalFrame)
        updateToolBubblePosition()
    }

    private func showOriginalWindow(image: NSImage, frame: CGRect) {
        closeOriginalWindow()
        let createdWindow = TranslationOriginalWindow(
            contentRect: frame,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        createdWindow.title = "Marr Original Screenshot"
        createdWindow.isOpaque = false
        createdWindow.backgroundColor = .clear
        createdWindow.hasShadow = true
        createdWindow.animationBehavior = .none
        createdWindow.isReleasedWhenClosed = false
        createdWindow.level = .screenSaver
        createdWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        createdWindow.ignoresMouseEvents = false
        createdWindow.isMovableByWindowBackground = true
        createdWindow.contentView = TranslationDraggableHostingView(
            rootView: TranslationDockedOriginalView(image: image, model: model)
                .marrPreferredColorScheme(),
            selectableRects: model.highlightPairs.flatMap(\.sourceRects)
        )

        originalWindow = createdWindow
        createdWindow.orderFront(nil)
    }

    private func closeOriginalWindow() {
        originalWindow?.orderOut(nil)
        originalWindow?.contentView = nil
        originalWindow?.close()
        originalWindow = nil
    }

    private func toolBubbleFrame() -> CGRect {
        toolBubbleFrame(near: anchorRect)
    }

    private func updateToolBubblePosition() {
        toolWindow?.contentView = NSHostingView(
            rootView: TranslationToolBubbleView(isComparing: isComparing) { [weak self] in
                self?.toggleCompare()
            }
            .marrPreferredColorScheme()
        )
        toolWindow?.setFrame(toolBubbleFrame(), display: true)
    }

    private func toolBubbleFrame(near frame: CGRect) -> CGRect {
        let size = CGSize(width: 104, height: 32)
        let visibleFrame = screenVisibleFrame()
        let x = min(max(frame.midX - size.width / 2, visibleFrame.minX + 8), visibleFrame.maxX - size.width - 8)
        let preferredY = frame.minY - size.height - 10
        let y = preferredY >= visibleFrame.minY + 8
            ? preferredY
            : min(frame.maxY + 10, visibleFrame.maxY - size.height - 8)

        return CGRect(origin: CGPoint(x: x, y: y), size: size).integral
    }

    private func screenVisibleFrame() -> CGRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(anchorRect) } ?? NSScreen.main
        return screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 900, height: 620)
    }

    private func installEscapeMonitor() {
        removeEscapeMonitor()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == kVK_Escape else {
                return event
            }

            self?.close()
            return nil
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
    }
}

private class TranslationOverlayWindow: NSWindow {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
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

private final class TranslationOriginalWindow: TranslationOverlayWindow {
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

private final class TranslationToolWindow: NSWindow {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }
}

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
        return !selectableRects.contains { $0.contains(normalizedPoint) }
    }
}

@MainActor
private final class ImageTranslationOverlayModel: ObservableObject {
    @Published var state: ImageTranslationOverlayState = .loading
    @Published var highlightPairs: [ImageTranslationHighlightPair] = []
    @Published var selectedHighlightIDs: Set<String> = []

    private var selectionStart: CGPoint?
    private var selectionSide: TranslationHighlightSide?

    func updateHighlightSelection(side: TranslationHighlightSide, point: CGPoint) {
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

enum TranslationCompareLayout {
    static func originalFrame(
        anchorFrame: CGRect,
        visibleFrame: CGRect,
        margin: CGFloat = 12,
        gap: CGFloat = 8
    ) -> CGRect {
        let availableFrame = visibleFrame.insetBy(dx: margin, dy: margin)
        let sourceFrame = anchorFrame.integral
        guard sourceFrame.width > 0, sourceFrame.height > 0 else {
            return sourceFrame
        }

        let candidates = [
            CGRect(
                x: sourceFrame.minX - gap - sourceFrame.width,
                y: sourceFrame.minY,
                width: sourceFrame.width,
                height: sourceFrame.height
            ),
            CGRect(
                x: sourceFrame.maxX + gap,
                y: sourceFrame.minY,
                width: sourceFrame.width,
                height: sourceFrame.height
            ),
            CGRect(
                x: sourceFrame.minX,
                y: sourceFrame.maxY + gap,
                width: sourceFrame.width,
                height: sourceFrame.height
            ),
            CGRect(
                x: sourceFrame.minX,
                y: sourceFrame.minY - gap - sourceFrame.height,
                width: sourceFrame.width,
                height: sourceFrame.height
            )
        ]

        if let nonOverlappingFrame = candidates.first(where: { candidate in
            availableFrame.contains(candidate) && !candidate.intersects(sourceFrame)
        }) {
            return nonOverlappingFrame.integral
        }

        return candidates
            .map { clampedFrame($0, to: availableFrame) }
            .enumerated()
            .min { lhs, rhs in
                let lhsOverlap = overlapArea(lhs.element, sourceFrame)
                let rhsOverlap = overlapArea(rhs.element, sourceFrame)
                if lhsOverlap != rhsOverlap {
                    return lhsOverlap < rhsOverlap
                }
                return lhs.offset < rhs.offset
            }?
            .element
            .integral ?? sourceFrame
    }

    private static func clampedFrame(_ frame: CGRect, to bounds: CGRect) -> CGRect {
        return CGRect(
            x: min(max(frame.minX, bounds.minX), bounds.maxX - frame.width),
            y: min(max(frame.minY, bounds.minY), bounds.maxY - frame.height),
            width: frame.width,
            height: frame.height
        )
    }

    private static func overlapArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else {
            return 0
        }
        return intersection.width * intersection.height
    }
}

private struct ImageTranslationOverlayView: View {
    @ObservedObject var model: ImageTranslationOverlayModel

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                switch model.state {
                case .loading:
                    loadingView
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                case .result(let image):
                    TranslationInteractiveImageView(
                        image: image,
                        side: .translated,
                        model: model
                    )
                    .overlay(selectionHintBorder)
                case .error(let message):
                    errorView(message)
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private var loadingView: some View {
        ProgressView()
            .controlSize(.small)
            .padding(14)
            .background(.black.opacity(0.56), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.white.opacity(0.20), lineWidth: 0.8)
            )
    }

    private func errorView(_ message: String) -> some View {
        Text(message)
            .font(MarrTypography.body(size: 12.5, weight: .medium))
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
            .stroke(
                .white.opacity(0.42),
                style: StrokeStyle(lineWidth: 0.8, dash: [8, 7])
            )
            .overlay(
                Rectangle()
                    .stroke(.black.opacity(0.10), lineWidth: 0.6)
                    .padding(1)
            )
            .padding(-2)
            .allowsHitTesting(false)
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

    var body: some View {
        TranslationInteractiveImageView(
            image: image,
            side: .source,
            model: model
        )
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(Rectangle().stroke(.primary.opacity(0.24), lineWidth: 1))
            .overlay(alignment: .topLeading) {
                Text("Original")
                    .font(MarrTypography.body(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.62), in: Capsule())
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
    var isComparing = false
    let onCompare: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onCompare) {
            HStack(spacing: 6) {
                Image(systemName: isComparing ? "checkmark" : "rectangle.split.2x1")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary.opacity(isHovering ? 0.94 : 0.78))
                    .frame(width: 20, height: 20)
                    .background(
                        Color.primary.opacity(isHovering ? 0.12 : 0.065),
                        in: Circle()
                    )
                Text(isComparing ? "Done" : "Compare")
                    .font(MarrTypography.body(size: 12, weight: .semibold))
            }
            .foregroundStyle(.primary.opacity(isHovering ? 0.92 : 0.78))
            .frame(width: 104, height: 32)
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
