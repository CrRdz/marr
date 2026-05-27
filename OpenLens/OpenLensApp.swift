import SwiftUI

@main
struct OpenLensApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView(client: OpenAIClient())
                .frame(minWidth: 760, minHeight: 720)
        }
        .windowResizability(.contentMinSize)
    }
}
