import AppKit
import Carbon
import MarrCore
import MarrNetworking
import MarrSettings
import SwiftUI

struct CodexConversationSettings: View {
    @ObservedObject var workspace: RuntimeWorkspaceController

    var body: some View {
        VStack(alignment: .leading, spacing: MarrUI.Spacing.medium) {
            CompactSettingsGroup("Conversation model") {
                CompactSettingsRow("Model", systemImage: "square.stack") {
                    Picker("Conversation model", selection: Binding(
                        get: { workspace.selectedModel },
                        set: { workspace.selectModel($0) }
                    )) {
                        ForEach(workspace.availableModels) { model in
                            Text(model.name).tag(model.id)
                        }
                        if !workspace.availableModels.contains(where: { $0.id == workspace.selectedModel }) {
                            Text(workspace.selectedModel).tag(workspace.selectedModel)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(maxWidth: 200)
                    .disabled(workspace.isRunning || workspace.availableModels.isEmpty)
                }
                if !workspace.availableReasoningEfforts.isEmpty {
                    CompactSettingsDivider()
                    CodexReasoningSlider("Conversation reasoning effort", efforts: workspace.availableReasoningEfforts, selection: Binding(
                            get: { workspace.selectedReasoningEffort ?? workspace.availableModels.first { $0.id == workspace.selectedModel }?.defaultReasoningEffort ?? "" },
                            set: { workspace.selectReasoningEffort($0) }
                        ))
                    .disabled(workspace.isRunning)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: MarrUI.Spacing.regular) {
                if workspace.isLoadingModels {
                    Text("Loading models…").marrTextStyle(.secondary).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button { workspace.refreshModels() } label: {
                    Label("Refresh", marrSymbol: "arrow.clockwise")
                }
                    .controlSize(.small)
                    .disabled(workspace.isLoadingModels || workspace.isRunning)
            }
            if let error = workspace.modelLoadError {
                Text(error).marrTextStyle(.secondary).foregroundStyle(MarrUI.Status.error.color())
            }
        }
        .onAppear { workspace.refreshModelsIfNeeded() }
    }
}

struct CodexTranslationSettings: View {
    @ObservedObject var controller: MarrController
    @ObservedObject var workspace: RuntimeWorkspaceController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CompactSettingsRow("Model", systemImage: "square.stack") {
                Picker("Translation Codex model", selection: Binding(
                    get: { controller.translationCodexModel },
                    set: { model in
                        guard model != controller.translationCodexModel else { return }
                        controller.translationCodexModel = model
                        controller.translationCodexReasoningEffort = ""
                    }
                )) {
                    Text("Same as conversation").tag("")
                    ForEach(workspace.availableModels) { model in
                        Text(model.name).tag(model.id)
                    }
                    if hasUnavailableSavedModel {
                        Text("\(controller.translationCodexModel) (Unavailable)")
                            .tag(controller.translationCodexModel)
                            .disabled(true)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: 200)
                .disabled(workspace.availableModels.isEmpty)
                .accessibilityLabel("Translation Codex model")
            }

            CompactSettingsDivider()

            CodexReasoningSlider("Translation reasoning effort", efforts: reasoningEfforts,
                                 includesAutomatic: true, selection: $controller.translationCodexReasoningEffort)
                .disabled(effectiveModel == nil)

            Text(controller.translationCodexModel.isEmpty
                 ? "Automatic follows the conversation’s reasoning."
                 : "Automatic uses the model’s default reasoning.")
                .marrTextStyle(.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
                .padding(.bottom, 12)

            HStack(spacing: MarrUI.Spacing.regular) {
                if workspace.isLoadingModels {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Loading Codex models")
                    Text("Loading models…")
                        .marrTextStyle(.secondary)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { workspace.refreshModels() } label: {
                    Label("Refresh models", marrSymbol: "arrow.clockwise")
                }
                    .controlSize(.small)
                    .disabled(workspace.isLoadingModels || workspace.isRunning)
            }

            if let error = workspace.modelLoadError {
                validationMessage(error)
            } else if workspace.availableModels.isEmpty && !workspace.isLoadingModels {
                validationMessage("No Codex models are available. Refresh models to try again.")
            }

            if !workspace.availableModels.isEmpty && !workspace.isLoadingModels {
                if hasUnavailableSavedModel {
                    validationMessage("The saved translation model is unavailable. Choose another model or Same as conversation.")
                } else if hasUnavailableSavedEffort {
                    validationMessage("The saved reasoning effort is unavailable for this model. Choose Automatic or a supported effort.")
                }
            }
        }
        .onAppear { workspace.refreshModelsIfNeeded() }
    }

    private var effectiveModel: CodexModelOption? {
        let modelID = controller.translationCodexModel.isEmpty
            ? workspace.selectedModel : controller.translationCodexModel
        return workspace.availableModels.first { $0.id == modelID }
    }

    private var hasUnavailableSavedModel: Bool {
        !controller.translationCodexModel.isEmpty
            && !workspace.availableModels.contains { $0.id == controller.translationCodexModel }
    }

    private var hasUnavailableSavedEffort: Bool {
        !controller.translationCodexReasoningEffort.isEmpty
            && !reasoningEfforts.contains(controller.translationCodexReasoningEffort)
    }

    private var reasoningEfforts: [String] {
        let order = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
        return (effectiveModel?.reasoningEfforts ?? []).sorted {
            (order.firstIndex(of: $0) ?? order.count) < (order.firstIndex(of: $1) ?? order.count)
        }
    }

    private func validationMessage(_ message: String) -> some View {
        Label(message, marrSymbol: "exclamationmark.circle")
            .marrTextStyle(.secondary)
            .foregroundStyle(MarrUI.Status.error.color())
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct CodexReasoningSlider: View {
    let title: String
    let efforts: [String]
    let includesAutomatic: Bool
    @Binding var selection: String

    init(_ title: String, efforts: [String], includesAutomatic: Bool = false, selection: Binding<String>) {
        self.title = title
        self.efforts = efforts
        self.includesAutomatic = includesAutomatic
        self._selection = selection
    }

    private var options: [String] {
        let order = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
        return (includesAutomatic ? [""] : []) + Set(efforts.filter { !$0.isEmpty }).sorted {
            let lhs = order.firstIndex(of: $0) ?? order.count
            let rhs = order.firstIndex(of: $1) ?? order.count
            return lhs == rhs ? $0 < $1 : lhs < rhs
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
            HStack {
                Text("Reasoning")
                Spacer()
                Text(label(selection) + (options.contains(selection) ? "" : " (Unavailable)"))
                    .foregroundStyle(.secondary)
            }
            if options.count > 1 {
                MarrReasoningTickSlider(options: options, selection: selection,
                                        onSelect: { selection = $0 }, accessibilityTitle: title)
                    .frame(height: MarrUI.Control.compact)
                HStack {
                    Text(label(options[0]))
                    Spacer()
                    Text(label(options[options.count - 1]))
                }
                .marrTextStyle(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 12)
    }

    private func label(_ value: String) -> String { value.isEmpty ? "Automatic" : value.capitalized }
}

struct MarrChatGPTModelSettings: View {
    let models: [ChatGPTModel]
    @Binding var model: String
    @Binding var reasoning: String
    @Binding var fastMode: Bool
    var showsReasoning = true
    var isBusy = false
    var isLoading = false
    var error: String? = nil
    var onRetry: () -> Void = {}

    private var selectedModel: ChatGPTModel? { models.first { $0.slug == model } }

    var body: some View {
        CompactSettingsGroup(showsReasoning ? "Model & response" : "Translation model") {
            if showsReasoning, let selectedModel {
                MarrModelConfigurationPanel(models: models.map { CodexModelOption(id: $0.slug, name: $0.displayName) },
                    selectedModel: model, efforts: selectedModel.reasoningEfforts, effort: reasoning,
                    fastMode: fastMode, supportsFastMode: selectedModel.supportsFastMode, isEnabled: !isBusy,
                    onSelectModel: { model = $0 }, onSelectEffort: { reasoning = $0 },
                    onToggleSpeed: { fastMode.toggle() })
                    .marrSurface(.input, cornerRadius: MarrUI.Radius.panel)
            } else if isLoading && models.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading models…").marrTextStyle(.secondary).foregroundStyle(.secondary)
                }.padding(.vertical, 12)
            } else {
                CompactSettingsRow("Model", systemImage: "square.stack") {
                    Picker("Model", selection: $model) {
                        Text("Choose a model").tag("")
                        ForEach(models) { Text($0.displayName).tag($0.slug) }
                    }
                    .pickerStyle(.menu).labelsHidden().controlSize(.small)
                    .frame(width: 168, alignment: .trailing)
                    .disabled(isBusy || models.isEmpty)
                }
            }
            if let error {
                VStack(alignment: .leading, spacing: 6) {
                    Text(error).marrTextStyle(.secondary).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Retry", action: onRetry).buttonStyle(.link).disabled(isLoading || isBusy)
                }.padding(.top, 8)
            }
        }
    }
}
