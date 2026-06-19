import AppKit
import XCTest
@testable import OpenLens

@MainActor
final class ConversationHarnessTests: XCTestCase {
    func testBuildsStructuredRoleSequenceForFollowUp() throws {
        let session = ConversationSession(
            initialImage: makeImage(name: "first.png", byte: 1),
            initialQuestion: "What is shown?"
        )
        let firstID = try XCTUnwrap(session.turns.first?.id)
        session.complete(firstID, answer: "A settings window.")
        let secondID = try XCTUnwrap(session.beginTurn(question: "Which button should I press?"))

        let request = try XCTUnwrap(session.request(for: secondID))

        XCTAssertEqual(request.messages.map(\.role), [.user, .assistant, .user])
        XCTAssertEqual(imageCount(in: request.messages[0]), 1)
        XCTAssertEqual(imageCount(in: request.messages[2]), 0)
        XCTAssertEqual(text(in: request.messages[1]), "A settings window.")
    }

    func testNewScreenshotBelongsToNextTurnWithoutReplacingHistory() throws {
        let session = ConversationSession(
            initialImage: makeImage(name: "first.png", byte: 1),
            initialQuestion: "Describe this."
        )
        let firstID = try XCTUnwrap(session.turns.first?.id)
        let firstImageID = try XCTUnwrap(session.turns.first?.imageIDs.first)
        session.complete(firstID, answer: "The first screen.")

        let secondImageID = session.appendScreenshot(makeImage(name: "second.png", byte: 2))
        let secondID = try XCTUnwrap(session.beginTurn(question: "What changed?"))
        let request = try XCTUnwrap(session.request(for: secondID))

        XCTAssertNotEqual(firstImageID, secondImageID)
        XCTAssertNotNil(session.images[firstImageID])
        XCTAssertNotNil(session.images[secondImageID])
        XCTAssertEqual(session.turns[1].imageIDs, [secondImageID])
        XCTAssertEqual(imageCount(in: request.messages[0]), 1)
        XCTAssertEqual(imageCount(in: request.messages[2]), 1)
    }

    func testContextPolicyKeepsOnlyMostRecentCompletedTurns() throws {
        let policy = ConversationContextPolicy(
            maximumCompletedTurns: 1,
            maximumTextCharacters: 10_000,
            maximumImages: 2
        )
        let session = ConversationSession(
            initialImage: makeImage(name: "first.png", byte: 1),
            initialQuestion: "Question one",
            contextBuilder: ConversationContextBuilder(policy: policy)
        )
        let firstID = try XCTUnwrap(session.turns.first?.id)
        session.complete(firstID, answer: "Answer one")
        let secondID = try XCTUnwrap(session.beginTurn(question: "Question two"))
        session.complete(secondID, answer: "Answer two")
        let thirdID = try XCTUnwrap(session.beginTurn(question: "Question three"))

        let request = try XCTUnwrap(session.request(for: thirdID))

        XCTAssertEqual(request.messages.map(\.role), [.user, .assistant, .user])
        XCTAssertEqual(text(in: request.messages[0]), "Question two")
        XCTAssertEqual(text(in: request.messages[2]), "Question three")
        XCTAssertEqual(imageCount(in: request.messages[2]), 1)
    }

    func testFailedTurnCanBeRetriedWithSameContext() throws {
        let session = ConversationSession(
            initialImage: makeImage(name: "first.png", byte: 1),
            initialQuestion: "Try this"
        )
        let turnID = try XCTUnwrap(session.turns.first?.id)
        session.fail(turnID, message: "Network error")

        XCTAssertTrue(session.prepareRetry(turnID))
        XCTAssertEqual(session.turns[0].status, .loading)
        XCTAssertNil(session.turns[0].errorMessage)
        XCTAssertNotNil(session.request(for: turnID))
    }

    private func makeImage(name: String, byte: UInt8) -> PickedImage {
        PickedImage(
            data: Data([byte]),
            mimeType: "image/png",
            fileName: name,
            image: NSImage(size: NSSize(width: 1, height: 1))
        )
    }

    private func imageCount(in message: VisionMessage) -> Int {
        message.content.reduce(into: 0) { count, content in
            if case .image = content { count += 1 }
        }
    }

    private func text(in message: VisionMessage) -> String? {
        message.content.compactMap { content in
            if case .text(let value) = content { return value }
            return nil
        }.last
    }
}
