import Foundation
import MarrCore
import SwiftUI

@MainActor
final class ConversationRequestCoordinator {
    private weak var controller: MarrController?
    private let session: ConversationSession
    private var activeTurnID: UUID?
    private var requestTask: Task<Void, Never>?

    init(controller: MarrController, session: ConversationSession) {
        self.controller = controller
        self.session = session
    }

    deinit {
        requestTask?.cancel()
    }

    func submit(_ turnID: UUID) {
        cancelActiveRequest(markTurnAsCancelled: true)

        guard let request = session.request(for: turnID) else {
            session.fail(turnID, message: "Could not build the conversation context.")
            return
        }

        activeTurnID = turnID
        requestTask = Task { [weak self] in
            guard let self, let controller else { return }

            do {
                let response = try await controller.submit(request: request)
                try Task.checkCancellation()
                guard activeTurnID == turnID else { return }

                withAnimation(.easeOut(duration: 0.18)) {
                    self.session.complete(turnID, answer: response)
                }
            } catch is CancellationError {
                return
            } catch {
                guard activeTurnID == turnID else { return }

                withAnimation(.easeOut(duration: 0.18)) {
                    self.session.fail(turnID, message: controller.userFacingMessage(for: error))
                }
            }

            finish(turnID)
        }
    }

    func cancel() {
        cancelActiveRequest(markTurnAsCancelled: true)
    }

    private func cancelActiveRequest(markTurnAsCancelled: Bool) {
        let turnID = activeTurnID
        activeTurnID = nil
        requestTask?.cancel()
        requestTask = nil

        if markTurnAsCancelled, let turnID {
            session.fail(turnID, message: "Request cancelled.")
        }
    }

    private func finish(_ turnID: UUID) {
        guard activeTurnID == turnID else { return }
        activeTurnID = nil
        requestTask = nil
    }
}

enum ConversationTitlePrompt {
    static let systemPrompt = """
    Create a concise title that summarizes the screenshot conversation.

    Requirements:
    - Use the same language as the conversation.
    - Capture the actual subject or outcome, not the wording of the user's request.
    - Use 4 to 10 words in English, or 6 to 18 characters in Chinese when practical.
    - Return only the title, without quotes, markdown, labels, or ending punctuation.
    """

    static func request(question: String, answer: String) -> VisionRequest {
        VisionRequest(
            systemPrompt: systemPrompt,
            messages: [
                VisionMessage(
                    role: .user,
                    content: [
                        .text("""
                        User question:
                        \(question)

                        Assistant answer:
                        \(answer)
                        """)
                    ]
                )
            ]
        )
    }

    static func clean(_ response: String) -> String {
        var title = response
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""

        for prefix in ["Title:", "Title：", "标题:", "标题："] where title.hasPrefix(prefix) {
            title = String(title.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        title = title.trimmingCharacters(
            in: CharacterSet(charactersIn: "#*`\"'“”‘’《》 ")
                .union(.whitespacesAndNewlines)
        )
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: ".。!！?？:：;；"))

        let maximumLength = 48
        if title.count > maximumLength {
            title = String(title.prefix(maximumLength - 1))
                .trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return title
    }
}

@MainActor
final class ConversationTitleCoordinator {
    private weak var controller: MarrController?
    private let session: ConversationSession
    private var attemptedSignature: String?
    private var requestTask: Task<Void, Never>?

    init(controller: MarrController, session: ConversationSession) {
        self.controller = controller
        self.session = session
    }

    deinit {
        requestTask?.cancel()
    }

    func generateIfNeeded() {
        guard session.generatedTitle == nil else { return }
        guard let turn = session.turns.first(where: { $0.status == .completed && !$0.answer.isEmpty }) else {
            return
        }

        let signature = turn.question + "\u{0}" + turn.answer
        guard attemptedSignature != signature else { return }
        attemptedSignature = signature
        requestTask?.cancel()

        let request = ConversationTitlePrompt.request(question: turn.question, answer: turn.answer)
        requestTask = Task { [weak self] in
            guard let self, let controller else { return }
            defer { requestTask = nil }
            do {
                let response = try await controller.submit(request: request)
                try Task.checkCancellation()
                guard attemptedSignature == signature else { return }
                let title = ConversationTitlePrompt.clean(response)
                guard !title.isEmpty else { return }
                session.setGeneratedTitle(title)
            } catch {
                return
            }
        }
    }

    func cancel() {
        requestTask?.cancel()
        requestTask = nil
    }
}
