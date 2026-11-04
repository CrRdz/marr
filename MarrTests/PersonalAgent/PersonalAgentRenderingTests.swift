import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import Marr

@MainActor
final class PersonalAgentRenderingTests: XCTestCase {
    func testWorkspaceSectionsRenderAtOriginalWidthInLightAndDarkWithoutExecution() throws {
        let suite = "marr-agent-render-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let runtime = RuntimeWorkspaceController(defaults: defaults, outboundMessage: { _ in XCTFail("Rendering must not connect") }, codexSyncEnabled: false)
        defer { runtime.shutdown() }
        let store = PersonalAgentStore(rootURL: nil), agent = store.archive.agents[0]
        try store.save(PersonalAgentSkill(name: "Source-backed brief", instructions: "Find primary sources, compare changes, and return a concise summary with citations."))
        try store.save(PersonalAgentRoutine(agentID: agent.id, name: "Morning research", instruction: "Summarize updates"))
        let run = try store.begin(agentID: agent.id, prompt: "Prepare a short research brief.")
        try store.updateRun(run.id) { $0.status = .succeeded; $0.result = "A saved result appears here.\n\n- Verified sources\n- Clear next steps" }
        try store.save(PersonalAgentProfile(name: "Research", role: "Sources, ideas and discoveries", instructions: "Research carefully", tint: 300))
        try store.save(PersonalAgentProfile(name: "Planner", role: "A clear plan for today", instructions: "Plan realistically", tint: 80))
        let coordinator = PersonalAgentCoordinator(store: store, endpoint: { XCTFail("No execution from render"); throw CancellationError() }, model: { "test" }, isReady: { false })
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("marr-personal-agent-preview")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for dark in [false, true] {
            for section in PersonalAgentWorkspaceView.Section.allCases {
                try capture(section: section, agentID: nil, dark: dark, coordinator: coordinator, runtime: runtime, output: output)
            }
            try capture(section: .agents, agentID: agent.id, dark: dark, coordinator: coordinator, runtime: runtime, output: output)
            try capture(section: .agents, agentID: agent.id, dark: dark, coordinator: coordinator, runtime: runtime, output: output, wide: true)
        }
    }

    private func capture(section: PersonalAgentWorkspaceView.Section, agentID: UUID?, dark: Bool,
                         coordinator: PersonalAgentCoordinator, runtime: RuntimeWorkspaceController, output: URL, wide: Bool = false) throws {
        coordinator.savedSelectedAgentID = nil
        coordinator.savedSection = section.rawValue
        let size = CGSize(width: wide ? 860 : 484, height: 596)
        let window = MarrOffscreenTestWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        defer { window.contentView = nil; window.close() }
        let navigation = AnswerPanelNavigation(initialDestination: nil, sidebar: nil, workspaceIDs: [])
        navigation.setHistoryExpanded(wide)
        navigation.sidebarRevealWidth = wide ? AnswerPanelSidebarLayout.sidebarWidth : 0
        let host = NSHostingView(rootView: HStack(spacing: 0) {
            MarrNavigationRail(selection: .constant(.personalAgent))
            PersonalAgentWorkspaceView(coordinator: coordinator, runtime: runtime, section: section, selectedAgentID: agentID, navigation: navigation)
        }
        .frame(width: size.width, height: size.height)
        .marrGlassSurface(cornerRadius: 22, frostsTop: true, frostOpacity: 0.80)
        .environment(\.colorScheme, dark ? .dark : .light))
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded(); CATransaction.flush()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let file = output.appendingPathComponent("\(wide ? "wide-" : "")\(agentID == nil ? section.rawValue.lowercased() : "conversation")-\(dark ? "dark" : "light").png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: file)
        let attachment = XCTAttachment(contentsOfFile: file); attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertEqual(host.bounds.width, size.width)
    }
}
