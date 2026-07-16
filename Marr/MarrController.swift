import AppKit
import Carbon
import MarrCore
import MarrNetworking
import MarrSettings
import SwiftUI

@MainActor
final class MarrController: ObservableObject {
    @Published var provider: InferenceProvider = .gateway { didSet { scheduleInferenceSettingsSave() } }
    @Published var apiKey = "" { didSet { scheduleInferenceSettingsSave() } }
    @Published var gatewayBaseURL = "http://127.0.0.1:15721/claude-desktop" { didSet { scheduleInferenceSettingsSave() } }
    @Published var gatewayAPIKey = "" { didSet { scheduleInferenceSettingsSave() } }
    @Published var gatewayAuthScheme: GatewayAuthScheme = .bearer { didSet { scheduleInferenceSettingsSave() } }
    @Published var gatewayAPIFormat: GatewayAPIFormat = .anthropicMessages { didSet { scheduleInferenceSettingsSave() } }
    @Published var customHeadersText = "" { didSet { scheduleInferenceSettingsSave() } }
    @Published var model = "claude-sonnet-4-6" { didSet { scheduleInferenceSettingsSave() } }
    @Published var maximumOutputTokens = 4_096 { didSet { scheduleInferenceSettingsSave() } }
    @Published var statusMessage: String?
    @Published private(set) var hotKeyConfiguration = MarrHotKeyConfiguration.current
    @Published private(set) var windowCaptureHotKeyConfiguration = MarrWindowCaptureHotKeyConfiguration.current
    let historyStore: ConversationHistoryStore

    private let client: VisionAIClient
    private let settingsRepository: InferenceSettingsRepository
    private var settingsSaveTask: Task<Void, Never>?
    private var translationTask: Task<Void, Never>?
    private var windowCaptureTask: Task<Void, Never>?
    private var captureHotKeyManager: HotKeyManager?
    private var windowCaptureHotKeyManager: HotKeyManager?
    private var overlayController: ScreenshotOverlayController?
    private var windowCaptureOverlayController: WindowCaptureOverlayController?
    private var answerPanelController: AnswerPanelController?
    private var translationOverlayController: TranslationOverlayController?

    init(
        client: VisionAIClient,
        historyStore: ConversationHistoryStore? = nil,
        settingsRepository: InferenceSettingsRepository = InferenceSettingsRepository()
    ) {
        self.client = client
        self.historyStore = historyStore ?? ConversationHistoryStore()
        self.settingsRepository = settingsRepository

        do {
            let settings = try settingsRepository.load()
            provider = settings.provider
            apiKey = settings.openAIAPIKey
            gatewayBaseURL = settings.gatewayBaseURL
            gatewayAPIKey = settings.gatewayAPIKey
            gatewayAuthScheme = settings.gatewayAuthScheme
            gatewayAPIFormat = settings.gatewayAPIFormat
            customHeadersText = settings.customHeadersText
            model = settings.model
            maximumOutputTokens = settings.maximumOutputTokens
        } catch {
            statusMessage = "Could not load AI settings: \(error.localizedDescription)"
        }
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
            readyMessages.append("\(captureConfiguration.displayString) for area")
        } catch {
            warningMessages.append("Could not register \(captureConfiguration.displayString): \(error.localizedDescription)")
        }

        do {
            try nextWindowCaptureHotKeyManager.register()
            windowCaptureHotKeyManager = nextWindowCaptureHotKeyManager
            readyMessages.append("\(windowConfiguration.displayString) for current window")
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
        guard overlayController == nil, windowCaptureOverlayController == nil else {
            statusMessage = "Capture already active."
            return
        }

        let windowCandidates = currentWindowCaptureCandidates()
        if answerPanelController != nil {
            startAppendScreenshotCapture(windowCandidates: windowCandidates)
        } else {
            startCustomOverlayCapture(windowCandidates: windowCandidates)
        }
    }

    func captureFrontmostWindow() {
        guard overlayController == nil, windowCaptureOverlayController == nil else {
            statusMessage = "Capture already active."
            return
        }

        guard
            let frontmostApplication = NSWorkspace.shared.frontmostApplication,
            frontmostApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else {
            statusMessage = "No current application window found."
            return
        }

        let candidates = WindowCapture.captureCandidates(
            for: frontmostApplication.processIdentifier
        )
        guard !candidates.isEmpty else {
            statusMessage = "No open window found for \(frontmostApplication.localizedName ?? "the current application")."
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
                guard let self else { return }

                self.windowCaptureOverlayController = nil
                self.captureSelectedWindow(candidate)
            }
        }

        windowCaptureOverlayController = overlay
        overlay.show()
        statusMessage = candidates.count == 1
            ? "Click the current window to capture it."
            : "Choose an open window in the current application."
    }

    func startCustomOverlayCapture(
        windowCandidates: [WindowCaptureCandidate] = []
    ) {
        guard overlayController == nil, windowCaptureOverlayController == nil else {
            statusMessage = "Capture already active."
            return
        }

        let overlay = ScreenshotOverlayController(windowCandidates: windowCandidates)
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
        overlay.onTranslate = { [weak self] image, rect in
            Task { @MainActor in
                guard let self else {
                    return
                }

                self.overlayController = nil
                self.translateScreenshot(image, near: rect)
            }
        }
        overlay.onWindowCapture = { [weak self] candidate in
            Task { @MainActor in
                guard let self else { return }
                self.overlayController = nil
                self.captureSelectedWindow(candidate)
            }
        }
        overlayController = overlay
        overlay.show()
        statusMessage = windowCandidates.isEmpty
            ? "Drag to take a screenshot."
            : "Drag to select an area, or click an open window."
    }

    func startAppendScreenshotCapture(
        windowCandidates: [WindowCaptureCandidate] = []
    ) {
        guard overlayController == nil, windowCaptureOverlayController == nil else {
            statusMessage = "Capture already active."
            return
        }

        let overlay = ScreenshotOverlayController(
            mode: .selectionOnly,
            windowCandidates: windowCandidates
        )
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
        overlay.onWindowCapture = { [weak self] candidate in
            Task { @MainActor in
                guard let self else { return }
                self.overlayController = nil
                self.captureSelectedWindow(candidate)
            }
        }
        overlayController = overlay
        overlay.show()
        statusMessage = windowCandidates.isEmpty
            ? "Drag to select an area, then press Return to add it to the current conversation."
            : "Drag to select an area, or click an open window."
    }

    private func currentWindowCaptureCandidates() -> [WindowCaptureCandidate] {
        WindowCapture.captureCandidatesForFrontmostApplication()
    }

    private func captureSelectedWindow(_ candidate: WindowCaptureCandidate) {
        windowCaptureTask?.cancel()
        statusMessage = "Capturing current window..."
        windowCaptureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.windowCaptureTask = nil }

            do {
                let capturedWindow = try await WindowCapture.capture(candidate)
                try Task.checkCancellation()
                let question = WindowCapture.analysisQuestion(
                    appName: capturedWindow.appName,
                    title: capturedWindow.title
                )

                if let answerPanelController = self.answerPanelController {
                    answerPanelController.appendScreenshot(capturedWindow.image)
                } else {
                    self.showAnswerPanel(
                        for: capturedWindow.image,
                        near: capturedWindow.anchorRect,
                        question: question
                    )
                }

                self.statusMessage = "Current window captured."
            } catch is CancellationError {
                return
            } catch {
                self.statusMessage = self.userFacingMessage(for: error)
            }
        }
    }

    func useCCSwitchClaudeDesktopPreset() {
        provider = .gateway
        gatewayBaseURL = "http://127.0.0.1:15721/claude-desktop"
        gatewayAuthScheme = .bearer
        gatewayAPIFormat = .anthropicMessages
        model = "claude-sonnet-4-6"
    }

    func submit(request: MarrCore.VisionRequest) async throws -> String {
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
        return try await client.ask(
            request: request,
            model: trimmedModel,
            connection: requestConnection
        )
    }

    private func translateScreenshot(_ image: PickedImage, near rect: CGRect) {
        translationTask?.cancel()
        translationOverlayController?.close()

        let overlay = TranslationOverlayController(anchorRect: rect)
        translationOverlayController = overlay
        overlay.onClose = { [weak self, weak overlay] in
            guard
                let self,
                let overlay,
                self.translationOverlayController === overlay
            else {
                return
            }

            self.translationTask?.cancel()
            self.translationTask = nil
            self.translationOverlayController = nil
        }
        overlay.show()
        statusMessage = "Translating screenshot..."

        translationTask = Task { [weak self, weak overlay] in
            guard let self else {
                return
            }

            do {
                let recognition = try await BackgroundOperation.run(priority: .userInitiated) {
                    do {
                        try Task.checkCancellation()
                        let regions = try ImageTranslationTextRecognizer.regions(for: image)
                        try Task.checkCancellation()
                        return (regions: regions, succeeded: true)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return (regions: [], succeeded: false)
                    }
                }
                let regions = recognition.regions
                if recognition.succeeded, regions.isEmpty {
                    guard
                        let overlay,
                        self.translationOverlayController === overlay
                    else {
                        return
                    }
                    guard let originalImage = NSImage(data: image.data) else {
                        overlay.showError("Could not render translation.")
                        self.statusMessage = "Could not render translation."
                        return
                    }
                    overlay.showTranslatedImage(originalImage, originalImage: originalImage)
                    self.statusMessage = "No translatable text found."
                    return
                }
                let request = regions.isEmpty
                    ? ImageTranslationPrompt.request(for: image)
                    : ImageTranslationPrompt.request(for: image, regions: regions)
                let response = try await self.submit(request: request)
                let blocks: [ImageTranslationBlock]

                if regions.isEmpty {
                    blocks = ImageTranslationResponseParser.parse(response)
                } else {
                    let parsedReplacements = ImageTranslationResponseParser.parseReplacements(response)
                    let replacements = try await self.completedTranslationReplacements(
                        parsedReplacements,
                        image: image,
                        regions: regions
                    )
                    let mergedBlocks = ImageTranslationResponseParser.merge(
                        replacements: replacements,
                        regions: regions
                    )
                    blocks = mergedBlocks
                }

                try Task.checkCancellation()
                let translatedImageData = try await BackgroundOperation.run(priority: .userInitiated) {
                    try Task.checkCancellation()
                    let data = ImageTranslationRenderer.renderData(sourceData: image.data, blocks: blocks)
                    try Task.checkCancellation()
                    return data
                }
                try Task.checkCancellation()

                await MainActor.run {
                    guard
                        let overlay,
                        self.translationOverlayController === overlay
                    else {
                        return
                    }

                    guard
                        let originalImage = NSImage(data: image.data),
                        let translatedImageData,
                        let translatedImage = NSImage(data: translatedImageData)
                    else {
                        overlay.showError("Could not render translation.")
                        self.statusMessage = "Could not render translation."
                        return
                    }

                    overlay.showTranslatedImage(translatedImage, originalImage: originalImage)
                    self.statusMessage = blocks.isEmpty ? "No translatable text found." : "Translation ready."
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    guard
                        let overlay,
                        self.translationOverlayController === overlay
                    else {
                        return
                    }

                    let message = self.userFacingMessage(for: error)
                    overlay.showError(message)
                    self.statusMessage = message
                }
            }
        }
    }

    private func completedTranslationReplacements(
        _ replacements: [ImageTranslationReplacement],
        image: PickedImage,
        regions: [ImageTranslationSourceRegion]
    ) async throws -> [ImageTranslationReplacement] {
        let missingRegions = missingTranslationRegions(in: regions, replacements: replacements)
        guard !missingRegions.isEmpty else {
            return replacements
        }

        let retryRequest = ImageTranslationPrompt.request(for: image, regions: missingRegions)
        let retryResponse = try await submit(request: retryRequest)
        return combinedTranslationReplacements(
            replacements,
            ImageTranslationResponseParser.parseReplacements(retryResponse)
        )
    }

    private func missingTranslationRegions(
        in regions: [ImageTranslationSourceRegion],
        replacements: [ImageTranslationReplacement]
    ) -> [ImageTranslationSourceRegion] {
        let replacementByID = Dictionary(
            replacements.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return regions.filter { region in
            guard let replacement = replacementByID[region.id] else {
                return true
            }
            switch region.translationStrategy {
            case .block:
                return replacement.text.isEmpty
            case .selective:
                return replacement.segments.isEmpty && !replacement.text.isEmpty
            }
        }
    }

    private func combinedTranslationReplacements(
        _ primary: [ImageTranslationReplacement],
        _ secondary: [ImageTranslationReplacement]
    ) -> [ImageTranslationReplacement] {
        var seenIDs = Set<String>()
        var combined: [ImageTranslationReplacement] = []

        for replacement in primary + secondary where seenIDs.insert(replacement.id).inserted {
            combined.append(replacement)
        }

        return combined
    }

    func copyAnswer(_ answer: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(answer, forType: .string)
    }

    func dismissCaptureSession() {
        translationTask?.cancel()
        translationTask = nil
        windowCaptureTask?.cancel()
        windowCaptureTask = nil
        answerPanelController?.close()
        answerPanelController = nil
        overlayController?.close()
        overlayController = nil
        windowCaptureOverlayController?.close()
        windowCaptureOverlayController = nil
        translationOverlayController?.close()
        translationOverlayController = nil
        statusMessage = "Ready. Press \(hotKeyConfiguration.displayString) to capture."
    }

    func minimizeAnswerPanel() {
        answerPanelController?.minimize()
        statusMessage = "Answer panel minimized. Press \(hotKeyConfiguration.displayString) to restore it."
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
            return .openAI(apiKey: openAIKey, maximumOutputTokens: maximumOutputTokens)
        case .gateway:
            return InferenceConnection(
                provider: .gateway,
                baseURL: gatewayBaseURL,
                apiKey: gatewayKey,
                authScheme: gatewayAuthScheme,
                apiFormat: gatewayAPIFormat,
                customHeaders: parseCustomHeaders(customHeadersText),
                maximumOutputTokens: maximumOutputTokens
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

    private func scheduleInferenceSettingsSave() {
        settingsSaveTask?.cancel()
        let settings = InferenceSettingsSnapshot(
            provider: provider,
            openAIAPIKey: apiKey,
            gatewayBaseURL: gatewayBaseURL,
            gatewayAPIKey: gatewayAPIKey,
            gatewayAuthScheme: gatewayAuthScheme,
            gatewayAPIFormat: gatewayAPIFormat,
            customHeadersText: customHeadersText,
            model: model,
            maximumOutputTokens: maximumOutputTokens
        )
        let repository = settingsRepository

        settingsSaveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
                try Task.checkCancellation()
                try await BackgroundOperation.run(priority: .utility) {
                    try repository.save(settings)
                }
            } catch is CancellationError {
                return
            } catch {
                self?.statusMessage = "Could not save AI settings: \(error.localizedDescription)"
            }
        }
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
