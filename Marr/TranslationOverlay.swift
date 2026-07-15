import AppKit
import Carbon
import SwiftUI

@MainActor
final class TranslationOverlayController {
    var onClose: (() -> Void)?

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

    init(anchorRect: CGRect) {
        let rect = anchorRect.integral
        self.anchorRect = rect
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
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showTranslatedImage(_ image: NSImage, originalImage: NSImage) {
        closeOriginalWindow()
        self.originalImage = originalImage
        translatedImage = image
        isComparing = false
        window.ignoresMouseEvents = true
        window.setFrame(anchorRect, display: true)
        model.state = .result(image)
        showToolBubble()
    }

    func showError(_ message: String) {
        closeOriginalWindow()
        isComparing = false
        window.ignoresMouseEvents = true
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
        window.ignoresMouseEvents = true
        window.setFrame(anchorRect, display: true)
        model.state = .result(translatedImage)
        updateToolBubblePosition()
    }

    private func showImageCompare(originalImage: NSImage, translatedImage: NSImage) {
        closeOriginalWindow()
        isComparing = true
        if let dockedFrame = TranslationCompareLayout.dockedOriginalFrame(
            anchorFrame: anchorRect,
            visibleFrame: screenVisibleFrame()
        ) {
            window.ignoresMouseEvents = true
            window.setFrame(anchorRect, display: true)
            model.state = .result(translatedImage)
            showOriginalWindow(image: originalImage, frame: dockedFrame)
        } else {
            let presentation = imageComparePresentation(
                originalImage: originalImage,
                translatedImage: translatedImage
            )
            window.ignoresMouseEvents = false
            window.setFrame(presentation.containerFrame, display: true)
            model.state = .compare(presentation)
        }
        updateToolBubblePosition()
    }

    private func showOriginalWindow(image: NSImage, frame: CGRect) {
        closeOriginalWindow()
        let createdWindow = TranslationOverlayWindow(
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
        createdWindow.ignoresMouseEvents = true
        createdWindow.contentView = NSHostingView(
            rootView: TranslationDockedOriginalView(image: image)
                .marrPreferredColorScheme()
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
        let referenceFrame: CGRect
        if isComparing, let originalWindow {
            referenceFrame = window.frame.union(originalWindow.frame)
        } else {
            referenceFrame = isComparing ? window.frame : anchorRect
        }
        return toolBubbleFrame(near: referenceFrame)
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
        let size = CGSize(width: 108, height: 30)
        let visibleFrame = screenVisibleFrame()
        let x = min(max(frame.midX - size.width / 2, visibleFrame.minX + 8), visibleFrame.maxX - size.width - 8)
        let preferredY = frame.minY - size.height - 10
        let y = preferredY >= visibleFrame.minY + 8
            ? preferredY
            : min(frame.maxY + 10, visibleFrame.maxY - size.height - 8)

        return CGRect(origin: CGPoint(x: x, y: y), size: size).integral
    }

    private func imageComparePresentation(
        originalImage: NSImage,
        translatedImage: NSImage
    ) -> TranslationImageComparePresentation {
        let compareFrame = TranslationCompareLayout.imageFrame(
            anchorFrame: anchorRect,
            visibleFrame: screenVisibleFrame()
        )

        return TranslationImageComparePresentation(
            originalImage: originalImage,
            translatedImage: translatedImage,
            containerFrame: compareFrame
        )
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

private final class TranslationOverlayWindow: NSWindow {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
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

@MainActor
private final class ImageTranslationOverlayModel: ObservableObject {
    @Published var state: ImageTranslationOverlayState = .loading
}

private enum ImageTranslationOverlayState {
    case loading
    case result(NSImage)
    case compare(TranslationImageComparePresentation)
    case error(String)
}

private struct TranslationImageComparePresentation {
    let originalImage: NSImage
    let translatedImage: NSImage
    let containerFrame: CGRect
}

enum TranslationCompareLayout {
    static let dividerWidth: CGFloat = 1

    static func paneWidth(containerWidth: CGFloat) -> CGFloat {
        max(1, containerWidth / 2)
    }

    static func dividerX(containerWidth: CGFloat) -> CGFloat {
        paneWidth(containerWidth: containerWidth)
    }

    static func dockedOriginalFrame(
        anchorFrame: CGRect,
        visibleFrame: CGRect,
        margin: CGFloat = 12,
        gap: CGFloat = 8
    ) -> CGRect? {
        let availableFrame = visibleFrame.insetBy(dx: margin, dy: margin)
        let sourceFrame = anchorFrame.integral
        guard
            sourceFrame.width > 0,
            sourceFrame.height > 0,
            sourceFrame.width <= availableFrame.width,
            sourceFrame.height <= availableFrame.height
        else {
            return nil
        }

        let y = min(
            max(sourceFrame.minY, availableFrame.minY),
            availableFrame.maxY - sourceFrame.height
        ).rounded()
        let leftX = sourceFrame.minX - gap - sourceFrame.width
        if leftX >= availableFrame.minX {
            return CGRect(
                x: leftX.rounded(),
                y: y,
                width: sourceFrame.width,
                height: sourceFrame.height
            )
        }

        let rightX = sourceFrame.maxX + gap
        if rightX + sourceFrame.width <= availableFrame.maxX {
            return CGRect(
                x: rightX.rounded(),
                y: y,
                width: sourceFrame.width,
                height: sourceFrame.height
            )
        }

        return nil
    }

    static func imageFrame(
        anchorFrame: CGRect,
        visibleFrame: CGRect,
        margin: CGFloat = 12,
        minimumSize: CGSize = CGSize(width: 760, height: 520)
    ) -> CGRect {
        let availableFrame = visibleFrame.insetBy(dx: margin, dy: margin)
        let sourceFrame = anchorFrame.integral
        let idealWidth = sourceFrame.width * 2 + 1
        let idealHeight = sourceFrame.height + 45
        let size = CGSize(
            width: min(availableFrame.width, max(idealWidth, minimumSize.width)),
            height: min(availableFrame.height, max(idealHeight, minimumSize.height))
        )
        let x = min(
            max(sourceFrame.midX - size.width / 2, availableFrame.minX),
            availableFrame.maxX - size.width
        )
        let y = min(
            max(sourceFrame.midY - size.height / 2, availableFrame.minY),
            availableFrame.maxY - size.height
        )

        return CGRect(
            origin: CGPoint(x: x.rounded(), y: y.rounded()),
            size: size
        )
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
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .overlay(selectionHintBorder)
                case .compare(let presentation):
                    TranslationImageCompareView(
                        originalImage: presentation.originalImage,
                        translatedImage: presentation.translatedImage
                    )
                    .frame(width: geometry.size.width, height: geometry.size.height)
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

private struct TranslationDockedOriginalView: View {
    let image: NSImage

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

private struct TranslationImageCompareView: View {
    let originalImage: NSImage
    let translatedImage: NSImage

    private let headerHeight: CGFloat = 44

    var body: some View {
        GeometryReader { geometry in
            let paneWidth = TranslationCompareLayout.paneWidth(
                containerWidth: geometry.size.width
            )

            VStack(spacing: 0) {
                compareHeader(paneWidth: paneWidth)
                    .frame(height: headerHeight)
                Divider()

                ScrollView([.horizontal, .vertical]) {
                    HStack(alignment: .top, spacing: 0) {
                        compareImage(originalImage, width: paneWidth)
                        compareImage(translatedImage, width: paneWidth)
                    }
                    .frame(minWidth: geometry.size.width, alignment: .topLeading)
                }
                .scrollIndicators(.visible)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .topLeading) {
                Rectangle()
                    .fill(.primary.opacity(0.16))
                    .frame(
                        width: TranslationCompareLayout.dividerWidth,
                        height: geometry.size.height
                    )
                    .offset(
                        x: TranslationCompareLayout.dividerX(
                            containerWidth: geometry.size.width
                        ) - TranslationCompareLayout.dividerWidth / 2
                    )
                    .allowsHitTesting(false)
            }
            .overlay(Rectangle().stroke(.primary.opacity(0.18), lineWidth: 1))
        }
        .accessibilityLabel("Original and translated screenshot comparison")
    }

    private func compareHeader(paneWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            headerLabel("Original", width: paneWidth)
            headerLabel("简体中文", width: paneWidth)
        }
        .background(.primary.opacity(0.035))
    }

    private func headerLabel(_ title: String, width: CGFloat) -> some View {
        Text(title)
            .font(MarrTypography.body(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .frame(width: width, alignment: .leading)
    }

    private func compareImage(_ image: NSImage, width: CGFloat) -> some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: width, alignment: .top)
            .clipped()
    }
}

private struct TranslationToolBubbleView: View {
    var isComparing = false
    let onCompare: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onCompare) {
            HStack(spacing: 7) {
                Image(systemName: isComparing ? "checkmark" : "rectangle.split.2x1")
                    .font(.system(size: 13, weight: .semibold))
                Text(isComparing ? "Done" : "Compare")
                    .font(MarrTypography.body(size: 13, weight: .semibold))
            }
            .foregroundStyle(.primary.opacity(isHovering ? 0.95 : 0.78))
            .frame(width: 108, height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(isComparing ? "Return to translated image" : "Compare original and translation")
    }
}
