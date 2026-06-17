import AppKit
import Carbon
import SwiftUI

@MainActor
final class AnswerPanelController {
    private let window: AnswerPanelWindow
    private var escapeMonitor: Any?
    private var onClose: (() -> Void)?

    init(controller: OpenLensController, image: PickedImage, anchorRect: CGRect, initialQuestion: String) {
        let panelSize = NSSize(width: 536, height: 346)
        let screen = NSScreen.screens.first { $0.frame.intersects(anchorRect) } ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let margin: CGFloat = 22
        let gap: CGFloat = 16
        let preferredBelow = anchorRect.minY - panelSize.height - gap
        let preferredAbove = anchorRect.maxY + gap
        let x: CGFloat
        let y: CGFloat

        x = min(max(anchorRect.midX - panelSize.width / 2, visibleFrame.minX + margin), visibleFrame.maxX - panelSize.width - margin)
        y = preferredBelow >= visibleFrame.minY + margin
            ? preferredBelow
            : min(preferredAbove, visibleFrame.maxY - panelSize.height - margin)

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
        window.isMovableByWindowBackground = true
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = NSHostingView(
            rootView: AnswerPanelView(
                controller: controller,
                image: image,
                initialQuestion: initialQuestion
            )
        )
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

private final class AnswerPanelWindow: NSWindow {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }
}

private struct ConversationTurn: Identifiable, Equatable {
    let id: UUID
    var question: String
    var answer: String
    var errorMessage: String?
    var isLoading: Bool
}

struct AnswerPanelView: View {
    @ObservedObject var controller: OpenLensController
    let image: PickedImage
    let initialQuestion: String

    @State private var question = ""
    @State private var turns: [ConversationTurn] = []
    @State private var showsHistory = false
    @FocusState private var questionFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            conversationBody
            composer
        }
        .frame(width: 520, height: 330)
        .padding(8)
        .onAppear {
            DispatchQueue.main.async {
                questionFocused = true
                send(initialQuestion)
            }
        }
    }

    private var conversationBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsHistory {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(turns) { turn in
                            turnView(turn, isCompact: false, showsUserMessage: true)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } else {
                if hiddenTurnCount > 0 {
                    Button {
                        withAnimation(.snappy(duration: 0.22)) {
                            showsHistory = true
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 12, weight: .medium))
                            Text("View previous messages")
                                .font(.system(size: 12, weight: .medium))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary.opacity(0.72))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .liquidGlassSurface(cornerRadius: 15, isClear: true)
                }

                if let latestTurn {
                    turnView(latestTurn, isCompact: true, showsUserMessage: true)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func turnView(_ turn: ConversationTurn, isCompact: Bool, showsUserMessage: Bool) -> some View {
        VStack(spacing: 10) {
            if showsUserMessage {
                HStack {
                    Spacer(minLength: 72)
                    Text(turn.question)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(isCompact ? 2 : nil)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(nsColor: .controlAccentColor).opacity(0.92), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 5)
                }
            }

            HStack(alignment: .top) {
                assistantMessage(turn, isCompact: isCompact)
                Spacer(minLength: 72)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func assistantMessage(_ turn: ConversationTurn, isCompact: Bool) -> some View {
        if turn.isLoading {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Thinking...")
            }
            .font(.system(size: 13))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .liquidGlassSurface(cornerRadius: 15, isClear: true)
            .shadow(color: .black.opacity(0.10), radius: 10, x: 0, y: 5)
        } else if let errorMessage = turn.errorMessage {
            Text(errorMessage)
                .font(.system(size: 13))
                .foregroundStyle(.red)
                .lineSpacing(3)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .liquidGlassSurface(cornerRadius: 15, isClear: true)
                .shadow(color: .black.opacity(0.10), radius: 10, x: 0, y: 5)
        } else {
            Text(turn.answer.isEmpty ? " " : turn.answer)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .lineSpacing(3)
                .lineLimit(isCompact ? 7 : nil)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .liquidGlassSurface(cornerRadius: 15, isClear: true)
                .shadow(color: .black.opacity(0.10), radius: 10, x: 0, y: 5)
        }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Ask a follow-up", text: $question, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...3)
                .focused($questionFocused)
                .onSubmit {
                    sendCurrentQuestion()
                }

            Button {
                sendCurrentQuestion()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .sendCircleButton(isEnabled: canSend)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!canSend)
            .help("Send")
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 10)
        .liquidGlassSurface(cornerRadius: 22, isClear: true)
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white.opacity(0.16), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.12), radius: 14, x: 0, y: 7)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    private var canSend: Bool {
        !hasLoadingTurn && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasLoadingTurn: Bool {
        turns.contains { $0.isLoading }
    }

    private var latestTurn: ConversationTurn? {
        turns.last
    }

    private var hiddenTurnCount: Int {
        max(0, turns.count - 1)
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
        turns.append(
            ConversationTurn(
                id: turnID,
                question: trimmedQuestion,
                answer: "",
                errorMessage: nil,
                isLoading: true
            )
        )
        showsHistory = false

        Task {
            do {
                let response = try await controller.submit(image: image, question: contextPrompt)
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

        turns[index].answer = answer
        turns[index].errorMessage = errorMessage
        turns[index].isLoading = false
        questionFocused = true
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
