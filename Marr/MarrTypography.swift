import AppKit
import CoreText
import SwiftUI

/// Shared type scale for app chrome. Screenshot translation keeps its source typography.
enum MarrTypography {
    enum Role {
        case hero, brand, pageTitle, title, body, secondary, caption, badge, code, codeControl

        var size: CGFloat {
            switch self {
            case .hero: return 24
            case .brand: return 20
            case .pageTitle: return 16
            case .title: return 14
            case .body, .codeControl: return 13
            case .secondary, .code: return 12
            case .caption: return 11
            case .badge: return 10
            }
        }
    }

    static func font(_ role: Role, weight: Font.Weight = .regular) -> Font {
        .system(
            size: role.size,
            weight: weight,
            design: role == .code || role == .codeControl ? .monospaced : .default
        )
    }

    static var menuFont: NSFont { .menuFont(ofSize: Role.body.size) }

    static func registerBundledFonts() {
        let fontURLs = ["ttf", "otf"].flatMap {
            Bundle.main.urls(forResourcesWithExtension: $0, subdirectory: "Fonts") ?? []
        }
        for url in fontURLs {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
