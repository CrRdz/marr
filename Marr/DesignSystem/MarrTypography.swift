import AppKit
import CoreText
import SwiftUI

/// Shared type scale for controls and answers. Screenshot translation keeps its source typography.
enum MarrTypography {
    enum Role: String, CaseIterable, Identifiable {
        case hero, brand, pageTitle, title, answer, body, secondary, caption, badge, code, codeControl

        var id: String { rawValue }

        var size: CGFloat {
            switch self {
            case .hero: return 24
            case .brand: return 20
            case .pageTitle: return 18
            case .title: return 16
            case .answer: return 14
            case .body, .codeControl: return 13
            case .secondary, .code: return 12
            case .caption: return 11
            case .badge: return 10
            }
        }

        var weight: Font.Weight {
            switch self {
            case .hero, .brand, .pageTitle, .title: return .semibold
            case .badge: return .medium
            default: return .regular
            }
        }

        /// Extra leading beyond the system font's own line height, in points.
        var lineSpacing: CGFloat {
            switch self {
            case .answer: return 4
            case .body: return 3
            case .secondary: return 2
            case .hero, .brand, .pageTitle, .title: return 2
            case .caption, .badge, .code, .codeControl: return 1
            }
        }

        /// Spacing between prose paragraphs; compact controls do not add it.
        var paragraphSpacing: CGFloat {
            switch self {
            case .hero, .brand, .pageTitle: return 12
            case .title, .answer, .body: return 8
            case .secondary: return 6
            case .caption, .badge: return 4
            case .code, .codeControl: return 0
            }
        }

        var usesMonospacedFont: Bool { self == .code || self == .codeControl }
    }

    static func font(_ role: Role, weight: Font.Weight = .regular) -> Font {
        .system(
            size: role.size,
            weight: weight,
            design: role.usesMonospacedFont ? .monospaced : .default
        )
    }

    /// Icon footprints match the text role; glyph ink occupies 84% of the box.
    static func iconSize(for role: Role) -> CGFloat {
        switch role {
        case .hero, .brand: MarrUI.Icon.hero
        case .pageTitle, .title: MarrUI.Icon.navigation
        case .answer, .body, .codeControl: MarrUI.Icon.inline
        case .secondary, .caption, .badge, .code: MarrUI.Icon.status
        }
    }

    static var menuFont: NSFont { .menuFont(ofSize: Role.body.size) }

    /// Transcript rhythm is shared by Markdown prose, prompts and code. Use
    /// the system sans family (including its CJK fallback), never a UI scale.
    enum Reading {
        static let columnWidth: CGFloat = 720
        static let blockSpacing: CGFloat = 10
        static let compactBlockSpacing: CGFloat = 6
        static let listSpacing: CGFloat = 4
        static let codeSize: CGFloat = 13
        static let codeLeading: CGFloat = 4

        static func headingSize(_ level: Int, compact: Bool) -> CGFloat {
            if compact { return Role.answer.size }
            switch level {
            case 1: return 18
            case 2: return 16
            default: return Role.answer.size
            }
        }
    }

    static func registerBundledFonts() {
        let fontURLs = ["ttf", "otf"].flatMap {
            Bundle.main.urls(forResourcesWithExtension: $0, subdirectory: "Fonts") ?? []
        }
        for url in fontURLs {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

extension View {
    /// Shared text rhythm. Paragraph spacing is opt-in so form controls retain
    /// their native hit areas and single-line labels do not acquire extra padding.
    func marrTextStyle(_ role: MarrTypography.Role, weight: Font.Weight? = nil,
                       paragraph: Bool = false) -> some View {
        font(MarrTypography.font(role, weight: weight ?? role.weight))
            .environment(\.marrIconSize, MarrTypography.iconSize(for: role))
            .lineSpacing(role.lineSpacing)
            .padding(.bottom, paragraph ? role.paragraphSpacing : 0)
    }
}
