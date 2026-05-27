import AppKit
import SwiftUI

struct ContentView: View {
    private let client: VisionAIClient

    @State private var provider: InferenceProvider = .openAI
    @State private var apiKey = ""
    @State private var gatewayBaseURL = "https://api.openai.com/v1"
    @State private var gatewayAPIKey = ""
    @State private var gatewayAuthScheme: GatewayAuthScheme = .bearer
    @State private var gatewayAPIFormat: GatewayAPIFormat = .openAIResponses
    @State private var customHeadersText = ""
    @State private var model = "gpt-4.1-mini"
    @State private var question = ""
    @State private var answer = ""
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var selectedImage: PickedImage?

    init(client: VisionAIClient) {
        self.client = client
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("OpenLens")
                .font(.largeTitle.bold())

            connectionSettings

            modelSettings

            Divider()

            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        selectImage()
                    } label: {
                        Label("Choose Image", systemImage: "photo")
                    }

                    if let selectedImage {
                        Text(selectedImage.fileName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("PNG, JPG, or JPEG")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    imagePreview
                }
                .frame(width: 300)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Question")
                        .font(.headline)

                    TextEditor(text: $question)
                        .font(.body)
                        .frame(minHeight: 120)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.25))
                        )

                    HStack {
                        Button {
                            ask()
                        } label: {
                            Label("Ask", systemImage: "paperplane.fill")
                        }
                        .keyboardShortcut(.return, modifiers: [.command])
                        .disabled(isLoading)

                        if isLoading {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading...")
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Answer")
                        .font(.headline)

                    Spacer()

                    Button {
                        copyAnswer()
                    } label: {
                        Label("Copy Answer", systemImage: "doc.on.doc")
                    }
                    .disabled(answer.isEmpty)
                }

                ScrollView {
                    Text(answer.isEmpty ? "The answer will appear here." : answer)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(answer.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .padding(12)
                }
                .frame(minHeight: 180)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.2))
                )
            }

            Spacer(minLength: 0)
        }
        .padding(24)
    }

    private var connectionSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Connection", systemImage: "network")
                    .font(.headline)

                Spacer()

                Picker("Provider", selection: $provider) {
                    ForEach(InferenceProvider.allCases) { provider in
                        Text(provider.rawValue).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
            }

            if provider == .openAI {
                LabeledContent("OpenAI API Key") {
                    SecureField("sk-...", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Spacer()

                        Button {
                            useCCSwitchClaudeDesktopPreset()
                        } label: {
                            Label("Use CC Switch", systemImage: "switch.2")
                        }
                    }

                    LabeledContent("Gateway Base URL") {
                        TextField("https://gateway.example.com/v1", text: $gatewayBaseURL)
                            .textFieldStyle(.roundedBorder)
                    }

                    LabeledContent("API Format") {
                        Picker("API Format", selection: $gatewayAPIFormat) {
                            ForEach(GatewayAPIFormat.allCases) { format in
                                Text(format.rawValue).tag(format)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }

                    LabeledContent("Gateway API Key") {
                        SecureField("Gateway key", text: $gatewayAPIKey)
                            .textFieldStyle(.roundedBorder)
                    }

                    LabeledContent("Gateway Auth Scheme") {
                        Picker("Gateway Auth Scheme", selection: $gatewayAuthScheme) {
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

                        TextEditor(text: $customHeadersText)
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
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.18))
                )
            }
        }
    }

    private var modelSettings: some View {
        LabeledContent("Model") {
            TextField("Model", text: $model)
                .textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder
    private var imagePreview: some View {
        if let nsImage = selectedImage?.image {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFit()
                .frame(width: 300, height: 220)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.2))
                )
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.08))
                VStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.system(size: 32))
                    Text("No image selected")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 300, height: 220)
        }
    }

    private func selectImage() {
        errorMessage = nil
        if let image = ImagePicker.pickImage() {
            selectedImage = image
            answer = ""
        }
    }

    private func ask() {
        errorMessage = nil

        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedGatewayBaseURL = gatewayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedGatewayAPIKey = gatewayAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)

        guard provider != .openAI || !trimmedAPIKey.isEmpty else {
            errorMessage = "Please enter an OpenAI API Key."
            return
        }

        guard provider != .gateway || !trimmedGatewayBaseURL.isEmpty else {
            errorMessage = "Please enter a Gateway Base URL."
            return
        }

        guard provider != .gateway || gatewayAuthScheme == .none || !trimmedGatewayAPIKey.isEmpty else {
            errorMessage = "Please enter a Gateway API Key, or set Gateway Auth Scheme to None."
            return
        }

        guard let selectedImage else {
            errorMessage = "Please choose an image first."
            return
        }

        guard !trimmedQuestion.isEmpty else {
            errorMessage = "Please enter a question."
            return
        }

        guard !trimmedModel.isEmpty else {
            errorMessage = "Please enter a model name."
            return
        }

        isLoading = true
        answer = ""

        Task {
            do {
                let response = try await client.ask(
                    imageData: selectedImage.data,
                    mimeType: selectedImage.mimeType,
                    question: trimmedQuestion,
                    model: trimmedModel,
                    connection: connection(
                        openAIKey: trimmedAPIKey,
                        gatewayBaseURL: trimmedGatewayBaseURL,
                        gatewayKey: trimmedGatewayAPIKey
                    )
                )

                await MainActor.run {
                    answer = response
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = userFacingMessage(for: error)
                    isLoading = false
                }
            }
        }
    }

    private func connection(openAIKey: String, gatewayBaseURL: String, gatewayKey: String) -> InferenceConnection {
        switch provider {
        case .openAI:
            return .openAI(apiKey: openAIKey)
        case .gateway:
            return InferenceConnection(
                provider: .gateway,
                baseURL: gatewayBaseURL,
                apiKey: gatewayKey,
                authScheme: gatewayAuthScheme,
                apiFormat: gatewayAPIFormat,
                customHeaders: parseCustomHeaders(customHeadersText)
            )
        }
    }

    private func parseCustomHeaders(_ text: String) -> [String: String] {
        var headers: [String: String] = [:]

        for line in text.components(separatedBy: .newlines) {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty, let separator = trimmedLine.firstIndex(of: ":") else {
                continue
            }

            let name = String(trimmedLine[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(trimmedLine[trimmedLine.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)

            if !name.isEmpty, !value.isEmpty {
                headers[name] = value
            }
        }

        return headers
    }

    private func useCCSwitchClaudeDesktopPreset() {
        provider = .gateway
        gatewayBaseURL = "http://127.0.0.1:15721/claude-desktop"
        gatewayAuthScheme = .bearer
        gatewayAPIFormat = .anthropicMessages
        model = "claude-sonnet-4-6"
    }

    private func copyAnswer() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(answer, forType: .string)
    }

    private func userFacingMessage(for error: Error) -> String {
        if let openAIError = error as? OpenAIClientError {
            return openAIError.localizedDescription
        }

        if let urlError = error as? URLError {
            return "Network error: \(urlError.localizedDescription)"
        }

        return error.localizedDescription
    }
}
