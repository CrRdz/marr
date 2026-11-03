import AppKit
import SwiftUI

struct AttachmentDropArea: ViewModifier {
    let isEnabled: Bool
    @Binding var isTargeted: Bool
    let tint: Color
    let onDrop: ([URL]) -> Bool
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .overlay {
                AttachmentDropTarget(isEnabled: isEnabled, onDrop: onDrop,
                    onTargetChanged: { isTargeted = $0 })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if isEnabled && isTargeted {
                    RoundedRectangle(cornerRadius: MarrUI.Radius.panel, style: .continuous)
                        .fill(tint.opacity(0.06))
                        .overlay {
                            RoundedRectangle(cornerRadius: MarrUI.Radius.panel, style: .continuous)
                                .strokeBorder(tint, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                        }
                        .overlay {
                            Label("Drop files to attach", marrSymbol: "paperclip")
                                .marrTextStyle(.body, weight: .medium)
                                .foregroundStyle(MarrPanelColors.primary(for: colorScheme))
                                .padding(16)
                                .marrGlassSurface(cornerRadius: 14)
                                .accessibilityElement(children: .combine)
                        }
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { isTargeted = false }
            }
            .onDisappear { isTargeted = false }
    }
}

/// The marker defines the drop region; its native ancestor receives AppKit drags.
/// A mouse-transparent overlay cannot itself be a hit-tested drag destination.
struct AttachmentDropTarget: NSViewRepresentable {
    let isEnabled: Bool
    let onDrop: ([URL]) -> Bool
    let onTargetChanged: (Bool) -> Void

    func makeNSView(context: Context) -> AttachmentDropTargetView { AttachmentDropTargetView() }

    func updateNSView(_ view: AttachmentDropTargetView, context: Context) {
        view.onDrop = onDrop
        view.onTargetChanged = onTargetChanged
        view.isDropEnabled = isEnabled
        view.connectDropContainer()
    }

    static func dismantleNSView(_ view: AttachmentDropTargetView, coordinator: ()) {
        view.isDropEnabled = false
        view.onDrop = nil
        view.onTargetChanged = nil
    }
}

final class AttachmentDropTargetView: NSView {
    var onDrop: (([URL]) -> Bool)?
    var onTargetChanged: ((Bool) -> Void)?
    var isDropEnabled = false {
        didSet {
            guard isDropEnabled != oldValue else { return }
            connectDropContainer()
            if !isDropEnabled { setTargeted(false) }
        }
    }
    private var isTargeted = false
    private weak var dropContainer: AttachmentDropContentView?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        connectDropContainer()
    }

    func connectDropContainer() {
        let container = window?.contentView as? AttachmentDropContentView
        if dropContainer !== container || !isDropEnabled {
            if dropContainer?.attachmentDropTarget === self {
                dropContainer?.attachmentDropTarget = nil
            }
        }
        dropContainer = container
        if isDropEnabled { container?.attachmentDropTarget = self }
    }

    func containsDrop(_ sender: NSDraggingInfo) -> Bool {
        isDropEnabled && !isHiddenOrHasHiddenAncestor
            && window === sender.draggingDestinationWindow
            && visibleRect.contains(convert(sender.draggingLocation, from: nil))
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func accepts(_ sender: NSDraggingInfo) -> Bool {
        isDropEnabled && onDrop != nil && sender.draggingSourceOperationMask.contains(.copy)
            && sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    private func setTargeted(_ value: Bool) {
        guard isTargeted != value else { return }
        isTargeted = value
        onTargetChanged?(value)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let accepted = accepts(sender)
        setTargeted(accepted)
        return accepted ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { setTargeted(false) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { accepts(sender) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setTargeted(false)
        guard accepts(sender) else { return false }
        let urls = AttachmentDropLoader.fileURLs(on: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        return onDrop?(urls) ?? false
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) { setTargeted(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { setTargeted(false) }
}

/// Keep the receiver on the ancestor chain of the actual hit view, so AppKit
/// can find it even over SwiftUI's empty space. Never intercept normal clicks.
class AttachmentDropContentView: NSView {
    weak var attachmentDropTarget: AttachmentDropTargetView? {
        didSet {
            if attachmentDropTarget != nil { registerForDraggedTypes([.fileURL]) }
            else { unregisterDraggedTypes() }
        }
    }

    private func target(for sender: NSDraggingInfo) -> AttachmentDropTargetView? {
        guard let target = attachmentDropTarget, target.containsDrop(sender) else { return nil }
        return target
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let target = target(for: sender) else { return [] }
        return target.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let target = target(for: sender) else {
            attachmentDropTarget?.draggingExited(sender)
            return []
        }
        return target.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        attachmentDropTarget?.draggingExited(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        target(for: sender)?.prepareForDragOperation(sender) ?? false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        target(for: sender)?.performDragOperation(sender) ?? false
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        attachmentDropTarget?.concludeDragOperation(sender)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        attachmentDropTarget?.draggingEnded(sender)
    }
}
