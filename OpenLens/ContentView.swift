import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var controller: OpenLensController

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header

            captureSection

            connectionSection

            Spacer(minLength: 0)
        }
        .padding(30)
        .frame(minWidth: 760, minHeight: 620)
        .background(
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                LinearGradient(
                    colors: [
                        .white.opacity(0.20),
                        Color.accentColor.opacity(0.06),
                        .clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        )
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.thinMaterial)
                Image(systemName: "viewfinder")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 52, height: 52)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.38), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 14, x: 0, y: 8)

            VStack(alignment: .leading, spacing: 5) {
                Text("OpenLens")
                    .font(.system(size: 30, weight: .bold))

                Text("Capture any part of your screen, then ask AI about exactly what you saw.")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                controller.startScreenCapture()
            } label: {
                Label("Capture", systemImage: "camera.viewfinder")
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(.white.opacity(0.26), lineWidth: 1)
        )
    }

    private var captureSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Capture Flow", systemImage: "rectangle.dashed")
                    .font(.headline)

                Spacer()

                Text("Command Shift 0")
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }

            HStack(spacing: 12) {
                flowStep(icon: "command", title: "Shortcut", detail: "Press the global hotkey from anywhere.")
                flowStep(icon: "crop", title: "Frame", detail: "Drag or resize the selection box.")
                flowStep(icon: "text.bubble", title: "Ask", detail: "Type a question below the capture.")
                flowStep(icon: "sparkles", title: "Answer", detail: "The answer panel appears after sending.")
            }

            if let message = controller.statusMessage {
                Text(message)
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.22), lineWidth: 1)
        )
    }

    private func flowStep(icon: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(height: 24)

            Text(title)
                .font(.headline)

            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.24), lineWidth: 1)
        )
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Connection", systemImage: "network")
                    .font(.headline)

                Spacer()

                Picker("Provider", selection: $controller.provider) {
                    ForEach(InferenceProvider.allCases) { provider in
                        Text(provider.rawValue).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
            }

            if controller.provider == .openAI {
                LabeledContent("OpenAI API Key") {
                    SecureField("sk-...", text: $controller.apiKey)
                        .textFieldStyle(.roundedBorder)
                }
            } else {
                gatewaySettings
            }

            LabeledContent("Model") {
                TextField("Model", text: $controller.model)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.22), lineWidth: 1)
        )
    }

    private var gatewaySettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer()

                Button {
                    controller.useCCSwitchClaudeDesktopPreset()
                } label: {
                    Label("Use CC Switch", systemImage: "switch.2")
                }
            }

            LabeledContent("Gateway Base URL") {
                TextField("https://gateway.example.com/v1", text: $controller.gatewayBaseURL)
                    .textFieldStyle(.roundedBorder)
            }

            LabeledContent("API Format") {
                Picker("API Format", selection: $controller.gatewayAPIFormat) {
                    ForEach(GatewayAPIFormat.allCases) { format in
                        Text(format.rawValue).tag(format)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            LabeledContent("Gateway API Key") {
                SecureField("Gateway key", text: $controller.gatewayAPIKey)
                    .textFieldStyle(.roundedBorder)
            }

            LabeledContent("Gateway Auth Scheme") {
                Picker("Gateway Auth Scheme", selection: $controller.gatewayAuthScheme) {
                    ForEach(GatewayAuthScheme.allCases) { scheme in
                        Text(scheme.rawValue).tag(scheme)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Custom Headers")
                    .font(.subheadline.weight(.medium))

                TextEditor(text: $controller.customHeadersText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 72, maxHeight: 90)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.25))
                    )

                Text("One header per line, for example: X-Tenant-ID: demo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.22), lineWidth: 1)
        )
    }
}
