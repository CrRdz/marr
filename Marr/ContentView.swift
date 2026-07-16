import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var controller: MarrController
    @Environment(\.openWindow) private var openWindow
    @AppStorage("menu.showStatus") private var showStatus = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            menuDivider
            secondaryActions
        }
        .padding(.leading, 12)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
        .frame(width: 220)
        .marrGlassSurface(cornerRadius: 18, isClear: true)
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

    private var menuDivider: some View {
        Rectangle()
            .fill(.secondary.opacity(0.22))
            .frame(height: 1)
            .padding(.vertical, 6)
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
            Color.clear.marrGlassSurface(cornerRadius: 8, isClear: true)
        } else {
            shape.fill(.clear)
        }
    }

    private var selectedAccent: MarrAccentColor {
        MarrAccentColor.resolve(accentColor)
    }
}

private extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
