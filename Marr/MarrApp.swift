import SwiftUI

@main
@MainActor
struct MarrApp: App {
    @StateObject private var controller: MarrController

    init() {
        let controller = MarrController(client: OpenAIClient())
        _controller = StateObject(wrappedValue: controller)
        controller.installHotKeyIfNeeded()
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(controller: controller)
        } label: {
            Image(systemName: "viewfinder")
                .accessibilityLabel("Marr")
        }
        .menuBarExtraStyle(.window)

        Window("Marr History", id: "history") {
            HistoryView(controller: controller)
        }
        .defaultSize(width: 840, height: 560)
        .windowResizability(.contentMinSize)
    }
}
