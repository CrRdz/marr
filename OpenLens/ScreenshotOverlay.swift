import AppKit
import SwiftUI

@MainActor
final class ScreenshotOverlayController {
    var onCapture: ((PickedImage, CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private var windows: [NSWindow] = []

    func show() {
        windows = NSScreen.screens.map { screen in
            let window = NSWindow(
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
                onCapture: { [weak self] rect in
                    self?.capture(rect: rect, on: screen)
                }
            )
            window.contentView = NSHostingView(rootView: view)
            window.makeKeyAndOrderFront(nil)
            return window
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
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

    private func capture(rect: CGRect, on screen: NSScreen) {
        close()

        guard let image = ScreenCapture.capture(rect: rect, screen: screen) else {
            onCancel?()
            return
        }

        onCapture?(image, rect)
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
    let onCapture: (CGRect) -> Void

    @State private var selection: CGRect = .zero
    @State private var dragStart: CGRect = .zero
    @State private var isMovingSelection = false
    @State private var activeResizeHandle: ResizeHandle?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.38)
                    .ignoresSafeArea()

                if selection != .zero {
                    selectionLayer(in: geometry.size)
                    instructionBar(in: geometry.size)
                }
            }
            .onAppear {
                selection = defaultSelection(in: geometry.size)
            }
        }
    }

    private func selectionLayer(in bounds: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.white.opacity(0.04))
                .frame(width: selection.width, height: selection.height)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.white, lineWidth: 1.5)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.accentColor, lineWidth: 2.5)
                        .padding(-1)
                )
                .position(x: selection.midX, y: selection.midY)
                .gesture(moveGesture)

            ForEach(ResizeHandle.allCases, id: \.self) { handle in
                resizeHandle(handle)
            }

            captureControls
                .position(x: selection.midX, y: controlsY(in: bounds))
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
            .fill(Color.white)
            .frame(width: 12, height: 12)
            .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
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

    private var captureControls: some View {
        HStack(spacing: 8) {
            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark")
            }
            .help("Cancel")

            Button {
                onCapture(globalSelectionRect())
            } label: {
                Label("Capture", systemImage: "camera")
            }
            .keyboardShortcut(.return, modifiers: [])
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 12)
    }

    private func instructionBar(in size: CGSize) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "crop")
            Text("\(Int(selection.width)) x \(Int(selection.height))")
                .font(.system(.callout, design: .monospaced))
            Text("Drag the frame or handles, then capture.")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .position(x: size.width / 2, y: 34)
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

    private func controlsY(in bounds: CGSize) -> CGFloat {
        let lowerY = selection.maxY + 36
        if lowerY < bounds.height - 34 {
            return lowerY
        }

        return max(selection.minY - 36, 34)
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
