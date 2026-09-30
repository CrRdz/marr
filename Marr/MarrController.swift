import AppKit
import Carbon
import MarrCore
import MarrNetworking
import MarrSettings
import SwiftUI

struct InferenceCredentialState: Equatable {
    enum Activity: Equatable {
        case idle
        case checking
        case saving
        case verifying
        case removing
    }

    var isConfigured: Bool?
    var activity: Activity
    var message: String?
    var messageIsError: Bool

    static let unknown = InferenceCredentialState(
        isConfigured: nil,
        activity: .idle,
        message: nil,
        messageIsError: false
    )

    var isBusy: Bool {
        activity != .idle
    }
}

@MainActor
final class MarrController: ObservableObject {
    @Published var provider: InferenceProvider = .gateway { didSet { scheduleInferenceSettingsSave() } }
    @Published var gatewayBaseURL = "http://127.0.0.1:15721/claude-desktop" { didSet { scheduleInferenceSettingsSave() } }
    @Published var gatewayAuthScheme: GatewayAuthScheme = .bearer { didSet { scheduleInferenceSettingsSave() } }
    @Published var gatewayAPIFormat: GatewayAPIFormat = .anthropicMessages { didSet { scheduleInferenceSettingsSave() } }
    @Published var model = "claude-sonnet-4-6" { didSet { scheduleInferenceSettingsSave() } }
    @Published var maximumOutputTokens = 4_096 { didSet { scheduleInferenceSettingsSave() } }
    @Published var translationUsesDedicatedConfiguration = false { didSet { scheduleInferenceSettingsSave() } }
    @Published var translationProvider: TranslationProvider = .openAI { didSet { scheduleInferenceSettingsSave() } }
    @Published var translationGatewayBaseURL = "" { didSet { scheduleInferenceSettingsSave() } }
    @Published var translationGatewayAuthScheme: GatewayAuthScheme = .bearer { didSet { scheduleInferenceSettingsSave() } }
    @Published var translationGatewayAPIFormat: GatewayAPIFormat = .openAIResponses { didSet { scheduleInferenceSettingsSave() } }
    @Published var translationDeepLXServerURL = "http://127.0.0.1:1188" { didSet { scheduleInferenceSettingsSave() } }
    @Published var translationModel = "gpt-4.1-mini" { didSet { scheduleInferenceSettingsSave() } }
    @Published var translationMaximumOutputTokens = 4_096 { didSet { scheduleInferenceSettingsSave() } }
    @Published var statusMessage: String?
    @Published private var credentialStates: [InferenceCredential: InferenceCredentialState] = [:]
    @Published private(set) var hotKeyConfiguration = MarrHotKeyConfiguration.current
    @Published private(set) var windowCaptureHotKeyConfiguration = MarrWindowCaptureHotKeyConfiguration.current
    let historyStore: ConversationHistoryStore
    let tokenUsageStore: TokenUsageStore
    let codexWorkspace = CodexWorkspaceController()

    let usesCodexForConversation: Bool
    private let client: VisionAIClient
    private let deepLXClient: DeepLXTranslationClient
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
        usesCodexForConversation: Bool = false,
        deepLXClient: DeepLXTranslationClient = DeepLXTranslationClient(),
        historyStore: ConversationHistoryStore? = nil,
        tokenUsageStore: TokenUsageStore? = nil,
        settingsRepository: InferenceSettingsRepository = InferenceSettingsRepository()
    ) {
        self.client = client
        self.usesCodexForConversation = usesCodexForConversation
        self.deepLXClient = deepLXClient
        self.historyStore = historyStore ?? ConversationHistoryStore()
        self.tokenUsageStore = tokenUsageStore ?? TokenUsageStore()
        self.settingsRepository = settingsRepository

        let settings = settingsRepository.loadConfiguration()
        provider = settings.provider
        gatewayBaseURL = settings.gatewayBaseURL
        gatewayAuthScheme = settings.gatewayAuthScheme
        gatewayAPIFormat = settings.gatewayAPIFormat
        model = settings.model
        maximumOutputTokens = settings.maximumOutputTokens
        translationUsesDedicatedConfiguration = settings.translationUsesDedicatedConfiguration
        translationProvider = settings.translationProvider
        translationGatewayBaseURL = settings.translationGatewayBaseURL
        translationGatewayAuthScheme = settings.translationGatewayAuthScheme
        translationGatewayAPIFormat = settings.translationGatewayAPIFormat
        translationDeepLXServerURL = settings.translationDeepLXServerURL
        translationModel = settings.translationModel
        translationMaximumOutputTokens = settings.translationMaximumOutputTokens
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
        overlay.onCapture = { [weak self] image, _, answerAnchorRect, question in
            Task { @MainActor in
                self?.overlayController = nil
                self?.showAnswerPanel(for: image, near: answerAnchorRect, question: question)
                self?.statusMessage = "Screenshot captured."
            }
        }
        overlay.onCaptureBatch = { [weak self] images, anchor, question in
            guard let self, !images.isEmpty else { return }
            self.overlayController = nil
            let session = ConversationSession()
            for image in images { session.appendScreenshot(image) }
            guard let turnID = session.beginTurn(question: question) else { return }
            session.revealAssistant(for: turnID)
            self.showAnswerPanel(for: session, near: anchor, persistImmediately: true)
            self.statusMessage = "Captured \(images.count) screenshots."
        }
        overlay.onTranslate = { [weak self] image, rect, frozenSnapshot in
            guard let self else {
                return
            }

            self.overlayController = nil
            self.translateScreenshot(image, near: rect, frozenSnapshot: frozenSnapshot)
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
        overlay.onCapture = { [weak self] image, _, _, _ in
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
        if usesCodexForConversation {
            return try await codexWorkspace.conversationResponse(request)
        }
        return try await submit(request: request, using: standardInferenceConfiguration)
    }

    private func submitTranslation(
        request: MarrCore.VisionRequest,
        requestTimeout: TimeInterval = 25
    ) async throws -> String {
        let configuration = translationUsesDedicatedConfiguration
            ? translationInferenceConfiguration
            : standardInferenceConfiguration
        do {
            return try await submit(
                request: request,
                using: configuration,
                requestTimeout: requestTimeout
            )
        } catch let error as URLError where error.code == .timedOut {
            throw UserFacingError(
                "Translation exceeded (Int(requestTimeout.rounded(.up))) seconds. Choose a faster gateway model or configure a dedicated translation API."
            )
        }
    }

    private func submit(
        request: MarrCore.VisionRequest,
        using configuration: InferenceRequestConfiguration,
        requestTimeout: TimeInterval = 120
    ) async throws -> String {
        let trimmedModel = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedGatewayBaseURL = configuration.gatewayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)

        guard configuration.provider != .gateway || !trimmedGatewayBaseURL.isEmpty else {
            throw UserFacingError("Gateway Base URL required.")
        }
        guard !request.messages.isEmpty else {
            throw UserFacingError("Conversation request is empty.")
        }
        guard !trimmedModel.isEmpty else {
            throw UserFacingError("Model name required.")
        }

        let credentials = try await requestCredentials(for: configuration)
        guard configuration.provider != .openAI || !credentials.apiKey.isEmpty else {
            throw UserFacingError("OpenAI API Key required.")
        }
        guard configuration.provider != .gateway
                || configuration.gatewayAuthScheme == .none
                || !credentials.apiKey.isEmpty
        else {
            throw UserFacingError("Gateway API Key required, or set auth to None.")
        }

        let requestConnection = connection(
            provider: configuration.provider,
            openAIKey: credentials.apiKey,
            gatewayBaseURL: trimmedGatewayBaseURL,
            gatewayKey: credentials.apiKey,
            gatewayAuthScheme: configuration.gatewayAuthScheme,
            gatewayAPIFormat: configuration.gatewayAPIFormat,
            customHeadersText: credentials.customHeadersText,
            maximumOutputTokens: configuration.maximumOutputTokens,
            requestTimeout: requestTimeout
        )
        let response = try await client.askWithUsage(
            request: request,
            model: trimmedModel,
            connection: requestConnection
        )
        if let usage = response.usage {
            tokenUsageStore.record(usage)
        }
        return response.text
    }

    func submitToCodex(_ prompt: String, images: [ConversationImageAsset]) {
        codexWorkspace.submit(prompt: prompt, images: images)
    }

    func credentialState(for credential: InferenceCredential) -> InferenceCredentialState {
        credentialStates[credential] ?? .unknown
    }

    func refreshCredentialState(for credential: InferenceCredential) async {
        guard !credentialState(for: credential).isBusy else { return }

        updateCredentialState(credential) {
            $0.activity = .checking
            $0.message = nil
            $0.messageIsError = false
        }

        let isStored = settingsRepository.credentialIsStored(credential)
        updateCredentialState(credential) {
            $0.isConfigured = isStored
            $0.activity = .idle
        }
    }

    @discardableResult
    func saveAndVerifyCredential(
        _ value: String,
        for credential: InferenceCredential
    ) async -> Bool {
        let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedValue.isEmpty else {
            updateCredentialState(credential) {
                $0.message = "Enter a value before saving."
                $0.messageIsError = true
            }
            return false
        }

        updateCredentialState(credential) {
            $0.activity = .saving
            $0.message = nil
            $0.messageIsError = false
        }

        let repository = settingsRepository
        do {
            try await BackgroundOperation.run(priority: .utility) {
                try repository.setCredential(normalizedValue, for: credential)
            }
            updateCredentialState(credential) {
                $0.isConfigured = true
                $0.activity = .verifying
            }
        } catch {
            updateCredentialState(credential) {
                $0.activity = .idle
                $0.message = "Could not save the credential: \(error.localizedDescription)"
                $0.messageIsError = true
            }
            return false
        }

        do {
            try await verifyCredential(credential, using: normalizedValue)
            updateCredentialState(credential) {
                $0.activity = .idle
                $0.message = "Saved and verified."
                $0.messageIsError = false
            }
        } catch {
            updateCredentialState(credential) {
                $0.activity = .idle
                $0.message = "Saved, but the connection check failed: \(userFacingMessage(for: error))"
                $0.messageIsError = true
            }
        }

        return true
    }

    @discardableResult
    func removeCredential(_ credential: InferenceCredential) async -> Bool {
        updateCredentialState(credential) {
            $0.activity = .removing
            $0.message = nil
            $0.messageIsError = false
        }

        let repository = settingsRepository
        do {
            try await BackgroundOperation.run(priority: .utility) {
                try repository.setCredential("", for: credential)
            }
            updateCredentialState(credential) {
                $0.isConfigured = false
                $0.activity = .idle
                $0.message = "Removed."
            }
            return true
        } catch {
            updateCredentialState(credential) {
                $0.activity = .idle
                $0.message = "Could not remove the credential: \(error.localizedDescription)"
                $0.messageIsError = true
            }
            return false
        }
    }

    private func translateScreenshot(
        _ image: PickedImage,
        near rect: CGRect,
        frozenSnapshot: ScreenCaptureSnapshot
    ) {
        translationTask?.cancel()
        translationOverlayController?.close()

        let overlay = TranslationOverlayController(
            anchorRect: rect,
            frozenSnapshot: frozenSnapshot
        )
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
        let translationStartedAt = Date()

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
                let blocks: [ImageTranslationBlock]
                let replacements: [ImageTranslationReplacement]
                let usesDeepLX = self.translationUsesDedicatedConfiguration
                    && self.translationProvider == .deepLX
                let aiTranslationUsesGateway = (
                    self.translationUsesDedicatedConfiguration
                        ? self.translationInferenceConfiguration
                        : self.standardInferenceConfiguration
                ).provider == .gateway

                if usesDeepLX {
                    guard recognition.succeeded else {
                        throw UserFacingError("DeepLX translation requires text recognized by macOS Vision.")
                    }
                    replacements = try await self.deepLXTranslationReplacements(for: regions)
                    blocks = ImageTranslationResponseParser.merge(
                        replacements: replacements,
                        regions: regions
                    )
                } else {
                    let request = regions.isEmpty
                        ? ImageTranslationPrompt.request(for: image)
                        : aiTranslationUsesGateway
                            ? ImageTranslationPrompt.request(regions: regions)
                            : ImageTranslationPrompt.request(for: image, regions: regions)
                    let remainingInitialBudget = 27
                        - Date().timeIntervalSince(translationStartedAt)
                    guard remainingInitialBudget >= 5 else {
                        throw UserFacingError(
                            "Translation preparation exceeded the 30-second experience budget. Try a smaller capture."
                        )
                    }
                    let response = try await self.submitTranslation(
                        request: request,
                        requestTimeout: min(25, remainingInitialBudget)
                    )
                    if regions.isEmpty {
                        blocks = ImageTranslationResponseParser.parse(response)
                        replacements = []
                    } else {
                        replacements = ImageTranslationResponseParser.parseReplacements(response)
                        blocks = ImageTranslationResponseParser.merge(
                            replacements: replacements,
                            regions: regions
                        )
                    }
                }

                try Task.checkCancellation()
                let highlightPairs = ImageTranslationHighlightBuilder.pairs(
                    regions: regions,
                    replacements: replacements
                )
                let renderedTranslation = try await BackgroundOperation.run(priority: .userInitiated) {
                    try Task.checkCancellation()
                    let result = ImageTranslationRenderer.renderDataWithHighlights(
                        sourceData: image.data,
                        blocks: blocks,
                        highlightPairs: highlightPairs
                    )
                    try Task.checkCancellation()
                    return result
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
                        let renderedTranslation,
                        let translatedImage = NSImage(data: renderedTranslation.data)
                    else {
                        overlay.showError("Could not render translation.")
                        self.statusMessage = "Could not render translation."
                        return
                    }

                    let exactHighlightPairs = highlightPairs.compactMap { pair in
                        guard pair.targetText != nil else { return pair }
                        guard let exactRects = renderedTranslation.translatedHighlightRects[pair.id],
                              !exactRects.isEmpty
                        else { return nil }
                        return ImageTranslationHighlightPair(
                            id: pair.id,
                            sourceID: pair.sourceID,
                            targetText: pair.targetText,
                            sourceRects: pair.sourceRects,
                            translatedRects: exactRects
                        )
                    }
                    overlay.showTranslatedImage(
                        translatedImage,
                        originalImage: originalImage,
                        highlightPairs: exactHighlightPairs
                    )
                    self.statusMessage = blocks.isEmpty ? "No translatable text found." : "Translation ready."
                }

                var refinedReplacements = replacements
                var refinedBlocks = blocks

                // Existing translations can be aligned while missing regions are translated.
                // Both operations retain their original validation and prompt requirements.
                async let initialAlignmentRepair = self.bestEffortTranslationAlignments(
                    replacements,
                    regions: usesDeepLX ? [] : regions
                )

                // A model that omits an OCR region should not make the user wait for a
                // second full gateway round trip. Show the first usable result, then fill
                // any gaps opportunistically in the background.
                if !usesDeepLX, !regions.isEmpty {
                    do {
                        let completedReplacements = try await self.completedTranslationReplacements(
                            replacements,
                            image: image,
                            includesImageContext: !aiTranslationUsesGateway,
                            regions: regions
                        )
                        if completedReplacements != refinedReplacements {
                            refinedReplacements = completedReplacements
                            refinedBlocks = ImageTranslationResponseParser.merge(
                                replacements: refinedReplacements,
                                regions: regions
                            )
                            try await self.refreshDisplayedTranslation(
                                image: image,
                                blocks: refinedBlocks,
                                regions: regions,
                                replacements: refinedReplacements,
                                overlay: overlay
                            )
                        }
                    } catch is CancellationError {
                        return
                    } catch {
                        // The first translation is already visible; completion is best-effort.
                    }
                }

                // Semantic alignment improves linked source/translation highlights, but it
                // does not change the translated text. Refine it after the useful result is
                // already visible so a slow gateway cannot hold the translation UI hostage.
                guard !usesDeepLX,
                      !regions.isEmpty,
                      !refinedBlocks.isEmpty
                else { return }
                let initiallyAligned = await initialAlignmentRepair
                try Task.checkCancellation()
                let unchanged = Self.reusingTranslationAlignments(
                    original: replacements,
                    aligned: initiallyAligned,
                    completed: refinedReplacements
                )
                let changedReplacements = refinedReplacements.filter { replacement in
                    !replacements.contains(replacement)
                }
                let alignedChanges = await self.bestEffortTranslationAlignments(
                    changedReplacements,
                    regions: regions
                )
                try Task.checkCancellation()
                let alignedReplacements = self.combinedTranslationReplacements(unchanged, alignedChanges)
                guard alignedReplacements != refinedReplacements else { return }

                let refinedPairs = ImageTranslationHighlightBuilder.pairs(
                    regions: regions,
                    replacements: alignedReplacements
                )
                let blocksForAlignment = refinedBlocks
                let refinedRendering = try await BackgroundOperation.run(priority: .utility) {
                    try Task.checkCancellation()
                    return ImageTranslationRenderer.renderDataWithHighlights(
                        sourceData: image.data,
                        blocks: blocksForAlignment,
                        highlightPairs: refinedPairs
                    )
                }
                try Task.checkCancellation()
                guard let refinedRendering else { return }
                let exactRefinedPairs = refinedPairs.compactMap { pair in
                    guard pair.targetText != nil else { return pair }
                    guard let exactRects = refinedRendering.translatedHighlightRects[pair.id],
                          !exactRects.isEmpty
                    else { return nil }
                    return ImageTranslationHighlightPair(
                        id: pair.id,
                        sourceID: pair.sourceID,
                        targetText: pair.targetText,
                        sourceRects: pair.sourceRects,
                        translatedRects: exactRects
                    )
                }
                await MainActor.run {
                    guard
                        let overlay,
                        self.translationOverlayController === overlay
                    else { return }
                    overlay.updateHighlightPairs(exactRefinedPairs)
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

    private func refreshDisplayedTranslation(
        image: PickedImage,
        blocks: [ImageTranslationBlock],
        regions: [ImageTranslationSourceRegion],
        replacements: [ImageTranslationReplacement],
        overlay: TranslationOverlayController?
    ) async throws {
        let highlightPairs = ImageTranslationHighlightBuilder.pairs(
            regions: regions,
            replacements: replacements
        )
        let rendered = try await BackgroundOperation.run(priority: .utility) {
            try Task.checkCancellation()
            return ImageTranslationRenderer.renderDataWithHighlights(
                sourceData: image.data,
                blocks: blocks,
                highlightPairs: highlightPairs
            )
        }
        try Task.checkCancellation()
        guard let rendered, let translatedImage = NSImage(data: rendered.data) else { return }
        let exactHighlightPairs = highlightPairs.compactMap { pair in
            guard pair.targetText != nil else { return pair }
            guard let exactRects = rendered.translatedHighlightRects[pair.id],
                  !exactRects.isEmpty
            else { return nil }
            return ImageTranslationHighlightPair(
                id: pair.id,
                sourceID: pair.sourceID,
                targetText: pair.targetText,
                sourceRects: pair.sourceRects,
                translatedRects: exactRects
            )
        }

        await MainActor.run {
            guard
                let overlay,
                self.translationOverlayController === overlay
            else { return }
            overlay.updateTranslatedImage(
                translatedImage,
                highlightPairs: exactHighlightPairs
            )
            self.statusMessage = blocks.isEmpty ? "No translatable text found." : "Translation ready."
        }
    }

    private func completedTranslationReplacements(
        _ replacements: [ImageTranslationReplacement],
        image: PickedImage,
        includesImageContext: Bool,
        regions: [ImageTranslationSourceRegion]
    ) async throws -> [ImageTranslationReplacement] {
        let missingRegions = missingTranslationRegions(in: regions, replacements: replacements)
        guard !missingRegions.isEmpty else {
            return replacements
        }

        let retryRequest = includesImageContext
            ? ImageTranslationPrompt.request(for: image, regions: missingRegions)
            : ImageTranslationPrompt.request(regions: missingRegions)
        let retryResponse = try await submitTranslation(request: retryRequest)
        return combinedTranslationReplacements(
            replacements,
            ImageTranslationResponseParser.parseReplacements(retryResponse)
        )
    }

    private func deepLXTranslationReplacements(
        for regions: [ImageTranslationSourceRegion]
    ) async throws -> [ImageTranslationReplacement] {
        let serverURL = translationDeepLXServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedServerURL = serverURL.isEmpty ? "http://127.0.0.1:1188" : serverURL
        let repository = settingsRepository
        let accessToken = try await BackgroundOperation.run(priority: .userInitiated) {
            try repository.credential(.translationDeepLXAccessToken) ?? ""
        }

        // Flatten requests first so all regions and selective spans share one limit.
        let spans = regions.map { region -> [(range: Range<Int>?, text: String)] in
            if region.translationStrategy == .block {
                return [(nil, region.sourceText)]
            }
            return Self.deepLXSelectiveRanges(for: region).map { range in
                (range, region.tokens[range].map(\.text).joined(separator: " "))
            }
        }
        let translations = try await deepLXClient.translateBatch(
            spans.flatMap { $0.map(\.text) },
            serverURL: resolvedServerURL,
            accessToken: accessToken
        )
        try Task.checkCancellation()
        var offset = 0
        return zip(regions, spans).map { region, regionSpans in
            defer { offset += regionSpans.count }
            if region.translationStrategy == .block {
                return ImageTranslationReplacement(id: region.id, text: translations[offset])
            }
            let segments = regionSpans.enumerated().compactMap { index, span -> ImageTranslationReplacementSegment? in
                guard let range = span.range else { return nil }
                return ImageTranslationReplacementSegment(
                    tokenStart: range.lowerBound,
                    tokenEnd: range.upperBound,
                    text: translations[offset + index]
                )
            }
            return ImageTranslationReplacement(id: region.id, text: "", segments: segments)
        }
    }

    static func deepLXSelectiveRanges(for region: ImageTranslationSourceRegion) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start: Int?
        for index in region.tokens.indices {
            if region.tokens[index].isProtected {
                if let start, start < index { ranges.append(start..<index) }
                start = nil
            } else if start == nil {
                start = index
            }
        }
        if let start, start < region.tokens.count { ranges.append(start..<region.tokens.count) }
        return ranges.filter { range in
            region.tokens[range].contains { token in
                token.text.unicodeScalars.contains { CharacterSet.letters.contains($0) }
            }
        }
    }

    static func reusingTranslationAlignments(
        original: [ImageTranslationReplacement],
        aligned: [ImageTranslationReplacement],
        completed: [ImageTranslationReplacement]
    ) -> [ImageTranslationReplacement] {
        completed.map { replacement in
            // A completion response may replace an existing region. Never attach an
            // alignment computed for a different translation to the new text.
            guard original.contains(replacement),
                  let repaired = aligned.first(where: { $0.id == replacement.id })
            else { return replacement }
            return repaired
        }
    }

    private func bestEffortTranslationAlignments(
        _ replacements: [ImageTranslationReplacement],
        regions: [ImageTranslationSourceRegion]
    ) async -> [ImageTranslationReplacement] {
        do {
            return try await repairedTranslationAlignments(replacements, regions: regions)
        } catch {
            // Keep the already usable translation if optional alignment fails.
            return replacements
        }
    }

    private func repairedTranslationAlignments(
        _ replacements: [ImageTranslationReplacement],
        regions: [ImageTranslationSourceRegion]
    ) async throws -> [ImageTranslationReplacement] {
        let alignmentRegions = ImageTranslationHighlightBuilder.regionsNeedingAlignmentRepair(
            regions: regions,
            replacements: replacements
        )
        guard !alignmentRegions.isEmpty else { return replacements }

        let response = try await submitTranslation(request: ImageTranslationPrompt.alignmentRepairRequest(
            regions: alignmentRegions,
            replacements: replacements
        ))
        let repaired = ImageTranslationResponseParser.parseReplacements(response)
        let repairedByID = Dictionary(
            repaired.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return replacements.map { original in
            guard let candidate = repairedByID[original.id],
                  candidate.text == original.text,
                  let region = alignmentRegions.first(where: { $0.id == original.id }),
                  ImageTranslationHighlightBuilder.hasReliableAlignments(
                    replacement: candidate,
                    region: region
                  )
            else { return original }
            return ImageTranslationReplacement(
                id: original.id,
                text: original.text,
                kind: original.kind,
                segments: original.segments,
                alignments: candidate.alignments
            )
        }
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
        let secondaryByID = Dictionary(
            secondary.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var seenIDs = Set(primary.map(\.id))
        var combined = primary.map { secondaryByID[$0.id] ?? $0 }

        for replacement in secondary where seenIDs.insert(replacement.id).inserted {
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

    func startNewConversation(work: Bool = false) {
        if work {
            guard !codexWorkspace.isRunning else { return }
            codexWorkspace.startNewTask()
        }
        showAnswerPanel(
            for: ConversationSession(),
            near: defaultAnswerPanelAnchorRect(),
            persistImmediately: false,
            initialDestination: work ? .work : nil
        )
    }

    func showAnswerPanelUtility(_ destination: AnswerPanelUtilityDestination) {
        if let answerPanelController {
            answerPanelController.show(destination)
            return
        }

        let session = ConversationSession()
        showAnswerPanel(
            for: session,
            near: defaultAnswerPanelAnchorRect(),
            persistImmediately: false,
            initialDestination: destination
        )
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
        persistImmediately: Bool,
        initialDestination: AnswerPanelUtilityDestination? = nil
    ) {
        let previousFrame = answerPanelController?.frame
        answerPanelController?.close()
        let panel = AnswerPanelController(
            controller: self,
            historyStore: historyStore,
            session: session,
            anchorRect: rect,
            persistImmediately: persistImmediately,
            initialDestination: initialDestination
        )
        answerPanelController = panel
        panel.show(preservingFrame: previousFrame)
    }

    private func defaultAnswerPanelAnchorRect() -> CGRect {
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            return screen.visibleFrame
        }
        return CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    private var standardInferenceConfiguration: InferenceRequestConfiguration {
        InferenceRequestConfiguration(
            provider: provider,
            gatewayBaseURL: gatewayBaseURL,
            gatewayAuthScheme: gatewayAuthScheme,
            gatewayAPIFormat: gatewayAPIFormat,
            model: model,
            maximumOutputTokens: maximumOutputTokens,
            openAIAPIKeyCredential: .openAIAPIKey,
            gatewayAPIKeyCredential: .gatewayAPIKey,
            customHeadersCredential: .customHeaders
        )
    }

    private var translationInferenceConfiguration: InferenceRequestConfiguration {
        InferenceRequestConfiguration(
            provider: translationProvider.inferenceProvider ?? .gateway,
            gatewayBaseURL: translationGatewayBaseURL,
            gatewayAuthScheme: translationGatewayAuthScheme,
            gatewayAPIFormat: translationGatewayAPIFormat,
            model: translationModel,
            maximumOutputTokens: translationMaximumOutputTokens,
            openAIAPIKeyCredential: .translationOpenAIAPIKey,
            gatewayAPIKeyCredential: .translationGatewayAPIKey,
            customHeadersCredential: .translationCustomHeaders
        )
    }

    private func requestCredentials(
        for configuration: InferenceRequestConfiguration
    ) async throws -> InferenceRequestCredentials {
        let repository = settingsRepository
        return try await BackgroundOperation.run(priority: .userInitiated) {
            switch configuration.provider {
            case .openAI:
                return InferenceRequestCredentials(
                    apiKey: try repository.credential(configuration.openAIAPIKeyCredential) ?? "",
                    customHeadersText: ""
                )
            case .gateway:
                let apiKey = configuration.gatewayAuthScheme == .none
                    ? ""
                    : try repository.credential(configuration.gatewayAPIKeyCredential) ?? ""
                return InferenceRequestCredentials(
                    apiKey: apiKey,
                    customHeadersText: try repository.credential(configuration.customHeadersCredential) ?? ""
                )
            }
        }
    }

    private func verifyCredential(
        _ credential: InferenceCredential,
        using value: String
    ) async throws {
        if credential == .translationDeepLXAccessToken,
           translationProvider == .deepLX {
            let configuredURL = translationDeepLXServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try await deepLXClient.translate(
                "Hello",
                serverURL: configuredURL.isEmpty ? "http://127.0.0.1:1188" : configuredURL,
                accessToken: value
            )
            return
        }
        let configuration = credential.isTranslationCredential
            ? translationInferenceConfiguration
            : standardInferenceConfiguration
        let selectedProvider: InferenceProvider = credential == configuration.openAIAPIKeyCredential ? .openAI : .gateway
        let trimmedGatewayBaseURL = configuration.gatewayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedModel.isEmpty else {
            throw UserFacingError("Model name required.")
        }
        guard selectedProvider != .gateway || !trimmedGatewayBaseURL.isEmpty else {
            throw UserFacingError("Gateway Base URL required.")
        }

        let repository = settingsRepository
        let credentials = try await BackgroundOperation.run(priority: .userInitiated) {
            if credential == configuration.openAIAPIKeyCredential {
                return InferenceRequestCredentials(apiKey: value, customHeadersText: "")
            }
            if credential == configuration.gatewayAPIKeyCredential {
                return InferenceRequestCredentials(
                    apiKey: value,
                    customHeadersText: try repository.credential(configuration.customHeadersCredential) ?? ""
                )
            }
            let apiKey = configuration.gatewayAuthScheme == .none
                    ? ""
                    : try repository.credential(configuration.gatewayAPIKeyCredential) ?? ""
            return InferenceRequestCredentials(apiKey: apiKey, customHeadersText: value)
        }

        guard selectedProvider != .gateway
                || configuration.gatewayAuthScheme == .none
                || !credentials.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw UserFacingError("Gateway API Key required, or set auth to None.")
        }

        let verificationConnection = connection(
            provider: selectedProvider,
            openAIKey: credentials.apiKey,
            gatewayBaseURL: trimmedGatewayBaseURL,
            gatewayKey: credentials.apiKey,
            gatewayAuthScheme: configuration.gatewayAuthScheme,
            gatewayAPIFormat: configuration.gatewayAPIFormat,
            customHeadersText: credentials.customHeadersText,
            maximumOutputTokens: 256
        )
        let verificationRequest = VisionRequest(
            systemPrompt: "This is a connection check.",
            messages: [
                VisionMessage(role: .user, content: [.text("Reply with OK.")])
            ]
        )

        _ = try await client.ask(
            request: verificationRequest,
            model: trimmedModel,
            connection: verificationConnection
        )
    }

    private func connection(
        provider: InferenceProvider,
        openAIKey: String,
        gatewayBaseURL: String,
        gatewayKey: String,
        gatewayAuthScheme: GatewayAuthScheme,
        gatewayAPIFormat: GatewayAPIFormat,
        customHeadersText: String,
        maximumOutputTokens: Int,
        requestTimeout: TimeInterval = 120
    ) -> InferenceConnection {
        switch provider {
        case .openAI:
            var connection = InferenceConnection.openAI(
                apiKey: openAIKey,
                maximumOutputTokens: maximumOutputTokens
            )
            connection.requestTimeout = requestTimeout
            return connection
        case .gateway:
            return InferenceConnection(
                provider: .gateway,
                baseURL: gatewayBaseURL,
                apiKey: gatewayKey,
                authScheme: gatewayAuthScheme,
                apiFormat: gatewayAPIFormat,
                customHeaders: parseCustomHeaders(customHeadersText),
                maximumOutputTokens: maximumOutputTokens,
                requestTimeout: requestTimeout
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
            openAIAPIKey: "",
            gatewayBaseURL: gatewayBaseURL,
            gatewayAPIKey: "",
            gatewayAuthScheme: gatewayAuthScheme,
            gatewayAPIFormat: gatewayAPIFormat,
            customHeadersText: "",
            model: model,
            maximumOutputTokens: maximumOutputTokens,
            translationUsesDedicatedConfiguration: translationUsesDedicatedConfiguration,
            translationProvider: translationProvider,
            translationGatewayBaseURL: translationGatewayBaseURL,
            translationGatewayAuthScheme: translationGatewayAuthScheme,
            translationGatewayAPIFormat: translationGatewayAPIFormat,
            translationDeepLXServerURL: translationDeepLXServerURL,
            translationModel: translationModel,
            translationMaximumOutputTokens: translationMaximumOutputTokens
        )
        let repository = settingsRepository

        settingsSaveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
                try Task.checkCancellation()
                try await BackgroundOperation.run(priority: .utility) {
                    repository.saveConfiguration(settings)
                }
            } catch is CancellationError {
                return
            } catch {
                self?.statusMessage = "Could not save AI settings: \(error.localizedDescription)"
            }
        }
    }

    private func updateCredentialState(
        _ credential: InferenceCredential,
        update: (inout InferenceCredentialState) -> Void
    ) {
        var state = credentialState(for: credential)
        update(&state)
        credentialStates[credential] = state
    }
}

private struct InferenceRequestCredentials: Sendable {
    let apiKey: String
    let customHeadersText: String
}

private struct InferenceRequestConfiguration: Sendable {
    let provider: InferenceProvider
    let gatewayBaseURL: String
    let gatewayAuthScheme: GatewayAuthScheme
    let gatewayAPIFormat: GatewayAPIFormat
    let model: String
    let maximumOutputTokens: Int
    let openAIAPIKeyCredential: InferenceCredential
    let gatewayAPIKeyCredential: InferenceCredential
    let customHeadersCredential: InferenceCredential
}

private extension InferenceCredential {
    var isTranslationCredential: Bool {
        switch self {
        case .translationOpenAIAPIKey, .translationGatewayAPIKey, .translationCustomHeaders,
             .translationDeepLXAccessToken:
            true
        case .openAIAPIKey, .gatewayAPIKey, .customHeaders:
            false
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
