import SwiftUI

enum MarrBubbleColor: String, CaseIterable, Identifiable {
    case system
    case blue
    case green
    case yellow
    case pink
    case orange
    case purple

    static let storageKey = "appearance.bubbleColor"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Default"
        case .blue: "Blue"
        case .green: "Green"
        case .yellow: "Yellow"
        case .pink: "Pink"
        case .orange: "Orange"
        case .purple: "Purple"
        }
    }

    var color: Color {
        switch self {
        case .system: Color(red: 0.90, green: 0.91, blue: 0.92)
        case .blue: Color(red: 0.25, green: 0.50, blue: 0.80)
        case .green: Color(red: 0.20, green: 0.58, blue: 0.39)
        case .yellow: Color(red: 0.70, green: 0.53, blue: 0.15)
        case .pink: Color(red: 0.76, green: 0.38, blue: 0.55)
        case .orange: Color(red: 0.78, green: 0.40, blue: 0.23)
        case .purple: Color(red: 0.50, green: 0.40, blue: 0.76)
        }
    }

    var dotColor: Color {
        switch self {
        case .system: color
        default: color
        }
    }

    var foregroundColor: Color {
        switch self {
        case .system:
            .black.opacity(0.86)
        default:
            .white
        }
    }

    static func resolve(_ rawValue: String) -> MarrBubbleColor {
        MarrBubbleColor(rawValue: rawValue) ?? .system
    }
}

enum MarrAccentColor: String, CaseIterable, Identifiable {
    case system
    case blue
    case green
    case yellow
    case pink
    case orange
    case purple

    static let storageKey = "appearance.accentColor"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Default"
        case .blue: "Blue"
        case .green: "Green"
        case .yellow: "Yellow"
        case .pink: "Pink"
        case .orange: "Orange"
        case .purple: "Purple"
        }
    }

    var color: Color {
        switch self {
        case .system: Color(red: 0.90, green: 0.91, blue: 0.92)
        case .blue: Color(red: 0.25, green: 0.50, blue: 0.80)
        case .green: Color(red: 0.20, green: 0.58, blue: 0.39)
        case .yellow: Color(red: 0.70, green: 0.53, blue: 0.15)
        case .pink: Color(red: 0.76, green: 0.38, blue: 0.55)
        case .orange: Color(red: 0.78, green: 0.40, blue: 0.23)
        case .purple: Color(red: 0.50, green: 0.40, blue: 0.76)
        }
    }

    var foregroundColor: Color {
        switch self {
        case .system:
            .black.opacity(0.86)
        default:
            .white
        }
    }

    var secondaryForegroundColor: Color {
        switch self {
        case .system:
            .black.opacity(0.58)
        default:
            .white.opacity(0.82)
        }
    }

    var dotColor: Color {
        switch self {
        case .system: color
        default: color
        }
    }

    static func resolve(_ rawValue: String) -> MarrAccentColor {
        MarrAccentColor(rawValue: rawValue) ?? .system
    }
}
