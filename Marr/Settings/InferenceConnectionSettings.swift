import AppKit
import MarrCore
import MarrNetworking
import MarrSettings
import SwiftUI

/// Connections are edited independently of the model selected for each feature.
struct CompactProviderSettingsPanel: View {
    @ObservedObject var controller: MarrController
    let page: MarrSettingsSection
    let openAccount: () -> Void
    var refreshAccountsOnAppear = true
    var isOnboarding = false
    @State private var editingConnection: AIConnectionProfile?
    @State private var translationTestRunning = false
    @State private var translationTestFeedback = ""

    var body: some View {
        VStack(alignment: .leading, spacing: MarrSettingsLayout.sectionSpacing) {
            if isOnboarding, let connection = editingConnection {
                AIConnectionEditor(controller: controller, connection: connection, isEmbedded: true,
                                   onDone: { editingConnection = nil })
                    .id(connection.id)
            } else if page == .translation {
                AIModelAssignment(controller: controller, translation: true)
                Text("Connections and credentials are managed in AI & Models.")
                    .marrTextStyle(.secondary).foregroundStyle(.secondary)
                Button("Manage AI connections", action: openAccount)
                Button(translationTestRunning ? "Testing translation…" : "Test translation") {
                    translationTestRunning = true
                    translationTestFeedback = ""
                    Task { @MainActor in
                        defer { translationTestRunning = false }
                        do { translationTestFeedback = try await controller.testTranslationConnection() }
                        catch { translationTestFeedback = controller.userFacingMessage(for: error) }
                    }
                }.disabled(translationTestRunning || !controller.canSelectProvider)
                if !translationTestFeedback.isEmpty {
                    Text(translationTestFeedback).marrTextStyle(.secondary).textSelection(.enabled)
                }
                if controller.usesCodexForConversation, controller.aiConnections.translation == nil {
                    CodexTranslationSettings(controller: controller, workspace: controller.codexWorkspace)
                }
            } else {
                connections
                CompactSettingsDivider()
                AIModelAssignment(controller: controller, isOnboarding: isOnboarding)
                if isOnboarding {
                    DisclosureGroup("Translation model") {
                        AIModelAssignment(controller: controller, translation: true).padding(.top, 12)
                    }
                } else {
                    AIModelAssignment(controller: controller, translation: true)
                }
                if !isOnboarding {
                    if controller.usesCodexForConversation {
                        CodexConversationSettings(workspace: controller.codexWorkspace)
                    } else if controller.provider == .chatGPT {
                        chatGPTResponseOptions
                    }
                    DisclosureGroup("Response limits") {
                        CompactSettingsRow("Conversation output limit", systemImage: "text.word.spacing") {
                            Stepper(controller.maximumOutputTokens.formatted(), value: $controller.maximumOutputTokens,
                                    in: 256...32_768, step: 256).controlSize(.small)
                        }
                        CompactSettingsRow("Translation output limit", systemImage: "text.word.spacing") {
                            Stepper(controller.translationMaximumOutputTokens.formatted(), value: $controller.translationMaximumOutputTokens,
                                    in: 256...32_768, step: 256).controlSize(.small)
                        }
                    }
                }
            }
        }
        .sheet(item: Binding(get: { isOnboarding ? nil : editingConnection }, set: { editingConnection = $0 })) { connection in
            AIConnectionEditor(controller: controller, connection: connection)
        }
        .onAppear { if refreshAccountsOnAppear { controller.refreshChatGPTAccount() } }
    }

    private var chatGPTResponseOptions: some View {
        CompactSettingsGroup("Response options") {
            if let selected = controller.selectedChatGPTModel {
                MarrModelConfigurationPanel(models: [], selectedModel: controller.model,
                    efforts: selected.reasoningEfforts, effort: controller.chatGPTReasoningEffort,
                    fastMode: controller.chatGPTFastMode, supportsFastMode: selected.supportsFastMode,
                    isEnabled: controller.canSelectProvider, offersModelSelection: false,
                    onSelectModel: { _ in }, onSelectEffort: { controller.chatGPTReasoningEffort = $0 },
                    onToggleSpeed: { controller.chatGPTFastMode.toggle() })
            }
            if controller.chatGPTModelsLoading { ProgressView().controlSize(.small) }
            if let error = controller.chatGPTModelError {
                Text(error).marrTextStyle(.secondary).foregroundStyle(MarrUI.Status.error.color())
                Button("Retry") { controller.refreshChatGPTAccount(forceRefresh: true) }
                    .disabled(controller.chatGPTBusy || controller.chatGPTModelsLoading)
            }
        }
    }

    private var connections: some View {
        CompactSettingsGroup(isOnboarding ? "1 · Connect a service" : "My connections") {
            if !isOnboarding {
                Text("Connect a service here, then choose where to use its models below.")
                    .marrTextStyle(.secondary).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.bottom, 12)
            }
            ForEach(controller.aiConnections.connections) { connection in
                HStack(spacing: 12) {
                    ProviderBrandIcon(name: connection.iconName, size: 24)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(connection.name).marrTextStyle(.body, weight: .medium)
                        Text(connectionDetail(connection)).marrTextStyle(.secondary).foregroundStyle(.secondary)
                            .lineLimit(2).truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    Button(isOnboarding ? "Configure" : "Manage") { editingConnection = connection }
                        .controlSize(.small).accessibilityLabel("Manage " + connection.name)
                }.padding(.vertical, 12)
                CompactSettingsDivider()
            }
            HStack {
                Menu {
                    Button("ChatGPT account…") { controller.signInWithChatGPT(newAccount: true) }
                    Divider()
                    Button("OpenAI API") {
                        add(.init(name: "OpenAI API", baseURL: "https://api.openai.com/v1", apiFormat: .openAIResponses))
                    }
                    ForEach(GatewayPreset.allCases) { preset in
                        Button(preset.title) {
                            add(.init(name: preset.title, preset: preset, baseURL: preset.baseURL,
                                      apiFormat: preset.apiFormat, authScheme: preset.authScheme))
                        }
                    }
                    Divider()
                    Button("DeepLX · Translation only") {
                        add(.init(name: "DeepLX", kind: .deepLX, baseURL: "http://localhost:1188", authScheme: .none))
                    }
                } label: { Label("Add connection", systemImage: "plus") }
                .fixedSize().disabled(!controller.canSelectProvider || controller.chatGPTBusy)
                Spacer()
                if controller.chatGPTBusy {
                    ProgressView().controlSize(.small)
                    Button("Cancel sign-in") { controller.cancelChatGPTSignIn() }.controlSize(.small)
                }
            }.padding(.top, 12)
            if !controller.chatGPTStatus.isEmpty {
                Text(controller.chatGPTStatus).marrTextStyle(.secondary).padding(.top, 8)
            }
        }
    }

    private func add(_ connection: AIConnectionProfile) {
        controller.saveAIConnection(connection)
        editingConnection = connection
    }

    private func connectionDetail(_ connection: AIConnectionProfile) -> String {
        if connection.kind == .chatGPT {
            guard let profile = controller.chatGPTProfiles.first(where: { $0.id == connection.chatGPTProfileID }) else {
                return "Sign in to connect"
            }
            return profile.isSignedIn ? (profile.canUsePlan ? "Signed in · ChatGPT plan" : "Plan access not enabled") : "Signed out"
        }
        if connection.kind == .deepLX { return "Translation only · " + connection.baseURL }
        let modelCount = connection.models.count
        return "\(modelCount) saved model\(modelCount == 1 ? "" : "s") · \(connection.baseURL.isEmpty ? "Setup required" : connection.baseURL)"
    }
}

struct AIModelAssignment: View {
    @ObservedObject var controller: MarrController
    var translation = false
    var isOnboarding = false

    private var reference: AIModelReference? {
        translation ? controller.aiConnections.translation : controller.aiConnections.conversation
    }
    private var selectionID: String {
        if translation && reference == nil { return "follow" }
        if !translation && controller.usesCodexForConversation { return "codex" }
        return reference?.connectionID ?? ""
    }
    private var selectedConnection: AIConnectionProfile? { reference.flatMap { controller.aiConnections.connection($0.connectionID) } }

    var body: some View {
        CompactSettingsGroup(translation ? "Screenshot translation" : isOnboarding ? "2 · Choose a model" : "Default conversation") {
            CompactSettingsRow("Connection", systemImage: "network") {
                Picker(translation ? "Translation connection" : "Default conversation connection", selection: Binding(
                    get: { selectionID }, set: selectConnection)) {
                    if translation { Text("Follow conversation").tag("follow") }
                    ForEach(controller.aiConnections.connections.filter { translation || $0.supportsConversation }) {
                        Text($0.name).tag($0.id)
                    }
                    if !translation && controller.supportsRuntimeConversation {
                        Text("Codex · Work integration").tag("codex")
                    }
                }.labelsHidden().frame(maxWidth: 260).disabled(!controller.canSelectProvider)
            }
            if selectionID != "follow", selectionID != "codex", let connection = selectedConnection,
               connection.kind != .deepLX {
                CompactSettingsRow("Model", systemImage: "square.stack") {
                    Picker(translation ? "Translation model" : "Default conversation model", selection: Binding(
                        get: { reference?.modelID ?? "" }, set: { model in
                            controller.chooseAIModel(connectionID: connection.id, modelID: model, translation: translation)
                        })) {
                        Text("Choose a model").tag("")
                        ForEach(connection.models, id: \.self) { Text($0).tag($0) }
                        if let saved = reference?.modelID, !saved.isEmpty, !connection.models.contains(saved) {
                            Text(saved + " · Saved selection").tag(saved)
                        }
                    }.labelsHidden().frame(maxWidth: 260)
                        .disabled(!controller.canSelectProvider || connection.models.isEmpty)
                }
                if connection.models.isEmpty {
                    Text("Manage this connection to add model IDs or refresh its models.")
                        .marrTextStyle(.secondary).foregroundStyle(.secondary)
                }
            }
            if selectionID == "follow" {
                Text("Uses the conversation connection and model. Credentials stay shared.")
                    .marrTextStyle(.secondary).foregroundStyle(.secondary).padding(.top, 4)
            }
        }
    }

    private func selectConnection(_ id: String) {
        if id == "follow" { controller.followConversationForTranslation(); return }
        if id == "codex" { controller.selectProvider("codex"); return }
        guard let connection = controller.aiConnections.connection(id) else { return }
        controller.chooseAIModel(connectionID: id, modelID: connection.models.first ?? "", translation: translation)
    }
}

struct AIConnectionEditor: View {
    @ObservedObject var controller: MarrController
    @Environment(\.dismiss) private var dismiss
    @State var connection: AIConnectionProfile
    var isEmbedded = false
    var onDone: (() -> Void)? = nil
    @State private var modelIDs = ""
    @State private var feedback = ""
    @State private var testing = false
    @State private var confirmRemoval = false

    private var saved: AIConnectionProfile? { controller.aiConnections.connection(connection.id) }
    private var hasChanges: Bool { connection.name != saved?.name || connection.baseURL != saved?.baseURL || connection.apiFormat != saved?.apiFormat || connection.authScheme != saved?.authScheme || (connection.kind != .chatGPT && parsedModels != saved?.models) }
    private var parsedModels: [String] {
        var seen = Set<String>()
        return modelIDs.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
    private var valid: Bool {
        guard !connection.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if connection.kind == .chatGPT { return true }
        guard let url = URLComponents(string: connection.baseURL),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false else { return false }
        return true
    }
    private var isUsed: Bool {
        controller.aiConnections.conversation.connectionID == connection.id || controller.aiConnections.translation?.connectionID == connection.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(isEmbedded ? connection.name : "Manage connection").marrTextStyle(.pageTitle)
                Spacer()
                Button(isEmbedded ? "Back to connections" : "Done", action: finishEditing)
                    .keyboardShortcut(.cancelAction)
            }
            if isEmbedded { editorContent }
            else { ScrollView { editorContent } }
        }
        .padding(isEmbedded ? 0 : 24)
        .frame(width: isEmbedded ? nil : 520, height: isEmbedded ? nil : 620)
        .onAppear { modelIDs = connection.models.joined(separator: "\n") }
        .confirmationDialog("Remove this connection?", isPresented: $confirmRemoval) {
            Button("Remove connection", role: .destructive) {
                controller.removeAIConnection(connection.id); finishEditing()
            }
        } message: { Text("Saved credentials remain in Keychain. This does not sign out of the service.") }
    }

    private func finishEditing() {
        if let onDone { onDone() } else { dismiss() }
    }

    private var editorContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            TextField("Connection name", text: $connection.name).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Connection name")
            if connection.kind == .chatGPT { accountControls }
            else { apiControls }
            HStack {
                Button("Save connection") { save() }.disabled(!valid || !hasChanges || !controller.canSelectProvider)
                if connection.kind != .chatGPT {
                    Button(testing ? "Testing…" : "Test connection") { test() }
                        .disabled(hasChanges || !valid || testing || !controller.canSelectProvider)
                }
                Spacer()
            }
            if !valid {
                Text("Enter a name and a valid http:// or https:// server address.")
                    .foregroundStyle(MarrUI.Status.error.color()).marrTextStyle(.secondary)
            }
            if !feedback.isEmpty { Text(feedback).marrTextStyle(.secondary).textSelection(.enabled) }
            if connection.kind != .chatGPT {
                credentials.disabled(hasChanges || testing)
                if hasChanges {
                    Text("Save connection changes before updating credentials or testing.")
                        .marrTextStyle(.secondary).foregroundStyle(.secondary)
                }
                CompactSettingsDivider()
                Button("Remove connection", role: .destructive) { confirmRemoval = true }
                    .disabled(isUsed || !controller.canSelectProvider)
                if isUsed {
                    Text("Choose another default before removing this connection.")
                        .marrTextStyle(.secondary).foregroundStyle(.secondary)
                }
            }
        }.padding(.vertical, 4)
    }

    private var apiControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Server address").marrTextStyle(.body, weight: .medium)
            TextField("https://api.example.com/v1", text: $connection.baseURL).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Server address")
            if connection.kind != .deepLX {
                Text("Available models").marrTextStyle(.body, weight: .medium)
                Text("Enter one model ID per line. Use IDs available to this connection.")
                    .marrTextStyle(.secondary).foregroundStyle(.secondary)
                TextEditor(text: $modelIDs).font(.system(.body, design: .monospaced))
                    .frame(height: 100).border(Color.secondary.opacity(0.25)).accessibilityLabel("Model IDs, one per line")
                if let preset = connection.preset, !preset.models.isEmpty {
                    Menu("Add model example") {
                        ForEach(preset.models, id: \.self) { model in
                            Button(model) { modelIDs += (modelIDs.isEmpty ? "" : "\n") + model }
                        }
                    }.fixedSize()
                    Text("Examples are suggestions; verify availability with your service.")
                        .marrTextStyle(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("Advanced connection options") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("API protocol", selection: $connection.apiFormat) {
                            ForEach(GatewayAPIFormat.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Picker("Authentication", selection: $connection.authScheme) {
                            Text("Bearer token").tag(GatewayAuthScheme.bearer)
                            Text("x-api-key").tag(GatewayAuthScheme.xAPIKey)
                            Text("None").tag(GatewayAuthScheme.none)
                        }
                    }.padding(.top, 8)
                }
            }
        }
    }

    private var credentials: some View {
        VStack(alignment: .leading, spacing: 12) {
            if connection.authScheme != .none || connection.kind == .deepLX {
                CompactSettingsGroup(connection.kind == .deepLX ? "Access token · Optional" : "API key") {
                    CompactCredentialEditor(controller: controller, credential: connection.keyCredential)
                        .id(connection.keyCredential)
                }
            }
            if connection.kind == .api {
                DisclosureGroup("Custom request headers") {
                    CompactHeadersCredentialEditor(controller: controller, credential: connection.headersCredential)
                        .id(connection.headersCredential)
                }
            }
        }
    }

    private var accountControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ChatGPT account").marrTextStyle(.body, weight: .medium)
            if let profile = controller.chatGPTProfiles.first(where: { $0.id == connection.chatGPTProfileID }) {
                Text(profile.email ?? profile.label).textSelection(.enabled)
                Text(profile.isSignedIn ? (profile.canUsePlan ? "Plan access enabled" : "Plan access not enabled") : "Signed out")
                    .marrTextStyle(.secondary).foregroundStyle(.secondary)
                if profile.isSignedIn && !profile.canUsePlan {
                    Button("Enable plan access") { controller.reconnectChatGPTProfile(profile.id, requestConsent: true) }
                        .disabled(controller.chatGPTBusy || !controller.canSelectProvider)
                }
                HStack {
                    Button(profile.isSignedIn ? "Reconnect" : "Sign in") { controller.reconnectChatGPTProfile(profile.id) }
                    Button("Refresh models") { controller.refreshAIModels(connection.id) }
                    if profile.isSignedIn {
                        Button("Sign out", role: .destructive) { controller.signOutOfChatGPT(profileID: profile.id) }
                    }
                }.disabled(controller.chatGPTBusy || !controller.canSelectProvider)
                Link("Manage plan usage", destination: URL(string: "https://chatgpt.com/settings/usage")!)
                Text("Signing in does not change the default conversation connection.")
                    .marrTextStyle(.secondary).foregroundStyle(.secondary)
            } else {
                Button("Sign in with ChatGPT") { controller.signInWithChatGPT() }
            }
            if controller.chatGPTBusy { ProgressView().controlSize(.small) }
            if !controller.chatGPTStatus.isEmpty { Text(controller.chatGPTStatus).marrTextStyle(.secondary) }
            if let error = controller.chatGPTModelError { Text(error).foregroundStyle(MarrUI.Status.error.color()) }
        }
    }

    private func save() {
        connection.name = connection.name.trimmingCharacters(in: .whitespacesAndNewlines)
        connection.baseURL = connection.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if connection.kind != .chatGPT { connection.models = parsedModels }
        else { connection.models = saved?.models ?? connection.models }
        controller.saveAIConnection(connection)
        feedback = "Connection saved."
    }
    private func test() {
        testing = true; feedback = ""
        Task { @MainActor in
            defer { testing = false }
            do { _ = try await controller.testAIConnection(connection.id); feedback = "Connection verified." }
            catch { feedback = controller.userFacingMessage(for: error) }
        }
    }
}

struct ProviderBrandIcon: View {
    let name: String?
    var size: CGFloat = 20
    var body: some View {
        Group {
            if let name { Image("Provider-" + name).resizable().scaledToFit() }
            else { Image(systemName: "network").resizable().scaledToFit() }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}
