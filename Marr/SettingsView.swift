import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var controller: MarrController
    @State private var selection: SettingsSection = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .font(MarrTypography.body(size: 14, weight: selection == section ? .semibold : .regular))
                    .tag(section)
            }
            .navigationTitle("Settings")
            .frame(minWidth: 190)
        } detail: {
            Form {
                selectedPanel
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .padding(.top, 8)
            .background(.regularMaterial)
            .navigationTitle(selection.title)
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 520, idealHeight: 580)
    }

    @ViewBuilder
    private var selectedPanel: some View {
        switch selection {
        case .general:
            GeneralSettingsPanel(controller: controller)
        case .capture:
            CaptureSettingsPanel()
        case .provider:
            ProviderSettingsPanel(controller: controller)
        case .appearance:
            AppearanceSettingsPanel()
        case .advanced:
            AdvancedSettingsPanel(controller: controller)
        }
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case capture
    case provider
    case appearance
    case advanced

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .capture: "Capture"
        case .provider: "AI Provider"
        case .appearance: "Appearance"
        case .advanced: "Advanced"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .capture: "viewfinder"
        case .provider: "sparkles"
        case .appearance: "sun.max"
        case .advanced: "wrench.and.screwdriver"
        }
    }
}

private struct GeneralSettingsPanel: View {
    @ObservedObject var controller: MarrController
    @AppStorage("general.showProviderInMenu") private var showProviderInMenu = true
    @State private var isConfirmingHistoryClear = false

    var body: some View {
        Section("Menu Bar") {
            Toggle("Show provider in menu", isOn: $showProviderInMenu)
            SettingsValueRow(title: "Status", value: statusLabel)
        }

        Section("History") {
            SettingsValueRow(
                title: "Saved conversations",
                value: "\(controller.historyStore.conversations.count)"
            )

            Button("Clear History", role: .destructive) {
                isConfirmingHistoryClear = true
            }
            .disabled(controller.historyStore.conversations.isEmpty)
            .confirmationDialog(
                "Clear all conversation history?",
                isPresented: $isConfirmingHistoryClear
            ) {
                Button("Clear History", role: .destructive) {
                    controller.historyStore.deleteAll()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private var statusLabel: String {
        guard let message = controller.statusMessage else { return "Ready" }
        if message.localizedCaseInsensitiveContains("could not") { return "Needs attention" }
        if message.localizedCaseInsensitiveContains("drag") || message.localizedCaseInsensitiveContains("select") { return "Capturing" }
        return "Ready"
    }
}

private struct CaptureSettingsPanel: View {
    var body: some View {
        Section("Shortcut") {
            SettingsValueRow(title: "Capture area", value: "⌘⇧0")
            SettingsValueRow(title: "Hotkey scope", value: "Global")
        }

        Section("Answer Panel") {
            SettingsValueRow(title: "New capture", value: "Open answer panel")
            SettingsValueRow(title: "When minimized", value: "Shortcut restores panel")
        }
    }
}

private struct ProviderSettingsPanel: View {
    @ObservedObject var controller: MarrController

    var body: some View {
        Section("Provider") {
            Picker("Provider", selection: $controller.provider) {
                ForEach(InferenceProvider.allCases) { provider in
                    Text(provider.rawValue).tag(provider)
                }
            }
            .pickerStyle(.segmented)

            TextField("Model", text: $controller.model)
        }

        if controller.provider == .openAI {
            Section("OpenAI") {
                SecureField("API Key", text: $controller.apiKey)
            }
        } else {
            gatewaySection
        }
    }

    private var gatewaySection: some View {
        Section("Gateway") {
            TextField("Base URL", text: $controller.gatewayBaseURL)

            Picker("API Format", selection: $controller.gatewayAPIFormat) {
                ForEach(GatewayAPIFormat.allCases) { format in
                    Text(format.rawValue).tag(format)
                }
            }

            Picker("Auth Scheme", selection: $controller.gatewayAuthScheme) {
                ForEach(GatewayAuthScheme.allCases) { scheme in
                    Text(scheme.rawValue).tag(scheme)
                }
            }

            SecureField("API Key", text: $controller.gatewayAPIKey)

            VStack(alignment: .leading, spacing: 6) {
                Text("Custom Headers")
                    .font(MarrTypography.body(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextEditor(text: $controller.customHeadersText)
                    .font(MarrTypography.mono(size: 12))
                    .frame(minHeight: 88)
                    .scrollContentBackground(.hidden)
                    .padding(7)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(.secondary.opacity(0.22)))
            }

            Button("Use CC Switch Preset") {
                controller.useCCSwitchClaudeDesktopPreset()
            }
        }
    }
}

private struct AppearanceSettingsPanel: View {
    @AppStorage("appearance.colorScheme") private var colorScheme = "System"
    @AppStorage("appearance.glassSurfaces") private var glassSurfaces = true
    @AppStorage(MarrBubbleColor.storageKey) private var bubbleColor = MarrBubbleColor.system.rawValue

    var body: some View {
        Section("Theme") {
            Picker("Color Scheme", selection: $colorScheme) {
                Text("System").tag("System")
                Text("Light").tag("Light")
                Text("Dark").tag("Dark")
            }
            .pickerStyle(.segmented)
        }

        Section("Surfaces") {
            Toggle("Use glass surfaces", isOn: $glassSurfaces)
            SettingsValueRow(title: "Fallback", value: "Material")
        }

        Section("Messages") {
            Picker("Bubble Color", selection: $bubbleColor) {
                ForEach(MarrBubbleColor.allCases) { option in
                    Label {
                        Text(option.title)
                    } icon: {
                        Circle()
                            .fill(option.dotColor)
                            .frame(width: 9, height: 9)
                    }
                    .tag(option.rawValue)
                }
            }
        }

        Section("Typography") {
            SettingsValueRow(title: "Display", value: "LXGW WenKai")
            SettingsValueRow(title: "Text", value: "Noto Sans CJK SC")
            SettingsValueRow(title: "Mono", value: "IBM Plex Mono")
        }
    }
}

private struct AdvancedSettingsPanel: View {
    @ObservedObject var controller: MarrController

    var body: some View {
        Section("Presets") {
            Button("Reset Provider to CC Switch") {
                controller.useCCSwitchClaudeDesktopPreset()
            }
        }

        Section("Diagnostics") {
            SettingsValueRow(title: "Last error", value: controller.historyStore.lastErrorMessage ?? "None")
        }
    }
}

private struct SettingsValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(MarrTypography.body(size: 13))
    }
}
