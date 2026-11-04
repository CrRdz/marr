import AppKit
import SwiftUI

/// Imagegen artwork, packaged as template images. Semantic aliases keep state
/// models independent of the artwork and give SwiftUI and AppKit one icon set.
enum MarrIcons {
    static let aliases: [String: String] = [
        "app": "window",
        "archivebox": "archive",
        "arrow.clockwise": "refresh",
        "arrow.down": "arrow-down",
        "arrow.left.arrow.right": "exchange",
        "arrow.triangle.branch": "branch",
        "arrow.up": "arrow-up",
        "arrow.up.right": "arrow-diagonal",
        "arrow.up.right.square": "external-link",
        "arrow.uturn.backward": "return",
        "at": "at",
        "bubble.left": "chat",
        "bubble.left.and.text.bubble.right": "chats",
        "bubble.left.fill": "chat",
        "camera": "camera",
        "camera.viewfinder": "capture",
        "character": "translate",
        "chart.bar": "usage",
        "checklist": "checklist",
        "checkmark": "check",
        "checkmark.circle": "success",
        "checkmark.circle.fill": "success",
        "chevron.down": "chevron-down",
        "chevron.left": "chevron-left",
        "chevron.left.forwardslash.chevron.right": "code",
        "chevron.right": "chevron-right",
        "circle": "radio",
        "circle.dotted": "loading",
        "circle.fill": "radio-selected",
        "circle.lefthalf.filled": "appearance",
        "clear": "close",
        "clock": "clock",
        "clock.arrow.circlepath": "history",
        "command": "command",
        "cpu": "cpu",
        "desktopcomputer": "monitor",
        "doc": "document",
        "doc.badge.gearshape": "document-settings",
        "doc.badge.plus": "document-add",
        "doc.on.doc": "copy",
        "doc.richtext": "document",
        "doc.text": "document",
        "doc.text.magnifyingglass": "document-search",
        "doc.text.viewfinder": "capture",
        "ellipsis": "more",
        "ellipsis.circle.fill": "more",
        "eraser": "eraser",
        "exclamationmark": "warning",
        "exclamationmark.circle": "warning",
        "exclamationmark.triangle": "warning",
        "exclamationmark.triangle.fill": "warning",
        "folder": "folder",
        "folder.badge.plus": "folder-add",
        "folder.fill": "folder",
        "gearshape": "settings",
        "globe": "globe",
        "hammer": "hammer",
        "hand.raised": "approval",
        "hand.raised.fill": "approval",
        "info.circle": "info",
        "largecircle.fill.circle": "radio-selected",
        "lightbulb": "bulb",
        "lightbulb.slash": "bulb-off",
        "link": "link",
        "list.bullet.clipboard": "checklist",
        "list.bullet.rectangle": "checklist",
        "list.number": "list",
        "lock": "privacy",
        "macwindow": "window",
        "magnifyingglass": "search",
        "memories": "history",
        "message": "chat",
        "minus": "minus",
        "minus.circle": "minus-circle",
        "minus.magnifyingglass": "zoom-out",
        "moon": "moon",
        "network": "globe",
        "number": "hash",
        "number.circle": "hash",
        "paperclip": "attachment",
        "paragraph": "text",
        "pause": "pause",
        "pencil": "edit",
        "pencil.tip": "pen",
        "person.2": "people",
        "person.crop.circle": "profile",
        "person.fill": "profile",
        "photo": "image",
        "photo.badge.exclamationmark": "image",
        "pin": "pin",
        "pin.fill": "pin",
        "plus": "plus",
        "plus.magnifyingglass": "zoom-in",
        "point.3.connected.trianglepath.dotted": "branch",
        "power": "power",
        "puzzlepiece.extension": "puzzle",
        "questionmark.bubble": "question-chat",
        "questionmark.circle": "question",
        "rectangle": "rectangle",
        "rectangle.on.rectangle": "copy",
        "rectangle.split.2x1": "split",
        "scope": "target",
        "shippingbox": "package",
        "sidebar.left": "sidebar",
        "slider.horizontal.3": "sliders",
        "sparkle": "sparkle",
        "sparkles": "sparkle",
        "square.and.arrow.up": "export",
        "square.and.pencil": "compose",
        "square.grid.2x2": "grid",
        "square.stack": "layers",
        "square.stack.3d.up": "layers",
        "stop": "stop",
        "stop.circle": "stop",
        "stop.fill": "stop",
        "sun.max": "sun",
        "switch.2": "switches",
        "tablecells": "table",
        "target": "target",
        "terminal": "terminal",
        "text.alignleft": "text",
        "text.bubble": "chat",
        "text.magnifyingglass": "search",
        "text.word.spacing": "text",
        "translate": "translate",
        "trash": "trash",
        "viewfinder": "capture",
        "wrench": "wrench",
        "xmark": "close",
        "xmark.circle.fill": "failure",
    ]

    @MainActor private static var viewImages: [String: Image] = [:]

    @MainActor
    static func viewImage(named symbol: String, size: CGFloat) -> Image {
        let key = (aliases[symbol] ?? "question") + ":" + String(Double(size))
        if let cached = viewImages[key] { return cached }
        // Native menu labels use the image's intrinsic size, ignoring SwiftUI
        // frame modifiers. Cache one correctly sized image per glyph/role.
        let rendered = Image(nsImage: image(named: symbol, size: size) ?? NSImage(size: NSSize(width: size, height: size)))
            .renderingMode(.template)
        viewImages[key] = rendered
        return rendered
    }

    static func image(named symbol: String, size: CGFloat = 16,
                      accessibilityDescription: String? = nil) -> NSImage? {
        // NSImage(named:) caches the asset. A shallow copy changes only this
        // presentation's logical size; no file I/O or bitmap conversion on hover.
        let asset = aliases[symbol] ?? "question"
        guard let source = NSImage(named: "MarrIcon-" + asset),
              let image = source.copy() as? NSImage else { return nil }
        image.size = NSSize(width: size, height: size)
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
    }
}

private struct MarrIconSizeKey: EnvironmentKey {
    static let defaultValue = MarrUI.Icon.inline
}

extension EnvironmentValues {
    var marrIconSize: CGFloat {
        get { self[MarrIconSizeKey.self] }
        set { self[MarrIconSizeKey.self] = newValue }
    }
}

/// Asset images don't inherit SF Symbol font sizing. This view gives them one
/// explicit, environment-driven geometry and reuses cached images in lists.
struct MarrIcon: View {
    let symbol: String
    var size: CGFloat? = nil
    @Environment(\.marrIconSize) private var inheritedSize

    init(_ symbol: String, size: CGFloat? = nil) {
        self.symbol = symbol
        self.size = size
    }

    var body: some View {
        MarrIcons.viewImage(named: symbol, size: size ?? inheritedSize)
            .resizable()
            .interpolation(.high)
            .frame(width: size ?? inheritedSize, height: size ?? inheritedSize)
            .accessibilityHidden(true)
    }
}

extension Label where Title == Text, Icon == MarrIcon {
    init<S: StringProtocol>(_ title: S, marrSymbol: String) {
        self.init { Text(String(title)) } icon: { MarrIcon(marrSymbol) }
    }
}

extension Button where Label == SwiftUI.Label<Text, MarrIcon> {
    init<S: StringProtocol>(_ title: S, marrSymbol: String, action: @escaping () -> Void) {
        self.init(action: action) { SwiftUI.Label(title, marrSymbol: marrSymbol) }
    }
}

extension Menu where Label == SwiftUI.Label<Text, MarrIcon> {
    init<S: StringProtocol>(_ title: S, marrSymbol: String, @ViewBuilder content: () -> Content) {
        self.init(content: content) { SwiftUI.Label(title, marrSymbol: marrSymbol) }
    }
}
