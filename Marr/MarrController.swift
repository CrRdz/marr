import AppKit
import Carbon
import NaturalLanguage
import SwiftUI
import Vision

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
    private var translationOverlayController: TranslationOverlayController?
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
        overlay.onTranslate = { [weak self] image, rect in
            Task { @MainActor in
                guard let self else {
                    return
                }

                self.overlayController = nil
                self.translateScreenshot(image, near: rect)
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

    private func translateScreenshot(_ image: PickedImage, near rect: CGRect) {
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

            self.translationOverlayController = nil
        }
        overlay.show()
        statusMessage = "Translating screenshot..."

        Task { [weak self, weak overlay] in
            guard let self else {
                return
            }

            do {
                let recognition = await Task.detached(priority: .userInitiated) {
                    do {
                        return (
                            regions: try ImageTranslationTextRecognizer.regions(for: image),
                            succeeded: true
                        )
                    } catch {
                        return (regions: [], succeeded: false)
                    }
                }.value
                let regions = recognition.regions
                if recognition.succeeded, regions.isEmpty {
                    guard
                        let overlay,
                        self.translationOverlayController === overlay
                    else {
                        return
                    }
                    guard let originalImage = ImageTranslationRenderer.originalImage(source: image) else {
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

                await MainActor.run {
                    guard
                        let overlay,
                        self.translationOverlayController === overlay
                    else {
                        return
                    }

                    guard
                        let originalImage = ImageTranslationRenderer.originalImage(source: image),
                        let translatedImage = ImageTranslationRenderer.render(source: image, blocks: blocks)
                    else {
                        overlay.showError("Could not render translation.")
                        self.statusMessage = "Could not render translation."
                        return
                    }

                    overlay.showTranslatedImage(translatedImage, originalImage: originalImage)
                    self.statusMessage = blocks.isEmpty ? "No translatable text found." : "Translation ready."
                }
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
        answerPanelController?.close()
        answerPanelController = nil
        overlayController?.close()
        overlayController = nil
        windowCaptureOverlayController?.close()
        windowCaptureOverlayController = nil
        translationOverlayController?.close()
        translationOverlayController = nil
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

@MainActor
private final class TranslationOverlayController {
    var onClose: (() -> Void)?

    private let window: TranslationOverlayWindow
    private let anchorRect: CGRect
    private let model = ImageTranslationOverlayModel()
    private var toolWindow: TranslationToolWindow?
    private var originalWindow: TranslationOverlayWindow?
    private var originalImage: NSImage?
    private var translatedImage: NSImage?
    private var escapeMonitor: Any?
    private var isComparing = false
    private var didClose = false

    init(anchorRect: CGRect) {
        let rect = anchorRect.integral
        self.anchorRect = rect
        let createdWindow = TranslationOverlayWindow(
            contentRect: rect,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        createdWindow.title = "Marr Translation"
        createdWindow.isOpaque = false
        createdWindow.backgroundColor = .clear
        createdWindow.hasShadow = false
        createdWindow.animationBehavior = .none
        createdWindow.isReleasedWhenClosed = false
        createdWindow.level = .screenSaver
        createdWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        createdWindow.ignoresMouseEvents = true

        window = createdWindow
        createdWindow.contentView = NSHostingView(
            rootView: ImageTranslationOverlayView(model: model)
        )
    }

    func show() {
        installEscapeMonitor()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showTranslatedImage(_ image: NSImage, originalImage: NSImage) {
        closeOriginalWindow()
        self.originalImage = originalImage
        translatedImage = image
        isComparing = false
        window.ignoresMouseEvents = true
        window.setFrame(anchorRect, display: true)
        model.state = .result(image)
        showToolBubble()
    }

    func showError(_ message: String) {
        closeOriginalWindow()
        isComparing = false
        window.ignoresMouseEvents = true
        closeToolBubble()
        window.setFrame(anchorRect, display: true)
        model.state = .error(message)
    }

    func close() {
        guard !didClose else {
            return
        }

        didClose = true
        removeEscapeMonitor()
        closeToolBubble()
        closeOriginalWindow()
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        onClose?()
    }

    private func showToolBubble() {
        if toolWindow != nil {
            return
        }

        let createdWindow = TranslationToolWindow(
            contentRect: toolBubbleFrame(),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        createdWindow.title = "Marr Translation Tools"
        createdWindow.isOpaque = false
        createdWindow.backgroundColor = .clear
        createdWindow.hasShadow = false
        createdWindow.animationBehavior = .none
        createdWindow.isReleasedWhenClosed = false
        createdWindow.level = .screenSaver
        createdWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        createdWindow.ignoresMouseEvents = false
        createdWindow.contentView = NSHostingView(
            rootView: TranslationToolBubbleView { [weak self] in
                self?.toggleCompare()
            }
        )

        toolWindow = createdWindow
        createdWindow.makeKeyAndOrderFront(nil)
    }

    private func closeToolBubble() {
        toolWindow?.orderOut(nil)
        toolWindow?.contentView = nil
        toolWindow?.close()
        toolWindow = nil
    }

    private func toggleCompare() {
        guard let originalImage, let translatedImage else {
            return
        }

        if isComparing {
            showTranslationOnly(translatedImage)
        } else {
            showImageCompare(originalImage: originalImage, translatedImage: translatedImage)
        }
    }

    private func showTranslationOnly(_ translatedImage: NSImage) {
        closeOriginalWindow()
        isComparing = false
        window.ignoresMouseEvents = true
        window.setFrame(anchorRect, display: true)
        model.state = .result(translatedImage)
        updateToolBubblePosition()
    }

    private func showImageCompare(originalImage: NSImage, translatedImage: NSImage) {
        closeOriginalWindow()
        isComparing = true
        if let dockedFrame = TranslationCompareLayout.dockedOriginalFrame(
            anchorFrame: anchorRect,
            visibleFrame: screenVisibleFrame()
        ) {
            window.ignoresMouseEvents = true
            window.setFrame(anchorRect, display: true)
            model.state = .result(translatedImage)
            showOriginalWindow(image: originalImage, frame: dockedFrame)
        } else {
            let presentation = imageComparePresentation(
                originalImage: originalImage,
                translatedImage: translatedImage
            )
            window.ignoresMouseEvents = false
            window.setFrame(presentation.containerFrame, display: true)
            model.state = .compare(presentation)
        }
        updateToolBubblePosition()
    }

    private func showOriginalWindow(image: NSImage, frame: CGRect) {
        closeOriginalWindow()
        let createdWindow = TranslationOverlayWindow(
            contentRect: frame,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        createdWindow.title = "Marr Original Screenshot"
        createdWindow.isOpaque = false
        createdWindow.backgroundColor = .clear
        createdWindow.hasShadow = true
        createdWindow.animationBehavior = .none
        createdWindow.isReleasedWhenClosed = false
        createdWindow.level = .screenSaver
        createdWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        createdWindow.ignoresMouseEvents = true
        createdWindow.contentView = NSHostingView(
            rootView: TranslationDockedOriginalView(image: image)
        )

        originalWindow = createdWindow
        createdWindow.orderFront(nil)
    }

    private func closeOriginalWindow() {
        originalWindow?.orderOut(nil)
        originalWindow?.contentView = nil
        originalWindow?.close()
        originalWindow = nil
    }

    private func toolBubbleFrame() -> CGRect {
        let referenceFrame: CGRect
        if isComparing, let originalWindow {
            referenceFrame = window.frame.union(originalWindow.frame)
        } else {
            referenceFrame = isComparing ? window.frame : anchorRect
        }
        return toolBubbleFrame(near: referenceFrame)
    }

    private func updateToolBubblePosition() {
        toolWindow?.contentView = NSHostingView(
            rootView: TranslationToolBubbleView(isComparing: isComparing) { [weak self] in
                self?.toggleCompare()
            }
        )
        toolWindow?.setFrame(toolBubbleFrame(), display: true)
    }

    private func toolBubbleFrame(near frame: CGRect) -> CGRect {
        let size = CGSize(width: 108, height: 30)
        let visibleFrame = screenVisibleFrame()
        let x = min(max(frame.midX - size.width / 2, visibleFrame.minX + 8), visibleFrame.maxX - size.width - 8)
        let preferredY = frame.minY - size.height - 10
        let y = preferredY >= visibleFrame.minY + 8
            ? preferredY
            : min(frame.maxY + 10, visibleFrame.maxY - size.height - 8)

        return CGRect(origin: CGPoint(x: x, y: y), size: size).integral
    }

    private func imageComparePresentation(
        originalImage: NSImage,
        translatedImage: NSImage
    ) -> TranslationImageComparePresentation {
        let compareFrame = TranslationCompareLayout.imageFrame(
            anchorFrame: anchorRect,
            visibleFrame: screenVisibleFrame()
        )

        return TranslationImageComparePresentation(
            originalImage: originalImage,
            translatedImage: translatedImage,
            containerFrame: compareFrame
        )
    }

    private func screenVisibleFrame() -> CGRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(anchorRect) } ?? NSScreen.main
        return screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 900, height: 620)
    }

    private func installEscapeMonitor() {
        removeEscapeMonitor()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == kVK_Escape else {
                return event
            }

            self?.close()
            return nil
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
    }
}

private final class TranslationOverlayWindow: NSWindow {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }
}

private final class TranslationToolWindow: NSWindow {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }
}

@MainActor
private final class ImageTranslationOverlayModel: ObservableObject {
    @Published var state: ImageTranslationOverlayState = .loading
}

private enum ImageTranslationOverlayState {
    case loading
    case result(NSImage)
    case compare(TranslationImageComparePresentation)
    case error(String)
}

private struct TranslationImageComparePresentation {
    let originalImage: NSImage
    let translatedImage: NSImage
    let containerFrame: CGRect
}

enum TranslationCompareLayout {
    static let dividerWidth: CGFloat = 1

    static func paneWidth(containerWidth: CGFloat) -> CGFloat {
        max(1, containerWidth / 2)
    }

    static func dividerX(containerWidth: CGFloat) -> CGFloat {
        paneWidth(containerWidth: containerWidth)
    }

    static func dockedOriginalFrame(
        anchorFrame: CGRect,
        visibleFrame: CGRect,
        margin: CGFloat = 12,
        gap: CGFloat = 8
    ) -> CGRect? {
        let availableFrame = visibleFrame.insetBy(dx: margin, dy: margin)
        let sourceFrame = anchorFrame.integral
        guard
            sourceFrame.width > 0,
            sourceFrame.height > 0,
            sourceFrame.width <= availableFrame.width,
            sourceFrame.height <= availableFrame.height
        else {
            return nil
        }

        let y = min(
            max(sourceFrame.minY, availableFrame.minY),
            availableFrame.maxY - sourceFrame.height
        ).rounded()
        let leftX = sourceFrame.minX - gap - sourceFrame.width
        if leftX >= availableFrame.minX {
            return CGRect(
                x: leftX.rounded(),
                y: y,
                width: sourceFrame.width,
                height: sourceFrame.height
            )
        }

        let rightX = sourceFrame.maxX + gap
        if rightX + sourceFrame.width <= availableFrame.maxX {
            return CGRect(
                x: rightX.rounded(),
                y: y,
                width: sourceFrame.width,
                height: sourceFrame.height
            )
        }

        return nil
    }

    static func imageFrame(
        anchorFrame: CGRect,
        visibleFrame: CGRect,
        margin: CGFloat = 12,
        minimumSize: CGSize = CGSize(width: 760, height: 520)
    ) -> CGRect {
        let availableFrame = visibleFrame.insetBy(dx: margin, dy: margin)
        let sourceFrame = anchorFrame.integral
        let idealWidth = sourceFrame.width * 2 + 1
        let idealHeight = sourceFrame.height + 45
        let size = CGSize(
            width: min(availableFrame.width, max(idealWidth, minimumSize.width)),
            height: min(availableFrame.height, max(idealHeight, minimumSize.height))
        )
        let x = min(
            max(sourceFrame.midX - size.width / 2, availableFrame.minX),
            availableFrame.maxX - size.width
        )
        let y = min(
            max(sourceFrame.midY - size.height / 2, availableFrame.minY),
            availableFrame.maxY - size.height
        )

        return CGRect(
            origin: CGPoint(x: x.rounded(), y: y.rounded()),
            size: size
        )
    }
}

private struct ImageTranslationOverlayView: View {
    @ObservedObject var model: ImageTranslationOverlayModel

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                switch model.state {
                case .loading:
                    loadingView
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                case .result(let image):
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .overlay(selectionHintBorder)
                case .compare(let presentation):
                    TranslationImageCompareView(
                        originalImage: presentation.originalImage,
                        translatedImage: presentation.translatedImage
                    )
                    .frame(width: geometry.size.width, height: geometry.size.height)
                case .error(let message):
                    errorView(message)
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private var loadingView: some View {
        ProgressView()
            .controlSize(.small)
            .padding(14)
            .background(.black.opacity(0.56), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.white.opacity(0.20), lineWidth: 0.8)
            )
    }

    private func errorView(_ message: String) -> some View {
        Text(message)
            .font(MarrTypography.body(size: 12.5, weight: .medium))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: 280)
            .background(.red.opacity(0.72), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.white.opacity(0.22), lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(0.20), radius: 10, x: 0, y: 5)
    }

    private var selectionHintBorder: some View {
        Rectangle()
            .stroke(
                .white.opacity(0.42),
                style: StrokeStyle(lineWidth: 0.8, dash: [8, 7])
            )
            .overlay(
                Rectangle()
                    .stroke(.black.opacity(0.10), lineWidth: 0.6)
                    .padding(1)
            )
            .padding(-2)
            .allowsHitTesting(false)
    }

}

private struct TranslationDockedOriginalView: View {
    let image: NSImage

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(Rectangle().stroke(.primary.opacity(0.24), lineWidth: 1))
            .overlay(alignment: .topLeading) {
                Text("Original")
                    .font(MarrTypography.body(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.62), in: Capsule())
                    .padding(8)
            }
            .accessibilityLabel("Original screenshot")
    }
}

private struct TranslationImageCompareView: View {
    let originalImage: NSImage
    let translatedImage: NSImage

    private let headerHeight: CGFloat = 44

    var body: some View {
        GeometryReader { geometry in
            let paneWidth = TranslationCompareLayout.paneWidth(
                containerWidth: geometry.size.width
            )

            VStack(spacing: 0) {
                compareHeader(paneWidth: paneWidth)
                    .frame(height: headerHeight)
                Divider()

                ScrollView([.horizontal, .vertical]) {
                    HStack(alignment: .top, spacing: 0) {
                        compareImage(originalImage, width: paneWidth)
                        compareImage(translatedImage, width: paneWidth)
                    }
                    .frame(minWidth: geometry.size.width, alignment: .topLeading)
                }
                .scrollIndicators(.visible)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .topLeading) {
                Rectangle()
                    .fill(.primary.opacity(0.16))
                    .frame(
                        width: TranslationCompareLayout.dividerWidth,
                        height: geometry.size.height
                    )
                    .offset(
                        x: TranslationCompareLayout.dividerX(
                            containerWidth: geometry.size.width
                        ) - TranslationCompareLayout.dividerWidth / 2
                    )
                    .allowsHitTesting(false)
            }
            .overlay(Rectangle().stroke(.primary.opacity(0.18), lineWidth: 1))
        }
        .accessibilityLabel("Original and translated screenshot comparison")
    }

    private func compareHeader(paneWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            headerLabel("Original", width: paneWidth)
            headerLabel("简体中文", width: paneWidth)
        }
        .background(.primary.opacity(0.035))
    }

    private func headerLabel(_ title: String, width: CGFloat) -> some View {
        Text(title)
            .font(MarrTypography.body(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .frame(width: width, alignment: .leading)
    }

    private func compareImage(_ image: NSImage, width: CGFloat) -> some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: width, alignment: .top)
            .clipped()
    }
}

private struct TranslationToolBubbleView: View {
    var isComparing = false
    let onCompare: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onCompare) {
            HStack(spacing: 7) {
                Image(systemName: isComparing ? "checkmark" : "rectangle.split.2x1")
                    .font(.system(size: 13, weight: .semibold))
                Text(isComparing ? "Done" : "Compare")
                    .font(MarrTypography.body(size: 13, weight: .semibold))
            }
            .foregroundStyle(.primary.opacity(isHovering ? 0.95 : 0.78))
            .frame(width: 108, height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(isComparing ? "Return to translated image" : "Compare original and translation")
    }
}

enum ImageTranslationSourcePolicy {
    static func shouldTranslate(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, !containsTargetLanguageText(trimmed) else {
            return false
        }

        let latinLetterCount = trimmed.unicodeScalars.reduce(into: 0) { count, scalar in
            if scalar.isASCII,
               CharacterSet.letters.contains(scalar) {
                count += 1
            }
        }
        return latinLetterCount >= 2
    }

    static func isDecorativeFragment(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 1 else {
            return false
        }

        return trimmed.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || CharacterSet.punctuationCharacters.contains(scalar)
                || CharacterSet.symbols.contains(scalar)
        }
    }

    static func shouldIncludeRecognizedToken(
        _ text: String,
        index: Int,
        totalCount: Int
    ) -> Bool {
        !isProtectedRecognizedToken(text, index: index, totalCount: totalCount)
    }

    static func isProtectedRecognizedToken(
        _ text: String,
        index: Int,
        totalCount: Int
    ) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return true
        }

        let scalars = trimmed.unicodeScalars
        let containsDigit = scalars.contains { CharacterSet.decimalDigits.contains($0) }
        let containsLetter = scalars.contains { CharacterSet.letters.contains($0) }
        if containsDigit, !containsLetter {
            return true
        }
        if !containsDigit, !containsLetter {
            return true
        }

        if index == 0, trimmed.allSatisfy(isLeadingDecorativeCharacter) {
            return true
        }

        if index == 0, totalCount > 1, trimmed.count == 1 {
            return true
        }

        if isStructuralSeparator(trimmed) || isIntrinsicIdentifier(trimmed) {
            return true
        }

        return totalCount == 1 && isDecorativeFragment(trimmed)
    }

    static func isLeadingDecorativeCharacter(_ character: Character) -> Bool {
        "•·●○◦▪▫‣⁃→↗↘↙↖⇱⇲⤴①②③④⑤⑥⑦⑧⑨⑩".contains(character)
    }

    static func protectedTokenIndexes(
        _ tokens: [String],
        preservedPhrases: [[String]] = [],
        namedEntityIndexes: Set<Int> = []
    ) -> Set<Int> {
        var protected = namedEntityIndexes
        for (index, token) in tokens.enumerated() where isProtectedRecognizedToken(
            token,
            index: index,
            totalCount: tokens.count
        ) {
            protected.insert(index)
        }

        let normalizedTokens = tokens.map(normalizedComparableToken)
        for phrase in preservedPhrases {
            let normalizedPhrase = phrase.map(normalizedComparableToken).filter { !$0.isEmpty }
            guard !normalizedPhrase.isEmpty, normalizedPhrase.count <= normalizedTokens.count else {
                continue
            }
            for start in 0...(normalizedTokens.count - normalizedPhrase.count) where
                Array(normalizedTokens[start..<(start + normalizedPhrase.count)]) == normalizedPhrase {
                protected.formUnion(start..<(start + normalizedPhrase.count))
            }
        }
        return protected
    }

    static func identityPhraseBeforeSeparator(_ tokens: [String]) -> [String]? {
        guard
            let separatorIndex = tokens.firstIndex(where: isStructuralSeparator),
            separatorIndex > 0,
            separatorIndex <= 5
        else {
            return nil
        }
        var prefix = Array(tokens.prefix(separatorIndex))
        while prefix.count > 1,
              let first = prefix.first,
              first.trimmingCharacters(in: .whitespacesAndNewlines).count == 1 {
            prefix.removeFirst()
        }
        guard prefix.allSatisfy(isLikelyIdentityComponent) else {
            return nil
        }
        return prefix
    }

    static func translationStrategy(
        tokenTexts: [String],
        protectedIndexes: Set<Int>,
        lineCount: Int
    ) -> ImageTranslationStrategy {
        guard lineCount == 1, tokenTexts.count <= 8 else {
            return .block
        }

        let translatableIndexes = tokenTexts.indices.filter { index in
            !protectedIndexes.contains(index)
                && tokenTexts[index].unicodeScalars.contains {
                    CharacterSet.letters.contains($0)
                }
        }
        guard let firstTranslatableIndex = translatableIndexes.first else {
            return .block
        }

        let hasProtectedPrefix = firstTranslatableIndex > 0
            && (0..<firstTranslatableIndex).allSatisfy { protectedIndexes.contains($0) }
        let hasStructuralSeparator = tokenTexts.contains(where: isStructuralSeparator)
        let hasSentenceTerminator = tokenTexts.last.map { token in
            token.trimmingCharacters(in: .whitespacesAndNewlines)
                .allSatisfy { ".!?。！？".contains($0) }
        } ?? false

        guard
            !hasSentenceTerminator,
            hasStructuralSeparator || hasProtectedPrefix
        else {
            return .block
        }
        return .selective
    }

    static func isStructuralSeparator(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.allSatisfy { "|｜¦".contains($0) }
    }

    private static func isIntrinsicIdentifier(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
        guard trimmed.count >= 2 else {
            return false
        }
        if ImageTranslationCodeHeuristics.isStrongIdentifier(trimmed) {
            return true
        }

        let letters = trimmed.filter(\.isLetter)
        guard letters.count >= 2 else {
            return false
        }
        if letters.allSatisfy({ $0.isUppercase }) {
            return true
        }
        let trailingLetters = letters.dropFirst()
        return trailingLetters.contains(where: { $0.isUppercase })
            && letters.contains(where: { $0.isLowercase })
    }

    private static func isLikelyIdentityComponent(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
        return trimmed.range(
            of: #"^[A-Z][A-Za-z0-9'’._-]*$"#,
            options: .regularExpression
        ) != nil
    }

    private static func normalizedComparableToken(_ token: String) -> String {
        token
            .trimmingCharacters(in: .punctuationCharacters.union(.symbols))
            .lowercased()
    }

    private static func containsTargetLanguageText(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let value = Int(scalar.value)
            return (0x3400...0x4DBF).contains(value)
                || (0x4E00...0x9FFF).contains(value)
                || (0xF900...0xFAFF).contains(value)
        }
    }
}

private enum ImageTranslationTextRecognizer {
    static func regions(for pickedImage: PickedImage) throws -> [ImageTranslationSourceRegion] {
        var sourceRect = CGRect(origin: .zero, size: pickedImage.image.size)
        guard let cgImage = pickedImage.image.cgImage(forProposedRect: &sourceRect, context: nil, hints: nil) else {
            return []
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US", "zh-Hans"]
        request.minimumTextHeight = 0.006

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let observations = request.results ?? []
        let preservedPhrases = dynamicallyPreservedPhrases(from: observations)
        let fragments = observations.compactMap { observation in
            fragment(
                from: observation,
                bitmap: bitmap,
                preservedPhrases: preservedPhrases
            )
        }
        let protectedRects = fragments
            .flatMap(\.protectedBoxes)
            .map { expandedProtectedTokenRect(topLeftRect(fromVisionBox: $0)) }
        let lines = mergedVisualLines(from: fragments)
        let textBlocks = mergedTextBlocks(from: lines)
        let regions = expandedSourceRegions(
            from: textBlocks,
            globalProtectedRects: protectedRects
        )

        return regions.enumerated().map { index, region in
            ImageTranslationSourceRegion(
                id: String(format: "r%03d", index + 1),
                sourceText: region.text,
                x: region.rect.minX,
                y: region.rect.minY,
                width: region.rect.width,
                height: region.rect.height,
                lineRects: region.lineRects.map { lineRect in
                    ImageTranslationLineRect(
                        x: lineRect.minX,
                        y: lineRect.minY,
                        width: lineRect.width,
                        height: lineRect.height
                    )
                },
                textRects: region.textRects.map { textRect in
                    ImageTranslationLineRect(
                        x: textRect.minX,
                        y: textRect.minY,
                        width: textRect.width,
                        height: textRect.height
                    )
                },
                protectedRects: (
                    region.translationStrategy == .selective
                        ? region.protectedRects
                        : []
                ).map { protectedRect in
                    ImageTranslationLineRect(
                        x: protectedRect.minX,
                        y: protectedRect.minY,
                        width: protectedRect.width,
                        height: protectedRect.height
                    )
                },
                tokens: region.tokens.map { token in
                    ImageTranslationSourceToken(
                        text: token.text,
                        x: token.rect.minX,
                        y: token.rect.minY,
                        width: token.rect.width,
                        height: token.rect.height,
                        isProtected: token.isProtected
                    )
                },
                translationStrategy: region.translationStrategy,
                codeRects: region.codeRects.map { tokenRect in
                    ImageTranslationTokenRect(
                        text: tokenRect.text,
                        x: tokenRect.rect.minX,
                        y: tokenRect.rect.minY,
                        width: tokenRect.rect.width,
                        height: tokenRect.rect.height
                    )
                },
                kind: region.kind.rawValue,
                alignment: "left",
                weight: region.kind.prefersBoldText ? "semibold" : nil,
                fontSize: region.fontSize
            )
        }
    }

    private struct Fragment {
        let text: String
        let boundingBox: CGRect
        let textBoxes: [CGRect]
        let protectedBoxes: [CGRect]
        let tokens: [FragmentToken]
        let codeTokens: [CodeTokenFragment]
    }

    private struct FragmentToken {
        let text: String
        let boundingBox: CGRect
        let isProtected: Bool
    }

    private struct CodeTokenFragment {
        let text: String
        let boundingBox: CGRect
    }

    private struct RecognizedToken {
        let text: String
        let boundingBox: CGRect
        let range: Range<String.Index>?
    }

    private struct VisualLine {
        var fragments: [Fragment]

        var boundingBox: CGRect {
            fragments
                .map(\.boundingBox)
                .reduce(fragments[0].boundingBox) { $0.union($1) }
        }

        var text: String {
            fragments
                .sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                .map(\.text)
                .joined(separator: " ")
                .replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        mutating func append(_ fragment: Fragment) {
            fragments.append(fragment)
        }
    }

    private struct TextBlock {
        var lines: [VisualLine]

        var boundingBox: CGRect {
            lines
                .map(\.boundingBox)
                .reduce(lines[0].boundingBox) { $0.union($1) }
        }

        var text: String {
            lines
                .sorted { lhs, rhs in
                    if abs(lhs.boundingBox.midY - rhs.boundingBox.midY) > 0.01 {
                        return lhs.boundingBox.midY > rhs.boundingBox.midY
                    }
                    return lhs.boundingBox.minX < rhs.boundingBox.minX
                }
                .map(\.text)
                .joined(separator: " ")
                .replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        mutating func append(_ line: VisualLine) {
            lines.append(line)
        }
    }

    private struct SourceRegionCandidate {
        let text: String
        let rect: CGRect
        let lineRects: [CGRect]
        let textRects: [CGRect]
        let protectedRects: [CGRect]
        let tokens: [SourceOCRTokenCandidate]
        let translationStrategy: ImageTranslationStrategy
        let codeRects: [SourceTokenCandidate]
        let kind: TextBlockKind
        let fontSize: Double
    }

    private struct SourceTokenCandidate {
        let text: String
        let rect: CGRect
    }

    private struct SourceOCRTokenCandidate {
        let text: String
        let rect: CGRect
        let isProtected: Bool
    }

    private enum TextBlockKind: String {
        case title
        case heading
        case paragraph
        case listItem = "list_item"
        case caption
        case code

        var prefersBoldText: Bool {
            switch self {
            case .title, .heading:
                return true
            case .paragraph, .listItem, .caption, .code:
                return false
            }
        }
    }

    private static func fragment(
        from observation: VNRecognizedTextObservation,
        bitmap: NSBitmapImageRep,
        preservedPhrases: [[String]]
    ) -> Fragment? {
        guard let recognizedText = observation.topCandidates(1).first else {
            return nil
        }

        let tokenization = recognizedTokens(in: recognizedText)
        let fallbackTokens = tokenization.tokens.isEmpty
            ? [RecognizedToken(
                text: recognizedText.string,
                boundingBox: observation.boundingBox,
                range: nil
            )]
            : tokenization.tokens
        let codeTokens = codeTokenFragments(
            in: recognizedText,
            lineBox: observation.boundingBox,
            bitmap: bitmap
        )
        let namedEntityIndexes = namedEntityTokenIndexes(
            in: recognizedText.string,
            tokens: fallbackTokens
        )
        var protectedIndexes = ImageTranslationSourcePolicy.protectedTokenIndexes(
            fallbackTokens.map(\.text),
            preservedPhrases: preservedPhrases,
            namedEntityIndexes: namedEntityIndexes
        )
        for (index, token) in fallbackTokens.enumerated() where codeTokens.contains(where: {
            $0.boundingBox.intersects(token.boundingBox)
        }) {
            protectedIndexes.insert(index)
        }

        let text = normalizedSourceText(fallbackTokens.map(\.text).joined(separator: " "))
        guard
            !text.isEmpty,
            !ImageTranslationSourcePolicy.isDecorativeFragment(text)
        else {
            return nil
        }
        if !ImageTranslationSourcePolicy.shouldTranslate(text) {
            protectedIndexes.formUnion(fallbackTokens.indices)
        }

        let boundingBox = fallbackTokens
            .dropFirst()
            .reduce(fallbackTokens[0].boundingBox) { partial, token in
                partial.union(token.boundingBox)
            }
        let fragmentTokens = fallbackTokens.enumerated().map { index, token in
            FragmentToken(
                text: token.text,
                boundingBox: token.boundingBox,
                isProtected: protectedIndexes.contains(index)
            )
        }

        return Fragment(
            text: text,
            boundingBox: boundingBox,
            textBoxes: fallbackTokens.map(\.boundingBox),
            protectedBoxes: tokenization.protectedBoxes
                + fragmentTokens.filter { $0.isProtected }.map(\.boundingBox),
            tokens: fragmentTokens,
            codeTokens: codeTokens
        )
    }

    private static func recognizedTokens(
        in recognizedText: VNRecognizedText
    ) -> (tokens: [RecognizedToken], protectedBoxes: [CGRect]) {
        var tokens: [RecognizedToken] = []
        var protectedBoxes: [CGRect] = []

        for rawRange in recognizedText.string.translationTokenRanges() {
            var range = rawRange
            while range.lowerBound < range.upperBound,
                  ImageTranslationSourcePolicy.isLeadingDecorativeCharacter(
                    recognizedText.string[range.lowerBound]
                  ) {
                range = recognizedText.string.index(after: range.lowerBound)..<range.upperBound
            }

            if rawRange.lowerBound < range.lowerBound {
                let protectedRange = rawRange.lowerBound..<range.lowerBound
                if let observation = try? recognizedText.boundingBox(for: protectedRange) {
                    let box = observation.boundingBox
                    if box.width > 0, box.height > 0 {
                        protectedBoxes.append(box)
                    }
                }
            }
            guard range.lowerBound < range.upperBound,
                  let observation = try? recognizedText.boundingBox(for: range)
            else {
                continue
            }

            let box = observation.boundingBox
            guard box.width > 0, box.height > 0 else {
                continue
            }
            tokens.append(RecognizedToken(
                text: String(recognizedText.string[range]),
                boundingBox: box,
                range: range
            ))
        }

        return (tokens, protectedBoxes)
    }

    private static func dynamicallyPreservedPhrases(
        from observations: [VNRecognizedTextObservation]
    ) -> [[String]] {
        var phrases: [[String]] = []

        for observation in observations {
            guard let recognizedText = observation.topCandidates(1).first else {
                continue
            }
            let tokenization = recognizedTokens(in: recognizedText)
            let tokens = tokenization.tokens
            guard !tokens.isEmpty else {
                continue
            }

            if let prefix = ImageTranslationSourcePolicy.identityPhraseBeforeSeparator(
                tokens.map(\.text)
            ) {
                phrases.append(prefix)
            }

            let entityIndexes = namedEntityTokenIndexes(
                in: recognizedText.string,
                tokens: tokens
            )
            var currentPhrase: [String] = []
            for (index, token) in tokens.enumerated() {
                if entityIndexes.contains(index) {
                    currentPhrase.append(token.text)
                } else if !currentPhrase.isEmpty {
                    phrases.append(currentPhrase)
                    currentPhrase = []
                }
            }
            if !currentPhrase.isEmpty {
                phrases.append(currentPhrase)
            }
        }

        var seen: Set<String> = []
        return phrases.filter { phrase in
            let key = phrase
                .map {
                    $0.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
                        .lowercased()
                }
                .filter { !$0.isEmpty }
                .joined(separator: "\u{1F}")
            guard !key.isEmpty, seen.insert(key).inserted else {
                return false
            }
            return true
        }
    }

    private static func namedEntityTokenIndexes(
        in text: String,
        tokens: [RecognizedToken]
    ) -> Set<Int> {
        guard !text.isEmpty else {
            return []
        }

        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let fullRange = text.startIndex..<text.endIndex
        tagger.setLanguage(.english, range: fullRange)
        var entityRanges: [Range<String.Index>] = []
        tagger.enumerateTags(
            in: fullRange,
            unit: .word,
            scheme: .nameType,
            options: [.omitWhitespace, .omitPunctuation, .joinNames]
        ) { tag, range in
            if let tag,
               tag == .personalName || tag == .organizationName || tag == .placeName {
                entityRanges.append(range)
            }
            return true
        }

        return Set(tokens.enumerated().compactMap { index, token in
            guard let tokenRange = token.range,
                  entityRanges.contains(where: { $0.overlaps(tokenRange) })
            else {
                return nil
            }
            return index
        })
    }

    private static func mergedVisualLines(from fragments: [Fragment]) -> [VisualLine] {
        let sorted = fragments.sorted { lhs, rhs in
            if abs(lhs.boundingBox.midY - rhs.boundingBox.midY) > 0.01 {
                return lhs.boundingBox.midY > rhs.boundingBox.midY
            }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }

        var lines: [VisualLine] = []
        for fragment in sorted {
            if let index = lines.firstIndex(where: { belongsToSameVisualLine(fragment, line: $0) }) {
                lines[index].append(fragment)
            } else {
                lines.append(VisualLine(fragments: [fragment]))
            }
        }

        return lines.map { line in
            VisualLine(fragments: line.fragments.sorted { $0.boundingBox.minX < $1.boundingBox.minX })
        }
    }

    private static func mergedTextBlocks(from lines: [VisualLine]) -> [TextBlock] {
        let sorted = lines.sorted { lhs, rhs in
            if abs(lhs.boundingBox.midY - rhs.boundingBox.midY) > 0.01 {
                return lhs.boundingBox.midY > rhs.boundingBox.midY
            }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }

        var blocks: [TextBlock] = []
        for line in sorted where shouldUseSourceText(line.text) {
            if let lastIndex = blocks.indices.last,
               belongsToSameTextBlock(line, block: blocks[lastIndex]) {
                blocks[lastIndex].append(line)
            } else {
                blocks.append(TextBlock(lines: [line]))
            }
        }

        return blocks
    }

    private static func belongsToSameTextBlock(_ line: VisualLine, block: TextBlock) -> Bool {
        guard let previousLine = block.lines.last else {
            return false
        }

        let previousBox = previousLine.boundingBox
        let currentBox = line.boundingBox
        let maxLineHeight = max(previousBox.height, currentBox.height)
        let verticalGap = previousBox.minY - currentBox.maxY
        guard verticalGap > -maxLineHeight * 0.45, verticalGap < maxLineHeight * 1.85 else {
            return false
        }

        let currentIsBullet = isBulletLine(line.text)
        let blockIsBullet = isBulletLine(block.lines.first?.text ?? "")
        if currentIsBullet {
            return false
        }

        if blockIsBullet {
            let firstLineBox = block.lines.first?.boundingBox ?? block.boundingBox
            let continuationIndent = firstLineBox.minX + max(0.012, maxLineHeight * 0.28)
            let isIndentedContinuation = currentBox.minX >= continuationIndent
            let isWrappedContinuation = isIndentedContinuation || lineSuggestsContinuation(previousLine.text)
            return isWrappedContinuation
                && (isIndentedContinuation || !endsTextBlock(previousLine.text))
                && currentBox.minX <= block.boundingBox.maxX + 0.025
                && verticalGap < maxLineHeight * 1.35
        }

        if looksLikeStandaloneHeading(line.text) || endsTextBlock(previousLine.text) {
            return false
        }

        let indentationDelta = abs(currentBox.minX - previousBox.minX)
        return indentationDelta < 0.035
            && verticalGap < maxLineHeight * 1.25
            && (lineSuggestsContinuation(previousLine.text) || !startsLikeNewSentence(line.text))
    }

    private static func expandedSourceRegions(
        from blocks: [TextBlock],
        globalProtectedRects: [CGRect]
    ) -> [SourceRegionCandidate] {
        let allLineHeights = blocks
            .flatMap(\.lines)
            .map { topLeftRect(fromVisionBox: $0.boundingBox).height }
            .filter { $0 > 0 }
        let medianLineHeight = median(allLineHeights) ?? 0.018
        let baseRects = blocks.enumerated().map { index, block in
            expandedTextBlockRect(
                topLeftRect(fromVisionBox: block.boundingBox),
                kind: blockKind(for: block, index: index, medianLineHeight: medianLineHeight)
            )
        }

        return blocks.enumerated().compactMap { index, block -> SourceRegionCandidate? in
            let text = block.text
            guard shouldUseSourceText(text) else {
                return nil
            }

            let kind = blockKind(for: block, index: index, medianLineHeight: medianLineHeight)
            let rect = baseRects[index]
            guard rect.width > 0.01, rect.height > 0.008 else {
                return nil
            }

            let sourceLineHeight = median(
                block.lines.map { topLeftRect(fromVisionBox: $0.boundingBox).height }.filter { $0 > 0 }
            ) ?? medianLineHeight
            let lineRects = block.lines.map { line in
                expandedTextLineRect(
                    topLeftRect(fromVisionBox: line.boundingBox),
                    kind: kind
                )
            }
            let localProtectedRects = block.lines.flatMap { line in
                line.fragments.flatMap(\.protectedBoxes).map { protectedBox in
                    expandedProtectedTokenRect(topLeftRect(fromVisionBox: protectedBox))
                }
            }
            let nearbyProtectedRects = globalProtectedRects.filter { protectedRect in
                isProtectedRect(protectedRect, adjacentTo: lineRects)
            }
            let orderedTokens = orderedFragmentTokens(in: block)
            let protectedTokenIndexes = Set(
                orderedTokens.enumerated().compactMap { index, token in
                    token.isProtected ? index : nil
                }
            )
            let translationStrategy = ImageTranslationSourcePolicy.translationStrategy(
                tokenTexts: orderedTokens.map(\.text),
                protectedIndexes: protectedTokenIndexes,
                lineCount: block.lines.count
            )
            return SourceRegionCandidate(
                text: text,
                rect: rect,
                lineRects: lineRects,
                textRects: block.lines.flatMap { line in
                    line.fragments.flatMap { fragment in
                        let textBoxes = fragment.textBoxes.isEmpty
                            ? [fragment.boundingBox]
                            : fragment.textBoxes
                        return textBoxes.map { textBox in
                            expandedTextFragmentRect(topLeftRect(fromVisionBox: textBox))
                        }
                    }
                },
                protectedRects: deduplicatedRects(localProtectedRects + nearbyProtectedRects),
                tokens: orderedTokens.map { token in
                    SourceOCRTokenCandidate(
                        text: token.text,
                        rect: expandedTextFragmentRect(topLeftRect(fromVisionBox: token.boundingBox)),
                        isProtected: token.isProtected
                    )
                },
                translationStrategy: translationStrategy,
                codeRects: block.lines.flatMap { line in
                    line.fragments.flatMap { fragment in
                        fragment.codeTokens.map { token in
                            SourceTokenCandidate(
                                text: token.text,
                                rect: expandedCodeTokenRect(topLeftRect(fromVisionBox: token.boundingBox))
                            )
                        }
                    }
                },
                kind: kind,
                fontSize: fontSize(for: kind, sourceLineHeight: sourceLineHeight)
            )
        }
    }

    private static func orderedFragmentTokens(in block: TextBlock) -> [FragmentToken] {
        block.lines
            .sorted { lhs, rhs in
                if abs(lhs.boundingBox.midY - rhs.boundingBox.midY) > 0.01 {
                    return lhs.boundingBox.midY > rhs.boundingBox.midY
                }
                return lhs.boundingBox.minX < rhs.boundingBox.minX
            }
            .flatMap { line in
                line.fragments
                    .sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                    .flatMap { fragment in
                        fragment.tokens.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                    }
            }
    }

    private static func isProtectedRect(_ protectedRect: CGRect, adjacentTo lineRects: [CGRect]) -> Bool {
        lineRects.contains { lineRect in
            let verticalOverlap = min(protectedRect.maxY, lineRect.maxY) - max(protectedRect.minY, lineRect.minY)
            let overlapRatio = max(0, verticalOverlap) / max(min(protectedRect.height, lineRect.height), 0.001)
            let horizontalGap = max(
                0,
                max(protectedRect.minX - lineRect.maxX, lineRect.minX - protectedRect.maxX)
            )
            return overlapRatio > 0.32
                && horizontalGap <= max(protectedRect.height, lineRect.height) * 1.8
        }
    }

    private static func deduplicatedRects(_ rects: [CGRect]) -> [CGRect] {
        var result: [CGRect] = []
        for rect in rects where !result.contains(where: {
            abs($0.minX - rect.minX) < 0.001
                && abs($0.minY - rect.minY) < 0.001
                && abs($0.width - rect.width) < 0.001
                && abs($0.height - rect.height) < 0.001
        }) {
            result.append(rect)
        }
        return result
    }

    private static func codeTokenFragments(
        in recognizedText: VNRecognizedText,
        lineBox: CGRect,
        bitmap: NSBitmapImageRep
    ) -> [CodeTokenFragment] {
        recognizedText.string.sourceTokenRanges().compactMap { range in
            let token = String(recognizedText.string[range])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: codeTrimCharacters)
            guard shouldPreserveCodeToken(token),
                  let observation = try? recognizedText.boundingBox(for: range)
            else {
                return nil
            }

            let box = observation.boundingBox
            guard box.width > 0, box.height > 0 else {
                return nil
            }
            let hasVisualCodeBackground = hasCodeLikeBackground(
                tokenBox: box,
                lineBox: lineBox,
                bitmap: bitmap
            )
            guard hasVisualCodeBackground || ImageTranslationCodeHeuristics.isStrongIdentifier(token)
            else {
                return nil
            }

            return CodeTokenFragment(text: token, boundingBox: box)
        }
    }

    private static func hasCodeLikeBackground(
        tokenBox: CGRect,
        lineBox: CGRect,
        bitmap: NSBitmapImageRep
    ) -> Bool {
        let horizontalPadding = max(0.002, tokenBox.height * 0.24)
        let verticalPadding = max(0.0012, tokenBox.height * 0.14)
        let chipBox = clampedUnitRect(
            tokenBox.insetBy(dx: -horizontalPadding, dy: -verticalPadding)
        )
        let backgroundGap = max(0.002, tokenBox.height * 0.30)
        let midY = tokenBox.midY
        let midX = tokenBox.midX

        let chipPoints = [
            CGPoint(x: max(chipBox.minX, tokenBox.minX - horizontalPadding * 0.55), y: midY),
            CGPoint(x: min(chipBox.maxX, tokenBox.maxX + horizontalPadding * 0.55), y: midY),
            CGPoint(x: midX, y: max(chipBox.minY, tokenBox.minY - verticalPadding * 0.55)),
            CGPoint(x: midX, y: min(chipBox.maxY, tokenBox.maxY + verticalPadding * 0.55))
        ]
        let backgroundPoints = [
            CGPoint(x: chipBox.minX - backgroundGap, y: midY),
            CGPoint(x: chipBox.maxX + backgroundGap, y: midY),
            CGPoint(x: midX, y: min(lineBox.maxY + backgroundGap, 1)),
            CGPoint(x: midX, y: max(lineBox.minY - backgroundGap, 0))
        ]

        guard
            let chipColor = averageColor(
                chipPoints.compactMap { sampledVisionColor(at: $0, bitmap: bitmap) }
            ),
            let backgroundColor = averageColor(
                backgroundPoints.compactMap { point in
                    guard point.x >= 0, point.x <= 1, point.y >= 0, point.y <= 1 else {
                        return nil
                    }
                    return sampledVisionColor(at: point, bitmap: bitmap)
                }
            )
        else {
            return false
        }

        return colorDistance(chipColor, backgroundColor) >= 0.045
            || abs(luminance(chipColor) - luminance(backgroundColor)) >= 0.030
    }

    private static func clampedUnitRect(_ rect: CGRect) -> CGRect {
        let minX = min(max(rect.minX, 0), 1)
        let minY = min(max(rect.minY, 0), 1)
        let maxX = min(max(rect.maxX, 0), 1)
        let maxY = min(max(rect.maxY, 0), 1)

        return CGRect(
            x: minX,
            y: minY,
            width: max(0, maxX - minX),
            height: max(0, maxY - minY)
        )
    }

    private static func sampledVisionColor(at point: CGPoint, bitmap: NSBitmapImageRep) -> NSColor? {
        let clampedX = min(max(point.x, 0), 1)
        let clampedY = min(max(point.y, 0), 1)
        let x = min(
            max(0, Int((clampedX * CGFloat(bitmap.pixelsWide - 1)).rounded())),
            bitmap.pixelsWide - 1
        )
        let y = min(
            max(0, Int(((1 - clampedY) * CGFloat(bitmap.pixelsHigh - 1)).rounded())),
            bitmap.pixelsHigh - 1
        )

        return bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
    }

    private static func averageColor(_ colors: [NSColor]) -> NSColor? {
        guard !colors.isEmpty else {
            return nil
        }

        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var count: CGFloat = 0

        for rawColor in colors {
            guard let color = rawColor.usingColorSpace(.sRGB) else {
                continue
            }

            red += color.redComponent
            green += color.greenComponent
            blue += color.blueComponent
            count += 1
        }

        guard count > 0 else {
            return nil
        }

        return NSColor(
            srgbRed: red / count,
            green: green / count,
            blue: blue / count,
            alpha: 1
        )
    }

    private static func colorDistance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        guard
            let lhs = lhs.usingColorSpace(.sRGB),
            let rhs = rhs.usingColorSpace(.sRGB)
        else {
            return 0
        }

        let redDelta = lhs.redComponent - rhs.redComponent
        let greenDelta = lhs.greenComponent - rhs.greenComponent
        let blueDelta = lhs.blueComponent - rhs.blueComponent

        return sqrt(redDelta * redDelta + greenDelta * greenDelta + blueDelta * blueDelta)
    }

    private static func luminance(_ color: NSColor) -> CGFloat {
        guard let color = color.usingColorSpace(.sRGB) else {
            return 0
        }

        return 0.2126 * color.redComponent
            + 0.7152 * color.greenComponent
            + 0.0722 * color.blueComponent
    }

    private static func blockKind(
        for block: TextBlock,
        index: Int,
        medianLineHeight: CGFloat
    ) -> TextBlockKind {
        let text = block.text
        let firstText = block.lines.first?.text ?? text
        if isBulletLine(firstText) {
            return .listItem
        }

        if isCodeOnlyLine(text) {
            return .code
        }

        let blockLineHeight = median(
            block.lines.map { topLeftRect(fromVisionBox: $0.boundingBox).height }.filter { $0 > 0 }
        ) ?? medianLineHeight
        if looksLikeStandaloneHeading(text) {
            if index == 0 || blockLineHeight > medianLineHeight * 1.28 {
                return .title
            }
            return .heading
        }

        if block.lines.count == 1,
           text.count <= 60,
           blockLineHeight < medianLineHeight * 0.82 {
            return .caption
        }

        return .paragraph
    }

    private static func fontSize(for kind: TextBlockKind, sourceLineHeight: CGFloat) -> Double {
        switch kind {
        case .title:
            let baseSize = sourceLineHeight * 0.82
            return Double(min(max(baseSize, 0.018), 0.046))
        case .heading:
            let baseSize = sourceLineHeight * 0.82
            return Double(min(max(baseSize, 0.014), 0.034))
        case .paragraph, .listItem:
            let baseSize = sourceLineHeight * 1.08
            return Double(min(max(baseSize, 0.010), 0.034))
        case .caption:
            let baseSize = sourceLineHeight * 1.06
            return Double(min(max(baseSize, 0.008), 0.030))
        case .code:
            let baseSize = sourceLineHeight * 0.82
            return Double(min(max(baseSize, 0.009), 0.024))
        }
    }

    private static func belongsToSameVisualLine(_ fragment: Fragment, line: VisualLine) -> Bool {
        let box = line.boundingBox
        let smallerHeight = min(fragment.boundingBox.height, box.height)
        let verticalOverlap = min(fragment.boundingBox.maxY, box.maxY) - max(fragment.boundingBox.minY, box.minY)
        let overlapRatio = verticalOverlap / max(smallerHeight, 0.001)
        let midlineDistance = abs(fragment.boundingBox.midY - box.midY)
        let allowedDistance = max(fragment.boundingBox.height, box.height) * 0.45

        return overlapRatio > 0.35 || midlineDistance < allowedDistance
    }

    private static func isBulletLine(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("•")
            || trimmed.hasPrefix("·")
            || trimmed.hasPrefix("- ")
            || trimmed.hasPrefix("* ")
    }

    private static func looksLikeStandaloneHeading(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 36 else {
            return false
        }

        return !isBulletLine(trimmed)
            && trimmed.range(of: #"[.!?。！？:,，]"#, options: .regularExpression) == nil
    }

    private static func endsTextBlock(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }

        if lineSuggestsContinuation(trimmed) {
            return false
        }

        return trimmed.range(of: #"[.!?。！？]$"#, options: .regularExpression) != nil
    }

    private static func lineSuggestsContinuation(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }

        if trimmed.range(of: #"[-,;:，；：]$"#, options: .regularExpression) != nil {
            return true
        }

        return trimmed.range(
            of: #"\b(and|or|with|without|to|into|from|when|while|that|which|for|of|in|as)\s*$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func startsLikeNewSentence(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else {
            return false
        }

        return first.isUppercase || isBulletLine(trimmed)
    }

    private static func normalizedSourceText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func shouldUseSourceText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ImageTranslationSourcePolicy.shouldTranslate(trimmed) else {
            return false
        }

        return !isCodeOnlyLine(trimmed)
    }

    private static func isCodeOnlyLine(_ line: String) -> Bool {
        let tokens = line
            .split(whereSeparator: \.isWhitespace)
            .map { String($0).trimmingCharacters(in: codeTrimCharacters) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else {
            return false
        }

        return tokens.allSatisfy { token in
            token.range(of: #"^[A-Za-z0-9_./:-]+$"#, options: .regularExpression) != nil
                && (
                    token.range(of: #"[a-z][A-Z]"#, options: .regularExpression) != nil
                    || token.range(of: #"^[A-Z0-9_]{2,}$"#, options: .regularExpression) != nil
                    || token.contains("_")
                    || token.contains(".")
                    || token.contains("/")
                )
        }
    }

    private static func shouldPreserveCodeToken(_ text: String) -> Bool {
        let token = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: codeTrimCharacters)
        guard token.count >= 3, token.range(of: #"^[A-Za-z_][A-Za-z0-9_./:-]*$"#, options: .regularExpression) != nil else {
            return false
        }

        if ImageTranslationCodeHeuristics.isStrongIdentifier(token) {
            return true
        }

        if token.range(of: #"[a-z][A-Z]"#, options: .regularExpression) != nil, token.count >= 8 {
            return true
        }

        return token.contains("_")
            || token.contains(".")
            || token.contains("/")
            || token.range(of: #"^[A-Z0-9_]{3,}$"#, options: .regularExpression) != nil
    }

    private static let codeTrimCharacters = CharacterSet(charactersIn: ".,;:!?()[]{}<>`\"'“”‘’")

    private static func topLeftRect(fromVisionBox box: CGRect) -> CGRect {
        let x = min(max(box.minX, 0), 1)
        let y = min(max(1 - box.maxY, 0), 1)
        let maxX = min(max(box.maxX, 0), 1)
        let maxY = min(max(1 - box.minY, 0), 1)

        return CGRect(
            x: x,
            y: y,
            width: max(0, maxX - x),
            height: max(0, maxY - y)
        )
    }

    private static func expandedTextBlockRect(_ rect: CGRect, kind: TextBlockKind) -> CGRect {
        let horizontalMultiplier: CGFloat
        let verticalMultiplier: CGFloat
        switch kind {
        case .title, .heading:
            horizontalMultiplier = 0.18
            verticalMultiplier = 0.22
        case .listItem:
            horizontalMultiplier = 0.14
            verticalMultiplier = 0.16
        case .caption, .code:
            horizontalMultiplier = 0.10
            verticalMultiplier = 0.12
        case .paragraph:
            horizontalMultiplier = 0.16
            verticalMultiplier = 0.16
        }

        let horizontalPadding = max(0.002, rect.height * horizontalMultiplier)
        let verticalPadding = max(0.0015, rect.height * verticalMultiplier)
        let minX = max(0, rect.minX - horizontalPadding)
        let minY = max(0, rect.minY - verticalPadding)
        let maxX = min(1, rect.maxX + horizontalPadding)
        let maxY = min(1, rect.maxY + verticalPadding)

        return CGRect(
            x: minX,
            y: minY,
            width: max(0, maxX - minX),
            height: max(0, maxY - minY)
        )
    }

    private static func expandedTextLineRect(_ rect: CGRect, kind: TextBlockKind) -> CGRect {
        let horizontalMultiplier: CGFloat
        let verticalMultiplier: CGFloat
        switch kind {
        case .title, .heading:
            horizontalMultiplier = 0.14
            verticalMultiplier = 0.18
        case .listItem:
            horizontalMultiplier = 0.10
            verticalMultiplier = 0.12
        case .caption, .code:
            horizontalMultiplier = 0.08
            verticalMultiplier = 0.10
        case .paragraph:
            horizontalMultiplier = 0.10
            verticalMultiplier = 0.12
        }

        let horizontalPadding = max(0.0015, rect.height * horizontalMultiplier)
        let verticalPadding = max(0.001, rect.height * verticalMultiplier)
        let minX = max(0, rect.minX - horizontalPadding)
        let minY = max(0, rect.minY - verticalPadding)
        let maxX = min(1, rect.maxX + horizontalPadding)
        let maxY = min(1, rect.maxY + verticalPadding)

        return CGRect(
            x: minX,
            y: minY,
            width: max(0, maxX - minX),
            height: max(0, maxY - minY)
        )
    }

    private static func expandedTextFragmentRect(_ rect: CGRect) -> CGRect {
        let horizontalPadding = max(0.001, rect.height * 0.08)
        let verticalPadding = max(0.0008, rect.height * 0.10)
        let minX = max(0, rect.minX - horizontalPadding)
        let minY = max(0, rect.minY - verticalPadding)
        let maxX = min(1, rect.maxX + horizontalPadding)
        let maxY = min(1, rect.maxY + verticalPadding)

        return CGRect(
            x: minX,
            y: minY,
            width: max(0, maxX - minX),
            height: max(0, maxY - minY)
        )
    }

    private static func expandedCodeTokenRect(_ rect: CGRect) -> CGRect {
        let horizontalPadding = max(0.0015, rect.height * 0.18)
        let verticalPadding = max(0.001, rect.height * 0.12)
        let minX = max(0, rect.minX - horizontalPadding)
        let minY = max(0, rect.minY - verticalPadding)
        let maxX = min(1, rect.maxX + horizontalPadding)
        let maxY = min(1, rect.maxY + verticalPadding)

        return CGRect(
            x: minX,
            y: minY,
            width: max(0, maxX - minX),
            height: max(0, maxY - minY)
        )
    }

    private static func expandedProtectedTokenRect(_ rect: CGRect) -> CGRect {
        let horizontalPadding = max(0.0015, rect.height * 0.20)
        let verticalPadding = max(0.001, rect.height * 0.16)
        let minX = max(0, rect.minX - horizontalPadding)
        let minY = max(0, rect.minY - verticalPadding)
        let maxX = min(1, rect.maxX + horizontalPadding)
        let maxY = min(1, rect.maxY + verticalPadding)

        return CGRect(
            x: minX,
            y: minY,
            width: max(0, maxX - minX),
            height: max(0, maxY - minY)
        )
    }

    private static func median(_ values: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty else {
            return nil
        }

        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}

private extension String {
    func nonWhitespaceRanges() -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var tokenStart: String.Index?
        var index = startIndex

        while index < endIndex {
            if self[index].isWhitespace {
                if let start = tokenStart {
                    ranges.append(start..<index)
                    tokenStart = nil
                }
            } else if tokenStart == nil {
                tokenStart = index
            }

            index = self.index(after: index)
        }

        if let start = tokenStart {
            ranges.append(start..<endIndex)
        }

        return ranges
    }

    func sourceTokenRanges() -> [Range<String.Index>] {
        guard let expression = try? NSRegularExpression(pattern: #"[A-Za-z_][A-Za-z0-9_./:-]*"#) else {
            return []
        }

        let fullRange = NSRange(startIndex..<endIndex, in: self)
        return expression.matches(in: self, range: fullRange).compactMap { match in
            Range(match.range, in: self)
        }
    }

    func translationTokenRanges() -> [Range<String.Index>] {
        guard let expression = try? NSRegularExpression(
            pattern: #"[\p{L}\p{M}\p{N}_]+(?:[./:][\p{L}\p{M}\p{N}_]+)*|[^\s]"#
        ) else {
            return nonWhitespaceRanges()
        }

        let fullRange = NSRange(startIndex..<endIndex, in: self)
        return expression.matches(in: self, range: fullRange).compactMap { match in
            Range(match.range, in: self)
        }
    }
}

enum ImageTranslationMarkdownLineLayout {
    struct Token {
        let markdown: String
        let plainText: String
        let isCode: Bool
    }

    static func lines(
        for markdown: String,
        lineRects: [CGRect],
        codeRects: [CGRect],
        availableWidth: (CGRect) -> CGFloat,
        measuredWidth: (String, CGRect) -> CGFloat
    ) -> [String]? {
        guard lineRects.count > 1, !markdown.contains("\n") else {
            return nil
        }

        let tokens = markdownLineTokens(markdown)
        guard tokens.count >= lineRects.count else {
            return nil
        }

        let codeLineIndices = codeLineIndices(
            for: codeRects,
            lineRects: lineRects,
            expectedCodeCount: tokens.filter(\.isCode).count
        )
        if !codeRects.isEmpty, codeLineIndices == nil {
            return nil
        }

        var lineTokens = Array(repeating: [Token](), count: lineRects.count)
        var lineIndex = 0
        var codeTokenIndex = 0

        for tokenIndex in tokens.indices {
            let token = tokens[tokenIndex]
            if token.isCode, let codeLineIndices {
                let targetLineIndex = codeLineIndices[codeTokenIndex]
                guard targetLineIndex >= lineIndex else {
                    return nil
                }
                lineIndex = targetLineIndex
                lineTokens[lineIndex].append(token)
                codeTokenIndex += 1
                continue
            }

            if lineIndex < lineRects.count - 1, !lineTokens[lineIndex].isEmpty {
                let remainingTokensAfterThis = tokens.count - tokenIndex - 1
                let remainingLinesAfterThis = lineRects.count - lineIndex - 1
                let nextCodeLineIndex: Int
                if let codeLineIndices, codeTokenIndex < codeLineIndices.count {
                    nextCodeLineIndex = codeLineIndices[codeTokenIndex]
                } else {
                    nextCodeLineIndex = lineRects.count - 1
                }
                let canAdvanceBeforeNextCode = lineIndex < min(lineRects.count - 1, nextCodeLineIndex)
                let candidateText = markdownLine(from: lineTokens[lineIndex] + [token])
                let lineRect = lineRects[lineIndex]

                if measuredWidth(candidateText, lineRect) > availableWidth(lineRect) * 0.98,
                   remainingTokensAfterThis >= remainingLinesAfterThis,
                   canAdvanceBeforeNextCode {
                    lineIndex += 1
                }
            }

            lineTokens[lineIndex].append(token)
        }

        if let codeLineIndices, codeTokenIndex != codeLineIndices.count {
            return nil
        }

        let lines = lineTokens.map(markdownLine)
        guard lines.allSatisfy({ !$0.isEmpty }) else {
            return nil
        }
        return lines
    }

    private static func codeLineIndices(
        for codeRects: [CGRect],
        lineRects: [CGRect],
        expectedCodeCount: Int
    ) -> [Int]? {
        guard !codeRects.isEmpty else {
            return nil
        }
        guard expectedCodeCount == codeRects.count else {
            return nil
        }

        let indexedCodeRects = codeRects.compactMap { codeRect -> (rect: CGRect, lineIndex: Int)? in
            guard let lineIndex = bestLineIndex(for: codeRect, in: lineRects) else {
                return nil
            }
            return (codeRect, lineIndex)
        }
        guard indexedCodeRects.count == codeRects.count else {
            return nil
        }

        return indexedCodeRects
            .sorted { lhs, rhs in
                if lhs.lineIndex != rhs.lineIndex {
                    return lhs.lineIndex < rhs.lineIndex
                }
                return lhs.rect.minX < rhs.rect.minX
            }
            .map(\.lineIndex)
    }

    private static func bestLineIndex(for rect: CGRect, in lineRects: [CGRect]) -> Int? {
        lineRects.indices
            .map { index in
                (
                    index: index,
                    overlap: verticalOverlapRatio(rect, lineRects[index])
                )
            }
            .filter { $0.overlap > 0.22 }
            .max { lhs, rhs in lhs.overlap < rhs.overlap }?
            .index
    }

    private static func markdownLineTokens(_ markdown: String) -> [Token] {
        inlineMarkdownSpans(markdown).flatMap { span -> [Token] in
            if span.isCode {
                return [
                    Token(
                        markdown: "`\(span.text)`",
                        plainText: span.text,
                        isCode: true
                    )
                ]
            }

            return naturalTextTokens(span.text).map { token in
                Token(markdown: token, plainText: token, isCode: false)
            }
        }
    }

    private struct InlineMarkdownSpan {
        let text: String
        let isCode: Bool
    }

    private static func inlineMarkdownSpans(_ markdown: String) -> [InlineMarkdownSpan] {
        var spans: [InlineMarkdownSpan] = []
        var current = ""
        var isCode = false

        for character in markdown {
            if character == "`" {
                if !current.isEmpty {
                    spans.append(InlineMarkdownSpan(text: current, isCode: isCode))
                    current = ""
                }
                isCode.toggle()
            } else {
                current.append(character)
            }
        }

        if !current.isEmpty {
            spans.append(InlineMarkdownSpan(text: current, isCode: isCode))
        }

        return spans
    }

    private static func naturalTextTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""

        func flushCurrent() {
            if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }

        for character in text {
            if character.isWhitespace {
                flushCurrent()
            } else if isCJKCharacter(character) {
                flushCurrent()
                tokens.append(String(character))
            } else if isCJKPunctuation(character) {
                if current.isEmpty {
                    tokens.append(String(character))
                } else {
                    current.append(character)
                    flushCurrent()
                }
            } else {
                current.append(character)
            }
        }
        flushCurrent()

        return tokens
    }

    private static func markdownLine(from tokens: [Token]) -> String {
        var result = ""
        var previous: Token?

        for token in tokens {
            if result.isEmpty {
                result = token.markdown
            } else {
                if let previous {
                    if isBulletMarker(previous.plainText) {
                        result += "\t"
                    } else if shouldInsertSpace(between: previous.plainText, and: token.plainText) {
                        result += " "
                    }
                }
                result += token.markdown
            }
            previous = token
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isBulletMarker(_ text: String) -> Bool {
        ["•", "·", "▪", "◦", "-", "*"].contains(text)
    }

    private static func shouldInsertSpace(between lhs: String, and rhs: String) -> Bool {
        guard let lhsLast = lhs.last, let rhsFirst = rhs.first else {
            return false
        }

        if isClosingPunctuation(rhsFirst) || isOpeningPunctuation(lhsLast) {
            return false
        }

        if isCJKCharacter(lhsLast), isCJKCharacter(rhsFirst) {
            return false
        }

        return isASCIIAlphanumeric(lhsLast)
            || isASCIIAlphanumeric(rhsFirst)
            || lhsLast == "•"
            || lhsLast == "-"
    }

    private static func verticalOverlapRatio(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let overlap = min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY)
        return max(0, overlap) / max(min(lhs.height, rhs.height), 1)
    }

    private static func isCJKCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(Int(scalar.value))
                || (0x3400...0x4DBF).contains(Int(scalar.value))
                || (0x3040...0x30FF).contains(Int(scalar.value))
                || (0xAC00...0xD7AF).contains(Int(scalar.value))
        }
    }

    private static func isCJKPunctuation(_ character: Character) -> Bool {
        "，。！？；：、（）《》“”‘’".contains(character)
    }

    private static func isOpeningPunctuation(_ character: Character) -> Bool {
        "([{（《“‘".contains(character)
    }

    private static func isClosingPunctuation(_ character: Character) -> Bool {
        ".,;:!?)]}，。！？；：、）》”’".contains(character)
    }

    private static func isASCIIAlphanumeric(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII
        }
    }
}


enum ImageTranslationLayoutGeometry {
    static func expandedLineRects(
        _ lineRects: [CGRect],
        sourceRect: CGRect,
        bounds: CGRect
    ) -> [CGRect] {
        guard lineRects.count > 1 else {
            return lineRects
        }

        let originalRightEdge = lineRects.map(\.maxX).max() ?? sourceRect.maxX
        let rightEdge = min(bounds.maxX, max(sourceRect.maxX, originalRightEdge))

        return lineRects.map { lineRect in
            guard rightEdge > lineRect.minX + 1 else {
                return lineRect
            }

            return CGRect(
                x: lineRect.minX,
                y: lineRect.minY,
                width: rightEdge - lineRect.minX,
                height: lineRect.height
            )
            .intersection(bounds)
            .integral
        }
    }

    static func expandedCodeRect(_ rect: CGRect, text: String, bounds: CGRect) -> CGRect {
        guard rect.width > 1, rect.height > 1, !text.isEmpty else {
            return rect.intersection(bounds).integral
        }

        // The OCR box already includes the code-chip padding. Expanding with a
        // normal proportional-font coefficient made the protected rectangle
        // consume the first letters of the following prose ("owns", "compiles",
        // etc.). Monospaced glyphs inside these chips average about 0.39 of the
        // expanded chip height; the renderer adds its own antialiasing margin.
        let expectedTextWidth = rect.height * 0.39 * CGFloat(text.count)
        let rightEdge = min(
            bounds.maxX,
            rect.minX + max(rect.width, expectedTextWidth)
        )

        return CGRect(
            x: rect.minX,
            y: rect.minY,
            width: max(0, rightEdge - rect.minX),
            height: rect.height
        )
        .intersection(bounds)
        .integral
    }
}

enum ImageTranslationCodeHeuristics {
    static func isStrongIdentifier(_ text: String) -> Bool {
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count >= 4,
              token.range(of: #"^[A-Za-z_][A-Za-z0-9_./:-]*$"#, options: .regularExpression) != nil
        else {
            return false
        }

        if token.contains("_")
            || token.contains(".")
            || token.contains("/")
            || token.contains(":") {
            return true
        }

        let letters = token.filter(\.isLetter)
        guard letters.count >= 3 else {
            return false
        }
        if letters.allSatisfy({ $0.isUppercase }) {
            return true
        }

        // Strong standalone type/API identifiers normally begin with an
        // uppercase component. Lowercase-leading brand spellings such as
        // "macOS" are product names, not code tokens; visual chip detection
        // still handles genuine lowerCamelCase identifiers inside code UI.
        guard letters.first?.isUppercase == true else {
            return false
        }
        return letters.dropFirst().contains(where: { $0.isUppercase })
            && letters.contains(where: { $0.isLowercase })
    }
}

enum ImageTranslationSemanticNormalizer {
    static func normalize(_ blocks: [ImageTranslationBlock]) -> [ImageTranslationBlock] {
        blocks.flatMap { block in
            guard normalizedKind(block.kind) == "list_item" else {
                return [block]
            }

            let items = splitListItems(block.text)
            guard items.count > 1 else {
                return [block]
            }

            return items.enumerated().map { index, text in
                let fraction = Double(index) / Double(items.count)
                return ImageTranslationBlock(
                    text: text,
                    x: block.x,
                    y: min(1, block.y + block.height * fraction),
                    width: block.width,
                    height: max(0.006, block.height / Double(items.count)),
                    lineRects: [],
                    textRects: [],
                    trailingAttachments: block.trailingAttachments,
                    translationStrategy: block.translationStrategy,
                    codeRects: block.codeRects,
                    kind: block.kind,
                    textColor: block.textColor,
                    backgroundColor: block.backgroundColor,
                    alignment: block.alignment,
                    weight: block.weight,
                    fontSize: block.fontSize
                )
            }
        }
    }

    static func splitListItems(_ markdown: String) -> [String] {
        let text = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let expression = try? NSRegularExpression(
                pattern: #"(?:^|\s)[•·]\s+|(?:^|\n)\s*[-*]\s+"#
              )
        else {
            return []
        }

        let nsText = text as NSString
        let matches = expression.matches(
            in: text,
            range: NSRange(location: 0, length: nsText.length)
        )
        guard !matches.isEmpty else {
            return [text]
        }

        var items: [String] = []
        var start = matches[0].range.location + matches[0].range.length
        for match in matches.dropFirst() {
            let range = NSRange(location: start, length: max(0, match.range.location - start))
            let item = nsText.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            if !item.isEmpty {
                items.append(item)
            }
            start = match.range.location + match.range.length
        }

        let tail = nsText.substring(from: start).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            items.append(tail)
        }

        return items.isEmpty ? [text] : items
    }

    private static func normalizedKind(_ kind: String?) -> String {
        kind?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_") ?? "paragraph"
    }
}

enum ImageTranslationElasticSpacing {
    static func distributedGaps(
        baseGaps: [CGFloat],
        minimumGaps: [CGFloat],
        maximumGaps: [CGFloat],
        itemHeights: [CGFloat],
        availableHeight: CGFloat
    ) -> [CGFloat] {
        guard baseGaps.count == minimumGaps.count,
              baseGaps.count == maximumGaps.count,
              baseGaps.count == itemHeights.count,
              !baseGaps.isEmpty
        else {
            return baseGaps
        }

        let availableForGaps = max(0, availableHeight - itemHeights.reduce(0, +))
        let minimumTotal = minimumGaps.reduce(0, +)
        let baseTotal = baseGaps.reduce(0, +)

        if availableForGaps <= baseTotal {
            guard minimumTotal > 0 else {
                return Array(repeating: 0, count: baseGaps.count)
            }
            if availableForGaps <= minimumTotal {
                let scale = availableForGaps / minimumTotal
                return minimumGaps.map { $0 * scale }
            }

            let flexibleTotal = max(1, baseTotal - minimumTotal)
            let progress = (availableForGaps - minimumTotal) / flexibleTotal
            return zip(minimumGaps, baseGaps).map { minimum, base in
                minimum + (base - minimum) * progress
            }
        }

        var gaps = baseGaps
        var remaining = availableForGaps - baseTotal
        for _ in 0..<baseGaps.count where remaining > 0.5 {
            let expandable = gaps.indices.filter { gaps[$0] < maximumGaps[$0] - 0.5 }
            guard !expandable.isEmpty else {
                break
            }
            let share = remaining / CGFloat(expandable.count)
            var consumed: CGFloat = 0
            for index in expandable {
                let addition = min(share, maximumGaps[index] - gaps[index])
                gaps[index] += addition
                consumed += addition
            }
            remaining -= consumed
        }

        return gaps
    }
}

@MainActor
enum ImageTranslationRenderer {
    static func originalImage(source pickedImage: PickedImage) -> NSImage? {
        guard let cgImage = sourceCGImage(from: pickedImage) else {
            return nil
        }

        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
    }

    static func render(source pickedImage: PickedImage, blocks: [ImageTranslationBlock]) -> NSImage? {
        guard let cgImage = sourceCGImage(from: pickedImage) else {
            return nil
        }

        let imageSize = NSSize(width: cgImage.width, height: cgImage.height)
        let bounds = CGRect(origin: .zero, size: imageSize)
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let backgroundSourceImage = NSImage(cgImage: cgImage, size: imageSize)
        let output = (pickedImage.image.copy() as? NSImage) ?? NSImage(cgImage: cgImage, size: imageSize)
        output.size = imageSize

        output.lockFocus()
        defer {
            output.unlockFocus()
        }

        let translatedBlocks = blocks.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !translatedBlocks.isEmpty else {
            return output
        }

        let drawableBlocks = layoutDrawableBlocks(
            blocks: translatedBlocks,
            imageSize: imageSize,
            bounds: bounds,
        )
        let canvasBackgroundColor = semanticCanvasBackground(
            bitmap: bitmap,
            bounds: bounds
        )
        for drawableBlock in drawableBlocks {
            draw(
                drawableBlock,
                imageSize: imageSize,
                bounds: bounds,
                bitmap: bitmap,
                backgroundSourceImage: backgroundSourceImage,
                canvasBackgroundColor: canvasBackgroundColor
            )
        }

        return output
    }

    private static func sourceCGImage(from pickedImage: PickedImage) -> CGImage? {
        var sourceRect = CGRect(origin: .zero, size: pickedImage.image.size)
        return pickedImage.image.cgImage(
            forProposedRect: &sourceRect,
            context: nil,
            hints: nil
        )
    }

    private struct SemanticLayoutItem {
        let kind: String
        let fontSize: CGFloat
        let spacingBefore: CGFloat
        let horizontalInset: CGFloat
        let sourceTopRatio: CGFloat
        let attributed: AttributedMarkdownLayout
        let measuredHeight: CGFloat
    }

    private static func drawSemanticTranslationLayer(
        blocks: [ImageTranslationBlock],
        imageSize: CGSize,
        bounds: CGRect,
        bitmap: NSBitmapImageRep
    ) {
        let backgroundColor = semanticCanvasBackground(bitmap: bitmap, bounds: bounds)
        let foregroundColor = readableTextColor(on: backgroundColor)
        drawSemanticCanvas(in: bounds, backgroundColor: backgroundColor)

        let margin = max(18, min(54, min(bounds.width * 0.038, bounds.height * 0.045)))
        let contentWidth = max(1, bounds.width - margin * 2)
        let availableHeight = max(1, bounds.height - margin * 2)
        let orderedBlocks = ImageTranslationSemanticNormalizer.normalize(blocks).sorted { lhs, rhs in
            if abs(lhs.y - rhs.y) > 0.006 {
                return lhs.y < rhs.y
            }
            return lhs.x < rhs.x
        }

        var scale: CGFloat = 1
        var spacingScale: CGFloat = 1
        var items = semanticLayoutItems(
            blocks: orderedBlocks,
            imageSize: imageSize,
            contentWidth: contentWidth,
            foregroundColor: foregroundColor,
            scale: scale,
            spacingScale: spacingScale
        )

        for _ in 0..<12 {
            let frames = semanticFrames(for: items, in: bounds, margin: margin)
            let minimumY = frames.map(\.minY).min() ?? bounds.minY + margin
            let safeBottom = bounds.minY + margin * 0.72
            guard minimumY < safeBottom else {
                break
            }

            if spacingScale > 0.56 {
                spacingScale = max(0.56, spacingScale * 0.86)
            } else if scale > 0.58 {
                let overflow = safeBottom - minimumY
                let correction = max(0.84, min(0.96, availableHeight / max(availableHeight + overflow, 1)))
                scale = max(0.58, scale * correction)
            } else {
                break
            }
            items = semanticLayoutItems(
                blocks: orderedBlocks,
                imageSize: imageSize,
                contentWidth: contentWidth,
                foregroundColor: foregroundColor,
                scale: scale,
                spacingScale: spacingScale
            )
        }

        let chipColor = codeChipColor(on: backgroundColor)
        let dividerColor = foregroundColor.withAlphaComponent(0.14)
        let frames = semanticFrames(for: items, in: bounds, margin: margin)

        for (item, rect) in zip(items, frames) {
            guard rect.minY >= bounds.minY + margin * 0.32 else {
                break
            }

            if item.kind == "code" {
                chipColor.withAlphaComponent(0.72).setFill()
                NSBezierPath(
                    roundedRect: rect.insetBy(dx: -item.fontSize * 0.42, dy: -item.fontSize * 0.28),
                    xRadius: max(4, item.fontSize * 0.28),
                    yRadius: max(4, item.fontSize * 0.28)
                ).fill()
            }

            drawCodeChipBackgrounds(
                for: item.attributed,
                in: rect,
                color: chipColor,
                fontSize: item.fontSize
            )
            item.attributed.attributed.draw(
                with: rect,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )

            if item.kind == "title" || item.kind == "heading" {
                let dividerY = rect.minY - semanticDividerGap(for: item)
                dividerColor.setStroke()
                let path = NSBezierPath()
                path.lineWidth = max(1, imageSize.height * 0.001)
                path.move(to: CGPoint(x: bounds.minX + margin, y: dividerY))
                path.line(to: CGPoint(x: bounds.maxX - margin, y: dividerY))
                path.stroke()
            }
        }
    }

    private static func semanticFrames(
        for items: [SemanticLayoutItem],
        in bounds: CGRect,
        margin: CGFloat
    ) -> [CGRect] {
        guard !items.isEmpty else {
            return []
        }

        let contentWidth = max(1, bounds.width - margin * 2)
        var previousBottom = bounds.maxY - margin
        var frames: [CGRect] = []

        let anchorIndices = items.indices.filter { index in
            index == 0 || items[index].kind == "title" || items[index].kind == "heading"
        }

        for (anchorPosition, anchorIndex) in anchorIndices.enumerated() {
            let anchor = items[anchorIndex]
            let desiredTop = semanticDesiredTop(for: anchor, in: bounds, margin: margin)
            let anchorTop = min(previousBottom - anchor.spacingBefore, desiredTop)
            let anchorRect = semanticFrame(
                for: anchor,
                top: anchorTop,
                bounds: bounds,
                margin: margin,
                contentWidth: contentWidth
            )
            frames.append(anchorRect)

            let nextAnchorIndex = anchorPosition + 1 < anchorIndices.count
                ? anchorIndices[anchorPosition + 1]
                : items.count
            let contentIndices = Array((anchorIndex + 1)..<nextAnchorIndex)
            guard !contentIndices.isEmpty else {
                previousBottom = anchorRect.minY - semanticDividerGap(for: anchor)
                continue
            }

            let sectionTop = anchorRect.minY - semanticDividerGap(for: anchor)
            let sectionBottom: CGFloat
            if nextAnchorIndex < items.count {
                let nextAnchor = items[nextAnchorIndex]
                sectionBottom = semanticDesiredTop(for: nextAnchor, in: bounds, margin: margin)
                    + nextAnchor.spacingBefore
            } else {
                sectionBottom = bounds.minY + margin * 0.72
            }

            let sectionItems = contentIndices.map { items[$0] }
            let gaps = ImageTranslationElasticSpacing.distributedGaps(
                baseGaps: sectionItems.map(\.spacingBefore),
                minimumGaps: sectionItems.map { max(5, $0.fontSize * 0.30) },
                maximumGaps: sectionItems.map { item in
                    item.kind == "list_item"
                        ? max(item.spacingBefore, item.fontSize * 1.75)
                        : max(item.spacingBefore, item.fontSize * 1.90)
                },
                itemHeights: sectionItems.map(\.measuredHeight),
                availableHeight: max(0, sectionTop - sectionBottom)
            )

            var cursorY = sectionTop
            for (item, gap) in zip(sectionItems, gaps) {
                cursorY -= gap
                let rect = semanticFrame(
                    for: item,
                    top: cursorY,
                    bounds: bounds,
                    margin: margin,
                    contentWidth: contentWidth
                )
                frames.append(rect)
                cursorY = rect.minY
            }
            previousBottom = cursorY
        }

        return frames
    }

    private static func semanticDesiredTop(
        for item: SemanticLayoutItem,
        in bounds: CGRect,
        margin: CGFloat
    ) -> CGFloat {
        let sourceTop = bounds.maxY - min(max(item.sourceTopRatio, 0), 1) * bounds.height
        return min(bounds.maxY - margin, max(bounds.minY + margin, sourceTop))
    }

    private static func semanticFrame(
        for item: SemanticLayoutItem,
        top: CGFloat,
        bounds: CGRect,
        margin: CGFloat,
        contentWidth: CGFloat
    ) -> CGRect {
        CGRect(
            x: bounds.minX + margin + item.horizontalInset,
            y: top - item.measuredHeight,
            width: max(1, contentWidth - item.horizontalInset),
            height: item.measuredHeight
        ).integral
    }

    private static func semanticDividerGap(for item: SemanticLayoutItem) -> CGFloat {
        item.kind == "title" || item.kind == "heading"
            ? max(5, item.fontSize * 0.34)
            : 0
    }

    private static func semanticLayoutItems(
        blocks: [ImageTranslationBlock],
        imageSize: CGSize,
        contentWidth: CGFloat,
        foregroundColor: NSColor,
        scale: CGFloat,
        spacingScale: CGFloat
    ) -> [SemanticLayoutItem] {
        blocks.enumerated().map { index, block in
            let kind = normalizedKind(block.kind)
            let fontSize = semanticFontSize(for: block, imageSize: imageSize) * scale
            let horizontalInset = kind == "list_item" ? fontSize * 0.9 : 0
            let width = max(1, contentWidth - horizontalInset)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = textAlignment(from: block.alignment)
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.lineSpacing = semanticLineSpacing(kind: kind, fontSize: fontSize)
            if kind == "list_item" {
                paragraph.firstLineHeadIndent = 0
                paragraph.headIndent = fontSize * 1.05
            }

            let text = semanticText(for: block.text, kind: kind)
            let attributed = attributedMarkdownLayout(
                text,
                fontSize: fontSize,
                weight: semanticFontWeight(kind: kind, block: block),
                foregroundColor: foregroundColor,
                paragraph: paragraph
            )
            let measured = measuredAttributedTextSize(attributed.attributed, constrainedTo: width)

            return SemanticLayoutItem(
                kind: kind,
                fontSize: fontSize,
                spacingBefore: semanticSpacingBefore(kind: kind, index: index, fontSize: fontSize) * spacingScale,
                horizontalInset: horizontalInset,
                sourceTopRatio: CGFloat(block.y),
                attributed: attributed,
                measuredHeight: max(fontSize * 1.18, measured.height)
            )
        }
    }

    private static func semanticText(for markdown: String, kind: String) -> String {
        let text = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard kind == "list_item" else {
            return text
        }

        let bulletPrefixes = ["•", "·", "- ", "* "]
        return bulletPrefixes.contains(where: { text.hasPrefix($0) }) ? text : "• \(text)"
    }

    private static func semanticFontSize(for block: ImageTranslationBlock, imageSize: CGSize) -> CGFloat {
        let sourceRect = blockRect(block, imageSize: imageSize)
        let inferred = baseFontSize(block.fontSize, imageHeight: imageSize.height, rect: sourceRect)
        let kind = normalizedKind(block.kind)

        switch kind {
        case "title":
            return min(max(inferred, imageSize.height * 0.052), imageSize.height * 0.060)
        case "heading":
            return min(max(inferred, imageSize.height * 0.038), imageSize.height * 0.046)
        case "caption":
            return min(max(inferred, imageSize.height * 0.018), imageSize.height * 0.024)
        case "code":
            return min(max(inferred, imageSize.height * 0.023), imageSize.height * 0.030)
        default:
            return min(max(inferred, imageSize.height * 0.026), imageSize.height * 0.032)
        }
    }

    private static func semanticFontWeight(kind: String, block: ImageTranslationBlock) -> NSFont.Weight {
        switch kind {
        case "title":
            return .bold
        case "heading":
            return .semibold
        default:
            return block.weight == nil ? .regular : fontWeight(from: block.weight)
        }
    }

    private static func semanticLineSpacing(kind: String, fontSize: CGFloat) -> CGFloat {
        switch kind {
        case "title", "heading", "caption", "code":
            return fontSize * 0.08
        default:
            return fontSize * 0.22
        }
    }

    private static func semanticSpacingBefore(kind: String, index: Int, fontSize: CGFloat) -> CGFloat {
        guard index > 0 else {
            return 0
        }

        switch kind {
        case "title":
            return fontSize * 0.25
        case "heading":
            return fontSize * 1.05
        case "list_item":
            return fontSize * 0.72
        case "caption":
            return fontSize * 0.68
        default:
            return fontSize * 1.05
        }
    }

    private static func semanticCanvasBackground(bitmap: NSBitmapImageRep, bounds: CGRect) -> NSColor {
        let insetX = max(2, bounds.width * 0.025)
        let insetY = max(2, bounds.height * 0.025)
        let xValues = [bounds.minX + insetX, bounds.midX, bounds.maxX - insetX]
        let yValues = [bounds.minY + insetY, bounds.midY, bounds.maxY - insetY]
        let edgePoints = xValues.flatMap { x in
            [
                CGPoint(x: x, y: bounds.minY + insetY),
                CGPoint(x: x, y: bounds.maxY - insetY)
            ]
        } + yValues.flatMap { y in
            [
                CGPoint(x: bounds.minX + insetX, y: y),
                CGPoint(x: bounds.maxX - insetX, y: y)
            ]
        }
        let colors = edgePoints.compactMap { point in
            sampledColor(appKitX: point.x, appKitY: point.y, bitmap: bitmap, bounds: bounds)
        }

        return dominantBackgroundColor(colors)
            ?? averageColor(colors)
            ?? .windowBackgroundColor
    }

    private static func drawSemanticCanvas(in bounds: CGRect, backgroundColor: NSColor) {
        let topColor: NSColor
        if luminance(backgroundColor) < 0.5 {
            topColor = blendedColor(from: backgroundColor, to: .white, progress: 0.035)
        } else {
            topColor = blendedColor(from: backgroundColor, to: .black, progress: 0.018)
        }

        if let gradient = NSGradient(starting: topColor, ending: backgroundColor) {
            gradient.draw(in: bounds, angle: 90)
        } else {
            backgroundColor.setFill()
            NSBezierPath(rect: bounds).fill()
        }
    }

    private struct DrawableBlock {
        let block: ImageTranslationBlock
        let sourceRect: CGRect
        let sourceLineRects: [CGRect]
        let sourceTextRects: [CGRect]
        let sourceProtectedRects: [CGRect]
        let sourceTrailingAttachmentRects: [CGRect]
        let sourceCodeRects: [CGRect]
        let layoutLineRects: [CGRect]
        let layoutRect: CGRect
    }

    private static func layoutDrawableBlocks(
        blocks: [ImageTranslationBlock],
        imageSize: CGSize,
        bounds: CGRect
    ) -> [DrawableBlock] {
        let sourceRects = blocks
            .filter { !$0.text.isEmpty }
            .map { block in
                (
                    block: block,
                    rect: blockRect(block, imageSize: imageSize)
                        .intersection(bounds)
                        .integral
                )
            }
            .filter { $0.rect.width > 1 && $0.rect.height > 1 }
            .sorted { lhs, rhs in
                if abs(lhs.rect.midY - rhs.rect.midY) > 2 {
                    return lhs.rect.midY > rhs.rect.midY
                }
                return lhs.rect.minX < rhs.rect.minX
            }

        return sourceRects.map { item in
            let lineRects = sourceLineRects(
                for: item.block,
                imageSize: imageSize,
                bounds: bounds
            )
            let textRects = sourceTextRects(
                for: item.block,
                imageSize: imageSize,
                bounds: bounds
            )
            let protectedRects = sourceProtectedRects(
                for: item.block,
                imageSize: imageSize,
                bounds: bounds
            )
            let trailingAttachmentRects = sourceTrailingAttachmentRects(
                for: item.block,
                imageSize: imageSize,
                bounds: bounds
            )
            let codeRects = sourceCodeRects(
                for: item.block,
                imageSize: imageSize,
                bounds: bounds,
                textRects: textRects
            )
            let layoutLineRects = ImageTranslationLayoutGeometry.expandedLineRects(
                lineRects,
                sourceRect: item.rect,
                bounds: bounds
            )
            let layoutRect = sourceLayoutRect(
                sourceRect: item.rect,
                lineRects: layoutLineRects,
                bounds: bounds
            )

            return DrawableBlock(
                block: item.block,
                sourceRect: item.rect,
                sourceLineRects: lineRects,
                sourceTextRects: textRects,
                sourceProtectedRects: protectedRects,
                sourceTrailingAttachmentRects: trailingAttachmentRects,
                sourceCodeRects: codeRects,
                layoutLineRects: layoutLineRects,
                layoutRect: layoutRect.intersection(bounds).integral
            )
        }
    }

    private static func sourceLineRects(
        for block: ImageTranslationBlock,
        imageSize: CGSize,
        bounds: CGRect
    ) -> [CGRect] {
        block.lineRects
            .map { lineRect in
                CGRect(
                    x: CGFloat(lineRect.x) * imageSize.width,
                    y: imageSize.height - (CGFloat(lineRect.y) * imageSize.height) - CGFloat(lineRect.height) * imageSize.height,
                    width: CGFloat(lineRect.width) * imageSize.width,
                    height: CGFloat(lineRect.height) * imageSize.height
                )
                .intersection(bounds)
                .integral
            }
            .filter { (rect: CGRect) in rect.width > 1 && rect.height > 1 }
    }

    private static func sourceTextRects(
        for block: ImageTranslationBlock,
        imageSize: CGSize,
        bounds: CGRect
    ) -> [CGRect] {
        block.textRects
            .map { textRect in
                CGRect(
                    x: CGFloat(textRect.x) * imageSize.width,
                    y: imageSize.height - (CGFloat(textRect.y) * imageSize.height) - CGFloat(textRect.height) * imageSize.height,
                    width: CGFloat(textRect.width) * imageSize.width,
                    height: CGFloat(textRect.height) * imageSize.height
                )
                .intersection(bounds)
                .integral
            }
            .filter { $0.width > 1 && $0.height > 1 }
    }

    private static func sourceCodeRects(
        for block: ImageTranslationBlock,
        imageSize: CGSize,
        bounds: CGRect,
        textRects: [CGRect]
    ) -> [CGRect] {
        let translatedCodeTexts = inlineMarkdownSpans(block.text)
            .filter(\.isCode)
            .map(\.text)

        return block.codeRects
            .enumerated()
            .map { index, tokenRect in
                let rect = CGRect(
                    x: CGFloat(tokenRect.x) * imageSize.width,
                    y: imageSize.height - (CGFloat(tokenRect.y) * imageSize.height) - CGFloat(tokenRect.height) * imageSize.height,
                    width: CGFloat(tokenRect.width) * imageSize.width,
                    height: CGFloat(tokenRect.height) * imageSize.height
                )
                .intersection(bounds)
                .integral

                let expandedRect = ImageTranslationLayoutGeometry.expandedCodeRect(
                    rect,
                    text: index < translatedCodeTexts.count
                        ? (translatedCodeTexts[index].count > tokenRect.text.count
                            ? translatedCodeTexts[index]
                            : tokenRect.text)
                        : tokenRect.text,
                    bounds: bounds
                )
                let nextTextRect = textRects
                    .filter { candidate in
                        verticalOverlapRatio(candidate, rect) > 0.30
                            && candidate.minX >= rect.maxX - max(2, rect.height * 0.18)
                    }
                    .min { $0.minX < $1.minX }
                guard let nextTextRect else {
                    return expandedRect
                }

                let neighborGap = max(1, rect.height * 0.06)
                let cappedMaxX = min(expandedRect.maxX, nextTextRect.minX - neighborGap)
                guard cappedMaxX > expandedRect.minX + 1 else {
                    return expandedRect
                }
                return CGRect(
                    x: expandedRect.minX,
                    y: expandedRect.minY,
                    width: cappedMaxX - expandedRect.minX,
                    height: expandedRect.height
                ).integral
            }
            .filter { (rect: CGRect) in rect.width > 1 && rect.height > 1 }
    }

    private static func sourceTrailingAttachmentRects(
        for block: ImageTranslationBlock,
        imageSize: CGSize,
        bounds: CGRect
    ) -> [CGRect] {
        block.trailingAttachments
            .map { attachmentRect in
                CGRect(
                    x: CGFloat(attachmentRect.x) * imageSize.width,
                    y: imageSize.height
                        - CGFloat(attachmentRect.y) * imageSize.height
                        - CGFloat(attachmentRect.height) * imageSize.height,
                    width: CGFloat(attachmentRect.width) * imageSize.width,
                    height: CGFloat(attachmentRect.height) * imageSize.height
                )
                .intersection(bounds)
                .integral
            }
            .filter { $0.width > 1 && $0.height > 1 }
    }

    private static func sourceProtectedRects(
        for block: ImageTranslationBlock,
        imageSize: CGSize,
        bounds: CGRect
    ) -> [CGRect] {
        block.protectedRects
            .map { protectedRect in
                CGRect(
                    x: CGFloat(protectedRect.x) * imageSize.width,
                    y: imageSize.height
                        - CGFloat(protectedRect.y) * imageSize.height
                        - CGFloat(protectedRect.height) * imageSize.height,
                    width: CGFloat(protectedRect.width) * imageSize.width,
                    height: CGFloat(protectedRect.height) * imageSize.height
                )
                .intersection(bounds)
                .integral
            }
            .filter { $0.width > 1 && $0.height > 1 }
    }

    private static func sourceLayoutRect(
        sourceRect: CGRect,
        lineRects: [CGRect],
        bounds: CGRect
    ) -> CGRect {
        guard let firstLineRect = lineRects.first else {
            return sourceRect.intersection(bounds).integral
        }

        let rect = lineRects
            .dropFirst()
            .reduce(firstLineRect) { partial, lineRect in
                partial.union(lineRect)
            }

        return rect.intersection(sourceRect.union(rect)).intersection(bounds).integral
    }

    private static func verticalOverlapRatio(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let overlap = min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY)
        return max(0, overlap) / max(min(lhs.height, rhs.height), 1)
    }

    private static func draw(
        _ drawableBlock: DrawableBlock,
        imageSize: CGSize,
        bounds: CGRect,
        bitmap: NSBitmapImageRep,
        backgroundSourceImage: NSImage,
        canvasBackgroundColor: NSColor
    ) {
        let block = drawableBlock.block
        let rect = drawableBlock.layoutRect.intersection(bounds).integral
        guard rect.width > 1, rect.height > 1 else {
            return
        }

        let backgroundSampleRect = drawableBlock.sourceRect
            .insetBy(dx: -max(1, drawableBlock.sourceRect.height * 0.05), dy: -max(1, drawableBlock.sourceRect.height * 0.08))
            .intersection(bounds)
            .integral
        let eraseRects = sourceEraseRects(
            for: drawableBlock,
            imageHeight: imageSize.height,
            bounds: bounds
        )
        let sampledLocalBackgroundColor = sampledBackgroundColor(
                in: backgroundSampleRect,
                bitmap: bitmap
            )
            ?? dominantInteriorBackgroundColor(
                in: eraseRects,
                bitmap: bitmap,
                bounds: bounds
            )
            ?? color(from: block.backgroundColor)
            ?? .windowBackgroundColor
        let backgroundColor = harmonizedBackgroundColor(
            sampledLocalBackgroundColor,
            canvasBackgroundColor: canvasBackgroundColor
        )
        let foregroundColor = color(from: block.textColor)
            ?? sampledForegroundColor(
                in: drawableBlock.sourceTextRects.isEmpty
                    ? drawableBlock.sourceLineRects
                    : drawableBlock.sourceTextRects,
                bitmap: bitmap,
                backgroundColor: backgroundColor,
                bounds: bounds
            )
            ?? readableTextColor(on: backgroundColor)
        let inlineCodeBackgroundColor = dominantInteriorBackgroundColor(
            in: drawableBlock.sourceCodeRects,
            bitmap: bitmap,
            bounds: bounds
        ) ?? codeChipColor(on: backgroundColor)
        let backgroundPatchSourceRect = backgroundPatchSourceRect(
            around: backgroundSampleRect,
            matching: backgroundColor,
            bitmap: bitmap,
            bounds: bounds
        )

        for eraseRect in mergedEraseRects(eraseRects) {
            paintBackgroundPatch(
                in: eraseRect,
                sourceImage: backgroundSourceImage,
                sourceRect: backgroundPatchSourceRect,
                color: backgroundColor
            )
        }

        for attachmentRect in drawableBlock.sourceTrailingAttachmentRects {
            let padding = max(1, min(attachmentRect.height * 0.08, 3))
            paintBackgroundPatch(
                in: attachmentRect.insetBy(dx: -padding, dy: -padding).intersection(bounds).integral,
                sourceImage: backgroundSourceImage,
                sourceRect: backgroundPatchSourceRect,
                color: backgroundColor
            )
        }

        let preservesSourceCode = block.translationStrategy == .selective
            && !drawableBlock.sourceCodeRects.isEmpty
        drawText(
            block,
            in: rect,
            lineRects: drawableBlock.layoutLineRects,
            codeRects: preservesSourceCode ? drawableBlock.sourceCodeRects : [],
            imageHeight: imageSize.height,
            foregroundColor: foregroundColor,
            backgroundColor: backgroundColor,
            inlineCodeBackgroundColor: inlineCodeBackgroundColor,
            alignment: textAlignment(from: block.alignment),
            sourceHeight: drawableBlock.sourceRect.height,
            preserveSourceCode: preservesSourceCode
        )

        drawTrailingAttachments(
            drawableBlock,
            imageHeight: imageSize.height,
            bounds: bounds,
            bitmap: bitmap
        )
    }

    private static func paintBackgroundPatch(
        in rect: CGRect,
        sourceImage: NSImage,
        sourceRect: CGRect?,
        color: NSColor
    ) {
        if let sourceRect, sourceRect.width > 0, sourceRect.height > 0 {
            sourceImage.draw(
                in: rect,
                from: sourceRect,
                operation: .copy,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.none]
            )
            return
        }

        let fillColor: NSColor
        if let sourceColor = color.usingColorSpace(.sRGB) {
            fillColor = NSColor(
                deviceRed: sourceColor.redComponent,
                green: sourceColor.greenComponent,
                blue: sourceColor.blueComponent,
                alpha: 1
            )
        } else {
            fillColor = color
        }
        fillColor.setFill()
        NSBezierPath(rect: rect).fill()
    }

    /// Selects an untouched source pixel near the text block so erasing old text
    /// preserves the screenshot's exact color profile instead of repainting an
    /// approximately matching `NSColor` that can shift after ColorSync conversion.
    private static func backgroundPatchSourceRect(
        around rect: CGRect,
        matching backgroundColor: NSColor,
        bitmap: NSBitmapImageRep,
        bounds: CGRect
    ) -> CGRect? {
        let sampleOffset = max(2, min(10, rect.height * 0.20))
        let fractions: [CGFloat] = [0.08, 0.22, 0.38, 0.5, 0.62, 0.78, 0.92]
        var points: [CGPoint] = []

        for fraction in fractions {
            points.append(CGPoint(x: rect.minX + rect.width * fraction, y: rect.minY - sampleOffset))
            points.append(CGPoint(x: rect.minX + rect.width * fraction, y: rect.maxY + sampleOffset))
            points.append(CGPoint(x: rect.minX - sampleOffset, y: rect.minY + rect.height * fraction))
            points.append(CGPoint(x: rect.maxX + sampleOffset, y: rect.minY + rect.height * fraction))
        }

        let candidates = points.compactMap { point -> (point: CGPoint, distance: CGFloat)? in
            guard bounds.contains(point), let color = sampledColor(
                appKitX: point.x,
                appKitY: point.y,
                bitmap: bitmap,
                bounds: bounds
            ) else {
                return nil
            }
            return (point, rgbDistance(color, backgroundColor))
        }
        guard let candidate = candidates.min(by: { $0.distance < $1.distance }) else {
            return nil
        }

        let pixelWidth = max(1, bounds.width / CGFloat(max(bitmap.pixelsWide, 1)))
        let pixelHeight = max(1, bounds.height / CGFloat(max(bitmap.pixelsHigh, 1)))
        return CGRect(
            x: floor(candidate.point.x),
            y: floor(candidate.point.y),
            width: pixelWidth,
            height: pixelHeight
        ).intersection(bounds)
    }

    private static func mergedEraseRects(_ rects: [CGRect]) -> [CGRect] {
        var merged = rects
            .filter { $0.width > 1 && $0.height > 1 }
            .map(\.integral)
            .sorted { lhs, rhs in
                if abs(lhs.minY - rhs.minY) > 1 {
                    return lhs.minY < rhs.minY
                }
                return lhs.minX < rhs.minX
            }

        var didMerge = true
        while didMerge {
            didMerge = false
            outer: for firstIndex in merged.indices {
                for secondIndex in merged.indices where secondIndex > firstIndex {
                    let lhs = merged[firstIndex]
                    let rhs = merged[secondIndex]
                    let horizontalOverlap = min(lhs.maxX, rhs.maxX) - max(lhs.minX, rhs.minX)
                    let verticalOverlap = min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY)
                    let horizontalGap = max(0, max(lhs.minX, rhs.minX) - min(lhs.maxX, rhs.maxX))
                    let verticalGap = max(0, max(lhs.minY, rhs.minY) - min(lhs.maxY, rhs.maxY))
                    let sharesVisualRow = verticalOverlap >= min(lhs.height, rhs.height) * 0.45
                        && horizontalGap <= 2
                    let sharesVisualColumn = horizontalOverlap >= min(lhs.width, rhs.width) * 0.45
                        && verticalGap <= 2

                    guard sharesVisualRow || sharesVisualColumn else {
                        continue
                    }

                    merged[firstIndex] = lhs.union(rhs).integral
                    merged.remove(at: secondIndex)
                    didMerge = true
                    break outer
                }
            }
        }

        return merged
    }

    private static func sourceEraseRects(
        for drawableBlock: DrawableBlock,
        imageHeight: CGFloat,
        bounds: CGRect
    ) -> [CGRect] {
        if drawableBlock.block.translationStrategy == .block {
            let blockEraseBases = drawableBlock.sourceLineRects.isEmpty
                ? [drawableBlock.sourceRect]
                : drawableBlock.sourceLineRects
            return blockEraseBases.compactMap { sourceLineRect in
                let horizontalPadding = max(2, min(sourceLineRect.height * 0.12, 6))
                let verticalPadding = max(2, min(sourceLineRect.height * 0.16, 8))
                let rect = sourceLineRect
                    .insetBy(dx: -horizontalPadding, dy: -verticalPadding)
                    .intersection(bounds)
                    .integral
                return rect.width > 1 && rect.height > 1 ? rect : nil
            }
        }

        let preservedRects = drawableBlock.sourceCodeRects + drawableBlock.sourceProtectedRects
        if !drawableBlock.sourceTrailingAttachmentRects.isEmpty,
           !drawableBlock.sourceTextRects.isEmpty {
            let cleanupRects = continuousSelectiveCleanupRects(
                textRects: drawableBlock.sourceTextRects,
                attachmentRects: drawableBlock.sourceTrailingAttachmentRects,
                bounds: bounds
            )
            if !cleanupRects.isEmpty {
                return cleanupRects
            }
        }

        if hasReliableTextRects(drawableBlock) {
            var preciseEraseRects: [CGRect] = []
            for sourceTextRect in drawableBlock.sourceTextRects {
                let horizontalPadding = max(1, min(sourceTextRect.height * 0.08, 4))
                let verticalPadding = max(1, min(sourceTextRect.height * 0.12, 5))
                let eraseRect = sourceTextRect
                    .insetBy(dx: -horizontalPadding, dy: -verticalPadding)
                    .intersection(bounds)
                    .integral
                let segments = eraseRectsExcludingCode(
                    eraseRect,
                    codeRects: preservedRects,
                    bounds: bounds
                )
                preciseEraseRects.append(contentsOf: segments)
            }
            return preciseEraseRects.filter { $0.width > 1 && $0.height > 1 }
        }

        if !drawableBlock.sourceLineRects.isEmpty {
            var eraseRects: [CGRect] = []
            for sourceLineRect in drawableBlock.sourceLineRects {
                let horizontalPadding = max(2, min(sourceLineRect.height * 0.12, 6))
                let verticalPadding = max(2, min(sourceLineRect.height * 0.16, 8))
                let eraseRect = sourceLineRect
                    .insetBy(dx: -horizontalPadding, dy: -verticalPadding)
                    .intersection(bounds)
                    .integral
                eraseRects.append(contentsOf: eraseRectsExcludingCode(
                    eraseRect,
                    codeRects: preservedRects,
                    bounds: bounds
                ))
            }
            return eraseRects.filter { $0.width > 1 && $0.height > 1 }
        }

        if !drawableBlock.sourceTextRects.isEmpty {
            var eraseRects: [CGRect] = []
            for sourceTextRect in drawableBlock.sourceTextRects {
                let horizontalPadding = max(2, min(sourceTextRect.height * 0.12, 6))
                let verticalPadding = max(2, min(sourceTextRect.height * 0.16, 8))
                let eraseRect = sourceTextRect
                    .insetBy(dx: -horizontalPadding, dy: -verticalPadding)
                    .intersection(bounds)
                    .integral
                eraseRects.append(contentsOf: eraseRectsExcludingCode(
                    eraseRect,
                    codeRects: preservedRects,
                    bounds: bounds
                ))
            }
            return eraseRects.filter { $0.width > 1 && $0.height > 1 }
        }

        let sourceRect = drawableBlock.sourceRect.intersection(bounds)
        guard sourceRect.width > 1, sourceRect.height > 1 else {
            return []
        }

        let baseSize = baseFontSize(
            drawableBlock.block.fontSize,
            imageHeight: imageHeight,
            rect: sourceRect
        )
        let estimatedLineHeight = max(baseSize * 1.28, 2)
        let estimatedLineCount = max(
            1,
            min(10, Int((sourceRect.height / max(estimatedLineHeight * 0.92, 1)).rounded()))
        )
        let horizontalPadding = max(1, min(sourceRect.height * 0.08, 4))
        let verticalPadding = max(1, min(sourceRect.height * 0.06, 3))

        guard estimatedLineCount > 1 else {
            let eraseRect = sourceRect
                    .insetBy(dx: -horizontalPadding, dy: -verticalPadding)
                    .intersection(bounds)
                    .integral
            return eraseRectsExcludingCode(
                eraseRect,
                codeRects: preservedRects,
                bounds: bounds
            )
        }

        let step = sourceRect.height / CGFloat(estimatedLineCount)
        let patchHeight = min(step * 0.84, estimatedLineHeight * 1.10)

        var eraseRects: [CGRect] = []
        for index in 0..<estimatedLineCount {
            let y = sourceRect.maxY
                - CGFloat(index + 1) * step
                + max(0, (step - patchHeight) / 2)
            let eraseRect = CGRect(
                x: sourceRect.minX,
                y: y,
                width: sourceRect.width,
                height: patchHeight
            )
            .insetBy(dx: -horizontalPadding, dy: -verticalPadding)
            .intersection(bounds)
            .integral

            eraseRects.append(contentsOf: eraseRectsExcludingCode(
                eraseRect,
                codeRects: preservedRects,
                bounds: bounds
            ))
        }

        return eraseRects.filter { $0.width > 1 && $0.height > 1 }
    }

    private static func continuousSelectiveCleanupRects(
        textRects: [CGRect],
        attachmentRects: [CGRect],
        bounds: CGRect
    ) -> [CGRect] {
        attachmentRects.compactMap { attachmentRect in
            let matchingTextRects = textRects.filter { textRect in
                verticalOverlapRatio(textRect, attachmentRect) > 0.24
            }
            guard let leadingTextRect = matchingTextRects.min(by: { lhs, rhs in
                lhs.minX < rhs.minX
            }) else {
                return nil
            }

            let textLineRect = matchingTextRects.reduce(leadingTextRect) { partial, rect in
                partial.union(rect)
            }
            let union = textLineRect.union(attachmentRect)
            let horizontalPadding = max(2, min(union.height * 0.14, 7))
            let verticalPadding = max(1, min(union.height * 0.14, 6))
            var cleanupRect = union
                .insetBy(dx: -horizontalPadding, dy: -verticalPadding)
                .intersection(bounds)
                .integral
            cleanupRect.size.width = min(
                bounds.maxX - cleanupRect.minX,
                cleanupRect.width + max(2, attachmentRect.height * 0.10)
            )
            return cleanupRect.width > 1 && cleanupRect.height > 1
                ? cleanupRect
                : nil
        }
    }

    private static func hasReliableTextRects(_ drawableBlock: DrawableBlock) -> Bool {
        guard !drawableBlock.sourceTextRects.isEmpty else {
            return false
        }
        guard !drawableBlock.sourceLineRects.isEmpty else {
            return true
        }

        return drawableBlock.sourceLineRects.allSatisfy { lineRect in
            horizontalCoverage(
                of: drawableBlock.sourceTextRects.filter {
                    verticalOverlapRatio($0, lineRect) > 0.32
                },
                within: lineRect
            ) >= 0.42
        }
    }

    private static func horizontalCoverage(of rects: [CGRect], within lineRect: CGRect) -> CGFloat {
        let intervals = rects
            .compactMap { rect -> ClosedRange<CGFloat>? in
                let intersection = rect.intersection(lineRect)
                guard !intersection.isNull, intersection.width > 0 else {
                    return nil
                }
                return intersection.minX...intersection.maxX
            }
            .sorted { $0.lowerBound < $1.lowerBound }
        guard let first = intervals.first, lineRect.width > 0 else {
            return 0
        }

        var coveredWidth: CGFloat = 0
        var currentStart = first.lowerBound
        var currentEnd = first.upperBound
        for interval in intervals.dropFirst() {
            if interval.lowerBound <= currentEnd {
                currentEnd = max(currentEnd, interval.upperBound)
            } else {
                coveredWidth += currentEnd - currentStart
                currentStart = interval.lowerBound
                currentEnd = interval.upperBound
            }
        }
        coveredWidth += currentEnd - currentStart

        return min(max(coveredWidth / lineRect.width, 0), 1)
    }

    private static func eraseRectsExcludingCode(
        _ rect: CGRect,
        codeRects: [CGRect],
        bounds: CGRect
    ) -> [CGRect] {
        let blockers = codeRects
            .map { codeRect in
                let padding = max(1, min(codeRect.height * 0.10, 3))
                return codeRect.insetBy(dx: -padding, dy: -padding)
            }
            .filter { $0.intersects(rect) }
            .sorted { $0.minX < $1.minX }

        guard !blockers.isEmpty else {
            return [rect]
        }

        var segments: [CGRect] = []
        var cursorX = rect.minX

        for blocker in blockers {
            let clippedBlocker = blocker.intersection(rect)
            if clippedBlocker.minX > cursorX + 1 {
                segments.append(CGRect(
                    x: cursorX,
                    y: rect.minY,
                    width: clippedBlocker.minX - cursorX,
                    height: rect.height
                ))
            }
            cursorX = max(cursorX, clippedBlocker.maxX)
        }

        if cursorX < rect.maxX - 1 {
            segments.append(CGRect(
                x: cursorX,
                y: rect.minY,
                width: rect.maxX - cursorX,
                height: rect.height
            ))
        }

        return segments
            .map { $0.intersection(bounds).integral }
            .filter { $0.width > 1 && $0.height > 1 }
    }

    private static func drawTrailingAttachments(
        _ drawableBlock: DrawableBlock,
        imageHeight: CGFloat,
        bounds: CGRect,
        bitmap: NSBitmapImageRep
    ) {
        guard
            !drawableBlock.sourceTrailingAttachmentRects.isEmpty,
            let renderedTextRect = renderedInlineTextRect(
                for: drawableBlock,
                imageHeight: imageHeight
            ),
            let cgImage = bitmap.cgImage
        else {
            return
        }

        let sourceImage = NSImage(
            cgImage: cgImage,
            size: NSSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        )
        var cursorX = renderedTextRect.maxX
        for sourceRect in drawableBlock.sourceTrailingAttachmentRects {
            let gap = max(3, min(7, renderedTextRect.height * 0.22))
            let targetX = min(bounds.maxX - sourceRect.width, cursorX + gap)
            let targetY = min(
                bounds.maxY - sourceRect.height,
                max(bounds.minY, renderedTextRect.midY - sourceRect.height / 2)
            ).rounded()
            let targetRect = CGRect(
                x: max(bounds.minX, targetX).rounded(),
                y: targetY,
                width: sourceRect.width,
                height: sourceRect.height
            ).integral
            sourceImage.draw(
                in: targetRect,
                from: sourceRect,
                operation: .copy,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
            cursorX = targetRect.maxX
        }
    }

    private static func renderedInlineTextRect(
        for drawableBlock: DrawableBlock,
        imageHeight: CGFloat
    ) -> CGRect? {
        let block = drawableBlock.block
        guard block.translationStrategy == .selective else {
            return nil
        }
        let rect = drawableBlock.layoutRect
        let sourceHeight = drawableBlock.sourceRect.height
        let horizontalInset = min(max(1, sourceHeight * 0.05), max(1, rect.width * 0.035))
        let textRect = rect.insetBy(dx: horizontalInset, dy: 0)
        guard textRect.width > 1, textRect.height > 1 else {
            return nil
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = textAlignment(from: block.alignment)
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = lineSpacing(for: block, sourceHeight: sourceHeight)
        let layoutText = layoutMarkdown(for: block)
        let baseSize = typographicBaseFontSize(
            for: block,
            imageHeight: imageHeight,
            rect: CGRect(x: textRect.minX, y: textRect.minY, width: textRect.width, height: sourceHeight)
        )
        configureParagraphStyle(paragraph, for: block, fontSize: baseSize)
        let fontSize = fittingFontSize(
            for: layoutText,
            baseFontSize: baseSize,
            rect: textRect,
            weight: effectiveFontWeight(for: block),
            paragraph: paragraph,
            minimumFontSize: max(6, baseSize * 0.50)
        )
        configureParagraphStyle(paragraph, for: block, fontSize: fontSize)
        let rendered = attributedMarkdownLayout(
            layoutText,
            fontSize: fontSize,
            weight: effectiveFontWeight(for: block),
            foregroundColor: .labelColor,
            paragraph: paragraph
        )
        let measured = measuredAttributedTextSize(rendered.attributed, constrainedTo: textRect.width)
        let drawHeight = min(max(measured.height, fontSize), textRect.height)
        return CGRect(
            x: textRect.minX,
            y: min(max(textRect.minY, textRect.maxY - measured.height), textRect.maxY - drawHeight),
            width: min(measured.width, textRect.width),
            height: drawHeight
        )
    }

    private static func drawText(
        _ block: ImageTranslationBlock,
        in rect: CGRect,
        lineRects: [CGRect],
        codeRects: [CGRect],
        imageHeight: CGFloat,
        foregroundColor: NSColor,
        backgroundColor: NSColor,
        inlineCodeBackgroundColor: NSColor,
        alignment: NSTextAlignment,
        sourceHeight: CGFloat,
        preserveSourceCode: Bool
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = lineSpacing(for: block, sourceHeight: sourceHeight)
        let horizontalInset = min(max(1, sourceHeight * 0.05), max(1, rect.width * 0.035))
        let textRect = rect.insetBy(dx: horizontalInset, dy: 0)
        let layoutText = layoutMarkdown(for: block)

        if drawExplicitMarkdownLines(
            block,
            lineRects: lineRects,
            codeRects: codeRects,
            imageHeight: imageHeight,
            foregroundColor: foregroundColor,
            backgroundColor: backgroundColor,
            inlineCodeBackgroundColor: inlineCodeBackgroundColor,
            alignment: alignment,
            preserveSourceCode: preserveSourceCode
        ) {
            return
        }

        let baseFontSize = typographicBaseFontSize(
            for: block,
            imageHeight: imageHeight,
            rect: CGRect(x: textRect.minX, y: textRect.minY, width: textRect.width, height: sourceHeight)
        )
        configureParagraphStyle(paragraph, for: block, fontSize: baseFontSize)
        let weight = effectiveFontWeight(for: block)
        let fontSize = fittingFontSize(
            for: layoutText,
            baseFontSize: baseFontSize,
            rect: textRect,
            weight: weight,
            paragraph: paragraph,
            minimumFontSize: max(6, baseFontSize * 0.50)
        )
        configureParagraphStyle(paragraph, for: block, fontSize: fontSize)
        let renderedText = attributedMarkdownLayout(
            layoutText,
            fontSize: fontSize,
            weight: weight,
            foregroundColor: foregroundColor,
            paragraph: paragraph,
            preserveCodeSpans: preserveSourceCode
        )
        let measured = measuredAttributedTextSize(renderedText.attributed, constrainedTo: textRect.width)
        let drawHeight = min(max(measured.height, fontSize), textRect.height)
        let topAlignedY = min(
            max(textRect.minY, textRect.maxY - measured.height),
            textRect.maxY - drawHeight
        )
        let verticallyCenteredY = min(
            max(textRect.minY, textRect.midY - drawHeight / 2),
            textRect.maxY - drawHeight
        )
        let shouldCenterShortTranslation = lineRects.count > 1
            && !layoutText.contains("\n")
            && drawHeight <= textRect.height * 0.68
        let drawRect = CGRect(
            x: textRect.minX,
            y: shouldCenterShortTranslation ? verticallyCenteredY : topAlignedY,
            width: textRect.width,
            height: drawHeight
        )

        if !preserveSourceCode {
            drawCodeChipBackgrounds(
                for: renderedText,
                in: drawRect,
                color: inlineCodeBackgroundColor,
                fontSize: fontSize
            )
        }

        renderedText.attributed.draw(
            with: drawRect,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
    }

    @discardableResult
    private static func drawExplicitMarkdownLines(
        _ block: ImageTranslationBlock,
        lineRects: [CGRect],
        codeRects: [CGRect],
        imageHeight: CGFloat,
        foregroundColor: NSColor,
        backgroundColor: NSColor,
        inlineCodeBackgroundColor: NSColor,
        alignment: NSTextAlignment,
        preserveSourceCode: Bool
    ) -> Bool {
        let layoutText = layoutMarkdown(for: block)
        let explicitLines = layoutText.components(separatedBy: .newlines)
        let lines: [String]
        if explicitLines.count > 1 {
            guard explicitLines.count == lineRects.count else {
                return false
            }
            lines = explicitLines
        } else if let wrappedLines = automaticMarkdownLines(
                    for: layoutText,
                    lineRects: lineRects,
                    codeRects: codeRects,
                    imageHeight: imageHeight,
                    block: block,
                    weight: effectiveFontWeight(for: block),
                    alignment: alignment
                  ) {
            lines = wrappedLines
        } else {
            return false
        }

        for (line, rawLineRect) in zip(lines, lineRects) {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                continue
            }

            let lineRect = rawLineRect.integral
            let horizontalInset = min(max(1, lineRect.height * 0.08), max(1, lineRect.width * 0.035))
            let textRect = lineRect.insetBy(dx: horizontalInset, dy: 0)
            guard textRect.width > 1, textRect.height > 1 else {
                continue
            }

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = alignment
            paragraph.lineBreakMode = .byTruncatingTail
            paragraph.lineSpacing = 0

            let baseFontSize = typographicBaseFontSize(
                for: block,
                imageHeight: imageHeight,
                rect: textRect
            )
            configureParagraphStyle(paragraph, for: block, fontSize: baseFontSize)

            let lineCodeRects = codeRects
                .filter { verticalOverlapRatio($0, lineRect) > 0.22 }
                .sorted { $0.minX < $1.minX }
            if !lineCodeRects.isEmpty,
               drawMarkdownLineAroundSourceCode(
                text,
                in: textRect,
                codeRects: lineCodeRects,
                imageHeight: imageHeight,
                foregroundColor: foregroundColor,
                weight: effectiveFontWeight(for: block),
                paragraph: paragraph,
                block: block
               ) {
                continue
            }

            let weight = effectiveFontWeight(for: block)
            let fontSize = fittingFontSize(
                for: text,
                baseFontSize: baseFontSize,
                rect: textRect,
                weight: weight,
                paragraph: paragraph,
                minimumFontSize: max(6, baseFontSize * 0.56)
            )
            configureParagraphStyle(paragraph, for: block, fontSize: fontSize)
            let renderedText = attributedMarkdownLayout(
                text,
                fontSize: fontSize,
                weight: weight,
                foregroundColor: foregroundColor,
                paragraph: paragraph,
                preserveCodeSpans: preserveSourceCode
            )
            let measured = measuredAttributedTextSize(renderedText.attributed, constrainedTo: textRect.width)
            let drawHeight = min(max(measured.height, fontSize), textRect.height)
            let drawRect = CGRect(
                x: textRect.minX,
                y: min(max(textRect.minY, textRect.midY - drawHeight / 2), textRect.maxY - drawHeight),
                width: textRect.width,
                height: drawHeight
            )

            if !preserveSourceCode {
                drawCodeChipBackgrounds(
                    for: renderedText,
                    in: drawRect,
                    color: inlineCodeBackgroundColor,
                    fontSize: fontSize
                )
            }

            renderedText.attributed.draw(
                with: drawRect,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )
        }

        return true
    }

    private struct MarkdownLineToken {
        let markdown: String
        let plainText: String
        let isCode: Bool
    }

    private static func automaticMarkdownLines(
        for markdown: String,
        lineRects: [CGRect],
        codeRects: [CGRect],
        imageHeight: CGFloat,
        block: ImageTranslationBlock,
        weight: NSFont.Weight,
        alignment: NSTextAlignment
    ) -> [String]? {
        guard lineRects.count > 1, !markdown.contains("\n") else {
            return nil
        }

        return ImageTranslationMarkdownLineLayout.lines(
            for: markdown,
            lineRects: lineRects,
            codeRects: codeRects,
            availableWidth: { lineRect in
                let horizontalInset = min(max(1, lineRect.height * 0.08), max(1, lineRect.width * 0.035))
                return max(1, lineRect.width - horizontalInset * 2)
            },
            measuredWidth: { candidateText, lineRect in
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = alignment
                paragraph.lineBreakMode = .byTruncatingTail
                paragraph.lineSpacing = 0
                let fontSize = typographicBaseFontSize(
                    for: block,
                    imageHeight: imageHeight,
                    rect: lineRect
                )
                configureParagraphStyle(paragraph, for: block, fontSize: fontSize)
                return measuredMarkdownLineWidth(
                    candidateText,
                    fontSize: fontSize,
                    weight: weight,
                    paragraph: paragraph
                )
            }
        )
    }

    private static func codeLineIndices(
        for codeRects: [CGRect],
        lineRects: [CGRect],
        expectedCodeCount: Int
    ) -> [Int]? {
        guard !codeRects.isEmpty else {
            return []
        }
        guard expectedCodeCount == codeRects.count else {
            return nil
        }

        let indexedCodeRects = codeRects.compactMap { codeRect -> (rect: CGRect, lineIndex: Int)? in
            guard let lineIndex = bestLineIndex(for: codeRect, in: lineRects) else {
                return nil
            }
            return (codeRect, lineIndex)
        }
        guard indexedCodeRects.count == codeRects.count else {
            return nil
        }

        return indexedCodeRects
            .sorted { lhs, rhs in
                if lhs.lineIndex != rhs.lineIndex {
                    return lhs.lineIndex < rhs.lineIndex
                }
                return lhs.rect.minX < rhs.rect.minX
            }
            .map(\.lineIndex)
    }

    private static func bestLineIndex(for rect: CGRect, in lineRects: [CGRect]) -> Int? {
        lineRects.indices
            .map { index in
                (
                    index: index,
                    overlap: verticalOverlapRatio(rect, lineRects[index])
                )
            }
            .filter { $0.overlap > 0.22 }
            .max { lhs, rhs in lhs.overlap < rhs.overlap }?
            .index
    }

    private static func markdownLineTokens(_ markdown: String) -> [MarkdownLineToken] {
        inlineMarkdownSpans(markdown).flatMap { span -> [MarkdownLineToken] in
            if span.isCode {
                return [
                    MarkdownLineToken(
                        markdown: "`\(span.text)`",
                        plainText: span.text,
                        isCode: true
                    )
                ]
            }

            return naturalTextTokens(span.text).map { token in
                MarkdownLineToken(markdown: token, plainText: token, isCode: false)
            }
        }
    }

    private static func naturalTextTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""

        func flushCurrent() {
            if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }

        for character in text {
            if character.isWhitespace {
                flushCurrent()
            } else if isCJKCharacter(character) {
                flushCurrent()
                tokens.append(String(character))
            } else if isCJKPunctuation(character) {
                if current.isEmpty {
                    tokens.append(String(character))
                } else {
                    current.append(character)
                    flushCurrent()
                }
            } else {
                current.append(character)
            }
        }
        flushCurrent()

        return tokens
    }

    private static func markdownLine(from tokens: [MarkdownLineToken]) -> String {
        var result = ""
        var previous: MarkdownLineToken?

        for token in tokens {
            if result.isEmpty {
                result = token.markdown
            } else {
                if let previous {
                    if isListMarker(previous.plainText) {
                        result += "\t"
                    } else if shouldInsertSpace(between: previous.plainText, and: token.plainText) {
                        result += " "
                    }
                }
                result += token.markdown
            }
            previous = token
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isListMarker(_ text: String) -> Bool {
        ["•", "·", "▪", "◦", "-", "*"].contains(text)
    }

    private static func shouldInsertSpace(between lhs: String, and rhs: String) -> Bool {
        guard let lhsLast = lhs.last, let rhsFirst = rhs.first else {
            return false
        }

        if isClosingPunctuation(rhsFirst) || isOpeningPunctuation(lhsLast) {
            return false
        }

        if isCJKCharacter(lhsLast), isCJKCharacter(rhsFirst) {
            return false
        }

        return isASCIIAlphanumeric(lhsLast)
            || isASCIIAlphanumeric(rhsFirst)
            || lhsLast == "•"
            || lhsLast == "-"
    }

    private static func measuredMarkdownLineWidth(
        _ markdown: String,
        fontSize: CGFloat,
        weight: NSFont.Weight,
        paragraph: NSParagraphStyle
    ) -> CGFloat {
        let attributed = attributedMarkdown(
            markdown,
            fontSize: fontSize,
            weight: weight,
            foregroundColor: .labelColor,
            paragraph: paragraph,
            codeBackgroundColor: .clear
        )
        return measuredAttributedTextSize(attributed, constrainedTo: 10_000).width
    }

    private static func drawMarkdownLineAroundSourceCode(
        _ markdown: String,
        in lineRect: CGRect,
        codeRects: [CGRect],
        imageHeight: CGFloat,
        foregroundColor: NSColor,
        weight: NSFont.Weight,
        paragraph: NSMutableParagraphStyle,
        block: ImageTranslationBlock
    ) -> Bool {
        let spans = inlineMarkdownSpans(markdown)
        let codeSpans = spans.filter(\.isCode)
        guard !codeSpans.isEmpty, codeSpans.count == codeRects.count else {
            return false
        }

        var codeIndex = 0
        var cursorX = lineRect.minX
        for span in spans {
            if span.isCode {
                cursorX = max(cursorX, codeRects[codeIndex].maxX + max(2, lineRect.height * 0.16))
                codeIndex += 1
                continue
            }

            let text = trimmedSegmentText(span.text)
            guard !text.isEmpty else {
                continue
            }

            let nextCodeMinX = codeIndex < codeRects.count ? codeRects[codeIndex].minX : lineRect.maxX
            let segmentRect = CGRect(
                x: cursorX,
                y: lineRect.minY,
                width: max(0, nextCodeMinX - cursorX - max(1, lineRect.height * 0.10)),
                height: lineRect.height
            )
            guard segmentRect.width > 1, segmentRect.height > 1 else {
                continue
            }

            let baseFontSize = typographicBaseFontSize(
                for: block,
                imageHeight: imageHeight,
                rect: segmentRect
            )
            configureParagraphStyle(paragraph, for: block, fontSize: baseFontSize)
            let fontSize = fittingFontSize(
                for: text,
                baseFontSize: baseFontSize,
                rect: segmentRect,
                weight: weight,
                paragraph: paragraph,
                minimumFontSize: max(6, baseFontSize * 0.56)
            )
            configureParagraphStyle(paragraph, for: block, fontSize: fontSize)
            let attributed = NSAttributedString(
                string: text,
                attributes: [
                    .font: NSFont.systemFont(ofSize: fontSize, weight: weight),
                    .foregroundColor: foregroundColor,
                    .paragraphStyle: paragraph
                ]
            )
            let measured = measuredAttributedTextSize(attributed, constrainedTo: segmentRect.width)
            let drawHeight = min(max(measured.height, fontSize), segmentRect.height)
            let drawRect = CGRect(
                x: segmentRect.minX,
                y: min(max(segmentRect.minY, segmentRect.midY - drawHeight / 2), segmentRect.maxY - drawHeight),
                width: segmentRect.width,
                height: drawHeight
            )
            attributed.draw(
                with: drawRect,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )
        }

        return true
    }

    private static func trimmedSegmentText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isCJKCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(Int(scalar.value))
                || (0x3400...0x4DBF).contains(Int(scalar.value))
                || (0x3040...0x30FF).contains(Int(scalar.value))
                || (0xAC00...0xD7AF).contains(Int(scalar.value))
        }
    }

    private static func isCJKPunctuation(_ character: Character) -> Bool {
        "，。！？；：、（）《》“”‘’".contains(character)
    }

    private static func isOpeningPunctuation(_ character: Character) -> Bool {
        "([{（《“‘".contains(character)
    }

    private static func isClosingPunctuation(_ character: Character) -> Bool {
        ".,;:!?)]}，。！？；：、）》”’".contains(character)
    }

    private static func isASCIIAlphanumeric(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII
        }
    }

    private static func blockRect(_ block: ImageTranslationBlock, imageSize: CGSize) -> CGRect {
        let width = CGFloat(block.width) * imageSize.width
        let height = CGFloat(block.height) * imageSize.height
        let x = CGFloat(block.x) * imageSize.width
        let y = imageSize.height - (CGFloat(block.y) * imageSize.height) - height

        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func baseFontSize(_ requested: Double?, imageHeight: CGFloat, rect: CGRect) -> CGFloat {
        if let requested, requested > 0 {
            if requested <= 1 {
                return min(CGFloat(requested) * imageHeight, rect.height * 0.92)
            }
            return min(CGFloat(requested), rect.height * 0.92)
        }

        return min(max(rect.height * 0.68, 8), 48)
    }

    private static func typographicBaseFontSize(
        for block: ImageTranslationBlock,
        imageHeight: CGFloat,
        rect: CGRect
    ) -> CGFloat {
        let inferred = baseFontSize(
            block.fontSize,
            imageHeight: imageHeight,
            rect: rect
        )

        switch normalizedKind(block.kind) {
        case "title":
            return min(rect.height * 0.92, inferred * 1.05)
        case "heading":
            return min(rect.height * 0.92, inferred * 1.10)
        case "caption":
            return min(rect.height * 0.88, inferred * 0.96)
        default:
            return min(rect.height * 0.90, inferred)
        }
    }

    private static func layoutMarkdown(for block: ImageTranslationBlock) -> String {
        let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedKind(block.kind) == "list_item" else {
            return text
        }

        let content: String
        if text.hasPrefix("•") || text.hasPrefix("·") || text.hasPrefix("▪") || text.hasPrefix("◦") {
            content = String(text.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if text.hasPrefix("- ") || text.hasPrefix("* ") {
            content = String(text.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            content = text
        }

        return content.isEmpty ? "•" : "•\t\(content)"
    }

    private static func configureParagraphStyle(
        _ paragraph: NSMutableParagraphStyle,
        for block: ImageTranslationBlock,
        fontSize: CGFloat
    ) {
        guard normalizedKind(block.kind) == "list_item" else {
            paragraph.firstLineHeadIndent = 0
            paragraph.headIndent = 0
            paragraph.tabStops = []
            paragraph.paragraphSpacing = 0
            return
        }

        let contentIndent = max(8, fontSize * 1.05)
        paragraph.firstLineHeadIndent = 0
        paragraph.headIndent = contentIndent
        paragraph.defaultTabInterval = contentIndent
        paragraph.tabStops = [
            NSTextTab(
                textAlignment: .left,
                location: contentIndent,
                options: [:]
            )
        ]
        paragraph.paragraphSpacing = max(1, fontSize * 0.16)
    }

    private static func effectiveFontWeight(for block: ImageTranslationBlock) -> NSFont.Weight {
        let explicitWeight = fontWeight(from: block.weight)
        if block.weight != nil {
            return explicitWeight
        }

        switch normalizedKind(block.kind) {
        case "title", "heading":
            return .semibold
        default:
            return explicitWeight
        }
    }

    private static func lineSpacing(for block: ImageTranslationBlock, sourceHeight: CGFloat) -> CGFloat {
        switch normalizedKind(block.kind) {
        case "title", "heading":
            return max(0, sourceHeight * 0.02)
        case "caption", "code":
            return 0
        default:
            return max(0, sourceHeight * 0.04)
        }
    }

    private static func normalizedKind(_ kind: String?) -> String {
        kind?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_") ?? "paragraph"
    }

    private static func fittingFontSize(
        for text: String,
        baseFontSize: CGFloat,
        rect: CGRect,
        weight: NSFont.Weight,
        paragraph: NSParagraphStyle,
        minimumFontSize: CGFloat = 7
    ) -> CGFloat {
        var fontSize = max(minimumFontSize, min(baseFontSize, rect.height * 0.92))

        while fontSize > minimumFontSize {
            let attributed = attributedMarkdown(
                text,
                fontSize: fontSize,
                weight: weight,
                foregroundColor: .labelColor,
                paragraph: paragraph,
                codeBackgroundColor: .clear
            )
            let measured = measuredAttributedTextSize(attributed, constrainedTo: rect.width)

            if measured.height <= rect.height * 0.98, measured.width <= rect.width * 1.02 {
                return fontSize
            }

            fontSize -= 0.5
        }

        return max(minimumFontSize, fontSize)
    }

    private static func textAttributes(
        fontSize: CGFloat,
        weight: NSFont.Weight,
        foregroundColor: NSColor,
        paragraph: NSParagraphStyle
    ) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: fontSize, weight: weight),
            .foregroundColor: foregroundColor,
            .paragraphStyle: paragraph
        ]
    }

    private static func attributedMarkdown(
        _ markdown: String,
        fontSize: CGFloat,
        weight: NSFont.Weight,
        foregroundColor: NSColor,
        paragraph: NSParagraphStyle,
        codeBackgroundColor: NSColor
    ) -> NSAttributedString {
        attributedMarkdownLayout(
            markdown,
            fontSize: fontSize,
            weight: weight,
            foregroundColor: foregroundColor,
            paragraph: paragraph
        ).attributed
    }

    private struct AttributedMarkdownLayout {
        let attributed: NSAttributedString
        let codeRanges: [NSRange]
    }

    private static func attributedMarkdownLayout(
        _ markdown: String,
        fontSize: CGFloat,
        weight: NSFont.Weight,
        foregroundColor: NSColor,
        paragraph: NSParagraphStyle,
        preserveCodeSpans: Bool = false
    ) -> AttributedMarkdownLayout {
        let attributed = NSMutableAttributedString(string: "")
        let spans = inlineMarkdownSpans(markdown)
        var codeRanges: [NSRange] = []
        var location = 0

        for span in spans where !span.text.isEmpty {
            var attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: foregroundColor,
                .paragraphStyle: paragraph
            ]

            if span.isCode {
                let codeFontSize = max(fontSize * 0.85, fontSize - 2)
                attributes[.font] = NSFont.monospacedSystemFont(
                    ofSize: codeFontSize,
                    weight: .regular
                )
                attributes[.baselineOffset] = -max(0.35, fontSize * 0.025)
                if preserveCodeSpans {
                    attributes[.foregroundColor] = NSColor.clear
                }
            } else {
                attributes[.font] = NSFont.systemFont(ofSize: fontSize, weight: weight)
            }

            let range = NSRange(location: location, length: (span.text as NSString).length)
            if span.isCode {
                codeRanges.append(range)
            }
            attributed.append(NSAttributedString(string: span.text, attributes: attributes))
            location += range.length
        }

        return AttributedMarkdownLayout(attributed: attributed, codeRanges: codeRanges)
    }

    private static func drawCodeChipBackgrounds(
        for layout: AttributedMarkdownLayout,
        in rect: CGRect,
        color: NSColor,
        fontSize: CGFloat
    ) {
        guard !layout.codeRanges.isEmpty, layout.attributed.length > 0 else {
            return
        }

        let textStorage = NSTextStorage(attributedString: layout.attributed)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: rect.size)
        textContainer.lineFragmentPadding = 0
        textContainer.maximumNumberOfLines = 0
        textContainer.lineBreakMode = .byWordWrapping
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)

        color.setFill()
        for characterRange in layout.codeRanges {
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: characterRange,
                actualCharacterRange: nil
            )
            layoutManager.enumerateEnclosingRects(
                forGlyphRange: glyphRange,
                withinSelectedGlyphRange: glyphRange,
                in: textContainer
            ) { enclosingRect, _ in
                let horizontalPadding = max(2, fontSize * 0.18)
                let verticalPadding = max(1, fontSize * 0.07)
                let chipRect = CGRect(
                    x: rect.minX + enclosingRect.minX,
                    y: rect.maxY - enclosingRect.maxY,
                    width: enclosingRect.width,
                    height: enclosingRect.height
                )
                    .insetBy(dx: -horizontalPadding, dy: -verticalPadding)
                    .integral
                NSBezierPath(
                    roundedRect: chipRect,
                    xRadius: max(2, fontSize * 0.24),
                    yRadius: max(2, fontSize * 0.24)
                ).fill()
            }
        }
    }

    private struct InlineMarkdownSpan {
        let text: String
        let isCode: Bool
    }

    private static func inlineMarkdownSpans(_ markdown: String) -> [InlineMarkdownSpan] {
        var spans: [InlineMarkdownSpan] = []
        var current = ""
        var isCode = false

        for character in markdown {
            if character == "`" {
                if !current.isEmpty {
                    spans.append(InlineMarkdownSpan(text: cleanedMarkdownText(current, isCode: isCode), isCode: isCode))
                    current = ""
                }
                isCode.toggle()
            } else {
                current.append(character)
            }
        }

        if !current.isEmpty {
            spans.append(InlineMarkdownSpan(text: cleanedMarkdownText(current, isCode: isCode), isCode: isCode))
        }

        return spans
    }

    private static func cleanedMarkdownText(_ text: String, isCode: Bool) -> String {
        guard !isCode else {
            return text
        }

        return text
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
    }

    private static func measuredAttributedTextSize(
        _ attributed: NSAttributedString,
        constrainedTo width: CGFloat
    ) -> CGSize {
        let rect = attributed.boundingRect(
            with: CGSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return CGSize(width: ceil(rect.width), height: ceil(rect.height))
    }

    private static func codeChipColor(on backgroundColor: NSColor) -> NSColor {
        guard let color = backgroundColor.usingColorSpace(.sRGB) else {
            return NSColor.controlBackgroundColor.withAlphaComponent(0.90)
        }

        if luminance(color) < 0.5 {
            return blendedColor(from: color, to: .white, progress: 0.18).withAlphaComponent(0.94)
        }

        return blendedColor(from: color, to: .black, progress: 0.11).withAlphaComponent(0.90)
    }

    private static func harmonizedBackgroundColor(
        _ localBackgroundColor: NSColor,
        canvasBackgroundColor: NSColor
    ) -> NSColor {
        guard
            let local = localBackgroundColor.usingColorSpace(.sRGB),
            let canvas = canvasBackgroundColor.usingColorSpace(.sRGB)
        else {
            return localBackgroundColor
        }

        let channelDistance = max(
            abs(local.redComponent - canvas.redComponent),
            abs(local.greenComponent - canvas.greenComponent),
            abs(local.blueComponent - canvas.blueComponent)
        )
        let localLuminance = luminance(local)
        let canvasLuminance = luminance(canvas)
        let tolerance: CGFloat
        if localLuminance > 0.84, canvasLuminance > 0.84 {
            tolerance = 0.022
        } else if localLuminance < 0.24, canvasLuminance < 0.24 {
            tolerance = 0.028
        } else {
            tolerance = 0.018
        }

        guard channelDistance <= tolerance else {
            return localBackgroundColor
        }
        return canvas.withAlphaComponent(1)
    }

    private static func dominantInteriorBackgroundColor(
        in rects: [CGRect],
        bitmap: NSBitmapImageRep,
        bounds: CGRect
    ) -> NSColor? {
        var counts: [Int: Int] = [:]
        var redSums: [Int: CGFloat] = [:]
        var greenSums: [Int: CGFloat] = [:]
        var blueSums: [Int: CGFloat] = [:]

        for rect in rects where rect.width > 1 && rect.height > 1 {
            let columns = max(3, min(36, Int(ceil(rect.width / 2))))
            let rows = max(3, min(18, Int(ceil(rect.height / 2))))
            for row in 0..<rows {
                let y = rect.minY + (CGFloat(row) + 0.5) / CGFloat(rows) * rect.height
                for column in 0..<columns {
                    let x = rect.minX + (CGFloat(column) + 0.5) / CGFloat(columns) * rect.width
                    guard let color = sampledColor(
                        appKitX: x,
                        appKitY: y,
                        bitmap: bitmap,
                        bounds: bounds
                    )?.usingColorSpace(.sRGB) else {
                        continue
                    }

                    let redBin = Int((color.redComponent * 255).rounded()) / 16
                    let greenBin = Int((color.greenComponent * 255).rounded()) / 16
                    let blueBin = Int((color.blueComponent * 255).rounded()) / 16
                    let key = (redBin << 16) | (greenBin << 8) | blueBin
                    counts[key, default: 0] += 1
                    redSums[key, default: 0] += color.redComponent
                    greenSums[key, default: 0] += color.greenComponent
                    blueSums[key, default: 0] += color.blueComponent
                }
            }
        }

        guard
            let dominant = counts.max(by: { $0.value < $1.value }),
            dominant.value >= 2
        else {
            return nil
        }

        let count = CGFloat(dominant.value)
        return NSColor(
            srgbRed: redSums[dominant.key, default: 0] / count,
            green: greenSums[dominant.key, default: 0] / count,
            blue: blueSums[dominant.key, default: 0] / count,
            alpha: 1
        )
    }

    private static func sampledForegroundColor(
        in rects: [CGRect],
        bitmap: NSBitmapImageRep,
        backgroundColor: NSColor,
        bounds: CGRect
    ) -> NSColor? {
        var candidates: [(color: NSColor, distance: CGFloat)] = []

        for rect in rects where rect.width > 1 && rect.height > 1 {
            let columns = max(3, min(28, Int(ceil(rect.width / 2))))
            let rows = max(3, min(14, Int(ceil(rect.height / 2))))

            for row in 0..<rows {
                let y = rect.minY + (CGFloat(row) + 0.5) / CGFloat(rows) * rect.height
                for column in 0..<columns {
                    let x = rect.minX + (CGFloat(column) + 0.5) / CGFloat(columns) * rect.width
                    guard let sampled = sampledColor(
                        appKitX: x,
                        appKitY: y,
                        bitmap: bitmap,
                        bounds: bounds
                    ) else {
                        continue
                    }

                    let distance = rgbDistance(sampled, backgroundColor)
                    if distance >= 0.10 {
                        candidates.append((sampled, distance))
                    }
                }
            }
        }

        guard !candidates.isEmpty else {
            return nil
        }

        let sorted = candidates.sorted { $0.distance > $1.distance }
        let selectedCount = max(1, Int(ceil(Double(sorted.count) * 0.36)))
        return averageColor(sorted.prefix(selectedCount).map(\.color))
    }

    private static func rgbDistance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        guard
            let lhs = lhs.usingColorSpace(.sRGB),
            let rhs = rhs.usingColorSpace(.sRGB)
        else {
            return 0
        }

        let red = lhs.redComponent - rhs.redComponent
        let green = lhs.greenComponent - rhs.greenComponent
        let blue = lhs.blueComponent - rhs.blueComponent
        return sqrt(red * red + green * green + blue * blue)
    }

    private static func sampledBackgroundColor(in rect: CGRect, bitmap: NSBitmapImageRep) -> NSColor? {
        let bounds = CGRect(
            x: 0,
            y: 0,
            width: bitmap.pixelsWide,
            height: bitmap.pixelsHigh
        )
        let sampleOffset = max(2, min(10, rect.height * 0.20))
        let fractions: [CGFloat] = [0.08, 0.22, 0.38, 0.5, 0.62, 0.78, 0.92]
        var points: [CGPoint] = []

        for fraction in fractions {
            points.append(CGPoint(x: rect.minX + rect.width * fraction, y: rect.minY - sampleOffset))
            points.append(CGPoint(x: rect.minX + rect.width * fraction, y: rect.maxY + sampleOffset))
            points.append(CGPoint(x: rect.minX - sampleOffset, y: rect.minY + rect.height * fraction))
            points.append(CGPoint(x: rect.maxX + sampleOffset, y: rect.minY + rect.height * fraction))
        }

        let colors = points.compactMap { point in
            sampledColor(appKitX: point.x, appKitY: point.y, bitmap: bitmap, bounds: bounds)
        }

        return dominantBackgroundColor(colors) ?? averageColor(colors)
    }

    private static func averageColor(_ colors: [NSColor]) -> NSColor? {
        guard !colors.isEmpty else {
            return nil
        }

        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        var count: CGFloat = 0

        for rawColor in colors {
            guard let color = rawColor.usingColorSpace(.sRGB) else {
                continue
            }

            red += color.redComponent
            green += color.greenComponent
            blue += color.blueComponent
            alpha += color.alphaComponent
            count += 1
        }

        guard count > 0 else {
            return nil
        }

        return NSColor(
            srgbRed: red / count,
            green: green / count,
            blue: blue / count,
            alpha: alpha / count
        )
    }

    private static func dominantBackgroundColor(_ colors: [NSColor]) -> NSColor? {
        let converted = colors.compactMap { color -> NSColor? in
            color.usingColorSpace(.sRGB)
        }
        guard !converted.isEmpty else {
            return nil
        }

        let sorted = converted.sorted { lhs, rhs in
            luminance(lhs) < luminance(rhs)
        }
        let median = luminance(sorted[sorted.count / 2])
        let selected: [NSColor]

        if median < 0.5 {
            let count = max(1, Int(ceil(Double(sorted.count) * 0.68)))
            selected = Array(sorted.prefix(count))
        } else {
            let count = max(1, Int(ceil(Double(sorted.count) * 0.68)))
            selected = Array(sorted.suffix(count))
        }

        return averageColor(selected)
    }

    private static func luminance(_ color: NSColor) -> CGFloat {
        0.2126 * color.redComponent
            + 0.7152 * color.greenComponent
            + 0.0722 * color.blueComponent
    }

    private static func blendedColor(from start: NSColor, to end: NSColor, progress: CGFloat) -> NSColor {
        guard
            let start = start.usingColorSpace(.sRGB),
            let end = end.usingColorSpace(.sRGB)
        else {
            return start
        }

        let clampedProgress = min(max(progress, 0), 1)
        return NSColor(
            srgbRed: start.redComponent + (end.redComponent - start.redComponent) * clampedProgress,
            green: start.greenComponent + (end.greenComponent - start.greenComponent) * clampedProgress,
            blue: start.blueComponent + (end.blueComponent - start.blueComponent) * clampedProgress,
            alpha: start.alphaComponent + (end.alphaComponent - start.alphaComponent) * clampedProgress
        )
    }

    private static func sampledColor(
        appKitX: CGFloat,
        appKitY: CGFloat,
        bitmap: NSBitmapImageRep,
        bounds: CGRect
    ) -> NSColor? {
        let clampedX = min(max(bounds.minX, appKitX), bounds.maxX - 1)
        let clampedY = min(max(bounds.minY, appKitY), bounds.maxY - 1)
        let x = min(max(0, Int(clampedX.rounded())), bitmap.pixelsWide - 1)
        let y = min(max(0, bitmap.pixelsHigh - 1 - Int(clampedY.rounded())), bitmap.pixelsHigh - 1)
        return bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
    }

    private static func color(from hex: String?) -> NSColor? {
        guard let hex else {
            return nil
        }

        let cleaned = hex
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let expanded: String

        if cleaned.count == 3 {
            expanded = cleaned.map { "\($0)\($0)" }.joined()
        } else {
            expanded = cleaned
        }

        guard expanded.count == 6, let value = Int(expanded, radix: 16) else {
            return nil
        }

        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1
        )
    }

    private static func readableTextColor(on backgroundColor: NSColor) -> NSColor {
        guard let color = backgroundColor.usingColorSpace(.sRGB) else {
            return .labelColor
        }

        let luminance = 0.2126 * color.redComponent
            + 0.7152 * color.greenComponent
            + 0.0722 * color.blueComponent
        return luminance > 0.55 ? .black : .white
    }

    private static func textAlignment(from value: String?) -> NSTextAlignment {
        switch value?.lowercased() {
        case "left", "leading":
            return .left
        case "right", "trailing":
            return .right
        default:
            return .center
        }
    }

    private static func fontWeight(from value: String?) -> NSFont.Weight {
        let normalized = value?.lowercased() ?? ""

        if normalized.contains("bold") || normalized.contains("heavy") || normalized.contains("black") {
            return .bold
        }

        if normalized.contains("semi") || normalized.contains("medium") {
            return .semibold
        }

        if normalized.contains("light") || normalized.contains("thin") {
            return .light
        }

        return .regular
    }
}
