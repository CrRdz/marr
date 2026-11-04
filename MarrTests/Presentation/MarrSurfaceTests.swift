import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Marr

final class MarrSurfaceTests: XCTestCase {
    func testSecondaryAndControlClicksOpenMenuWithoutStartingCapture() {
        XCTAssertTrue(MarrStatusItemInteraction.opensMenu(type: .rightMouseUp, clickCount: 1, modifiers: []))
        XCTAssertTrue(MarrStatusItemInteraction.opensMenu(type: .leftMouseUp, clickCount: 1, modifiers: .control))
        XCTAssertTrue(MarrStatusItemInteraction.opensMenu(type: .leftMouseUp, clickCount: 2, modifiers: []))
        XCTAssertFalse(MarrStatusItemInteraction.opensMenu(type: .leftMouseUp, clickCount: 1, modifiers: []))
    }

    @MainActor
    func testAllLightSurfacesMatchTheWhiteInputWithoutFlatteningDarkHierarchy() throws {
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        for role in MarrUI.SurfaceRole.allCases {
            light.performAsCurrentDrawingAppearance {
                let color = NSColor(MarrUI.Surface.color(role)).usingColorSpace(.sRGB)!
                XCTAssertEqual(color.redComponent, 1, accuracy: 0.001, role.rawValue)
                XCTAssertEqual(color.greenComponent, 1, accuracy: 0.001, role.rawValue)
                XCTAssertEqual(color.blueComponent, 1, accuracy: 0.001, role.rawValue)
                XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.001, role.rawValue)
            }
        }
        dark.performAsCurrentDrawingAppearance {
            let canvas = NSColor(MarrUI.Surface.canvas).usingColorSpace(.sRGB)!
            let raised = NSColor(MarrUI.Surface.raised).usingColorSpace(.sRGB)!
            XCTAssertLessThan(canvas.redComponent, raised.redComponent)
            XCTAssertLessThan(raised.redComponent, 0.25)
        }
    }

    @MainActor
    func testLongTranscriptScrollStopsPublishingAfterTitleFadeRange() {
        let chrome = MarrConversationScrollChrome()
        chrome.update(origin: -72)
        var changes = 0
        let observation = chrome.objectWillChange.sink { changes += 1 }
        for distance in 73...2_000 { chrome.update(origin: -CGFloat(distance)) }
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(chrome.distance, 72)
        chrome.update(origin: 0)
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(chrome.distance, 0)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testGeneratedIconAssetsAreBundledVisibleAndTemplateTintable() throws {
        for (symbol, _) in MarrIcons.aliases {
            let image = try XCTUnwrap(MarrIcons.image(named: symbol), "Missing bundled artwork for \(symbol)")
            XCTAssertTrue(image.isTemplate, symbol)
            XCTAssertEqual(image.size, NSSize(width: 16, height: 16), symbol)
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil)))
            var visiblePixels = 0, transparentPixels = 0
            for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
                let alpha = bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0
                if alpha > 0.5 { visiblePixels += 1 }
                if alpha < 0.01 { transparentPixels += 1 }
            } }
            for point in [(0, 0), (bitmap.pixelsWide - 1, 0),
                          (0, bitmap.pixelsHigh - 1), (bitmap.pixelsWide - 1, bitmap.pixelsHigh - 1)] {
                XCTAssertEqual(bitmap.colorAt(x: point.0, y: point.1)?.alphaComponent ?? 1, 0,
                               accuracy: 0.01, "Nontransparent corner: \(symbol)")
            }
            XCTAssertGreaterThan(visiblePixels, 5, "Empty artwork: \(symbol)")
            XCTAssertGreaterThan(transparentPixels, bitmap.pixelsWide * bitmap.pixelsHigh / 4, "Opaque background: \(symbol)")
        }
    }

    @MainActor
    func testIconSizingDoesNotMutateOtherControlsOrCachedAssets() throws {
        let menu = try XCTUnwrap(MarrIcons.image(named: "folder", size: 16, accessibilityDescription: "Project"))
        let hero = try XCTUnwrap(MarrIcons.image(named: "folder", size: 32))
        XCTAssertEqual(menu.size.width, 16)
        XCTAssertEqual(hero.size.width, 32)
        XCTAssertEqual(menu.accessibilityDescription, "Project")
        XCTAssertEqual(try XCTUnwrap(MarrIcons.image(named: "folder")).size.width, 16)
        XCTAssertNotNil(MarrIcons.image(named: "future-unknown-symbol"), "Future symbols have a visible question-mark fallback")
    }

    func testScrollFadesOnlyIndicateContentBeyondTheVisibleEdges() {
        func edges(_ height: CGFloat, _ origin: CGFloat, flipped: Bool = true) -> MarrScrollOverflow {
            MarrScrollOverflow(documentHeight: height, viewportHeight: 100,
                               origin: origin, isFlipped: flipped)
        }
        XCTAssertEqual(edges(80, 0), MarrScrollOverflow())
        XCTAssertFalse(edges(300, 0).top)
        XCTAssertTrue(edges(300, 0).bottom)
        XCTAssertTrue(edges(300, 100).top)
        XCTAssertTrue(edges(300, 100).bottom)
        XCTAssertTrue(edges(300, 200).top)
        XCTAssertFalse(edges(300, 200).bottom)
        XCTAssertEqual(edges(300, -30), edges(300, 0))
        XCTAssertEqual(edges(300, 250), edges(300, 200))
        XCTAssertEqual(edges(300, 0, flipped: false), edges(300, 200))
        XCTAssertEqual(edges(300, 200, flipped: false), edges(300, 0))
        XCTAssertEqual(edges(.infinity, 0), MarrScrollOverflow())
    }
}
