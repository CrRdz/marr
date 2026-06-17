import AppKit
import Carbon
import SwiftUI

@MainActor
final class ScreenshotOverlayController {
    var onCapture: ((PickedImage, CGRect, String) -> Void)?
    var onCancel: (() -> Void)?

    private var windows: [NSWindow] = []
    private var escapeMonitor: Any?

    func show() {
        close()
        installEscapeMonitor()
        windows = NSScreen.screens.map { screen in
            let window = OverlayWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.animationBehavior = .none
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.ignoresMouseEvents = false

            let view = ScreenshotSelectionView(
                screen: screen,
                onCancel: { [weak self] in
                    self?.cancel()
                },
                onCapture: { [weak self] rect, question in
                    self?.capture(rect: rect, question: question, on: screen)
                }
            )
            window.contentView = NSHostingView(rootView: view)
            window.makeKeyAndOrderFront(nil)
            return window
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        removeEscapeMonitor()
        windows.forEach { window in
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        windows.removeAll()
    }

    private func cancel() {
        close()
        onCancel?()
    }

    private func installEscapeMonitor() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == kVK_Escape else {
                return event
            }

            self?.cancel()
            return nil
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
    }

    private func capture(rect: CGRect, question: String, on screen: NSScreen) {
        close()

        guard let image = ScreenCapture.capture(rect: rect, screen: screen) else {
            onCancel?()
            return
        }

        showFrozenCapture(image: image, rect: rect)
        onCapture?(image, rect, question)
    }

    private func showFrozenCapture(image: PickedImage, rect: CGRect) {
        windows = NSScreen.screens.map { screen in
            let window = OverlayWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.level = .floating
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.animationBehavior = .none
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.ignoresMouseEvents = true
            window.contentView = NSHostingView(
                rootView: FrozenScreenshotView(screen: screen, image: image.image, captureRect: rect)
            )
            window.orderFrontRegardless()
            return window
        }
    }
}

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }
}

private enum ResizeHandle: CaseIterable, Hashable {
    case topLeft
    case top
    case topRight
    case right
    case bottomRight
    case bottom
    case bottomLeft
    case left

    var cursor: NSCursor {
        switch self {
        case .topLeft, .bottomRight:
            return .resizeUpDown
        case .topRight, .bottomLeft:
            return .resizeUpDown
        case .left, .right:
            return .resizeLeftRight
        case .top, .bottom:
            return .resizeUpDown
        }
    }
}

struct ScreenshotSelectionView: View {
    let screen: NSScreen
    let onCancel: () -> Void
    let onCapture: (CGRect, String) -> Void

    @State private var question = ""
    @State private var selection: CGRect = .zero
    @State private var dragStart: CGRect = .zero
    @State private var isMovingSelection = false
    @State private var activeResizeHandle: ResizeHandle?
    @FocusState private var questionFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if selection != .zero {
                    dimmedBackdrop(in: geometry.size)
                    selectionLayer(in: geometry.size)
                    promptBar(in: geometry.size)
                } else {
                    Color.black.opacity(0.32)
                        .ignoresSafeArea()
                }
            }
            .onAppear {
                selection = defaultSelection(in: geometry.size)
                DispatchQueue.main.async {
                    questionFocused = true
                }
            }
        }
    }

    private func dimmedBackdrop(in bounds: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(.black.opacity(0.36))
                .frame(width: bounds.width, height: selection.minY)

            Rectangle()
                .fill(.black.opacity(0.36))
                .frame(width: bounds.width, height: max(0, bounds.height - selection.maxY))
                .position(x: bounds.width / 2, y: selection.maxY + max(0, bounds.height - selection.maxY) / 2)

            Rectangle()
                .fill(.black.opacity(0.36))
                .frame(width: selection.minX, height: selection.height)
                .position(x: selection.minX / 2, y: selection.midY)

            Rectangle()
                .fill(.black.opacity(0.36))
                .frame(width: max(0, bounds.width - selection.maxX), height: selection.height)
                .position(x: selection.maxX + max(0, bounds.width - selection.maxX) / 2, y: selection.midY)
        }
        .ignoresSafeArea()
    }

    private func selectionLayer(in bounds: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(.clear)
                .frame(width: selection.width, height: selection.height)
                .overlay(
                    Rectangle()
                        .stroke(
                            .white.opacity(0.88),
                            style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])
                        )
                )
                .overlay(
                    Rectangle()
                        .stroke(.black.opacity(0.24), lineWidth: 1)
                        .padding(1)
                )
                .contentShape(Rectangle())
                .position(x: selection.midX, y: selection.midY)
                .gesture(moveGesture)

            ForEach(ResizeHandle.allCases, id: \.self) { handle in
                resizeHandle(handle)
            }
        }
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isMovingSelection {
                    dragStart = selection
                    isMovingSelection = true
                }

                let next = dragStart.offsetBy(dx: value.translation.width, dy: value.translation.height)
                selection = clamp(next, in: screen.frame.size)
            }
            .onEnded { _ in
                isMovingSelection = false
            }
    }

    private func resizeHandle(_ handle: ResizeHandle) -> some View {
        Circle()
            .fill(.white.opacity(0.94))
            .frame(width: 9, height: 9)
            .overlay(Circle().stroke(.black.opacity(0.30), lineWidth: 1))
            .shadow(color: .black.opacity(0.28), radius: 3, x: 0, y: 1)
            .position(position(for: handle))
            .onHover { inside in
                if inside {
                    handle.cursor.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if activeResizeHandle != handle {
                            dragStart = selection
                            activeResizeHandle = handle
                        }

                        selection = resize(dragStart, handle: handle, translation: value.translation, bounds: screen.frame.size)
                    }
                    .onEnded { _ in
                        activeResizeHandle = nil
                    }
            )
    }

    private var questionControls: some View {
        HStack(spacing: 10) {
            TextField("Ask about this area", text: $question, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .regular))
                .lineLimit(1...2)
                .foregroundStyle(.primary)
                .focused($questionFocused)
                .onSubmit {
                    sendQuestion()
                }

            Button {
                sendQuestion()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 34, height: 34)
            }
            .sendCircleButton(isEnabled: canSend)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!canSend)
            .help("Send")
        }
        .padding(.leading, 14)
        .padding(.trailing, 7)
        .padding(.vertical, 6)
        .frame(width: 420)
        .frame(minHeight: 46)
        .liquidGlassSurface(cornerRadius: 23, isClear: true)
        .overlay(
            RoundedRectangle(cornerRadius: 23, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.16), radius: 18, x: 0, y: 10)
        .shadow(color: .white.opacity(0.10), radius: 1, x: 0, y: -1)
    }

    private func promptBar(in size: CGSize) -> some View {
        questionControls
        .position(x: toolbarX(in: size), y: toolbarY(in: size))
    }

    private var canSend: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendQuestion() {
        guard canSend else {
            return
        }

        onCapture(globalSelectionRect(), question)
    }

    private func defaultSelection(in size: CGSize) -> CGRect {
        let width = min(760, size.width * 0.62)
        let height = min(430, size.height * 0.52)
        return CGRect(
            x: (size.width - width) / 2,
            y: (size.height - height) / 2,
            width: width,
            height: height
        )
    }

    private func position(for handle: ResizeHandle) -> CGPoint {
        switch handle {
        case .topLeft:
            return CGPoint(x: selection.minX, y: selection.minY)
        case .top:
            return CGPoint(x: selection.midX, y: selection.minY)
        case .topRight:
            return CGPoint(x: selection.maxX, y: selection.minY)
        case .right:
            return CGPoint(x: selection.maxX, y: selection.midY)
        case .bottomRight:
            return CGPoint(x: selection.maxX, y: selection.maxY)
        case .bottom:
            return CGPoint(x: selection.midX, y: selection.maxY)
        case .bottomLeft:
            return CGPoint(x: selection.minX, y: selection.maxY)
        case .left:
            return CGPoint(x: selection.minX, y: selection.midY)
        }
    }

    private func toolbarX(in bounds: CGSize) -> CGFloat {
        min(max(selection.midX, 260), bounds.width - 260)
    }

    private func toolbarY(in bounds: CGSize) -> CGFloat {
        let toolbarHeight: CGFloat = 54
        let preferredBelow = selection.maxY + toolbarHeight / 2 + 14
        if preferredBelow <= bounds.height - toolbarHeight / 2 - 8 {
            return preferredBelow
        }

        return max(selection.minY - toolbarHeight / 2 - 14, toolbarHeight / 2 + 8)
    }

    private func resize(_ rect: CGRect, handle: ResizeHandle, translation: CGSize, bounds: CGSize) -> CGRect {
        var next = rect
        let minSize: CGFloat = 80

        switch handle {
        case .topLeft:
            next.origin.x += translation.width
            next.origin.y += translation.height
            next.size.width -= translation.width
            next.size.height -= translation.height
        case .top:
            next.origin.y += translation.height
            next.size.height -= translation.height
        case .topRight:
            next.origin.y += translation.height
            next.size.width += translation.width
            next.size.height -= translation.height
        case .right:
            next.size.width += translation.width
        case .bottomRight:
            next.size.width += translation.width
            next.size.height += translation.height
        case .bottom:
            next.size.height += translation.height
        case .bottomLeft:
            next.origin.x += translation.width
            next.size.width -= translation.width
            next.size.height += translation.height
        case .left:
            next.origin.x += translation.width
            next.size.width -= translation.width
        }

        if next.width < minSize {
            next.size.width = minSize
            if [.topLeft, .left, .bottomLeft].contains(handle) {
                next.origin.x = rect.maxX - minSize
            }
        }

        if next.height < minSize {
            next.size.height = minSize
            if [.topLeft, .top, .topRight].contains(handle) {
                next.origin.y = rect.maxY - minSize
            }
        }

        return clamp(next, in: bounds)
    }

    private func clamp(_ rect: CGRect, in bounds: CGSize) -> CGRect {
        var next = rect
        next.size.width = min(next.width, bounds.width)
        next.size.height = min(next.height, bounds.height)
        next.origin.x = min(max(0, next.minX), bounds.width - next.width)
        next.origin.y = min(max(0, next.minY), bounds.height - next.height)
        return next.integral
    }

    private func globalSelectionRect() -> CGRect {
        CGRect(
            x: screen.frame.minX + selection.minX,
            y: screen.frame.maxY - selection.maxY,
            width: selection.width,
            height: selection.height
        )
    }
}

private struct FrozenScreenshotView: View {
    let screen: NSScreen
    let image: NSImage
    let captureRect: CGRect

    var body: some View {
        GeometryReader { _ in
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()

                if screen.frame.intersects(captureRect) {
                    frozenCapture
                }
            }
        }
    }

    private var frozenCapture: some View {
        let rect = localRect

        return Image(nsImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }

    private var localRect: CGRect {
        CGRect(
            x: captureRect.minX - screen.frame.minX,
            y: screen.frame.maxY - captureRect.maxY,
            width: captureRect.width,
            height: captureRect.height
        )
    }
}

private extension View {
    @ViewBuilder
    func liquidGlassSurface(cornerRadius: CGFloat, isClear: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(
                isClear ? .clear.interactive() : .regular.interactive(),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            self
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.white.opacity(isClear ? 0.05 : 0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(.white.opacity(isClear ? 0.22 : 0.34), lineWidth: 1)
                )
        }
    }

    @ViewBuilder
    func liquidGlassProminentButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(.white.opacity(0.18), lineWidth: 1)
                )
        }
    }

    @ViewBuilder
    func liquidGlassIconButton(isActive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self
                .buttonStyle(.glass)
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
        } else {
            self
                .buttonStyle(.plain)
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
        }
    }

    @ViewBuilder
    func sendCircleButton(isEnabled: Bool) -> some View {
        self
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(isEnabled ? Color(nsColor: .labelColor) : Color.secondary.opacity(0.46), in: Circle())
            .shadow(color: .black.opacity(isEnabled ? 0.18 : 0.06), radius: 8, x: 0, y: 4)
    }
}

enum ScreenCapture {
    static func capture(rect: CGRect, screen: NSScreen) -> PickedImage? {
        guard let displayNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }

        let displayID = CGDirectDisplayID(displayNumber.uint32Value)
        guard let fullImage = CGDisplayCreateImage(displayID) else {
            return nil
        }

        let scale = screen.backingScaleFactor
        let localX = (rect.minX - screen.frame.minX) * scale
        let localYFromTop = (screen.frame.maxY - rect.maxY) * scale
        let pixelRect = CGRect(
            x: localX,
            y: localYFromTop,
            width: rect.width * scale,
            height: rect.height * scale
        ).integral

        guard let cropped = fullImage.cropping(to: pixelRect) else {
            return nil
        }

        let prepared = prepareForVision(cropped)
        guard let data = jpegData(from: prepared) else {
            return nil
        }

        let image = NSImage(
            cgImage: prepared,
            size: NSSize(width: prepared.width, height: prepared.height)
        )

        return PickedImage(
            data: data,
            mimeType: "image/jpeg",
            fileName: "Screen Capture",
            image: image
        )
    }

    private static func prepareForVision(_ image: CGImage) -> CGImage {
        let maxPixelDimension = 2200
        let maxDimension = max(image.width, image.height)

        guard maxDimension > maxPixelDimension else {
            return image
        }

        let scale = CGFloat(maxPixelDimension) / CGFloat(maxDimension)
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    private static func jpegData(from image: CGImage) -> Data? {
        let bitmap = NSBitmapImageRep(cgImage: image)
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.88])
    }
}
