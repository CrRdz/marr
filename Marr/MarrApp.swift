import SwiftUI

@main
@MainActor
struct MarrApp: App {
    @StateObject private var controller: MarrController
    @AppStorage("appearance.colorScheme") private var colorScheme = "System"

    init() {
        MarrTypography.registerBundledFonts()

        let controller = MarrController(client: OpenAIClient())
        _controller = StateObject(wrappedValue: controller)
        controller.installHotKeyIfNeeded()
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(controller: controller)
                .preferredColorScheme(preferredColorScheme)
        } label: {
            Image(systemName: "viewfinder")
                .accessibilityLabel("Marr")
        }
        .menuBarExtraStyle(.window)

        Window("Marr Settings", id: "settings") {
            SettingsView(controller: controller)
                .preferredColorScheme(preferredColorScheme)
        }
        .defaultSize(width: 820, height: 580)
        .windowResizability(.contentMinSize)
    }

    private var preferredColorScheme: ColorScheme? {
        switch colorScheme {
        case "Light": .light
        case "Dark": .dark
        default: nil
        }
    }
}
