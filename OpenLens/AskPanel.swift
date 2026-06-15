import AppKit
import SwiftUI

@MainActor
final class AskPanelController {
    private let window: NSWindow

    init(controller: OpenLensController, image: PickedImage, anchorRect: CGRect) {
        let panelSize = NSSize(width: 680, height: 430)
        let screen = NSScreen.screens.first { $0.frame.intersects(anchorRect) } ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let x = min(max(anchorRect.midX - panelSize.width / 2, visibleFrame.minX + 20), visibleFrame.maxX - panelSize.width - 20)
        let preferredY = anchorRect.minY - panelSize.height - 16
        let fallbackY = anchorRect.maxY + 16
        let y = preferredY >= visibleFrame.minY + 20
            ? preferredY
            : min(fallbackY, visibleFrame.maxY - panelSize.height - 20)

        window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: x, y: y), size: panelSize),
            styleMask: [.titled, .fullSizeContentView, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "OpenLens"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: AskPanelView(controller: controller, image: image))
        window.minSize = NSSize(width: 520, height: 260)
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window.close()
    }
}

struct AskPanelView: View {
    @ObservedObject var controller: OpenLensController
    let image: PickedImage

    @State private var question = ""
    @State private var answer = ""
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var hasSubmitted = false
    @FocusState private var questionFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(nsImage: image.image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 92, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.18))
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text("Ask about this capture")
                        .font(.headline)

                    Text(image.fileName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            HStack(alignment: .bottom, spacing: 10) {
                TextField("Ask a question about the screenshot", text: $question, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .padding(12)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.2))
                    )
                    .focused($questionFocused)
                    .onSubmit {
                        ask()
                    }

                Button {
                    ask()
                } label: {
                    Image(systemName: "paperplane.fill")
                }
                .help("Send")
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(isLoading || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .textSelection(.enabled)
            }

            if hasSubmitted {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Answer")
                            .font(.headline)

                        Spacer()

                        Button {
                            controller.copyAnswer(answer)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .help("Copy Answer")
                        .disabled(answer.isEmpty)
                    }

                    ScrollView {
                        Text(answerText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(answer.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                            .padding(12)
                    }
                    .frame(minHeight: 130)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.18))
                    )
                }
            }

            Spacer(minLength: 0)
        }
        .padding(18)
        .background(.regularMaterial)
        .onAppear {
            questionFocused = true
        }
    }

    private var answerText: String {
        if isLoading {
            return "Thinking..."
        }

        return answer.isEmpty ? "No answer yet." : answer
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
