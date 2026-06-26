import AppKit
import Carbon
import SwiftUI

@MainActor
final class MarrController: ObservableObject {
    @Published var provider: InferenceProvider = .gateway
    @Published var apiKey = ""
    @Published var gatewayBaseURL = "http://127.0.0.1:15721/claude-desktop"
    @Published var gatewayAPIKey = ""
    @Published var gatewayAuthScheme: GatewayAuthScheme = .bearer
    @Published var gatewayAPIFormat: GatewayAPIFormat = .anthropicMessages
    @Published var customHeadersText = ""
    @Published var model = "claude-sonnet-4-6"
    @Published var statusMessage: String?
    let historyStore: ConversationHistoryStore

    private let client: VisionAIClient
    private var hotKeyManager: HotKeyManager?
    private var overlayController: ScreenshotOverlayController?
    private var answerPanelController: AnswerPanelController?
    private var nativeScreenshotController: NativeScreenshotController?

    init(
        client: VisionAIClient,
        historyStore: ConversationHistoryStore? = nil
    ) {
        self.client = client
        self.historyStore = historyStore ?? ConversationHistoryStore()
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
        guard overlayController == nil else {
            statusMessage = "Capture already active."
            return
        }

        if let answerPanelController {
            if answerPanelController.isMinimized {
                answerPanelController.restore()
                statusMessage = "Answer panel restored."
                return
            }
            startAppendScreenshotCapture()
        } else {
            startCustomOverlayCapture()
        }
    }

    func startCustomOverlayCapture() {
        guard overlayController == nil else {
            statusMessage = "Capture already active."
            return
        }

        let overlay = ScreenshotOverlayController()
        overlay.onCancel = { [weak self] in
            Task { @MainActor in
                self?.overlayController = nil
                self?.statusMessage = "Capture cancelled."
            }
        }
        overlay.onCapture = { [weak self] image, rect, question in
            Task { @MainActor in
                self?.overlayController = nil
                self?.showAnswerPanel(for: image, near: rect, question: question)
                self?.statusMessage = "Screenshot captured."
            }
        }
        overlayController = overlay
        overlay.show()
        statusMessage = "Drag or resize the selection, then capture."
    }

    func startAppendScreenshotCapture() {
        guard overlayController == nil else {
            statusMessage = "Capture already active."
            return
        }

        let overlay = ScreenshotOverlayController(mode: .selectionOnly)
        overlay.onCancel = { [weak self] in
            Task { @MainActor in
                self?.overlayController = nil
                self?.statusMessage = "Capture cancelled."
            }
        }
        overlay.onCapture = { [weak self] image, _, _ in
            Task { @MainActor in
                self?.overlayController = nil
                self?.answerPanelController?.appendScreenshot(image)
                self?.statusMessage = "Screenshot added to the current conversation."
            }
        }
        overlayController = overlay
        overlay.show()
        statusMessage = "Select an area, then press Return to add it to the current conversation."
    }

    func useCCSwitchClaudeDesktopPreset() {
        provider = .gateway
        gatewayBaseURL = "http://127.0.0.1:15721/claude-desktop"
        gatewayAuthScheme = .bearer
        gatewayAPIFormat = .anthropicMessages
        model = "claude-sonnet-4-6"
    }

    func submit(request: VisionRequest) async throws -> String {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedGatewayBaseURL = gatewayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedGatewayAPIKey = gatewayAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard provider != .openAI || !trimmedAPIKey.isEmpty else {
            throw UserFacingError("OpenAI API Key required.")
        }

        guard provider != .gateway || !trimmedGatewayBaseURL.isEmpty else {
            throw UserFacingError("Gateway Base URL required.")
        }

        guard provider != .gateway || gatewayAuthScheme == .none || !trimmedGatewayAPIKey.isEmpty else {
            throw UserFacingError("Gateway API Key required, or set auth to None.")
        }

        guard !request.messages.isEmpty else {
            throw UserFacingError("Conversation request is empty.")
        }

        guard !trimmedModel.isEmpty else {
            throw UserFacingError("Model name required.")
        }

        let requestConnection = connection(
            openAIKey: trimmedAPIKey,
            gatewayBaseURL: trimmedGatewayBaseURL,
            gatewayKey: trimmedGatewayAPIKey
        )
        let client = client
        return try await Task.detached(priority: .userInitiated) {
            try await client.ask(
                request: request,
                model: trimmedModel,
                connection: requestConnection
            )
        }.value
    }

    func copyAnswer(_ answer: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(answer, forType: .string)
    }

    func dismissCaptureSession() {
        answerPanelController?.close()
        answerPanelController = nil
        overlayController?.close()
        overlayController = nil
        nativeScreenshotController?.cancel()
        nativeScreenshotController = nil
        statusMessage = "Ready. Press Command Shift 0 to capture."
    }

    func minimizeAnswerPanel() {
        answerPanelController?.minimize()
        statusMessage = "Answer panel minimized. Press Command Shift 0 to restore it."
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

    private func showAnswerPanel(for image: PickedImage, near rect: CGRect, question: String) {
        answerPanelController?.close()
        let panel = AnswerPanelController(
            controller: self,
            historyStore: historyStore,
            image: image,
            anchorRect: rect,
            initialQuestion: question
        )
        answerPanelController = panel
        panel.show()
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
