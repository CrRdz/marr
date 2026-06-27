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
        case .system: Color.accentColor
        case .blue: Color(red: 0.04, green: 0.48, blue: 0.98)
        case .green: Color(red: 0.05, green: 0.68, blue: 0.33)
        case .yellow: Color(red: 0.95, green: 0.68, blue: 0.05)
        case .pink: Color(red: 0.96, green: 0.36, blue: 0.62)
        case .orange: Color(red: 0.94, green: 0.34, blue: 0.12)
        case .purple: Color(red: 0.58, green: 0.42, blue: 0.92)
        }
    }

    var dotColor: Color {
        switch self {
        case .system: .secondary
        default: color
        }
    }

    static func resolve(_ rawValue: String) -> MarrBubbleColor {
        MarrBubbleColor(rawValue: rawValue) ?? .system
    }
}
