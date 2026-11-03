import AppKit
import SwiftUI

/// Hover is local to a row, never a list-wide selected/hovered identifier.
struct MarrHoverRegion<Content: View>: View {
    @ViewBuilder let content: (Bool) -> Content
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content(isHovered)
            .onHover { isHovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: isHovered)
    }
}

@MainActor
final class MarrHistoryScrollPosition: ObservableObject {
    @Published var visibleID: UUID?
}

/// Observe scroll anchors here, not in the panel's navigation model. The
/// content value stays intact while the scroll view writes its visible row.
struct MarrHistoryScrollView<Content: View>: View {
    @ObservedObject var position: MarrHistoryScrollPosition
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView { content }
            .scrollPosition(id: $position.visibleID)
    }
}

@MainActor
final class MarrConversationScrollChrome: ObservableObject {
    @Published private(set) var distance: CGFloat = 0

    func update(origin: CGFloat) {
        guard origin.isFinite else { return }
        // Past the fade range, a long transcript produces no UI publications.
        let next = min(72, max(0, -origin)).rounded()
        guard next != distance else { return }
        distance = next
    }
}

struct MarrConversationTitleScrollEffect: ViewModifier {
    @ObservedObject var chrome: MarrConversationScrollChrome

    func body(content: Content) -> some View {
        content
            .opacity(AnswerPanelTitleFade.opacity(forScrollDistance: chrome.distance))
            .offset(y: -min(5, chrome.distance * 0.07))
    }
}

enum MarrAppearanceKeys {
    static let colorScheme = "appearance.colorScheme"
    static let glassSurfaces = "appearance.glassSurfaces"
}

enum MarrSurfaceMode: Equatable {
    case activeClear
    case activeRegular
    case unfocused

    static func resolve(usesLiquidGlass: Bool, prefersClearGlass: Bool) -> Self {
        guard usesLiquidGlass else { return .unfocused }
        return prefersClearGlass ? .activeClear : .activeRegular
    }
}

enum BackgroundBrightnessSampler {
    static func isNearlyWhite(in rect: CGRect, on screen: NSScreen) -> Bool {
        guard
            let displayNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else {
            return false
        }

        let scale = screen.backingScaleFactor
        let pixelRect = CGRect(
            x: (rect.minX - screen.frame.minX) * scale,
            y: (screen.frame.maxY - rect.maxY) * scale,
            width: rect.width * scale,
            height: rect.height * scale
        ).integral
        let displayID = CGDirectDisplayID(displayNumber.uint32Value)

        guard
            let image = CGDisplayCreateImage(displayID, rect: pixelRect),
            let bitmap = NSBitmapImageRep(cgImage: image).retagging(with: .sRGB)
        else {
            return false
        }

        let columns = 32
        let rows = 6
        var luminanceTotal: CGFloat = 0
        var nearWhiteSamples = 0
        var sampleCount = 0

        for row in 0..<rows {
            for column in 0..<columns {
                let x = min(bitmap.pixelsWide - 1, (column * bitmap.pixelsWide + bitmap.pixelsWide / 2) / columns)
                let y = min(bitmap.pixelsHigh - 1, (row * bitmap.pixelsHigh + bitmap.pixelsHigh / 2) / rows)
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                    continue
                }

                let luminance = 0.2126 * color.redComponent
                    + 0.7152 * color.greenComponent
                    + 0.0722 * color.blueComponent
                luminanceTotal += luminance
                if luminance >= 0.93 && color.saturationComponent <= 0.08 {
                    nearWhiteSamples += 1
                }
                sampleCount += 1
            }
        }

        guard sampleCount > 0 else {
            return false
        }

        let averageLuminance = luminanceTotal / CGFloat(sampleCount)
        let nearWhiteRatio = CGFloat(nearWhiteSamples) / CGFloat(sampleCount)
        return averageLuminance >= 0.90 && nearWhiteRatio >= 0.72
    }
}

extension View {
    func marrGlassSurface(
        cornerRadius: CGFloat,
        isClear: Bool = false,
        frostsTop: Bool = false,
        frostOpacity: Double = 1,
        tintOpacity: Double? = nil,
        drawsBorder: Bool = true,
        appliesForegroundEffects: Bool = false,
        solidBackground: Color? = nil
    ) -> some View {
        modifier(
            MarrGlassSurfaceModifier(
                cornerRadius: cornerRadius,
                isClear: isClear,
                frostsTop: frostsTop,
                frostOpacity: frostOpacity,
                tintOpacity: tintOpacity,
                drawsBorder: drawsBorder,
                appliesForegroundEffects: appliesForegroundEffects,
                solidBackground: solidBackground
            )
        )
    }

    func marrPreferredColorScheme() -> some View {
        modifier(MarrPreferredColorSchemeModifier())
    }
}

private struct MarrGlassSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let isClear: Bool
    let frostsTop: Bool
    let frostOpacity: Double
    let tintOpacity: Double?
    let drawsBorder: Bool
    let appliesForegroundEffects: Bool
    let solidBackground: Color?

    @AppStorage(MarrAppearanceKeys.glassSurfaces) private var usesGlassSurfaces = true
    @Environment(\.accessibilityReduceTransparency) private var systemReducesTransparency
    @Environment(\.marrAccessibilityOverrides) private var accessibilityOverrides
    private var reducesTransparency: Bool {
        accessibilityOverrides?.reducesTransparency ?? systemReducesTransparency
    }
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            // Change the glass value, not the content structure, so appearance and
            // foreground-effect changes preserve drafts, focus and scroll state.
            content
                .background { surfaceBackground.allowsHitTesting(false) }
                .glassEffect(
                    solidBackground == nil && appliesForegroundEffects && usesGlassSurfaces && !reducesTransparency ? nativeGlass : .identity,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .overlay(surfaceBorder)
        } else {
            content
                .background { surfaceBackground.allowsHitTesting(false) }
                .overlay(surfaceBorder)
        }
    }

    @ViewBuilder
    private var surfaceBackground: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if let solidBackground {
            shape.fill(solidBackground)
        } else if reducesTransparency {
            shape.fill(reducedTransparencyColor)
        } else if #available(macOS 26.0, *), usesGlassSurfaces {
            if !appliesForegroundEffects {
                shape.fill(.clear).glassEffect(nativeGlass, in: shape)
                    .overlay {
                        if frostsTop {
                            // Fade a real backdrop material over clear glass; mask
                            // only the background so text and controls stay crisp.
                            shape.fill(.regularMaterial)
                                .overlay { shape.fill(readabilityTint) }
                                .mask(frostMask)
                                .opacity(effectiveFrostOpacity)
                        }
                    }
            }
        } else {
            shape.fill(.regularMaterial)
                .overlay { shape.fill(surfaceTint) }
                .opacity(frostsTop ? effectiveFrostOpacity : 1)
        }
    }

    @available(macOS 26.0, *)
    private var nativeGlass: Glass {
        let glass: Glass = isClear || frostsTop ? .clear : .regular
        if frostsTop {
            // Keep the lower edge clear instead of tinting the whole window.
            return glass
        }
        return tintOpacity == 0 ? glass : glass.tint(readabilityTint)
    }

    // Tune the background veil, never the content or the native glass edge.
    // Increased Contrast retains the original full-strength frost.
    private var effectiveFrostOpacity: Double {
        colorSchemeContrast == .increased ? 1 : min(1, max(0, frostOpacity))
    }

    private var frostMask: LinearGradient {
        LinearGradient(stops: [
            .init(color: .white, location: 0),
            .init(color: .white, location: 0.28),
            .init(color: .white.opacity(0.76), location: 0.50),
            .init(color: .white.opacity(0.30), location: 0.74),
            .init(color: .clear, location: 1)
        ], startPoint: .top, endPoint: .bottom)
    }

    private var surfaceMode: MarrSurfaceMode {
        .resolve(usesLiquidGlass: usesGlassSurfaces, prefersClearGlass: isClear)
    }

    private var readabilityTint: Color {
        let opacity = tintOpacity ?? defaultReadabilityTintOpacity
        return contrastBaseColor.opacity(opacity)
    }

    private var contrastBaseColor: Color {
        colorScheme == .dark ? .black : .white
    }

    private var unfocusedGlassTint: Color {
        contrastBaseColor.opacity(
            tintOpacity ?? (colorSchemeContrast == .increased ? 0.40 : colorScheme == .dark ? 0.22 : 0.30)
        )
    }

    private var surfaceTint: Color {
        if surfaceMode == .unfocused {
            return unfocusedGlassTint
        }
        return contrastBaseColor.opacity(
            tintOpacity ?? (colorSchemeContrast == .increased ? 0.62 : isClear ? 0.48 : 0.40)
        )
    }

    private var defaultReadabilityTintOpacity: Double {
        if colorSchemeContrast == .increased {
            return isClear ? 0.68 : 0.58
        }
        // Native regular glass handles backdrop luminance. A restrained neutral
        // tint preserves wallpaper color without tinting the opaque white pages.
        return colorScheme == .dark ? 0.36 : (isClear ? 0.26 : 0.18)
    }

    private var reducedTransparencyColor: Color {
        MarrUI.Surface.content
    }

    private var surfaceBorder: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        // Two polarities keep a stable contour: the dark edge survives white
        // backgrounds, while the inset highlight survives dark/colorful ones.
        // This is compositing only; no screen capture or polling is needed.
        return shape
            .strokeBorder((colorScheme == .dark ? Color.white : Color.black)
                .opacity(drawsBorder ? (colorSchemeContrast == .increased ? 0.45 : 0.12) : 0), lineWidth: 0.75)
            .overlay {
                shape.inset(by: 0.75).strokeBorder(
                    Color.white.opacity(drawsBorder && !reducesTransparency ? (colorScheme == .dark ? 0.08 : 0.38) : 0),
                    lineWidth: 0.75)
            }
            .allowsHitTesting(false)
    }
}

private struct MarrPreferredColorSchemeModifier: ViewModifier {
    @AppStorage(MarrAppearanceKeys.colorScheme) private var preference = "System"

    func body(content: Content) -> some View {
        content.preferredColorScheme(preferredColorScheme)
    }

    private var preferredColorScheme: ColorScheme? {
        switch preference {
        case "Light": .light
        case "Dark": .dark
        default: nil
        }
    }
}

/// Resolved neutral colors keep text and controls legible on glass. Hierarchical
/// foreground styles can pick up vibrancy from a different effective appearance.
enum MarrPanelColors {
    static func primary(for scheme: ColorScheme) -> Color {
        Color(white: scheme == .dark ? 0.92 : 0.12)
    }

    static func secondary(for scheme: ColorScheme) -> Color {
        Color(white: scheme == .dark ? 0.74 : 0.36)
    }

    static func error(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 1, green: 0.58, blue: 0.55)
            : Color(red: 0.70, green: 0.16, blue: 0.14)
    }
}

/// Short transitions for content changes; reduced motion updates immediately.
enum MarrMotion {
    static func transition(reducesMotion: Bool) -> Animation? {
        reducesMotion ? nil : .easeOut(duration: 0.18)
    }

    static func layout(reducesMotion: Bool) -> Animation? {
        reducesMotion ? nil : .easeInOut(duration: 0.22)
    }
}

/// An indeterminate work indicator with a fixed footprint.
/// Hide it from accessibility when adjacent status text already describes the work.
struct MarrActivityIndicator: View {
    var color: Color = .secondary
    var label = "Working"
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    var body: some View {
        Group {
            if reducesMotion {
                ring(rotation: .degrees(-90))
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: 1.25) / 1.25
                    ring(rotation: .degrees(phase * 360 - 90))
                }
            }
        }
        .frame(width: 14, height: 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("In progress")
    }

    private func ring(rotation: Angle) -> some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.18), lineWidth: 1.5)
            Circle()
                .trim(from: 0, to: 0.3)
                .stroke(color.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(rotation)
        }
        .padding(1)
    }
}

/// Follows growing replies until the reader scrolls away. Native clip-view
/// observation also covers Markdown relayout and window resizing, without
/// rerendering or animating the transcript on each token.
struct MarrScrollOverflow: Equatable {
    var top = false
    var bottom = false

    init() {}

    init(documentHeight: CGFloat, viewportHeight: CGFloat, origin: CGFloat, isFlipped: Bool) {
        guard documentHeight.isFinite, viewportHeight.isFinite, origin.isFinite,
              viewportHeight > 0, documentHeight > viewportHeight + 1 else { return }
        let distance = max(0, documentHeight - viewportHeight)
        let offset = min(distance, max(0, origin))
        top = isFlipped ? offset > 1 : distance - offset > 1
        bottom = isFlipped ? distance - offset > 1 : offset > 1
    }
}

struct MarrFollowingScrollView<Content: View>: View {
    let identity: String
    var onLiveScrollChange: (Bool) -> Void = { _ in }
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceTransparency) private var reducesTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isFollowing = true
    @State private var jumpRequest = 0
    @State private var overflow = MarrScrollOverflow()

    var body: some View {
        ScrollView {
            content.background {
                MarrScrollObserver(identity: identity, jumpRequest: jumpRequest,
                                   onLiveScrollChange: onLiveScrollChange,
                                   onFollowingChange: { isFollowing = $0 },
                                   onOverflowChange: { overflow = $0 })
                .accessibilityHidden(true)
            }
        }
        .mask {
            if reducesTransparency || contrast == .increased {
                Color.black
            } else {
                VStack(spacing: 0) {
                    LinearGradient(colors: overflow.top ? [.clear, .black.opacity(0.8), .black] : [.black],
                                   startPoint: .top, endPoint: .bottom).frame(height: 12)
                    Color.black
                    LinearGradient(colors: overflow.bottom ? [.black, .black.opacity(0.8), .clear] : [.black],
                                   startPoint: .top, endPoint: .bottom).frame(height: 12)
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !isFollowing && overflow.bottom {
                Button {
                    jumpRequest += 1
                } label: {
                    Label("Jump to latest", marrSymbol: "arrow.down")
                        .font(MarrTypography.font(.secondary, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().stroke(.separator.opacity(0.5)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Jump to latest")
                .padding(8)
            }
        }
    }
}

private struct MarrScrollObserver: NSViewRepresentable {
    let identity: String
    let jumpRequest: Int
    let onLiveScrollChange: (Bool) -> Void
    let onFollowingChange: (Bool) -> Void
    let onOverflowChange: (MarrScrollOverflow) -> Void

    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.follower = context.coordinator
        return view
    }

    func makeCoordinator() -> MarrScrollFollower { MarrScrollFollower() }

    func updateNSView(_ nsView: Probe, context: Context) {
        context.coordinator.onLiveScrollChange = onLiveScrollChange
        context.coordinator.onFollowingChange = onFollowingChange
        context.coordinator.onOverflowChange = onOverflowChange
        context.coordinator.update(identity: identity, jumpRequest: jumpRequest)
        nsView.connect()
    }

    static func dismantleNSView(_ nsView: Probe, coordinator: MarrScrollFollower) {
        coordinator.detach()
    }

    final class Probe: NSView {
        weak var follower: MarrScrollFollower?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); connect() }
        override func layout() { super.layout(); connect() }
        func connect() {
            if let scrollView = enclosingScrollView { follower?.attach(to: scrollView) }
        }
    }
}

@MainActor
final class MarrScrollFollower {
    var onLiveScrollChange: (Bool) -> Void = { _ in }
    var onFollowingChange: (Bool) -> Void = { _ in }
    var onOverflowChange: (MarrScrollOverflow) -> Void = { _ in }
    private(set) var isFollowing = true
    private weak var scrollView: NSScrollView?
    private var observers: [NSObjectProtocol] = []
    private var identity: String?
    private var jumpRequest = 0
    private var knownDocumentHeight: CGFloat = 0
    private var knownViewportHeight: CGFloat = 0
    private var knownOrigin: CGFloat = 0
    private var followScheduled = false
    private var isAdjusting = false
    private var isLiveScrolling = false
    private var wheelActive = false
    private var userScrollTowardEarlier: Bool?
    private var wheelIdleTask: Task<Void, Never>?
    private var eventMonitor: Any?
    private var reportedScrolling = false
    private var generation = 0
    private var overflowScheduled = false
    private var lastOverflow: MarrScrollOverflow?

    func update(identity: String, jumpRequest: Int) {
        guard self.identity != identity || self.jumpRequest != jumpRequest else { return }
        self.identity = identity
        self.jumpRequest = jumpRequest
        setFollowing(true)
        scheduleFollow()
    }

    func attach(to view: NSScrollView) {
        guard scrollView !== view, let document = view.documentView else { return }
        detach()
        scrollView = view
        knownDocumentHeight = document.frame.height
        knownViewportHeight = view.contentView.bounds.height
        knownOrigin = view.contentView.bounds.minY
        document.postsFrameChangedNotifications = true
        view.contentView.postsBoundsChangedNotifications = true
        view.contentView.postsFrameChangedNotifications = true
        observe(NSView.frameDidChangeNotification, object: document) { $0.documentChanged() }
        observe(NSView.frameDidChangeNotification, object: view.contentView) { $0.scheduleFollow() }
        observe(NSView.boundsDidChangeNotification, object: view.contentView) { $0.boundsChanged() }
        observe(NSScrollView.willStartLiveScrollNotification, object: view) {
            $0.isLiveScrolling = true
            $0.setFollowing(false)
            $0.reportScrolling()
        }
        observe(NSScrollView.didLiveScrollNotification, object: view) {
            $0.rearmOnlyAtLatestEdge()
        }
        observe(NSScrollView.didEndLiveScrollNotification, object: view) {
            $0.isLiveScrolling = false
            $0.reportScrolling()
            $0.rearmOnlyAtLatestEdge()
            $0.scheduleFollow()
        }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let view = self.scrollView, let window = view.window,
                  event.window === window,
                  view.bounds.contains(view.convert(event.locationInWindow, from: nil)),
                  abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else { return event }
            self.userDidScroll(towardEarlier: event.scrollingDeltaY > 0)
            return event
        }
        scheduleFollow()
    }

    /// Record intent before AppKit changes bounds or a lazy stack estimates its
    /// new height. Near-bottom geometry alone cannot distinguish a user from layout.
    func userDidScroll(towardEarlier: Bool) {
        userScrollTowardEarlier = towardEarlier
        if towardEarlier { setFollowing(false) }
        wheelActive = true
        reportScrolling()
        wheelIdleTask?.cancel()
        wheelIdleTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(220)) } catch { return }
            guard let self else { return }
            self.wheelActive = false
            self.reportScrolling()
            self.rearmOnlyAtLatestEdge()
            self.userScrollTowardEarlier = nil
            self.scheduleFollow()
        }
    }

    private func reportScrolling() {
        let value = isLiveScrolling || wheelActive
        guard reportedScrolling != value else { return }
        reportedScrolling = value
        onLiveScrollChange(value)
    }

    private func rearmOnlyAtLatestEdge() {
        guard userScrollTowardEarlier == false, isNearBottom else { return }
        setFollowing(true)
    }

    func detach() {
        wheelIdleTask?.cancel()
        wheelIdleTask = nil
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        wheelActive = false
        userScrollTowardEarlier = nil
        if reportedScrolling { reportedScrolling = false; onLiveScrollChange(false) }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        scrollView = nil
        generation += 1
        followScheduled = false
        isLiveScrolling = false
        overflowScheduled = false
        lastOverflow = nil
    }

    private func observe(_ name: Notification.Name, object: AnyObject,
                         action: @escaping @MainActor (MarrScrollFollower) -> Void) {
        observers.append(NotificationCenter.default.addObserver(
            forName: name, object: object, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        })
    }

    private var isNearBottom: Bool {
        guard let view = scrollView, let document = view.documentView else { return true }
        let clip = view.contentView
        let distance = document.isFlipped
            ? document.frame.height - clip.bounds.maxY
            : clip.bounds.minY
        return distance <= 1
    }

    private func documentChanged() {
        knownDocumentHeight = scrollView?.documentView?.frame.height ?? 0
        scheduleFollow()
    }

    private func boundsChanged() {
        guard let view = scrollView, let document = view.documentView else { return }
        publishOverflow()
        let previousOrigin = knownOrigin
        knownOrigin = view.contentView.bounds.minY
        guard !isAdjusting else { return }
        let changedSize = document.frame.height != knownDocumentHeight
            || view.contentView.bounds.height != knownViewportHeight
        let towardEarlier = document.isFlipped ? knownOrigin < previousOrigin : knownOrigin > previousOrigin
        // User intent always wins over height estimates and pending follow work.
        if isLiveScrolling || wheelActive || (!changedSize && knownOrigin != previousOrigin) {
            if userScrollTowardEarlier == true || (userScrollTowardEarlier == nil && towardEarlier) {
                setFollowing(false)
            } else if !towardEarlier && isNearBottom && (userScrollTowardEarlier == false || isLiveScrolling) {
                setFollowing(true)
            }
        }
        if changedSize {
            knownViewportHeight = view.contentView.bounds.height
            documentChanged()
        }
    }

    private func setFollowing(_ value: Bool) {
        // Empty and short transcripts cannot be scrolled away from latest.
        // AppKit still sends wheel/live-scroll events during elastic scrolling.
        let value = value || !hasScrollableContent
        guard value != isFollowing else { return }
        isFollowing = value
        let generation = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == generation else { return }
            self.onFollowingChange(self.isFollowing)
        }
    }

    private func scheduleFollow() {
        if !hasScrollableContent { setFollowing(true) }
        publishOverflow()
        guard isFollowing, !isLiveScrolling, !wheelActive, !followScheduled, scrollView != nil else { return }
        followScheduled = true
        let generation = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == generation else { return }
            self.followScheduled = false
            guard self.isFollowing, !self.isLiveScrolling, !self.wheelActive,
                  let view = self.scrollView, let document = view.documentView else { return }
            self.isAdjusting = true
            let y = document.isFlipped ? max(0, document.frame.height - view.contentView.bounds.height) : 0
            view.contentView.scroll(to: NSPoint(x: view.contentView.bounds.minX, y: y))
            view.reflectScrolledClipView(view.contentView)
            self.knownOrigin = view.contentView.bounds.minY
            self.knownDocumentHeight = document.frame.height
            self.knownViewportHeight = view.contentView.bounds.height
            self.isAdjusting = false
            self.publishOverflow()
        }
    }

    private func publishOverflow() {
        guard !overflowScheduled, scrollView != nil else { return }
        overflowScheduled = true
        let generation = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == generation else { return }
            self.overflowScheduled = false
            guard let view = self.scrollView, let document = view.documentView else { return }
            let overflow = MarrScrollOverflow(documentHeight: document.frame.height,
                                              viewportHeight: view.contentView.bounds.height,
                                              origin: view.contentView.bounds.minY,
                                              isFlipped: document.isFlipped)
            guard overflow != self.lastOverflow else { return }
            self.lastOverflow = overflow
            self.onOverflowChange(overflow)
        }
    }

    private var hasScrollableContent: Bool {
        guard let view = scrollView, let document = view.documentView else { return false }
        let height = document.frame.height
        let viewport = view.contentView.bounds.height
        return height.isFinite && viewport.isFinite && viewport > 0 && height > viewport + 1
    }
}
