#if DEBUG
import AppKit
import MarrCore
import SwiftUI

/// An explicitly opened developer page made from production components.
/// It has no app controller, network client, persistent preferences or startup hook.
struct MarrComponentGallery: View {
    @State private var appearance = GalleryAppearance.system
    @State private var compact = false
    @State private var overridesAccessibility = false
    @State private var reducesMotion = false
    @State private var reducesTransparency = false
    @State private var increasedContrast = false
    @State private var status = MarrUI.Status.idle
    @State private var companionMood = MarrCompanionMood.waiting
    @State private var companionReading = false
    @State private var companionForm = MarrCompanionForm.orb
    @State private var companionReplay = 0
    @State private var draft = ""
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var editorFocused = false
    @State private var feedback = ""
    @State private var attachments: [ConversationImageAsset] = []

    var body: some View {
        VStack(alignment: .leading, spacing: MarrUI.Spacing.large) {
            Text("Component gallery").marrTextStyle(.brand)
                .accessibilityAddTraits(.isHeader)
            Text("Local sample content. Actions here do not submit requests or change your settings.")
                .marrTextStyle(.secondary)
                .foregroundStyle(.secondary)
            controls
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: MarrUI.Spacing.section) {
                    companion
                    surfaces
                    typography
                    interaction
                    composer
                    codeAndDiff
                }
                .frame(maxWidth: compact ? 360 : 760, alignment: .leading)
                .padding(MarrUI.Spacing.large)
                .frame(maxWidth: .infinity, alignment: .center)
                .environment(\.marrAccessibilityOverrides, overridesAccessibility
                    ? MarrAccessibilityPreferences(reducesMotion: reducesMotion,
                                                   reducesTransparency: reducesTransparency,
                                                   increasedContrast: increasedContrast)
                    : nil)
            }
            .background(MarrUI.Surface.canvas)
        }
        .padding(MarrUI.Spacing.large)
        .frame(minWidth: 440, minHeight: 560)
        .marrTextStyle(.body)
        .background(MarrUI.Surface.canvas)
        .preferredColorScheme(appearance.colorScheme)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
            HStack {
                Picker("Appearance", selection: $appearance) {
                    ForEach(GalleryAppearance.allCases) { Text($0.rawValue).tag($0) }
                }
                .frame(maxWidth: 220)
                Toggle("Narrow content", isOn: $compact)
                    .toggleStyle(.checkbox)
            }
            Toggle("Preview accessibility overrides", isOn: $overridesAccessibility)
                .toggleStyle(.checkbox)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: MarrUI.Spacing.medium) { accessibilityControls }
                VStack(alignment: .leading, spacing: MarrUI.Spacing.small) { accessibilityControls }
            }
            .disabled(!overridesAccessibility)
        }
    }

    private var companion: some View {
        section("Capture companion") {
            HStack(spacing: MarrUI.Spacing.large) {
                MarrCompanion(phase: companionMood == .processing && companionReading
                              ? .recognizing : companionMood.representativePhase, size: 96, form: companionForm)
                    .id(companionReplay)
                VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
                    Picker("Shape", selection: $companionForm) {
                        ForEach(MarrCompanionForm.allCases, id: \.rawValue) { form in
                            Text(form.title).tag(form)
                        }
                    }
                    .pickerStyle(.segmented)
                    Picker("State", selection: $companionMood) {
                        ForEach(MarrCompanionMood.allCases, id: \.rawValue) { mood in
                            Text(mood.title).tag(mood)
                        }
                    }
                    .pickerStyle(.menu)
                    if companionMood == .processing {
                        Toggle("Reading text", isOn: $companionReading).toggleStyle(.checkbox)
                    }
                    Text("Shape follows the tool. Activity controls the light and motion independently.")
                        .marrTextStyle(.secondary)
                    Button("Replay animation") { companionReplay += 1 }
                        .help("Restart the selected companion animation")
                }
            }
        }
    }

    @ViewBuilder private var accessibilityControls: some View {
        Toggle("Reduce motion", isOn: $reducesMotion).toggleStyle(.checkbox)
        Toggle("Opaque surfaces", isOn: $reducesTransparency).toggleStyle(.checkbox)
        Toggle("Increase contrast", isOn: $increasedContrast).toggleStyle(.checkbox)
    }

    private var surfaces: some View {
        section("Surfaces and boundaries") {
            ForEach(MarrUI.SurfaceRole.allCases) { role in
                HStack {
                    Text(role.rawValue.capitalized).marrTextStyle(.body, weight: .medium)
                    Spacer()
                    Text("Readable native content").marrTextStyle(.secondary).foregroundStyle(.secondary)
                }
                .padding(MarrUI.Spacing.medium)
                .marrSurface(role)
            }
            HStack(spacing: MarrUI.Spacing.regular) {
                ForEach(MarrUI.BorderRole.allCases) { role in
                    Text(role.rawValue.capitalized)
                        .marrTextStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(MarrUI.Spacing.medium)
                        .marrSurface(.card, border: role)
                }
            }
        }
    }

    private var typography: some View {
        section("Typography and long content") {
            Text("A clear title / 清晰的标题").marrTextStyle(.pageTitle)
            Text("A paragraph should remain readable when the window narrows. 中文、English、数字 0123456789 与标点应保持稳定的行距。")
                .marrTextStyle(.answer, paragraph: true)
                .fixedSize(horizontal: false, vertical: true)
            Text("Secondary guidance wraps without hiding the essential message.")
                .marrTextStyle(.secondary, paragraph: true)
                .foregroundStyle(.secondary)
            Text("/workspace/研究资料/very-long-file-name-that-preserves-its-extension.swift")
                .marrTextStyle(.code)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var interaction: some View {
        section("Actions and task states") {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: MarrUI.Spacing.regular) { buttons }
                VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) { buttons }
            }
            ForEach(MarrUI.Status.allCases) { MarrStatusLabel($0) }
            MarrStatusLabel(.error, title: "A long failure message remains readable and offers enough context to decide what to do next.")
            if !feedback.isEmpty {
                Text(feedback).marrTextStyle(.secondary).foregroundStyle(.secondary)
                    .accessibilityLabel("Gallery feedback: \(feedback)")
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        Button("Primary") { feedback = "Primary action selected" }
            .buttonStyle(MarrButtonStyle(.primary))
        Button("Secondary") { feedback = "Secondary action selected" }
            .buttonStyle(MarrButtonStyle(.secondary))
        Button("Quiet") { feedback = "Quiet action selected" }
            .buttonStyle(MarrButtonStyle(.ghost))
        Button("Disabled") { }
            .buttonStyle(MarrButtonStyle(.secondary)).disabled(true)
    }

    private var composer: some View {
        section("Native input and attachments") {
            Picker("Sample task state", selection: $status) {
                ForEach(MarrUI.Status.allCases) { Text($0.title).tag($0) }
            }
            VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
                if !attachments.isEmpty {
                    ComposerContextStrip(attachments: attachments) { id in
                        attachments.removeAll { $0.id == id }
                    }
                }
                AgentComposerEditor(text: $draft, selection: $selection, focused: $editorFocused,
                                    placeholder: "Try Chinese input, multiline text and keyboard navigation…",
                                    onKey: { _ in false }, onSubmit: submitSample)
                    .frame(minHeight: 44)
                    .accessibilityLabel("Gallery sample message")
                ViewThatFits(in: .horizontal) {
                    HStack {
                        MarrStatusLabel(status)
                        Spacer()
                        composerActions
                    }
                    VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
                        MarrStatusLabel(status)
                        HStack { composerActions }
                    }
                }
            }
            .padding(MarrUI.Spacing.medium)
            .marrSurface(.input, cornerRadius: MarrUI.Radius.composer)
            .marrAmbientGlow(isRunning: status == .running)
        }
    }

    @ViewBuilder private var composerActions: some View {
        Button("Sample attachments") { attachments = Self.sampleAttachments() }
            .buttonStyle(MarrButtonStyle(.ghost, size: .compact))
        Button("Submit sample", action: submitSample)
            .buttonStyle(MarrButtonStyle(.primary, size: .compact))
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var codeAndDiff: some View {
        section("Production code and diff readers") {
            MarrCodeBlock(code: "// 保留中文注释与缩进\nfunc greeting(name: String) -> String {\n    return \"Hello, \\(name)\"\n}", language: "swift")
            MarrDiffView(source: """
            diff --git a/Greeting.swift b/Greeting.swift
            --- a/Greeting.swift
            +++ b/Greeting.swift
            @@ -1,3 +1,3 @@
             func greeting() -> String {
            -    return "Hello"
            +    return "Hello, Marr"
             }
            """)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: MarrUI.Spacing.medium) {
            Text(title).marrTextStyle(.title).accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func submitSample() {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        feedback = "Sample accepted locally; the draft is retained."
    }

    /// Generated only on an explicit button click; no files or network are used.
    private static func sampleAttachments() -> [ConversationImageAsset] {
        let image = NSImage(size: NSSize(width: 960, height: 540), flipped: false) { rect in
            NSColor.windowBackgroundColor.setFill()
            rect.fill()
            ("Marr screenshot sample\n截图细节 / code / chart labels\n0123456789" as NSString)
                .draw(at: NSPoint(x: 36, y: 300), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 26), .foregroundColor: NSColor.labelColor
                ])
            return true
        }
        var assets = [ConversationImageAsset(data: Data("# Sample document\n\nA long filename should retain its extension.".utf8),
                                             mimeType: "text/markdown",
                                             fileName: "研究记录-with-a-long-descriptive-filename.md")]
        if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            assets.insert(ConversationImageAsset(data: png, mimeType: "image/png", fileName: "Screenshot sample.png"), at: 0)
        }
        return assets
    }
}

private enum GalleryAppearance: String, CaseIterable, Identifiable {
    case system = "System", light = "Light", dark = "Dark"
    var id: String { rawValue }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
#endif
