import AppKit
import Carbon
import MarrCore
import MarrSettings
import SwiftUI

enum MarrOnboarding {
    static let completedVersionKey = "onboarding.completedVersion"
    static let currentVersion = 1

    static func isRequired(in defaults: UserDefaults = .standard) -> Bool {
        defaults.integer(forKey: completedVersionKey) < currentVersion
    }

    static func markCompleted(in defaults: UserDefaults = .standard) {
        defaults.set(currentVersion, forKey: completedVersionKey)
    }
}

@MainActor
final class MarrOnboardingPresenter {
    static let shared = MarrOnboardingPresenter()

    private var windowController: MarrOnboardingWindowController?

    private init() {}

    func show(controller: MarrController) {
        if let windowController {
            windowController.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let nextWindowController = MarrOnboardingWindowController(
            controller: controller
        ) { [weak self] in
            self?.windowController?.close()
            self?.windowController = nil
        }
        windowController = nextWindowController
        nextWindowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

#if DEBUG
    var presentedWindowForTesting: NSWindow? {
        windowController?.window
    }

    func dismissForTesting() {
        windowController?.close()
        windowController = nil
    }
#endif
}

@MainActor
final class MarrOnboardingWindowController: NSWindowController, NSWindowDelegate {
    init(controller: MarrController, onFinish: @escaping () -> Void) {
        let rootView = OnboardingView(controller: controller, onFinish: onFinish)
            .marrPreferredColorScheme()
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)

        window.title = "Welcome to Marr"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.minSize = NSSize(width: 820, height: 600)
        window.setContentSize(NSSize(width: 920, height: 650))
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        false
    }
}

private struct OnboardingView: View {
    @ObservedObject var controller: MarrController
    let onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var sidebarSelection
    @State private var step = OnboardingStep.welcome
    @State private var navigationDirection = 1
    @AppStorage(MarrAccentColor.storageKey) private var accentColor = MarrAccentColor.system.rawValue

    var body: some View {
        HStack(spacing: 0) {
            sidebar

            Divider()

            VStack(spacing: 0) {
                ScrollView {
                    pageContent
                        .id(step)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.horizontal, 48)
                        .padding(.top, 52)
                        .padding(.bottom, 36)
                        .transition(pageTransition)
                }
                .scrollIndicators(.hidden)
                .clipped()

                Divider()
                footer
            }
        }
        .frame(minWidth: 820, minHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(selectedAccent.color)
        .animation(
            reduceMotion ? nil : .spring(response: 0.48, dampingFraction: 0.88),
            value: step
        )
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(selectedAccent.color)
                    Image(systemName: "viewfinder")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(selectedAccent.foregroundColor)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Marr")
                        .font(MarrTypography.body(size: 19, weight: .semibold))
                }
            }
            .padding(.bottom, 36)

            VStack(alignment: .leading, spacing: 7) {
                ForEach(OnboardingStep.allCases) { item in
                    sidebarStep(item)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 30)
        .padding(.bottom, 24)
        .frame(width: 235)
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.72))
    }

    private func sidebarStep(_ item: OnboardingStep) -> some View {
        HStack(spacing: 11) {
            ZStack {
                Circle()
                    .fill(step == item ? selectedAccent.color : Color.primary.opacity(0.07))
                    .scaleEffect(step == item ? 1.08 : 1)

                if item.rawValue < step.rawValue {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(step == item ? selectedAccent.foregroundColor : .secondary)
                        .transition(.scale(scale: 0.55).combined(with: .opacity))
                } else {
                    Text("\(item.rawValue + 1)")
                        .font(MarrTypography.mono(size: 10, weight: .semibold))
                        .foregroundStyle(step == item ? selectedAccent.foregroundColor : .secondary)
                        .transition(.scale(scale: 0.55).combined(with: .opacity))
                }
            }
            .frame(width: 25, height: 25)

            Text(item.title)
                .font(MarrTypography.body(size: 13, weight: step == item ? .semibold : .regular))
                .foregroundStyle(step.rawValue >= item.rawValue ? .primary : .secondary)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
        .background(
            ZStack {
                if step == item {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(selectedAccent.color.opacity(0.12))
                        .matchedGeometryEffect(id: "sidebar-selection", in: sidebarSelection)
                }
            }
        )
    }

    @ViewBuilder
    private var pageContent: some View {
        switch step {
        case .welcome:
            WelcomeOnboardingPage(accent: selectedAccent)
        case .shortcuts:
            ShortcutsOnboardingPage(controller: controller)
        case .provider:
            ProviderOnboardingPage(controller: controller)
        case .preferences:
            PreferencesOnboardingPage(controller: controller)
        case .ready:
            ReadyOnboardingPage(controller: controller, accent: selectedAccent)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if step != .ready {
                Button("Set Up Later") {
                    finish()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if step != .welcome {
                Button("Back") {
                    move(by: -1)
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            }

            Button(step == .ready ? "Start Using Marr" : "Continue") {
                if step == .ready {
                    finish()
                } else {
                    move(by: 1)
                }
            }
            .buttonStyle(.borderedProminent)
            .foregroundStyle(selectedAccent.foregroundColor)
            .keyboardShortcut(.defaultAction)
        }
        .controlSize(.large)
        .padding(.horizontal, 30)
        .frame(height: 76)
    }

    private var selectedAccent: MarrAccentColor {
        MarrAccentColor.resolve(accentColor)
    }

    private var pageTransition: AnyTransition {
        guard !reduceMotion else {
            return .opacity
        }

        let insertionEdge: Edge = navigationDirection > 0 ? .trailing : .leading
        let removalEdge: Edge = navigationDirection > 0 ? .leading : .trailing
        return .asymmetric(
            insertion: .opacity.combined(with: .move(edge: insertionEdge)),
            removal: .opacity.combined(with: .move(edge: removalEdge))
        )
    }

    private func move(by offset: Int) {
        guard let next = OnboardingStep(rawValue: step.rawValue + offset) else { return }
        navigationDirection = offset >= 0 ? 1 : -1
        step = next
    }

    private func finish() {
        MarrOnboarding.markCompleted()
        onFinish()
    }
}

private enum OnboardingStep: Int, CaseIterable, Identifiable {
    case welcome
    case shortcuts
    case provider
    case preferences
    case ready

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .shortcuts: "Shortcuts"
        case .provider: "AI Provider"
        case .preferences: "Preferences"
        case .ready: "Ready"
        }
    }
}

private struct WelcomeOnboardingPage: View {
    let accent: MarrAccentColor

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var contentVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            OnboardingPageHeader(title: "Welcome to Marr")

            OnboardingWelcomeHero(accent: accent)
                .frame(height: 238)
                .opacity(contentVisible ? 1 : 0)
                .scaleEffect(contentVisible ? 1 : 0.96)

            HStack(spacing: 14) {
                OnboardingFeatureCard(
                    icon: "viewfinder",
                    title: "Capture",
                    accent: accent.color,
                    isVisible: contentVisible,
                    delay: 0
                )
                OnboardingFeatureCard(
                    icon: "bubble.left.and.bubble.right",
                    title: "Ask",
                    accent: accent.color,
                    isVisible: contentVisible,
                    delay: 0.07
                )
                OnboardingFeatureCard(
                    icon: "character.book.closed",
                    title: "Translate",
                    accent: accent.color,
                    isVisible: contentVisible,
                    delay: 0.14
                )
            }
        }
        .onAppear {
            guard !contentVisible else { return }
            if reduceMotion {
                contentVisible = true
            } else {
                withAnimation(.spring(response: 0.58, dampingFraction: 0.84)) {
                    contentVisible = true
                }
            }
        }
    }
}

private struct ShortcutsOnboardingPage: View {
    @ObservedObject var controller: MarrController
    @State private var runningApplications = OnboardingApplicationOption.currentOptions
    @AppStorage(MarrHotKeyConfiguration.keyCodeKey) private var keyCode = Int(kVK_ANSI_0)
    @AppStorage(MarrHotKeyConfiguration.modifiersKey) private var modifiers = Int(cmdKey | shiftKey)
    @AppStorage(MarrWindowCaptureHotKeyConfiguration.keyCodeKey) private var windowKeyCode = Int(kVK_ANSI_9)
    @AppStorage(MarrWindowCaptureHotKeyConfiguration.modifiersKey) private var windowModifiers = Int(cmdKey | shiftKey)
    @AppStorage(MarrHotKeyConfiguration.scopeKey) private var scope = MarrHotKeyScope.global.rawValue
    @AppStorage(MarrHotKeyConfiguration.scopeBundleIDKey) private var scopeBundleID = ""
    @AppStorage(MarrHotKeyConfiguration.scopeAppNameKey) private var scopeAppName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            OnboardingPageHeader(title: "Keyboard Shortcuts")

            VStack(spacing: 12) {
                shortcutCard(
                    icon: "viewfinder",
                    title: "Capture an area",
                    keyCode: $keyCode,
                    modifiers: $modifiers
                )

                shortcutCard(
                    icon: "macwindow",
                    title: "Capture current window",
                    keyCode: $windowKeyCode,
                    modifiers: $windowModifiers
                )
            }

            OnboardingCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Availability")
                            .font(MarrTypography.body(size: 14, weight: .semibold))
                        Spacer()
                        Picker("Shortcut availability", selection: scopeBinding) {
                            ForEach(MarrHotKeyScope.allCases) { option in
                                Text(option.title).tag(option.rawValue)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 160)
                    }

                    if MarrHotKeyScope(rawValue: scope) == .frontmostApplication {
                        Divider()
                        HStack {
                            Text("Active only in")
                                .font(MarrTypography.body(size: 13))
                            Spacer()
                            Picker("Application", selection: applicationBinding) {
                                ForEach(runningApplications) { app in
                                    Text(app.name).tag(app.bundleID)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 210)
                        }
                    }
                }
            }

            if shortcutsConflict {
                Label("Shortcuts must be different.", systemImage: "exclamationmark.triangle.fill")
                    .font(MarrTypography.body(size: 12))
                    .foregroundStyle(.orange)
            }
        }
        .onAppear {
            refreshRunningApplications()
        }
    }

    private func shortcutCard(
        icon: String,
        title: String,
        keyCode: Binding<Int>,
        modifiers: Binding<Int>
    ) -> some View {
        OnboardingCard {
            HStack(spacing: 15) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 32)

                Text(title)
                    .font(MarrTypography.body(size: 14, weight: .semibold))

                Spacer()

                OnboardingHotKeyRecorder(
                    keyCode: keyCode,
                    modifiers: modifiers,
                    onChange: saveShortcuts
                )
                .frame(width: 136, height: 31)
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
                saveShortcuts()
            }
        )
    }

    private var applicationBinding: Binding<String> {
        Binding(
            get: { scopeBundleID },
            set: { nextValue in
                scopeBundleID = nextValue
                scopeAppName = runningApplications.first { $0.bundleID == nextValue }?.name ?? nextValue
                saveShortcuts()
            }
        )
    }

    private var shortcutsConflict: Bool {
        keyCode == windowKeyCode && modifiers == windowModifiers
    }

    private func refreshRunningApplications() {
        runningApplications = OnboardingApplicationOption.currentOptions
    }

    private func saveShortcuts() {
        MarrHotKeyConfiguration(
            keyCode: UInt32(keyCode),
            modifiers: UInt32(modifiers),
            scope: MarrHotKeyScope(rawValue: scope) ?? .global,
            scopeBundleID: scopeBundleID,
            scopeAppName: scopeAppName
        ).save()
        MarrWindowCaptureHotKeyConfiguration(
            keyCode: UInt32(windowKeyCode),
            modifiers: UInt32(windowModifiers)
        ).save()
        controller.reloadHotKey()
    }
}

private struct ProviderOnboardingPage: View {
    @ObservedObject var controller: MarrController
    @State private var apiKeyDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            OnboardingPageHeader(title: "AI Provider")

            Picker("Provider", selection: $controller.provider) {
                ForEach(InferenceProvider.allCases) { provider in
                    Text(provider.rawValue).tag(provider)
                }
            }
            .pickerStyle(.segmented)

            OnboardingCard {
                VStack(alignment: .leading, spacing: 15) {
                    if controller.provider == .gateway {
                        onboardingField("Base URL") {
                            TextField("https://your-gateway.example/v1", text: $controller.gatewayBaseURL)
                                .textFieldStyle(.roundedBorder)
                        }

                        HStack(spacing: 18) {
                            onboardingField("API format") {
                                Picker("API format", selection: $controller.gatewayAPIFormat) {
                                    ForEach(GatewayAPIFormat.allCases) { format in
                                        Text(format.rawValue).tag(format)
                                    }
                                }
                                .labelsHidden()
                            }

                            onboardingField("Authentication") {
                                Picker("Authentication", selection: $controller.gatewayAuthScheme) {
                                    ForEach(GatewayAuthScheme.allCases) { scheme in
                                        Text(scheme.rawValue).tag(scheme)
                                    }
                                }
                                .labelsHidden()
                            }
                        }
                    }

                    onboardingField("Model") {
                        TextField("Model name", text: $controller.model)
                            .textFieldStyle(.roundedBorder)
                    }

                    if let credential {
                        Divider()

                        VStack(alignment: .leading, spacing: 9) {
                            HStack {
                                Text("API Key")
                                    .font(MarrTypography.body(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                credentialStatus(for: credential)
                            }

                            HStack(spacing: 10) {
                                SecureField("Enter API Key", text: $apiKeyDraft)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit(saveCredential)

                                Button(action: saveCredential) {
                                    if credentialState(for: credential).isBusy {
                                        ProgressView()
                                            .controlSize(.small)
                                            .frame(width: 82)
                                    } else {
                                        Text("Save & Verify")
                                            .frame(width: 82)
                                    }
                                }
                                .disabled(trimmedAPIKey.isEmpty || credentialState(for: credential).isBusy)
                            }

                            if
                                credentialState(for: credential).messageIsError,
                                let message = credentialState(for: credential).message
                            {
                                Text(message)
                                    .font(MarrTypography.body(size: 11))
                                    .foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
        .task(id: credential) {
            if let credential {
                await controller.refreshCredentialState(for: credential)
            }
        }
        .onChange(of: controller.provider) {
            apiKeyDraft = ""
        }
    }

    private var credential: InferenceCredential? {
        switch controller.provider {
        case .openAI:
            .openAIAPIKey
        case .gateway:
            controller.gatewayAuthScheme == .none ? nil : .gatewayAPIKey
        }
    }

    private var trimmedAPIKey: String {
        apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func credentialState(for credential: InferenceCredential) -> InferenceCredentialState {
        controller.credentialState(for: credential)
    }

    @ViewBuilder
    private func credentialStatus(for credential: InferenceCredential) -> some View {
        let state = credentialState(for: credential)
        if state.activity == .checking {
            ProgressView()
                .controlSize(.small)
        } else if state.isConfigured == true {
            Label("Saved", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(MarrTypography.body(size: 11, weight: .semibold))
        } else {
            Text("Not set")
                .font(MarrTypography.body(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func onboardingField<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(MarrTypography.body(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func saveCredential() {
        guard let credential, !trimmedAPIKey.isEmpty else { return }
        let value = apiKeyDraft
        Task {
            if await controller.saveAndVerifyCredential(value, for: credential) {
                apiKeyDraft = ""
            }
        }
    }
}

private struct PreferencesOnboardingPage: View {
    @ObservedObject var controller: MarrController
    @AppStorage(MarrAppearanceKeys.colorScheme) private var colorScheme = "System"
    @AppStorage(MarrAppearanceKeys.glassSurfaces) private var glassSurfaces = true
    @AppStorage(MarrAccentColor.storageKey) private var accentColor = MarrAccentColor.system.rawValue
    @AppStorage(MarrBubbleColor.storageKey) private var bubbleColor = MarrBubbleColor.system.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            OnboardingPageHeader(title: "Preferences")

            OnboardingCard {
                VStack(alignment: .leading, spacing: 18) {
                    preferenceHeader("Appearance")

                    Picker("Appearance", selection: $colorScheme) {
                        Text("System").tag("System")
                        Text("Light").tag("Light")
                        Text("Dark").tag("Dark")
                    }
                    .pickerStyle(.segmented)

                    Toggle("Use Liquid Glass surfaces", isOn: $glassSurfaces)

                    Divider()

                    colorChoices(
                        title: "Accent color",
                        options: MarrAccentColor.allCases.map { ($0.rawValue, $0.title, $0.dotColor) },
                        selection: $accentColor
                    )

                    colorChoices(
                        title: "Answer bubble",
                        options: MarrBubbleColor.allCases.map { ($0.rawValue, $0.title, $0.dotColor) },
                        selection: $bubbleColor
                    )
                }
            }

            OnboardingCard {
                VStack(alignment: .leading, spacing: 14) {
                    preferenceHeader("Response length")

                    Stepper(
                        value: $controller.maximumOutputTokens,
                        in: 256...32_768,
                        step: 256
                    ) {
                        HStack {
                            Text("Maximum output tokens")
                                .font(MarrTypography.body(size: 13))
                            Spacer()
                            Text(controller.maximumOutputTokens.formatted())
                                .font(MarrTypography.mono(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    private func preferenceHeader(_ title: String) -> some View {
        Text(title)
            .font(MarrTypography.body(size: 14, weight: .semibold))
    }

    private func colorChoices(
        title: String,
        options: [(value: String, title: String, color: Color)],
        selection: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(MarrTypography.body(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                ForEach(options, id: \.value) { option in
                    Button {
                        selection.wrappedValue = option.value
                    } label: {
                        ZStack {
                            Circle()
                                .fill(option.color)
                                .frame(width: 22, height: 22)
                            if selection.wrappedValue == option.value {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .black))
                                    .foregroundStyle(.white)
                                    .shadow(color: .black.opacity(0.45), radius: 1)
                            }
                        }
                        .padding(4)
                        .background(
                            Circle()
                                .stroke(
                                    selection.wrappedValue == option.value
                                        ? Color.primary.opacity(0.7)
                                        : Color.clear,
                                    lineWidth: 1.5
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .help(option.title)
                    .accessibilityLabel(option.title)
                }
            }
        }
    }
}

private struct ReadyOnboardingPage: View {
    @ObservedObject var controller: MarrController
    let accent: MarrAccentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(spacing: 20) {
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(accent.color)
                    Image(systemName: "checkmark")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(accent.foregroundColor)
                }
                .frame(width: 76, height: 76)

                Text("Ready")
                    .font(MarrTypography.body(size: 28, weight: .semibold))
            }

            VStack(spacing: 12) {
                summaryRow(
                    icon: "viewfinder",
                    title: "Capture an area",
                    value: MarrHotKeyConfiguration.current.displayString
                )
                summaryRow(
                    icon: "macwindow",
                    title: "Capture current window",
                    value: MarrWindowCaptureHotKeyConfiguration.current.displayString
                )
                summaryRow(
                    icon: "sparkles",
                    title: "AI provider",
                    value: "\(controller.provider.rawValue) · \(controller.model)"
                )
            }

        }
    }

    private func summaryRow(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26)
            Text(title)
                .font(MarrTypography.body(size: 13, weight: .semibold))
            Spacer()
            Text(value)
                .font(MarrTypography.mono(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

private struct OnboardingPageHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(MarrTypography.body(size: 28, weight: .semibold))
    }
}

private struct OnboardingWelcomeHero: View {
    let accent: MarrAccentColor

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAnimating = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [
                        accent.color.opacity(0.17),
                        accent.color.opacity(0.055),
                        Color.primary.opacity(0.025)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Circle()
                    .fill(accent.color.opacity(0.22))
                    .frame(width: 190, height: 190)
                    .blur(radius: 52)
                    .offset(
                        x: isAnimating ? proxy.size.width * 0.28 : proxy.size.width * 0.08,
                        y: isAnimating ? -54 : 48
                    )
                    .animation(
                        .easeInOut(duration: 4.2).repeatForever(autoreverses: true),
                        value: isAnimating
                    )

                HStack(spacing: 24) {
                    capturePreview
                        .frame(maxWidth: .infinity)

                    flowIndicator

                    answerPreview
                        .frame(maxWidth: .infinity)
                }
                .padding(26)
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(accent.color.opacity(0.18), lineWidth: 1)
            )
        }
        .onAppear {
            isAnimating = !reduceMotion
        }
        .onChange(of: reduceMotion) { _, nextValue in
            isAnimating = !nextValue
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Capture, ask, translate")
    }

    private var capturePreview: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color.primary.opacity(0.14 - Double(index) * 0.025))
                        .frame(width: 6, height: 6)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 28)

            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.primary.opacity(0.045))

                Image(systemName: "text.viewfinder")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(accent.color.opacity(0.9))

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.clear, accent.color.opacity(0.85), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 2)
                    .padding(.horizontal, 18)
                    .offset(y: isAnimating ? 36 : -36)
                    .animation(
                        .easeInOut(duration: 1.8).repeatForever(autoreverses: true),
                        value: isAnimating
                    )
            }
            .padding([.horizontal, .bottom], 12)
        }
        .frame(height: 168)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 15, y: 8)
        .rotationEffect(.degrees(isAnimating ? -0.7 : 0.7))
        .offset(y: isAnimating ? -2 : 3)
        .animation(
            .easeInOut(duration: 2.8).repeatForever(autoreverses: true),
            value: isAnimating
        )
    }

    private var flowIndicator: some View {
        ZStack {
            Capsule()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 52, height: 2)

            Circle()
                .fill(accent.color)
                .frame(width: 9, height: 9)
                .shadow(color: accent.color.opacity(0.5), radius: 6)
                .offset(x: isAnimating ? 21 : -21)
                .animation(
                    .easeInOut(duration: 1.35).repeatForever(autoreverses: true),
                    value: isAnimating
                )

            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accent.color)
                .padding(8)
                .background(.regularMaterial, in: Circle())
                .scaleEffect(isAnimating ? 1.08 : 0.92)
                .rotationEffect(.degrees(isAnimating ? 8 : -8))
                .animation(
                    .easeInOut(duration: 1.6).repeatForever(autoreverses: true),
                    value: isAnimating
                )
        }
        .frame(width: 54)
    }

    private var answerPreview: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 8) {
                Circle()
                    .fill(accent.color.opacity(0.22))
                    .frame(width: 26, height: 26)
                    .overlay {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(accent.color)
                    }

                Capsule()
                    .fill(Color.primary.opacity(0.11))
                    .frame(width: 58, height: 7)
            }

            VStack(alignment: .leading, spacing: 8) {
                answerLine(width: 0.9, delay: 0)
                answerLine(width: 1, delay: 0.08)
                answerLine(width: 0.72, delay: 0.16)
            }

            HStack(spacing: 7) {
                ForEach(["doc.on.doc", "speaker.wave.2", "arrow.clockwise"], id: \.self) { icon in
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 25, height: 25)
                        .background(Color.primary.opacity(0.055), in: Circle())
                }
            }
        }
        .padding(18)
        .frame(height: 168, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 15, y: 8)
        .rotationEffect(.degrees(isAnimating ? 0.7 : -0.7))
        .offset(y: isAnimating ? 3 : -2)
        .animation(
            .easeInOut(duration: 3.1).repeatForever(autoreverses: true),
            value: isAnimating
        )
    }

    private func answerLine(width: CGFloat, delay: Double) -> some View {
        GeometryReader { proxy in
            Capsule()
                .fill(accent.color.opacity(0.18))
                .frame(width: proxy.size.width * width, height: 7)
                .scaleEffect(x: isAnimating ? 1 : 0.72, anchor: .leading)
                .opacity(isAnimating ? 1 : 0.5)
                .animation(
                    .easeInOut(duration: 1.45)
                        .delay(delay)
                        .repeatForever(autoreverses: true),
                    value: isAnimating
                )
        }
        .frame(height: 7)
    }
}

private struct OnboardingFeatureCard: View {
    let icon: String
    let title: String
    let accent: Color
    let isVisible: Bool
    let delay: Double

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(isHovered ? accent : Color.secondary)
                .frame(height: 24)
            Text(title)
                .font(MarrTypography.body(size: 14, weight: .semibold))
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .background(
            isHovered ? accent.opacity(0.09) : Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isHovered ? accent.opacity(0.24) : Color.primary.opacity(0.07), lineWidth: 1)
        )
        .shadow(color: isHovered ? accent.opacity(0.13) : .clear, radius: 13, y: 6)
        .opacity(isVisible ? 1 : 0)
        .offset(y: isVisible ? (isHovered ? -4 : 0) : 16)
        .scaleEffect(isHovered ? 1.015 : 1)
        .animation(
            .spring(response: 0.48, dampingFraction: 0.82).delay(delay),
            value: isVisible
        )
        .animation(.easeOut(duration: 0.18), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

private struct OnboardingCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            )
    }
}

private struct OnboardingApplicationOption: Identifiable {
    let bundleID: String
    let name: String

    var id: String { bundleID }

    static var currentOptions: [OnboardingApplicationOption] {
        let options = NSWorkspace.shared.runningApplications.compactMap { app -> OnboardingApplicationOption? in
            guard
                app.activationPolicy == .regular,
                let bundleID = app.bundleIdentifier,
                !bundleID.isEmpty
            else {
                return nil
            }

            return OnboardingApplicationOption(
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

private struct OnboardingHotKeyRecorder: NSViewRepresentable {
    @Binding var keyCode: Int
    @Binding var modifiers: Int
    let onChange: () -> Void

    func makeNSView(context: Context) -> OnboardingHotKeyRecorderView {
        let view = OnboardingHotKeyRecorderView()
        view.onRecord = { keyCode, modifiers in
            self.keyCode = Int(keyCode)
            self.modifiers = Int(modifiers)
            onChange()
        }
        return view
    }

    func updateNSView(_ nsView: OnboardingHotKeyRecorderView, context: Context) {
        nsView.displayString = HotKeyFormatter.displayString(
            keyCode: UInt32(keyCode),
            modifiers: UInt32(modifiers)
        )
    }
}

private final class OnboardingHotKeyRecorderView: NSButton {
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
