import AppKit
import Foundation
import MarrCore
import SwiftUI

enum MarrMixedConversationContent {
    enum Row: Identifiable {
        case local(ConversationHistoryRecord), codex(SavedTask)
        var id: String {
            switch self {
            case .local(let record): "local-" + record.id.uuidString
            case .codex(let task): "codex-" + task.id.uuidString
            }
        }
        var updatedAt: Date {
            switch self {
            case .local(let record): record.updatedAt
            case .codex(let task): task.updatedAt
            }
        }
    }

    static func rows(local: [ConversationHistoryRecord], codex: [SavedTask], query: String) -> [Row] {
        let records = local.filter { !$0.isArchived && $0.workspaceID == nil
            && MarrGlobalSearchContent.matches($0, query: query) }
        return (records.map(Row.local) + codex.map(Row.codex)).sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
    }
}

/// The timer only exists while an overflowing title is hovered. Short titles and
/// reduced-motion users retain normal truncation and the full-title tooltip.
struct MarrScrollingConversationTitle: View {
    let title: String
    let isSelected: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoverStartedAt: Date?
    @State private var textWidth: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0

    private var label: some View {
        Text(verbatim: title).marrTextStyle(.body, weight: isSelected ? .medium : .regular)
    }

    var body: some View {
        let overflow = max(0, textWidth - viewportWidth)
        let scrolls = hoverStartedAt != nil && overflow > 1 && !reduceMotion
        label.lineLimit(1).truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
            .opacity(scrolls ? 0 : 1)
            .background(alignment: .leading) {
                label.fixedSize().hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
            }
            .overlay(alignment: .leading) {
                if scrolls, let start = hoverStartedAt {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                        label.fixedSize()
                            .offset(x: MarrTitleMarquee.offset(elapsed: context.date.timeIntervalSince(start), overflow: overflow))
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .onHover { hoverStartedAt = $0 ? Date() : nil }
            .onChange(of: title) { _, _ in hoverStartedAt = nil }
            .onDisappear { hoverStartedAt = nil }
            .help(title)
    }
}

enum MarrTitleMarquee {
    static func offset(elapsed: TimeInterval, overflow: CGFloat) -> CGFloat {
        guard overflow > 1, elapsed > 0.7 else { return 0 }
        let duration = Double(overflow) / 28
        let pause = 0.8
        let phase = (elapsed - 0.7).truncatingRemainder(dividingBy: 2 * (duration + pause))
        if phase < duration { return -CGFloat(phase / duration) * overflow }
        if phase < duration + pause { return -overflow }
        if phase < 2 * duration + pause { return -overflow * CGFloat(1 - (phase - duration - pause) / duration) }
        return 0
    }
}
