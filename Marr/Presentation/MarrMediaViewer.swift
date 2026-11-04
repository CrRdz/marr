import AppKit
import ImageIO
import MarrCore
import SwiftUI
import UniformTypeIdentifiers

/// A viewer item keeps its original source. Remote images are fetched only after
/// the user opens the viewer; a gallery never eagerly decodes all its images.
struct MarrMediaItem: Identifiable, Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case data(Data)
        case dataURL(String)
        case url(URL)
    }

    let id: String
    let label: String
    let source: Source

    init(attachment: ConversationImageAsset) {
        id = attachment.id.uuidString
        label = attachment.fileName
        source = .data(attachment.data)
    }

    init?(source: String, label: String, id: String = UUID().uuidString) {
        self.id = id
        self.label = label.isEmpty ? "Image" : label
        if source.hasPrefix("data:image/") {
            guard source.utf8.count <= MarrMediaLoader.maximumEncodedBytes,
                  let comma = source.firstIndex(of: ","),
                  source[..<comma].hasSuffix(";base64") else { return nil }
            self.source = .dataURL(source)
        } else {
            let url: URL?
            if source.hasPrefix("/") {
                url = URL(fileURLWithPath: source)
            } else if source.hasPrefix("~/") {
                url = URL(fileURLWithPath: (source as NSString).expandingTildeInPath)
            } else {
                url = URL(string: source)
            }
            guard let url, Self.isAllowedURL(url) else { return nil }
            self.source = .url(url)
        }
    }

    static func isAllowedURL(_ url: URL) -> Bool {
        if url.isFileURL {
            return (url.host == nil || url.host == "" || url.host?.lowercased() == "localhost") && url.path.hasPrefix("/")
        }
        return CodexResourceAccess.isWebURL(url)
    }

    /// Local and embedded images can render with the message. Network resources
    /// still require an explicit preview request.
    var canLoadAutomatically: Bool {
        switch source {
        case .data, .dataURL: return true
        case .url(let url): return url.isFileURL
        }
    }
}

/// 100% means one source image pixel per physical display pixel. The backing
/// scale is deliberately separate from NSImage.size, which may contain DPI data.
enum MarrMediaGeometry {
    static func baseSize(pixels: CGSize, backingScale: CGFloat) -> CGSize {
        let backing = backingScale.isFinite && backingScale > 0 ? backingScale : 1
        return CGSize(width: max(1, pixels.width) / backing, height: max(1, pixels.height) / backing)
    }

    static func fitScale(pixels: CGSize, viewport: CGSize, backingScale: CGFloat) -> CGFloat {
        guard viewport.width > 0, viewport.height > 0 else { return 1 }
        let base = baseSize(pixels: pixels, backingScale: backingScale)
        return min(1, viewport.width / base.width, viewport.height / base.height)
    }

    static func clampedOffset(_ offset: CGPoint, pixels: CGSize, viewport: CGSize,
                              backingScale: CGFloat, scale: CGFloat) -> CGPoint {
        let base = baseSize(pixels: pixels, backingScale: backingScale)
        let horizontal = max(0, (base.width * scale - viewport.width) / 2)
        let vertical = max(0, (base.height * scale - viewport.height) / 2)
        return CGPoint(x: min(horizontal, max(-horizontal, offset.x)),
                       y: min(vertical, max(-vertical, offset.y)))
    }

    /// The anchor is in viewport coordinates, with a top-left origin.
    static func zoomedOffset(_ offset: CGPoint, from oldScale: CGFloat, to newScale: CGFloat,
                             anchor: CGPoint, pixels: CGSize, viewport: CGSize,
                             backingScale: CGFloat) -> CGPoint {
        guard oldScale.isFinite, oldScale > 0, newScale.isFinite, newScale > 0 else { return .zero }
        let ratio = newScale / oldScale
        let relative = CGPoint(x: anchor.x - viewport.width / 2, y: anchor.y - viewport.height / 2)
        let next = CGPoint(x: relative.x - (relative.x - offset.x) * ratio,
                           y: relative.y - (relative.y - offset.y) * ratio)
        return clampedOffset(next, pixels: pixels, viewport: viewport,
                             backingScale: backingScale, scale: newScale)
    }

    static func selectedIndex(requestedID: String?, items: [MarrMediaItem]) -> Int? {
        guard !items.isEmpty else { return nil }
        return requestedID.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
    }

    static func adjacentIndex(_ current: Int, offset: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        // Navigation does not wrap: repeated arrows at the end keep the same image.
        return min(count - 1, max(0, current + offset))
    }
}

struct MarrDecodedMedia: @unchecked Sendable {
    // CGImage is immutable; decoding happens off the main actor.
    let image: CGImage
    let data: Data
    let typeIdentifier: String
    let frameCount: Int
    var pixelSize: CGSize { CGSize(width: image.width, height: image.height) }
}

enum MarrMediaLoadError: LocalizedError, Equatable {
    case tooLarge, tooManyPixels, unavailable, invalidImage, invalidSource

    var errorDescription: String? {
        switch self {
        case .tooLarge: "This image exceeds the 49 MB preview limit."
        case .tooManyPixels: "This image exceeds the 24 megapixel preview limit."
        case .unavailable: "The image could not be read. Check its location or connection and try again."
        case .invalidImage: "This file does not contain a supported image."
        case .invalidSource: "This image location is not supported."
        }
    }
}

enum MarrMediaLoader {
    static let maximumBytes = 49_000_000
    static let maximumEncodedBytes = 66_000_000
    static let maximumPixels = 24_000_000
    static let maximumDimension = 32_768
    private static let decoding = MarrMediaDecodePipeline()

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    static func load(_ item: MarrMediaItem, maximumPixelDimension: Int? = nil) async throws -> MarrDecodedMedia {
        // Callers include SwiftUI .task closures. Keep disk reads, base64 decoding
        // and image metadata work off their actor even if concurrency defaults change.
        try Task.checkCancellation()
        let operation = Task.detached(priority: .userInitiated) {
            try await loadSource(item, maximumPixelDimension: maximumPixelDimension)
        }
        let image = try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: { operation.cancel() }
        try Task.checkCancellation()
        return image
    }

    private static func loadSource(_ item: MarrMediaItem, maximumPixelDimension: Int?) async throws -> MarrDecodedMedia {
        try Task.checkCancellation()
        let data: Data
        switch item.source {
        case .data(let supplied):
            data = supplied
        case .dataURL(let source):
            guard source.utf8.count <= maximumEncodedBytes,
                  let comma = source.firstIndex(of: ","),
                  source.hasPrefix("data:image/"), source[..<comma].hasSuffix(";base64"),
                  let decoded = Data(base64Encoded: String(source[source.index(after: comma)...])) else {
                throw MarrMediaLoadError.invalidSource
            }
            data = decoded
        case .url(let url):
            guard MarrMediaItem.isAllowedURL(url) else { throw MarrMediaLoadError.invalidSource }
            if url.isFileURL {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true else { throw MarrMediaLoadError.unavailable }
                guard let size = values.fileSize, size <= maximumBytes else { throw MarrMediaLoadError.tooLarge }
                data = try Data(contentsOf: url, options: .mappedIfSafe)
            } else {
                var request = URLRequest(url: url)
                request.setValue("image/*", forHTTPHeaderField: "Accept")
                let (bytes, response) = try await session.bytes(for: request)
                defer { bytes.task.cancel() }
                guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                      let finalURL = response.url, MarrMediaItem.isAllowedURL(finalURL), !finalURL.isFileURL else {
                    throw MarrMediaLoadError.unavailable
                }
                guard response.expectedContentLength <= Int64(maximumBytes) else { throw MarrMediaLoadError.tooLarge }
                var buffer = Data()
                if response.expectedContentLength > 0 { buffer.reserveCapacity(Int(response.expectedContentLength)) }
                for try await byte in bytes {
                    if buffer.count % 4096 == 0 { try Task.checkCancellation() }
                    guard buffer.count < maximumBytes else { throw MarrMediaLoadError.tooLarge }
                    buffer.append(byte)
                }
                data = buffer
            }
        }
        try Task.checkCancellation()
        return try await decoding.decode(data, maximumPixelDimension: maximumPixelDimension)
    }

    static func validateDimensions(width: Int, height: Int) throws {
        guard width > 0, height > 0 else { throw MarrMediaLoadError.invalidImage }
        guard width <= maximumDimension, height <= maximumDimension,
              Double(width) * Double(height) <= Double(maximumPixels) else { throw MarrMediaLoadError.tooManyPixels }
    }

    static func decode(_ data: Data, maximumPixelDimension: Int? = nil) throws -> MarrDecodedMedia {
        guard data.count <= maximumBytes else { throw MarrMediaLoadError.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              let type = CGImageSourceGetType(source) else { throw MarrMediaLoadError.invalidImage }
        try validateDimensions(width: width, height: height)
        try Task.checkCancellation()
        // ImageIO applies EXIF orientation without an additional full-size bitmap.
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension.map { min(max(width, height), max(1, $0)) } ?? max(width, height),
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else { throw MarrMediaLoadError.invalidImage }
        try Task.checkCancellation()
        return MarrDecodedMedia(image: image, data: data, typeIdentifier: type as String,
                                frameCount: CGImageSourceGetCount(source))
    }

    /// Small attachment chips should not decode an entire screenshot on the UI thread.
    static func thumbnail(_ data: Data, maximumDimension: Int = 80) -> CGImage? {
        guard data.count <= maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (try? validateDimensions(width: width, height: height)) != nil else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maximumDimension),
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }

    static func loadThumbnail(_ data: Data, maximumDimension: Int = 80) async -> CGImage? {
        try? await decoding.thumbnail(data, maximumDimension: maximumDimension)
    }
}

/// ImageIO cannot stop in the middle of a decode. Serializing this short stage
/// prevents rapid gallery switching from decoding several large bitmaps at once.
private actor MarrMediaDecodePipeline {
    func decode(_ data: Data, maximumPixelDimension: Int?) throws -> MarrDecodedMedia {
        try Task.checkCancellation()
        return try MarrMediaLoader.decode(data, maximumPixelDimension: maximumPixelDimension)
    }

    func thumbnail(_ data: Data, maximumDimension: Int) throws -> CGImage? {
        try Task.checkCancellation()
        let image = MarrMediaLoader.thumbnail(data, maximumDimension: maximumDimension)
        try Task.checkCancellation()
        return image
    }
}

@MainActor
enum MarrMediaViewer {
    private static var controller: MarrMediaViewerWindowController?

    static func show(items: [MarrMediaItem], selectedID: String? = nil) {
        guard !items.isEmpty else { return }
        let previous = controller
        let invokingWindow = NSApp.keyWindow
        let invokedInsideViewer = invokingWindow === previous?.window
        let returnWindow = invokedInsideViewer ? previous?.returnWindow : invokingWindow
        let returnResponder = invokedInsideViewer ? previous?.returnResponder : returnWindow?.firstResponder
        previous?.restoresFocusOnClose = false
        previous?.close()
        let next = MarrMediaViewerWindowController(items: items, selectedID: selectedID,
                                                   returnWindow: returnWindow, returnResponder: returnResponder)
        controller = next
        next.onClose = { [weak next] in
            if controller === next { controller = nil }
        }
        next.showWindow(nil)
        next.window?.makeKeyAndOrderFront(nil)
    }

    static func show(attachments: [ConversationImageAsset], selectedID: UUID) {
        show(items: attachments.filter(\.isImage).map(MarrMediaItem.init(attachment:)), selectedID: selectedID.uuidString)
    }
}

private enum MarrMediaZoomCommand: Equatable { case fit, actualSize, zoomIn, zoomOut }

@MainActor
private final class MarrMediaViewerState: ObservableObject {
    let items: [MarrMediaItem]
    @Published private(set) var selectedIndex: Int
    @Published private(set) var image: NSImage?
    @Published private(set) var decoded: MarrDecodedMedia?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published var actionFeedback: String?
    @Published var zoomPercent: Int = 100
    @Published var isFitting = true
    @Published var zoomCommand = MarrMediaZoomCommand.fit
    @Published var zoomSequence = 0
    var onClose: (() -> Void)?
    private var loadTask: Task<Void, Never>?
    private var feedbackTask: Task<Void, Never>?
    private var generation = UUID()
    private var exportedURL: URL?

    var item: MarrMediaItem { items[selectedIndex] }
    var canGoBack: Bool { selectedIndex > 0 }
    var canGoForward: Bool { selectedIndex + 1 < items.count }
    var originalFileURL: URL? {
        if case .url(let url) = item.source, url.isFileURL { return url }
        return nil
    }

    init(items: [MarrMediaItem], selectedID: String?) {
        self.items = items
        selectedIndex = MarrMediaGeometry.selectedIndex(requestedID: selectedID, items: items) ?? 0
        load()
    }

    func select(offset: Int) {
        guard let index = MarrMediaGeometry.adjacentIndex(selectedIndex, offset: offset, count: items.count), index != selectedIndex else { return }
        selectedIndex = index
        load()
    }

    func load() {
        loadTask?.cancel()
        image = nil
        decoded = nil
        error = nil
        actionFeedback = nil
        exportedURL = nil
        isLoading = true
        isFitting = true
        zoom(.fit)
        let selected = item
        let requestID = UUID()
        generation = requestID
        loadTask = Task { [weak self] in
            do {
                let result = try await MarrMediaLoader.load(selected)
                try Task.checkCancellation()
                guard let self, generation == requestID else { return }
                decoded = result
                image = NSImage(cgImage: result.image, size: result.pixelSize)
                isLoading = false
            } catch is CancellationError {
                // Switching image or closing must not replace the next image's state.
            } catch {
                guard let self, generation == requestID, !Task.isCancelled else { return }
                self.error = (error as? MarrMediaLoadError)?.localizedDescription ?? MarrMediaLoadError.unavailable.localizedDescription
                isLoading = false
            }
        }
    }

    func zoom(_ command: MarrMediaZoomCommand) {
        zoomCommand = command
        zoomSequence += 1
    }

    func copyImage() {
        guard let image else { return }
        NSPasteboard.general.clearContents()
        feedback(NSPasteboard.general.writeObjects([image]) ? "Image copied" : "Could not copy the image")
    }

    func openInPreview() {
        guard let previewApp = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else {
            feedback("Preview is unavailable")
            return
        }
        do {
            let url: URL
            if let originalFileURL {
                url = originalFileURL
            } else if let exportedURL {
                url = exportedURL
            } else if let decoded {
                url = try MarrMediaTemporaryFiles.shared.export(decoded, label: item.label)
                exportedURL = url
            } else { return }
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: previewApp, configuration: configuration) { [weak self] _, error in
                if error != nil { Task { @MainActor in self?.feedback("Could not open the image in Preview") } }
            }
        } catch { feedback("Could not prepare the image for Preview") }
    }

    func stop() {
        generation = UUID()
        loadTask?.cancel()
        feedbackTask?.cancel()
        image = nil
        decoded = nil
    }

    private func feedback(_ text: String) {
        feedbackTask?.cancel()
        actionFeedback = text
        feedbackTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            self?.actionFeedback = nil
        }
    }
}

/// Preview needs a real file for data attachments. These private temporary copies
/// live for the app session, so switching images does not break Preview's document.
@MainActor
private final class MarrMediaTemporaryFiles {
    static let shared = MarrMediaTemporaryFiles()
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MarrMediaViewer-\(UUID().uuidString)", isDirectory: true)
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [directory] _ in
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func export(_ media: MarrDecodedMedia, label: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let suffix = UTType(media.typeIdentifier)?.preferredFilenameExtension ?? "image"
        let name = URL(fileURLWithPath: label).deletingPathExtension().lastPathComponent
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ ")).inverted).joined()
        let url = directory.appendingPathComponent("\(name.isEmpty ? "Image" : String(name.prefix(80)))-\(UUID().uuidString).\(suffix)")
        try media.data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }
}

@MainActor
private final class MarrMediaViewerWindowController: NSWindowController, NSWindowDelegate {
    weak var returnWindow: NSWindow?
    weak var returnResponder: NSResponder?
    var restoresFocusOnClose = true
    var onClose: (() -> Void)?
    private let state: MarrMediaViewerState
    private var closingWhileKey = false

    init(items: [MarrMediaItem], selectedID: String?, returnWindow: NSWindow?, returnResponder: NSResponder?) {
        state = MarrMediaViewerState(items: items, selectedID: selectedID)
        self.returnWindow = returnWindow
        self.returnResponder = returnResponder
        let panel = MarrMediaPanel(contentRect: NSRect(x: 0, y: 0, width: 840, height: 620),
                                   styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = "Image viewer"
        panel.identifier = NSUserInterfaceItemIdentifier("MarrMediaViewer")
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 560, height: 380)
        panel.level = returnWindow?.level ?? .normal
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: MarrMediaViewerContent(state: state))
        panel.onKey = { [weak state] event in
            guard let state else { return false }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 53 { state.onClose?(); return true }
            if modifiers.contains(.command) {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "c": state.copyImage(); return true
                case "0": state.zoom(.fit); return true
                case "1": state.zoom(.actualSize); return true
                case "+", "=": state.zoom(.zoomIn); return true
                case "-": state.zoom(.zoomOut); return true
                default: return false
                }
            }
            if modifiers.intersection([.command, .control, .option]).isEmpty {
                if event.keyCode == 123 { state.select(offset: -1); return true }
                if event.keyCode == 124 { state.select(offset: 1); return true }
            }
            return false
        }
        state.onClose = { [weak self] in self?.close() }
        panel.center()
    }

    required init?(coder: NSCoder) { nil }

    override func close() {
        closingWhileKey = window?.isKeyWindow == true
        super.close()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        closingWhileKey = sender.isKeyWindow
        return true
    }

    func windowWillClose(_ notification: Notification) {
        state.stop()
        let keyWindow = NSApp.keyWindow
        let mayRestore = restoresFocusOnClose && closingWhileKey && NSApp.isActive
            && (keyWindow === window || keyWindow === returnWindow || keyWindow == nil)
        if mayRestore, let returnWindow, returnWindow.isVisible, !returnWindow.isMiniaturized {
            returnWindow.makeKeyAndOrderFront(nil)
            if let view = returnResponder as? NSView, view.window === returnWindow {
                returnWindow.makeFirstResponder(view)
            }
        }
        onClose?()
    }
}

private final class MarrMediaPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKey?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

private struct MarrMediaViewerContent: View {
    @ObservedObject var state: MarrMediaViewerState

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(state.item.label).font(MarrTypography.font(.body, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 12)
                    Text("\(state.selectedIndex + 1) / \(state.items.count)").font(MarrTypography.font(.secondary)).monospacedDigit().foregroundStyle(.secondary)
                        .accessibilityLabel("Image \(state.selectedIndex + 1) of \(state.items.count)")
                }
                HStack(spacing: 8) {
                    Button { state.select(offset: -1) } label: { MarrIcon("chevron.left") }
                        .disabled(!state.canGoBack).help("Previous image (←)").accessibilityLabel("Previous image")
                    Button { state.select(offset: 1) } label: { MarrIcon("chevron.right") }
                        .disabled(!state.canGoForward).help("Next image (→)").accessibilityLabel("Next image")
                    Divider().frame(height: 18)
                    Button("Fit") { state.zoom(.fit) }.help("Fit image (⌘0)").disabled(state.image == nil)
                        .accessibilityValue(state.isFitting ? "Selected" : "")
                    Button("100%") { state.zoom(.actualSize) }.help("One image pixel per display pixel (⌘1)")
                        .disabled(state.image == nil)
                    Button { state.zoom(.zoomOut) } label: { MarrIcon("minus.magnifyingglass") }
                        .help("Zoom out (⌘−)").accessibilityLabel("Zoom out").disabled(state.image == nil)
                    Text(state.image == nil ? "—" : "\(state.zoomPercent)%").font(MarrTypography.font(.secondary)).monospacedDigit().frame(width: 42)
                        .accessibilityLabel(state.image == nil ? "Image not loaded" : "Zoom \(state.zoomPercent) percent")
                    Button { state.zoom(.zoomIn) } label: { MarrIcon("plus.magnifyingglass") }
                        .help("Zoom in (⌘+)").accessibilityLabel("Zoom in").disabled(state.image == nil)
                    Spacer(minLength: 0)
                    Button { state.copyImage() } label: { MarrIcon("doc.on.doc") }
                        .disabled(state.image == nil).help("Copy image (⌘C)").accessibilityLabel("Copy image")
                    Button("Open in Preview") { state.openInPreview() }
                        .disabled(state.decoded == nil && state.originalFileURL == nil)
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
            }
            .padding(12)
            .marrSurface(.content, cornerRadius: 0)
            Divider()
            ZStack {
                if let image = state.image, let decoded = state.decoded {
                    MarrMediaCanvas(image: image, pixelSize: decoded.pixelSize, label: state.item.label,
                                    command: state.zoomCommand, sequence: state.zoomSequence) { scale, fitting in
                        let percent = Int((scale * 100).rounded())
                        if state.zoomPercent != percent { state.zoomPercent = percent }
                        if state.isFitting != fitting { state.isFitting = fitting }
                    }
                    .id(state.item.id)
                } else if state.isLoading {
                    ProgressView("Loading image…").controlSize(.small)
                } else if let error = state.error {
                    VStack(spacing: 12) {
                        MarrIcon("photo.badge.exclamationmark", size: MarrUI.Icon.hero).foregroundStyle(.secondary)
                        Text(error).font(MarrTypography.font(.body)).multilineTextAlignment(.center).frame(maxWidth: 360)
                        Button("Try again") { state.load() }
                    }
                    .padding(24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MarrUI.Surface.canvas)
            Divider()
            HStack(spacing: 12) {
                if let feedback = state.actionFeedback {
                    Text(feedback).accessibilityLabel(feedback)
                } else if let decoded = state.decoded {
                    Text("\(decoded.image.width) × \(decoded.image.height) px\(decoded.frameCount > 1 ? " · First frame" : "")")
                } else { Text("Image viewer") }
                Spacer(minLength: 8)
                Text("Pinch to zoom · Drag / ⌥ arrows to pan · Esc to close").foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.85)
            }
            .font(MarrTypography.font(.caption))
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }
}

private struct MarrMediaCanvas: NSViewRepresentable {
    let image: NSImage
    let pixelSize: CGSize
    let label: String
    let command: MarrMediaZoomCommand
    let sequence: Int
    let onZoom: (CGFloat, Bool) -> Void

    func makeNSView(context: Context) -> MarrMediaCanvasView {
        let view = MarrMediaCanvasView()
        view.image = image
        view.pixelSize = pixelSize
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.image)
        view.setAccessibilityLabel(label)
        view.setAccessibilityHelp("Use the toolbar to change zoom. Pinch to zoom, drag, scroll or use Option-arrow keys to pan. Left and right arrows switch images; Escape closes the viewer.")
        return view
    }

    func updateNSView(_ view: MarrMediaCanvasView, context: Context) {
        view.onZoom = onZoom
        if view.lastSequence != sequence {
            view.lastSequence = sequence
            view.apply(command)
        }
    }
}

private final class MarrMediaCanvasView: NSView {
    var image: NSImage?
    var pixelSize = CGSize(width: 1, height: 1)
    var onZoom: ((CGFloat, Bool) -> Void)?
    var lastSequence = -1
    private var scale: CGFloat = 1
    private var offset = CGPoint.zero
    private var fitting = true
    private var dragStart: CGPoint?
    private var dragOffset = CGPoint.zero
    private var backing: CGFloat { window?.backingScaleFactor ?? 1 }
    private var fit: CGFloat { MarrMediaGeometry.fitScale(pixels: pixelSize, viewport: bounds.size, backingScale: backing) }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let image else { return }
        let base = MarrMediaGeometry.baseSize(pixels: pixelSize, backingScale: backing)
        let size = CGSize(width: base.width * scale, height: base.height * scale)
        let rect = CGRect(x: (bounds.width - size.width) / 2 + offset.x,
                          y: (bounds.height - size.height) / 2 + offset.y, width: size.width, height: size.height)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        resizeImage()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resizeImage()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        resizeImage()
    }

    func apply(_ command: MarrMediaZoomCommand) {
        switch command {
        case .fit:
            fitting = true
            scale = fit
            offset = .zero
            changed()
        case .actualSize: zoom(to: 1)
        case .zoomIn: zoom(to: scale * 1.25)
        case .zoomOut: zoom(to: scale / 1.25)
        }
    }

    private func zoom(to proposed: CGFloat, anchor: CGPoint? = nil) {
        guard proposed.isFinite else { return }
        let next = min(8, max(min(fit, 0.05), proposed))
        offset = MarrMediaGeometry.zoomedOffset(offset, from: scale, to: next,
                                                anchor: anchor ?? CGPoint(x: bounds.midX, y: bounds.midY),
                                                pixels: pixelSize, viewport: bounds.size, backingScale: backing)
        scale = next
        fitting = false
        changed()
    }

    private func resizeImage() {
        if fitting { scale = fit; offset = .zero }
        else { offset = MarrMediaGeometry.clampedOffset(offset, pixels: pixelSize, viewport: bounds.size, backingScale: backing, scale: scale) }
        changed()
    }

    private func changed() {
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        setAccessibilityValue("\(Int((scale * 100).rounded())) percent")
        let scale = scale, fitting = fitting
        // SwiftUI may be updating the representable or laying out the window.
        DispatchQueue.main.async { [weak self] in self?.onZoom?(scale, fitting) }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: scale > fit ? .openHand : .arrow)
    }

    override func magnify(with event: NSEvent) {
        zoom(to: scale * (1 + event.magnification), anchor: convert(event.locationInWindow, from: nil))
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.option) || event.modifierFlags.contains(.command) {
            zoom(to: scale * exp(-event.scrollingDeltaY * 0.01), anchor: convert(event.locationInWindow, from: nil))
        } else {
            let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
            offset = MarrMediaGeometry.clampedOffset(CGPoint(x: offset.x + event.scrollingDeltaX * factor,
                                                             y: offset.y + event.scrollingDeltaY * factor),
                                                     pixels: pixelSize, viewport: bounds.size, backingScale: backing, scale: scale)
            changed()
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.option), [123, 124, 125, 126].contains(event.keyCode) {
            let movement: CGPoint
            switch event.keyCode {
            case 123: movement = CGPoint(x: 40, y: 0)
            case 124: movement = CGPoint(x: -40, y: 0)
            case 125: movement = CGPoint(x: 0, y: -40)
            default: movement = CGPoint(x: 0, y: 40)
            }
            offset = MarrMediaGeometry.clampedOffset(CGPoint(x: offset.x + movement.x, y: offset.y + movement.y),
                                                     pixels: pixelSize, viewport: bounds.size, backingScale: backing, scale: scale)
            changed()
        } else {
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2 {
            if fitting || scale < 1 { zoom(to: 1, anchor: point) } else { apply(.fit) }
        } else {
            dragStart = point
            dragOffset = offset
            if scale > fit { NSCursor.closedHand.set() }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        offset = MarrMediaGeometry.clampedOffset(CGPoint(x: dragOffset.x + point.x - dragStart.x,
                                                         y: dragOffset.y + point.y - dragStart.y),
                                                 pixels: pixelSize, viewport: bounds.size, backingScale: backing, scale: scale)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
        window?.invalidateCursorRects(for: self)
    }
}

private struct MarrHistoryThreadKey: EnvironmentKey { static let defaultValue: String? = nil }
extension EnvironmentValues {
    var marrHistoryThreadID: String? {
        get { self[MarrHistoryThreadKey.self] }
        set { self[MarrHistoryThreadKey.self] = newValue }
    }
}

/// Coalesce recovery by thread and keep archive IO/decompression off the UI thread.
@MainActor
enum MarrHistoryImageRecovery {
    private static var tasks: [String: Task<Void, Never>] = [:]
    private static var attempts: [String: Date] = [:]

    static func cancelAll() {
        for task in tasks.values { task.cancel() }
        attempts = [:]
    }

    static func recover(source: String, threadID: String?, retry: Bool = false) async -> URL? {
        guard let threadID, let id = UUID(uuidString: threadID), source.hasPrefix("/") else { return nil }
        let thread = id.uuidString.lowercased()
        let root = MarrStorage.rootURL.appendingPathComponent("HistoryImages").appendingPathComponent(thread)
        let image = root.appendingPathComponent(CodexHistoryImageArchive.key(source) + ".image")
        if FileManager.default.fileExists(atPath: image.path) { return image }
        guard UserDefaults.standard.bool(forKey: RuntimeWorkspaceController.codexSyncEnabledKey),
              ProcessInfo.processInfo.environment["MARR_TEST_HOST"] != "1" else { return nil }
        if let task = tasks[thread] { await task.value }
        else if retry || Date().timeIntervalSince(attempts[thread] ?? .distantPast) >= 60 {
            attempts[thread] = Date()
            let home = CodexRuntime.homeURL
            let task = Task.detached(priority: .utility) {
                do { try CodexHistoryImageArchive.recover(threadID: thread, codexHome: home, destination: root) } catch {}
            }
            tasks[thread] = task
            await task.value
            tasks[thread] = nil
        }
        guard !Task.isCancelled, FileManager.default.fileExists(atPath: image.path) else { return nil }
        return image
    }
}
