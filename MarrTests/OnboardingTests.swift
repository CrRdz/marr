import AppKit
import MarrCore
import XCTest
@testable import Marr

@MainActor
final class OnboardingTests: XCTestCase {
    func testOnboardingIsRequiredUntilCurrentVersionIsCompleted() throws {
        let suiteName = "MarrOnboardingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(MarrOnboarding.isRequired(in: defaults))

        MarrOnboarding.markCompleted(in: defaults)

        XCTAssertFalse(MarrOnboarding.isRequired(in: defaults))
        XCTAssertEqual(
            defaults.integer(forKey: MarrOnboarding.completedVersionKey),
            MarrOnboarding.currentVersion
        )
    }

    func testOlderCompletedVersionRequiresOnboardingAgain() throws {
        let suiteName = "MarrOnboardingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            MarrOnboarding.currentVersion - 1,
            forKey: MarrOnboarding.completedVersionKey
        )

        XCTAssertTrue(MarrOnboarding.isRequired(in: defaults))
    }

    func testSettingsWelcomeEntryPresentsAndReusesWindow() throws {
        let presenter = MarrOnboardingPresenter.shared
        presenter.dismissForTesting()
        defer { presenter.dismissForTesting() }
        let controller = MarrController(client: OnboardingTestClient())

        openMarrWelcomeGuide(controller: controller)
        let firstWindow = try XCTUnwrap(presenter.presentedWindowForTesting)

        XCTAssertTrue(firstWindow.isVisible)

        openMarrWelcomeGuide(controller: controller)

        XCTAssertTrue(presenter.presentedWindowForTesting === firstWindow)
    }
}

private struct OnboardingTestClient: VisionAIClient {
    func ask(
        request: VisionRequest,
        model: String,
        connection: InferenceConnection
    ) async throws -> String {
        "OK"
    }
}
