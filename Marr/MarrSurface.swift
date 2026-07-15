import AppKit
import SwiftUI

enum MarrAppearanceKeys {
    static let colorScheme = "appearance.colorScheme"
    static let glassSurfaces = "appearance.glassSurfaces"
}

enum MarrSurfaceMode: Equatable {
    case activeClear
    case activeRegular
    case unfocused

    static func resolve(usesActiveGlass: Bool, prefersClearGlass: Bool) -> Self {
        guard usesActiveGlass else { return .unfocused }
        return prefersClearGlass ? .activeClear : .activeRegular
    }
}

extension View {
    func marrGlassSurface(cornerRadius: CGFloat, isClear: Bool = false) -> some View {
        modifier(MarrGlassSurfaceModifier(cornerRadius: cornerRadius, isClear: isClear))
    }

    func marrPreferredColorScheme() -> some View {
        modifier(MarrPreferredColorSchemeModifier())
    }
}

private struct MarrGlassSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let isClear: Bool

    @AppStorage(MarrAppearanceKeys.glassSurfaces) private var usesGlassSurfaces = true
    @Environment(\.accessibilityReduceTransparency) private var reducesTransparency
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        if reducesTransparency {
            content
                .background(
                    reducedTransparencyColor,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .overlay(surfaceBorder)
        } else if #available(macOS 26.0, *) {
            switch surfaceMode {
            case .activeClear:
                content.glassEffect(
                    .clear,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
            case .activeRegular:
                content.glassEffect(
                    .regular,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
            case .unfocused:
                content
                    .glassEffect(
                        .regular.tint(unfocusedGlassTint),
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    )
                    .environment(\.appearsActive, false)
            }
        } else {
            content
                .background(
                    .regularMaterial,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(frostedSurfaceTint)
                        .allowsHitTesting(false)
                )
                .overlay(surfaceBorder)
        }
    }

    private var surfaceMode: MarrSurfaceMode {
        .resolve(usesActiveGlass: usesGlassSurfaces, prefersClearGlass: isClear)
    }

    private var unfocusedGlassTint: Color {
        colorScheme == .dark
            ? .black.opacity(0.22)
            : .white.opacity(0.30)
    }

    private var frostedSurfaceTint: Color {
        if surfaceMode == .unfocused {
            return colorScheme == .dark
                ? .black.opacity(0.22)
                : .white.opacity(0.30)
        }

        if colorScheme == .dark {
            return .black.opacity(isClear ? 0.06 : 0.12)
        }
        return .white.opacity(isClear ? 0.06 : 0.12)
    }

    private var reducedTransparencyColor: Color {
        colorScheme == .dark
            ? .init(nsColor: .windowBackgroundColor).opacity(0.96)
            : .init(nsColor: .windowBackgroundColor).opacity(0.94)
    }

    private var surfaceBorder: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .stroke(.primary.opacity(isClear ? 0.12 : 0.18), lineWidth: 1)
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
