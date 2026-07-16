import AppKit
import MarrNetworking
import SwiftUI

@main
@MainActor
struct MarrApp: App {
    @NSApplicationDelegateAdaptor(MarrAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class MarrAppDelegate: NSObject, NSApplicationDelegate {
    let controller: MarrController

    private var didBootstrapApplication = false
    private var statusItem: NSStatusItem?
    private var menuPopover: NSPopover?
    private var settingsWindowController: NSWindowController?

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
        item.autosaveName = "MarrStatusItem"
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
            button.action = #selector(toggleMenuPopover(_:))
        }

        statusItem = item
    }

    @objc
    private func toggleMenuPopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }

        let popover = menuPopover ?? makeMenuPopover()
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func makeMenuPopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 220, height: 136)
        popover.contentViewController = NSHostingController(
            rootView: ContentView(
                controller: controller,
                openSettings: { [weak self] in self?.showSettings() },
                quit: { NSApp.terminate(nil) }
            )
            .marrPreferredColorScheme()
        )
        menuPopover = popover
        return popover
    }

    private func showSettings() {
        menuPopover?.performClose(nil)

        let windowController = settingsWindowController ?? makeSettingsWindowController()
        guard let window = windowController.window else { return }

        windowController.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeSettingsWindowController() -> NSWindowController {
        let hostingController = NSHostingController(
            rootView: SettingsView(controller: controller)
                .marrPreferredColorScheme()
        )
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Marr Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 820, height: 580))
        window.minSize = NSSize(width: 760, height: 520)
        window.isReleasedWhenClosed = false
        window.center()

        let windowController = NSWindowController(window: window)
        settingsWindowController = windowController
        return windowController
    }
}
