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
        static let panel: CGFloat = 16
        static let composer: CGFloat = 20
    }

    enum Control {
        static let compact: CGFloat = 28
        static let regular: CGFloat = 32
        static let spacious: CGFloat = 36
    }

    enum Icon {
        static let disclosure: CGFloat = 10
        static let status: CGFloat = 12
        static let inline: CGFloat = 14
        static let navigation: CGFloat = 16
        static let toolbar: CGFloat = 18
        static let hero: CGFloat = 24
    }

    enum Row {
        static let height: CGFloat = 32
        static let detailHeight: CGFloat = 56
        static let inset: CGFloat = 8
        static let indent: CGFloat = 20
    }

    enum SurfaceRole: String, CaseIterable, Identifiable {
        case canvas, content, card, popover, input
        var id: String { rawValue }
    }

    /// Opaque native fallback surfaces. Glass remains a separate material choice
    /// at the window/composer boundary rather than leaking into semantic roles.
    enum Surface {
        static var canvas: Color { adaptive(light: 0xFFFFFF, dark: 0x20201F) }
        static var raised: Color { adaptive(light: 0xFFFFFF, dark: 0x2C2C2A) }
        static var content: Color { adaptive(light: 0xFFFFFF, dark: 0x252524) }
        static var card: Color { raised }
        static var popover: Color { raised }
        static var input: Color { raised }

        private static func adaptive(light: Int, dark: Int) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
                return NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                               green: CGFloat((hex >> 8) & 255) / 255,
                               blue: CGFloat(hex & 255) / 255, alpha: 1)
            })
        }

        static func color(_ role: SurfaceRole) -> Color {
            switch role {
            case .canvas: return canvas
            case .content: return content
            case .card: return card
            case .popover: return popover
            case .input: return input
            }
        }

        static func border(increasedContrast: Bool) -> Color {
            Border.color(.standard, increasedContrast: increasedContrast)
        }
    }

    enum BorderRole: String, CaseIterable, Identifiable {
        case subtle, standard, focus
        var id: String { rawValue }
    }

    enum Border {
        static func opacity(_ role: BorderRole, increasedContrast: Bool) -> Double {
            switch role {
            case .subtle: return increasedContrast ? 0.32 : 0.08
            case .standard: return increasedContrast ? 0.42 : 0.12
            case .focus: return 1
            }
        }

        static func color(_ role: BorderRole, increasedContrast: Bool = false,
                          tint: Color = .accentColor) -> Color {
            (role == .focus ? tint : .primary).opacity(opacity(role, increasedContrast: increasedContrast))
        }

        static func width(_ role: BorderRole, increasedContrast: Bool = false) -> CGFloat {
            role == .focus ? 2 : increasedContrast ? 1 : 0.75
        }
    }

    enum Status: String, CaseIterable, Identifiable {
        case idle, running, needsInput, success, error
        var id: String { rawValue }

        var title: String {
            switch self {
            case .idle: return "Ready"
            case .running: return "Running"
            case .needsInput: return "Needs input"
            case .success: return "Completed"
            case .error: return "Failed"
            }
        }

        var symbolName: String {
            switch self {
            case .idle: return "circle"
            case .running: return "circle.dotted"
            case .needsInput: return "questionmark.circle"
            case .success: return "checkmark.circle"
            case .error: return "exclamationmark.circle"
            }
        }

        func color(tint: Color = .accentColor) -> Color {
            switch self {
            case .idle: return .secondary
            case .running: return tint
            case .needsInput: return Color(nsColor: .systemOrange)
            case .success: return Color(nsColor: .systemGreen)
            case .error: return Color(nsColor: .systemRed)
            }
        }
    }
}

/// Symbol and text accompany every status, so color is never its only meaning.
/// The caller supplies real runtime state; this component has no timers or state transitions.
struct MarrStatusLabel: View {
    let status: MarrUI.Status
    var title: String?
    var tint: Color

    init(_ status: MarrUI.Status, title: String? = nil, tint: Color = .accentColor) {
        self.status = status
        self.title = title
        self.tint = tint
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: MarrUI.Spacing.small) {
            MarrIcon(status.symbolName)
                .foregroundStyle(status.color(tint: tint))
                .accessibilityHidden(true)
            Text(title ?? status.title)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .marrTextStyle(.secondary, weight: .medium)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    func marrSurface(_ role: MarrUI.SurfaceRole, cornerRadius: CGFloat = MarrUI.Radius.card,
                     border: MarrUI.BorderRole = .subtle, tint: Color = .accentColor) -> some View {
        modifier(MarrSemanticSurface(role: role, cornerRadius: cornerRadius, border: border, tint: tint))
    }
}

private struct MarrSemanticSurface: ViewModifier {
    let role: MarrUI.SurfaceRole
    let cornerRadius: CGFloat
    let border: MarrUI.BorderRole
    let tint: Color
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.marrAccessibilityOverrides) private var accessibilityOverrides

    func body(content: Content) -> some View {
        let increasedContrast = accessibilityOverrides?.increasedContrast ?? (contrast == .increased)
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(MarrUI.Surface.color(role), in: shape)
            .overlay {
                shape.strokeBorder(MarrUI.Border.color(border, increasedContrast: increasedContrast, tint: tint),
                                   lineWidth: MarrUI.Border.width(border, increasedContrast: increasedContrast))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
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

struct MarrAmbientWindowVisibilityObserver: NSViewRepresentable {
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
                .marrTextStyle(.body, weight: .medium)
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
                        outline.strokeBorder(MarrUI.Border.color(.focus, increasedContrast: increasedContrast, tint: style.tint),
                                             lineWidth: MarrUI.Border.width(.focus, increasedContrast: increasedContrast))
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
