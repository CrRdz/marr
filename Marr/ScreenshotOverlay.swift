import AppKit
import Carbon
import SwiftUI

@MainActor
final class ScreenshotOverlayController {
    var onCapture: ((PickedImage, CGRect, String) -> Void)?
    var onTranslate: ((PickedImage, CGRect) -> Void)?
    var onWindowCapture: ((WindowCaptureCandidate) -> Void)?
    var onCancel: (() -> Void)?

    private var windows: [NSWindow] = []
    private var screenSnapshots: [CGDirectDisplayID: ScreenCaptureSnapshot] = [:]
    private var keyMonitor: Any?
    private var spaceChangeObserver: NSObjectProtocol?
    private var appActivationObserver: NSObjectProtocol?
    private var refreshWorkItem: DispatchWorkItem?
    private let mode: ScreenshotOverlayMode
    private var windowCandidates: [WindowCaptureCandidate]
    private let captureAfterOverlayDismissDelay: TimeInterval = 0.10

    init(
        mode: ScreenshotOverlayMode = .ask,
        windowCandidates: [WindowCaptureCandidate] = []
    ) {
        self.mode = mode
        self.windowCandidates = windowCandidates
    }

    func show() {
        close()
        installKeyMonitor()
        installEnvironmentObservers()
        buildOverlayWindows()
    }

    func close() {
        refreshWorkItem?.cancel()
        refreshWorkItem = nil
        removeKeyMonitor()
        removeEnvironmentObservers()
        closeOverlayWindows()
    }

    private func buildOverlayWindows() {
        let screens = NSScreen.screens
        screenSnapshots = Dictionary(uniqueKeysWithValues: screens.compactMap { screen in
            guard
                let displayID = ScreenCapture.displayID(for: screen),
                let snapshot = ScreenCapture.snapshot(of: screen)
            else {
                return nil
            }
            return (displayID, snapshot)
        })

        windows = screens.map { screen in
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
                snapshot: snapshot(for: screen),
                mode: mode,
                windowCandidates: windowCandidates.filter { $0.anchorRect.intersects(screen.frame) },
                onCancel: { [weak self] in
                    self?.cancel()
                },
                onCapture: { [weak self] rect, question in
                    self?.capture(rect: rect, question: question, on: screen)
                },
                onTranslate: { [weak self] rect in
                    self?.translate(rect: rect, on: screen)
                },
                onWindowCapture: { [weak self] candidate in
                    self?.captureWindow(candidate)
                }
            )
            window.contentView = NSHostingView(rootView: view.marrPreferredColorScheme())
            window.makeKeyAndOrderFront(nil)
            return window
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeOverlayWindows() {
        windows.forEach { window in
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        windows.removeAll()
        screenSnapshots.removeAll()
    }

    private func installEnvironmentObservers() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        spaceChangeObserver = notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleEnvironmentRefresh()
            }
        }

        appActivationObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                application.activationPolicy == .regular
            else {
                return
            }
            let processID = application.processIdentifier
            Task { @MainActor in
                self?.scheduleEnvironmentRefresh(preferredProcessID: processID)
            }
        }
    }

    private func removeEnvironmentObservers() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        if let spaceChangeObserver {
            notificationCenter.removeObserver(spaceChangeObserver)
            self.spaceChangeObserver = nil
        }
        if let appActivationObserver {
            notificationCenter.removeObserver(appActivationObserver)
            self.appActivationObserver = nil
        }
    }

    private func scheduleEnvironmentRefresh(preferredProcessID: pid_t? = nil) {
        let currentProcessID = ProcessInfo.processInfo.processIdentifier
        if let preferredProcessID, preferredProcessID == currentProcessID {
            return
        }

        refreshWorkItem?.cancel()
        closeOverlayWindows()

        let refresh = DispatchWorkItem { [weak self] in
            guard let self, self.keyMonitor != nil else { return }
            if let preferredProcessID {
                self.windowCandidates = WindowCapture.captureCandidates(for: preferredProcessID)
            } else {
                self.windowCandidates = WindowCapture.captureCandidatesForFrontmostApplication()
            }
            self.buildOverlayWindows()
        }
        refreshWorkItem = refresh
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: refresh)
    }

    private func cancel() {
        close()
        onCancel?()
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == kVK_Escape {
                self?.cancel()
                return nil
            }

            if self?.mode == .selectionOnly, [kVK_Return, kVK_ANSI_KeypadEnter].contains(Int(event.keyCode)) {
                NotificationCenter.default.post(name: .captureSelectionOnlyScreenshot, object: nil)
                return nil
            }

            return event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func capture(rect: CGRect, question: String, on screen: NSScreen) {
        let screenSnapshot = snapshot(for: screen)
        close()

        DispatchQueue.main.asyncAfter(deadline: .now() + captureAfterOverlayDismissDelay) { [weak self] in
            guard let self else {
                return
            }

            guard let image = ScreenCapture.capture(
                rect: rect,
                screen: screen,
                snapshot: screenSnapshot
            ) else {
                self.onCancel?()
                return
            }

            self.onCapture?(image, rect, question)
        }
    }

    private func translate(rect: CGRect, on screen: NSScreen) {
        let screenSnapshot = snapshot(for: screen)
        close()

        DispatchQueue.main.asyncAfter(deadline: .now() + captureAfterOverlayDismissDelay) { [weak self] in
            guard let self else {
                return
            }

            guard let image = ScreenCapture.capture(
                rect: rect,
                screen: screen,
                snapshot: screenSnapshot
            ) else {
                self.onCancel?()
                return
            }

            self.onTranslate?(image, rect)
        }
    }

    private func captureWindow(_ candidate: WindowCaptureCandidate) {
        close()
        onWindowCapture?(candidate)
    }

    private func snapshot(for screen: NSScreen) -> ScreenCaptureSnapshot? {
        guard let displayID = ScreenCapture.displayID(for: screen) else {
            return nil
        }
        return screenSnapshots[displayID]
    }

}

@MainActor
final class WindowCaptureOverlayController {
    var onCapture: ((WindowCaptureCandidate) -> Void)?
    var onCancel: (() -> Void)?

    private var windows: [NSWindow] = []
    private var keyMonitor: Any?
    private var spaceChangeObserver: NSObjectProtocol?
    private var appDeactivationObserver: NSObjectProtocol?
    private let candidates: [WindowCaptureCandidate]

    init(candidates: [WindowCaptureCandidate]) {
        self.candidates = candidates
    }

    func show() {
        close()
        installKeyMonitor()
        installInterruptionObservers()
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

            let screenCandidates = candidates.filter { $0.anchorRect.intersects(screen.frame) }
            let view = WindowCaptureSelectionView(
                screen: screen,
                candidates: screenCandidates,
                cancelsOnBackgroundTap: true,
                onCancel: { [weak self] in
                    self?.cancel()
                },
                onCapture: { [weak self] candidate in
                    self?.capture(candidate)
                },
                onHoverCandidate: { _ in }
            )
            window.contentView = NSHostingView(rootView: view.marrPreferredColorScheme())
            window.makeKeyAndOrderFront(nil)
            return window
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        removeKeyMonitor()
        removeInterruptionObservers()
        windows.forEach { window in
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        windows.removeAll()
    }

    private func capture(_ candidate: WindowCaptureCandidate) {
        close()
        onCapture?(candidate)
    }

    private func cancel() {
        close()
        onCancel?()
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == kVK_Escape {
                self?.cancel()
                return nil
            }

            return event
        }
    }

    private func installInterruptionObservers() {
        spaceChangeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.cancel()
            }
        }

        appDeactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.cancel()
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func removeInterruptionObservers() {
        if let spaceChangeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceChangeObserver)
            self.spaceChangeObserver = nil
        }

        if let appDeactivationObserver {
            NotificationCenter.default.removeObserver(appDeactivationObserver)
            self.appDeactivationObserver = nil
        }
    }
}

enum ScreenshotOverlayMode {
    case ask
    case selectionOnly
}

private extension Notification.Name {
    static let captureSelectionOnlyScreenshot = Notification.Name("MarrCaptureSelectionOnlyScreenshot")
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

struct ScreenshotPreviewLayout: Equatable {
    let frame: CGRect

    private enum Side {
        case top
        case bottom
        case left
        case right
    }

    private struct Candidate {
        let frame: CGRect
        let area: CGFloat
    }

    static func resolve(
        bounds: CGRect,
        selection: CGRect,
        prompt: CGRect,
        imageAspectRatio: CGFloat,
        contentInset: CGFloat = 12,
        gap: CGFloat = 14,
        maximumSize: CGSize = CGSize(width: 420, height: 320)
    ) -> ScreenshotPreviewLayout? {
        guard imageAspectRatio.isFinite, imageAspectRatio > 0 else {
            return nil
        }

        let safeBounds = bounds.insetBy(dx: contentInset, dy: contentInset)
        guard safeBounds.width > 0, safeBounds.height > 0 else {
            return nil
        }

        let avoidanceRect = selection.union(prompt).insetBy(dx: -gap, dy: -gap)
        let regions: [(Side, CGRect)] = [
            (
                .top,
                CGRect(
                    x: safeBounds.minX,
                    y: safeBounds.minY,
                    width: safeBounds.width,
                    height: max(0, min(safeBounds.maxY, avoidanceRect.minY) - safeBounds.minY)
                )
            ),
            (
                .bottom,
                CGRect(
                    x: safeBounds.minX,
                    y: max(safeBounds.minY, avoidanceRect.maxY),
                    width: safeBounds.width,
                    height: max(0, safeBounds.maxY - max(safeBounds.minY, avoidanceRect.maxY))
                )
            ),
            (
                .left,
                CGRect(
                    x: safeBounds.minX,
                    y: safeBounds.minY,
                    width: max(0, min(safeBounds.maxX, avoidanceRect.minX) - safeBounds.minX),
                    height: safeBounds.height
                )
            ),
            (
                .right,
                CGRect(
                    x: max(safeBounds.minX, avoidanceRect.maxX),
                    y: safeBounds.minY,
                    width: max(0, safeBounds.maxX - max(safeBounds.minX, avoidanceRect.maxX)),
                    height: safeBounds.height
                )
            )
        ]

        let candidates = regions.compactMap { side, region -> Candidate? in
            let availableWidth = min(maximumSize.width, region.width)
            let availableHeight = min(maximumSize.height, region.height)
            guard availableWidth > 0, availableHeight > 0 else { return nil }

            var width = availableWidth
            var height = width / imageAspectRatio
            if height > availableHeight {
                height = availableHeight
                width = height * imageAspectRatio
            }
            guard width >= 48, height >= 48 else { return nil }

            let preferredX = prompt.midX - width / 2
            let preferredY = prompt.midY - height / 2
            let origin: CGPoint
            switch side {
            case .top:
                origin = CGPoint(
                    x: min(max(preferredX, region.minX), region.maxX - width),
                    y: region.maxY - height
                )
            case .bottom:
                origin = CGPoint(
                    x: min(max(preferredX, region.minX), region.maxX - width),
                    y: region.minY
                )
            case .left:
                origin = CGPoint(
                    x: region.maxX - width,
                    y: min(max(preferredY, region.minY), region.maxY - height)
                )
            case .right:
                origin = CGPoint(
                    x: region.minX,
                    y: min(max(preferredY, region.minY), region.maxY - height)
                )
            }

            let frame = CGRect(origin: origin, size: CGSize(width: width, height: height))
            return Candidate(frame: frame, area: frame.width * frame.height)
        }

        guard let best = candidates.max(by: { $0.area < $1.area }) else {
            return nil
        }
        return ScreenshotPreviewLayout(frame: best.frame)
    }
}

struct ScreenshotSelectionView: View {
    let screen: NSScreen
    let snapshot: ScreenCaptureSnapshot?
    let mode: ScreenshotOverlayMode
    let windowCandidates: [WindowCaptureCandidate]
    let onCancel: () -> Void
    let onCapture: (CGRect, String) -> Void
    let onTranslate: (CGRect) -> Void
    let onWindowCapture: (WindowCaptureCandidate) -> Void

    @State private var question = ""
    @State private var selection: CGRect = .zero
    @State private var selectionOrigin: CGPoint?
    @State private var isDrawingSelection = false
    @State private var dragStart: CGRect = .zero
    @State private var isMovingSelection = false
    @State private var activeResizeHandle: ResizeHandle?
    @State private var isSending = false
    @State private var pendingCapture: DispatchWorkItem?
    @State private var cursorLocation: CGPoint?
    @State private var hoveredWindowCandidate: WindowCaptureCandidate?
    @State private var showsImagePreview = false
    @State private var usesRegularTranslationGlass = false
    @AppStorage(MarrBubbleColor.storageKey) private var bubbleColor = MarrBubbleColor.system.rawValue
    @FocusState private var questionFocused: Bool

    private let questionBarWidth: CGFloat = 500
    private let translationButtonDiameter: CGFloat = 42
    private let translationButtonGap: CGFloat = 10
    private let chatCapsuleScale: CGFloat = 1
    private let capsuleTransitionDuration = 0.42
    private let minimumSelectionDimension: CGFloat = 12

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                captureCanvas(in: geometry.size)

                if !hasSelection, !isDrawingSelection, !windowCandidates.isEmpty {
                    WindowCaptureSelectionView(
                        screen: screen,
                        candidates: windowCandidates,
                        cancelsOnBackgroundTap: false,
                        onCancel: {},
                        onCapture: onWindowCapture,
                        onHoverCandidate: { candidate in
                            hoveredWindowCandidate = candidate
                        }
                    )
                }

                if selection.width > 0, selection.height > 0 {
                    subtleDimmedBackdrop(in: geometry.size)
                    selectionLayer(in: geometry.size)
                }

                if mode == .ask, showsPromptBar {
                    promptBar(in: geometry.size)
                }

                if mode == .ask, showsPromptBar, !isSending {
                    translationButton(in: geometry.size)
                }

                if showsImagePreview, hasSelection {
                    imagePreviewPanel(in: geometry.size)
                }

                if !hasConfirmedSelection, !isDrawingSelection, cursorLocation != nil {
                    dragHint(in: geometry.size)
                } else if mode == .selectionOnly, hasConfirmedSelection {
                    selectionOnlyConfirmationHint(in: geometry.size)
                }
            }
            .onAppear {
                updateInitialCursorLocation()
                questionFocused = false
            }
            .onReceive(NotificationCenter.default.publisher(for: .captureSelectionOnlyScreenshot)) { _ in
                captureSelectionOnlyQuestion()
            }
            .onDisappear {
                pendingCapture?.cancel()
                pendingCapture = nil
            }
        }
    }

    private func captureCanvas(in bounds: CGSize) -> some View {
        Rectangle()
            .fill(selection.width > 0 && selection.height > 0 ? Color.clear : Color.black.opacity(0.04))
            .frame(width: bounds.width, height: bounds.height)
            .contentShape(Rectangle())
            .gesture(createSelectionGesture(in: bounds))
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    cursorLocation = location
                case .ended:
                    cursorLocation = nil
                }
            }
            .ignoresSafeArea()
    }

    private func subtleDimmedBackdrop(in bounds: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(.black.opacity(0.08))
                .frame(width: bounds.width, height: selection.minY)

            Rectangle()
                .fill(.black.opacity(0.08))
                .frame(width: bounds.width, height: max(0, bounds.height - selection.maxY))
                .position(x: bounds.width / 2, y: selection.maxY + max(0, bounds.height - selection.maxY) / 2)

            Rectangle()
                .fill(.black.opacity(0.08))
                .frame(width: selection.minX, height: selection.height)
                .position(x: selection.minX / 2, y: selection.midY)

            Rectangle()
                .fill(.black.opacity(0.08))
                .frame(width: max(0, bounds.width - selection.maxX), height: selection.height)
                .position(x: selection.maxX + max(0, bounds.width - selection.maxX) / 2, y: selection.midY)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
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

            if !isDrawingSelection {
                ForEach(ResizeHandle.allCases, id: \.self) { handle in
                    resizeHandle(handle)
                }
            }
        }
    }

    private func createSelectionGesture(in bounds: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .onChanged { value in
                guard !isSending else { return }

                if !isDrawingSelection {
                    selectionOrigin = clampedPoint(value.startLocation, in: bounds)
                    isDrawingSelection = true
                    hoveredWindowCandidate = nil
                    questionFocused = false
                }

                guard let selectionOrigin else { return }
                selection = rectangle(
                    from: selectionOrigin,
                    to: clampedPoint(value.location, in: bounds)
                )
            }
            .onEnded { value in
                guard !isSending else { return }

                if let selectionOrigin {
                    selection = rectangle(
                        from: selectionOrigin,
                        to: clampedPoint(value.location, in: bounds)
                    )
                }

                selectionOrigin = nil
                isDrawingSelection = false

                guard hasSelection else {
                    selection = .zero
                    return
                }

                selection = selection.integral
                if mode == .ask {
                    DispatchQueue.main.async {
                        questionFocused = true
                    }
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
            if hasConfirmedSelection {
                Button {
                    showsImagePreview.toggle()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "photo")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Image")
                            .font(MarrTypography.body(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.primary.opacity(0.90))
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(
                        showsImagePreview
                            ? bubbleTint.opacity(0.18)
                            : Color.secondary.opacity(0.13),
                        in: Capsule()
                    )
                    .overlay(
                        Capsule()
                            .stroke(
                                showsImagePreview ? bubbleTint.opacity(0.42) : Color.clear,
                                lineWidth: 0.8
                            )
                    )
                }
                .buttonStyle(.plain)
                .disabled(snapshot == nil)
                .help(showsImagePreview ? "Hide screenshot preview" : "Preview screenshot")
                .transition(.scale(scale: 0.92).combined(with: .opacity))
            } else if hoveredWindowCandidate != nil {
                HStack(spacing: 7) {
                    Image(systemName: "macwindow")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Window")
                        .font(MarrTypography.body(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(.primary.opacity(0.90))
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(Color.secondary.opacity(0.13), in: Capsule())
                .transition(.scale(scale: 0.92).combined(with: .opacity))
            }

            TextField(questionPlaceholder, text: $question, axis: .vertical)
                .textFieldStyle(.plain)
                .font(MarrTypography.body(size: 15))
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
            .sendCircleButton(isEnabled: canSend, color: bubbleTint, foregroundColor: bubbleForegroundColor)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!canSend)
            .help("Send")
        }
        .disabled(isSending)
        .padding(.leading, 14)
        .padding(.trailing, 7)
        .padding(.vertical, 6)
        .frame(width: questionBarWidth)
        .frame(minHeight: 46)
        .marrGlassSurface(cornerRadius: 23, isClear: true)
        .overlay(
            RoundedRectangle(cornerRadius: 23, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.16), radius: 18, x: 0, y: 10)
        .shadow(color: .white.opacity(0.10), radius: 1, x: 0, y: -1)
        .animation(.easeOut(duration: 0.18), value: hasConfirmedSelection)
    }

    private func promptBar(in size: CGSize) -> some View {
        questionControls
            .allowsHitTesting(hasConfirmedSelection)
            .position(promptBarPosition(in: size))
    }

    private func translationButton(in size: CGSize) -> some View {
        Button {
            translateSelection()
        } label: {
            Image(systemName: "translate")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: translationButtonDiameter, height: translationButtonDiameter)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(canTranslate ? bubbleTint : .secondary.opacity(0.72))
        .marrGlassSurface(
            cornerRadius: translationButtonDiameter / 2,
            isClear: !usesRegularTranslationGlass
        )
        .overlay(
            Circle()
                .stroke(.white.opacity(0.18), lineWidth: 0.8)
                .allowsHitTesting(false)
        )
        .shadow(color: .black.opacity(0.16), radius: 12, x: 0, y: 7)
        .disabled(!canTranslate)
        .allowsHitTesting(hasConfirmedSelection)
        .help("Translate")
        .position(translationButtonPosition(in: size))
        .zIndex(2)
        .onAppear {
            updateTranslationButtonGlass(in: size)
        }
        .onChange(of: selection) { _, _ in
            updateTranslationButtonGlass(in: size)
        }
        .transition(.scale(scale: 0.90).combined(with: .opacity))
    }

    private func dragHint(in size: CGSize) -> some View {
        Text("Drag to take a screenshot")
            .font(.system(size: 12, weight: .regular))
            .foregroundStyle(.black.opacity(0.92))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .captureLabelSurface()
            .position(dragHintPosition(in: size))
            .allowsHitTesting(false)
    }

    private func selectionOnlyConfirmationHint(in size: CGSize) -> some View {
        Text("Press Return to add screenshot")
            .font(MarrTypography.body(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.96))
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(.black.opacity(0.72), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.20), lineWidth: 0.8))
            .shadow(color: .black.opacity(0.22), radius: 8, x: 0, y: 4)
            .position(x: toolbarX(in: size), y: toolbarY(in: size))
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func imagePreviewPanel(in size: CGSize) -> some View {
        if
            let previewImage,
            let layout = ScreenshotPreviewLayout.resolve(
                bounds: CGRect(origin: .zero, size: size),
                selection: selection,
                prompt: promptBarRect(in: size),
                imageAspectRatio: previewImage.size.width / max(1, previewImage.size.height)
            )
        {

            Image(nsImage: previewImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: layout.frame.width, height: layout.frame.height)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.26), radius: 18, x: 0, y: 10)
                .position(x: layout.frame.midX, y: layout.frame.midY)
                .allowsHitTesting(false)
        }
    }

    private func promptBarRect(in bounds: CGSize) -> CGRect {
        let position = promptBarPosition(in: bounds)
        return CGRect(
            x: position.x - questionBarWidth / 2 - translationButtonGap - translationButtonDiameter,
            y: position.y - 27,
            width: questionBarWidth + translationButtonGap + translationButtonDiameter,
            height: 54
        )
    }

    private var canSend: Bool {
        hasConfirmedSelection
            && !isSending
            && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var questionPlaceholder: String {
        hoveredWindowCandidate == nil
            ? "What can I help you with today?"
            : "Click a window to capture"
    }

    private var canTranslate: Bool {
        hasConfirmedSelection && !isSending
    }

    private var previewImage: NSImage? {
        guard let snapshot else { return nil }
        return ScreenCapture.preview(
            rect: globalSelectionRect(),
            snapshot: snapshot
        )
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

    private func captureSelectionOnlyQuestion() {
        guard mode == .selectionOnly, hasConfirmedSelection, !isSending, NSApp.keyWindow?.screen == screen else {
            return
        }

        isSending = true
        onCapture(globalSelectionRect(), "")
    }

    private func sendQuestion() {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSending, !trimmedQuestion.isEmpty else {
            return
        }

        let rect = globalSelectionRect()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            questionFocused = false
        }

        withAnimation(.easeInOut(duration: capsuleTransitionDuration)) {
            isSending = true
        }

        let capture = DispatchWorkItem {
            onCapture(rect, trimmedQuestion)
        }
        pendingCapture = capture
        DispatchQueue.main.asyncAfter(deadline: .now() + capsuleTransitionDuration + 0.08, execute: capture)
    }

    private func translateSelection() {
        guard canTranslate else {
            return
        }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            questionFocused = false
            isSending = true
        }

        onTranslate(globalSelectionRect())
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
        let halfWidth = questionBarWidth / 2
        let minimumX = halfWidth + translationButtonDiameter + translationButtonGap + 12
        let maximumX = bounds.width - halfWidth - 12
        guard minimumX <= maximumX else {
            return bounds.width / 2
        }
        return min(max(selection.midX, minimumX), maximumX)
    }

    private func toolbarY(in bounds: CGSize) -> CGFloat {
        let toolbarHeight: CGFloat = 54
        let preferredBelow = selection.maxY + toolbarHeight / 2 + 14
        if preferredBelow <= bounds.height - toolbarHeight / 2 - 8 {
            return preferredBelow
        }

        return max(selection.minY - toolbarHeight / 2 - 14, toolbarHeight / 2 + 8)
    }

    private func chatCapsulePosition(in bounds: CGSize) -> CGPoint {
        let visibleFrame = screen.visibleFrame
        let panelWidth: CGFloat = 544
        let panelMargin: CGFloat = 22
        let panelContentPadding: CGFloat = 12
        let composerVisualHeight: CGFloat = 46

        let globalX = visibleFrame.maxX - panelMargin - panelWidth / 2
        let globalY = visibleFrame.minY + panelMargin + panelContentPadding + composerVisualHeight / 2

        let localX = globalX - screen.frame.minX
        let localY = screen.frame.maxY - globalY
        let halfWidth = questionBarWidth * chatCapsuleScale / 2
        let halfHeight = composerVisualHeight * chatCapsuleScale / 2

        return CGPoint(
            x: min(max(localX, halfWidth + 12), bounds.width - halfWidth - 12),
            y: min(max(localY, halfHeight + 12), bounds.height - halfHeight - 12)
        )
    }

    private func promptBarPosition(in bounds: CGSize) -> CGPoint {
        if isSending {
            return chatCapsulePosition(in: bounds)
        }
        if hasConfirmedSelection {
            return CGPoint(x: toolbarX(in: bounds), y: toolbarY(in: bounds))
        }
        return initialPromptBarPosition(in: bounds)
    }

    private func translationButtonPosition(in bounds: CGSize) -> CGPoint {
        let promptPosition = promptBarPosition(in: bounds)
        return CGPoint(
            x: promptPosition.x - questionBarWidth / 2 - translationButtonGap - translationButtonDiameter / 2,
            y: promptPosition.y
        )
    }

    private func updateTranslationButtonGlass(in bounds: CGSize) {
        let position = translationButtonPosition(in: bounds)
        let localRect = CGRect(
            x: position.x - translationButtonDiameter / 2,
            y: position.y - translationButtonDiameter / 2,
            width: translationButtonDiameter,
            height: translationButtonDiameter
        )
        let globalRect = CGRect(
            x: screen.frame.minX + localRect.minX,
            y: screen.frame.maxY - localRect.maxY,
            width: localRect.width,
            height: localRect.height
        )
        usesRegularTranslationGlass = BackgroundBrightnessSampler.isNearlyWhite(
            in: globalRect,
            on: screen
        )
    }

    private func initialPromptBarPosition(in bounds: CGSize) -> CGPoint {
        let visibleFrame = screen.visibleFrame
        let globalY = visibleFrame.minY + 22 + 23
        let localY = screen.frame.maxY - globalY
        return CGPoint(
            x: bounds.width / 2,
            y: min(max(localY, 35), bounds.height - 35)
        )
    }

    private func dragHintPosition(in bounds: CGSize) -> CGPoint {
        guard let cursorLocation else {
            return CGPoint(x: bounds.width / 2, y: bounds.height / 2)
        }

        let hintHalfWidth: CGFloat = 96
        let hintHalfHeight: CGFloat = 16
        let horizontalGap: CGFloat = 14
        let verticalGap: CGFloat = 10
        let preferredX = cursorLocation.x + horizontalGap + hintHalfWidth
        let fallbackX = cursorLocation.x - horizontalGap - hintHalfWidth
        let preferredY = cursorLocation.y + verticalGap + hintHalfHeight
        let fallbackY = cursorLocation.y - verticalGap - hintHalfHeight

        return CGPoint(
            x: preferredX + hintHalfWidth <= bounds.width
                ? preferredX
                : max(hintHalfWidth + 8, fallbackX),
            y: preferredY + hintHalfHeight <= bounds.height
                ? preferredY
                : max(hintHalfHeight + 8, fallbackY)
        )
    }

    private func updateInitialCursorLocation() {
        let globalLocation = NSEvent.mouseLocation
        guard screen.frame.contains(globalLocation) else {
            cursorLocation = nil
            return
        }

        cursorLocation = CGPoint(
            x: globalLocation.x - screen.frame.minX,
            y: screen.frame.maxY - globalLocation.y
        )
    }

    private func rectangle(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    private func clampedPoint(_ point: CGPoint, in bounds: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(0, point.x), bounds.width),
            y: min(max(0, point.y), bounds.height)
        )
    }

    private var hasSelection: Bool {
        selection.width >= minimumSelectionDimension
            && selection.height >= minimumSelectionDimension
    }

    private var hasConfirmedSelection: Bool {
        hasSelection && !isDrawingSelection
    }

    private var showsPromptBar: Bool {
        cursorLocation != nil
            || hoveredWindowCandidate != nil
            || selection.width > 0
            || selection.height > 0
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

private struct WindowCaptureSelectionView: View {
    let screen: NSScreen
    let candidates: [WindowCaptureCandidate]
    let cancelsOnBackgroundTap: Bool
    let onCancel: () -> Void
    let onCapture: (WindowCaptureCandidate) -> Void
    let onHoverCandidate: (WindowCaptureCandidate?) -> Void

    @State private var hoveredWindowID: CGWindowID?
    @AppStorage(MarrAccentColor.storageKey) private var accentColor = MarrAccentColor.system.rawValue

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if cancelsOnBackgroundTap {
                    Color.clear
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                        .onTapGesture(perform: onCancel)
                }

                ForEach(candidates) { candidate in
                    captureLabel(for: candidate, in: geometry.size)
                }
            }
        }
    }

    private func captureLabel(for candidate: WindowCaptureCandidate, in size: CGSize) -> some View {
        let rect = localRect(for: candidate)
        let isHovered = hoveredWindowID == candidate.windowID
        let labelOrigin = labelOrigin(for: candidate, rect: rect, in: size)

        return Button {
            onCapture(candidate)
        } label: {
            targetLabel(for: candidate, in: rect.size, isStageManager: candidate.isStageManagerSurface, isHovered: isHovered)
        }
        .buttonStyle(.plain)
        .offset(x: labelOrigin.x, y: labelOrigin.y)
        .onHover { isHovering in
            hoveredWindowID = isHovering ? candidate.windowID : nil
            onHoverCandidate(isHovering ? candidate : nil)
        }
    }

    private func targetLabel(
        for candidate: WindowCaptureCandidate,
        in size: CGSize,
        isStageManager: Bool,
        isHovered: Bool
    ) -> some View {
        let text = labelText(for: candidate)
        let textWidth = labelTextWidth(for: text, targetSize: size, isStageManager: isStageManager)

        return Text(text)
            .font(.system(size: labelFontSize(for: size), weight: .regular))
            .foregroundStyle(isHovered ? selectedAccent.foregroundColor : .black.opacity(0.92))
            .lineLimit(isStageManager ? 5 : 2)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: textWidth, alignment: .leading)
            .padding(.horizontal, labelHorizontalPadding(for: size))
            .padding(.vertical, labelVerticalPadding(for: size))
            .captureLabelSurface(
                isHighlighted: isHovered,
                highlightColor: selectedAccent.color
            )
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private func labelText(for candidate: WindowCaptureCandidate) -> String {
        "Capture \(candidate.title)"
    }

    private func labelTextWidth(
        for text: String,
        targetSize size: CGSize,
        isStageManager: Bool
    ) -> CGFloat {
        let measuredWidth = measuredTextWidth(text, fontSize: labelFontSize(for: size))

        if isStageManager {
            return min(max(measuredWidth, 76), min(max(size.width * 0.40, 104), 126))
        }

        let maxWidth: CGFloat
        if max(size.width, size.height) > 360 {
            maxWidth = min(max(size.width * 0.62, 220), 420)
        } else if max(size.width, size.height) > 180 {
            maxWidth = min(max(size.width * 0.58, 126), 220)
        } else {
            maxWidth = min(max(size.width * 0.76, 96), 160)
        }

        return min(max(measuredWidth, 54), maxWidth)
    }

    private func labelVisualWidth(
        for candidate: WindowCaptureCandidate,
        size: CGSize,
        isStageManager: Bool
    ) -> CGFloat {
        labelTextWidth(
            for: labelText(for: candidate),
            targetSize: size,
            isStageManager: isStageManager
        ) + labelHorizontalPadding(for: size) * 2
    }

    private func labelVisualHeight(
        for candidate: WindowCaptureCandidate,
        size: CGSize,
        isStageManager: Bool
    ) -> CGFloat {
        let text = labelText(for: candidate)
        let textWidth = labelTextWidth(for: text, targetSize: size, isStageManager: isStageManager)
        let measuredWidth = measuredTextWidth(text, fontSize: labelFontSize(for: size))
        let maxLines: CGFloat = isStageManager ? 5 : 2
        let lineCount = min(max(1, ceil(measuredWidth / max(1, textWidth))), maxLines)

        return lineCount * (labelFontSize(for: size) + 3) + labelVerticalPadding(for: size) * 2
    }

    private func measuredTextWidth(_ text: String, fontSize: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .regular)
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        return ceil(width)
    }

    private func labelInset(for size: CGSize) -> CGFloat {
        min(max(min(size.width, size.height) * 0.045, 8), 16)
    }

    private func labelFontSize(for size: CGSize) -> CGFloat {
        min(size.width, size.height) < 110 ? 10 : 12
    }

    private func labelHorizontalPadding(for size: CGSize) -> CGFloat {
        min(size.width, size.height) < 110 ? 6 : 9
    }

    private func labelVerticalPadding(for size: CGSize) -> CGFloat {
        min(size.width, size.height) < 110 ? 3 : 5
    }

    private func labelOrigin(for candidate: WindowCaptureCandidate, rect: CGRect, in containerSize: CGSize) -> CGPoint {
        let inset = labelInset(for: rect.size)
        let estimatedWidth = labelVisualWidth(
            for: candidate,
            size: rect.size,
            isStageManager: candidate.isStageManagerSurface
        )
        let estimatedHeight = labelVisualHeight(
            for: candidate,
            size: rect.size,
            isStageManager: candidate.isStageManagerSurface
        )
        let preferredX: CGFloat
        let preferredY: CGFloat
        if candidate.isStageManagerSurface {
            preferredX = rect.minX + rect.width * 0.31
            preferredY = rect.minY + rect.height * 0.28
        } else {
            preferredX = rect.minX + inset
            preferredY = rect.minY + inset
        }
        let x = min(max(preferredX, 6), max(6, containerSize.width - estimatedWidth - 6))
        let y = min(max(preferredY, 6), max(6, containerSize.height - estimatedHeight - 6))
        return CGPoint(x: x, y: y)
    }

    private func localRect(for candidate: WindowCaptureCandidate) -> CGRect {
        let rect = candidate.anchorRect
        return CGRect(
            x: rect.minX - screen.frame.minX,
            y: screen.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private var selectedAccent: MarrAccentColor {
        MarrAccentColor.resolve(accentColor)
    }
}

private extension View {
    func captureLabelSurface(
        isHighlighted: Bool = false,
        highlightColor: Color = .clear
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        return self
            .background {
                if isHighlighted {
                    shape.fill(highlightColor)
                }
            }
            .marrGlassSurface(cornerRadius: 6, isClear: true)
            .overlay(
                shape.stroke(
                    isHighlighted ? highlightColor.opacity(0.90) : .white.opacity(0.18),
                    lineWidth: 0.8
                )
                .allowsHitTesting(false)
            )
            .shadow(color: .black.opacity(0.10), radius: 10, x: 0, y: 5)
            .shadow(color: .white.opacity(0.12), radius: 1, x: 0, y: -1)
    }

    @ViewBuilder
    func sendCircleButton(isEnabled: Bool, color: Color, foregroundColor: Color) -> some View {
        self
            .buttonStyle(.plain)
            .foregroundStyle(isEnabled ? foregroundColor : .white)
            .background(isEnabled ? color : Color.secondary.opacity(0.46), in: Circle())
            .shadow(color: .black.opacity(isEnabled ? 0.18 : 0.06), radius: 8, x: 0, y: 4)
    }
}

struct ScreenCaptureSnapshot {
    fileprivate let image: CGImage
    fileprivate let screenFrame: CGRect
    fileprivate let pixelScaleX: CGFloat
    fileprivate let pixelScaleY: CGFloat

    init(image: CGImage, screenFrame: CGRect) {
        self.image = image
        self.screenFrame = screenFrame
        pixelScaleX = CGFloat(image.width) / screenFrame.width
        pixelScaleY = CGFloat(image.height) / screenFrame.height
    }

    fileprivate func croppedImage(in rect: CGRect) -> CGImage? {
        let requestedPixelRect = CGRect(
            x: (rect.minX - screenFrame.minX) * pixelScaleX,
            y: (screenFrame.maxY - rect.maxY) * pixelScaleY,
            width: rect.width * pixelScaleX,
            height: rect.height * pixelScaleY
        ).integral
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let pixelRect = requestedPixelRect.intersection(imageBounds).integral

        guard !pixelRect.isNull, pixelRect.width >= 1, pixelRect.height >= 1 else {
            return nil
        }

        return image.cropping(to: pixelRect)
    }
}

enum ScreenCapture {
    static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        guard
            let displayNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else {
            return nil
        }
        return CGDirectDisplayID(displayNumber.uint32Value)
    }

    static func snapshot(of screen: NSScreen) -> ScreenCaptureSnapshot? {
        guard
            let displayID = displayID(for: screen),
            let image = CGDisplayCreateImage(displayID),
            screen.frame.width > 0,
            screen.frame.height > 0
        else {
            return nil
        }

        return ScreenCaptureSnapshot(image: image, screenFrame: screen.frame)
    }

    static func preview(rect: CGRect, snapshot: ScreenCaptureSnapshot) -> NSImage? {
        guard let cropped = snapshot.croppedImage(in: rect) else {
            return nil
        }
        return NSImage(
            cgImage: cropped,
            size: NSSize(width: cropped.width, height: cropped.height)
        )
    }

    static func capture(
        rect: CGRect,
        screen: NSScreen,
        snapshot: ScreenCaptureSnapshot? = nil
    ) -> PickedImage? {
        guard
            let source = snapshot ?? self.snapshot(of: screen),
            let cropped = source.croppedImage(in: rect)
        else {
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
