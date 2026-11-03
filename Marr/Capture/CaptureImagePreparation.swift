import AppKit

/// Shared pixel budget and encoding for window and selection captures.
enum CaptureImagePreparation {
    static func jpeg(_ source: CGImage, fileName: String) -> PickedImage? {
        let prepared = prepareForVision(source)
        let bitmap = NSBitmapImageRep(cgImage: prepared)
        guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.88]) else { return nil }
        return PickedImage(data: data, mimeType: "image/jpeg", fileName: fileName,
            image: NSImage(cgImage: prepared, size: NSSize(width: prepared.width, height: prepared.height)))
    }

    private static func prepareForVision(_ image: CGImage) -> CGImage {
        let maxPixelDimension = 2_200
        let maxDimension = max(image.width, image.height)
        guard maxDimension > maxPixelDimension else { return image }

        let scale = CGFloat(maxPixelDimension) / CGFloat(maxDimension)
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }
}
