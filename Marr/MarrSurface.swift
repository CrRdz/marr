import SwiftUI

extension View {
    func marrGlassSurface(cornerRadius: CGFloat, isClear: Bool = false) -> some View {
        modifier(MarrGlassSurfaceModifier(cornerRadius: cornerRadius, isClear: isClear))
    }
}

private struct MarrGlassSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let isClear: Bool

    @AppStorage("appearance.glassSurfaces") private var usesGlassSurfaces = true

    func body(content: Content) -> some View {
        if usesGlassSurfaces, #available(macOS 26.0, *) {
            content.glassEffect(
                isClear ? .clear.interactive() : .regular.interactive(),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.white.opacity(isClear ? 0.04 : 0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(.white.opacity(isClear ? 0.18 : 0.28), lineWidth: 1)
                )
        }
    }
}
