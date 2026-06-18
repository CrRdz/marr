import AppKit
import Carbon
import SwiftUI

@MainActor
final class AnswerPanelController {
    private let window: AnswerPanelWindow
    private let session: AnswerPanelSession
    private var escapeMonitor: Any?
    private var onClose: (() -> Void)?
    private var allowsWindowDragging = false

    init(controller: OpenLensController, image: PickedImage, anchorRect: CGRect, initialQuestion: String) {
        session = AnswerPanelSession(image: image)
        let panelSize = NSSize(width: 544, height: 398)
        let screen = NSScreen.screens.first { $0.frame.intersects(anchorRect) } ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let margin: CGFloat = 22

        let x = visibleFrame.maxX - panelSize.width - margin
        let y = visibleFrame.minY + margin
        let composerRect = CGRect(
            x: x + (panelSize.width - 420) / 2,
            y: y + 12,
            width: 420,
            height: 46
        )
        let usesRegularComposerGlass = screen.map {
            BackgroundBrightnessSampler.isNearlyWhite(in: composerRect, on: $0)
        } ?? false

        window = AnswerPanelWindow(
            contentRect: CGRect(origin: CGPoint(x: x, y: y), size: panelSize),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "OpenLens"
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovableByWindowBackground = allowsWindowDragging
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.acceptsMouseMovedEvents = true
        window.ignoresMouseEvents = false
        let hostingView = AnswerPanelHostingView(
            rootView: AnswerPanelView(
                controller: controller,
                session: session,
                initialQuestion: initialQuestion,
                usesRegularComposerGlass: usesRegularComposerGlass
            )
        )
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()
        onClose = { [weak controller] in
            controller?.dismissCaptureSession()
        }
    }

    func show() {
        installEscapeMonitor()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        removeEscapeMonitor()
        window.close()
    }

    func setWindowDraggingEnabled(_ isEnabled: Bool) {
        allowsWindowDragging = isEnabled
        window.isMovableByWindowBackground = isEnabled
    }

    func appendScreenshot(_ image: PickedImage) {
        session.image = image
        session.focusRequestID += 1
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func installEscapeMonitor() {
        removeEscapeMonitor()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == kVK_Escape else {
                return event
            }

            self?.onClose?()
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

private enum BackgroundBrightnessSampler {
    static func isNearlyWhite(in rect: CGRect, on screen: NSScreen) -> Bool {
        guard
            let displayNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else {
            return false
        }

        let scale = screen.backingScaleFactor
        let pixelRect = CGRect(
            x: (rect.minX - screen.frame.minX) * scale,
            y: (screen.frame.maxY - rect.maxY) * scale,
            width: rect.width * scale,
            height: rect.height * scale
        ).integral
        let displayID = CGDirectDisplayID(displayNumber.uint32Value)

        guard
            let image = CGDisplayCreateImage(displayID, rect: pixelRect),
            let bitmap = NSBitmapImageRep(cgImage: image).retagging(with: .sRGB)
        else {
            return false
        }

        let columns = 32
        let rows = 6
        var luminanceTotal: CGFloat = 0
        var nearWhiteSamples = 0
        var sampleCount = 0

        for row in 0..<rows {
            for column in 0..<columns {
                let x = min(bitmap.pixelsWide - 1, (column * bitmap.pixelsWide + bitmap.pixelsWide / 2) / columns)
                let y = min(bitmap.pixelsHigh - 1, (row * bitmap.pixelsHigh + bitmap.pixelsHigh / 2) / rows)
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                    continue
                }

                let luminance = 0.2126 * color.redComponent
                    + 0.7152 * color.greenComponent
                    + 0.0722 * color.blueComponent
                luminanceTotal += luminance
                if luminance >= 0.93 && color.saturationComponent <= 0.08 {
                    nearWhiteSamples += 1
                }
                sampleCount += 1
            }
        }

        guard sampleCount > 0 else {
            return false
        }

        let averageLuminance = luminanceTotal / CGFloat(sampleCount)
        let nearWhiteRatio = CGFloat(nearWhiteSamples) / CGFloat(sampleCount)
        return averageLuminance >= 0.90 && nearWhiteRatio >= 0.72
    }
}

private final class AnswerPanelSession: ObservableObject {
    @Published var image: PickedImage
    @Published var focusRequestID = 0

    init(image: PickedImage) {
        self.image = image
    }
}

private final class AnswerPanelWindow: NSWindow {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }
}

private final class AnswerPanelHostingView<Content: View>: NSHostingView<Content> {
    override var acceptsFirstResponder: Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) ?? (bounds.contains(point) ? self : nil)
    }

    override func scrollWheel(with event: NSEvent) {
        if let scrollView = firstScrollView(in: self) {
            scrollView.scrollWheel(with: event)
        }
        // Keep wheel events inside the transparent answer panel instead of
        // allowing them to pass through to whatever is behind the window.
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView {
            return scrollView
        }

        for subview in view.subviews {
            if let scrollView = firstScrollView(in: subview) {
                return scrollView
            }
        }

        return nil
    }
}

private struct ConversationTurn: Identifiable, Equatable {
    let id: UUID
    var question: String
    var answer: String
    var errorMessage: String?
    var isLoading: Bool
    var showsAssistant: Bool
}

private struct AnswerPanelView: View {
    @ObservedObject var controller: OpenLensController
    @ObservedObject var session: AnswerPanelSession
    let initialQuestion: String
    let usesRegularComposerGlass: Bool

    @State private var question = ""
    @State private var turns: [ConversationTurn]
    @State private var lastAutoScrolledTurnCount = 0
    @State private var hasSubmittedInitialQuestion = false
    @FocusState private var questionFocused: Bool

    private let composerWidth: CGFloat = 420
    private let assistantRevealDelay = 0.30

    init(
        controller: OpenLensController,
        session: AnswerPanelSession,
        initialQuestion: String,
        usesRegularComposerGlass: Bool
    ) {
        self.controller = controller
        self.session = session
        self.initialQuestion = initialQuestion
        self.usesRegularComposerGlass = usesRegularComposerGlass
        _turns = State(initialValue: [
            ConversationTurn(
                id: UUID(),
                question: initialQuestion,
                answer: "",
                errorMessage: nil,
                isLoading: true,
                showsAssistant: true
            )
        ])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            conversationBody
            composer
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(width: 520, height: 374, alignment: .bottom)
        .padding(12)
        .onAppear {
            DispatchQueue.main.async {
                questionFocused = true
                submitInitialQuestion()
            }
        }
        .onChange(of: session.focusRequestID) { _, _ in
            questionFocused = true
        }
    }

    private var conversationBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(turns) { turn in
                        turnView(turn, isCompact: false, showsUserMessage: true)
                            .id(turn.id)
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 2)
                .frame(width: composerWidth, alignment: .topLeading)
                .frame(minHeight: 276, alignment: .bottom)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .onChange(of: turns.count) { _, nextCount in
                guard nextCount > lastAutoScrolledTurnCount, let lastID = turns.last?.id else {
                    return
                }

                lastAutoScrolledTurnCount = nextCount
                DispatchQueue.main.async {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: 276)
    }

    private func turnView(_ turn: ConversationTurn, isCompact: Bool, showsUserMessage: Bool) -> some View {
        VStack(spacing: 10) {
            if showsUserMessage {
                HStack {
                    Spacer(minLength: 72)
                    Text(turn.question)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(nsColor: .controlAccentColor).opacity(0.92), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.10), radius: 6, x: 0, y: 3)
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .opacity
                ))
            }

            if turn.showsAssistant {
                if turn.errorMessage != nil {
                    errorMessage(turn)
                        .transition(.opacity)
                } else {
                    HStack(alignment: .top) {
                        assistantMessage(turn, isCompact: isCompact)
                        Spacer(minLength: 72)
                    }
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .opacity
                    ))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func assistantMessage(_ turn: ConversationTurn, isCompact: Bool) -> some View {
        if turn.isLoading {
            TypingIndicatorView()
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .liquidGlassSurface(cornerRadius: 15, isClear: true)
            .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 3)
        } else {
            Text(turn.answer.isEmpty ? " " : turn.answer)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .lineSpacing(3)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .liquidGlassSurface(cornerRadius: 15, isClear: true)
                .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 3)
        }
    }

    private func errorMessage(_ turn: ConversationTurn) -> some View {
        Text(turn.errorMessage ?? "")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.red)
            .multilineTextAlignment(.center)
            .lineSpacing(3)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 6)
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Ask a follow-up", text: $question, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .regular))
                .lineLimit(1...2)
                .foregroundStyle(.primary)
                .focused($questionFocused)
                .onSubmit {
                    sendCurrentQuestion()
                }

            Button {
                sendCurrentQuestion()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 34, height: 34)
            }
            .sendCircleButton(isEnabled: canSend)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!canSend)
            .help("Send")
        }
        .padding(.leading, 14)
        .padding(.trailing, 7)
        .padding(.vertical, 6)
        .frame(width: composerWidth)
        .frame(minHeight: 46)
        .liquidGlassSurface(cornerRadius: 23, isClear: !usesRegularComposerGlass)
        .overlay(
            RoundedRectangle(cornerRadius: 23, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 0.8)
        )
        .shadow(color: .white.opacity(0.10), radius: 1, x: 0, y: -1)
    }

    private var canSend: Bool {
        !hasLoadingTurn && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasLoadingTurn: Bool {
        turns.contains { $0.isLoading }
    }

    private func sendCurrentQuestion() {
        let current = question
        question = ""
        send(current)
    }

    private func send(_ rawQuestion: String) {
        let trimmedQuestion = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty, !hasLoadingTurn else {
            return
        }

        let turnID = UUID()
        let contextPrompt = prompt(for: trimmedQuestion)
        withAnimation(.easeOut(duration: 0.20)) {
            turns.append(
                ConversationTurn(
                    id: turnID,
                    question: trimmedQuestion,
                    answer: "",
                    errorMessage: nil,
                    isLoading: true,
                    showsAssistant: false
                )
            )
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + assistantRevealDelay) {
            withAnimation(.easeOut(duration: 0.20)) {
                showAssistantMessage(id: turnID)
            }
        }

        Task {
            do {
                let response = try await controller.submit(image: session.image, question: contextPrompt)
                await MainActor.run {
                    updateTurn(id: turnID, answer: response, errorMessage: nil)
                }
            } catch {
                await MainActor.run {
                    updateTurn(id: turnID, answer: "", errorMessage: controller.userFacingMessage(for: error))
                }
            }
        }
    }

    private func submitInitialQuestion() {
        guard !hasSubmittedInitialQuestion, let turnID = turns.first?.id else {
            return
        }

        hasSubmittedInitialQuestion = true
        let contextPrompt = prompt(for: initialQuestion)
        Task {
            do {
                let response = try await controller.submit(image: session.image, question: contextPrompt)
                await MainActor.run {
                    updateTurn(id: turnID, answer: response, errorMessage: nil)
                }
            } catch {
                await MainActor.run {
                    updateTurn(id: turnID, answer: "", errorMessage: controller.userFacingMessage(for: error))
                }
            }
        }
    }

    private func updateTurn(id: UUID, answer: String, errorMessage: String?) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else {
            return
        }

        withAnimation(.easeOut(duration: 0.18)) {
            turns[index].answer = answer
            turns[index].errorMessage = errorMessage
            turns[index].isLoading = false
        }
        questionFocused = true
    }

    private func showAssistantMessage(id: UUID) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else {
            return
        }

        turns[index].showsAssistant = true
    }

    private func prompt(for newQuestion: String) -> String {
        let previousTurns = turns
            .filter { !$0.isLoading && $0.errorMessage == nil && !$0.answer.isEmpty }
            .map { "User: \($0.question)\nAssistant: \($0.answer)" }
            .joined(separator: "\n\n")

        guard !previousTurns.isEmpty else {
            return newQuestion
        }

        return """
        You are continuing a conversation about the same screenshot. Use the previous conversation as context, but answer the latest user question directly.

        Previous conversation:
        \(previousTurns)

        Latest user question:
        \(newQuestion)
        """
    }
}

private struct TypingIndicatorView: View {
    @State private var activeDot = 0
    @State private var timer: Timer?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(.primary.opacity(index == activeDot ? 0.72 : 0.28))
                    .frame(width: 5, height: 5)
                    .offset(y: index == activeDot ? -1 : 0)
            }
        }
        .frame(height: 16)
        .onAppear {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.22, repeats: true) { _ in
                activeDot = (activeDot + 1) % 3
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }
}

private extension View {
    @ViewBuilder
    func liquidGlassSurface(cornerRadius: CGFloat, isClear: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(
                isClear ? .clear.interactive() : .regular.interactive(),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            self
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.white.opacity(isClear ? 0.05 : 0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(.white.opacity(isClear ? 0.22 : 0.34), lineWidth: 1)
                )
        }
    }

    @ViewBuilder
    func liquidGlassIconButton() -> some View {
        if #available(macOS 26.0, *) {
            self
                .buttonStyle(.glass)
                .foregroundStyle(.secondary)
        } else {
            self
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    func sendCircleButton(isEnabled: Bool) -> some View {
        self
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(isEnabled ? Color(nsColor: .labelColor) : Color.secondary.opacity(0.46), in: Circle())
            .shadow(color: .black.opacity(isEnabled ? 0.18 : 0.06), radius: 8, x: 0, y: 4)
    }
}
