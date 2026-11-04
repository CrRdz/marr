import AppKit
import Carbon
import MarrCore
import MarrNetworking
import MarrSettings
import SwiftUI

struct CodexRuntimeConfigurationSettings: View {
    @ObservedObject var workspace: RuntimeWorkspaceController

    private var canEdit: Bool {
        workspace.canWriteConfiguration && !workspace.isRunning
            && !workspace.settingsLoadingMethods.contains("config/value/write")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MarrUI.Spacing.section) {
            if let config = workspace.configuration {
                preferences(config)
                policies(config)
                if !config.layers.isEmpty {
                    CompactSettingsGroup("Configuration sources") {
                        ForEach(config.layers) { layer in
                            VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
                                Text(layer.name).fontWeight(.medium)
                                if let path = layer.path {
                                    Text(path).textSelection(.enabled).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                if let reason = layer.disabledReason {
                                    Text(reason).foregroundStyle(.secondary)
                                }
                            }
                            .marrTextStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                        }
                    }
                }
            }
            if !workspace.configurationStatusMessage.isEmpty {
                Text(workspace.configurationStatusMessage)
                    .marrTextStyle(.secondary).foregroundStyle(.secondary)
            }
            CodexSettingsRequestStatus(workspace: workspace,
                methods: ["config/read", "configRequirements/read", "config/value/write"])
            Button { workspace.refreshConfiguration() } label: {
                Label("Refresh configuration", marrSymbol: "arrow.clockwise")
            }
            .disabled(workspace.settingsLoadingMethods.contains("config/read") || workspace.settingsLoadingMethods.contains("config/value/write"))
            features
        }
        .onAppear {
            workspace.refreshConfiguration()
            workspace.refreshExperimentalFeatures()
        }
    }

    private func preferences(_ config: CodexConfiguration) -> some View {
        CompactSettingsGroup("Preferences", info: "Shared with Codex. Changes apply to new chats; managed policies may override them.") {
            preference("Web search", key: "web_search", value: config.webSearch,
                       options: webSearchOptions, labels: ["disabled": "Off", "cached": "Cached", "indexed": "Indexed", "live": "Live"])
            CompactSettingsDivider()
            preference("Response detail", key: "model_verbosity", value: config.modelVerbosity,
                       options: ["low", "medium", "high"])
            CompactSettingsDivider()
            preference("Reasoning summary", key: "model_reasoning_summary", value: config.modelReasoningSummary,
                       options: ["auto", "concise", "detailed", "none"])
            CompactSettingsDivider()
            CompactSettingsRow("Share analytics", systemImage: "chart.bar") {
                Picker("Share analytics", selection: Binding(
                    get: { config.analyticsEnabled.map { $0 ? "on" : "off" } ?? "" },
                    set: { value in
                        workspace.setConfigurationValue("analytics.enabled", value: value.isEmpty ? NSNull() : value == "on")
                    }
                )) {
                    Text("Default").tag("")
                    Text("On").tag("on")
                    Text("Off").tag("off")
                }
                .labelsHidden().controlSize(.small).disabled(!canEdit)
            }
        }
    }

    private var webSearchOptions: [String] {
        let options = ["disabled", "cached", "indexed", "live"]
        guard let allowed = workspace.configurationRequirements?.allowedWebSearchModes else { return options }
        return options.filter { allowed.contains($0) }
    }

    private func preference(_ title: String, key: String, value: String?, options: [String], labels: [String: String] = [:]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            CompactSettingsRow(title, systemImage: "slider.horizontal.3") {
                Picker(title, selection: Binding(
                    get: { value ?? "" },
                    set: { workspace.setConfigurationValue(key, value: $0.isEmpty ? NSNull() : $0 as Any) }
                )) {
                    Text("Default").tag("")
                    ForEach(options, id: \.self) { option in
                        Text(labels[option] ?? option.capitalized).tag(option)
                    }
                    if let value, !options.contains(value) {
                        Text(value.capitalized).tag(value).disabled(true)
                    }
                }
                .labelsHidden().controlSize(.small).disabled(!canEdit)
            }
            if let origin = workspace.configuration?.origins[key] {
                Text("From \(origin)")
                    .marrTextStyle(.caption).foregroundStyle(.secondary)
                    .padding(.bottom, 8)
            }
        }
    }

    private func policies(_ config: CodexConfiguration) -> some View {
        CompactSettingsGroup("Runtime policies") {
            policy("Model provider", value: config.modelProvider)
            policy("Approval policy", value: config.approvalPolicy)
            policy("Sandbox", value: config.sandboxMode)
            if let requirements = workspace.configurationRequirements {
                Text(requirements.summary)
                    .marrTextStyle(.secondary).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            }
        }
    }

    @ViewBuilder private func policy(_ title: String, value: String?) -> some View {
        if let value {
            VStack(alignment: .leading, spacing: MarrUI.Spacing.tight) {
                Text(title).foregroundStyle(.secondary)
                Text(value == "openai" ? "OpenAI" : value.replacingOccurrences(of: "-", with: " ").capitalized).textSelection(.enabled)
            }
            .marrTextStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
        }
    }

    private var features: some View {
        CompactSettingsGroup("Runtime features") {
            VStack(alignment: .leading, spacing: MarrUI.Spacing.medium) {
                ForEach(workspace.experimentalFeatures) { feature in
                    HStack(alignment: .top, spacing: MarrUI.Spacing.regular) {
                        VStack(alignment: .leading, spacing: MarrUI.Spacing.tight) {
                            Text(feature.displayName).fontWeight(.medium)
                            if !feature.description.isEmpty {
                                Text(feature.description).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Text(feature.stage == "underDevelopment" ? "In development" : feature.stage.capitalized)
                                .marrTextStyle(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(feature.enabled ? "On" : "Off").foregroundStyle(.secondary)
                    }
                    .marrTextStyle(.secondary)
                }
                CodexSettingsRequestStatus(workspace: workspace, methods: ["experimentalFeature/list"])
                Button("Refresh features") { workspace.refreshExperimentalFeatures() }
                    .disabled(workspace.settingsLoadingMethods.contains("experimentalFeature/list"))
            }
        }
    }
}

struct CodexSettingsRequestStatus: View {
    @ObservedObject var workspace: RuntimeWorkspaceController
    let methods: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
            if methods.contains(where: { workspace.settingsLoadingMethods.contains($0) }) {
                ProgressView("Loading…").controlSize(.small)
            }
            ForEach(methods, id: \.self) { method in
                if let error = workspace.settingsErrors[method] {
                    Text(error).foregroundStyle(MarrUI.Status.error.color())
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if let diagnostic = workspace.settingsDiagnostics[method], diagnostic != error {
                        DisclosureGroup("Details") {
                            ScrollView {
                                Text(diagnostic).marrTextStyle(.code).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 140)
                        }
                    }
                }
            }
        }
        .marrTextStyle(.secondary)
    }
}
