import AppKit
import SwiftUI

@MainActor
final class AskPanelController {
    private let window: AskPanelWindow

    init(controller: OpenLensController, image: PickedImage, anchorRect: CGRect, initialQuestion: String = "") {
        let panelSize = NSSize(width: 780, height: 168)
        let screen = NSScreen.screens.first { $0.frame.intersects(anchorRect) } ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let margin: CGFloat = 22
        let gap: CGFloat = 18
        let x = min(max(anchorRect.midX - panelSize.width / 2, visibleFrame.minX + margin), visibleFrame.maxX - panelSize.width - margin)
        let preferredY = anchorRect.minY - panelSize.height - gap
        let fallbackY = anchorRect.maxY + gap
        let y = preferredY >= visibleFrame.minY + 20
            ? preferredY
            : min(fallbackY, visibleFrame.maxY - panelSize.height - margin)

        window = AskPanelWindow(
            contentRect: CGRect(origin: CGPoint(x: x, y: y), size: panelSize),
            styleMask: [.borderless, .fullSizeContentView, .resizable],
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
            rootView: AskPanelView(
                controller: controller,
                image: image,
                initialQuestion: initialQuestion,
                onClose: { [weak controller] in
                    controller?.dismissCaptureSession()
                }
            )
        )
        window.minSize = NSSize(width: 560, height: 150)
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window.close()
    }
}

private final class AskPanelWindow: NSWindow {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }
}

struct AskPanelView: View {
    @ObservedObject var controller: OpenLensController
    let image: PickedImage
    let initialQuestion: String
    let onClose: () -> Void

    @State private var question: String
    @State private var answer = ""
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var hasSubmitted = false
    @FocusState private var questionFocused: Bool

    init(controller: OpenLensController, image: PickedImage, initialQuestion: String, onClose: @escaping () -> Void) {
        self.controller = controller
        self.image = image
        self.initialQuestion = initialQuestion
        self.onClose = onClose
        _question = State(initialValue: initialQuestion)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            inputSurface
            if hasSubmitted || isLoading || errorMessage != nil {
                responseStatus
            }
        }
        .liquidGlassSurface(cornerRadius: 28, isClear: true)
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.14), radius: 20, x: 0, y: 12)
        .padding(8)
        .onAppear {
            DispatchQueue.main.async {
                questionFocused = true
                if !initialQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ask()
                }
            }
        }
    }

    private var inputSurface: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("随心输入", text: $question, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 18, weight: .regular))
                .lineLimit(1...2)
                .focused($questionFocused)
                .onSubmit {
                    ask()
                }

            inputControls
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var inputControls: some View {
        HStack(spacing: 10) {
            Spacer()

            Button {
                ask()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 42, height: 42)
            }
            .sendCircleButton(isEnabled: canSend)
            .help("Send")
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!canSend)
        }
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(.secondary)
    }

    private var responseStatus: some View {
        HStack(spacing: 10) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                Text("Thinking...")
            } else if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            } else {
                Text(answerText)
                    .textSelection(.enabled)
            }

            Spacer()

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .liquidGlassIconButton()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
    }

    private var sendButtonBackground: LinearGradient {
        LinearGradient(
            colors: canSend
                ? [Color.accentColor, Color.accentColor.opacity(0.72)]
                : [Color.secondary.opacity(0.42), Color.secondary.opacity(0.26)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var modelOptions: [String] {
        [
            "claude-sonnet-4-6",
            "claude-opus-4-1",
            "gpt-4.1",
            "gpt-4o"
        ]
    }

    private var modelDisplayName: String {
        if controller.model.contains("sonnet") {
            return "Sonnet"
        }

        if controller.model.contains("opus") {
            return "Opus"
        }

        if controller.model.contains("gpt") {
            return "GPT"
        }

        return controller.model.isEmpty ? "Model" : controller.model
    }

    private var canSend: Bool {
        !isLoading && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var answerText: String {
        if isLoading {
            return "Thinking..."
        }

        return answer.isEmpty ? "" : answer
    }

    private func ask() {
        guard !isLoading else {
            return
        }

        errorMessage = nil
        hasSubmitted = true
        answer = ""
        isLoading = true

        Task {
            do {
                let response = try await controller.submit(image: image, question: question)
                await MainActor.run {
                    answer = response
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = controller.userFacingMessage(for: error)
                    isLoading = false
                }
            }
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
            self.buttonStyle(.glass)
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
