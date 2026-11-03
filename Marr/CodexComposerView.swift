import AppKit
import SwiftUI

enum CodexComposerKey: Equatable { case up, down, complete, accept, dismiss }

/// A native editor keeps completion at the insertion point and leaves marked
/// text to the input method. SwiftUI's multiline TextField hides both states.
struct CodexComposerEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    @Binding var focused: Bool
    let placeholder: String
    var onKey: (CodexComposerKey) -> Bool
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        let editor = CodexInputTextView()
        editor.isRichText = false
        editor.drawsBackground = false
        editor.isEditable = true
        editor.isSelectable = true
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainerInset = NSSize(width: 0, height: 5)
        editor.font = .systemFont(ofSize: 14)
        editor.textColor = .labelColor
        editor.insertionPointColor = .labelColor
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.allowsUndo = true
        editor.delegate = context.coordinator
        editor.requestedFocus = { [weak coordinator = context.coordinator] in
            coordinator?.parent.focused ?? false
        }
        editor.onWindowAttachmentChanged = { [weak coordinator = context.coordinator] isAttached in
            coordinator?.isAttached = isAttached
        }
        editor.setAccessibilityLabel("Work message")
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? CodexInputTextView else { return }
        context.coordinator.parent = self
        context.coordinator.updating = true
        editor.placeholder = placeholder
        editor.onKey = onKey
        editor.onSubmit = onSubmit
        if !editor.hasMarkedText() {
            if editor.string != text { editor.string = text }
            let location = min(selection.location, (text as NSString).length)
            let length = min(selection.length, (text as NSString).length - location)
            let range = NSRange(location: location, length: length)
            if editor.selectedRange() != range { editor.setSelectedRange(range) }
        }
        editor.needsDisplay = true
        editor.applyRequestedFocus()
        context.coordinator.updating = false
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.isAttached = false
        guard let editor = scroll.documentView as? CodexInputTextView else { return }
        editor.delegate = nil
        editor.requestedFocus = nil
        editor.onWindowAttachmentChanged = nil
        editor.onKey = nil
        editor.onSubmit = nil
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? 400
        guard let editor = nsView.documentView as? NSTextView,
              let container = editor.textContainer, let layout = editor.layoutManager else {
            return CGSize(width: width, height: 30)
        }
        container.containerSize = NSSize(width: max(40, width), height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: min(94, max(30, ceil(layout.usedRect(for: container).height) + 10)))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodexComposerEditor
        var updating = false
        var isAttached = false
        init(_ parent: CodexComposerEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard !updating, let editor = notification.object as? CodexInputTextView else { return }
            parent.text = editor.string
            parent.selection = editor.selectedRange()
            editor.needsDisplay = true
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !updating, let editor = notification.object as? CodexInputTextView else { return }
            parent.selection = editor.selectedRange()
        }
        func textDidBeginEditing(_ notification: Notification) {
            if !updating, isAttached { parent.focused = true }
        }
        func textDidEndEditing(_ notification: Notification) {
            guard !updating, isAttached, let editor = notification.object as? CodexInputTextView else { return }
            // AppKit can emit this before updating firstResponder. An outgoing
            // editor must not clear the replacement composer's shared binding.
            DispatchQueue.main.async { [weak self, weak editor] in
                guard let self, let editor, self.isAttached, !self.updating,
                      let window = editor.window,
                      window.firstResponder !== editor,
                      !(window.firstResponder is CodexInputTextView) else { return }
                self.parent.focused = false
            }
        }
    }
}

final class CodexInputTextView: NSTextView {
    var placeholder = ""
    var onKey: ((CodexComposerKey) -> Bool)?
    var onSubmit: (() -> Void)?
    var requestedFocus: (() -> Bool)?
    var onWindowAttachmentChanged: ((Bool) -> Void)?

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { onWindowAttachmentChanged?(false) }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowAttachmentChanged?(window != nil)
        applyRequestedFocus()
    }

    func applyRequestedFocus() {
        guard let window, let requestedFocus else { return }
        if requestedFocus() {
            if window.firstResponder !== self { window.makeFirstResponder(self) }
        } else if window.firstResponder === self {
            window.makeFirstResponder(nil)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            (placeholder as NSString).draw(at: NSPoint(x: textContainerInset.width, y: textContainerInset.height),
                withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.placeholderTextColor])
        }
    }

    override func keyDown(with event: NSEvent) {
        // Return/Escape and arrow keys must first belong to an active IME.
        if hasMarkedText() { super.keyDown(with: event); return }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let plain = modifiers.intersection([.command, .control, .option, .shift]).isEmpty
        switch event.keyCode {
        case 126 where plain: if onKey?(.up) == true { return }
        case 125 where plain: if onKey?(.down) == true { return }
        case 48 where plain: if onKey?(.complete) == true { return }
        case 53 where plain: if onKey?(.dismiss) == true { return }
        case 36, 76:
            if modifiers.contains(.shift) || modifiers.contains(.option) {
                insertNewlineIgnoringFieldEditor(self)
                return
            }
            if plain, onKey?(.accept) == true { return }
            if plain || modifiers.contains(.command) { onSubmit?(); return }
        default: break
        }
        super.keyDown(with: event)
    }
}

struct CodexCompletionOption: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    var enabled = true
    var section = ""
    var source = ""
    var showsDisclosure = false
    var helpText = ""
}

extension CodexCompletionOption {
    static func readableName(_ value: String) -> String {
        let parts = value.split(separator: ":").map(String.init)
        let names = parts.count == 2 && parts[0] == parts[1] ? [parts[1]] : parts
        return names.map { part in
            part.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
                .split(separator: " ").map { word in
                    let special = ["mcp": "MCP", "ui": "UI", "ux": "UX", "pdf": "PDF", "openai": "OpenAI", "figma": "Figma"]
                    return special[word.lowercased()] ?? word.prefix(1).uppercased() + word.dropFirst()
                }.joined(separator: " ")
        }.joined(separator: ": ")
    }

    static func summary(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func skill(_ skill: CodexSkill) -> Self {
        let title = skill.displayName == skill.name ? readableName(skill.name) : skill.displayName
        let plugin = skill.name.split(separator: ":").count > 1 ? skill.name.split(separator: ":").first.map(String.init) : nil
        let source = plugin.map { "From " + readableName($0) } ?? (skill.scope == "repo" ? "Project" : "Local file")
        return Self(id: skill.path, title: title, detail: summary(skill.shortDescription), symbol: "shippingbox",
                    source: source, helpText: "$" + skill.name + "\n" + skill.description + "\n" + skill.path)
    }

    static func command(_ candidate: CodexComposerCandidate) -> Self {
        let presentation: [String: (String, String)] = [
            "model": ("Model", "cpu"), "skills": ("Skills", "shippingbox"),
            "review": ("Code review", "checklist"), "rename": ("Rename", "pencil"),
            "new": ("New chat", "square.and.pencil"), "archive": ("Archive", "archivebox"),
            "resume": ("Resume chat", "clock"), "fork": ("Fork chat", "arrow.triangle.branch"),
            "compact": ("Compact", "circle.lefthalf.filled"), "config": ("Settings", "gearshape"),
            "plan": ("Plan mode", "lightbulb"), "goal": ("Goal", "target"),
            "copy": ("Copy reply", "doc.on.doc"), "export": ("Export", "square.and.arrow.up"),
            "diff": ("Changes", "doc.text.magnifyingglass"), "mention": ("Files and folders", "paperclip"),
            "status": ("Status", "info.circle"), "warnings": ("Diagnostics", "exclamationmark.triangle"),
            "pwd": ("Working directory", "folder"), "theme": ("Appearance", "circle.lefthalf.filled"),
            "mcp": ("MCP", "point.3.connected.trianglepath.dotted"), "apps": ("Apps", "square.grid.2x2"),
            "plugins": ("Plugins", "puzzlepiece.extension"), "clear": ("Clear chat", "eraser"),
            "help": ("Help", "questionmark.circle"), "default": ("Exit plan mode", "lightbulb.slash")
        ]
        let entry = presentation[candidate.id] ?? (readableName(candidate.id), "command")
        return Self(id: candidate.id, title: entry.0,
            detail: candidate.disabledReason ?? summary(candidate.detail), symbol: entry.1,
            enabled: candidate.isEnabled,
            showsDisclosure: ["model", "skills", "plugins", "apps", "mcp", "config", "theme", "goal", "resume"].contains(candidate.id),
            helpText: candidate.insertion + "\n" + candidate.detail + (candidate.disabledReason.map { "\n" + $0 } ?? ""))
    }
}

enum CodexCompletionLayout {
    static let rowHeight: CGFloat = 30
    static let sectionHeight: CGFloat = 26
    static let inset: CGFloat = 5

    static func contentHeight(_ options: [CodexCompletionOption]) -> CGFloat {
        var previous = ""
        return options.reduce(0) { height, option in
            let section = !option.section.isEmpty && option.section != previous
            previous = option.section
            return height + rowHeight + (section ? sectionHeight : 0)
        }
    }

    /// Disabled results remain inspectable, but arrow keys only visit actions
    /// that can actually be accepted.
    static func nextIndex(from index: Int, by offset: Int, options: [CodexCompletionOption]) -> Int {
        guard !options.isEmpty else { return 0 }
        for step in 1...options.count {
            let next = ((index + offset * step) % options.count + options.count) % options.count
            if options[next].enabled { return next }
        }
        return 0
    }
}

struct CodexCompletionPanel: View {
    let title: String
    let options: [CodexCompletionOption]
    @Binding var selectedIndex: Int
    var isLoading = false
    var emptyMessage = "No matches"
    var maxHeight: CGFloat = 320
    var onSelect: (CodexCompletionOption) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var lastPointerPosition: NSPoint?

    // Opaque, resolved colors prevent the window's glass vibrancy from turning
    // secondary labels or SF Symbols white inside this solid suggestion menu.
    private var labelColor: Color { Color(white: colorScheme == .dark ? 0.90 : 0.18) }
    private var secondaryColor: Color { Color(white: colorScheme == .dark ? 0.64 : contrast == .increased ? 0.32 : 0.44) }
    private var surfaceColor: Color { Color(white: colorScheme == .dark ? 0.13 : 1) }

    private var listHeight: CGFloat {
        min(max(30, maxHeight - CodexCompletionLayout.inset * 2),
            options.isEmpty ? 48 : CodexCompletionLayout.contentHeight(options))
    }

    var body: some View {
        GeometryReader { geometry in
            Group {
                if options.isEmpty {
                    HStack(spacing: 8) {
                        if isLoading { ProgressView().controlSize(.small) }
                        Text(isLoading ? "Searching…" : emptyMessage)
                            .font(.system(size: 12)).foregroundStyle(secondaryColor)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                } else {
                    ScrollViewReader { reader in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                                    if !option.section.isEmpty && (index == 0 || options[index - 1].section != option.section) {
                                        Text(option.section)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(secondaryColor)
                                            .padding(.horizontal, 10)
                                            .frame(height: CodexCompletionLayout.sectionHeight, alignment: .center)
                                    }
                                    row(option, index: index, width: geometry.size.width)
                                        .id(option.id)
                                }
                            }
                        }
                        .scrollIndicators(.never)
                        .onChange(of: selectedIndex) { _, value in
                            lastPointerPosition = NSEvent.mouseLocation
                            if options.indices.contains(value) {
                                // A nil anchor scrolls only enough to reveal the row.
                                reader.scrollTo(options[value].id)
                            }
                        }
                        .onChange(of: options.map(\.id)) { _, _ in
                            if options.indices.contains(selectedIndex) {
                                reader.scrollTo(options[selectedIndex].id, anchor: .top)
                            }
                        }
                    }
                }
            }
        }
        .frame(height: listHeight)
        .padding(CodexCompletionLayout.inset)
        .background(surfaceColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(labelColor.opacity(contrast == .increased ? 0.32 : 0.08), lineWidth: 1))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.18 : 0.06), radius: 10, x: 0, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .help("↑ ↓ to navigate · Tab to complete · Return to select · Esc to dismiss")
    }

    private func row(_ option: CodexCompletionOption, index: Int, width: CGFloat) -> some View {
        let measuredTitle = ceil((option.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width) + 1
        let titleWidth = min(measuredTitle, max(60, (width - 44) * (option.detail.isEmpty ? 0.9 : 0.60)))
        return Button { if option.enabled { onSelect(option) } } label: {
            HStack(spacing: 8) {
                Image(systemName: option.symbol)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(secondaryColor)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(option.title)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(option.enabled ? labelColor : secondaryColor)
                    .lineLimit(1)
                    .truncationMode(option.symbol == "doc.text" ? .middle : .tail)
                    .frame(width: titleWidth, alignment: .leading)
                Text(option.detail)
                    .font(.system(size: 13))
                    .foregroundStyle(secondaryColor)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !option.source.isEmpty, width >= 480 {
                    Text(option.source)
                        .font(.system(size: 12)).foregroundStyle(secondaryColor)
                        .lineLimit(1).frame(maxWidth: 110, alignment: .trailing)
                }
                if option.showsDisclosure {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(secondaryColor)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: CodexCompletionLayout.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(index == selectedIndex ? labelColor.opacity(contrast == .increased ? 0.16 : 0.055) : .clear,
                        in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!option.enabled)
        .onContinuousHover { phase in
            guard case .active = phase, option.enabled else { return }
            // A stationary pointer must not undo keyboard navigation as rows scroll.
            let position = NSEvent.mouseLocation
            guard position != lastPointerPosition else { return }
            lastPointerPosition = position
            selectedIndex = index
        }
        .help(option.helpText.isEmpty ? [option.title, option.detail, option.source].filter { !$0.isEmpty }.joined(separator: "\n") : option.helpText)
        .accessibilityLabel([option.title, option.detail, option.source].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityIdentifier("completion-" + option.id)
        .accessibilityAddTraits(index == selectedIndex ? .isSelected : [])
    }
}

struct CodexGoalEditor: View {
    @ObservedObject var workspace: CodexWorkspaceController
    @Environment(\.dismiss) private var dismiss
    @State private var objective = ""
    @State private var edited = false
    @State private var submittedObjective: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Task goal", systemImage: "target").font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Set the outcome Codex should keep working toward. You can pause, resume, or clear it here.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            if let goal = workspace.threadGoal {
                HStack {
                    Text(goal.status.capitalized).fontWeight(.medium)
                    Spacer()
                    Text("\(goal.tokensUsed.formatted()) tokens used").foregroundStyle(.secondary)
                }.font(.system(size: 12))
            }
            Text("Objective").font(.system(size: 13, weight: .medium))
            TextEditor(text: Binding(get: { objective }, set: { objective = $0; edited = true }))
                .font(.system(size: 14))
                .frame(height: 120).padding(6)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.25)))
                .accessibilityLabel("Goal objective")
            if !workspace.commandOutput.isEmpty {
                ScrollView { Text(workspace.commandOutput).font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 75)
            }
            HStack {
                if let goal = workspace.threadGoal {
                    Button(goal.status == "active" ? "Pause" : "Resume") {
                        _ = workspace.executeSlashCommand(goal.status == "active" ? "/goal pause" : "/goal resume")
                    }
                    Button("Clear goal", role: .destructive) { _ = workspace.executeSlashCommand("/goal clear") }
                }
                Spacer()
                Button("Set goal") {
                    if workspace.setThreadGoal(objective: objective) {
                        submittedObjective = objective.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22).frame(width: 500)
        .onAppear { objective = workspace.threadGoal?.objective ?? "" }
        .onChange(of: workspace.threadGoal) { _, goal in
            // Enqueueing is not confirmation: a late get response must not replace
            // a new objective, nor edits made while a set request is pending.
            if let submittedObjective, goal?.objective == submittedObjective {
                if objective.trimmingCharacters(in: .whitespacesAndNewlines) == submittedObjective { edited = false }
                self.submittedObjective = nil
            }
            if !edited { objective = goal?.objective ?? "" }
        }
    }
}
