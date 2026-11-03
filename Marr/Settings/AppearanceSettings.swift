import AppKit
import Carbon
import MarrCore
import MarrNetworking
import MarrSettings
import SwiftUI

struct CompactAppearanceSettingsPanel: View {
    @AppStorage(MarrAppearanceKeys.colorScheme) private var colorScheme = "System"
    @AppStorage(MarrAppearanceKeys.glassSurfaces) private var glassSurfaces = true
    @AppStorage(MarrBubbleColor.storageKey) private var bubbleColor = MarrBubbleColor.system.rawValue
    @AppStorage(MarrAccentColor.storageKey) private var accentColor = MarrAccentColor.system.rawValue

    var body: some View {
        VStack(spacing: MarrSettingsLayout.sectionSpacing) {
            CompactSettingsGroup("Theme") {
                HStack(spacing: MarrUI.Spacing.regular) {
                    ForEach(["System", "Light", "Dark"], id: \.self) { theme in
                        SettingsThemePreview(
                            title: theme,
                            isSelected: colorScheme == theme,
                            tint: settingsTint,
                            bubbleColor: selectedBubble
                        ) {
                            colorScheme = theme
                        }
                    }
                }
                .frame(maxWidth: 380, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .padding(.bottom, 8)

                CompactSettingsDivider()

                CompactSettingsRow("Liquid Glass", systemImage: "rectangle") {
                    Toggle("Liquid Glass", isOn: $glassSurfaces)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .accessibilityLabel("Liquid Glass")
                        .help("Translucent surfaces that follow macOS accessibility settings.")
                }
            }

            CompactSettingsGroup("Colors") {
                HStack(spacing: MarrUI.Spacing.regular) {
                    VStack(alignment: .leading, spacing: MarrUI.Spacing.tight) {
                        Text("Bubble")
                            .marrTextStyle(.body)
                        Text(selectedBubble.title)
                            .marrTextStyle(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 54, alignment: .leading)
                    HStack(spacing: MarrUI.Spacing.tight) {
                        ForEach(MarrBubbleColor.allCases) { color in
                            SettingsColorSwatch(
                                title: color.title,
                                color: color.dotColor,
                                isDefault: color == .system,
                                isSelected: selectedBubble == color,
                                tint: settingsTint,
                                accessibilityContext: "Bubble color"
                            ) {
                                bubbleColor = color.rawValue
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)

                CompactSettingsDivider()

                HStack(spacing: MarrUI.Spacing.regular) {
                    VStack(alignment: .leading, spacing: MarrUI.Spacing.tight) {
                        Text("Accent")
                            .marrTextStyle(.body)
                        Text(selectedAccent.title)
                            .marrTextStyle(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 54, alignment: .leading)
                    HStack(spacing: MarrUI.Spacing.tight) {
                        ForEach(MarrAccentColor.allCases) { color in
                            SettingsColorSwatch(
                                title: color.title,
                                color: color.dotColor,
                                isDefault: color == .system,
                                isSelected: selectedAccent == color,
                                tint: settingsTint,
                                accessibilityContext: "Accent color"
                            ) {
                                accentColor = color.rawValue
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
        }
    }

    private var selectedBubble: MarrBubbleColor { MarrBubbleColor.resolve(bubbleColor) }
    private var selectedAccent: MarrAccentColor { MarrAccentColor.resolve(accentColor) }
    private var settingsTint: Color { selectedAccent == .system ? .accentColor : selectedAccent.color }
}

private struct SettingsThemePreview: View {
    let title: String
    let isSelected: Bool
    let tint: Color
    let bubbleColor: MarrBubbleColor
    let action: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Button(action: action) {
            VStack(spacing: MarrUI.Spacing.regular) {
                ZStack {
                    SettingsThemeWindowPreview(isDark: title == "Dark", bubbleColor: bubbleColor, tint: tint)
                    if title == "System" {
                        SettingsThemeWindowPreview(isDark: true, bubbleColor: bubbleColor, tint: tint)
                            .mask {
                                HStack(spacing: 0) {
                                    Color.clear
                                    Rectangle()
                                }
                            }
                    }
                }
                .frame(height: 56)
                .clipShape(RoundedRectangle(cornerRadius: MarrUI.Radius.control, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: MarrUI.Radius.control, style: .continuous)
                        .strokeBorder(
                            isSelected ? tint : .primary.opacity(contrast == .increased ? 0.40 : 0.16),
                            lineWidth: isSelected ? 1.5 : 0.5
                        )
                }
                .overlay(alignment: .bottomTrailing) {
                    if isSelected {
                        MarrIcon("checkmark.circle.fill", size: MarrUI.Icon.status)
                            .foregroundStyle(tint)
                            .padding(4)
                    }
                }

                Text(title)
                    .marrTextStyle(.secondary, weight: isSelected ? .medium : .regular)
                .foregroundStyle(.primary)
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) appearance")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(title == "System" ? "Follow the macOS appearance" : "Use \(title.lowercased()) appearance")
    }
}

private struct SettingsThemeWindowPreview: View {
    let isDark: Bool
    let bubbleColor: MarrBubbleColor
    let tint: Color

    var body: some View {
        VStack(spacing: MarrUI.Spacing.regular) {
            HStack(spacing: MarrUI.Spacing.tight) {
                ForEach(0..<3) { _ in
                    Circle().fill(ink.opacity(0.22)).frame(width: 2, height: 2)
                }
                Spacer(minLength: 0)
            }

            HStack {
                Spacer(minLength: 0)
                RoundedRectangle(cornerRadius: 4)
                    .fill(bubbleColor == .system ? ink.opacity(0.08) : bubbleColor.color.opacity(isDark ? 0.64 : 0.22))
                    .frame(width: 30, height: 8)
            }

            VStack(alignment: .leading, spacing: MarrUI.Spacing.tight) {
                Capsule().fill(ink.opacity(0.32)).frame(width: 35, height: 2)
                Capsule().fill(ink.opacity(0.20)).frame(width: 25, height: 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Capsule().fill(ink.opacity(0.13)).frame(width: 24, height: 2)
                Spacer(minLength: 0)
                Circle().fill(tint).frame(width: 4, height: 4)
            }
            .padding(.horizontal, 5)
            .frame(height: 8)
            .background(ink.opacity(0.055), in: RoundedRectangle(cornerRadius: 4))
        }
        .padding(7)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: isDark ? 0.12 : 0.97))
        .accessibilityHidden(true)
    }

    private var ink: Color { isDark ? .white : .black }
}

private struct SettingsColorSwatch: View {
    let title: String
    let color: Color
    let isDefault: Bool
    let isSelected: Bool
    let tint: Color
    let accessibilityContext: String
    let action: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(isDefault ? Color.primary.opacity(0.08) : color)
                .frame(width: 20, height: 20)
                .overlay {
                    Circle().strokeBorder(.primary.opacity(contrast == .increased ? 0.55 : 0.18), lineWidth: 0.5)
                    if isDefault {
                        MarrIcon("circle.lefthalf.filled", size: MarrUI.Icon.status)
                            .foregroundStyle(.primary)
                    }
                }
                .overlay {
                    Circle()
                        .strokeBorder(isSelected ? tint : .clear, lineWidth: 1.5)
                        .padding(-3)
                }
                .overlay(alignment: .bottomTrailing) {
                    if isSelected {
                        MarrIcon("checkmark", size: MarrUI.Icon.disclosure)
                            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                            .frame(width: 10, height: 10)
                            .background(.primary, in: Circle())
                            .offset(x: 2, y: 2)
                    }
                }
                .frame(width: 28, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(accessibilityContext), \(title)")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help("\(accessibilityContext): \(title)")
    }
}
