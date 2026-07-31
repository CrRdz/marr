import AppKit
import Carbon
import MarrCore
import MarrSettings
import SwiftUI

struct AnswerPanelSettingsView: View {
    @ObservedObject var controller: MarrController
    @State private var selection = AnswerPanelSettingsSection.preferences
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
        case .preferences:
            CompactPreferencesSettingsPanel(controller: controller)
        case .provider:
            CompactProviderSettingsPanel(controller: controller)
        case .usage:
            CompactUsageSettingsPanel(
                usageStore: controller.tokenUsageStore,
                historyStore: controller.historyStore
            )
        }
    }

    private var selectedAccent: MarrAccentColor {
        MarrAccentColor.resolve(accentColor)
    }
}

private enum AnswerPanelSettingsSection: String, CaseIterable, Identifiable {
    case preferences
    case provider
    case usage

    var id: Self { self }

    var title: String {
        switch self {
        case .preferences: "Preferences"
        case .provider: "AI"
        case .usage: "Usage"
        }
    }

    var systemImage: String {
        switch self {
        case .preferences: "gearshape.2"
        case .provider: "cpu"
        case .usage: "chart.bar.xaxis"
        }
    }
}

private struct CompactPreferencesSettingsPanel: View {
    @ObservedObject var controller: MarrController

    var body: some View {
        VStack(spacing: 22) {
            CompactGeneralSettingsPanel(controller: controller)
            CompactAppearanceSettingsPanel()
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

private struct CompactProviderSettingsPanel: View {
    @ObservedObject var controller: MarrController
    @AppStorage("gateway.preset") private var gatewayPreset = GatewayPreset.custom.rawValue
    @State private var showsAdvanced = false

    var body: some View {
        VStack(spacing: 20) {
            providerSelector
            modelSection

            if controller.provider == .openAI {
                openAIConnection
            } else {
                gatewayEndpoint
                gatewayAuthentication
                gatewayAdvanced
            }
        }
    }

    private var providerSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PROVIDER")
                .font(MarrTypography.body(size: 10.5, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.55)

            Picker("Provider", selection: $controller.provider) {
                Label("OpenAI", systemImage: "sparkles")
                    .tag(InferenceProvider.openAI)
                Label("Custom Gateway", systemImage: "point.3.connected.trianglepath.dotted")
                    .tag(InferenceProvider.gateway)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(
                controller.provider == .openAI
                    ? "Managed OpenAI endpoint using the Responses API."
                    : "Connect an OpenAI Responses or Anthropic Messages compatible endpoint."
            )
            .font(MarrTypography.body(size: 10.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var modelSection: some View {
        CompactSettingsGroup("Model") {
            CompactSettingsRow("Model ID", systemImage: "cube") {
                TextField("Upstream model ID", text: $controller.model)
                    .textFieldStyle(.plain)
                    .font(MarrTypography.mono(size: 11.5))
                    .padding(.horizontal, 8)
                    .frame(width: 198, height: 28)
                    .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
            }

            CompactSettingsDivider()

            CompactSettingsRow("Output limit", systemImage: "text.word.spacing") {
                Stepper(
                    controller.maximumOutputTokens.formatted(),
                    value: $controller.maximumOutputTokens,
                    in: 256...32_768,
                    step: 256
                )
                .font(MarrTypography.mono(size: 11.5))
                .controlSize(.small)
                .frame(width: 150)
            }
        }
    }

    private var openAIConnection: some View {
        VStack(spacing: 18) {
            CompactSettingsGroup("Endpoint") {
                CompactReadOnlySetting(
                    title: "Base URL",
                    systemImage: "link",
                    value: "api.openai.com/v1"
                )
                CompactSettingsDivider()
                CompactReadOnlySetting(
                    title: "Protocol",
                    systemImage: "arrow.left.arrow.right",
                    value: "Responses API"
                )
            }

            CompactSettingsGroup("Authentication") {
                CompactCredentialEditor(
                    controller: controller,
                    credential: .openAIAPIKey
                )
            }
        }
    }

    private var gatewayEndpoint: some View {
        CompactSettingsGroup("Endpoint") {
            CompactSettingsRow("Preset", systemImage: "switch.2") {
                Picker("", selection: gatewayPresetBinding) {
                    ForEach(GatewayPreset.allCases) { preset in
                        Text(preset.title).tag(preset.rawValue)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 164)
            }

            CompactSettingsDivider()

            VStack(alignment: .leading, spacing: 7) {
                Label("Base URL", systemImage: "link")
                    .font(MarrTypography.body(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)

                TextField("https://gateway.example.com/v1", text: $controller.gatewayBaseURL)
                    .textFieldStyle(.plain)
                    .font(MarrTypography.mono(size: 11.5))
                    .padding(.horizontal, 9)
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))

                Text("The configured origin is used only for model requests. Marr appends the protocol endpoint when needed.")
                    .font(MarrTypography.body(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 8)

            CompactSettingsDivider()

            CompactSettingsRow("API protocol", systemImage: "arrow.left.arrow.right") {
                Picker("", selection: $controller.gatewayAPIFormat) {
                    ForEach(GatewayAPIFormat.allCases) { format in
                        Text(format.rawValue).tag(format)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 190)
            }
        }
    }

    private var gatewayAuthentication: some View {
        CompactSettingsGroup("Authentication") {
            CompactSettingsRow("Method", systemImage: "lock.shield") {
                Picker("", selection: $controller.gatewayAuthScheme) {
                    Text("Bearer token").tag(GatewayAuthScheme.bearer)
                    Text("x-api-key").tag(GatewayAuthScheme.xAPIKey)
                    Text("No authentication").tag(GatewayAuthScheme.none)
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 180)
            }

            if controller.gatewayAuthScheme != .none {
                CompactSettingsDivider()
                CompactCredentialEditor(
                    controller: controller,
                    credential: .gatewayAPIKey
                )
            } else {
                CompactSettingsDivider()
                Label("No credential will be sent with requests.", systemImage: "checkmark.shield")
                    .font(MarrTypography.body(size: 10.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            }
        }
    }

    private var gatewayAdvanced: some View {
        DisclosureGroup(isExpanded: $showsAdvanced) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Static request headers")
                    .font(MarrTypography.body(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                CompactHeadersCredentialEditor(controller: controller)
            }
            .padding(.top, 9)
        } label: {
            Label("Advanced request options", systemImage: "slider.horizontal.3")
                .font(MarrTypography.body(size: 12.5, weight: .medium))
        }
        .padding(.horizontal, 2)
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

private struct CompactReadOnlySetting: View {
    let title: String
    let systemImage: String
    let value: String

    var body: some View {
        CompactSettingsRow(title, systemImage: systemImage) {
            Text(value)
                .font(MarrTypography.mono(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
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

private struct CompactUsageSettingsPanel: View {
    @ObservedObject var usageStore: TokenUsageStore
    @ObservedObject var historyStore: ConversationHistoryStore
    @State private var hoveredBucketID: Date?

    private let calendar = Calendar.autoupdatingCurrent

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                CompactUsageMetric(value: compactTokenCount(totalTokens), title: "Total Tokens")
                CompactUsageMetric(value: compactTokenCount(peakDailyTokens), title: "Peak Day")
                CompactUsageMetric(value: durationLabel(longestConversationDuration), title: "Longest Chat")
                CompactUsageMetric(value: "\(streaks.current) days", title: "Current Streak")
                CompactUsageMetric(value: "\(streaks.longest) days", title: "Longest Streak")
            }

            CompactSettingsGroup("Token Activity") {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        VStack(alignment: .leading, spacing: 7) {
                            LazyHGrid(
                                rows: Array(repeating: GridItem(.fixed(7), spacing: 2), count: 7),
                                spacing: 2
                            ) {
                                ForEach(dailyBuckets) { bucket in
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(activityColor(tokens: bucket.tokens, maximum: peakDailyTokens))
                                        .frame(width: 7, height: 7)
                                        .overlay {
                                            if calendar.isDateInToday(bucket.start) {
                                                RoundedRectangle(cornerRadius: 2)
                                                    .stroke(Color.accentColor, lineWidth: 1)
                                            }
                                        }
                                        .overlay(alignment: .top) {
                                            if hoveredBucketID == bucket.id {
                                                TokenActivityTooltip(bucket: bucket)
                                                    .offset(x: tooltipHorizontalOffset(for: bucket), y: -36)
                                                    .zIndex(20)
                                            }
                                        }
                                        .onHover { isHovering in
                                            hoveredBucketID = isHovering ? bucket.id : nil
                                        }
                                        .zIndex(hoveredBucketID == bucket.id ? 20 : 0)
                                        .id(bucket.id)
                                }
                            }
                            .padding(.top, 38)

                            HStack(spacing: 2) {
                                ForEach(monthMarkers) { marker in
                                    Color.clear
                                        .frame(width: 7, height: 13)
                                        .overlay(alignment: .leading) {
                                            if let label = marker.label {
                                                Text(label)
                                                    .font(MarrTypography.body(size: 9.5))
                                                    .foregroundStyle(.secondary)
                                                    .fixedSize()
                                            }
                                        }
                                }
                            }
                        }
                        .padding(.vertical, 5)
                    }
                    .scrollIndicators(.hidden)
                    .onAppear {
                        DispatchQueue.main.async {
                            proxy.scrollTo(calendar.startOfDay(for: Date()), anchor: .trailing)
                        }
                    }
                }
            }
        }
    }

    private var totalTokens: Int {
        usageStore.events.reduce(0) { $0 + $1.totalTokens }
    }

    private var dailyTotals: [Date: Int] {
        Dictionary(grouping: usageStore.events) { calendar.startOfDay(for: $0.date) }
            .mapValues { $0.reduce(0) { $0 + $1.totalTokens } }
    }

    private var peakDailyTokens: Int { dailyTotals.values.max() ?? 0 }

    private var longestConversationDuration: TimeInterval {
        historyStore.conversations.map { max(0, $0.updatedAt.timeIntervalSince($0.createdAt)) }.max() ?? 0
    }

    private var streaks: (current: Int, longest: Int) {
        let days = dailyTotals.keys.sorted()
        guard !days.isEmpty else { return (0, 0) }

        var longest = 1
        var run = 1
        for index in 1..<days.count {
            if calendar.dateComponents([.day], from: days[index - 1], to: days[index]).day == 1 {
                run += 1
                longest = max(longest, run)
            } else {
                run = 1
            }
        }

        let today = calendar.startOfDay(for: Date())
        let gap = calendar.dateComponents([.day], from: days.last ?? today, to: today).day ?? 0
        return (gap <= 1 ? run : 0, longest)
    }

    private var dailyBuckets: [UsageBucket] {
        let today = calendar.startOfDay(for: Date())
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let firstDay = calendar.date(byAdding: .weekOfYear, value: -52, to: weekStart) ?? today
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = "MMM d, yyyy"

        return (0..<371).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: firstDay) else { return nil }
            return UsageBucket(
                start: date,
                tokens: date > today ? 0 : (dailyTotals[date] ?? 0),
                label: formatter.string(from: date)
            )
        }
    }

    private var monthMarkers: [UsageMonthMarker] {
        let weekStarts = stride(from: 0, to: dailyBuckets.count, by: 7).map { dailyBuckets[$0].start }
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("MMM")

        return weekStarts.enumerated().map { index, date in
            let previousDate = index > 0 ? weekStarts[index - 1] : nil
            let showsLabel = previousDate == nil
                || calendar.component(.month, from: previousDate!) != calendar.component(.month, from: date)
            return UsageMonthMarker(date: date, label: showsLabel ? formatter.string(from: date) : nil)
        }
    }

    private func activityColor(tokens: Int, maximum: Int) -> Color {
        guard tokens > 0, maximum > 0 else { return .primary.opacity(0.055) }
        let ratio = sqrt(Double(tokens) / Double(maximum))
        return Color.accentColor.opacity(0.25 + ratio * 0.75)
    }

    private func tooltipHorizontalOffset(for bucket: UsageBucket) -> CGFloat {
        guard let firstDate = dailyBuckets.first?.start else { return 0 }
        let dayOffset = calendar.dateComponents([.day], from: firstDate, to: bucket.start).day ?? 0
        let week = dayOffset / 7
        if week < 10 { return 88 }
        if week > 42 { return -88 }
        return 0
    }

    private func compactTokenCount(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000).replacingOccurrences(of: ".0M", with: "M")
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000).replacingOccurrences(of: ".0K", with: "K")
        }
        return value.formatted()
    }

    private func durationLabel(_ duration: TimeInterval) -> String {
        let seconds = Int(duration.rounded())
        if seconds >= 3_600 { return "\(seconds / 3_600)h \((seconds % 3_600) / 60)m" }
        if seconds >= 60 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds)s"
    }
}

private struct CompactUsageMetric: View {
    let value: String
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(MarrTypography.body(size: 17, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(title)
                .font(MarrTypography.body(size: 10.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct UsageMonthMarker: Identifiable {
    let date: Date
    let label: String?
    var id: Date { date }
}

private struct UsageBucket: Identifiable {
    let start: Date
    let tokens: Int
    let label: String
    var id: Date { start }
}

private struct TokenActivityTooltip: View {
    let bucket: UsageBucket

    var body: some View {
        Text("\(bucket.label)  ·  \(bucket.tokens.formatted()) Tokens")
            .font(MarrTypography.body(size: 11.5, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .fixedSize()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(.primary.opacity(0.16), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
            .allowsHitTesting(false)
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
