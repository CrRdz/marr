import AppKit
import Carbon
import SwiftUI

@MainActor
final class OpenLensController: ObservableObject {
    @Published var provider: InferenceProvider = .gateway
    @Published var apiKey = ""
    @Published var gatewayBaseURL = "http://127.0.0.1:15721/claude-desktop"
    @Published var gatewayAPIKey = ""
    @Published var gatewayAuthScheme: GatewayAuthScheme = .bearer
    @Published var gatewayAPIFormat: GatewayAPIFormat = .anthropicMessages
    @Published var customHeadersText = ""
    @Published var model = "claude-sonnet-4-6"
    @Published var statusMessage: String?

    private let client: VisionAIClient
    private var hotKeyManager: HotKeyManager?
    private var overlayController: ScreenshotOverlayController?
    private var askPanelController: AskPanelController?
    private var nativeScreenshotController: NativeScreenshotController?

    init(client: VisionAIClient) {
        self.client = client
    }

    func installHotKeyIfNeeded() {
        guard hotKeyManager == nil else {
            return
        }

        hotKeyManager = HotKeyManager(keyCode: UInt32(kVK_ANSI_0), modifiers: UInt32(cmdKey | shiftKey)) { [weak self] in
            Task { @MainActor in
                self?.startScreenCapture()
            }
        }

        do {
            try hotKeyManager?.register()
            statusMessage = "Ready. Press Command Shift 0 to capture."
        } catch {
            statusMessage = "Could not register Command Shift 0: \(error.localizedDescription)"
        }
    }

    func startScreenCapture() {
        overlayController?.close()
        askPanelController?.close()
        nativeScreenshotController?.cancel()

        let screenshotController = NativeScreenshotController()
        nativeScreenshotController = screenshotController
        statusMessage = "Select an area with the macOS screenshot tool."

        screenshotController.capture { [weak self] result in
            Task { @MainActor in
                guard let self else {
                    return
                }

                self.nativeScreenshotController = nil

                switch result {
                case .success(let image):
                    self.showQuestionPanel(for: image, near: self.defaultAskPanelAnchor())
                    self.statusMessage = "Screenshot captured."
                case .failure(let error):
                    self.statusMessage = self.userFacingMessage(for: error)
                }
            }
        }
    }

    func startCustomOverlayCapture() {
        let overlay = ScreenshotOverlayController()
        overlay.onCancel = { [weak self] in
            Task { @MainActor in
                self?.overlayController = nil
                self?.statusMessage = "Capture cancelled."
            }
        }
        overlay.onCapture = { [weak self] image, rect in
            Task { @MainActor in
                self?.overlayController = nil
                self?.showQuestionPanel(for: image, near: rect)
                self?.statusMessage = "Screenshot captured."
            }
        }
        overlayController = overlay
        overlay.show()
        statusMessage = "Drag or resize the selection, then capture."
    }

    func useCCSwitchClaudeDesktopPreset() {
        provider = .gateway
        gatewayBaseURL = "http://127.0.0.1:15721/claude-desktop"
        gatewayAuthScheme = .bearer
        gatewayAPIFormat = .anthropicMessages
        model = "claude-sonnet-4-6"
    }

    func submit(image: PickedImage, question: String) async throws -> String {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedGatewayBaseURL = gatewayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedGatewayAPIKey = gatewayAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard provider != .openAI || !trimmedAPIKey.isEmpty else {
            throw UserFacingError("Please enter an OpenAI API Key.")
        }

        guard provider != .gateway || !trimmedGatewayBaseURL.isEmpty else {
            throw UserFacingError("Please enter a Gateway Base URL.")
        }

        guard provider != .gateway || gatewayAuthScheme == .none || !trimmedGatewayAPIKey.isEmpty else {
            throw UserFacingError("Please enter a Gateway API Key, or set Gateway Auth Scheme to None.")
        }

        guard !trimmedQuestion.isEmpty else {
            throw UserFacingError("Please enter a question.")
        }

        guard !trimmedModel.isEmpty else {
            throw UserFacingError("Please enter a model name.")
        }

        let requestConnection = connection(
            openAIKey: trimmedAPIKey,
            gatewayBaseURL: trimmedGatewayBaseURL,
            gatewayKey: trimmedGatewayAPIKey
        )
        let client = client
        let imageData = image.data
        let mimeType = image.mimeType

        return try await Task.detached(priority: .userInitiated) {
            try await client.ask(
                imageData: imageData,
                mimeType: mimeType,
                question: trimmedQuestion,
                model: trimmedModel,
                connection: requestConnection
            )
        }.value
    }

    func copyAnswer(_ answer: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(answer, forType: .string)
    }

    func userFacingMessage(for error: Error) -> String {
        if let userFacingError = error as? UserFacingError {
            return userFacingError.message
        }

        if let openAIError = error as? OpenAIClientError {
            return openAIError.localizedDescription
        }

        if let urlError = error as? URLError {
            return "Network error: \(urlError.localizedDescription)"
        }

        return error.localizedDescription
    }

    private func showQuestionPanel(for image: PickedImage, near rect: CGRect) {
        let panel = AskPanelController(controller: self, image: image, anchorRect: rect)
        askPanelController = panel
        panel.show()
    }

    private func defaultAskPanelAnchor() -> CGRect {
        let mouseLocation = NSEvent.mouseLocation
        return CGRect(x: mouseLocation.x, y: mouseLocation.y, width: 1, height: 1)
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
}

struct UserFacingError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}
