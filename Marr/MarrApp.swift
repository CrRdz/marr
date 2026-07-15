import MarrNetworking
import SwiftUI

@main
@MainActor
struct MarrApp: App {
    @StateObject private var controller: MarrController

    init() {
        MarrTypography.registerBundledFonts()

        let controller = MarrController(client: OpenAIClient())
        _controller = StateObject(wrappedValue: controller)
        controller.installHotKeyIfNeeded()
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(controller: controller)
                .marrPreferredColorScheme()
        } label: {
            Image(systemName: "viewfinder")
                .accessibilityLabel("Marr")
        }
        .menuBarExtraStyle(.window)

        Window("Marr Settings", id: "settings") {
            SettingsView(controller: controller)
                .marrPreferredColorScheme()
        }
        .defaultSize(width: 820, height: 580)
        .windowResizability(.contentMinSize)
    }
}
