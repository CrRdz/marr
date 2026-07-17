import AppKit
import SwiftUI

enum MarrAppearanceKeys {
    static let colorScheme = "appearance.colorScheme"
    static let glassSurfaces = "appearance.glassSurfaces"
}

enum MarrSurfaceMode: Equatable {
    case activeClear
    case activeRegular
    case standardMaterial

    static func resolve(usesLiquidGlass: Bool, prefersClearGlass: Bool) -> Self {
        guard usesLiquidGlass else { return .standardMaterial }
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
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    @ViewBuilder
    func body(content: Content) -> some View {
        if reducesTransparency {
            content
                .background(
                    reducedTransparencyColor,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .overlay(surfaceBorder)
        } else if surfaceMode == .standardMaterial {
            content
                .background(
                    .regularMaterial,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .background(
                    standardMaterialBacking,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .overlay(surfaceBorder)
        } else if #available(macOS 26.0, *) {
            switch surfaceMode {
            case .activeClear:
                content
                    .glassEffect(
                        .clear.tint(readabilityTint),
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    )
                    .overlay(surfaceBorder)
            case .activeRegular:
                content
                    .glassEffect(
                        .regular.tint(readabilityTint),
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    )
                    .overlay(surfaceBorder)
            case .standardMaterial:
                EmptyView()
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
        .resolve(usesLiquidGlass: usesGlassSurfaces, prefersClearGlass: isClear)
    }

    private var readabilityTint: Color {
        let opacity: Double
        if colorSchemeContrast == .increased {
            opacity = isClear ? 0.68 : 0.58
        } else {
            opacity = isClear ? 0.52 : 0.44
        }
        return contrastBaseColor.opacity(opacity)
    }

    private var standardMaterialBacking: Color {
        contrastBaseColor.opacity(colorSchemeContrast == .increased ? 0.52 : 0.34)
    }

    private var contrastBaseColor: Color {
        colorScheme == .dark ? .black : .white
    }

    private var frostedSurfaceTint: Color {
        contrastBaseColor.opacity(colorSchemeContrast == .increased ? 0.62 : isClear ? 0.48 : 0.40)
    }

    private var reducedTransparencyColor: Color {
        colorScheme == .dark
            ? .init(nsColor: .windowBackgroundColor).opacity(0.96)
            : .init(nsColor: .windowBackgroundColor).opacity(0.94)
    }

    private var surfaceBorder: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .stroke(.primary.opacity(colorSchemeContrast == .increased ? 0.30 : isClear ? 0.16 : 0.20), lineWidth: 1)
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
