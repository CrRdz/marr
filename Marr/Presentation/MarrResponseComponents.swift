import MarrText
import AppKit
import SwiftUI
import MarrCore

struct MarrAttachmentPreviewButton<Content: View>: View {
    let attachment: ConversationImageAsset
    var gallery: [ConversationImageAsset] = []
    @ViewBuilder let content: () -> Content
    @State private var showsPreview = false

    var body: some View {
        Button {
            if attachment.isImage {
                MarrMediaViewer.show(attachments: gallery.isEmpty ? [attachment] : gallery, selectedID: attachment.id)
            } else {
                showsPreview = true
            }
        } label: { content() }
            .buttonStyle(.plain)
            .accessibilityLabel("Preview \(attachment.fileName)")
            .help("Preview \(attachment.fileName)")
            .popover(isPresented: $showsPreview) {
                ComposerAttachmentPreview(attachment: attachment)
            }
    }
}

/// Quiet transcript controls share a fixed hit area, without changing the
/// reading column when their icon or feedback changes.
struct MarrMessageActionButton: View {
    let title: String
    let symbol: String
    var feedback: String? = nil
    var isConfirmed = false
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    var body: some View {
        Button(action: action) {
            MarrIcon(symbol, size: MarrUI.Icon.status)
                .contentTransition(.opacity)
                .frame(width: 28, height: 28)
                .animation(MarrMotion.transition(reducesMotion: reducesMotion), value: symbol)
        }
        .buttonStyle(MarrMessageActionStyle(isConfirmed: isConfirmed))
        .help(feedback ?? title)
        .accessibilityLabel(title)
        .accessibilityValue(feedback ?? "")
    }
}

private struct MarrMessageActionStyle: ButtonStyle {
    var isConfirmed = false

    func makeBody(configuration: Configuration) -> some View {
        ActionSurface(configuration: configuration, isConfirmed: isConfirmed)
    }

    private struct ActionSurface: View {
        let configuration: ButtonStyle.Configuration
        let isConfirmed: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reducesMotion
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.colorSchemeContrast) private var contrast
        @State private var isHovered = false

        private var shape: RoundedRectangle {
            RoundedRectangle(cornerRadius: MarrUI.Radius.control, style: .continuous)
        }
        private var foreground: Color {
            if isConfirmed { return .accentColor }
            return isHovered || isFocused || contrast == .increased
                ? MarrPanelColors.primary(for: colorScheme)
                : MarrPanelColors.secondary(for: colorScheme)
        }

        var body: some View {
            configuration.label
                .foregroundStyle(foreground)
                .background(MarrPanelColors.primary(for: colorScheme)
                    .opacity(configuration.isPressed ? 0.10 : isHovered ? 0.055 : 0), in: shape)
                .contentShape(shape)
                .overlay {
                    if isFocused {
                        shape.strokeBorder(Color.accentColor, lineWidth: 1.5)
                            .allowsHitTesting(false)
                    }
                }
                .opacity(isEnabled ? 1 : 0.4)
                .scaleEffect(configuration.isPressed && !reducesMotion ? 0.94 : 1)
                .onHover { isHovered = $0 }
                .animation(MarrMotion.press(reducesMotion: reducesMotion), value: configuration.isPressed)
                .animation(MarrMotion.transition(reducesMotion: reducesMotion), value: isHovered)
        }
    }
}

struct MarrMessageActions: View {
    let text: String
    var copyTitle = "Copy response"
    var onEdit: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: MarrUI.Spacing.tight) {
            MarrCopyButton(text: text, accessibilityName: copyTitle)
            if let onEdit {
                MarrMessageActionButton(title: "Edit and regenerate", symbol: "pencil", action: onEdit)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Message actions")
    }
}

struct MarrCopyButton: View {
    let text: String
    var accessibilityName = "Copy response"
    @State private var feedback: String?
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        MarrMessageActionButton(
            title: accessibilityName,
            symbol: feedback == "Copied" ? "checkmark" : feedback == nil ? "doc.on.doc" : "exclamationmark",
            feedback: feedback,
            isConfirmed: feedback == "Copied"
        ) {
            resetTask?.cancel()
            NSPasteboard.general.clearContents()
            feedback = NSPasteboard.general.setString(text, forType: .string) ? "Copied" : "Try again"
            resetTask = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                feedback = nil
            }
        }
        .disabled(text.isEmpty)
        .onDisappear {
            resetTask?.cancel()
            resetTask = nil
            feedback = nil
        }
    }
}

struct MarrCodeBlock: View {
    let code: String
    let language: String?
    var compact = false
    var filename: String? = nil
    var initiallyShowsLineNumbers = false
    @State private var showsLineNumbers = false
    @State private var preview = MarrCodePreview("")
    @State private var highlighted = AttributedString("")
    @State private var lineNumbers = ""
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.marrAccessibilityOverrides) private var accessibilityOverrides

    private var header: MarrCodeHeader { MarrCodeHeader(language: language, filename: filename) }
    private var renderKey: RenderKey {
        RenderKey(code: code, language: header.language, dark: colorScheme == .dark,
                  highContrast: accessibilityOverrides?.increasedContrast ?? (contrast == .increased))
    }
    private var leading: CGFloat { compact ? 3 : MarrTypography.Reading.codeLeading }

    private struct RenderKey: Hashable, Sendable {
        let code: String
        let language: String?
        let dark: Bool
        let highContrast: Bool
    }

    /// Build the attributed value once per source/appearance, off the main
    /// actor. Body updates (hover, copy feedback, line numbers) reuse it.
    private struct RenderedCode: Sendable {
        let preview: MarrCodePreview
        let highlighted: AttributedString
        let lineNumbers: String

        nonisolated static func make(_ input: RenderKey) -> Self? {
            guard !Task.isCancelled else { return nil }
            let preview = MarrCodePreview(input.code, isCancelled: { Task.isCancelled })
            guard !Task.isCancelled else { return nil }
            var text = AttributedString(preview.text)
            if !input.highContrast {
                let tokens = MarrCodeHighlighter.tokens(preview.text, language: input.language,
                                                        isCancelled: { Task.isCancelled })
                for token in tokens where token.kind != .plain {
                    guard !Task.isCancelled else { return nil }
                    guard let range = Range(token.range, in: preview.text),
                          let attributedRange = Range(range, in: text) else { continue }
                    let color: Color
                    switch token.kind {
                    case .keyword: color = input.dark ? Color(red: 0.85, green: 0.68, blue: 0.97) : Color(red: 0.47, green: 0.20, blue: 0.62)
                    case .string: color = input.dark ? Color(red: 0.67, green: 0.83, blue: 0.59) : Color(red: 0.20, green: 0.40, blue: 0.15)
                    case .comment: color = .secondary
                    case .number: color = input.dark ? Color(red: 0.96, green: 0.77, blue: 0.53) : Color(red: 0.53, green: 0.30, blue: 0.08)
                    case .plain: color = .primary
                    }
                    text[attributedRange].foregroundColor = color
                }
            }
            guard !Task.isCancelled else { return nil }
            let numbers = preview.lineCount > 0 ? (1...preview.lineCount).map(String.init).joined(separator: "\n") : ""
            return Self(preview: preview, highlighted: text, lineNumbers: numbers)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: MarrUI.Spacing.regular) {
                Text(header.filename ?? header.language ?? "Code")
                    .marrTextStyle(.caption, weight: .medium)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(header.filename ?? header.language ?? "Code")
                if header.filename != nil, let language = header.language {
                    Text(language).marrTextStyle(.badge).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                MarrMessageActionButton(title: showsLineNumbers ? "Hide line numbers" : "Show line numbers", symbol: "list.number",
                                        isConfirmed: showsLineNumbers) { showsLineNumbers.toggle() }
                    .accessibilityValue(showsLineNumbers ? "Shown" : "Hidden")
                MarrCopyButton(text: code, accessibilityName: "Copy code")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            Divider()
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: MarrUI.Spacing.medium) {
                    if showsLineNumbers, preview.lineCount > 0 {
                        Text(lineNumbers)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    Text(highlighted)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .font(.system(size: compact ? MarrTypography.Role.code.size : MarrTypography.Reading.codeSize,
                              design: .monospaced))
                .lineSpacing(leading)
                .padding(10)
            }
            if preview.isTruncated {
                Text("Preview limited for this large code block. Copy includes the complete code.")
                    .marrTextStyle(.caption).foregroundStyle(.secondary)
                    .padding(MarrUI.Spacing.regular)
            }
        }
        .marrSurface(.card)
        .onAppear { showsLineNumbers = initiallyShowsLineNumbers }
        .task(id: renderKey) {
            let input = renderKey
            let worker = Task.detached(priority: .userInitiated) { RenderedCode.make(input) }
            let rendered = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, let rendered else { return }
            preview = rendered.preview
            highlighted = rendered.highlighted
            lineNumbers = rendered.lineNumbers
        }
    }
}

enum MarrDiffLayoutMode { case unified, sideBySide }

struct MarrDiffView: View {
    let source: String
    @State private var document = MarrDiffDocument("")
    @State private var width: CGFloat = 0
    @State private var prefersSplit: Bool

    init(source: String, initialMode: MarrDiffLayoutMode = .unified) {
        self.source = source
        _prefersSplit = State(initialValue: initialMode == .sideBySide)
    }

    private var supportsSplit: Bool { width >= 680 }

    var body: some View {
        VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
            HStack {
                Text("File changes").marrTextStyle(.secondary, weight: .medium)
                Spacer()
                if supportsSplit {
                    Picker("Diff layout", selection: $prefersSplit) {
                        Text("Unified").tag(false)
                        Text("Side by side").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 190)
                    .accessibilityLabel("Diff layout")
                }
                MarrCopyButton(text: source, accessibilityName: "Copy complete diff")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
                    ForEach(document.files) { file in
                        MarrDiffFileView(file: file, initiallyExpanded: document.files.count == 1 || file.id == 0,
                                         split: supportsSplit && prefersSplit, availableWidth: max(0, width - 16))
                    }
                    if document.isTruncated {
                        Text("Preview limited for this large diff. Copy includes the complete diff.")
                            .marrTextStyle(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxHeight: 300)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .task(id: source) {
            let source = source
            let worker = Task.detached(priority: .userInitiated) {
                MarrDiffDocument(source, isCancelled: { Task.isCancelled })
            }
            let parsed = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled else { return }
            document = parsed
        }
    }
}

private struct MarrDiffFileView: View {
    let file: MarrDiffFile
    let split: Bool
    let availableWidth: CGFloat
    @State private var isExpanded: Bool
    @State private var splitLayout = SplitLayout(rows: [], left: 0, right: 0)
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private struct LayoutKey: Equatable {
        let file: MarrDiffFile
        let active: Bool
    }

    private struct SplitLayout: Sendable {
        let rows: [MarrDiffSplitRow]
        let left: CGFloat
        let right: CGFloat

        nonisolated static func make(_ file: MarrDiffFile) -> Self? {
            guard !Task.isCancelled else { return nil }
            let rows = MarrDiffPairing.rows(file.lines, isCancelled: { Task.isCancelled })
            let font = NSFont.monospacedSystemFont(ofSize: MarrTypography.Role.code.size, weight: .regular)
            var left: CGFloat = 0
            var right: CGFloat = 0
            for line in file.lines {
                guard !Task.isCancelled else { return nil }
                guard [.context, .addition, .deletion].contains(line.kind) else { continue }
                let width = (String(line.text.dropFirst()) as NSString).size(withAttributes: [.font: font]).width
                if line.kind != .addition { left = max(left, width) }
                if line.kind != .deletion { right = max(right, width) }
            }
            return Self(rows: rows, left: ceil(left) + 68, right: ceil(right) + 68)
        }
    }

    init(file: MarrDiffFile, initiallyExpanded: Bool, split: Bool, availableWidth: CGFloat) {
        self.file = file
        self.split = split
        self.availableWidth = availableWidth
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ScrollView(.horizontal) {
                if split { splitContent } else { unifiedContent }
            }
        } label: {
            HStack(spacing: MarrUI.Spacing.regular) {
                Text(file.path).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text("+\(file.additions)").foregroundStyle(.green)
                Text("−\(file.deletions)").foregroundStyle(.red)
            }
            .marrTextStyle(.secondary)
            .monospacedDigit()
            .help(file.path)
        }
        .padding(MarrUI.Spacing.regular)
        .marrSurface(.card, cornerRadius: MarrUI.Radius.control)
        .animation(MarrMotion.disclosure(reducesMotion: reducesMotion), value: isExpanded)
        .task(id: LayoutKey(file: file, active: split && isExpanded)) {
            guard split && isExpanded else { return }
            let input = file
            let worker = Task.detached(priority: .userInitiated) { SplitLayout.make(input) }
            let layout = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, let layout else { return }
            splitLayout = layout
        }
    }

    private var unifiedContent: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(file.lines) { line in
                HStack(alignment: .firstTextBaseline, spacing: MarrUI.Spacing.regular) {
                    lineNumber(line.oldLine)
                    lineNumber(line.newLine)
                    Text(verbatim: line.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .marrTextStyle(.code)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(background(for: line.kind))
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var splitContent: some View {
        // Measure only when this file changes or split mode opens. Resizing,
        // hovering and copy feedback reuse rows and intrinsic column widths.
        let leftWidth = max((availableWidth - 1) / 2, splitLayout.left)
        let rightWidth = max((availableWidth - 1) / 2, splitLayout.right)
        return LazyVStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("Before").frame(width: leftWidth, alignment: .leading)
                Text("After").frame(width: rightWidth, alignment: .leading)
            }
            .marrTextStyle(.caption, weight: .medium)
            .foregroundStyle(.secondary)
            .padding(.vertical, MarrUI.Spacing.small)
            ForEach(splitLayout.rows) { row in
                if let shared = row.shared {
                    Text(verbatim: shared.text)
                        .marrTextStyle(.code)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .frame(minWidth: leftWidth + rightWidth, alignment: .leading)
                        .background(background(for: shared.kind))
                } else {
                    HStack(alignment: .top, spacing: 0) {
                        splitCell(row.left, old: true, width: leftWidth)
                        splitCell(row.right, old: false, width: rightWidth)
                    }
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func splitCell(_ line: MarrDiffLine?, old: Bool, width: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: MarrUI.Spacing.regular) {
            lineNumber(old ? line?.oldLine : line?.newLine)
            Text(verbatim: line.map(displayText) ?? " ")
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
        }
        .marrTextStyle(.code)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .frame(width: width, alignment: .leading)
        .background(line.map { background(for: $0.kind) } ?? .clear)
        .overlay(alignment: .trailing) {
            if old { Rectangle().fill(MarrUI.Border.color(.subtle, increasedContrast: contrast == .increased)).frame(width: 0.75).accessibilityHidden(true) }
        }
    }

    private func lineNumber(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .monospacedDigit()
            .frame(width: 36, alignment: .trailing)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }

    private func displayText(_ line: MarrDiffLine) -> String {
        // The unified view retains +/- prefixes; each split column already
        // identifies the side, so remove only that one presentation prefix.
        [.context, .addition, .deletion].contains(line.kind) ? String(line.text.dropFirst()) : line.text
    }

    private func background(for kind: MarrDiffLine.Kind) -> Color {
        switch kind {
        case .addition: .green.opacity(0.10)
        case .deletion: .red.opacity(0.09)
        case .hunk: .accentColor.opacity(0.08)
        default: .clear
        }
    }
}

/// Shared sizing keeps imported Work images and local conversation images aligned.
struct MarrUserImagePreview: View {
    static let maximumWidth: CGFloat = 280
    static let maximumHeight: CGFloat = 420
    let image: NSImage

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .frame(maxWidth: Self.maximumWidth, maxHeight: Self.maximumHeight, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
