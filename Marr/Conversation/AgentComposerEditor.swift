import AppKit
import SwiftUI

enum AgentComposerKey: Equatable { case up, down, complete, accept, dismiss }

/// A native editor keeps completion at the insertion point and leaves marked
/// text to the input method. SwiftUI's multiline TextField hides both states.
struct AgentComposerEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    @Binding var focused: Bool
    let placeholder: String
    var onKey: (AgentComposerKey) -> Bool
    var onSubmit: () -> Void
    var onFileDrop: (([URL]) -> Bool)? = nil
    var onFileDragTargetChanged: ((Bool) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        let editor = AgentInputTextView()
        editor.isRichText = false
        editor.drawsBackground = false
        editor.isEditable = true
        editor.isSelectable = true
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainerInset = NSSize(width: 0, height: 5)
        editor.font = .systemFont(ofSize: MarrTypography.Role.answer.size)
        editor.textColor = .labelColor
        editor.insertionPointColor = .labelColor
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.allowsUndo = true
        editor.registerForDraggedTypes([.fileURL])
        editor.delegate = context.coordinator
        editor.requestedFocus = { [weak coordinator = context.coordinator] in
            coordinator?.parent.focused ?? false
        }
        editor.onWindowAttachmentChanged = { [weak coordinator = context.coordinator] isAttached in
            coordinator?.isAttached = isAttached
        }
        editor.setAccessibilityLabel("Work message")
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? AgentInputTextView else { return }
        context.coordinator.parent = self
        context.coordinator.updating = true
        editor.placeholder = placeholder
        editor.onKey = onKey
        editor.onSubmit = onSubmit
        editor.onFileDrop = onFileDrop
        editor.onFileDragTargetChanged = onFileDragTargetChanged
        if !editor.hasMarkedText() {
            if editor.string != text { editor.string = text }
            let location = min(selection.location, (text as NSString).length)
            let length = min(selection.length, (text as NSString).length - location)
            let range = NSRange(location: location, length: length)
            if editor.selectedRange() != range { editor.setSelectedRange(range) }
        }
        editor.needsDisplay = true
        editor.applyRequestedFocus()
        context.coordinator.updating = false
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.isAttached = false
        guard let editor = scroll.documentView as? AgentInputTextView else { return }
        editor.delegate = nil
        editor.requestedFocus = nil
        editor.onWindowAttachmentChanged = nil
        editor.onKey = nil
        editor.onSubmit = nil
        editor.onFileDrop = nil
        editor.onFileDragTargetChanged = nil
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? 400
        guard let editor = nsView.documentView as? NSTextView,
              let container = editor.textContainer, let layout = editor.layoutManager else {
            return CGSize(width: width, height: 30)
        }
        container.containerSize = NSSize(width: max(40, width), height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: min(94, max(30, ceil(layout.usedRect(for: container).height) + 10)))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AgentComposerEditor
        var updating = false
        var isAttached = false
        init(_ parent: AgentComposerEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard !updating, let editor = notification.object as? AgentInputTextView else { return }
            parent.text = editor.string
            parent.selection = editor.selectedRange()
            editor.needsDisplay = true
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !updating, let editor = notification.object as? AgentInputTextView else { return }
            parent.selection = editor.selectedRange()
        }
        func textDidBeginEditing(_ notification: Notification) {
            if !updating, isAttached { parent.focused = true }
        }
        func textDidEndEditing(_ notification: Notification) {
            guard !updating, isAttached, let editor = notification.object as? AgentInputTextView else { return }
            // AppKit can emit this before updating firstResponder. An outgoing
            // editor must not clear the replacement composer's shared binding.
            DispatchQueue.main.async { [weak self, weak editor] in
                guard let self, let editor, self.isAttached, !self.updating,
                      let window = editor.window,
                      window.firstResponder !== editor,
                      !(window.firstResponder is AgentInputTextView) else { return }
                self.parent.focused = false
            }
        }
    }
}

final class AgentInputTextView: NSTextView {
    var placeholder = ""
    var onKey: ((AgentComposerKey) -> Bool)?
    var onSubmit: (() -> Void)?
    var onFileDrop: (([URL]) -> Bool)?
    var onFileDragTargetChanged: ((Bool) -> Void)?
    var requestedFocus: (() -> Bool)?
    var onWindowAttachmentChanged: ((Bool) -> Void)?

    private func handlesFileDrag(_ sender: NSDraggingInfo) -> Bool {
        onFileDrop != nil && sender.draggingPasteboard.types?.contains(.fileURL) == true
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard handlesFileDrag(sender) else { return super.draggingEntered(sender) }
        let acceptsCopy = sender.draggingSourceOperationMask.contains(.copy)
        onFileDragTargetChanged?(acceptsCopy)
        return acceptsCopy ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard handlesFileDrag(sender) else { return super.draggingUpdated(sender) }
        return draggingEntered(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onFileDragTargetChanged?(false)
        super.draggingExited(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if handlesFileDrag(sender) { return sender.draggingSourceOperationMask.contains(.copy) }
        return super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard handlesFileDrag(sender) else { return super.performDragOperation(sender) }
        onFileDragTargetChanged?(false)
        let urls = AttachmentDropLoader.fileURLs(on: sender.draggingPasteboard)
        guard !urls.isEmpty, sender.draggingSourceOperationMask.contains(.copy) else { return false }
        return onFileDrop?(urls) ?? false
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        onFileDragTargetChanged?(false)
        // AppKit's text insertion path is bypassed for file attachments.
        if let sender, handlesFileDrag(sender) { return }
        super.concludeDragOperation(sender)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { onWindowAttachmentChanged?(false) }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowAttachmentChanged?(window != nil)
        applyRequestedFocus()
    }

    func applyRequestedFocus() {
        guard let window, let requestedFocus else { return }
        if requestedFocus() {
            if window.firstResponder !== self { window.makeFirstResponder(self) }
        } else if window.firstResponder === self {
            window.makeFirstResponder(nil)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            (placeholder as NSString).draw(at: NSPoint(x: textContainerInset.width, y: textContainerInset.height),
                withAttributes: [.font: font ?? NSFont.systemFont(ofSize: MarrTypography.Role.answer.size), .foregroundColor: NSColor.placeholderTextColor])
        }
    }

    override func keyDown(with event: NSEvent) {
        // Return/Escape and arrow keys must first belong to an active IME.
        if hasMarkedText() { super.keyDown(with: event); return }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let plain = modifiers.intersection([.command, .control, .option, .shift]).isEmpty
        switch event.keyCode {
        case 126 where plain: if onKey?(.up) == true { return }
        case 125 where plain: if onKey?(.down) == true { return }
        case 48 where plain: if onKey?(.complete) == true { return }
        case 53 where plain: if onKey?(.dismiss) == true { return }
        case 36, 76:
            if modifiers.contains(.shift) || modifiers.contains(.option) {
                insertNewlineIgnoringFieldEditor(self)
                return
            }
            if plain, onKey?(.accept) == true { return }
            if plain || modifiers.contains(.command) { onSubmit?(); return }
        default: break
        }
        super.keyDown(with: event)
    }
}
