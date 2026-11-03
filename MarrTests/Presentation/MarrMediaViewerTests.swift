import CoreGraphics
import ImageIO
import MarrCore
import UniformTypeIdentifiers
import XCTest
@testable import Marr

/// Geometry and decoding only. These tests do not create NSApplication, windows,
/// pasteboards or network requests and are safe in the no-window test lane.
final class MarrMediaViewerTests: XCTestCase {
    func testHistoryImageRecoveryUsesOnlyExactUserImageAssociations() throws {
        let image = try imageData(width: 24, height: 12)
        let dataURL = "data:image/jpeg;base64," + image.base64EncodedString()
        func record(role: String = "user", extraImage: Bool = false) throws -> Data {
            var content: [[String: Any]] = [
                ["type": "input_text", "text": "<image name=[Image #1] path=\"/tmp/旧图.png\">"],
                ["type": "input_image", "image_url": dataURL]
            ]
            if extraImage { content.append(["type": "input_image", "image_url": dataURL]) }
            return try JSONSerialization.data(withJSONObject: ["type": "response_item", "payload": ["role": role, "content": content]])
        }
        let recovered = CodexHistoryImageArchive.images(in: try record())
        XCTAssertEqual(recovered.map(\.source), ["/tmp/旧图.png"])
        XCTAssertEqual(recovered.first?.data, image)
        XCTAssertTrue(CodexHistoryImageArchive.images(in: try record(role: "assistant")).isEmpty)
        XCTAssertTrue(CodexHistoryImageArchive.images(in: try record(extraImage: true)).isEmpty,
            "Never guess which image belongs to a path when counts disagree")
        XCTAssertEqual(CodexHistoryImageArchive.key("/tmp/a/../旧图.png"), CodexHistoryImageArchive.key("/tmp/旧图.png"))
    }

    func testHistoryImageRecoveryReadsArchivedRolloutWithoutOriginalFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let home = root.appendingPathComponent("codex")
        let archived = home.appendingPathComponent("archived_sessions")
        let destination = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString.lowercased(), original = "/missing/screenshot.png"
        let image = try imageData(width: 20, height: 10)
        let record: [String: Any] = ["type": "response_item", "payload": ["role": "user", "content": [
            ["type": "input_text", "text": "<image name=[Image #1] path=\"\(original)\">"],
            ["type": "input_image", "image_url": "data:image/jpeg;base64," + image.base64EncodedString()]
        ]]]
        var data = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": ["id": id]])
        data.append(10)
        data.append(try JSONSerialization.data(withJSONObject: record))
        let rollout = archived.appendingPathComponent("rollout-fixture-\(id).jsonl")
        try data.write(to: rollout)
        try CodexHistoryImageArchive.recover(threadID: id, codexHome: home, destination: destination)
        let cached = destination.appendingPathComponent(CodexHistoryImageArchive.key(original) + ".image")
        XCTAssertEqual(try Data(contentsOf: cached), image)
        XCTAssertEqual(try Data(contentsOf: rollout), data, "Recovery must never modify Codex history")
        XCTAssertThrowsError(try CodexHistoryImageArchive.recover(threadID: "../escape", codexHome: home, destination: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: original))
    }

    @MainActor
    func testContinuationImagesReachDirectPreviewLoader() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = home.appendingPathComponent("sessions/2026/10/25")
        let id = UUID().uuidString.lowercased()
        let destination = MarrStorage.rootURL.appendingPathComponent("HistoryImages/\(id)")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: destination)
        }
        let original = "/missing/续接截图.png"
        let image = try imageData(width: 800, height: 400)
        let metadata = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": ["id": id]])
        try metadata.write(to: sessions.appendingPathComponent("rollout-2026-10-23-\(id).jsonl"))
        var continuation = metadata
        continuation.append(10)
        continuation.append(try JSONSerialization.data(withJSONObject: ["type": "response_item", "payload": ["role": "user", "content": [
            ["type": "input_text", "text": "<image name=[Image #1] path=\"\(original)\">"],
            ["type": "input_image", "image_url": "data:image/jpeg;base64," + image.base64EncodedString()]
        ]]]))
        try continuation.write(to: sessions.appendingPathComponent("rollout-2026-10-25-\(id)_\(UUID().uuidString.lowercased()).jsonl"))
        try CodexHistoryImageArchive.recover(threadID: id, codexHome: home, destination: destination)
        let recovered = await MarrHistoryImageRecovery.recover(source: original, threadID: id)
        let url = try XCTUnwrap(recovered, "The UI must find the recovered image in the selected storage root")
        let item = try XCTUnwrap(MarrMediaItem(source: url.path, label: "续接截图"))
        let preview = try await MarrMediaLoader.load(item, maximumPixelDimension: 480)
        XCTAssertEqual(preview.image.width, 480)
        XCTAssertEqual(preview.image.height, 240)
        let full = try await MarrMediaLoader.load(item)
        XCTAssertEqual(full.image.width, 800)
        XCTAssertEqual(full.image.height, 400)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original))
    }

    func testRecoveryRejectsMismatchedSessionIdentity() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let id = UUID().uuidString.lowercased()
        let metadata = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": ["id": UUID().uuidString]])
        try metadata.write(to: sessions.appendingPathComponent("rollout-\(id).jsonl"))
        XCTAssertThrowsError(try CodexHistoryImageArchive.recover(threadID: id, codexHome: home,
            destination: home.appendingPathComponent("cache")))
    }

    func testCancelledHistoryRecoveryDoesNotCreateCache() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let destination = home.appendingPathComponent("cache")
        let task = Task.detached {
            // Wait for the test to cancel before entering the archive reader.
            while !Task.isCancelled { await Task.yield() }
            return Result { try CodexHistoryImageArchive.recover(threadID: UUID().uuidString,
                                                                 codexHome: home, destination: destination) }
        }
        task.cancel()
        switch await task.value {
        case .success: XCTFail("Cancelled recovery must stop before IO")
        case .failure(let error): XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testActualSizeUsesImagePixelsAndDisplayBackingScale() {
        let pixels = CGSize(width: 2000, height: 1000)
        XCTAssertEqual(MarrMediaGeometry.baseSize(pixels: pixels, backingScale: 2), CGSize(width: 1000, height: 500))
        XCTAssertEqual(MarrMediaGeometry.baseSize(pixels: pixels, backingScale: 1), pixels)
        XCTAssertEqual(MarrMediaGeometry.fitScale(pixels: pixels, viewport: CGSize(width: 500, height: 400), backingScale: 2), 0.5)
        XCTAssertEqual(MarrMediaGeometry.fitScale(pixels: pixels, viewport: CGSize(width: 500, height: 400), backingScale: 1), 0.25)
        XCTAssertEqual(MarrMediaGeometry.fitScale(pixels: CGSize(width: 20, height: 10), viewport: CGSize(width: 500, height: 400), backingScale: 2), 1)
    }

    func testZoomKeepsTheSourcePixelUnderThePointerUntilItReachesTheBoundary() {
        let pixels = CGSize(width: 2000, height: 1000)
        let viewport = CGSize(width: 500, height: 400)
        let anchor = CGPoint(x: 350, y: 200)
        let next = MarrMediaGeometry.zoomedOffset(.zero, from: 0.5, to: 1, anchor: anchor,
                                                  pixels: pixels, viewport: viewport, backingScale: 2)
        XCTAssertEqual(next.x, -100, accuracy: 0.001)
        XCTAssertEqual(next.y, 0, accuracy: 0.001)
        let originalPixel = (anchor.x - viewport.width / 2) / 0.5
        let zoomedPixel = (anchor.x - viewport.width / 2 - next.x)
        XCTAssertEqual(originalPixel, zoomedPixel, accuracy: 0.001)
    }

    func testPanBoundsAndFitResetCannotLeaveAnImageOffScreen() {
        let pixels = CGSize(width: 2000, height: 1000)
        let viewport = CGSize(width: 500, height: 400)
        let clamped = MarrMediaGeometry.clampedOffset(CGPoint(x: 999, y: -999), pixels: pixels,
                                                       viewport: viewport, backingScale: 2, scale: 1)
        XCTAssertEqual(clamped, CGPoint(x: 250, y: -50))
        let fit = MarrMediaGeometry.zoomedOffset(clamped, from: 1, to: 0.5, anchor: CGPoint(x: 490, y: 390),
                                                 pixels: pixels, viewport: viewport, backingScale: 2)
        XCTAssertEqual(fit, .zero)
        XCTAssertEqual(MarrMediaGeometry.zoomedOffset(.zero, from: 0, to: 1, anchor: .zero,
                                                      pixels: pixels, viewport: viewport, backingScale: 2), .zero)
    }

    func testGallerySelectionPreservesRequestedAttachmentAndDoesNotWrap() {
        let first = MarrMediaItem(attachment: asset(name: "first.png"))
        let second = MarrMediaItem(attachment: asset(name: "second.png"))
        XCTAssertEqual(MarrMediaGeometry.selectedIndex(requestedID: second.id, items: [first, second]), 1)
        XCTAssertEqual(MarrMediaGeometry.selectedIndex(requestedID: "missing", items: [first, second]), 0)
        XCTAssertNil(MarrMediaGeometry.selectedIndex(requestedID: nil, items: []))
        XCTAssertEqual(MarrMediaGeometry.adjacentIndex(0, offset: -1, count: 2), 0)
        XCTAssertEqual(MarrMediaGeometry.adjacentIndex(1, offset: 1, count: 2), 1)
        XCTAssertEqual(MarrMediaGeometry.adjacentIndex(0, offset: 1, count: 2), 1)
        XCTAssertNil(MarrMediaGeometry.adjacentIndex(0, offset: 1, count: 0))
    }

    func testViewerAcceptsOnlySupportedImageSourceLocations() {
        XCTAssertNotNil(MarrMediaItem(source: "/tmp/example.png", label: "Example"))
        XCTAssertNotNil(MarrMediaItem(source: "https://example.com/image.png", label: "Example"))
        XCTAssertNotNil(MarrMediaItem(source: "http://localhost:3000/image.png", label: "Local service"))
        XCTAssertNotNil(MarrMediaItem(source: "http://[::1]:3000/image.png", label: "Local service"))
        XCTAssertNotNil(MarrMediaItem(source: "data:image/png;base64,aGVsbG8=", label: "Example"))
        XCTAssertNil(MarrMediaItem(source: "file://elsewhere/tmp/example.png", label: "Example"))
        XCTAssertNil(MarrMediaItem(source: "javascript:alert(1)", label: "Example"))
        XCTAssertNil(MarrMediaItem(source: "http://example.com/image.png", label: "Unencrypted remote image"))
        XCTAssertNil(MarrMediaItem(source: "data:text/html;base64,aGVsbG8=", label: "Example"))
        XCTAssertNil(MarrMediaItem(source: "data:image/png,not-base64", label: "Example"))
        XCTAssertNil(MarrMediaItem(source: "https:///missing-host", label: "Example"))
    }

    func testDecodedPixelBudgetRejectsHugeOrInvalidMetadataBeforeAllocation() throws {
        try MarrMediaLoader.validateDimensions(width: 6000, height: 4000)
        XCTAssertThrowsError(try MarrMediaLoader.validateDimensions(width: 6001, height: 4000)) {
            XCTAssertEqual($0 as? MarrMediaLoadError, .tooManyPixels)
        }
        XCTAssertThrowsError(try MarrMediaLoader.validateDimensions(width: 1, height: 50_000)) {
            XCTAssertEqual($0 as? MarrMediaLoadError, .tooManyPixels)
        }
        XCTAssertThrowsError(try MarrMediaLoader.validateDimensions(width: -1, height: 1)) {
            XCTAssertEqual($0 as? MarrMediaLoadError, .invalidImage)
        }
        XCTAssertThrowsError(try MarrMediaLoader.decode(Data("not an image".utf8))) {
            XCTAssertEqual($0 as? MarrMediaLoadError, .invalidImage)
        }
    }

    func testImageIODecodesOrientationAndSmallThumbnailsWithoutAWindow() throws {
        let original = try imageData(width: 120, height: 60, orientation: 6)
        let decoded = try MarrMediaLoader.decode(original)
        XCTAssertEqual(decoded.pixelSize, CGSize(width: 60, height: 120))
        XCTAssertEqual(decoded.data, original)
        XCTAssertEqual(decoded.frameCount, 1)
        let thumbnail = try XCTUnwrap(MarrMediaLoader.thumbnail(original, maximumDimension: 20))
        XCTAssertEqual(thumbnail.width, 10)
        XCTAssertEqual(thumbnail.height, 20)
        let inline = try MarrMediaLoader.decode(original, maximumPixelDimension: 20)
        XCTAssertEqual(inline.pixelSize, CGSize(width: 10, height: 20))
        XCTAssertEqual(inline.data, original, "Downsampling the display must not change the retained original")
    }

    func testLocalImageAndDataURLShareTheSameValidatedDecoder() async throws {
        let data = try imageData(width: 8, height: 4)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MarrMediaViewerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fixture.jpg")
        try data.write(to: file)
        let local = try XCTUnwrap(MarrMediaItem(source: file.path, label: "Local"))
        let inline = try XCTUnwrap(MarrMediaItem(source: "data:image/jpeg;base64,\(data.base64EncodedString())", label: "Inline"))
        let loaded = try await MarrMediaLoader.load(local)
        let fromDataURL = try await MarrMediaLoader.load(inline)
        XCTAssertEqual(loaded.pixelSize, CGSize(width: 8, height: 4))
        XCTAssertEqual(loaded.data, fromDataURL.data)
        let folder = try XCTUnwrap(MarrMediaItem(source: directory.path, label: "Folder"))
        do {
            _ = try await MarrMediaLoader.load(folder)
            XCTFail("A directory is not an image")
        } catch { XCTAssertEqual(error as? MarrMediaLoadError, .unavailable) }
    }

    func testCancelledLoadDoesNotDecodeOrReturnAnImage() async throws {
        let item = MarrMediaItem(attachment: asset(name: "cancelled.png"))
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await MarrMediaLoader.load(item)
        }
        do {
            _ = try await operation.value
            XCTFail("Cancelled image loads must stop")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    private func asset(name: String) -> ConversationImageAsset {
        ConversationImageAsset(data: Data(), mimeType: "image/png", fileName: name)
    }

    private func imageData(width: Int, height: Int, orientation: Int = 1) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
