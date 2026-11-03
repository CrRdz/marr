import AppKit
import SwiftUI
import MarrCore

struct MarrAttachmentPreviewButton<Content: View>: View {
    let attachment: ConversationImageAsset
    @ViewBuilder let content: () -> Content
    @State private var showsPreview = false

    var body: some View {
        Button { showsPreview = true } label: { content() }
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
            Image(systemName: symbol)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 12, weight: .medium))
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
            RoundedRectangle(cornerRadius: 7, style: .continuous)
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
        HStack(spacing: 2) {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(language?.isEmpty == false ? language! : "Code")
                    .font(MarrTypography.font(.caption, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                MarrCopyButton(text: code, accessibilityName: "Copy code")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            Divider()
            ScrollView(.horizontal) {
                Text(verbatim: code)
                    .font(MarrTypography.font(.code))
                    .lineSpacing(compact ? 1 : 4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(10)
            }
        }
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: MarrUI.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: MarrUI.Radius.card).stroke(.primary.opacity(0.08), lineWidth: 0.5))
    }
}

struct MarrDiffLine: Identifiable, Equatable {
    enum Kind: Equatable { case context, addition, deletion, hunk, metadata }
    let id: Int
    let text: String
    let kind: Kind
    let oldLine: Int?
    let newLine: Int?
}

struct MarrDiffFile: Identifiable, Equatable {
    let id: Int
    var path: String
    var lines: [MarrDiffLine]
    var additions: Int { lines.filter { $0.kind == .addition }.count }
    var deletions: Int { lines.filter { $0.kind == .deletion }.count }
}

/// A bounded presentation of unified diffs; raw text remains available for copying.
/// Headers and binary/rename metadata are retained instead of inventing line numbers.
struct MarrDiffDocument: Equatable {
    let files: [MarrDiffFile]
    let isTruncated: Bool

    init(_ source: String, characterLimit: Int = 200_000, lineLimit: Int = 5_000) {
        let bounded = String(source.prefix(max(0, characterLimit)))
        let rawLines = bounded.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        isTruncated = source.count > characterLimit || rawLines.count > lineLimit
        var result: [MarrDiffFile] = []
        var current = MarrDiffFile(id: 0, path: "Changes", lines: [])
        var oldNumber: Int?
        var newNumber: Int?
        var oldRemaining = 0
        var newRemaining = 0
        var oldPath: String?
        var hasFileHeaders = false
        var hasHunk = false
        let hunk = try? NSRegularExpression(pattern: #"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"#)
        let gitHeader = try? NSRegularExpression(pattern: #"^diff --git ("(?:[^"\\]|\\.)*"|\S+) ("(?:[^"\\]|\\.)*"|\S+)$"#)

        // Git quotes paths with C escapes and octal UTF-8 bytes, not JSON escapes.
        func unquote(_ value: String) -> String? {
            let bytes = Array(value.utf8)
            guard bytes.first == 34, bytes.last == 34, bytes.count >= 2 else { return nil }
            var decoded: [UInt8] = []
            var index = 1
            while index < bytes.count - 1 {
                let byte = bytes[index]
                index += 1
                guard byte == 92 else { decoded.append(byte); continue }
                guard index < bytes.count - 1 else { return nil }
                let escaped = bytes[index]
                index += 1
                if (48...55).contains(escaped) {
                    var octal = Int(escaped - 48)
                    var digits = 1
                    while digits < 3, index < bytes.count - 1, (48...55).contains(bytes[index]) {
                        octal = octal * 8 + Int(bytes[index] - 48)
                        index += 1
                        digits += 1
                    }
                    guard let byte = UInt8(exactly: octal) else { return nil }
                    decoded.append(byte)
                } else {
                    let escapes: [UInt8: UInt8] = [97: 7, 98: 8, 116: 9, 110: 10, 118: 11,
                                                  102: 12, 114: 13, 92: 92, 34: 34]
                    guard let byte = escapes[escaped] else { return nil }
                    decoded.append(byte)
                }
            }
            return String(bytes: decoded, encoding: .utf8)
        }

        func path(_ raw: String, stripDiffPrefix: Bool = true) -> String? {
            var value = raw.components(separatedBy: "\t")[0]
            if value == "/dev/null" { return nil }
            if value.hasPrefix("\""), let decoded = unquote(value) {
                value = decoded
            }
            if stripDiffPrefix, value.hasPrefix("a/") || value.hasPrefix("b/") { value = String(value.dropFirst(2)) }
            return value.isEmpty ? nil : value
        }

        let visibleLines = Array(rawLines.prefix(max(0, lineLimit)))
        for (index, line) in visibleLines.enumerated() {
            let isGitHeader = line.hasPrefix("diff --git ")
            let isNextFileHeader = oldRemaining == 0 && newRemaining == 0
                && (hasFileHeaders || hasHunk) && line.hasPrefix("--- ")
                && index + 1 < visibleLines.count && visibleLines[index + 1].hasPrefix("+++ ")
            if isGitHeader || isNextFileHeader {
                if !current.lines.isEmpty { result.append(current) }
                current = MarrDiffFile(id: result.count, path: "Changes", lines: [])
                oldNumber = nil
                newNumber = nil
                oldRemaining = 0
                newRemaining = 0
                oldPath = nil
                hasFileHeaders = false
                hasHunk = false
            }
            if isGitHeader {
                if let match = gitHeader?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                   let range = Range(match.range(at: 2), in: line) {
                    current.path = path(String(line[range])) ?? "Changes"
                } else if let separator = line.range(of: " b/", options: .backwards) {
                    current.path = String(line[separator.lowerBound...].dropFirst(3))
                }
            }
            var kind = MarrDiffLine.Kind.metadata
            var old: Int?
            var new: Int?
            if let match = hunk?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let oldRange = Range(match.range(at: 1), in: line),
               let newRange = Range(match.range(at: 3), in: line) {
                func count(at group: Int) -> Int {
                    guard let range = Range(match.range(at: group), in: line) else { return 1 }
                    return Int(line[range]) ?? 0
                }
                oldNumber = Int(line[oldRange])
                newNumber = Int(line[newRange])
                oldRemaining = count(at: 2)
                newRemaining = count(at: 4)
                hasHunk = true
                kind = .hunk
            } else if oldRemaining > 0 || newRemaining > 0 {
                if line.hasPrefix("+"), newRemaining > 0 {
                    kind = .addition; new = newNumber
                    newNumber = newNumber.flatMap { $0 < Int.max ? $0 + 1 : nil }
                    newRemaining -= 1
                } else if line.hasPrefix("-"), oldRemaining > 0 {
                    kind = .deletion; old = oldNumber
                    oldNumber = oldNumber.flatMap { $0 < Int.max ? $0 + 1 : nil }
                    oldRemaining -= 1
                } else if line.hasPrefix(" "), oldRemaining > 0, newRemaining > 0 {
                    kind = .context; old = oldNumber; new = newNumber
                    oldNumber = oldNumber.flatMap { $0 < Int.max ? $0 + 1 : nil }
                    newNumber = newNumber.flatMap { $0 < Int.max ? $0 + 1 : nil }
                    oldRemaining -= 1
                    newRemaining -= 1
                } else if !line.hasPrefix("\\") {
                    oldNumber = nil; newNumber = nil
                    oldRemaining = 0; newRemaining = 0
                }
            }
            if kind == .metadata {
                if line.hasPrefix("--- ") { oldPath = path(String(line.dropFirst(4))) }
                if line.hasPrefix("+++ ") {
                    current.path = path(String(line.dropFirst(4))) ?? oldPath ?? current.path
                    hasFileHeaders = true
                }
                if line.hasPrefix("rename to ") {
                    current.path = path(String(line.dropFirst(10)), stripDiffPrefix: false) ?? current.path
                }
            }
            current.lines.append(MarrDiffLine(id: index, text: line, kind: kind, oldLine: old, newLine: new))
        }
        if !current.lines.isEmpty { result.append(current) }
        files = result
    }
}

struct MarrDiffView: View {
    let source: String
    @State private var document = MarrDiffDocument("")

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("File changes").font(MarrTypography.font(.secondary, weight: .medium))
                Spacer()
                MarrCopyButton(text: source, accessibilityName: "Copy complete diff")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(document.files) { file in
                        MarrDiffFileView(file: file, initiallyExpanded: document.files.count == 1 || file.id == 0)
                    }
                    if document.isTruncated {
                        Text("Preview limited to 5,000 lines or 200,000 characters. Copy includes the complete diff.")
                            .font(MarrTypography.font(.caption)).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxHeight: 300)
        }
        .task(id: source) { document = MarrDiffDocument(source) }
    }
}

private struct MarrDiffFileView: View {
    let file: MarrDiffFile
    @State private var isExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    init(file: MarrDiffFile, initiallyExpanded: Bool) {
        self.file = file
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ScrollView(.horizontal) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(file.lines) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(line.oldLine.map(String.init) ?? "")
                                .frame(width: 36, alignment: .trailing).foregroundStyle(.secondary)
                            Text(line.newLine.map(String.init) ?? "")
                                .frame(width: 36, alignment: .trailing).foregroundStyle(.secondary)
                            Text(verbatim: line.text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(MarrTypography.font(.code))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(background(for: line.kind))
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        } label: {
            HStack(spacing: 6) {
                Text(file.path).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text("+\(file.additions)").foregroundStyle(.green)
                Text("−\(file.deletions)").foregroundStyle(.red)
            }
            .font(MarrTypography.font(.secondary))
            .help(file.path)
        }
        .padding(8)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: MarrUI.Radius.control))
        .animation(MarrMotion.disclosure(reducesMotion: reducesMotion), value: isExpanded)
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
