import AppKit
import SwiftUI

struct AgentCompletionOption: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    var enabled = true
    var section = ""
    var source = ""
    var showsDisclosure = false
    var helpText = ""
    var providerIconName: String? = nil
    var providerTag = ""
}

extension AgentCompletionOption {
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

    static func command(_ candidate: AgentComposerCandidate) -> Self {
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

enum AgentCompletionLayout {
    static let rowHeight: CGFloat = 30
    static let sectionHeight: CGFloat = 26
    static let inset: CGFloat = 5

    static func contentHeight(_ options: [AgentCompletionOption]) -> CGFloat {
        var previous = ""
        return options.reduce(0) { height, option in
            let section = !option.section.isEmpty && option.section != previous
            previous = option.section
            return height + rowHeight + (section ? sectionHeight : 0)
        }
    }

    /// Disabled results remain inspectable, but arrow keys only visit actions
    /// that can actually be accepted.
    static func nextIndex(from index: Int, by offset: Int, options: [AgentCompletionOption]) -> Int {
        guard !options.isEmpty else { return 0 }
        for step in 1...options.count {
            let next = ((index + offset * step) % options.count + options.count) % options.count
            if options[next].enabled { return next }
        }
        return 0
    }
}

struct AgentCompletionPanel: View {
    let title: String
    let options: [AgentCompletionOption]
    @Binding var selectedIndex: Int
    var isLoading = false
    var emptyMessage = "No matches"
    var maxHeight: CGFloat = 320
    var onSelect: (AgentCompletionOption) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var lastPointerPosition: NSPoint?

    // Opaque, resolved colors prevent the window's glass vibrancy from turning
    // secondary labels or SF Symbols white inside this solid suggestion menu.
    private var labelColor: Color { Color(white: colorScheme == .dark ? 0.90 : 0.18) }
    private var secondaryColor: Color { Color(white: colorScheme == .dark ? 0.64 : contrast == .increased ? 0.32 : 0.44) }
    private var surfaceColor: Color { Color(white: colorScheme == .dark ? 0.13 : 1) }

    private var listHeight: CGFloat {
        min(max(30, maxHeight - AgentCompletionLayout.inset * 2),
            options.isEmpty ? 48 : AgentCompletionLayout.contentHeight(options))
    }

    var body: some View {
        GeometryReader { geometry in
            Group {
                if options.isEmpty {
                    HStack(spacing: MarrUI.Spacing.regular) {
                        if isLoading { ProgressView().controlSize(.small) }
                        Text(isLoading ? "Searching…" : emptyMessage)
                            .font(MarrTypography.font(.secondary)).foregroundStyle(secondaryColor)
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
                                            .font(MarrTypography.font(.secondary, weight: .medium))
                                            .foregroundStyle(secondaryColor)
                                            .padding(.horizontal, 10)
                                            .frame(height: AgentCompletionLayout.sectionHeight, alignment: .center)
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
        .padding(AgentCompletionLayout.inset)
        .background(surfaceColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(labelColor.opacity(contrast == .increased ? 0.32 : 0.08), lineWidth: 1))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.18 : 0.06), radius: 10, x: 0, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .help("↑ ↓ to navigate · Tab to complete · Return to select · Esc to dismiss")
    }

    private func row(_ option: AgentCompletionOption, index: Int, width: CGFloat) -> some View {
        let measuredTitle = ceil((option.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: MarrTypography.Role.body.size)]).width) + 1
        let titleWidth = min(measuredTitle, max(60, (width - 44) * (option.detail.isEmpty ? 0.9 : 0.60)))
        return Button { if option.enabled { onSelect(option) } } label: {
            HStack(spacing: MarrUI.Spacing.regular) {
                MarrIcon(option.symbol, size: MarrUI.Icon.inline)
                    .foregroundStyle(secondaryColor)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(option.title)
                    .font(MarrTypography.font(.body, weight: .regular))
                    .foregroundStyle(option.enabled ? labelColor : secondaryColor)
                    .lineLimit(1)
                    .truncationMode(option.symbol == "doc.text" ? .middle : .tail)
                    .frame(width: titleWidth, alignment: .leading)
                Text(option.detail)
                    .font(MarrTypography.font(.body))
                    .foregroundStyle(secondaryColor)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !option.source.isEmpty, width >= 480 {
                    Text(option.source)
                        .font(MarrTypography.font(.secondary)).foregroundStyle(secondaryColor)
                        .lineLimit(1).frame(maxWidth: 110, alignment: .trailing)
                }
                if option.showsDisclosure {
                    MarrIcon("chevron.right", size: MarrUI.Icon.disclosure).foregroundStyle(secondaryColor)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: AgentCompletionLayout.rowHeight)
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
