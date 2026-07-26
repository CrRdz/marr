import AppKit
import Carbon
import MarrCore
import MarrSettings
import SwiftUI

struct SettingsView: View {
    @ObservedObject var controller: MarrController
    @State private var selection: SettingsSection = .general
    @AppStorage(MarrAccentColor.storageKey) private var accentColor = MarrAccentColor.system.rawValue

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationTitle("Settings")
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            selectedDetail
                .navigationTitle(selection.title)
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 520, idealHeight: 580)
        .tint(selectedAccentColor)
        .accentColor(selectedAccentColor)
    }

    @ViewBuilder
    private var selectedDetail: some View {
        switch selection {
        case .history:
            HistoryView(controller: controller)
        default:
            Form {
                selectedPanel
            }
            .formStyle(.grouped)
        }
    }

    @ViewBuilder
    private var selectedPanel: some View {
        switch selection {
        case .general:
            GeneralSettingsPanel(controller: controller)
        case .provider:
            ProviderSettingsPanel(controller: controller)
        case .appearance:
            AppearanceSettingsPanel()
        case .history:
            EmptyView()
        }
    }

    private var selectedAccentColor: Color {
        selectedAccent.color
    }

    private var selectedAccent: MarrAccentColor {
        MarrAccentColor.resolve(accentColor)
    }
}

struct AnswerPanelSettingsView: View {
    @ObservedObject var controller: MarrController
    @State private var selection = AnswerPanelSettingsSection.general
    @AppStorage(MarrAccentColor.storageKey) private var accentColor = MarrAccentColor.system.rawValue

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(AnswerPanelSettingsSection.allCases) { section in
                    Button {
                        withAnimation(.easeOut(duration: 0.16)) {
                            selection = section
                        }
                    } label: {
                        VStack(spacing: 5) {
                            Label(section.title, systemImage: section.systemImage)
                                .font(MarrTypography.body(size: 12.5, weight: .semibold))
                                .frame(maxWidth: .infinity)

                            Capsule()
                                .fill(selection == section ? selectedAccent.color : .clear)
                                .frame(height: 2)
                        }
                        .foregroundStyle(selection == section ? selectedAccent.color : .secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection == section ? .isSelected : [])
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 2)

            Divider()
                .opacity(0.45)

            ScrollView {
                selectedPanel
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
            }
            .scrollIndicators(.automatic)
        }
        .tint(selectedAccent.color)
    }

    @ViewBuilder
    private var selectedPanel: some View {
        switch selection {
        case .general:
            CompactGeneralSettingsPanel(controller: controller)
        case .provider:
            CompactProviderSettingsPanel(controller: controller)
        case .appearance:
            CompactAppearanceSettingsPanel()
        }
    }

    private var selectedAccent: MarrAccentColor {
        MarrAccentColor.resolve(accentColor)
    }
}

private enum AnswerPanelSettingsSection: String, CaseIterable, Identifiable {
    case general
    case provider
    case appearance

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .provider: "AI"
        case .appearance: "Style"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .provider: "sparkles"
        case .appearance: "paintpalette"
        }
    }
}

private struct CompactGeneralSettingsPanel: View {
    @ObservedObject var controller: MarrController
    @State private var runningApplications = RunningApplicationOption.currentOptions
    @AppStorage(MarrHotKeyConfiguration.keyCodeKey) private var keyCode = Int(kVK_ANSI_0)
    @AppStorage(MarrHotKeyConfiguration.modifiersKey) private var modifiers = Int(cmdKey | shiftKey)
    @AppStorage(MarrWindowCaptureHotKeyConfiguration.keyCodeKey) private var windowKeyCode = Int(kVK_ANSI_9)
    @AppStorage(MarrWindowCaptureHotKeyConfiguration.modifiersKey) private var windowModifiers = Int(cmdKey | shiftKey)
    @AppStorage(MarrHotKeyConfiguration.scopeKey) private var scope = MarrHotKeyScope.global.rawValue
    @AppStorage(MarrHotKeyConfiguration.scopeBundleIDKey) private var scopeBundleID = ""
    @AppStorage(MarrHotKeyConfiguration.scopeAppNameKey) private var scopeAppName = ""

    var body: some View {
        VStack(spacing: 18) {
            CompactSettingsGroup("Shortcuts") {
                CompactSettingsRow("Area", systemImage: "viewfinder") {
                    HotKeyRecorder(
                        keyCode: $keyCode,
                        modifiers: $modifiers,
                        onChange: saveShortcut
                    )
                    .frame(width: 126, height: 28)
                }

                CompactSettingsDivider()

                CompactSettingsRow("Window", systemImage: "macwindow") {
                    HotKeyRecorder(
                        keyCode: $windowKeyCode,
                        modifiers: $windowModifiers,
                        onChange: saveWindowShortcut
                    )
                    .frame(width: 126, height: 28)
                }
            }

            CompactSettingsGroup("Availability") {
                CompactSettingsRow("Use in", systemImage: "scope") {
                    Picker("", selection: scopeBinding) {
                        ForEach(MarrHotKeyScope.allCases) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 154)
                }

                if MarrHotKeyScope(rawValue: scope) == .frontmostApplication {
                    CompactSettingsDivider()

                    CompactSettingsRow("App", systemImage: "app") {
                        Picker("", selection: applicationBinding) {
                            ForEach(runningApplications) { app in
                                Text(app.name).tag(app.bundleID)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(width: 174)
                    }
                    .onAppear(perform: refreshRunningApplications)
                }
            }

            CompactSettingsGroup("Marr") {
                Button {
                    openMarrWelcomeGuide(controller: controller)
                } label: {
                    Label("Welcome Guide", systemImage: "graduationcap")
                        .font(MarrTypography.body(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                CompactSettingsDivider()

                Button {
                    NSApp.terminate(nil)
                } label: {
                    Label("Quit", systemImage: "power")
                        .font(MarrTypography.body(size: 13, weight: .medium))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var scopeBinding: Binding<String> {
        Binding(
            get: { scope },
            set: { nextValue in
                scope = nextValue
                if MarrHotKeyScope(rawValue: nextValue) == .frontmostApplication, scopeBundleID.isEmpty {
                    refreshRunningApplications()
                    if let first = runningApplications.first {
                        scopeBundleID = first.bundleID
                        scopeAppName = first.name
                    }
                }
                saveShortcut()
            }
        )
    }

    private var applicationBinding: Binding<String> {
        Binding(
            get: { scopeBundleID },
            set: { nextValue in
                scopeBundleID = nextValue
                scopeAppName = runningApplications.first { $0.bundleID == nextValue }?.name ?? nextValue
                saveShortcut()
            }
        )
    }

    private func refreshRunningApplications() {
        runningApplications = RunningApplicationOption.currentOptions
    }

    private func saveShortcut() {
        MarrHotKeyConfiguration(
            keyCode: UInt32(keyCode),
            modifiers: UInt32(modifiers),
            scope: MarrHotKeyScope(rawValue: scope) ?? .global,
            scopeBundleID: scopeBundleID,
            scopeAppName: scopeAppName
        ).save()
        controller.reloadHotKey()
    }

    private func saveWindowShortcut() {
        MarrWindowCaptureHotKeyConfiguration(
            keyCode: UInt32(windowKeyCode),
            modifiers: UInt32(windowModifiers)
        ).save()
        controller.reloadHotKey()
    }
}

private struct CompactProviderSettingsPanel: View {
    @ObservedObject var controller: MarrController
    @AppStorage("gateway.preset") private var gatewayPreset = GatewayPreset.custom.rawValue

    var body: some View {
        VStack(spacing: 18) {
            CompactSettingsGroup("Model") {
                CompactSettingsRow("Provider", systemImage: "cpu") {
                    Picker("", selection: $controller.provider) {
                        ForEach(InferenceProvider.allCases) { provider in
                            Text(provider.rawValue).tag(provider)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 154)
                }

                CompactSettingsDivider()

                CompactSettingsRow("Model", systemImage: "textformat") {
                    TextField("Model", text: $controller.model)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 8)
                        .frame(width: 184, height: 28)
                        .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
                }

                CompactSettingsDivider()

                CompactSettingsRow("Max tokens", systemImage: "text.word.spacing") {
                    Stepper(
                        controller.maximumOutputTokens.formatted(),
                        value: $controller.maximumOutputTokens,
                        in: 256...32_768,
                        step: 256
                    )
                    .font(MarrTypography.mono(size: 12))
                    .controlSize(.small)
                    .frame(width: 146)
                }
            }

            if controller.provider == .openAI {
                CompactSettingsGroup("OpenAI Key") {
                    CompactCredentialEditor(
                        controller: controller,
                        credential: .openAIAPIKey
                    )
                }
            } else {
                CompactSettingsGroup("Gateway") {
                    CompactSettingsRow("Preset", systemImage: "switch.2") {
                        Picker("", selection: gatewayPresetBinding) {
                            ForEach(GatewayPreset.allCases) { preset in
                                Text(preset.title).tag(preset.rawValue)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(width: 154)
                    }

                    CompactSettingsDivider()

                    CompactSettingsRow("URL", systemImage: "link") {
                        TextField("Base URL", text: $controller.gatewayBaseURL)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 8)
                            .frame(width: 210, height: 28)
                            .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
                    }

                    CompactSettingsDivider()

                    CompactSettingsRow("Format", systemImage: "curlybraces") {
                        Picker("", selection: $controller.gatewayAPIFormat) {
                            ForEach(GatewayAPIFormat.allCases) { format in
                                Text(format.rawValue).tag(format)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(width: 174)
                    }

                    CompactSettingsDivider()

                    CompactSettingsRow("Auth", systemImage: "lock") {
                        Picker("", selection: $controller.gatewayAuthScheme) {
                            ForEach(GatewayAuthScheme.allCases) { scheme in
                                Text(scheme.rawValue).tag(scheme)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(width: 154)
                    }
                }

                if controller.gatewayAuthScheme != .none {
                    CompactSettingsGroup("Gateway Key") {
                        CompactCredentialEditor(
                            controller: controller,
                            credential: .gatewayAPIKey
                        )
                    }
                }

                CompactSettingsGroup("Headers") {
                    CompactHeadersCredentialEditor(controller: controller)
                }
            }
        }
    }

    private var gatewayPresetBinding: Binding<String> {
        Binding(
            get: { gatewayPreset },
            set: { nextValue in
                gatewayPreset = nextValue
                if GatewayPreset(rawValue: nextValue) == .ccSwitch {
                    controller.useCCSwitchClaudeDesktopPreset()
                }
            }
        )
    }
}

private struct CompactAppearanceSettingsPanel: View {
    @AppStorage(MarrAppearanceKeys.colorScheme) private var colorScheme = "System"
    @AppStorage(MarrAppearanceKeys.glassSurfaces) private var glassSurfaces = true
    @AppStorage(MarrBubbleColor.storageKey) private var bubbleColor = MarrBubbleColor.system.rawValue
    @AppStorage(MarrAccentColor.storageKey) private var accentColor = MarrAccentColor.system.rawValue

    var body: some View {
        VStack(spacing: 18) {
            CompactSettingsGroup("Interface") {
                CompactSettingsRow("Theme", systemImage: "circle.lefthalf.filled") {
                    Picker("", selection: $colorScheme) {
                        Text("System").tag("System")
                        Text("Light").tag("Light")
                        Text("Dark").tag("Dark")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 184)
                }

                CompactSettingsDivider()

                CompactSettingsRow("Glass", systemImage: "circle.hexagongrid") {
                    Toggle("", isOn: $glassSurfaces)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }

            CompactSettingsGroup("Colors") {
                CompactSettingsRow("Bubble", systemImage: "message") {
                    BubbleColorDropdown(selection: $bubbleColor)
                        .frame(width: 150)
                }

                CompactSettingsDivider()

                CompactSettingsRow("Accent", systemImage: "paintbrush") {
                    AccentColorDropdown(selection: $accentColor)
                        .frame(width: 150)
                }
            }
        }
    }
}

private struct CompactSettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(MarrTypography.body(size: 10.5, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.55)

            VStack(spacing: 0) {
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CompactSettingsRow<Control: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let control: () -> Control

    init(
        _ title: String,
        systemImage: String,
        @ViewBuilder control: @escaping () -> Control
    ) {
        self.title = title
        self.systemImage = systemImage
        self.control = control
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 17)

            Text(title)
                .font(MarrTypography.body(size: 13))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 8)

            control()
        }
        .frame(maxWidth: .infinity, minHeight: 38)
    }
}

private struct CompactSettingsDivider: View {
    var body: some View {
        Divider()
            .opacity(0.38)
            .padding(.leading, 26)
    }
}

private struct CompactCredentialEditor: View {
    @ObservedObject var controller: MarrController
    let credential: InferenceCredential
    @State private var draft = ""
    @State private var showsRemoveConfirmation = false

    private var state: InferenceCredentialState {
        controller.credentialState(for: credential)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                SecureField("API key", text: $draft)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 9)
                    .frame(height: 30)
                    .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
                    .onSubmit(save)

                if state.isConfigured == true {
                    Button {
                        showsRemoveConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(state.isBusy)
                    .help("Remove key")
                }

                Button(action: save) {
                    Group {
                        if state.isBusy {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "checkmark")
                        }
                    }
                    .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(trimmedDraft.isEmpty || state.isBusy)
                .help("Save and verify")
            }

            CompactCredentialStateLabel(state: state)

            if let message = state.message {
                Text(message)
                    .font(MarrTypography.body(size: 10.5))
                    .foregroundStyle(state.messageIsError ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 7)
        .task {
            await controller.refreshCredentialState(for: credential)
        }
        .confirmationDialog("Remove API key?", isPresented: $showsRemoveConfirmation) {
            Button("Remove", role: .destructive) {
                Task {
                    if await controller.removeCredential(credential) {
                        draft = ""
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        guard !trimmedDraft.isEmpty, !state.isBusy else { return }
        let value = draft
        Task {
            if await controller.saveAndVerifyCredential(value, for: credential) {
                draft = ""
            }
        }
    }
}

private struct CompactHeadersCredentialEditor: View {
    @ObservedObject var controller: MarrController
    @State private var draft = ""
    @State private var showsRemoveConfirmation = false

    private var state: InferenceCredentialState {
        controller.credentialState(for: .customHeaders)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            TextEditor(text: $draft)
                .font(MarrTypography.mono(size: 11.5))
                .frame(minHeight: 58)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
                .overlay(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("Header: value")
                            .font(MarrTypography.mono(size: 11.5))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }

            HStack(spacing: 8) {
                CompactCredentialStateLabel(state: state)

                Spacer()

                if state.isConfigured == true {
                    Button {
                        showsRemoveConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(state.isBusy)
                    .help("Remove headers")
                }

                Button("Save", action: save)
                    .controlSize(.small)
                    .disabled(trimmedDraft.isEmpty || state.isBusy)
            }

            if let message = state.message {
                Text(message)
                    .font(MarrTypography.body(size: 10.5))
                    .foregroundStyle(state.messageIsError ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 7)
        .task {
            await controller.refreshCredentialState(for: .customHeaders)
        }
        .confirmationDialog("Remove headers?", isPresented: $showsRemoveConfirmation) {
            Button("Remove", role: .destructive) {
                Task {
                    if await controller.removeCredential(.customHeaders) {
                        draft = ""
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        guard !trimmedDraft.isEmpty, !state.isBusy else { return }
        let value = draft
        Task {
            if await controller.saveAndVerifyCredential(value, for: .customHeaders) {
                draft = ""
            }
        }
    }
}

private struct CompactCredentialStateLabel: View {
    let state: InferenceCredentialState

    var body: some View {
        HStack(spacing: 5) {
            if state.activity == .checking {
                ProgressView()
                    .controlSize(.mini)
                Text("Checking")
            } else if state.isConfigured == true {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Saved")
            } else if state.isConfigured == false {
                Image(systemName: "circle")
                Text("Not set")
            } else {
                ProgressView()
                    .controlSize(.mini)
                Text("Checking")
            }
        }
        .font(MarrTypography.body(size: 10.5))
        .foregroundStyle(.secondary)
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case provider
    case appearance
    case history

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .provider: "AI Provider"
        case .appearance: "Appearance"
        case .history: "History"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .provider: "sparkles"
        case .appearance: "sun.max"
        case .history: "clock.arrow.circlepath"
        }
    }
}

private struct GeneralSettingsPanel: View {
    @ObservedObject var controller: MarrController
    @State private var runningApplications = RunningApplicationOption.currentOptions
    @AppStorage(MarrHotKeyConfiguration.keyCodeKey) private var keyCode = Int(kVK_ANSI_0)
    @AppStorage(MarrHotKeyConfiguration.modifiersKey) private var modifiers = Int(cmdKey | shiftKey)
    @AppStorage(MarrWindowCaptureHotKeyConfiguration.keyCodeKey) private var windowKeyCode = Int(kVK_ANSI_9)
    @AppStorage(MarrWindowCaptureHotKeyConfiguration.modifiersKey) private var windowModifiers = Int(cmdKey | shiftKey)
    @AppStorage(MarrHotKeyConfiguration.scopeKey) private var scope = MarrHotKeyScope.global.rawValue
    @AppStorage(MarrHotKeyConfiguration.scopeBundleIDKey) private var scopeBundleID = ""
    @AppStorage(MarrHotKeyConfiguration.scopeAppNameKey) private var scopeAppName = ""

    var body: some View {
        Section("Keyboard Shortcuts") {
            HStack {
                Text("Capture area")
                Spacer()
                HotKeyRecorder(
                    keyCode: $keyCode,
                    modifiers: $modifiers,
                    onChange: saveShortcut
                )
                .frame(width: 132, height: 30)
            }

            HStack {
                Text("Capture current window")
                Spacer()
                HotKeyRecorder(
                    keyCode: $windowKeyCode,
                    modifiers: $windowModifiers,
                    onChange: saveWindowShortcut
                )
                .frame(width: 132, height: 30)
            }
        }

        Section("Availability") {
            Picker("Use shortcuts", selection: scopeBinding) {
                ForEach(MarrHotKeyScope.allCases) { option in
                    Text(option.title).tag(option.rawValue)
                }
            }

            if MarrHotKeyScope(rawValue: scope) == .frontmostApplication {
                Picker("Application", selection: applicationBinding) {
                    ForEach(runningApplications) { app in
                        Text(app.name).tag(app.bundleID)
                    }
                }
                .onAppear {
                    refreshRunningApplications()
                }
            }
        }

        Section("Help") {
            Button {
                openMarrWelcomeGuide(controller: controller)
            } label: {
                Label("Open Welcome Guide", systemImage: "graduationcap")
            }
        }

        Section("Application") {
            Button("Quit Marr", role: .destructive) {
                NSApp.terminate(nil)
            }
        }
    }

    private var scopeBinding: Binding<String> {
        Binding(
            get: { scope },
            set: { nextValue in
                scope = nextValue
                if MarrHotKeyScope(rawValue: nextValue) == .frontmostApplication, scopeBundleID.isEmpty {
                    refreshRunningApplications()
                    if let first = runningApplications.first {
                        scopeBundleID = first.bundleID
                        scopeAppName = first.name
                    }
                }
                saveShortcut()
            }
        )
    }

    private var applicationBinding: Binding<String> {
        Binding(
            get: { scopeBundleID },
            set: { nextValue in
                scopeBundleID = nextValue
                scopeAppName = runningApplications.first { $0.bundleID == nextValue }?.name ?? nextValue
                saveShortcut()
            }
        )
    }

    private func refreshRunningApplications() {
        runningApplications = RunningApplicationOption.currentOptions
    }

    private func saveShortcut() {
        MarrHotKeyConfiguration(
            keyCode: UInt32(keyCode),
            modifiers: UInt32(modifiers),
            scope: MarrHotKeyScope(rawValue: scope) ?? .global,
            scopeBundleID: scopeBundleID,
            scopeAppName: scopeAppName
        ).save()
        controller.reloadHotKey()
    }

    private func saveWindowShortcut() {
        MarrWindowCaptureHotKeyConfiguration(
            keyCode: UInt32(windowKeyCode),
            modifiers: UInt32(windowModifiers)
        ).save()
        controller.reloadHotKey()
    }
}

@MainActor
func openMarrWelcomeGuide(controller: MarrController) {
    MarrOnboardingPresenter.shared.show(controller: controller)
}

private struct RunningApplicationOption: Identifiable, Hashable {
    let bundleID: String
    let name: String

    var id: String { bundleID }

    static var currentOptions: [RunningApplicationOption] {
        let options = NSWorkspace.shared.runningApplications.compactMap { app -> RunningApplicationOption? in
            guard
                app.activationPolicy == .regular,
                let bundleID = app.bundleIdentifier,
                !bundleID.isEmpty
            else {
                return nil
            }

            return RunningApplicationOption(
                bundleID: bundleID,
                name: app.localizedName ?? bundleID
            )
        }

        return Array(Dictionary(grouping: options, by: \.bundleID).compactMap { _, grouped in
            grouped.first
        })
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

private struct HotKeyRecorder: NSViewRepresentable {
    @Binding var keyCode: Int
    @Binding var modifiers: Int
    let onChange: () -> Void

    func makeNSView(context: Context) -> HotKeyRecorderView {
        let view = HotKeyRecorderView()
        view.onRecord = { keyCode, modifiers in
            self.keyCode = Int(keyCode)
            self.modifiers = Int(modifiers)
            onChange()
        }
        return view
    }

    func updateNSView(_ nsView: HotKeyRecorderView, context: Context) {
        nsView.displayString = HotKeyFormatter.displayString(
            keyCode: UInt32(keyCode),
            modifiers: UInt32(modifiers)
        )
    }
}

private final class HotKeyRecorderView: NSButton {
    var onRecord: ((UInt32, UInt32) -> Void)?
    var displayString = "" {
        didSet {
            if !isRecording {
                title = displayString
            }
        }
    }

    private var isRecording = false

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(beginRecording)
        focusRingType = .none
        title = displayString
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    @objc private func beginRecording() {
        isRecording = true
        title = "Press keys"
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        let carbonModifiers = HotKeyFormatter.carbonModifiers(from: event.modifierFlags)
        guard carbonModifiers != 0 else {
            NSSound.beep()
            return
        }

        isRecording = false
        onRecord?(UInt32(event.keyCode), carbonModifiers)
        window?.makeFirstResponder(nil)
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        title = displayString
        return super.resignFirstResponder()
    }
}

private struct ProviderSettingsPanel: View {
    @ObservedObject var controller: MarrController
    @AppStorage("gateway.preset") private var gatewayPreset = GatewayPreset.custom.rawValue

    var body: some View {
        Section("Provider") {
            Picker("Provider", selection: $controller.provider) {
                ForEach(InferenceProvider.allCases) { provider in
                    Text(provider.rawValue).tag(provider)
                }
            }
            .pickerStyle(.segmented)

            TextField("Model", text: $controller.model)

            Stepper(
                value: $controller.maximumOutputTokens,
                in: 256...32_768,
                step: 256
            ) {
                HStack {
                    Text("Maximum Output Tokens")
                    Spacer()
                    Text(controller.maximumOutputTokens.formatted())
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }

        if controller.provider == .openAI {
            Section("OpenAI Credentials") {
                APIKeyCredentialEditor(
                    controller: controller,
                    credential: .openAIAPIKey
                )
            }
        } else {
            gatewaySection

            if controller.gatewayAuthScheme != .none {
                Section("Gateway Credentials") {
                    APIKeyCredentialEditor(
                        controller: controller,
                        credential: .gatewayAPIKey
                    )
                }
            }

            Section("Custom Headers") {
                CustomHeadersCredentialEditor(controller: controller)
            }
        }
    }

    private var gatewaySection: some View {
        Section("Gateway") {
            Picker("Configuration", selection: gatewayPresetBinding) {
                ForEach(GatewayPreset.allCases) { preset in
                    Text(preset.title).tag(preset.rawValue)
                }
            }

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
        }
    }

    private var gatewayPresetBinding: Binding<String> {
        Binding(
            get: { gatewayPreset },
            set: { nextValue in
                gatewayPreset = nextValue
                if GatewayPreset(rawValue: nextValue) == .ccSwitch {
                    controller.useCCSwitchClaudeDesktopPreset()
                }
            }
        )
    }
}

private struct APIKeyCredentialEditor: View {
    @ObservedObject var controller: MarrController
    let credential: InferenceCredential
    @State private var draft = ""
    @State private var showsRemoveConfirmation = false

    private var state: InferenceCredentialState {
        controller.credentialState(for: credential)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SecureField(fieldPrompt, text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)

            credentialActions

            if let message = state.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(state.messageIsError ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task {
            await controller.refreshCredentialState(for: credential)
        }
        .confirmationDialog(
            "Remove the saved API Key?",
            isPresented: $showsRemoveConfirmation
        ) {
            Button("Remove API Key", role: .destructive) {
                Task {
                    if await controller.removeCredential(credential) {
                        draft = ""
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Marr will no longer be able to use this provider until another key is saved.")
        }
    }

    private var credentialActions: some View {
        HStack(spacing: 10) {
            CredentialStatusLabel(
                state: state,
                configuredText: "API Key saved securely",
                missingText: "No API Key saved"
            )

            Spacer(minLength: 12)

            if state.isConfigured == true {
                Button {
                    showsRemoveConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(state.isBusy)
                .help("Remove saved API Key")
                .accessibilityLabel("Remove saved API Key")
            }

            Button(action: save) {
                CredentialSaveButtonLabel(state: state)
            }
            .disabled(trimmedDraft.isEmpty || state.isBusy)
        }
    }

    private var fieldPrompt: String {
        state.isConfigured == true
            ? "Enter a new API Key to replace the saved key"
            : "Enter API Key"
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        guard !trimmedDraft.isEmpty, !state.isBusy else { return }
        let value = draft
        Task {
            if await controller.saveAndVerifyCredential(value, for: credential) {
                draft = ""
            }
        }
    }
}

private struct CustomHeadersCredentialEditor: View {
    @ObservedObject var controller: MarrController
    @State private var draft = ""
    @State private var showsRemoveConfirmation = false

    private var state: InferenceCredentialState {
        controller.credentialState(for: .customHeaders)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                if draft.isEmpty {
                    Text(fieldPrompt)
                        .font(MarrTypography.mono(size: 12))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $draft)
                    .font(MarrTypography.mono(size: 12))
                    .frame(minHeight: 88)
                    .scrollContentBackground(.hidden)
                    .padding(7)
            }
            .background(
                Color(nsColor: .textBackgroundColor).opacity(0.7),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(.secondary.opacity(0.22)))

            HStack(spacing: 10) {
                CredentialStatusLabel(
                    state: state,
                    configuredText: "Custom headers saved securely",
                    missingText: "No custom headers saved"
                )

                Spacer(minLength: 12)

                if state.isConfigured == true {
                    Button {
                        showsRemoveConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .disabled(state.isBusy)
                    .help("Remove saved custom headers")
                    .accessibilityLabel("Remove saved custom headers")
                }

                Button(action: save) {
                    CredentialSaveButtonLabel(state: state)
                }
                .disabled(trimmedDraft.isEmpty || state.isBusy)
            }

            if let message = state.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(state.messageIsError ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task {
            await controller.refreshCredentialState(for: .customHeaders)
        }
        .confirmationDialog(
            "Remove the saved custom headers?",
            isPresented: $showsRemoveConfirmation
        ) {
            Button("Remove Custom Headers", role: .destructive) {
                Task {
                    if await controller.removeCredential(.customHeaders) {
                        draft = ""
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var fieldPrompt: String {
        state.isConfigured == true
            ? "Enter replacement custom headers"
            : "Enter custom headers"
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        guard !trimmedDraft.isEmpty, !state.isBusy else { return }
        let value = draft
        Task {
            if await controller.saveAndVerifyCredential(value, for: .customHeaders) {
                draft = ""
            }
        }
    }
}

private struct CredentialStatusLabel: View {
    let state: InferenceCredentialState
    let configuredText: String
    let missingText: String

    var body: some View {
        HStack(spacing: 6) {
            if state.activity == .checking {
                ProgressView()
                    .controlSize(.small)
                Text("Checking...")
            } else if state.isConfigured == true {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(configuredText)
            } else if state.isConfigured == false {
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
                Text(missingText)
            } else {
                ProgressView()
                    .controlSize(.small)
                Text("Checking...")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

private struct CredentialSaveButtonLabel: View {
    let state: InferenceCredentialState

    var body: some View {
        HStack(spacing: 6) {
            if state.activity == .saving || state.activity == .verifying {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "checkmark.shield")
            }
            Text(title)
        }
        .frame(width: 118)
    }

    private var title: String {
        switch state.activity {
        case .saving:
            "Saving..."
        case .verifying:
            "Verifying..."
        default:
            "Save & Verify"
        }
    }
}

private enum GatewayPreset: String, CaseIterable, Identifiable {
    case custom = "none"
    case ccSwitch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .custom: "Custom"
        case .ccSwitch: "CC Switch"
        }
    }
}

private struct AppearanceSettingsPanel: View {
    @AppStorage(MarrAppearanceKeys.colorScheme) private var colorScheme = "System"
    @AppStorage(MarrAppearanceKeys.glassSurfaces) private var glassSurfaces = true
    @AppStorage(MarrBubbleColor.storageKey) private var bubbleColor = MarrBubbleColor.system.rawValue
    @AppStorage(MarrAccentColor.storageKey) private var accentColor = MarrAccentColor.system.rawValue

    var body: some View {
        Section("Appearance") {
            Picker("Mode", selection: $colorScheme) {
                Text("System").tag("System")
                Text("Light").tag("Light")
                Text("Dark").tag("Dark")
            }
            .pickerStyle(.segmented)
            Toggle("Liquid Glass", isOn: $glassSurfaces)
        }

        Section("Colors") {
            BubbleColorPicker(selection: $bubbleColor)
            AccentColorPicker(selection: $accentColor)
        }
    }
}

private struct BubbleColorPicker: View {
    @Binding var selection: String

    var body: some View {
        HStack {
            Text("Bubble Color")
            Spacer()
            BubbleColorDropdown(selection: $selection)
            .frame(width: 150, alignment: .trailing)
        }
    }
}

private struct AccentColorPicker: View {
    @Binding var selection: String

    var body: some View {
        HStack {
            Text("Accent Color")
            Spacer()
            AccentColorDropdown(selection: $selection)
            .frame(width: 150, alignment: .trailing)
        }
    }
}

private struct BubbleColorDropdown: View {
    @Binding var selection: String
    @State private var isPresented = false

    private var selectedOption: MarrBubbleColor {
        MarrBubbleColor.resolve(selection)
    }

    var body: some View {
        ColorDropdownButton(
            title: selectedOption.title,
            color: selectedOption.dotColor,
            isPresented: $isPresented
        )
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(MarrBubbleColor.allCases) { option in
                    Button {
                        selection = option.rawValue
                        isPresented = false
                    } label: {
                        ColorMenuOptionLabel(
                            title: option.title,
                            color: option.dotColor,
                            isSelected: selection == option.rawValue
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .frame(width: 156)
        }
    }
}

private struct AccentColorDropdown: View {
    @Binding var selection: String
    @State private var isPresented = false

    private var selectedOption: MarrAccentColor {
        MarrAccentColor.resolve(selection)
    }

    var body: some View {
        ColorDropdownButton(
            title: selectedOption.title,
            color: selectedOption.dotColor,
            isPresented: $isPresented
        )
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(MarrAccentColor.allCases) { option in
                    Button {
                        selection = option.rawValue
                        isPresented = false
                    } label: {
                        ColorMenuOptionLabel(
                            title: option.title,
                            color: option.dotColor,
                            isSelected: selection == option.rawValue
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .frame(width: 156)
        }
    }
}

private struct ColorDropdownButton: View {
    let title: String
    let color: Color
    @Binding var isPresented: Bool

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 9, height: 9)
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct ColorMenuOptionLabel: View {
    let title: String
    let color: Color
    let isSelected: Bool
    @AppStorage(MarrAccentColor.storageKey) private var accentColor = MarrAccentColor.system.rawValue

    var body: some View {
        HStack(spacing: 8) {
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 14)
            } else {
                Color.clear
                    .frame(width: 14)
            }
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
            Text(title)
                .font(MarrTypography.body(size: 13, weight: isSelected ? .semibold : .regular))
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .foregroundStyle(isSelected ? selectedAccent.foregroundColor : .primary)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? selectedAccentColor : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var selectedAccentColor: Color {
        selectedAccent.color
    }

    private var selectedAccent: MarrAccentColor {
        MarrAccentColor.resolve(accentColor)
    }
}
