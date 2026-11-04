import MarrText
import AppKit
import Combine
import MarrCore
import QuartzCore
import SwiftUI

/// Parsing is independent of layout. Keep it with the message's SwiftUI
/// identity so scrolling, hover, and unrelated workspace publications reuse it.
@MainActor
final class MarrMarkdownRenderCache {
    private var source: String?
    private var parsedBlocks: [MarkdownBlock] = []
    private struct InlineKey: Hashable {
        let content: String
        let size: CGFloat
    }
    private var inlineValues: [InlineKey: AttributedString] = [:]
    private(set) var blockParseCount = 0
    private(set) var inlineParseCount = 0

    func blocks(for source: String) -> [MarkdownBlock] {
        guard self.source != source else { return parsedBlocks }
        self.source = source
        parsedBlocks = MarkdownBlockParser.parse(source)
        inlineValues.removeAll(keepingCapacity: true)
        blockParseCount += 1
        return parsedBlocks
    }

    func inline(_ content: String, fontSize: CGFloat = MarrTypography.Role.answer.size) -> AttributedString {
        let key = InlineKey(content: content, size: fontSize)
        if let value = inlineValues[key] { return value }
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        var value = (try? AttributedString(markdown: content, options: options)) ?? AttributedString(content)
        for run in Array(value.runs) {
            guard var intent = run.inlinePresentationIntent else { continue }
            let strong = intent.contains(.stronglyEmphasized)
            if intent.contains(.code) || strong {
                var font = Font.system(size: intent.contains(.code) ? max(12, fontSize - 1) : fontSize,
                    weight: strong ? .semibold : .regular,
                    design: intent.contains(.code) ? .monospaced : .default)
                if intent.contains(.emphasized) { font = font.italic() }
                value[run.range].font = font
                // Retain link/inline-code semantics; avoid SwiftUI adding its
                // default bold weight on top of our restrained semibold.
                intent.remove(.stronglyEmphasized)
                value[run.range].inlinePresentationIntent = intent
            }
        }
        inlineValues[key] = value
        inlineParseCount += 1
        return value
    }
}

struct MarkdownResponseView: View, Equatable {
    let source: String
    var compact = false
    var proseRole: MarrTypography.Role? = nil
    private var textRole: MarrTypography.Role { proseRole ?? (compact ? .body : .answer) }
    @State private var renderCache = MarrMarkdownRenderCache()

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.source == rhs.source && lhs.compact == rhs.compact && lhs.proseRole == rhs.proseRole
    }

    private var blocks: [MarkdownBlock] { renderCache.blocks(for: source) }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? MarrTypography.Reading.compactBlockSpacing : MarrTypography.Reading.blockSpacing) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: compact ? nil : .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.openURL, OpenURLAction { url in
            guard let safeURL = CodexResourceAccess.url(for: url.absoluteString) else { return .discarded }
            CodexResourceAccess.open(safeURL)
            return .handled
        })
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case let .image(label, source):
            CodexMarkdownImageView(source: source, label: label)
        case let .heading(level, content):
            Text(inlineMarkdown(content, size: MarrTypography.Reading.headingSize(level, compact: compact)))
                .font(.system(size: MarrTypography.Reading.headingSize(level, compact: compact), weight: .semibold))
                .lineSpacing(2)
                .padding(.top, compact ? 2 : 6)

        case let .paragraph(content):
            Text(inlineMarkdown(content))
                .marrTextStyle(textRole)

        case let .unorderedList(items):
            VStack(alignment: .leading, spacing: MarrTypography.Reading.listSpacing) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: MarrUI.Spacing.regular) {
                        Text("•")
                            .font(MarrTypography.font(textRole))
                            .foregroundStyle(.secondary)
                        Text(inlineMarkdown(item))
                            .marrTextStyle(textRole)
                            .frame(maxWidth: compact ? nil : .infinity, alignment: .leading)
                    }
                }
            }

        case let .orderedList(items):
            VStack(alignment: .leading, spacing: MarrTypography.Reading.listSpacing) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: MarrUI.Spacing.regular) {
                        Text("\(index + 1).")
                            .font(MarrTypography.font(textRole))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 17, alignment: .trailing)
                        Text(inlineMarkdown(item))
                            .marrTextStyle(textRole)
                            .frame(maxWidth: compact ? nil : .infinity, alignment: .leading)
                    }
                }
            }

        case let .quote(content):
            HStack(alignment: .top, spacing: MarrUI.Spacing.regular) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(.secondary.opacity(0.45))
                    .frame(width: 3)
                Text(inlineMarkdown(content))
                    .marrTextStyle(textRole)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: compact ? nil : .infinity, alignment: .leading)
            }

        case let .code(content, language):
            if ["diff", "patch"].contains(MarrCodeHeader(language: language).language ?? "") {
                MarrDiffView(source: content)
            } else {
                MarrCodeBlock(code: content, language: language, compact: compact)
            }

        case let .table(headers, rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
                    GridRow {
                        ForEach(headers.indices, id: \.self) { index in
                            Text(inlineMarkdown(headers[index]))
                                .marrTextStyle(textRole, weight: .medium)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 7)
                        }
                    }
                    .background(.primary.opacity(0.055))

                    ForEach(rows.indices, id: \.self) { rowIndex in
                        let row = rows[rowIndex]
                        GridRow {
                            ForEach(headers.indices, id: \.self) { columnIndex in
                                Text(inlineMarkdown(columnIndex < row.count ? row[columnIndex] : ""))
                                    .marrTextStyle(textRole)
                                    .padding(.vertical, 7)
                            }
                        }
                        .background(rowIndex.isMultiple(of: 2) ? Color.primary.opacity(0.018) : .clear)
                    }
                }
                .padding(.horizontal, 10)
                .frame(minWidth: 260, alignment: .leading)
            }
            .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(.separator.opacity(0.6), lineWidth: 1)
            )

        case .divider:
            Rectangle()
                .fill(.separator.opacity(0.65))
                .frame(height: 1)
                .padding(.vertical, 2)
        }
    }

    private func inlineMarkdown(_ content: String, size: CGFloat? = nil) -> AttributedString {
        renderCache.inline(content, fontSize: size ?? textRole.size)
    }

}
