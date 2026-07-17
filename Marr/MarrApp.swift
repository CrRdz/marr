import AppKit
import MarrNetworking
import SwiftUI

@main
@MainActor
struct MarrApp: App {
    @NSApplicationDelegateAdaptor(MarrAppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Marr Settings", id: "marr-settings") {
            SettingsView(controller: appDelegate.controller)
                .marrPreferredColorScheme()
        }
        .defaultSize(width: 820, height: 580)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .keyboardShortcut(",", modifiers: .command)
    }
}

@MainActor
final class MarrAppDelegate: NSObject, NSApplicationDelegate {
    let controller: MarrController

    private var didBootstrapApplication = false
    private var statusItem: NSStatusItem?

    override init() {
        MarrTypography.registerBundledFonts()
        controller = MarrController(client: OpenAIClient())
        super.init()
        let environment = ProcessInfo.processInfo.environment
        let isRunningTests = environment["XCTestConfigurationFilePath"] != nil
            || environment["XCInjectBundleInto"] != nil
        if !isRunningTests {
            DispatchQueue.main.async { [weak self] in
                self?.bootstrapApplicationIfNeeded()
            }
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        bootstrapApplicationIfNeeded()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        bootstrapApplicationIfNeeded()
    }

    private func bootstrapApplicationIfNeeded() {
        guard !didBootstrapApplication else { return }
        didBootstrapApplication = true

        ProcessInfo.processInfo.disableAutomaticTermination("Marr runs from the menu bar")
        installStatusItem()
        controller.installHotKeyIfNeeded()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func installStatusItem() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.marr.Marr"
        item.autosaveName = "\(bundleIdentifier).statusItem.v2"
        item.behavior = []
        item.isVisible = true
        if let button = item.button {
            let image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "Marr")
                ?? NSImage(systemSymbolName: "camera", accessibilityDescription: "Marr")
            image?.isTemplate = true
            button.image = image
            button.title = image == nil ? "M" : ""
            button.toolTip = "Marr"
            button.target = self
            button.action = #selector(startCapture(_:))
        }

        statusItem = item
    }

    @objc
    private func startCapture(_ sender: Any?) {
        controller.startScreenCapture()
    }
}
