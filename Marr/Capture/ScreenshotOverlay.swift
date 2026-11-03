import AppKit
import Carbon
import SwiftUI

@MainActor
final class ScreenshotPinnedImages: ObservableObject {
    @Published var images: [PickedImage] = []
}

@MainActor
final class ScreenshotOverlayController {
    var onCapture: ((PickedImage, CGRect, CGRect, String) -> Void)?
    var onCaptureBatch: (([PickedImage], CGRect, String) -> Void)?
    var onTranslate: ((PickedImage, CGRect, ScreenCaptureSnapshot) -> Void)?
    var onCancel: (() -> Void)?

    private let pinnedImages = ScreenshotPinnedImages()
    private var windows: [NSWindow] = []
    private var screenSnapshots: [CGDirectDisplayID: ScreenCaptureSnapshot] = [:]
    private var keyMonitor: Any?
    private var spaceChangeObserver: NSObjectProtocol?
    private var appActivationObserver: NSObjectProtocol?
    private var refreshWorkItem: DispatchWorkItem?
    private let captureAfterOverlayDismissDelay: TimeInterval = 0.10

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
            let window = ScreenshotOverlayPanel.make(on: screen)

            let view = ScreenshotSelectionView(
                screen: screen,
                snapshot: snapshot(for: screen),
                onCancel: { [weak self] in
                    self?.cancel()
                },
                onCapture: { [weak self] rect, answerAnchorRect, question, annotations in
                    self?.capture(
                        rect: rect,
                        answerAnchorRect: answerAnchorRect,
                        question: question,
                        annotations: annotations,
                        on: screen
                    )
                },
                onTranslate: { [weak self] rect in
                    self?.translate(rect: rect, on: screen)
                },
                onCaptureBatch: { [weak self] images, anchor, question in
                    self?.close()
                    self?.onCaptureBatch?(images, anchor, question)
                },
                pinnedImages: pinnedImages
            )
            window.contentView = NSHostingView(rootView: view.marrPreferredColorScheme())
            return window
        }

        ScreenshotOverlayPanel.present(windows)
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

            if [kVK_Delete, kVK_ForwardDelete].contains(Int(event.keyCode)),
               event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
                let request = ScreenshotAnnotationDeleteRequest()
                NotificationCenter.default.post(name: .deleteSelectedScreenshotAnnotation, object: request)
                if request.handled { return nil }
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

    private func capture(
        rect: CGRect,
        answerAnchorRect: CGRect,
        question: String,
        annotations: [ScreenshotAnnotation],
        on screen: NSScreen
    ) {
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

            guard let annotated = ScreenCapture.annotating(image, with: annotations, selectionSize: rect.size) else {
                self.onCancel?()
                return
            }
            self.onCapture?(annotated, rect, answerAnchorRect, question)
        }
    }

    private func translate(rect: CGRect, on screen: NSScreen) {
        guard
            let screenSnapshot = snapshot(for: screen),
            let image = ScreenCapture.capture(
                rect: rect,
                screen: screen,
                snapshot: screenSnapshot
            )
        else {
            close()
            onCancel?()
            return
        }

        close()
        onTranslate?(image, rect, screenSnapshot)
    }

    private func snapshot(for screen: NSScreen) -> ScreenCaptureSnapshot? {
        guard let displayID = ScreenCapture.displayID(for: screen) else {
            return nil
        }
        return screenSnapshots[displayID]
    }

}

private final class ScreenshotAnnotationDeleteRequest {
    var handled = false
}

private struct ScreenshotPromptHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 54
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private extension Notification.Name {
    static let deleteSelectedScreenshotAnnotation = Notification.Name("MarrDeleteSelectedScreenshotAnnotation")
}

/// Capture must join the user's current Space without activating Marr's main
/// window, which may live on a different desktop from a full-screen app.
final class ScreenshotOverlayPanel: NSPanel {
    static func make(on screen: NSScreen) -> ScreenshotOverlayPanel {
        let panel = ScreenshotOverlayPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        // Enabling floating-panel behavior resets the native window level.
        // Apply the capture level afterwards so full-screen content stays below it.
        panel.level = .screenSaver
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [
            .canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications,
            .stationary, .ignoresCycle
        ]
        panel.ignoresMouseEvents = false
        return panel
    }

    static func present(_ windows: [NSWindow]) {
        // Order every display's overlay even while Marr is in the background.
        // A nonactivating panel can own keyboard input (Escape, Return and the
        // question field) without switching the frontmost app or its Space.
        windows.forEach { $0.orderFrontRegardless() }
        let target = windows.first { $0.frame.contains(NSEvent.mouseLocation) } ?? windows.first
        target?.makeKey()
    }

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }
}

private enum SelectionResizeHandle: CaseIterable, Hashable {
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
        case .left, .right:
            return .resizeLeftRight
        case .top, .bottom, .topLeft, .topRight, .bottomRight, .bottomLeft:
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
    let onCancel: () -> Void
    let onCapture: (CGRect, CGRect, String, [ScreenshotAnnotation]) -> Void
    let onTranslate: (CGRect) -> Void
    var onCaptureBatch: (([PickedImage], CGRect, String) -> Void)? = nil

    @ObservedObject var pinnedImages = ScreenshotPinnedImages()
    @State private var pinHovered = false
    @State private var showsScreenshotTray = false
    @State private var question = ""
    @State private var selection: CGRect = .zero
    @State private var selectionOrigin: CGPoint?
    @State private var isDrawingSelection = false
    @State private var dragStart: CGRect = .zero
    @State private var isMovingSelection = false
    @State private var activeResizeHandle: SelectionResizeHandle?
    @State private var isSending = false
    @State private var pendingCapture: DispatchWorkItem?
    @State private var cursorLocation: CGPoint?
    @State private var dragHintSize = CGSize.zero
    @State private var showsImagePreview = false
    @State private var annotations: [ScreenshotAnnotation] = []
    @State private var annotatedPreview: NSImage?
    @State private var draftAnnotation: ScreenshotAnnotation?
    @State private var annotationTool: ScreenshotAnnotationTool?
    @AppStorage("screenshotCompanionToolsExpanded") private var toolsExpanded = false
    @State private var promptHeight: CGFloat = 54
    @State private var selectedAnnotationIndex: Int?
    @State private var movingAnnotation: ScreenshotAnnotation?
    @State private var annotationGestureStarted = false
    @State private var annotationUndoStack: [[ScreenshotAnnotation]] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedSlashCommandIndex = 0
    @State private var dismissedSlashMenuInput: String?
    @AppStorage(MarrBubbleColor.storageKey) private var bubbleColor = MarrBubbleColor.system.rawValue
    @FocusState private var questionFocused: Bool

    private let questionBarWidth: CGFloat = 500
    private let questionBarHeight: CGFloat = 46
    private let capsuleTransitionDuration = 0.24
    private let minimumSelectionDimension: CGFloat = 12

    private var companionPhase: MarrCompanionPhase {
        .capture(sending: isSending,
                 selecting: isDrawingSelection || isMovingSelection || activeResizeHandle != nil,
                 annotating: annotationTool != nil || annotationGestureStarted,
                 hasSelection: hasConfirmedSelection, hasPinnedImages: !pinnedImages.images.isEmpty)
    }

    private func companionGaze(from origin: CGPoint) -> CGPoint {
        let target: CGPoint
        if isDrawingSelection, let cursorLocation {
            target = cursorLocation
        } else if selection.width > 0, selection.height > 0 {
            target = CGPoint(x: selection.midX, y: selection.midY)
        } else if let cursorLocation {
            target = cursorLocation
        } else { return .zero }
        return CGPoint(x: (target.x - origin.x) / 220, y: (target.y - origin.y) / 220)
    }

    private var questionCompanionGaze: CGPoint {
        let center = promptBarPosition(in: screen.frame.size)
        return companionGaze(from: CGPoint(x: center.x - questionBarWidth / 2 + 31, y: center.y))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                captureCanvas(in: geometry.size)

                if selection.width > 0, selection.height > 0 {
                    subtleDimmedBackdrop(in: geometry.size)
                    selectionLayer(in: geometry.size)
                }
                if hasConfirmedSelection, !isSending, onCaptureBatch != nil {
                    Button { pinSelection() } label: {
                        MarrIcon("pin.fill", size: MarrUI.Icon.navigation)
                            .frame(width: 30, height: 30)
                            .background(.regularMaterial, in: Circle())
                            .opacity(pinHovered ? 1 : 0)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { pinHovered = $0 }
                    .help("Pin screenshot and capture another")
                    .position(x: selection.maxX - 24, y: selection.minY + 24)
                }

                if showsPromptBar {
                    promptBar(in: geometry.size)
                }

                if hasConfirmedSelection, !isSending {
                    screenshotTools(in: geometry.size)
                }

                if showsImagePreview, hasSelection, annotationTool == nil {
                    imagePreviewPanel(in: geometry.size)
                }

                if !hasConfirmedSelection, cursorLocation != nil {
                    dragHint(in: geometry.size)
                }
            }
            .onAppear {
                updateInitialCursorLocation()
                questionFocused = false
            }
            .onReceive(NotificationCenter.default.publisher(for: .deleteSelectedScreenshotAnnotation)) { notification in
                guard let request = notification.object as? ScreenshotAnnotationDeleteRequest,
                      NSApp.keyWindow?.screen == screen,
                      !questionFocused, !isSending, !annotationGestureStarted,
                      let index = selectedAnnotationIndex, annotations.indices.contains(index) else { return }
                annotationUndoStack.append(annotations)
                annotations.remove(at: index)
                selectedAnnotationIndex = nil
                refreshAnnotatedPreview()
                request.handled = true
            }
            .onDisappear {
                pendingCapture?.cancel()
                pendingCapture = nil
            }
            .onChange(of: question) { _, nextQuestion in
                selectedSlashCommandIndex = 0
                if dismissedSlashMenuInput != nextQuestion {
                    dismissedSlashMenuInput = nil
                }
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
                        .stroke(.white.opacity(0.90), lineWidth: 1.25)
                )
                .overlay(
                    Rectangle()
                        .stroke(.black.opacity(0.22), lineWidth: 0.8)
                        .padding(1)
                )
                .contentShape(Rectangle())
                .position(x: selection.midX, y: selection.midY)
                .gesture(moveGesture)

            if hasConfirmedSelection {
                annotationLayer
            }

            if !isDrawingSelection, annotationTool == nil {
                ForEach(SelectionResizeHandle.allCases, id: \.self) { handle in
                    resizeHitTarget(handle)
                }
            }
        }
    }

    private func createSelectionGesture(in bounds: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .onChanged { value in
                guard !isSending else { return }

                cursorLocation = clampedPoint(value.location, in: bounds)

                if !isDrawingSelection {
                    annotations.removeAll()
                    annotationUndoStack.removeAll()
                    selectedAnnotationIndex = nil
                    draftAnnotation = nil
                    annotationTool = nil
                    selectionOrigin = clampedPoint(value.startLocation, in: bounds)
                    isDrawingSelection = true
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
                DispatchQueue.main.async {
                    questionFocused = true
                }
            }
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isMovingSelection {
                    selectedAnnotationIndex = nil
                    dragStart = selection
                    isMovingSelection = true
                }

                let next = dragStart.offsetBy(dx: value.translation.width, dy: value.translation.height)
                selection = clamp(next, in: screen.frame.size)
            }
            .onEnded { _ in
                isMovingSelection = false
                refreshAnnotatedPreview()
            }
    }

    private func resizeHitTarget(_ handle: SelectionResizeHandle) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(width: hitTargetSize(for: handle).width, height: hitTargetSize(for: handle).height)
            .position(position(for: handle))
            .onHover { inside in
                (inside ? handle.cursor : .arrow).set()
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if activeResizeHandle != handle {
                            dragStart = selection
                            activeResizeHandle = handle
                        }
                        selection = resize(
                            dragStart,
                            handle: handle,
                            translation: value.translation,
                            bounds: screen.frame.size
                        )
                    }
                    .onEnded { _ in
                        activeResizeHandle = nil
                        refreshAnnotatedPreview()
                    }
            )
    }

    private var screenshotThumbnails: [NSImage] {
        var images = pinnedImages.images.map(\.image)
        if hasConfirmedSelection, let previewImage { images.append(previewImage) }
        return images
    }

    private var screenshotThumbnailStack: some View {
        let images = screenshotThumbnails
        let visible = Array(images.suffix(3))
        return Button {
            if images.count == 1, pinnedImages.images.isEmpty {
                showsImagePreview.toggle()
            } else {
                showsScreenshotTray.toggle()
            }
        } label: {
            ZStack(alignment: .topLeading) {
                ForEach(visible.indices, id: \.self) { index in
                    let depth = visible.count - 1 - index
                    Image(nsImage: visible[index])
                        .resizable().scaledToFill()
                        .frame(width: 38, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.5), lineWidth: 1))
                        .shadow(color: .black.opacity(0.16), radius: 2, y: 1)
                        .offset(x: CGFloat(depth) * 5, y: -CGFloat(depth) * 2)
                }
            }
            .frame(width: 38 + CGFloat(max(0, visible.count - 1)) * 5, height: 30, alignment: .topLeading)
            .overlay(alignment: .bottomTrailing) {
                if images.count > 1 {
                    Text("\(images.count)")
                        .font(MarrTypography.font(.badge, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.regularMaterial, in: Capsule())
                        .offset(x: 3, y: 2)
                }
            }
            .padding(.top, 4)
        }
        .buttonStyle(.plain)
        .help("\(images.count) screenshot(s) · Click to view")
        .popover(isPresented: $showsScreenshotTray) {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(pinnedImages.images.indices, id: \.self) { index in
                        HStack(spacing: 10) {
                            Image(nsImage: pinnedImages.images[index].image)
                                .resizable().scaledToFit()
                                .frame(width: 150, height: 90)
                            Button {
                                pinnedImages.images.remove(at: index)
                                if pinnedImages.images.isEmpty { showsScreenshotTray = false }
                            } label: {
                                MarrIcon("xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .help("Remove screenshot")
                        }
                    }
                    if hasConfirmedSelection, let previewImage {
                        Image(nsImage: previewImage)
                            .resizable().scaledToFit()
                            .frame(width: 150, height: 90)
                    }
                }
                .padding(12)
            }
            .frame(width: 220, height: min(320, CGFloat(images.count) * 100 + 24))
        }
    }

    private var questionControls: some View {
        HStack(spacing: 10) {
            if !hasConfirmedSelection || isSending {
                MarrCompanion(phase: companionPhase, size: 34, gaze: questionCompanionGaze)
            }

            if hasConfirmedSelection || !pinnedImages.images.isEmpty {
                screenshotThumbnailStack
            }

            TextField(questionPlaceholder, text: $question, axis: .vertical)
                .textFieldStyle(.plain)
                .font(MarrTypography.font(.body))
                .lineLimit(1...2)
                .foregroundStyle(.primary)
                .focused($questionFocused)
                .onSubmit {
                    sendQuestion()
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

            Button {
                sendQuestion()
            } label: {
                MarrIcon("arrow.up", size: MarrUI.Icon.navigation)
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
        .overlay(alignment: .top) {
            if showsSlashCommandMenu {
                slashCommandMenu
                    .offset(y: questionBarHeight + 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .zIndex(showsSlashCommandMenu ? 10 : 0)
        .animation(.easeOut(duration: 0.18), value: hasConfirmedSelection)
        .animation(.easeOut(duration: 0.16), value: showsSlashCommandMenu)
    }

    private var slashCommandMenu: some View {
        VStack(spacing: 2) {
            ForEach(Array(slashCommandMatches.enumerated()), id: \.element.id) { index, command in
                Button {
                    chooseSlashCommand(command)
                } label: {
                    HStack(spacing: 10) {
                        MarrIcon(command.symbol, size: MarrUI.Icon.inline)
                            .foregroundStyle(bubbleTint)
                            .frame(width: 26, height: 26)
                            .background(bubbleTint.opacity(0.11), in: RoundedRectangle(cornerRadius: 7))

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
                            ? bubbleTint.opacity(0.14)
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
        .frame(width: questionBarWidth)
        .marrGlassSurface(cornerRadius: 16, isClear: true)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.20), lineWidth: 0.8)
                .allowsHitTesting(false)
        )
        .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 9)
    }

    private func promptBar(in size: CGSize) -> some View {
        questionControls
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: ScreenshotPromptHeightKey.self, value: geometry.size.height)
                }
            }
            .onPreferenceChange(ScreenshotPromptHeightKey.self) { promptHeight = max(46, $0) }
            .allowsHitTesting(hasConfirmedSelection)
            .scaleEffect(isSending ? 0.97 : 1)
            .opacity(isSending ? 0 : 1)
            .position(promptBarPosition(in: size))
    }

    private var annotationLayer: some View {
        ScreenshotAnnotationCanvas(
            annotations: annotations + (draftAnnotation.map { [$0] } ?? []),
            selectedIndex: selectedAnnotationIndex
        )
        .frame(width: selection.width, height: selection.height)
        .overlay {
            Color.clear
                .contentShape(ScreenshotAnnotationHitShape(annotations: annotations, includesBackground: annotationTool != nil))
                .gesture(annotationGesture)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        if annotationIndex(at: point) != nil { NSCursor.openHand.set() }
                        else if annotationTool != nil { NSCursor.crosshair.set() }
                    case .ended:
                        NSCursor.arrow.set()
                    }
                }
        }
        .clipped()
        .position(x: selection.midX, y: selection.midY)
    }

    private func annotationIndex(at point: CGPoint) -> Int? {
        annotations.indices.reversed().first {
            annotations[$0].interactionPath(in: selection.size).contains(point)
        }
    }

    private var annotationGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard !isSending else { return }
                questionFocused = false
                if !annotationGestureStarted {
                    annotationGestureStarted = true
                    selectedAnnotationIndex = annotationIndex(at: value.startLocation)
                    if let index = selectedAnnotationIndex {
                        movingAnnotation = annotations[index]
                    }
                }
                if let original = movingAnnotation, let index = selectedAnnotationIndex {
                    annotations[index] = original.translated(by: value.translation, in: selection.size)
                    NSCursor.closedHand.set()
                    return
                }
                guard let annotationTool else { return }
                let start = normalizedAnnotationPoint(value.startLocation)
                let point = normalizedAnnotationPoint(value.location)
                if draftAnnotation == nil {
                    draftAnnotation = ScreenshotAnnotation(
                        tool: annotationTool, points: [start],
                        number: (annotations.filter { $0.tool == .number }.map(\.number).max() ?? 0) + 1
                    )
                }
                if annotationTool == .pen {
                    draftAnnotation?.points.append(point)
                } else if annotationTool != .number {
                    draftAnnotation?.points = [start, point]
                }
            }
            .onEnded { _ in
                if let original = movingAnnotation, let index = selectedAnnotationIndex {
                    if annotations[index] != original {
                        var previous = annotations
                        previous[index] = original
                        annotationUndoStack.append(previous)
                        refreshAnnotatedPreview()
                    }
                    NSCursor.openHand.set()
                } else if let draft = draftAnnotation {
                    let first = draft.points.first ?? .zero
                    let last = draft.points.last ?? first
                    let distance = hypot((last.x - first.x) * selection.width, (last.y - first.y) * selection.height)
                    if draft.tool == .number || draft.tool == .pen || distance >= 3 {
                        annotationUndoStack.append(annotations)
                        annotations.append(draft)
                        refreshAnnotatedPreview()
                    }
                }
                movingAnnotation = nil
                annotationGestureStarted = false
                draftAnnotation = nil
            }
    }

    private func normalizedAnnotationPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x / max(1, selection.width), 0), 1),
                y: min(max(point.y / max(1, selection.height), 0), 1))
    }

    private func screenshotTools(in size: CGSize) -> some View {
        let layout = ScreenshotToolsLayout.resolve(
            selection: selection, bounds: size, expanded: toolsExpanded, avoiding: promptBarRect(in: size)
        )
        return ScreenshotCompanionTools(
            frame: layout.frame, expanded: $toolsExpanded, selectedTool: annotationTool,
            canUndo: !annotationUndoStack.isEmpty,
            gaze: companionGaze(from: CGPoint(x: layout.frame.midX, y: layout.frame.minY + 25)),
            onSelect: { tool in
                annotationTool = annotationTool == tool ? nil : tool
                selectedAnnotationIndex = nil
                draftAnnotation = nil
                questionFocused = false
                showsImagePreview = false
            },
            onTranslate: { translateSelection() },
            onUndo: {
                if let previous = annotationUndoStack.popLast() { annotations = previous }
                selectedAnnotationIndex = nil
                refreshAnnotatedPreview()
            }
        )
        .zIndex(3)
        .transition(.opacity)
    }

    private func dragHint(in size: CGSize) -> some View {
        HStack(spacing: 6) {

            Text(isDrawingSelection ? "Release to select area" : "Drag to take a screenshot")
                .font(MarrTypography.font(.secondary))
                .foregroundStyle(Color.primary.opacity(0.92))
        }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .fixedSize(horizontal: true, vertical: false)
            .captureLabelSurface()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { dragHintSize = $0 }
            .position(dragHintPosition(in: size))
            .opacity(dragHintSize == .zero ? 0 : 1)
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
            x: position.x - questionBarWidth / 2,
            y: position.y - promptHeight / 2,
            width: questionBarWidth,
            height: promptHeight
        )
    }

    private var canSend: Bool {
        (hasConfirmedSelection || !pinnedImages.images.isEmpty)
            && !isSending
            && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var slashCommandMatches: [ConversationSlashCommand] {
        ConversationSlashCommand.matching(question)
    }

    private var showsSlashCommandMenu: Bool {
        hasConfirmedSelection
            && questionFocused
            && !slashCommandMatches.isEmpty
            && dismissedSlashMenuInput != question
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

    private var questionPlaceholder: String {
        "What can I help you with today?"
    }

    private var canTranslate: Bool {
        hasConfirmedSelection && !isSending
    }

    private var previewImage: NSImage? {
        if !annotations.isEmpty, let annotatedPreview { return annotatedPreview }
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

    private func refreshAnnotatedPreview() {
        // Encoding a full PNG on every freehand drag update would stall drawing.
        // Refresh thumbnails only after a completed mark or selection adjustment.
        annotatedPreview = annotations.isEmpty ? nil : capturedSelection()?.image
    }

    private func capturedSelection() -> PickedImage? {
        guard let image = ScreenCapture.capture(rect: globalSelectionRect(), screen: screen, snapshot: snapshot) else { return nil }
        return ScreenCapture.annotating(image, with: annotations, selectionSize: selection.size)
    }

    private func pinSelection() {
        guard hasConfirmedSelection,
              let image = capturedSelection()
        else { return }
        pinnedImages.images.append(image)
        annotations.removeAll()
        annotationUndoStack.removeAll()
        selectedAnnotationIndex = nil
        draftAnnotation = nil
        annotationTool = nil
        selection = .zero
        selectionOrigin = nil
        showsImagePreview = false
        pinHovered = false
        questionFocused = false
    }

    private func sendQuestion() {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSending, !trimmedQuestion.isEmpty else {
            return
        }

        let rect = globalSelectionRect()
        let answerAnchorRect = globalQuestionBarRect(in: screen.frame.size)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            questionFocused = false
        }

        withAnimation(.easeInOut(duration: capsuleTransitionDuration)) {
            isSending = true
        }

        var images = pinnedImages.images
        if !images.isEmpty, hasConfirmedSelection {
            guard let image = capturedSelection() else {
                isSending = false
                return
            }
            images.append(image)
        }
        let capturedImages = images
        let capturedAnnotations = annotations
        let capture = DispatchWorkItem {
            if !capturedImages.isEmpty, let onCaptureBatch {
                onCaptureBatch(capturedImages, answerAnchorRect, trimmedQuestion)
            } else {
                onCapture(rect, answerAnchorRect, trimmedQuestion, capturedAnnotations)
            }
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

    private func position(for handle: SelectionResizeHandle) -> CGPoint {
        switch handle {
        case .topLeft: CGPoint(x: selection.minX, y: selection.minY)
        case .top: CGPoint(x: selection.midX, y: selection.minY)
        case .topRight: CGPoint(x: selection.maxX, y: selection.minY)
        case .right: CGPoint(x: selection.maxX, y: selection.midY)
        case .bottomRight: CGPoint(x: selection.maxX, y: selection.maxY)
        case .bottom: CGPoint(x: selection.midX, y: selection.maxY)
        case .bottomLeft: CGPoint(x: selection.minX, y: selection.maxY)
        case .left: CGPoint(x: selection.minX, y: selection.midY)
        }
    }

    private func hitTargetSize(for handle: SelectionResizeHandle) -> CGSize {
        let thickness: CGFloat = 12
        let corner: CGFloat = 18
        switch handle {
        case .top, .bottom:
            return CGSize(width: max(corner, selection.width - corner * 2), height: thickness)
        case .left, .right:
            return CGSize(width: thickness, height: max(corner, selection.height - corner * 2))
        case .topLeft, .topRight, .bottomRight, .bottomLeft:
            return CGSize(width: corner, height: corner)
        }
    }

    private func toolbarX(in bounds: CGSize) -> CGFloat {
        let halfWidth = questionBarWidth / 2
        let minimumX = halfWidth + 12
        let maximumX = bounds.width - halfWidth - 12
        guard minimumX <= maximumX else {
            return bounds.width / 2
        }
        return min(max(selection.midX, minimumX), maximumX)
    }

    private func toolbarY(in bounds: CGSize) -> CGFloat {
        let toolbarHeight = promptHeight
        let preferredBelow = selection.maxY + toolbarHeight / 2 + 14
        if preferredBelow <= bounds.height - toolbarHeight / 2 - 8 {
            return preferredBelow
        }

        return max(selection.minY - toolbarHeight / 2 - 14, toolbarHeight / 2 + 8)
    }

    private func promptBarPosition(in bounds: CGSize) -> CGPoint {
        if hasConfirmedSelection {
            return CGPoint(x: toolbarX(in: bounds), y: toolbarY(in: bounds))
        }
        return initialPromptBarPosition(in: bounds)
    }

    private func globalQuestionBarRect(in bounds: CGSize) -> CGRect {
        let position = promptBarPosition(in: bounds)
        return CGRect(
            x: screen.frame.minX + position.x - questionBarWidth / 2,
            y: screen.frame.maxY - position.y - promptHeight / 2,
            width: questionBarWidth,
            height: promptHeight
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

        let hintHalfWidth = dragHintSize.width / 2
        let hintHalfHeight = dragHintSize.height / 2
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
        !pinnedImages.images.isEmpty || cursorLocation != nil
            || selection.width > 0
            || selection.height > 0
    }

    private func resize(
        _ rect: CGRect,
        handle: SelectionResizeHandle,
        translation: CGSize,
        bounds: CGSize
    ) -> CGRect {
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
    let image: CGImage
    let screenFrame: CGRect
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

        return CaptureImagePreparation.jpeg(cropped, fileName: "Screen Capture")
    }

}
