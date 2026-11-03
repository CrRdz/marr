import AppKit
import SwiftUI

/// Shared native control metrics. These are points, not the web reference's CSS pixels.
enum MarrUI {
    enum Spacing {
        static let tight: CGFloat = 4
        static let small: CGFloat = 6
        static let regular: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let section: CGFloat = 24
    }

    enum Radius {
        static let control: CGFloat = 8
        static let chip: CGFloat = 8
        static let card: CGFloat = 12
        static let composer: CGFloat = 20
    }

    enum Control {
        static let compact: CGFloat = 28
        static let regular: CGFloat = 32
        static let spacious: CGFloat = 36
    }

    enum Surface {
        static var canvas: Color { Color(nsColor: .windowBackgroundColor) }
        static var raised: Color { Color(nsColor: .controlBackgroundColor) }

        static func border(increasedContrast: Bool) -> Color {
            .primary.opacity(increasedContrast ? 0.42 : 0.12)
        }
    }
}

/// Preview/test injection for otherwise read-only system accessibility settings.
/// A nil override always uses the actual macOS preferences.
struct MarrAccessibilityPreferences: Equatable {
    var reducesMotion: Bool
    var reducesTransparency: Bool
    var increasedContrast: Bool
}

private struct MarrAccessibilityOverridesKey: EnvironmentKey {
    static let defaultValue: MarrAccessibilityPreferences? = nil
}

extension EnvironmentValues {
    var marrAccessibilityOverrides: MarrAccessibilityPreferences? {
        get { self[MarrAccessibilityOverridesKey.self] }
        set { self[MarrAccessibilityOverridesKey.self] = newValue }
    }
}

extension MarrMotion {
    // Modest, purpose-specific springs; no message text or token count is a trigger.
    static func press(reducesMotion: Bool) -> Animation? {
        reducesMotion ? nil : .spring(response: 0.22, dampingFraction: 0.86)
    }

    static func selection(reducesMotion: Bool) -> Animation? {
        reducesMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86)
    }

    static func sheet(reducesMotion: Bool) -> Animation? {
        reducesMotion ? nil : .spring(response: 0.38, dampingFraction: 0.94)
    }

    static func attachment(reducesMotion: Bool) -> Animation? {
        reducesMotion ? nil : .spring(response: 0.30, dampingFraction: 0.84)
    }

    static func disclosure(reducesMotion: Bool) -> Animation? {
        reducesMotion ? nil : .spring(response: 0.28, dampingFraction: 0.96)
    }
}

/// The decoration has no animation schedule at all when hidden or static.
enum MarrAmbientPresentation: Equatable {
    case hidden, still, animated, outline

    static func resolve(
        isRunning: Bool,
        reducesMotion: Bool,
        reducesTransparency: Bool,
        increasedContrast: Bool,
        isVisible: Bool
    ) -> Self {
        guard isRunning else { return .hidden }
        if reducesTransparency || increasedContrast { return .outline }
        if reducesMotion || !isVisible { return .still }
        return .animated
    }
}

extension View {
    /// Apply after the composer's surface. The existing content keeps its identity.
    func marrAmbientGlow(
        isRunning: Bool,
        isVisible: Bool = true,
        cornerRadius: CGFloat = MarrUI.Radius.composer,
        tint: Color = .accentColor
    ) -> some View {
        modifier(MarrAmbientGlowModifier(isRunning: isRunning, isVisible: isVisible,
                                        cornerRadius: cornerRadius, tint: tint))
    }
}

private struct MarrAmbientGlowModifier: ViewModifier {
    let isRunning: Bool
    let isVisible: Bool
    let cornerRadius: CGFloat
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var systemReducesMotion
    @Environment(\.accessibilityReduceTransparency) private var systemReducesTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.marrAccessibilityOverrides) private var accessibilityOverrides
    @State private var windowIsVisible = false

    private var increasedContrast: Bool {
        accessibilityOverrides?.increasedContrast ?? (contrast == .increased)
    }
    private var reducesMotion: Bool {
        accessibilityOverrides?.reducesMotion ?? systemReducesMotion
    }

    private var presentation: MarrAmbientPresentation {
        .resolve(isRunning: isRunning, reducesMotion: reducesMotion,
                 reducesTransparency: accessibilityOverrides?.reducesTransparency ?? systemReducesTransparency,
                 increasedContrast: increasedContrast,
                 isVisible: isVisible && windowIsVisible)
    }

    func body(content: Content) -> some View {
        content
            .background {
                MarrAmbientWindowVisibilityObserver { windowIsVisible = $0 }
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .background {
                MarrAmbientGlow(presentation: presentation, cornerRadius: cornerRadius, tint: tint,
                                reducesMotion: reducesMotion)
                    .padding(-5)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .overlay {
                // Opaque and stationary: no blur when the user requests stronger
                // contrast or less transparency. Only entry/exit opacity changes.
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(tint, lineWidth: increasedContrast ? 1.5 : 0.75)
                    .opacity(presentation == .outline ? 1 : 0)
                    .animation(reducesMotion ? nil : .easeOut(duration: 0.16), value: presentation == .outline)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

private struct MarrAmbientWindowVisibilityObserver: NSViewRepresentable {
    let onVisibilityChanged: (Bool) -> Void

    func makeNSView(context: Context) -> MarrAmbientVisibilityView {
        let view = MarrAmbientVisibilityView()
        view.onVisibilityChanged = onVisibilityChanged
        return view
    }

    func updateNSView(_ view: MarrAmbientVisibilityView, context: Context) {
        view.onVisibilityChanged = onVisibilityChanged
        view.refreshVisibility()
    }

    static func dismantleNSView(_ view: MarrAmbientVisibilityView, coordinator: ()) {
        view.onVisibilityChanged = nil
        view.removeObservers()
    }
}

/// NSHostingView panels do not necessarily belong to a SwiftUI Scene. Observe
/// their actual native window instead of relying on an unpopulated scenePhase.
final class MarrAmbientVisibilityView: NSView {
    var onVisibilityChanged: ((Bool) -> Void)?
    private(set) var isWindowVisible = false
    private var observers: [NSObjectProtocol] = []

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeObservers()
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification] {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshVisibility() }
                })
            }
        }
        refreshVisibility()
    }

    func refreshVisibility() {
        let visible = window.map {
            $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
        } ?? false
        guard visible != isWindowVisible else { return }
        isWindowVisible = visible
        // Avoid publishing during an NSViewRepresentable update. Read the latest
        // state when delivered so rapid orderOut/orderFront changes coalesce.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onVisibilityChanged?(self.isWindowVisible)
        }
    }

    func removeObservers() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}

private struct MarrAmbientGlow: View {
    let presentation: MarrAmbientPresentation
    let cornerRadius: CGFloat
    let tint: Color
    let reducesMotion: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var showsGlow: Bool { presentation == .animated || presentation == .still }

    var body: some View {
        Group {
            switch presentation {
            case .animated:
                TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
                    // Wall-clock phase survives every streaming body update.
                    // Only this small decoration is reevaluated on each tick.
                    glow(phase: context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: 6) / 6 * .pi * 2)
                }
                .transition(.identity)
            case .still, .hidden, .outline:
                // Finishing removes the timeline immediately. A static drawing
                // can fade out without keeping an animation schedule alive.
                glow(phase: 0).transition(.identity)
            }
        }
        .transaction { $0.animation = nil }
        .opacity(showsGlow ? 1 : 0)
        .animation(reducesMotion ? nil : .easeOut(duration: 0.16), value: showsGlow)
    }

    private func glow(phase: Double) -> some View {
        let intensity = (colorScheme == .dark ? 0.20 : 0.13) + sin(phase) * 0.025
        let shape = RoundedRectangle(cornerRadius: cornerRadius + 5, style: .continuous)
        return shape
            .strokeBorder(
                LinearGradient(
                    colors: [tint.opacity(intensity * 0.55), tint.opacity(intensity),
                             tint.opacity(intensity * 0.65)],
                    startPoint: UnitPoint(x: 0.15 + sin(phase) * 0.08, y: 0),
                    endPoint: UnitPoint(x: 0.85 + cos(phase) * 0.08, y: 1)
                ),
                lineWidth: 6
            )
            .hueRotation(.degrees(sin(phase) * 5))
            .blur(radius: 7)
    }
}

/// Native Button semantics, keyboard activation, and focus remain with Button.
/// The style supplies a common visual state vocabulary without adding gestures.
struct MarrButtonStyle: ButtonStyle {
    enum Role: Equatable { case primary, secondary, ghost, destructive }
    enum Size: Equatable {
        case compact, regular, icon
        var height: CGFloat { self == .regular ? MarrUI.Control.regular : MarrUI.Control.compact }
    }
    enum Shape: Equatable { case rounded, circle }

    let role: Role
    var size: Size
    var shape: Shape
    var tint: Color
    var foregroundColor: Color?

    init(_ role: Role = .secondary, size: Size = .regular, shape: Shape = .rounded,
         tint: Color = .accentColor, foregroundColor: Color? = nil) {
        self.role = role
        self.size = size
        self.shape = shape
        self.tint = tint
        self.foregroundColor = foregroundColor
    }

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, style: self)
    }

    private struct StyledButton: View {
        let configuration: ButtonStyle.Configuration
        let style: MarrButtonStyle
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var systemReducesMotion
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.colorSchemeContrast) private var contrast
        @Environment(\.marrAccessibilityOverrides) private var accessibilityOverrides
        @State private var isHovered = false

        private var reducesMotion: Bool { accessibilityOverrides?.reducesMotion ?? systemReducesMotion }
        private var increasedContrast: Bool {
            accessibilityOverrides?.increasedContrast ?? (contrast == .increased)
        }
        private var isPressed: Bool { isEnabled && configuration.isPressed }
        private var outline: RoundedRectangle {
            RoundedRectangle(cornerRadius: style.shape == .circle ? style.size.height / 2 : MarrUI.Radius.control,
                             style: .continuous)
        }
        private var foreground: Color {
            if let color = style.foregroundColor { return color }
            switch style.role {
            case .primary, .destructive: return .white
            case .secondary, .ghost: return MarrPanelColors.primary(for: colorScheme)
            }
        }
        private var fill: Color {
            switch style.role {
            case .primary: return style.tint
            case .destructive: return MarrPanelColors.error(for: colorScheme)
            case .secondary: return .primary.opacity(isPressed ? 0.16 : isEnabled && isHovered ? 0.12 : 0.07)
            case .ghost: return .primary.opacity(isPressed ? 0.12 : isEnabled && isHovered ? 0.07 : 0)
            }
        }

        var body: some View {
            configuration.label
                .font(MarrTypography.font(.body, weight: .medium))
                .padding(.horizontal, style.size == .icon ? 0 : MarrUI.Spacing.medium)
                .frame(minWidth: style.size.height, minHeight: style.size.height)
                .foregroundStyle(foreground)
                .background(fill, in: outline)
                .overlay {
                    if isPressed && (style.role == .primary || style.role == .destructive) {
                        outline.fill(.black.opacity(0.10)).allowsHitTesting(false)
                    }
                }
                .overlay {
                    outline.strokeBorder(
                        MarrUI.Surface.border(increasedContrast: increasedContrast),
                        lineWidth: increasedContrast && style.role != .ghost ? 1 : 0
                    ).allowsHitTesting(false)
                }
                .opacity(isEnabled ? 1 : increasedContrast ? 0.65 : 0.42)
                .scaleEffect(isPressed && !reducesMotion ? 0.97 : 1)
                .contentShape(outline)
                .overlay {
                    if isFocused {
                        outline.strokeBorder(style.tint, lineWidth: 2)
                            .padding(-3)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .onHover { isHovered = $0 }
                .animation(MarrMotion.press(reducesMotion: reducesMotion), value: isPressed)
                .animation(MarrMotion.transition(reducesMotion: reducesMotion), value: isHovered)
        }
    }
}
