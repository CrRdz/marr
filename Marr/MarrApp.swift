import AppKit
import MarrNetworking
import SwiftUI

@main
@MainActor
private enum MarrApplication {
    static func main() {
        if #available(macOS 15.0, *) {
            MarrModernApp.main()
        } else {
            MarrLegacyApp.main()
        }
    }
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

    private var didBootstrapApplication = false
    private var statusItem: NSStatusItem?
    private var pendingStatusClick: DispatchWorkItem?

    override init() {
        MarrTypography.registerBundledFonts()
        controller = MarrController(client: OpenAIClient(), usesCodexForConversation: true)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        suppressLegacyInitialSettingsWindow()
        DispatchQueue.main.async { [weak self] in
            self?.bootstrapApplicationIfNeeded()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
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
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        statusItem = item
    }

    @objc
    private func handleStatusItemClick(_ sender: Any?) {
        pendingStatusClick?.cancel()
        if NSApp.currentEvent?.type == .rightMouseUp || (NSApp.currentEvent?.clickCount ?? 0) > 1 {
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
        guard let button = statusItem?.button else { return }

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
        menu.addItem(.separator())
        menu.addItem(statusMenuItem(
            title: "Quit Marr",
            action: #selector(quitMarr),
            systemImage: "power"
        ))

        menu.popUp(
            positioning: nil,
            at: NSPoint(x: button.bounds.minX, y: button.isFlipped ? button.bounds.maxY + 4 : button.bounds.minY - 4),
            in: button
        )
    }

    private func statusMenuItem(
        title: String,
        action: Selector,
        systemImage: String?
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        let symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 14,
            weight: .regular
        )
        if let systemImage {
            item.image = NSImage(
                systemSymbolName: systemImage,
                accessibilityDescription: nil
            )?.withSymbolConfiguration(symbolConfiguration)
            item.image?.size = NSSize(width: 16, height: 16)
        }
        return item
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

    @objc
    private func quitMarr() {
        NSApp.terminate(nil)
    }
}
