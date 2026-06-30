import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var controller: MarrController
    @ObservedObject private var historyStore: ConversationHistoryStore
    @Environment(\.openWindow) private var openWindow
    @AppStorage("menu.showRecentConversations") private var showRecentConversations = true
    @AppStorage("menu.recentItemCount") private var recentItemCount = 3
    @AppStorage("menu.showStatus") private var showStatus = true
    @AppStorage(MarrAccentColor.storageKey) private var accentColor = MarrAccentColor.system.rawValue
    @State private var hoveredConversationID: UUID?

    init(controller: MarrController) {
        self.controller = controller
        historyStore = controller.historyStore
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if showRecentConversations {
                menuDivider
                recentSection
            }
            menuDivider
            primaryActions
            menuDivider
            secondaryActions
        }
        .padding(.leading, 12)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
        .frame(width: 220)
        .marrLiquidGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Marr")
                    .font(MarrTypography.display(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(controller.provider.rawValue)
                    .font(MarrTypography.body(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if showStatus {
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 5, height: 5)
                    Text(statusTitle)
                        .font(MarrTypography.body(size: 10, weight: .semibold))
                        .foregroundStyle(statusColor)
                }
                .frame(width: 72, alignment: .center)
                .help(statusDetail)
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Recent")

            if recentConversations.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("No recent conversations")
                        .font(MarrTypography.body(size: 12, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.86))
                        .lineLimit(1)
                    Text("Capture anything on screen")
                        .font(MarrTypography.body(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                ForEach(recentConversations) { conversation in
                    recentRow(conversation)
                }
            }

            MenuDisclosureRow(title: "More") {
                openAppWindow(id: "history")
            }
        }
    }

    private var primaryActions: some View {
        VStack(alignment: .leading, spacing: 0) {
            menuRow("Capture Now") {
                controller.startScreenCapture()
            }
            menuDivider
            menuRow("Capture Window") {
                controller.captureFrontmostWindow()
            }
            menuDivider
            menuRow("History") {
                openAppWindow(id: "history")
            }
        }
    }

    private var secondaryActions: some View {
        VStack(alignment: .leading, spacing: 0) {
            menuRow("Settings") {
                openAppWindow(id: "settings")
            }
            menuDivider
            menuRow("Quit Marr") {
                NSApp.terminate(nil)
            }
        }
    }

    private func recentRow(_ conversation: ConversationHistoryRecord) -> some View {
        Button {
            openAppWindow(id: "history")
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.title)
                    .font(MarrTypography.body(size: 12, weight: .semibold))
                    .foregroundStyle(hoveredConversationID == conversation.id ? selectedAccentForegroundColor : .primary.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(recentSubtitle(for: conversation))
                    .font(MarrTypography.body(size: 10))
                    .foregroundStyle(hoveredConversationID == conversation.id ? selectedAccentSecondaryForegroundColor : .secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hoveredConversationID == conversation.id ? selectedAccentColor : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            hoveredConversationID = isHovering ? conversation.id : nil
        }
    }

    private func openAppWindow(id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func menuRow(
        _ title: String,
        trailing: String? = nil,
        usesGlass: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        MenuActionRow(
            title: title,
            trailing: trailing,
            usesGlass: usesGlass,
            action: action
        )
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(MarrTypography.body(size: 10, weight: .semibold))
            .foregroundStyle(.secondary.opacity(0.78))
    }

    private var menuDivider: some View {
        Rectangle()
            .fill(.secondary.opacity(0.22))
            .frame(height: 1)
            .padding(.vertical, 6)
    }

    private var recentConversations: [ConversationHistoryRecord] {
        Array(historyStore.conversations.prefix(max(1, min(recentItemCount, 5))))
    }

    private func recentSubtitle(for conversation: ConversationHistoryRecord) -> String {
        let imageCount = conversation.images.count
        let turnCount = conversation.turns.count

        if turnCount > 0, imageCount > 0 {
            return "\(relativeDateString(for: conversation.updatedAt)) · \(turnCount) chats · \(imageCount) captures"
        }
        if turnCount > 0 {
            return "\(relativeDateString(for: conversation.updatedAt)) · \(turnCount) chats"
        }
        if imageCount > 0 {
            return "\(relativeDateString(for: conversation.updatedAt)) · \(imageCount) captures"
        }
        return relativeDateString(for: conversation.updatedAt)
    }

    private func relativeDateString(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private var statusTitle: String {
        guard let message = controller.statusMessage else { return "Ready" }
        if message.localizedCaseInsensitiveContains("could not") { return "Needs attention" }
        if message.localizedCaseInsensitiveContains("active") { return "Capturing" }
        if message.localizedCaseInsensitiveContains("drag") || message.localizedCaseInsensitiveContains("select") { return "Capturing" }
        if message.localizedCaseInsensitiveContains("cancelled") { return "Ready" }
        return "Ready"
    }

    private var statusDetail: String {
        controller.statusMessage ?? "Use the shortcut to ask about anything on your screen."
    }

    private var statusColor: Color {
        statusTitle == "Needs attention" ? .orange : .green
    }

    private var selectedAccentColor: Color {
        selectedAccent.color
    }

    private var selectedAccentForegroundColor: Color {
        selectedAccent.foregroundColor
    }

    private var selectedAccentSecondaryForegroundColor: Color {
        selectedAccent.secondaryForegroundColor
    }

    private var selectedAccent: MarrAccentColor {
        MarrAccentColor.resolve(accentColor)
    }
}

private struct MenuDisclosureRow: View {
    let title: String
    let action: () -> Void

    @AppStorage(MarrAccentColor.storageKey) private var accentColor = MarrAccentColor.system.rawValue
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(MarrTypography.body(size: 12, weight: .regular))
                    .foregroundStyle(isHovered ? selectedAccent.foregroundColor : .primary.opacity(0.9))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isHovered ? selectedAccent.secondaryForegroundColor : .secondary)
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(hoverBackground)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var hoverBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isHovered ? selectedAccent.color : .clear)
    }

    private var selectedAccent: MarrAccentColor {
        MarrAccentColor.resolve(accentColor)
    }
}

private struct MenuActionRow: View {
    let title: String
    let trailing: String?
    let usesGlass: Bool
    let action: () -> Void

    @AppStorage(MarrAccentColor.storageKey) private var accentColor = MarrAccentColor.system.rawValue
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title)
                    .font(MarrTypography.body(size: 12, weight: .regular))
                    .foregroundStyle(isHovered ? selectedAccent.foregroundColor : .primary.opacity(0.92))
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(MarrTypography.mono(size: 10, weight: .semibold))
                        .foregroundStyle(isHovered ? selectedAccent.secondaryForegroundColor : .secondary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(rowBackground)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var rowBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)

        if isHovered {
            shape.fill(selectedAccent.color)
        } else if usesGlass {
            Color.clear.marrLiquidGlass(in: shape)
        } else {
            shape.fill(.clear)
        }
    }

    private var selectedAccent: MarrAccentColor {
        MarrAccentColor.resolve(accentColor)
    }
}

private extension View {
    func marrLiquidGlass<S: Shape>(in shape: S) -> some View {
        modifier(MarrMenuGlassModifier(shape: shape))
    }

    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

private struct MarrMenuGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    @AppStorage("appearance.glassSurfaces") private var usesGlassSurfaces = true

    func body(content: Content) -> some View {
        content
            .background {
                if usesGlassSurfaces, #available(macOS 26.0, *) {
                    shape
                        .fill(.clear)
                        .glassEffect(.clear, in: shape)
                        .allowsHitTesting(false)
                } else {
                    shape
                        .fill(.ultraThinMaterial)
                        .overlay(shape.fill(.white.opacity(0.035)))
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                shape
                    .stroke(.white.opacity(0.18), lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}
