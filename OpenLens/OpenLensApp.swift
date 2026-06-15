import SwiftUI

@main
struct OpenLensApp: App {
    @StateObject private var controller = OpenLensController(client: OpenAIClient())

    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller)
                .onAppear {
                    controller.installHotKeyIfNeeded()
                }
        }
        .windowResizability(.contentMinSize)
    }
}
