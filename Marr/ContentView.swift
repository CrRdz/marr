import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var controller: MarrController
    @ObservedObject private var historyStore: ConversationHistoryStore
    @Environment(\.openWindow) private var openWindow
    @AppStorage("general.showProviderInMenu") private var showProviderInMenu = true

    init(controller: MarrController) {
        self.controller = controller
        historyStore = controller.historyStore
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            VStack(alignment: .leading, spacing: 10) {
                menuAction(
                    title: "History",
                    subtitle: "\(historyStore.conversations.count) saved",
                    systemImage: "clock.arrow.circlepath"
                ) {
                    openWindow(id: "history")
                }
                menuAction(
                    title: "Settings",
                    subtitle: showProviderInMenu ? controller.provider.rawValue : "",
                    systemImage: "gearshape"
                ) {
                    openWindow(id: "settings")
                }
            }
            .padding(14)

            Divider()

            footer
        }
        .frame(width: 360)
        .background(.ultraThinMaterial)
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "viewfinder")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .marrGlassSurface(cornerRadius: 10, isClear: true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Marr")
                    .font(MarrTypography.display(size: 22, weight: .semibold))
                Text("Screen-aware AI companion")
                    .font(MarrTypography.latin(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 7) {
                if statusTitle == "Needs attention" {
                    Text(statusTitle)
                        .font(MarrTypography.body(size: 11, weight: .semibold))
                        .foregroundStyle(statusColor)
                }

                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                    .help(statusDetail)

                Text("⌘⇧0")
                    .font(MarrTypography.mono(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func menuAction(
        title: String,
        subtitle: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)

                Text(title)
                    .font(MarrTypography.body(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer()

                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(MarrTypography.body(size: 12))
                        .foregroundStyle(.secondary)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .marrGlassSurface(cornerRadius: 12, isClear: true)
    }

    private var footer: some View {
        HStack {
            Button("Quit") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(MarrTypography.body(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
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
}
