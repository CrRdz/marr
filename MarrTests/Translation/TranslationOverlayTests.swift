import AppKit
import Carbon
import Vision
import XCTest
@testable import Marr

@MainActor
final class TranslationOverlayTests: XCTestCase {
    func testCompletedTranslationPinIsClickableWithoutHighlightsAndKeepsItsSize() throws {
        try MarrUITestSupport.requireVisibleWindows()
        let fixture = try makeFixture()
        let controller = fixture.controller
        defer { controller.close() }
        XCTAssertEqual(controller.companionPhaseForTesting, .recognizing)
        controller.show()
        controller.showProcessing(.translating)
        XCTAssertEqual(controller.companionPhaseForTesting, .translating)
        controller.showProcessing(.rendering)
        XCTAssertEqual(controller.companionPhaseForTesting, .rendering)
        controller.showTranslatedImage(fixture.translation, originalImage: fixture.original)
        XCTAssertEqual(controller.companionPhaseForTesting, .success)
        let window = controller.windowForTesting
        settle(window)

        XCTAssertFalse(window.ignoresMouseEvents, "The pin must receive clicks even when no text highlight pairs exist")
        XCTAssertNotNil(controller.toolWindowForTesting)
        XCTAssertFalse(controller.isTranslationPinned)
        let initialFrame = window.frame

        try clickPin(in: window)
        settle(window)

        XCTAssertTrue(controller.isTranslationPinned, "Clicking the visible icon must enable movement")
        XCTAssertEqual(controller.companionPhaseForTesting, .pinned)
        XCTAssertTrue(try contentReceivesDrag(in: window), "Dragging the translated content must reach the window drag surface")
        XCTAssertEqual(window.frame, initialFrame, "Pinning must keep the captured size and position")
        XCTAssertFalse(window.styleMask.contains(.resizable), "The movable result has no resizing or 1:1 controls")
        let rendered = try recognizedText(in: window).lowercased()
        XCTAssertFalse(rendered.contains("1:1"), rendered)
        XCTAssertFalse(rendered.contains("zoom"), rendered)
        XCTAssertFalse(rendered.contains("pin"), "The pin has an accessibility label, not a visible text label: \(rendered)")
        let compare = try XCTUnwrap(controller.toolWindowForTesting)
        settle(compare)
        try click(in: compare, at: CGPoint(x: compare.contentLayoutRect.midX, y: compare.contentLayoutRect.midY))
        settle(compare)
        let original = try XCTUnwrap(controller.originalWindowForTesting, "The visible Compare control must open the original image")
        XCTAssertEqual(controller.companionPhaseForTesting, .comparing)
        let gaze = controller.companionGazeForTesting
        XCTAssertGreaterThan(gaze.x * (original.frame.midX - compare.frame.midX), 0,
                             "Opening comparison should look toward the actual original window")
        XCTAssertLessThan(gaze.y * (original.frame.midY - compare.frame.midY), 0,
                          "Screen-space Y must be flipped for the native eye direction")
        try click(in: compare, at: CGPoint(x: compare.contentLayoutRect.midX, y: compare.contentLayoutRect.midY))
        settle(compare)
        XCTAssertNil(controller.originalWindowForTesting, "The same control must close the original image when showing Done")
        XCTAssertTrue(controller.isTranslationPinned)
        XCTAssertEqual(controller.companionPhaseForTesting, .pinned)
        XCTAssertEqual(window.frame, initialFrame)
        try savePreview(controller)
    }

    func testPinnedMoveKeepsCompareAndBackgroundRefreshAtTheMovedPosition() throws {
        try MarrUITestSupport.requireVisibleWindows()
        let fixture = try makeFixture()
        let controller = fixture.controller
        defer { controller.close() }
        controller.show()
        controller.showTranslatedImage(fixture.translation, originalImage: fixture.original)
        controller.toggleTranslationPin()
        let window = controller.windowForTesting
        settle(window)
        let tools = try XCTUnwrap(controller.toolWindowForTesting)
        let initialToolFrame = tools.frame
        let initialFrame = window.frame

        window.setFrameOrigin(CGPoint(x: initialFrame.minX + 70, y: initialFrame.minY + 40))
        settle(window)
        let movedFrame = window.frame
        XCTAssertEqual(movedFrame.size, initialFrame.size)
        XCTAssertEqual(tools.frame.minX - initialToolFrame.minX, movedFrame.minX - initialFrame.minX, accuracy: 1)
        XCTAssertEqual(tools.frame.minY - initialToolFrame.minY, movedFrame.minY - initialFrame.minY, accuracy: 1)

        controller.toggleCompare()
        settle(window)
        XCTAssertTrue(controller.isTranslationPinned)
        XCTAssertEqual(window.frame, movedFrame)
        XCTAssertFalse(window.ignoresMouseEvents, "Compare must not disable the translated result's pin")
        let original = try XCTUnwrap(controller.originalWindowForTesting)
        let visibleFrame = try XCTUnwrap(window.screen ?? NSScreen.main).visibleFrame
        XCTAssertEqual(original.frame, TranslationCompareLayout.originalFrame(anchorFrame: movedFrame, visibleFrame: visibleFrame))

        let pairs = [ImageTranslationHighlightPair(
            id: "sentence",
            sourceRects: [CGRect(x: 0.08, y: 0.35, width: 0.7, height: 0.14)],
            translatedRects: [CGRect(x: 0.08, y: 0.35, width: 0.7, height: 0.14)]
        )]
        controller.updateTranslatedImage(fixture.translation, highlightPairs: pairs)
        controller.updateHighlightPairs([])
        settle(window)
        XCTAssertTrue(controller.isTranslationPinned)
        XCTAssertTrue(try contentReceivesDrag(in: window))
        XCTAssertFalse(window.ignoresMouseEvents)
        XCTAssertEqual(window.frame, movedFrame, "Alignment and translation updates must not undo the user's move")

        controller.toggleCompare()
        settle(window)
        XCTAssertNil(controller.originalWindowForTesting)
        XCTAssertTrue(controller.isTranslationPinned)
        XCTAssertEqual(window.frame, movedFrame, "Done must close only the original comparison, without snapping the result back")
    }

    func testUnpinRestoresSelectionAndPinCanBeClickedDuringCompare() throws {
        try MarrUITestSupport.requireVisibleWindows()
        let fixture = try makeFixture()
        let controller = fixture.controller
        defer { controller.close() }
        controller.show()
        controller.showTranslatedImage(fixture.translation, originalImage: fixture.original)
        let window = controller.windowForTesting
        let originalFrame = window.frame
        controller.toggleTranslationPin()
        window.setFrameOrigin(CGPoint(x: originalFrame.minX + 50, y: originalFrame.minY + 30))
        controller.toggleCompare()
        settle(window)

        try clickPin(in: window)
        settle(window)

        XCTAssertFalse(controller.isTranslationPinned)
        XCTAssertFalse(try contentReceivesDrag(in: window))
        XCTAssertEqual(window.frame, originalFrame, "Unpin returns the translation to its captured selection")
        XCTAssertNotNil(controller.toolWindowForTesting)
        XCTAssertFalse(window.ignoresMouseEvents)

        controller.showTranslatedImage(fixture.translation, originalImage: fixture.original)
        XCTAssertFalse(controller.isTranslationPinned)
        XCTAssertEqual(window.frame, originalFrame)
        XCTAssertNil(controller.originalWindowForTesting)
    }

    func testCloseCleansUpMovedResultAndComparisonExactlyOnce() throws {
        try MarrUITestSupport.requireVisibleWindows()
        let fixture = try makeFixture()
        let controller = fixture.controller
        var closeCount = 0
        controller.onClose = { closeCount += 1 }
        controller.show()
        controller.showTranslatedImage(fixture.translation, originalImage: fixture.original)
        controller.toggleTranslationPin()
        let window = controller.windowForTesting
        window.setFrameOrigin(CGPoint(x: window.frame.minX + 30, y: window.frame.minY + 20))
        controller.toggleCompare()
        let tools = try XCTUnwrap(controller.toolWindowForTesting)
        let original = try XCTUnwrap(controller.originalWindowForTesting)

        controller.close()
        controller.close()

        XCTAssertEqual(closeCount, 1)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(tools.isVisible)
        XCTAssertFalse(original.isVisible)
        XCTAssertNil(window.contentView)
        XCTAssertNil(controller.toolWindowForTesting)
        XCTAssertNil(controller.originalWindowForTesting)
        XCTAssertTrue(window.childWindows?.isEmpty ?? true)
    }

    func testPinReleasesFrozenPageAndUnpinRestoresCapturePreview() throws {
        try MarrUITestSupport.requireVisibleWindows()
        let fixture = try makeFixture()
        let controller = fixture.controller
        defer { controller.close() }
        controller.show()
        controller.showTranslatedImage(fixture.translation, originalImage: fixture.original)
        controller.toggleCompare()
        let window = controller.windowForTesting
        let anchorFrame = window.frame
        let backdrop = controller.backdropWindowForTesting
        let tools = try XCTUnwrap(controller.toolWindowForTesting)
        let original = try XCTUnwrap(controller.originalWindowForTesting)

        XCTAssertTrue(backdrop.isVisible)
        XCTAssertFalse(backdrop.ignoresMouseEvents)
        for captureWindow in [backdrop, window, tools, original] {
            XCTAssertEqual(captureWindow.level, .screenSaver)
        }

        controller.toggleTranslationPin()

        XCTAssertFalse(backdrop.isVisible, "Pinning must expose the live page instead of leaving the frozen screenshot on screen")
        XCTAssertTrue(backdrop.ignoresMouseEvents, "The hidden capture backdrop must stop intercepting page interactions")
        for residentWindow in [window, tools, original] {
            assertResidentPanel(residentWindow)
        }
        window.setFrameOrigin(CGPoint(x: anchorFrame.minX + 40, y: anchorFrame.minY + 30))
        controller.toggleTranslationPin()

        XCTAssertFalse(controller.isTranslationPinned)
        XCTAssertEqual(window.frame, anchorFrame)
        XCTAssertTrue(backdrop.isVisible, "Unpinning explicitly restores the captured-page preview")
        XCTAssertFalse(backdrop.ignoresMouseEvents)
        XCTAssertTrue(controller.originalWindowForTesting === original, "Changing residency must preserve an open comparison")
        for captureWindow in [backdrop, window, tools, original] {
            XCTAssertEqual(captureWindow.level, .screenSaver)
        }
    }

    func testResidentCompareAndUpdatesKeepTheLivePageReleased() throws {
        try MarrUITestSupport.requireVisibleWindows()
        let fixture = try makeFixture()
        let controller = fixture.controller
        defer { controller.close() }
        controller.show()
        controller.showTranslatedImage(fixture.translation, originalImage: fixture.original)
        controller.toggleTranslationPin()
        let window = controller.windowForTesting
        let backdrop = controller.backdropWindowForTesting
        window.setFrameOrigin(CGPoint(x: window.frame.minX + 45, y: window.frame.minY + 25))
        let movedFrame = window.frame

        controller.toggleCompare()
        let tools = try XCTUnwrap(controller.toolWindowForTesting)
        let original = try XCTUnwrap(controller.originalWindowForTesting)
        for residentWindow in [window, tools, original] {
            assertResidentPanel(residentWindow)
        }

        // Simulate lifecycle notifications locally; do not activate or control
        // another application on the user's desktop during unit tests.
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        controller.updateTranslatedImage(fixture.translation, highlightPairs: [])
        controller.updateHighlightPairs([])

        XCTAssertTrue(controller.isTranslationPinned)
        XCTAssertEqual(window.frame, movedFrame)
        XCTAssertFalse(backdrop.isVisible, "Background translation updates must not re-freeze the live page")
        XCTAssertTrue(backdrop.ignoresMouseEvents)
        for residentWindow in [window, tools, original] {
            assertResidentPanel(residentWindow)
        }
        controller.toggleCompare()
        XCTAssertNil(controller.originalWindowForTesting)
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(tools.isVisible)
        XCTAssertFalse(backdrop.isVisible, "Done must close only the comparison while the translated result remains resident")
    }

    func testEscapeFromUnrelatedOrUnownedWindowsPassesThrough() throws {
        try MarrUITestSupport.requireVisibleWindows()
        let fixture = try makeFixture()
        let controller = fixture.controller
        defer { controller.close() }
        controller.show()
        controller.showTranslatedImage(fixture.translation, originalImage: fixture.original)
        controller.toggleTranslationPin()
        var closeCount = 0
        controller.onClose = { closeCount += 1 }
        let unrelatedWindow = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        unrelatedWindow.isReleasedWhenClosed = false
        defer { unrelatedWindow.close() }
        let unrelatedEscape = try keyEvent(in: unrelatedWindow)
        let unownedEscape = try keyEvent(in: nil)
        let ordinaryKey = try keyEvent(in: controller.windowForTesting, keyCode: UInt16(kVK_ANSI_A), characters: "a")

        XCTAssertTrue(unrelatedEscape.window === unrelatedWindow)
        XCTAssertNil(unownedEscape.window)
        for event in [unrelatedEscape, unownedEscape, ordinaryKey] {
            XCTAssertTrue(controller.handleKeyEvent(event) === event, "Events outside the overlay's Escape handler must retain their identity")
        }
        XCTAssertEqual(closeCount, 0)
        XCTAssertTrue(controller.windowForTesting.isVisible)
    }

    func testEscapeFromEachResidentWindowClosesItsSessionExactlyOnce() throws {
        try MarrUITestSupport.requireVisibleWindows()
        for ownerIndex in 0..<3 {
            let fixture = try makeFixture()
            let controller = fixture.controller
            defer { controller.close() }
            controller.show()
            controller.showTranslatedImage(fixture.translation, originalImage: fixture.original)
            controller.toggleTranslationPin()
            controller.toggleCompare()
            var closeCount = 0
            controller.onClose = { closeCount += 1 }
            let windows = [controller.windowForTesting,
                           try XCTUnwrap(controller.toolWindowForTesting),
                           try XCTUnwrap(controller.originalWindowForTesting)]
            let event = try keyEvent(in: windows[ownerIndex])

            XCTAssertNil(controller.handleKeyEvent(event), "Escape in any owned panel should dismiss that translation session")
            controller.close()

            XCTAssertEqual(closeCount, 1)
            XCTAssertFalse(controller.backdropWindowForTesting.isVisible)
            for window in windows {
                XCTAssertFalse(window.isVisible)
            }
        }
    }

    private func assertResidentPanel(_ window: NSWindow, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(window is NSPanel, file: file, line: line)
        XCTAssertTrue(window.styleMask.contains(.nonactivatingPanel), file: file, line: line)
        XCTAssertFalse(window.hidesOnDeactivate, file: file, line: line)
        XCTAssertEqual(window.level, .floating, file: file, line: line)
        XCTAssertTrue(window.isVisible, file: file, line: line)
        XCTAssertFalse(window.ignoresMouseEvents, file: file, line: line)
    }

    private func keyEvent(in window: NSWindow?, keyCode: UInt16 = UInt16(kVK_Escape), characters: String = "\u{1b}") throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window?.windowNumber ?? 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode
        ))
    }

    private func makeFixture() throws -> (controller: TranslationOverlayController, translation: NSImage, original: NSImage) {
        try MarrUITestSupport.requireVisibleWindows()
        let screen = try XCTUnwrap(NSScreen.main)
        let visible = screen.visibleFrame
        let size = CGSize(width: min(420, visible.width * 0.4), height: min(240, visible.height * 0.4))
        let anchor = CGRect(x: visible.minX + 70, y: visible.minY + 100, width: size.width, height: size.height).integral
        let translation = fixtureImage(size: anchor.size, title: "截图翻译", lines: ["译文已完成，原框选边框保持可见。", "点击右上角图标后，可拖动整个译文框。"])
        let original = fixtureImage(size: anchor.size, title: "Screenshot translation", lines: ["The translated selection stays visible.", "Move the result using the corner control."])
        let backdrop = fixtureImage(size: CGSize(width: 320, height: 200), title: "", lines: [])
        let snapshot = ScreenCaptureSnapshot(image: try XCTUnwrap(backdrop.cgImage(forProposedRect: nil, context: nil, hints: nil)), screenFrame: screen.frame)
        return (TranslationOverlayController(anchorRect: anchor, frozenSnapshot: snapshot), translation, original)
    }

    private func fixtureImage(size: CGSize, title: String, lines: [String]) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        (title as NSString).draw(at: CGPoint(x: 24, y: size.height - 60), withAttributes: [
            .font: NSFont.systemFont(ofSize: 24, weight: .semibold),
            .foregroundColor: NSColor(calibratedRed: 0.1, green: 0.2, blue: 0.4, alpha: 1)
        ])
        for (index, line) in lines.enumerated() {
            (line as NSString).draw(at: CGPoint(x: 24, y: size.height - 112 - CGFloat(index) * 34), withAttributes: [
                .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.black
            ])
        }
        image.unlockFocus()
        return image
    }

    private func clickPin(in window: NSWindow) throws {
        let point = CGPoint(x: window.contentLayoutRect.width - 24, y: window.contentLayoutRect.height - 24)
        try click(in: window, at: point)
    }

    private func click(in window: NSWindow, at point: CGPoint) throws {
        let events = try [NSEvent.EventType.leftMouseDown, .leftMouseUp].map { type in
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        // Queue the release first so a hit-routing regression cannot leave a
        // native window-drag tracking loop waiting indefinitely during this test.
        NSApp.postEvent(events[1], atStart: true)
        window.sendEvent(events[0])
        window.sendEvent(events[1])
    }

    private func contentReceivesDrag(in window: NSWindow) throws -> Bool {
        let content = try XCTUnwrap(window.contentView)
        let hit = content.hitTest(CGPoint(x: content.bounds.midX, y: content.bounds.midY))
        return hit.map { String(describing: type(of: $0)).contains("TranslationWindowDragView") } ?? false
    }

    private func settle(_ window: NSWindow) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView?.displayIfNeeded()
    }

    private func bitmap(_ window: NSWindow) throws -> NSBitmapImageRep {
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        let result = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: result)
        return result
    }

    private func recognizedText(in window: NSWindow) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: try XCTUnwrap(bitmap(window).cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    private func savePreview(_ controller: TranslationOverlayController) throws {
        let windows = [controller.windowForTesting] + [controller.toolWindowForTesting].compactMap { $0 }
        let bounds = windows.reduce(CGRect.null) { $0.union($1.frame) }.insetBy(dx: -18, dy: -18)
        let captures = try windows.map { window in
            (frame: window.frame, image: NSImage(cgImage: try XCTUnwrap(bitmap(window).cgImage), size: window.frame.size))
        }
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        NSColor(calibratedWhite: 0.9, alpha: 1).setFill()
        CGRect(origin: .zero, size: bounds.size).fill()
        for capture in captures {
            capture.image.draw(in: capture.frame.offsetBy(dx: -bounds.minX, dy: -bounds.minY), from: .zero, operation: .sourceOver, fraction: 1)
        }
        image.unlockFocus()
        let result = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let data = try XCTUnwrap(result.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OpenLens-translation-pin-preview.png")
        try data.write(to: url, options: .atomic)
        print("Translation pin preview: \(url.path)")
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = "translation-pinned-result-with-compare"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
