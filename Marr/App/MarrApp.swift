import AppKit
import MarrCore
import MarrNetworking
import SwiftUI

enum MarrApplicationPreferences {
    static let showDockIcon = "marrShowDockIcon"
}

@main
@MainActor
private enum MarrApplication {
    static func main() {
        if NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["MARR_TEST_HOST"] == "1" {
            MarrTestHostApp.main()
        } else {
            do { try MarrStorage.importLegacyPreferences() }
            catch {
                let alert = NSAlert()
                alert.messageText = "Could not load existing Marr settings"
                alert.informativeText = "Your saved data was kept. \(error.localizedDescription)"
                alert.runModal()
                return
            }
            if #available(macOS 15.0, *) { MarrModernApp.main() }
            else { MarrLegacyApp.main() }
        }
    }
}

/// A settings-only scene has no launch window, including on macOS 14 where
/// defaultLaunchBehavior(.suppressed) is unavailable. Fixtures opt into their
/// own windows; the host never installs app-level hotkeys or status items.
@MainActor
private struct MarrTestHostApp: App {
    init() { MarrTypography.registerBundledFonts() }
    var body: some Scene { Settings { EmptyView() } }
}

@available(macOS 15.0, *)
@MainActor
private struct MarrModernApp: App {
    @NSApplicationDelegateAdaptor(MarrAppDelegate.self) private var appDelegate

    var body: some Scene {
        MarrLifecycleScene()
            .defaultLaunchBehavior(.suppressed)
    }
}

@MainActor
private struct MarrLegacyApp: App {
    @NSApplicationDelegateAdaptor(MarrAppDelegate.self) private var appDelegate

    var body: some Scene {
        MarrLifecycleScene()
    }
}

private struct MarrLifecycleScene: Scene {
    var body: some Scene {
        Window("Marr", id: "marr-lifecycle") {
            EmptyView()
        }
        .defaultSize(width: 1, height: 1)
    }
}

@MainActor
final class MarrAppDelegate: NSObject, NSApplicationDelegate {
    let controller: MarrController

    private var welcomeWindowController: MarrWelcomeWindowController?
    private var didBootstrapApplication = false
    private var statusItem: NSStatusItem?
    private var pendingStatusClick: DispatchWorkItem?
    private var dockPreferenceObserver: NSObjectProtocol?
    private var dockIconView: NSImageView?
#if DEBUG
    private var componentGalleryWindow: NSWindow?
#endif

    override init() {
        MarrTypography.registerBundledFonts()
        controller = MarrController(client: InferenceClient())
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        suppressLegacyInitialSettingsWindow()
        DispatchQueue.main.async { [weak self] in
            self?.bootstrapApplicationIfNeeded()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let dockPreferenceObserver {
            NotificationCenter.default.removeObserver(dockPreferenceObserver)
            self.dockPreferenceObserver = nil
        }
        controller.personalAgent.shutdown()
        controller.codexWorkspace.shutdown()
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let welcomeWindowController, welcomeWindowController.window?.isVisible == true
            || welcomeWindowController.window?.isMiniaturized == true {
            welcomeWindowController.present()
        } else {
            controller.restoreMainWindow()
        }
        return false
    }

    private func suppressLegacyInitialSettingsWindow() {
        guard #unavailable(macOS 15.0) else { return }

        orderOutInitialWindows()
        DispatchQueue.main.async { [weak self] in
            self?.orderOutInitialWindows()
        }
    }

    private func orderOutInitialWindows() {
        NSApp.windows
            .filter { $0.level == .normal }
            .forEach { $0.orderOut(nil) }
    }

    private func bootstrapApplicationIfNeeded() {
        guard !didBootstrapApplication else { return }
        didBootstrapApplication = true

        // Hosted unit tests do not need a menu-bar item or global hotkeys.
        // Visible fixture windows are separately and explicitly opted into.
        guard NSClassFromString("XCTestCase") == nil,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

        ProcessInfo.processInfo.disableAutomaticTermination("Marr stays available from the menu bar and Dock")
        installStatusItem()
        observeDockIconPreference()
        controller.installHotKeyIfNeeded()
        controller.personalAgent.startScheduler()
        if !MarrWelcomeProgress().isComplete { showWelcome() }
    }

    private func observeDockIconPreference() {
        UserDefaults.standard.register(defaults: [MarrApplicationPreferences.showDockIcon: true])
        updateDockIconVisibility()
        dockPreferenceObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateDockIconVisibility()
            }
        }
    }

    private func updateDockIconVisibility() {
        let showsIcon = UserDefaults.standard.bool(forKey: MarrApplicationPreferences.showDockIcon)
        let policy: NSApplication.ActivationPolicy = showsIcon ? .regular : .accessory
        let policyChanged = NSApp.activationPolicy() != policy
        if policyChanged { NSApp.setActivationPolicy(policy) }
        if showsIcon && (policyChanged || dockIconView == nil) {
            installCircularDockIcon()
        }
    }

    private func installCircularDockIcon() {
        if dockIconView == nil {
            // Read the ICNS pixels directly. The macOS 26 application-icon
            // renderer otherwise places transparent artwork on a square tile.
            guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
                  let image = NSImage(contentsOf: url) else { return }
            let view = NSImageView(frame: NSRect(origin: .zero, size: NSApp.dockTile.size))
            view.autoresizingMask = [.width, .height]
            view.image = image
            view.imageScaling = .scaleProportionallyUpOrDown
            view.imageAlignment = .alignCenter
            dockIconView = view
        }
        NSApp.dockTile.contentView = dockIconView
        NSApp.dockTile.display()
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
            let image = NSImage(named: "MarrStatusIcon")?.copy() as? NSImage
            image?.size = NSSize(width: 18, height: 18)
            image?.isTemplate = false
            image?.accessibilityDescription = "Marr"
            button.image = image
            button.title = image == nil ? "M" : ""
            button.toolTip = "Marr"
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        statusItem = item
    }

    @objc
    private func handleStatusItemClick(_ sender: Any?) {
        pendingStatusClick?.cancel()
        pendingStatusClick = nil
        if let event = NSApp.currentEvent,
           MarrStatusItemInteraction.opensMenu(type: event.type, clickCount: event.clickCount, modifiers: event.modifierFlags) {
            showStatusItemMenu()
            return
        }
        let click = DispatchWorkItem { [weak self] in
            self?.controller.startScreenCapture()
        }
        pendingStatusClick = click
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: click)
    }

    private func showStatusItemMenu() {
        guard let item = statusItem, let button = item.button else { return }

        let menu = NSMenu()
        menu.minimumWidth = 220
        menu.autoenablesItems = false
        menu.font = MarrTypography.menuFont
        menu.addItem(statusMenuItem(
            title: "New Conversation",
            action: #selector(newConversation),
            systemImage: "square.and.pencil"
        ))
        let newWorkItem = statusMenuItem(
            title: "New Work",
            action: #selector(newWork),
            systemImage: "hammer"
        )
        newWorkItem.isEnabled = !controller.codexWorkspace.isRunning
        menu.addItem(newWorkItem)
        menu.addItem(.separator())
        menu.addItem(statusMenuItem(
            title: "History",
            action: #selector(showHistory),
            systemImage: "clock.arrow.circlepath"
        ))
        menu.addItem(statusMenuItem(
            title: "Settings",
            action: #selector(showSettings),
            systemImage: "gearshape"
        ))
        menu.addItem(statusMenuItem(
            title: "Welcome to Marr",
            action: #selector(showWelcome),
            systemImage: "sparkles"
        ))
#if DEBUG
        menu.addItem(statusMenuItem(
            title: "Component Gallery (Debug)",
            action: #selector(showComponentGallery),
            systemImage: "square.grid.2x2"
        ))
#endif
        menu.addItem(.separator())
        menu.addItem(statusMenuItem(
            title: "Quit Marr",
            action: #selector(quitMarr),
            systemImage: "power"
        ))

        // Let the status bar track and anchor its own menu, including display
        // edges and menu-bar scaling. A generic view popup drifts when AppKit
        // flips or clamps that manually offset point.
        item.menu = menu
        defer { item.menu = nil }
        button.performClick(nil)
    }

    private func statusMenuItem(
        title: String,
        action: Selector,
        systemImage: String?
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let systemImage {
            item.image = MarrIcons.image(
                named: systemImage,
                accessibilityDescription: nil
            )
            item.image?.size = NSSize(width: 16, height: 16)
        }
        return item
    }

    @objc
    private func showWelcome() {
        if let welcomeWindowController, welcomeWindowController.window?.isVisible == true
            || welcomeWindowController.window?.isMiniaturized == true {
            welcomeWindowController.present()
            return
        }
        let welcome = MarrWelcomeWindowController(controller: controller)
        welcomeWindowController = welcome
        welcome.present()
    }

    @objc
    private func newConversation() {
        controller.startNewConversation()
    }

    @objc
    private func newWork() {
        controller.startNewConversation(work: true)
    }

    @objc
    private func showHistory() {
        controller.showAnswerPanelUtility(.history)
    }

    @objc
    private func showSettings() {
        controller.showAnswerPanelUtility(.settings)
    }

#if DEBUG
    @objc
    private func showComponentGallery() {
        if componentGalleryWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 760),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Marr Component Gallery"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: MarrComponentGallery())
            window.center()
            componentGalleryWindow = window
        }
        componentGalleryWindow?.makeKeyAndOrderFront(nil)
    }
#endif

    @objc
    private func quitMarr() {
        NSApp.terminate(nil)
    }
}

/// Keep secondary-click gestures out of the delayed capture action.
enum MarrStatusItemInteraction {
    static func opensMenu(type: NSEvent.EventType, clickCount: Int, modifiers: NSEvent.ModifierFlags) -> Bool {
        type == .rightMouseUp || clickCount > 1 || modifiers.contains(.control)
    }
}
