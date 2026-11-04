import AppKit
import XCTest
@testable import Marr

final class CaptureImagePreparationTests: XCTestCase {
    func testEncodingPreservesMetadataAndDoesNotUpscaleSmallImages() throws {
        let capture = try XCTUnwrap(CaptureImagePreparation.jpeg(makeImage(width: 120, height: 80), fileName: "Window Capture"))
        XCTAssertEqual(capture.fileName, "Window Capture")
        XCTAssertEqual(capture.mimeType, "image/jpeg")
        XCTAssertEqual(capture.image.size, CGSize(width: 120, height: 80))
        let decoded = try XCTUnwrap(NSBitmapImageRep(data: capture.data))
        XCTAssertEqual(decoded.pixelsWide, 120)
        XCTAssertEqual(decoded.pixelsHigh, 80)
    }

    func testBothOrientationsKeepAspectRatioWithinVisionPixelBudget() throws {
        for (width, height) in [(4400, 40), (40, 4400)] {
            let capture = try XCTUnwrap(CaptureImagePreparation.jpeg(makeImage(width: width, height: height), fileName: "Screen Capture"))
            let decoded = try XCTUnwrap(NSBitmapImageRep(data: capture.data))
            XCTAssertEqual(decoded.pixelsWide, width / 2)
            XCTAssertEqual(decoded.pixelsHigh, height / 2)
            XCTAssertEqual(capture.image.size, CGSize(width: width / 2, height: height / 2))
        }
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }
}
