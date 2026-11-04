import AppKit
import Carbon
import MarrCore
import MarrNetworking
import MarrSettings
import SwiftUI

struct RunningApplicationOption: Identifiable, Hashable {
    let bundleID: String
    let name: String
    var isRunning = true

    var id: String { bundleID }
    var title: String { isRunning ? name : "\(name) (Not running)" }

    static func includingSavedApplication(
        in running: [RunningApplicationOption], bundleID: String, name: String
    ) -> [RunningApplicationOption] {
        guard !bundleID.isEmpty, !running.contains(where: { $0.bundleID == bundleID }) else { return running }
        let saved = RunningApplicationOption(
            bundleID: bundleID, name: name.isEmpty ? bundleID : name, isRunning: false
        )
        return (running + [saved]).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static var currentOptions: [RunningApplicationOption] {
        let options = NSWorkspace.shared.runningApplications.compactMap { app -> RunningApplicationOption? in
            guard
                app.activationPolicy == .regular,
                let bundleID = app.bundleIdentifier,
                !bundleID.isEmpty
            else {
                return nil
            }

            return RunningApplicationOption(
                bundleID: bundleID,
                name: app.localizedName ?? bundleID
            )
        }

        return Array(Dictionary(grouping: options, by: \.bundleID).compactMap { _, grouped in
            grouped.first
        })
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

struct HotKeyRecorder: NSViewRepresentable {
    @Binding var keyCode: Int
    @Binding var modifiers: Int
    var conflictingKeyCode: Int? = nil
    var conflictingModifiers: Int? = nil
    var conflictingAction: String = "another action"
    let onValidation: (String?) -> Void
    let onChange: () -> Void

    func makeNSView(context: Context) -> HotKeyRecorderView {
        let view = HotKeyRecorderView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: HotKeyRecorderView, context: Context) {
        configure(nsView)
    }

    private func configure(_ nsView: HotKeyRecorderView) {
        nsView.displayString = HotKeyFormatter.displayString(
            keyCode: UInt32(keyCode),
            modifiers: UInt32(modifiers)
        )
        // Validate before either binding writes to AppStorage. Replacing this
        // callback on every update also tracks edits to the other shortcut.
        nsView.onRecord = { keyCode, modifiers in
            if let conflictingKeyCode, let conflictingModifiers,
               Int(keyCode) == conflictingKeyCode, Int(modifiers) == conflictingModifiers {
                let shortcut = HotKeyFormatter.displayString(keyCode: keyCode, modifiers: modifiers)
                onValidation("\(shortcut) is already used for \(conflictingAction). Choose a different shortcut.")
                return
            }
            onValidation(nil)
            self.keyCode = Int(keyCode)
            self.modifiers = Int(modifiers)
            onChange()
        }
    }
}

final class HotKeyRecorderView: NSButton, HotKeyRecording {
    var onRecord: ((UInt32, UInt32) -> Void)?
    var displayString = "" {
        didSet {
            if !isRecording {
                title = displayString
            }
        }
    }

    private var isRecording = false

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(beginRecording)
        focusRingType = .default
        title = displayString
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    @objc private func beginRecording() {
        isRecording = true
        title = "Press keys"
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        if event.keyCode == UInt16(kVK_Escape) {
            isRecording = false
            title = displayString
            window?.makeFirstResponder(nil)
            return
        }

        let carbonModifiers = HotKeyFormatter.carbonModifiers(from: event.modifierFlags)
        guard carbonModifiers != 0 else {
            NSSound.beep()
            return
        }

        _ = recordHotKey(keyCode: UInt32(event.keyCode), modifiers: carbonModifiers)
    }

    func recordHotKey(keyCode: UInt32, modifiers: UInt32) -> Bool {
        guard isRecording else { return false }
        isRecording = false
        onRecord?(keyCode, modifiers)
        title = displayString
        window?.makeFirstResponder(nil)
        return true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        title = displayString
        return super.resignFirstResponder()
    }
}
