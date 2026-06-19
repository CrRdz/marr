import SwiftUI

@main
@MainActor
struct OpenLensApp: App {
    @StateObject private var controller: OpenLensController

    init() {
        let controller = OpenLensController(client: OpenAIClient())
        _controller = StateObject(wrappedValue: controller)
        controller.installHotKeyIfNeeded()
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(controller: controller)
        } label: {
            Image(systemName: "viewfinder")
                .accessibilityLabel("OpenLens")
        }
        .menuBarExtraStyle(.window)

        Window("OpenLens History", id: "history") {
            HistoryView(store: controller.historyStore)
        }
        .defaultSize(width: 840, height: 560)
        .windowResizability(.contentMinSize)
    }
}
