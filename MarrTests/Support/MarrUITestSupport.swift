import Foundation
import AppKit
import XCTest
@testable import Marr

/// Visible-window tests are intentionally opt-in: the normal suite must not
/// activate Marr, cover the user's desktop, or move their keyboard focus.
enum MarrUITestSupport {
    static func requireVisibleWindows(file: StaticString = #filePath, line: UInt = #line) throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MARR_RUN_UI_TESTS"] == "1",
            "Visible-window test is opt-in. Run scripts/test-marr.sh --ui on an available desktop.",
            file: file, line: line
        )
    }
}

/// Offscreen fixtures must remain offscreen even if a future layout/focus
/// helper accidentally tries to order them in. Fail the test before AppKit can
/// cover the desktop or take keyboard focus.
@MainActor
final class MarrOffscreenTestWindow: NSWindow {
    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        guard place == .out else {
            XCTFail("An offscreen fixture tried to become visible. Use an explicitly gated visible-window test.")
            return
        }
        super.order(place, relativeTo: otherWin)
    }

    override func orderFront(_ sender: Any?) { rejectVisibility() }
    override func orderFrontRegardless() { rejectVisibility() }
    override func makeKeyAndOrderFront(_ sender: Any?) { rejectVisibility() }
    override func makeKey() { rejectVisibility() }

    private func rejectVisibility() {
        XCTFail("An offscreen fixture tried to become visible or key. Visible windows require explicit test opt-in.")
    }
}

/// Register cleanup in XCTest teardown, after the test's controllers and views
/// have left scope. SQLite must finish its queued work and close before its
/// directory is removed; an early `defer` can otherwise unlink a live database.
@MainActor
final class MarrHistoryTestResources {
    let rootURL: URL
    private var stores: [ConversationHistoryStore] = []

    init(rootURL: URL) { self.rootURL = rootURL }

    func makeStore(at directory: URL? = nil) -> ConversationHistoryStore {
        let store = ConversationHistoryStore(rootURL: directory ?? rootURL)
        stores.append(store)
        return store
    }

    func cleanUp() async throws {
        let references = stores.map(WeakStore.init)
        await drainAndReleaseStores()
        // SwiftUI releases a removed hosting graph on a subsequent main-loop
        // pass (not synchronously with contentView = nil). Keep the database
        // alive until that bounded teardown completes; still fail real leaks.
        let deadline = Date().addingTimeInterval(2)
        while references.contains(where: { $0.value != nil }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard references.allSatisfy({ $0.value == nil }) else {
            XCTFail("A history fixture is still retained at teardown; its database directory was preserved instead of unlinking an open SQLite file.")
            return
        }
        if FileManager.default.fileExists(atPath: rootURL.path) {
            try FileManager.default.removeItem(at: rootURL)
        }
    }

    private func drainAndReleaseStores() async {
        for store in stores { await store.waitForPendingOperations() }
        stores.removeAll()
    }

    private final class WeakStore {
        weak var value: ConversationHistoryStore?
        init(_ value: ConversationHistoryStore) { self.value = value }
    }
}
