import AppKit
import Carbon
import MarrCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var controller: MarrController
    @State private var selection: SettingsSection = .general
    @AppStorage(MarrAccentColor.storageKey) private var accentColor = MarrAccentColor.system.rawValue

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(SettingsSection.allCases) { section in
                    SettingsSidebarRow(
                        section: section,
                        isSelected: selection == section,
                        accentColor: selectedAccent.color,
                        accentForegroundColor: selectedAccent.foregroundColor
                    ) {
                        selection = section
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .navigationTitle("Settings")
            .frame(minWidth: 190)
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
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private var selectedPanel: some View {
        switch selection {
        case .general:
            GeneralSettingsPanel(controller: controller)
        case .capture:
            CaptureSettingsPanel(controller: controller)
        case .history:
            EmptyView()
        case .provider:
            ProviderSettingsPanel(controller: controller)
        case .appearance:
            AppearanceSettingsPanel()
        case .data:
            DataSettingsPanel(controller: controller)
        case .advanced:
            AdvancedSettingsPanel(controller: controller)
        }
    }

    private var selectedAccentColor: Color {
        selectedAccent.color
    }

    private var selectedAccent: MarrAccentColor {
        MarrAccentColor.resolve(accentColor)
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case capture
    case history
    case provider
    case appearance
    case data
    case advanced

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .capture: "Capture"
        case .history: "History"
        case .provider: "AI Provider"
        case .appearance: "Appearance"
        case .data: "Data"
        case .advanced: "Advanced"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .capture: "viewfinder"
        case .history: "clock.arrow.circlepath"
        case .provider: "sparkles"
        case .appearance: "sun.max"
        case .data: "externaldrive"
        case .advanced: "wrench.and.screwdriver"
        }
    }
}

private struct SettingsSidebarRow: View {
    let section: SettingsSection
    let isSelected: Bool
    let accentColor: Color
    let accentForegroundColor: Color
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label {
                Text(section.title)
                    .font(MarrTypography.body(size: 14, weight: isActive ? .semibold : .regular))
            } icon: {
                Image(systemName: section.systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 20)
            }
            .foregroundStyle(isActive ? accentForegroundColor : .primary)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isActive ? accentColor : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var isActive: Bool {
        isSelected || isHovered
    }
}

private struct GeneralSettingsPanel: View {
    @ObservedObject var controller: MarrController
    @AppStorage("menu.showStatus") private var showStatus = true

    var body: some View {
        Section("Menu Bar") {
            Toggle("Show status", isOn: $showStatus)
            SettingsValueRow(title: "Status", value: statusLabel)
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
        Section("Shortcut") {
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
                Text("Capture window")
                Spacer()
                HotKeyRecorder(
                    keyCode: $windowKeyCode,
                    modifiers: $windowModifiers,
                    onChange: saveWindowShortcut
                )
                .frame(width: 132, height: 30)
            }

            Picker("Hotkey scope", selection: scopeBinding) {
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

        Section("Answer Panel") {
            SettingsValueRow(title: "New capture", value: "Open answer panel")
            SettingsValueRow(title: "When minimized", value: "Shortcut restores panel")
        }

        Section("Planned Controls") {
            SettingsValueRow(title: "Default capture mode", value: "Area selection")
            SettingsValueRow(title: "Panel placement", value: "Near selection")
            SettingsValueRow(title: "Screenshot retention", value: "Save with history")
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
    @AppStorage("gateway.preset") private var gatewayPreset = GatewayPreset.none.rawValue

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
            Section("OpenAI") {
                SecureField("API Key", text: $controller.apiKey)
            }
        } else {
            gatewaySection
        }
    }

    private var gatewaySection: some View {
        Section("Gateway") {
            Picker("Preset", selection: gatewayPresetBinding) {
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

private enum GatewayPreset: String, CaseIterable, Identifiable {
    case none
    case ccSwitch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "None"
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
        Section("Theme") {
            Picker("Color Scheme", selection: $colorScheme) {
                Text("System").tag("System")
                Text("Light").tag("Light")
                Text("Dark").tag("Dark")
            }
            .pickerStyle(.segmented)
        }

        Section("Surfaces") {
            Toggle("Use active glass surfaces", isOn: $glassSurfaces)
            SettingsValueRow(
                title: "Current style",
                value: glassSurfaces ? "Active Liquid Glass" : "Unfocused Liquid Glass"
            )

            ZStack {
                LinearGradient(
                    colors: [
                        selectedAccent.color.opacity(0.72),
                        Color.purple.opacity(0.52),
                        Color.orange.opacity(0.46)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .allowsHitTesting(false)

                HStack(spacing: 10) {
                    Image(systemName: glassSurfaces ? "circle.hexagongrid.fill" : "drop.fill")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Surface preview")
                            .font(MarrTypography.body(size: 13, weight: .semibold))
                        Text(glassSurfaces ? "Adaptive refraction and highlights" : "Matches unfocused answer surfaces")
                            .font(MarrTypography.caption2())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .frame(height: 62)
                .marrGlassSurface(cornerRadius: 14, isClear: true)
            }
            .frame(height: 62)
        }

        Section("Messages") {
            BubbleColorPicker(selection: $bubbleColor)
            AccentColorPicker(selection: $accentColor)
        }

        Section("Typography") {
            SettingsValueRow(title: "Font selection", value: "Not configurable yet")
            Text("Marr currently chooses the best available bundled font automatically.")
                .font(MarrTypography.caption2())
                .foregroundStyle(.secondary)
        }
    }

    private var selectedAccent: MarrAccentColor {
        MarrAccentColor.resolve(accentColor)
    }
}

private struct BubbleColorPicker: View {
    @Binding var selection: String

    private var selectedOption: MarrBubbleColor {
        MarrBubbleColor.resolve(selection)
    }

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

    private var selectedOption: MarrAccentColor {
        MarrAccentColor.resolve(selection)
    }

    var body: some View {
        HStack {
            Text("Accent Color")
            Spacer()
            AccentColorDropdown(selection: $selection)
            .frame(width: 150, alignment: .trailing)
        }
    }
}

private struct ColorOptionLabel: View {
    let title: String
    let color: Color

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
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

private struct DataSettingsPanel: View {
    @ObservedObject var controller: MarrController
    @State private var isConfirmingHistoryClear = false

    var body: some View {
        Section("History") {
            SettingsValueRow(
                title: "Saved conversations",
                value: "\(controller.historyStore.conversations.count)"
            )

            Button(role: .destructive) {
                isConfirmingHistoryClear = true
            } label: {
                Label("Clear History", systemImage: "trash")
                    .font(MarrTypography.body(size: 13, weight: .semibold))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.vertical, 3)
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

        Section("Privacy") {
            SettingsValueRow(title: "Credentials in history", value: "Never saved")
            SettingsValueRow(title: "Screenshots", value: "Stored locally")
        }
    }
}

private struct AdvancedSettingsPanel: View {
    @ObservedObject var controller: MarrController
    @AppStorage(MarrHotKeyConfiguration.scopeKey) private var hotKeyScope = MarrHotKeyScope.global.rawValue

    var body: some View {
        Section("Diagnostics") {
            SettingsValueRow(title: "Last history error", value: controller.historyStore.lastErrorMessage ?? "None")
        }

        Section("Runtime") {
            SettingsValueRow(title: "Hotkey scope", value: resolvedHotKeyScope.title)
            SettingsValueRow(title: "History storage", value: "Application Support")
        }
    }

    private var resolvedHotKeyScope: MarrHotKeyScope {
        MarrHotKeyScope(rawValue: hotKeyScope) ?? .global
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
