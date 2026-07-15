import Foundation
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
