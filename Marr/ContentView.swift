import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var controller: MarrController
    @ObservedObject private var historyStore: ConversationHistoryStore
    @Environment(\.openWindow) private var openWindow
    @State private var showsConnectionSettings = false

    init(controller: MarrController) {
        self.controller = controller
        historyStore = controller.historyStore
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    captureSection
                    historySection
                    connectionSection
                }
                .padding(16)
            }

            Divider()
            footer
        }
        .frame(width: 390)
        .frame(minHeight: 310, maxHeight: showsConnectionSettings ? 650 : 430)
        .background(.ultraThinMaterial)
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "viewfinder")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 2) {
                Text("Marr")
                    .font(.headline)
                Text("Ask AI about anything on your screen")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var captureSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                controller.startScreenCapture()
            } label: {
                Label("Capture Screen Area", systemImage: "camera.viewfinder")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            HStack(spacing: 8) {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)

                Text(controller.statusMessage ?? "Ready to capture.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Spacer(minLength: 4)

                Text("⌘⇧0")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var connectionSection: some View {
        DisclosureGroup(isExpanded: $showsConnectionSettings) {
            VStack(alignment: .leading, spacing: 13) {
                Picker("Provider", selection: $controller.provider) {
                    ForEach(InferenceProvider.allCases) { provider in
                        Text(provider.rawValue).tag(provider)
                    }
                }
                .pickerStyle(.segmented)

                if controller.provider == .openAI {
                    field("OpenAI API Key") {
                        SecureField("sk-...", text: $controller.apiKey)
                            .textFieldStyle(.roundedBorder)
                    }
                } else {
                    gatewaySettings
                }

                field("Model") {
                    TextField("Model", text: $controller.model)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .padding(.top, 12)
        } label: {
            Label("Connection", systemImage: "network")
                .font(.system(size: 13, weight: .semibold))
        }
    }

    private var historySection: some View {
        Button {
            openWindow(id: "history")
        } label: {
            HStack {
                Label("History", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(historyStore.conversations.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var gatewaySettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Gateway")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Use CC Switch") {
                    controller.useCCSwitchClaudeDesktopPreset()
                }
                .controlSize(.small)
            }

            field("Base URL") {
                TextField("https://gateway.example.com/v1", text: $controller.gatewayBaseURL)
                    .textFieldStyle(.roundedBorder)
            }

            field("API Format") {
                Picker("API Format", selection: $controller.gatewayAPIFormat) {
                    ForEach(GatewayAPIFormat.allCases) { format in
                        Text(format.rawValue).tag(format)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            field("API Key") {
                SecureField("Gateway key", text: $controller.gatewayAPIKey)
                    .textFieldStyle(.roundedBorder)
            }

            field("Auth Scheme") {
                Picker("Auth Scheme", selection: $controller.gatewayAuthScheme) {
                    ForEach(GatewayAuthScheme.allCases) { scheme in
                        Text(scheme.rawValue).tag(scheme)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Custom Headers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $controller.customHeadersText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 58)
                    .scrollContentBackground(.hidden)
                    .padding(5)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.22)))
                Text("One header per line, for example X-Tenant-ID: demo")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("Marr runs from the menu bar")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Spacer()

            Button("Quit Marr") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var statusIcon: String {
        guard let message = controller.statusMessage else { return "checkmark.circle.fill" }
        return message.localizedCaseInsensitiveContains("could not") ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
    }

    private var statusColor: Color {
        statusIcon == "exclamationmark.triangle.fill" ? .orange : .green
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }
}
