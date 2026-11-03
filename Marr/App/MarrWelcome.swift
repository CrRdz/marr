import AppKit
import SwiftUI

/// Closing the window leaves the guide available next launch; finishing is explicit.
@MainActor
final class MarrWelcomeProgress: ObservableObject {
    static let completionKey = "marr.welcome.completed.v1"
    enum Step: Int, CaseIterable {
        case welcome, capture, ask, connect, ready
        var label: String {
            switch self {
            case .welcome: "Welcome"
            case .capture: "Capture"
            case .ask: "Ask & translate"
            case .connect: "Your AI"
            case .ready: "Ready"
            }
        }
    }
    @Published var step: Step = .welcome
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var isComplete: Bool { defaults.bool(forKey: Self.completionKey) }
    func next() { step = Step(rawValue: step.rawValue + 1) ?? .ready }
    func back() { step = Step(rawValue: step.rawValue - 1) ?? .welcome }
    func finish() { defaults.set(true, forKey: Self.completionKey) }
}

@MainActor
final class MarrWelcomeWindowController: NSWindowController {
    init(controller: MarrController) {
        let progress = MarrWelcomeProgress()
        let window = AnswerPanelWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 680))
        window.title = "Welcome to Marr"
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovableByWindowBackground = false
        window.contentMinSize = NSSize(width: 540, height: 600)
        super.init(window: window)
        let host = NSHostingView(rootView: AnyView(MarrWelcomeView(
            progress: progress, controller: controller,
            onFinish: { [weak self, weak controller] in
                progress.finish()
                self?.close()
                controller?.restoreMainWindow()
            }).marrPreferredColorScheme().ignoresSafeArea()))
        host.sizingOptions = [.minSize]
        window.contentView = AnswerPanelContentView(frame: NSRect(x: 0, y: 0, width: 640, height: 680), hostedView: host)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func present() {
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct MarrWelcomeView: View {
    @ObservedObject var progress: MarrWelcomeProgress
    @ObservedObject var controller: MarrController
    var refreshAccountsOnAppear = true
    var onFinish: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var systemReducesMotion
    @Environment(\.marrAccessibilityOverrides) private var accessibilityOverrides
    @AppStorage(MarrAccentColor.storageKey) private var accent = MarrAccentColor.system.rawValue

    private var reducesMotion: Bool { accessibilityOverrides?.reducesMotion ?? systemReducesMotion }
    private var ink: Color { MarrPanelColors.primary(for: scheme) }
    private var secondary: Color { MarrPanelColors.secondary(for: scheme) }

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                if progress.step != .connect {
                    ScrollView {
                        VStack(spacing: 24) { tutorial }
                            .padding(.horizontal, 32).padding(.vertical, 24)
                            .frame(maxWidth: 592).frame(maxWidth: .infinity)
                    }
                    .id(progress.step).scrollIndicators(.hidden)
                }
                // Keep the editor mounted while navigating the guide, retaining unsaved
                // fields and secure drafts. Refresh accounts only on the AI step.
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        heading("Connect your AI.", detail: "Add a connection, then choose your model.")
                            .frame(maxWidth: .infinity)
                        CompactProviderSettingsPanel(controller: controller, page: .conversation,
                            openAccount: {}, refreshAccountsOnAppear: false, isOnboarding: true)
                            .buttonStyle(MarrButtonStyle(.secondary, size: .compact))
                            .padding(20)
                            .background(MarrChatComposerSurface(isFocused: false))
                    }
                    .padding(.horizontal, 32).padding(.vertical, 24)
                    .frame(maxWidth: 592).frame(maxWidth: .infinity)
                }
                .opacity(progress.step == .connect ? 1 : 0)
                .allowsHitTesting(progress.step == .connect)
                .disabled(progress.step != .connect)
                .accessibilityHidden(progress.step != .connect)
            }
            footer.padding(.horizontal, 28).padding(.vertical, 20)
        }
        .foregroundStyle(ink)
        .marrGlassSurface(cornerRadius: AnswerPanelConversationLayout.surfaceCornerRadius,
                          frostsTop: true, frostOpacity: 0.80, drawsBorder: true)
        .clipShape(RoundedRectangle(cornerRadius: AnswerPanelConversationLayout.surfaceCornerRadius))
        .tint(MarrAccentColor.resolve(accent).color)
        .animation(MarrMotion.transition(reducesMotion: reducesMotion), value: progress.step)
        .frame(minWidth: 540, minHeight: 600)
        .onChange(of: progress.step, initial: true) { _, step in
            if step == .connect, refreshAccountsOnAppear { controller.refreshChatGPTAccount() }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: 70, height: 30).accessibilityHidden(true)
            Text("Marr").marrTextStyle(.body, weight: .semibold)
            AnswerPanelDragRegion().frame(maxWidth: .infinity, minHeight: 30)
                .accessibilityHidden(true)
            Button("Skip") { onFinish() }.buttonStyle(MarrButtonStyle(.ghost))
        }
        .frame(height: 32)
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8)
    }

    @ViewBuilder private var tutorial: some View {
        switch progress.step {
        case .welcome:
            brandMark(size: 136).padding(.top, 20)
            heading("Hello, Marr.", detail: "Stay with your thought.")
            VStack(spacing: 0) {
                guideRow("viewfinder", "Capture anything", "Select a part of your screen.")
                guideRow("character", "Read it your way", "Translate in place or ask a question.")
                guideRow("bubble.left", "Keep going", "Follow up in chat, with your context attached.")
            }
            .padding(12).background(MarrChatComposerSurface(isFocused: false))
        case .capture:
            heading("Start with what you see.", detail: "A shortcut. A selection. Your next thought.")
            capturePreview
            VStack(spacing: 0) {
                guideRow("command", captureShortcut, captureShortcutDetail)
                guideRow("viewfinder", "Drag to select", "Frame the text, image or window you need.")
                guideRow("pencil", "Mark what matters", "Annotate the screenshot, then translate or ask.")
            }
            Text("On your first capture, allow Screen Recording in macOS.")
                .marrTextStyle(.secondary).foregroundStyle(secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .ask:
            heading("Ask. Then ask again.", detail: "Try the composer here — no AI request is sent.")
            MarrWelcomePractice()
            VStack(spacing: 0) {
                guideRow("paperclip", "Bring your context", "Screenshots and files stay beside your question.")
                guideRow("character", "Just need a translation?", "Choose Translate from the capture toolbar.")
                guideRow("bubble.left", "Keep the conversation going", "Ask a follow-up without taking another screenshot.")
            }
        case .connect:
            EmptyView()
        case .ready:
            brandMark(size: 104)
            heading("A little less switching.", detail: "You're ready to explore Marr.")
            VStack(spacing: 0) {
                guideRow("square.and.pencil", "Start a conversation", "Type a question, or attach something to work on.")
                guideRow("clock.arrow.circlepath", "Pick up where you left off", "Find saved chats in the history sidebar.")
                guideRow("folder", "Keep related work together", "Create a workspace for your chats and attachments.")
            }
            .padding(12).background(MarrChatComposerSurface(isFocused: false))
            Button("Review AI setup") { progress.step = .connect }
                .buttonStyle(MarrButtonStyle(.ghost))
        }
    }

    private var captureShortcut: String {
        controller.hotKeyConfiguration.scope == .disabled ? "Click Marr in the menu bar" : controller.hotKeyConfiguration.displayString
    }
    private var captureShortcutDetail: String {
        switch controller.hotKeyConfiguration.scope {
        case .disabled: "The menu-bar icon opens capture."
        case .global: "Press from any app to open capture."
        case .frontmostApplication: "Available in \(controller.hotKeyConfiguration.scopeDisplayString)."
        }
    }

    private func heading(_ title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Text(title).marrTextStyle(.hero, weight: .semibold).accessibilityAddTraits(.isHeader)
            Text(detail).marrTextStyle(.body).foregroundStyle(secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func guideRow(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            MarrIcon(symbol, size: MarrUI.Icon.toolbar).frame(width: 24, height: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).marrTextStyle(.body, weight: .medium)
                Text(detail).marrTextStyle(.secondary).foregroundStyle(secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private static let brandImage: NSImage = {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let image = NSImage(contentsOf: url) { return image }
        return NSImage(named: "MarrStatusIcon") ?? NSImage()
    }()
    private func brandMark(size: CGFloat) -> some View {
        Image(nsImage: Self.brandImage).resizable().interpolation(.high)
            .aspectRatio(contentMode: .fit).frame(width: size, height: size).accessibilityHidden(true)
    }

    private var capturePreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("A moment of curiosity").marrTextStyle(.caption).foregroundStyle(secondary)
                Spacer()
                Text("Preview").marrTextStyle(.caption).foregroundStyle(secondary)
            }
            Text("Stay curious.")
                .marrTextStyle(.brand, weight: .semibold)
                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                .overlay {
                    RoundedRectangle(cornerRadius: MarrUI.Radius.control)
                        .stroke(ink.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                }
            HStack(spacing: 20) {
                Label("Annotate", marrSymbol: "pencil")
                Label("Translate", marrSymbol: "character")
                Label("Ask", marrSymbol: "bubble.left")
            }.marrTextStyle(.secondary).foregroundStyle(secondary)
        }
        .padding(20).background(MarrChatComposerSurface(isFocused: false))
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        HStack {
            Button("Back") { progress.back() }.buttonStyle(MarrButtonStyle(.ghost))
                .disabled(progress.step == .welcome).opacity(progress.step == .welcome ? 0 : 1)
            Spacer()
            Text("\(progress.step.rawValue + 1) / \(MarrWelcomeProgress.Step.allCases.count) · \(progress.step.label)")
                .marrTextStyle(.secondary).foregroundStyle(secondary)
                .accessibilityLabel("Step \(progress.step.rawValue + 1) of 5, \(progress.step.label)")
            Spacer()
            Button(progress.step == .ready ? "Start chatting" : "Continue") {
                if progress.step == .ready { onFinish() } else { progress.next() }
            }
            .buttonStyle(MarrButtonStyle(.primary, tint: ink, foregroundColor: MarrUI.Surface.canvas))
            .keyboardShortcut(progress.step == .connect || progress.step == .ask ? nil : .defaultAction)
        }
    }
}

/// A local practice composer; deliberately independent of the request coordinator.
struct MarrWelcomePractice: View {
    @State private var question = "What does this mean?"
    @State private var answer: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Practice").marrTextStyle(.caption).foregroundStyle(.secondary)
                Spacer()
                if answer != nil {
                    Button("Try again") { answer = nil; isFocused = true }
                        .buttonStyle(MarrButtonStyle(.ghost, size: .compact))
                }
            }
            if let answer {
                Text(answer).marrTextStyle(.answer).fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Sample answer. " + answer)
            }
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    MarrIcon("photo", size: MarrUI.Icon.inline).accessibilityHidden(true)
                    Text("Stay curious.").marrTextStyle(.secondary)
                    Spacer()
                    Text("Sample screenshot").marrTextStyle(.caption).foregroundStyle(.secondary)
                }
                TextField("Ask about the screenshot", text: $question, axis: .vertical)
                    .marrChatInput().focused($isFocused).onSubmit(send)
                    .accessibilityLabel("Practice question")
                HStack {
                    Text("Sample response only").marrTextStyle(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(action: send) {
                        MarrIcon("arrow.up", size: MarrUI.Icon.inline).frame(width: 28, height: 28)
                    }
                    .marrChatSendButton(isEnabled: !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Try a sample response")
                }
            }
            .padding(16).background(MarrChatComposerSurface(isFocused: isFocused))
        }
    }

    private func send() {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        answer = "Sample answer: “Stay curious” means keep asking questions and exploring."
        isFocused = false
    }
}
