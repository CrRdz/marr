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

enum MarrReasoningOptions {
    static func ordered(_ efforts: [String]) -> [String] {
        let order = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
        return Set(efforts.filter { !$0.isEmpty }).sorted {
            let lhs = order.firstIndex(of: $0) ?? order.count
            let rhs = order.firstIndex(of: $1) ?? order.count
            return lhs == rhs ? $0 < $1 : lhs < rhs
        }
    }

    static func label(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "Automatic" }
        if value == "xhigh" { return "Extra high" }
        return value.capitalized
    }
}

/// One quiet composer control; speed is a state inside the model summary.
struct MarrModelControlLabel: View {
    let name: String
    let effort: String?
    var fastMode: Bool? = nil
    var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @AppStorage(MarrAccentColor.storageKey) private var accentColor = MarrAccentColor.system.rawValue

    private var accent: Color {
        let selected = MarrAccentColor.resolve(accentColor)
        return selected == .system ? .primary : selected.color
    }

    var body: some View {
        MarrHoverRegion { hovered in
            HStack(spacing: MarrUI.Spacing.small) {
                ViewThatFits(in: .horizontal) {
                    if let effort, !effort.isEmpty {
                        (Text(displayName).fontWeight(.medium)
                         + Text(" · " + MarrReasoningOptions.label(effort)).foregroundColor(.secondary))
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    Text(displayName).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                }
                if let fastMode {
                    Image(systemName: fastMode ? "bolt.fill" : "bolt")
                        .font(.system(size: MarrUI.Icon.disclosure, weight: .medium))
                        .foregroundStyle(fastMode ? accent : .secondary)
                        .frame(width: 18, height: 18)
                        .accessibilityHidden(true)
                }
                MarrIcon("chevron.down", size: MarrUI.Icon.disclosure)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0)).accessibilityHidden(true)
            }
            .marrTextStyle(.secondary)
            .padding(.horizontal, MarrUI.Spacing.small)
            .padding(.vertical, 5)
            .background(.primary.opacity(isExpanded ? 0.08 : hovered ? 0.05 : 0),
                        in: RoundedRectangle(cornerRadius: MarrUI.Radius.control))
            .animation(MarrMotion.transition(reducesMotion: reducesMotion), value: isExpanded)
            .contentShape(Rectangle())
        }
    }

    private var displayName: String { name.isEmpty ? "Choose model" : name }
}

/// A compact model header with a borderless speed control above the original native
/// reasoning slider. Keep the system's thumb, focus and pointer treatment.
struct MarrModelConfigurationPanel: View {
    let models: [CodexModelOption]
    let selectedModel: String
    let efforts: [String]
    let effort: String?
    var includesAutomatic = true
    var fastMode: Bool? = nil
    var supportsFastMode = false
    var isEnabled = true
    var offersModelSelection = true
    let onSelectModel: (String) -> Void
    let onSelectEffort: (String) -> Void
    var onToggleSpeed: () -> Void = {}
    @State private var showsModels = false
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(MarrAccentColor.storageKey) private var accentColor = MarrAccentColor.system.rawValue

    private var options: [String] { (includesAutomatic ? [""] : []) + MarrReasoningOptions.ordered(efforts) }
    private var selectedEffort: String? { includesAutomatic ? (effort ?? "") : effort }
    private var effortLabel: String {
        if let selectedEffort, !selectedEffort.isEmpty, !options.contains(selectedEffort) { return "Unavailable" }
        return MarrReasoningOptions.label(effort)
    }
    private var modelName: String { models.first { $0.id == selectedModel }?.name ?? (selectedModel.isEmpty ? "Choose model" : selectedModel) }
    private var accent: Color {
        let selected = MarrAccentColor.resolve(accentColor)
        return selected == .system ? MarrPanelColors.primary(for: colorScheme) : selected.color
    }

    private var modelHeading: some View {
        HStack(spacing: MarrUI.Spacing.regular) {
            MarrIcon("square.stack", size: MarrUI.Icon.inline)
                .foregroundStyle(.secondary).accessibilityHidden(true)
            Text(modelName).lineLimit(1).truncationMode(.middle)
            if offersModelSelection {
                MarrIcon(showsModels ? "chevron.down" : "chevron.right", size: MarrUI.Icon.disclosure)
                    .foregroundStyle(.secondary).accessibilityHidden(true)
            }
            Spacer(minLength: 0)
        }
        .marrTextStyle(.body, weight: .medium)
        .frame(maxWidth: .infinity, minHeight: MarrUI.Control.regular, alignment: .leading)
        .contentShape(Rectangle())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: offersModelSelection ? MarrUI.Spacing.medium : MarrUI.Spacing.tight) {
            HStack(spacing: MarrUI.Spacing.regular) {
                if offersModelSelection {
                    Button { showsModels.toggle() } label: { modelHeading }
                        .buttonStyle(MarrButtonStyle(.ghost, size: .icon))
                        .disabled(!isEnabled || models.isEmpty)
                        .accessibilityLabel("Choose model")
                        .accessibilityValue("\(modelName), \(showsModels ? "expanded" : "collapsed")")
                        .help("Choose model · \(modelName)")
                } else {
                    HStack(spacing: MarrUI.Spacing.regular) {
                        Text("Reasoning").marrTextStyle(.caption).foregroundStyle(.secondary)
                        Text(effortLabel).marrTextStyle(.secondary, weight: .medium).lineLimit(1)
                            .accessibilityLabel("Reasoning: \(effortLabel)")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let fastMode {
                    Button(action: onToggleSpeed) {
                        Image(systemName: fastMode ? "bolt.fill" : "bolt")
                            .font(.system(size: MarrUI.Icon.inline, weight: .medium))
                            .foregroundStyle(fastMode ? accent : MarrPanelColors.secondary(for: colorScheme))
                    }
                    .buttonStyle(MarrButtonStyle(.ghost, size: .icon,
                                                foregroundColor: fastMode ? accent : MarrPanelColors.secondary(for: colorScheme)))
                    .disabled(!isEnabled || !supportsFastMode)
                    .help(supportsFastMode ? "Speed: \(fastMode ? "Fast" : "Standard"). Fast uses more plan allowance." : "Fast mode is unavailable for this model")
                    .accessibilityLabel("Speed mode")
                    .accessibilityValue(fastMode ? "Fast" : "Standard")
                    .accessibilityAddTraits(fastMode ? .isSelected : [])
                }

            }
            if offersModelSelection && showsModels {
                MarrModelOptionsList(models: models, selectedModel: selectedModel, isEnabled: isEnabled) {
                    onSelectModel($0)
                    showsModels = false
                }
                .marrTextStyle(.body)
            }
            VStack(spacing: MarrUI.Spacing.tight) {
                if offersModelSelection {
                    HStack(spacing: MarrUI.Spacing.small) {
                        Text("Reasoning").marrTextStyle(.secondary).foregroundStyle(.secondary)
                        Spacer(minLength: MarrUI.Spacing.regular)
                        Text(effortLabel).marrTextStyle(.secondary, weight: .medium).lineLimit(1)
                            .accessibilityLabel("Reasoning: \(effortLabel)")
                    }
                }
                if options.count > 1 {
                    if let selectedEffort, options.contains(selectedEffort) {
                        MarrReasoningTickSlider(options: options, selection: selectedEffort,
                                                onSelect: onSelectEffort)
                            .frame(height: MarrUI.Control.compact)
                            .disabled(!isEnabled)
                        HStack {
                            Text(MarrReasoningOptions.label(options.first))
                            Spacer()
                            Text(MarrReasoningOptions.label(options.last))
                        }
                        .marrTextStyle(.caption).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    } else {
                        Menu("Choose reasoning level") {
                            ForEach(options, id: \.self) { option in
                                Button(MarrReasoningOptions.label(option)) { onSelectEffort(option) }
                            }
                        }
                        .disabled(!isEnabled)
                    }
                }
            }

        }
        .padding(.horizontal, MarrUI.Spacing.medium)
        .padding(.vertical, offersModelSelection ? MarrUI.Spacing.medium : MarrUI.Spacing.regular)
    }
}

struct MarrModelOptionsList: View {
    let models: [CodexModelOption]
    let selectedModel: String
    let isEnabled: Bool
    let onSelect: (String) -> Void
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: MarrUI.Spacing.tight) {
                    ForEach(models) { model in
                        Button {
                            // Reselecting a model must not reset its custom effort.
                            guard model.id != selectedModel else { return }
                            onSelect(model.id)
                        } label: {
                            HStack(spacing: MarrUI.Spacing.regular) {
                                Text(model.name).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 0)
                                MarrIcon("checkmark", size: MarrUI.Icon.inline)
                                    .opacity(model.id == selectedModel ? 1 : 0)
                                    .accessibilityHidden(true)
                            }
                            .frame(maxWidth: .infinity, minHeight: MarrUI.Row.height)
                        }
                        .buttonStyle(MarrButtonStyle(.ghost, size: .compact))
                        .background(
                            Color.primary.opacity(model.id == selectedModel ? (contrast == .increased ? 0.16 : 0.08) : 0),
                            in: RoundedRectangle(cornerRadius: MarrUI.Radius.control, style: .continuous)
                        )
                        .help(model.description.isEmpty ? model.name : model.description)
                        .accessibilityIdentifier("model-option-" + model.id)
                        .accessibilityAddTraits(model.id == selectedModel ? .isSelected : [])
                        .disabled(!isEnabled)
                        .id(model.id)
                    }
                }
                .padding(2)
            }
            .frame(height: min(210, CGFloat(models.count) * (MarrUI.Row.height + MarrUI.Spacing.tight)))
            .task(id: [selectedModel] + models.map(\.id)) {
                // The catalog can arrive after opening. Let the new rows lay out
                // before positioning the selected item, without a fly-through.
                await Task.yield()
                guard !Task.isCancelled, models.contains(where: { $0.id == selectedModel }) else { return }
                proxy.scrollTo(selectedModel, anchor: .center)
            }
        }
    }
}

struct MarrReasoningPicker: View {
    let efforts: [String]
    let selection: String?
    let onSelect: (String) -> Void

    private var options: [String] { MarrReasoningOptions.ordered(efforts) }
    private var selectedIndex: Int? { selection.flatMap { options.firstIndex(of: $0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
            HStack {
                Text("Reasoning")
                Spacer()
                Text(MarrReasoningOptions.label(selection) + (selection?.isEmpty == false && selectedIndex == nil ? " (Unavailable)" : ""))
                    .foregroundStyle(.secondary)
            }
            if options.count > 1 {
                if options.count <= 4 {
                    MarrReasoningSegments(options: options, selection: selection, onSelect: onSelect)
                        .frame(height: MarrUI.Control.compact)
                } else if selectedIndex != nil {
                    MarrReasoningTickSlider(options: options, selection: selection, onSelect: onSelect)
                        .frame(height: MarrUI.Control.compact)
                    HStack {
                        Text(MarrReasoningOptions.label(options.first))
                        Spacer()
                        Text(MarrReasoningOptions.label(options.last))
                    }
                    .marrTextStyle(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    // An omitted or stale effort is not the first advertised
                    // value. Require an explicit choice before showing a thumb.
                    Menu("Choose level") {
                        ForEach(options, id: \.self) { effort in
                            Button(MarrReasoningOptions.label(effort)) { onSelect(effort) }
                        }
                    }
                    .accessibilityLabel("Reasoning effort")
                }
            } else if let only = options.first, selectedIndex == nil {
                Button("Use \(MarrReasoningOptions.label(only))") { onSelect(only) }
                    .buttonStyle(.link)
            }
        }
        .marrTextStyle(.secondary)
    }
}

/// Native controls preserve arrow-key operation and macOS focus indicators.
private struct MarrReasoningSegments: NSViewRepresentable {
    let options: [String]
    let selection: String?
    let onSelect: (String) -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.trackingMode = .selectOne
        control.segmentStyle = .rounded
        control.segmentDistribution = .fillEqually
        control.controlSize = .small
        control.target = context.coordinator
        control.action = #selector(Coordinator.changed(_:))
        control.setAccessibilityLabel("Reasoning effort")
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        if control.segmentCount != options.count { control.segmentCount = options.count }
        for (index, effort) in options.enumerated() {
            control.setLabel(MarrReasoningOptions.label(effort), forSegment: index)
            control.setWidth(0, forSegment: index)
        }
        control.selectedSegment = selection.flatMap { options.firstIndex(of: $0) } ?? -1
        control.isEnabled = isEnabled
    }

    final class Coordinator: NSObject {
        var parent: MarrReasoningSegments
        init(_ parent: MarrReasoningSegments) { self.parent = parent }
        @objc func changed(_ sender: NSSegmentedControl) {
            guard parent.isEnabled, parent.options.indices.contains(sender.selectedSegment) else { return }
            parent.onSelect(parent.options[sender.selectedSegment])
        }
    }
}

struct MarrReasoningTickSlider: NSViewRepresentable {
    let options: [String]
    let selection: String?
    let onSelect: (String) -> Void
    var accessibilityTitle = "Reasoning effort"
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSlider {
        // Keep the unmodified system cell so macOS supplies the original glass
        // thumb and its native hover, drag, focus and accessibility treatment.
        let slider = NSSlider()
        slider.minValue = 0
        slider.maxValue = 1
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.controlSize = .small
        slider.tickMarkPosition = .below
        slider.allowsTickMarkValuesOnly = true
        slider.isContinuous = true
        slider.setAccessibilityLabel(accessibilityTitle)
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.parent = self
        slider.maxValue = Double(max(1, options.count - 1))
        slider.numberOfTickMarks = options.count
        slider.doubleValue = Double(selection.flatMap { options.firstIndex(of: $0) } ?? 0)
        slider.isEnabled = isEnabled
        slider.setAccessibilityValueDescription(MarrReasoningOptions.label(selection))
        slider.toolTip = options.map { MarrReasoningOptions.label($0) }.joined(separator: " · ")
        slider.needsDisplay = true
    }

    final class Coordinator: NSObject {
        var parent: MarrReasoningTickSlider
        init(_ parent: MarrReasoningTickSlider) { self.parent = parent }
        @objc func changed(_ sender: NSSlider) {
            guard parent.isEnabled, !parent.options.isEmpty else { return }
            let index = min(parent.options.count - 1, max(0, Int(sender.doubleValue.rounded())))
            sender.doubleValue = Double(index)
            sender.setAccessibilityValueDescription(MarrReasoningOptions.label(parent.options[index]))
            parent.onSelect(parent.options[index])
        }
    }
}

struct ThreadGoalEditor: View {
    @ObservedObject var workspace: RuntimeWorkspaceController
    @Environment(\.dismiss) private var dismiss
    @State private var objective = ""
    @State private var edited = false
    @State private var submittedObjective: String?

    var body: some View {
        VStack(alignment: .leading, spacing: MarrUI.Spacing.large) {
            HStack {
                Label("Task goal", marrSymbol: "target").marrTextStyle(.title)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Set the outcome Codex should keep working toward. You can pause, resume, or clear it here.")
                .font(MarrTypography.font(.body)).foregroundStyle(.secondary)
            if let goal = workspace.threadGoal {
                HStack {
                    Text(goal.status.capitalized).fontWeight(.medium)
                    Spacer()
                    Text("\(goal.tokensUsed.formatted()) tokens used").foregroundStyle(.secondary)
                }.font(MarrTypography.font(.secondary))
            }
            Text("Objective").font(MarrTypography.font(.body, weight: .medium))
            TextEditor(text: Binding(get: { objective }, set: { objective = $0; edited = true }))
                .font(MarrTypography.font(.answer))
                .frame(height: 120).padding(6)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.25)))
                .accessibilityLabel("Goal objective")
            if !workspace.commandOutput.isEmpty {
                ScrollView { Text(workspace.commandOutput).font(MarrTypography.font(.secondary)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
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

/// The composer owns one menu at a time; switching tools never replaces its editor.
enum MarrComposerMenuKind: Hashable, CaseIterable { case attachments, mode, workModel, planModel }

@MainActor
final class MarrComposerMenuState: ObservableObject {
    @Published var query = ""
    @Published var highlightedID: String?

    func reset() { query = ""; highlightedID = nil }

    func results(in options: [AgentCompletionOption]) -> [AgentCompletionOption] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return options.filter { option in
            let text = [option.title, option.detail, option.id, option.providerTag].joined(separator: " ")
            return terms.allSatisfy { text.localizedStandardContains($0) }
        }
    }

    func reconcile(_ options: [AgentCompletionOption], selectedID: String?) {
        let available = results(in: options).filter(\.enabled)
        if available.contains(where: { $0.id == highlightedID }) { return }
        highlightedID = available.first(where: { $0.id == selectedID })?.id ?? available.first?.id
    }

    func move(by offset: Int, in options: [AgentCompletionOption]) {
        let available = results(in: options).filter(\.enabled)
        guard !available.isEmpty else { highlightedID = nil; return }
        let current = available.firstIndex { $0.id == highlightedID }
        let next = current.map { ($0 + offset + available.count) % available.count }
            ?? (offset < 0 ? available.count - 1 : 0)
        highlightedID = available[next].id
    }
}

/// A bounded results viewport keeps the bottom search field stationary even when
/// filtering yields no rows. Configuration controls are outside the scroll view.
struct MarrComposerMenu<Configuration: View>: View {
    let title: String
    let options: [AgentCompletionOption]
    var selectedID: String? = nil
    var isEnabled = true
    var emptyMessage = "No matches"
    var resultsHeight: CGFloat? = nil
    @ObservedObject var state: MarrComposerMenuState
    let onSelect: (AgentCompletionOption) -> Void
    let onDismiss: () -> Void
    @ViewBuilder var configuration: () -> Configuration
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var lastPointerPosition: NSPoint?

    private var results: [AgentCompletionOption] { state.results(in: options) }
    // Size against the full catalog, so filtering never moves the search footer.
    private var viewportHeight: CGFloat {
        resultsHeight ?? min(options.contains { !$0.detail.isEmpty } ? 176 : 144,
            max(options.isEmpty ? 68 : 40, options.reduce(CGFloat(6)) { $0 + rowHeight($1) + 2 }))
    }
    private func rowHeight(_ option: AgentCompletionOption) -> CGFloat { option.detail.isEmpty ? 32 : 40 }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).marrTextStyle(.secondary, weight: .medium)
                Spacer()
                Text("esc").marrTextStyle(.caption).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(results) { option in
                            row(option).id(option.id)
                        }
                    }
                    .padding(.horizontal, 6).padding(.vertical, 4)
                }
                .frame(height: viewportHeight)
                .overlay {
                    if results.isEmpty {
                        Text(state.query.isEmpty ? emptyMessage : "No matches for “\(state.query)”")
                            .marrTextStyle(.secondary).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).lineLimit(3).padding(20)
                            .allowsHitTesting(false)
                    }
                }
                .onChange(of: state.highlightedID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
                .task {
                    state.reconcile(options, selectedID: selectedID)
                    await Task.yield()
                    if let id = state.highlightedID { proxy.scrollTo(id) }
                }
            }
            configuration()
            Divider().padding(.horizontal, 12)
            HStack(spacing: 8) {
                MarrComposerSearchField(query: $state.query, placeholder: "Search \(title.lowercased())", onKey: handleKey)
                    .frame(height: 28)
                Text("↵").marrTextStyle(.secondary).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .foregroundStyle(MarrPanelColors.primary(for: colorScheme))
        .onChange(of: state.query) { _, _ in state.reconcile(options, selectedID: selectedID) }
        .onChange(of: options) { _, _ in state.reconcile(options, selectedID: selectedID) }
        .onExitCommand(perform: onDismiss)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private func handleKey(_ key: AgentComposerKey) {
        switch key {
        case .up: state.move(by: -1, in: options)
        case .down: state.move(by: 1, in: options)
        case .accept, .complete:
            if isEnabled, let option = results.first(where: { $0.id == state.highlightedID && $0.enabled }) {
                onSelect(option)
            }
        case .dismiss: onDismiss()
        }
    }

    private func row(_ option: AgentCompletionOption) -> some View {
        let selected = option.id == selectedID
        let highlighted = option.id == state.highlightedID
        return Button { if isEnabled && option.enabled { onSelect(option) } } label: {
            HStack(spacing: 8) {
                if !option.providerTag.isEmpty {
                    ProviderBrandIcon(name: option.providerIconName, size: 16)
                } else {
                    MarrIcon(option.symbol, size: MarrUI.Icon.inline)
                        .foregroundStyle(.secondary).frame(width: 16).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title).marrTextStyle(.body, weight: selected ? .medium : .regular)
                        .lineLimit(1).truncationMode(.middle)
                    if !option.detail.isEmpty {
                        Text(option.detail).marrTextStyle(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if !option.providerTag.isEmpty {
                    Text(option.providerTag)
                        .marrTextStyle(.caption, weight: .medium)
                        .foregroundStyle(MarrPanelColors.secondary(for: colorScheme))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.primary.opacity(contrast == .increased ? 0.12 : 0.06), in: Capsule())
                        .fixedSize()
                }
                if selected {
                    MarrIcon("checkmark", size: MarrUI.Icon.status).accessibilityHidden(true)
                } else if option.showsDisclosure {
                    MarrIcon("chevron.right", size: MarrUI.Icon.disclosure)
                        .foregroundStyle(.secondary).accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 6).frame(height: rowHeight(option))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(.primary.opacity(highlighted ? (contrast == .increased ? 0.16 : 0.06) : 0),
                        in: RoundedRectangle(cornerRadius: MarrUI.Radius.control))
        }
        .buttonStyle(.plain).disabled(!isEnabled || !option.enabled)
        .onContinuousHover { phase in
            guard case .active = phase, isEnabled, option.enabled else { return }
            let point = NSEvent.mouseLocation
            guard point != lastPointerPosition else { return }
            lastPointerPosition = point
            state.highlightedID = option.id
        }
        .help(option.helpText.isEmpty ? option.title : option.helpText)
        .accessibilityIdentifier("composer-option-" + option.id)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Native search preserves marked text (IME), Tab traversal and the clear button.
/// Only menu navigation is intercepted; Return in an empty menu never sends a draft.
struct MarrComposerSearchField: NSViewRepresentable {
    @Binding var query: String
    let placeholder: String
    let onKey: (AgentComposerKey) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.controlSize = .regular
        field.font = NSFont.systemFont(ofSize: MarrTypography.Role.secondary.size)
        field.focusRingType = .default
        field.bezelStyle = .roundedBezel
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true
        field.identifier = NSUserInterfaceItemIdentifier("composer-menu-search")
        field.setAccessibilityLabel(placeholder)
        // Focus once on presentation; subsequent filtering must not steal focus
        // from a clicked slider, speed control or menu row.
        DispatchQueue.main.async { [weak field] in
            guard let field, let window = field.window else { return }
            window.makeFirstResponder(field)
        }
        return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != query { field.stringValue = query }
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)
    }
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: MarrComposerSearchField
        init(_ parent: MarrComposerSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.query = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            let key: AgentComposerKey
            switch command {
            case #selector(NSResponder.moveUp(_:)): key = .up
            case #selector(NSResponder.moveDown(_:)): key = .down
            case #selector(NSResponder.insertNewline(_:)): key = .accept
            case #selector(NSResponder.cancelOperation(_:)): key = .dismiss
            default: return false
            }
            parent.onKey(key)
            return true
        }
    }
}

struct MarrComposerControlFrames: PreferenceKey {
    static let defaultValue: [MarrComposerMenuKind: CGRect] = [:]
    static func reduce(value: inout [MarrComposerMenuKind: CGRect], nextValue: () -> [MarrComposerMenuKind: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

struct MarrComposerMenuHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct MarrComposerSendBounds: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isEmpty { value = next }
    }
}

struct MarrComposerBounds: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isEmpty { value = next }
    }
}

extension View {
    func composerControlAnchor(_ kind: MarrComposerMenuKind) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(key: MarrComposerControlFrames.self,
                    value: [kind: geometry.frame(in: .named("answer-panel"))])
            }
        }
    }
}

enum MarrComposerMorphLayout {
    /// Keep the toolbar baseline. Prefer growing to the right from the source;
    /// shrink before moving the origin when the window has little room.
    static func destination(source: CGRect, canvas: CGSize, preferred: CGSize,
                            horizontalBounds: ClosedRange<CGFloat>? = nil) -> CGRect {
        let inset: CGFloat = 12
        let leading = max(inset, horizontalBounds?.lowerBound ?? inset)
        let trailing = min(canvas.width - inset, horizontalBounds?.upperBound ?? canvas.width - inset)
        let minimumWidth = min(220, preferred.width)
        let width = min(preferred.width, max(minimumWidth, trailing - source.minX), trailing - leading)
        let height = min(preferred.height, max(source.height, source.maxY - inset))
        let x = max(leading, min(source.minX, trailing - width))
        return CGRect(x: x, y: source.maxY - height, width: width, height: height)
    }

    static func frame(source: CGRect, destination: CGRect, progress: CGFloat) -> CGRect {
        let t = min(1, max(0, progress))
        return CGRect(x: source.minX + (destination.minX - source.minX) * t,
                      y: source.minY + (destination.minY - source.minY) * t,
                      width: source.width + (destination.width - source.width) * t,
                      height: source.height + (destination.height - source.height) * t)
    }
}

/// A single surface grows from the control's actual bounds. Full-size content is
/// revealed by the growing mask, so text and the native slider never stretch.
struct MarrComposerMorphSurface<Compact: View, Content: View>: View, Animatable {
    var progress: CGFloat
    let source: CGRect
    let destination: CGRect
    var isInteractive = true
    var isClear = false
    @ViewBuilder var compact: () -> Compact
    @ViewBuilder var content: () -> Content
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reducesTransparency
    @AppStorage(MarrAppearanceKeys.glassSurfaces) private var usesGlassSurfaces = true

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let t = min(1, max(0, progress))
        let rect = MarrComposerMorphLayout.frame(source: source, destination: destination, progress: t)
        let radius = source.height / 2 + (MarrUI.Radius.card - source.height / 2) * t
        ZStack(alignment: .bottomLeading) {
            content()
                .frame(width: destination.width, height: destination.height, alignment: .bottomLeading)
                .opacity(min(1, max(0, (t - 0.18) / 0.62)))
                .accessibilityHidden(!isInteractive)
            compact()
                .frame(width: source.width, height: source.height, alignment: .leading)
                .opacity(max(0, 1 - t / 0.3))
                .accessibilityHidden(true).allowsHitTesting(false)
        }
        .foregroundStyle(MarrPanelColors.primary(for: colorScheme))
        .frame(width: rect.width, height: rect.height, alignment: .bottomLeading)
        .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .background {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            if reducesTransparency || !usesGlassSurfaces {
                shape.fill(MarrUI.Surface.raised)
            } else if isClear && contrast != .increased {
                // Keep clear glass's rim and reflections, with the lightest
                // backdrop isolation so draft text cannot collide with labels.
                shape.fill(.ultraThinMaterial)
            } else if !isClear || contrast == .increased {
                // Frost the content behind the menu instead of covering glass
                // with an opaque card. A stronger material keeps high contrast readable.
                shape.fill(contrast == .increased ? .regularMaterial : .thinMaterial)
            }
        }
        .marrGlassSurface(cornerRadius: radius, isClear: isClear && contrast != .increased,
                          tintOpacity: isClear ? 0 : colorScheme == .dark ? 0.18 : 0.12)
        .shadow(color: .black.opacity((colorScheme == .dark ? 0.22 : 0.1) * t), radius: 12 * t, y: 4 * t)
        .allowsHitTesting(isInteractive)
        .offset(x: rect.minX, y: rect.minY)
    }
}

/// The plus first reveals actions in the toolbar. The editor does not move;
/// the model label gives up space before either action target is compressed.
struct MarrComposerAttachmentEntry: View {
    @Binding var expanded: Bool
    var offersContext: Bool
    var isEnabled = true
    let onAttach: () -> Void
    let onContext: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            Button {
                withAnimation(reducesMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86)) {
                    expanded.toggle()
                }
            } label: {
                MarrIcon("plus", size: MarrUI.Icon.toolbar)
                    .rotationEffect(.degrees(expanded ? 45 : 0))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Close attachment actions" : "Add attachments and context")
            .accessibilityLabel(expanded ? "Close attachment actions" : "Add attachments and context")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded {
                Button(action: onAttach) {
                    Text("Attach files").marrTextStyle(.secondary, weight: .medium)
                        .fixedSize().padding(.horizontal, 6).frame(height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("Attach files")
                if offersContext {
                    Button(action: onContext) {
                        MarrIcon("chevron.down", size: MarrUI.Icon.disclosure).frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help("Workspace context, skills and tools")
                    .accessibilityLabel("More context options")
                }
            }
        }
        .foregroundStyle(MarrPanelColors.primary(for: colorScheme))
        .background(.primary.opacity(expanded ? 0.065 : 0.035), in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
        .disabled(!isEnabled)
    }
}

/// Native text fields and glass hosts can bypass a SwiftUI clear-view gesture.
/// This window-local backdrop owns only the area outside the expanded surface.
struct MarrComposerMenuBackdrop: NSViewRepresentable {
    let menuFrame: CGRect
    var passthroughFrame: CGRect = .zero
    let onClick: (CGPoint) -> Void
    func makeNSView(context: Context) -> MarrComposerBackdropView { MarrComposerBackdropView() }
    func updateNSView(_ view: MarrComposerBackdropView, context: Context) {
        view.menuFrame = menuFrame
        view.passthroughFrame = passthroughFrame
        view.onClick = onClick
    }
}

final class MarrComposerBackdropView: NSView {
    var menuFrame: CGRect = .zero
    var passthroughFrame: CGRect = .zero
    var onClick: ((CGPoint) -> Void)?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) && !menuFrame.contains(local) && !passthroughFrame.contains(local) ? self : nil
    }
    override func mouseDown(with event: NSEvent) { onClick?(convert(event.locationInWindow, from: nil)) }
    override func rightMouseDown(with event: NSEvent) { onClick?(convert(event.locationInWindow, from: nil)) }
    override func accessibilityIsIgnored() -> Bool { true }
}
