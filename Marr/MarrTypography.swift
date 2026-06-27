import AppKit
import CoreText
import SwiftUI

enum MarrTypography {
    static let displayCandidates = [
        "LXGWWenKai-Regular",
        "LXGW WenKai",
        "SmileySans-Oblique",
        "Smiley Sans"
    ]

    static let bodyCandidates = [
        "HarmonyOS Sans SC",
        "HarmonyOS_Sans_SC",
        "NotoSansCJKsc-Regular",
        "Noto Sans CJK SC",
        "Noto Sans SC"
    ]

    static let latinCandidates = [
        "IBMPlexSans",
        "IBMPlexSans-SmBld",
        "IBM Plex Sans",
        "IBM Plex Sans Text"
    ]

    static let monoCandidates = [
        "IBMPlexMono",
        "IBMPlexMono-SmBld",
        "IBM Plex Mono",
        "SF Mono"
    ]

    static func registerBundledFonts() {
        let fontURLs = ["ttf", "otf"].flatMap {
            Bundle.main.urls(forResourcesWithExtension: $0, subdirectory: "Fonts") ?? []
        }

        for url in fontURLs {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    static func display(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        preferredFont(candidates: displayCandidates, size: size, fallbackWeight: weight)
    }

    static func body(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let candidates = boldish(weight) ? [
            "HarmonyOS Sans SC",
            "HarmonyOS_Sans_SC",
            "NotoSansCJKsc-Medium",
            "Noto Sans CJK SC",
            "Noto Sans SC"
        ] : bodyCandidates
        return preferredFont(candidates: candidates, size: size, fallbackWeight: weight)
    }

    static func latin(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let candidates = boldish(weight) ? [
            "IBMPlexSans-SmBld",
            "IBM Plex Sans",
            "IBMPlexSans",
            "IBM Plex Sans Text"
        ] : latinCandidates
        return preferredFont(candidates: candidates, size: size, fallbackWeight: weight)
    }

    static func mono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let candidates = boldish(weight) ? [
            "IBMPlexMono-SmBld",
            "IBM Plex Mono",
            "IBMPlexMono",
            "SF Mono"
        ] : monoCandidates
        return preferredFont(candidates: candidates, size: size, fallbackWeight: weight, design: .monospaced)
    }

    static func caption(weight: Font.Weight = .regular) -> Font {
        body(size: 12, weight: weight)
    }

    static func caption2(weight: Font.Weight = .regular) -> Font {
        body(size: 11, weight: weight)
    }

    private static func preferredFont(
        candidates: [String],
        size: CGFloat,
        fallbackWeight: Font.Weight,
        design: Font.Design = .default
    ) -> Font {
        for candidate in candidates where NSFont(name: candidate, size: size) != nil {
            return .custom(candidate, size: size).weight(fallbackWeight)
        }

        return .system(size: size, weight: fallbackWeight, design: design)
    }

    private static func boldish(_ weight: Font.Weight) -> Bool {
        weight == .medium || weight == .semibold || weight == .bold || weight == .heavy || weight == .black
    }
}
