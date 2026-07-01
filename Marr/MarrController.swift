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
    @Published private(set) var hotKeyConfiguration = MarrHotKeyConfiguration.current
    @Published private(set) var windowCaptureHotKeyConfiguration = MarrWindowCaptureHotKeyConfiguration.current
    let historyStore: ConversationHistoryStore

    private let client: VisionAIClient
    private var captureHotKeyManager: HotKeyManager?
    private var windowCaptureHotKeyManager: HotKeyManager?
    private var overlayController: ScreenshotOverlayController?
    private var windowCaptureOverlayController: WindowCaptureOverlayController?
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
        guard captureHotKeyManager == nil, windowCaptureHotKeyManager == nil else {
            return
        }

        registerHotKeys(
            captureConfiguration: MarrHotKeyConfiguration.current,
            windowConfiguration: MarrWindowCaptureHotKeyConfiguration.current
        )
    }

    func reloadHotKey() {
        registerHotKeys(
            captureConfiguration: MarrHotKeyConfiguration.current,
            windowConfiguration: MarrWindowCaptureHotKeyConfiguration.current
        )
    }

    private func registerHotKeys(
        captureConfiguration: MarrHotKeyConfiguration,
        windowConfiguration: MarrWindowCaptureHotKeyConfiguration
    ) {
        captureHotKeyManager?.unregister()
        windowCaptureHotKeyManager?.unregister()
        captureHotKeyManager = nil
        windowCaptureHotKeyManager = nil
        hotKeyConfiguration = captureConfiguration
        windowCaptureHotKeyConfiguration = windowConfiguration

        guard captureConfiguration.scope != .disabled else {
            statusMessage = "Capture shortcut disabled."
            return
        }

        let nextCaptureHotKeyManager = HotKeyManager(
            keyCode: captureConfiguration.keyCode,
            modifiers: captureConfiguration.modifiers,
            identifier: 1
        ) { [weak self] in
            Task { @MainActor in
                guard let self, self.hotKeyConfiguration.allowsCurrentFrontmostApplication() else {
                    return
                }
                self.startScreenCapture()
            }
        }

        let nextWindowCaptureHotKeyManager = HotKeyManager(
            keyCode: windowConfiguration.keyCode,
            modifiers: windowConfiguration.modifiers,
            identifier: 2
        ) { [weak self] in
            Task { @MainActor in
                guard let self, self.hotKeyConfiguration.allowsCurrentFrontmostApplication() else {
                    return
                }
                self.captureFrontmostWindow()
            }
        }

        var readyMessages: [String] = []
        var warningMessages: [String] = []

        do {
            try nextCaptureHotKeyManager.register()
            captureHotKeyManager = nextCaptureHotKeyManager
            readyMessages.append("\(captureConfiguration.displayString) to capture")
        } catch {
            warningMessages.append("Could not register \(captureConfiguration.displayString): \(error.localizedDescription)")
        }

        do {
            try nextWindowCaptureHotKeyManager.register()
            windowCaptureHotKeyManager = nextWindowCaptureHotKeyManager
            readyMessages.append("\(windowConfiguration.displayString) for window")
        } catch {
            warningMessages.append("Could not register \(windowConfiguration.displayString): \(error.localizedDescription)")
        }

        if readyMessages.isEmpty {
            statusMessage = warningMessages.joined(separator: " ")
        } else if warningMessages.isEmpty {
            statusMessage = "Ready. Press \(readyMessages.joined(separator: ", "))."
        } else {
            statusMessage = "Ready. Press \(readyMessages.joined(separator: ", ")). \(warningMessages.joined(separator: " "))"
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

    func captureFrontmostWindow() {
        guard overlayController == nil, windowCaptureOverlayController == nil else {
            statusMessage = "Capture already active."
            return
        }

        let candidates = WindowCapture.captureCandidates()
        guard !candidates.isEmpty else {
            statusMessage = "No capturable window found."
            return
        }

        let overlay = WindowCaptureOverlayController(candidates: candidates)
        overlay.onCancel = { [weak self] in
            Task { @MainActor in
                self?.windowCaptureOverlayController = nil
                self?.statusMessage = "Window capture cancelled."
            }
        }
        overlay.onCapture = { [weak self] candidate in
            Task { @MainActor in
                guard let self else {
                    return
                }

                self.windowCaptureOverlayController = nil

                do {
                    let capturedWindow = try WindowCapture.capture(candidate)
                    let question = "Send a screenshot of \(capturedWindow.title)"

                    if let answerPanelController = self.answerPanelController {
                        answerPanelController.appendScreenshot(capturedWindow.image)
                    } else {
                        self.showAnswerPanel(
                            for: capturedWindow.image,
                            near: capturedWindow.anchorRect,
                            question: question
                        )
                    }

                    self.statusMessage = "Window captured."
                } catch {
                    self.statusMessage = self.userFacingMessage(for: error)
                }
            }
        }

        windowCaptureOverlayController = overlay
        overlay.show()
        statusMessage = "Choose a window to capture."
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
        windowCaptureOverlayController?.close()
        windowCaptureOverlayController = nil
        nativeScreenshotController?.cancel()
        nativeScreenshotController = nil
        statusMessage = "Ready. Press \(hotKeyConfiguration.displayString) to capture."
    }

    func minimizeAnswerPanel() {
        answerPanelController?.minimize()
        statusMessage = "Answer panel minimized. Press \(hotKeyConfiguration.displayString) to restore it."
    }

    func setAnswerPanelHistoryExpanded(_ isExpanded: Bool) {
        answerPanelController?.setHistoryExpanded(isExpanded)
    }

    func openHistoryConversation(_ conversation: ConversationHistoryRecord) {
        let imageSources = conversation.images.map { image in
            HistoryImageAssetSource(
                reference: image,
                urls: historyStore.imageFileURLs(conversationID: conversation.id, imageID: image.id)
            )
        }
        statusMessage = "Opening history conversation..."

        Task {
            let imageAssets = await Task.detached(priority: .userInitiated) {
                imageSources.compactMap { source -> ConversationImageAsset? in
                    guard let url = source.urls.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
                          let data = try? Data(contentsOf: url)
                    else {
                        return nil
                    }
                    return ConversationImageAsset(
                        id: source.reference.id,
                        data: data,
                        mimeType: source.reference.mimeType,
                        fileName: source.reference.fileName
                    )
                }
            }.value

            await MainActor.run {
                let session = ConversationSession(
                    historyRecord: conversation,
                    imageAssets: imageAssets
                )
                showAnswerPanel(
                    for: session,
                    near: defaultAnswerPanelAnchorRect(),
                    persistImmediately: false
                )
                statusMessage = "History conversation opened."
            }
        }
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
        let session = ConversationSession(initialImage: image, initialQuestion: question)
        showAnswerPanel(for: session, near: rect, persistImmediately: true)
    }

    private func showAnswerPanel(
        for session: ConversationSession,
        near rect: CGRect,
        persistImmediately: Bool
    ) {
        answerPanelController?.close()
        let panel = AnswerPanelController(
            controller: self,
            historyStore: historyStore,
            session: session,
            anchorRect: rect,
            persistImmediately: persistImmediately
        )
        answerPanelController = panel
        panel.show()
    }

    private func defaultAnswerPanelAnchorRect() -> CGRect {
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            return screen.visibleFrame
        }
        return CGRect(x: 0, y: 0, width: 1, height: 1)
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

private struct HistoryImageAssetSource: Sendable {
    let reference: ConversationImageReference
    let urls: [URL]
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
