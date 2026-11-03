import AppKit
import Carbon
import MarrCore
import MarrNetworking
import MarrSettings
import SwiftUI

struct CompactGeneralSettingsPanel: View {
    @ObservedObject var controller: MarrController
    @AppStorage(MarrApplicationPreferences.showDockIcon) private var showDockIcon = true
    @State private var runningApplications = RunningApplicationOption.currentOptions
    @State private var shortcutValidationMessage: String?
    @AppStorage(MarrHotKeyConfiguration.keyCodeKey) private var keyCode = Int(kVK_ANSI_0)
    @AppStorage(MarrHotKeyConfiguration.modifiersKey) private var modifiers = Int(cmdKey | shiftKey)
    @AppStorage(MarrHotKeyConfiguration.scopeKey) private var scope = MarrHotKeyScope.global.rawValue
    @AppStorage(MarrHotKeyConfiguration.scopeBundleIDKey) private var scopeBundleID = ""
    @AppStorage(MarrHotKeyConfiguration.scopeAppNameKey) private var scopeAppName = ""

    var body: some View {
        VStack(spacing: MarrSettingsLayout.sectionSpacing) {
            CompactSettingsGroup("Application") {
                CompactSettingsRow("Show Dock icon", systemImage: "app", info: "Marr stays available from the menu bar and keyboard shortcuts when the Dock icon is hidden.") {
                    Toggle("Show Dock icon", isOn: $showDockIcon)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .accessibilityLabel("Show Dock icon")
                        .accessibilityHint("When off, Marr remains available from the menu bar and keyboard shortcuts.")
                }
            }

            CompactSettingsGroup("Shortcuts") {
                CompactSettingsRow("Area", systemImage: "viewfinder") {
                    HotKeyRecorder(
                        keyCode: $keyCode,
                        modifiers: $modifiers,
                        onValidation: { shortcutValidationMessage = $0 },
                        onChange: saveShortcut
                    )
                    .frame(width: 126, height: 28)
                }

                if let shortcutValidationMessage {
                    Label(shortcutValidationMessage, marrSymbol: "exclamationmark.circle")
                        .marrTextStyle(.secondary)
                        .foregroundStyle(MarrUI.Status.error.color())
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                }
            }

            CompactSettingsGroup("Availability") {
                CompactSettingsRow("Use in", systemImage: "scope") {
                    Picker("Shortcut availability", selection: scopeBinding) {
                        ForEach(MarrHotKeyScope.allCases) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 154, alignment: .trailing)
                }

                if MarrHotKeyScope(rawValue: scope) == .frontmostApplication {
                    CompactSettingsDivider()

                    CompactSettingsRow("App", systemImage: "app") {
                        Picker("Capture application", selection: applicationBinding) {
                            ForEach(applicationOptions) { app in
                                Text(app.title).tag(app.bundleID)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(width: 174, alignment: .trailing)
                    }
                    .onAppear(perform: refreshRunningApplications)
                }
            }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            refreshRunningApplications()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            refreshRunningApplications()
        }
    }

    private var applicationOptions: [RunningApplicationOption] {
        RunningApplicationOption.includingSavedApplication(
            in: runningApplications, bundleID: scopeBundleID, name: scopeAppName
        )
    }

    private var scopeBinding: Binding<String> {
        Binding(
            get: { scope },
            set: { nextValue in
                scope = nextValue
                if MarrHotKeyScope(rawValue: nextValue) == .frontmostApplication, scopeBundleID.isEmpty {
                    refreshRunningApplications()
                    if let first = runningApplications.first {
                        scopeBundleID = first.bundleID
                        scopeAppName = first.name
                    }
                }
                saveShortcut()
            }
        )
    }

    private var applicationBinding: Binding<String> {
        Binding(
            get: { scopeBundleID },
            set: { nextValue in
                scopeBundleID = nextValue
                scopeAppName = applicationOptions.first { $0.bundleID == nextValue }?.name ?? nextValue
                saveShortcut()
            }
        )
    }

    private func refreshRunningApplications() {
        runningApplications = RunningApplicationOption.currentOptions
    }

    private func saveShortcut() {
        MarrHotKeyConfiguration(
            keyCode: UInt32(keyCode),
            modifiers: UInt32(modifiers),
            scope: MarrHotKeyScope(rawValue: scope) ?? .global,
            scopeBundleID: scopeBundleID,
            scopeAppName: scopeAppName
        ).save()
        controller.reloadHotKey()
    }


}
