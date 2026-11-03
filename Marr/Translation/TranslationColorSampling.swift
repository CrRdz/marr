import AppKit
import CoreText
import Foundation

enum TranslationColorSampling {
    static func dominantInteriorBackgroundColor(
        in rects: [CGRect],
        bitmap: NSBitmapImageRep,
        bounds: CGRect
    ) -> NSColor? {
        var counts: [Int: Int] = [:]
        var redSums: [Int: CGFloat] = [:]
        var greenSums: [Int: CGFloat] = [:]
        var blueSums: [Int: CGFloat] = [:]

        for rect in rects where rect.width > 1 && rect.height > 1 {
            let columns = max(3, min(36, Int(ceil(rect.width / 2))))
            let rows = max(3, min(18, Int(ceil(rect.height / 2))))
            for row in 0..<rows {
                let y = rect.minY + (CGFloat(row) + 0.5) / CGFloat(rows) * rect.height
                for column in 0..<columns {
                    let x = rect.minX + (CGFloat(column) + 0.5) / CGFloat(columns) * rect.width
                    guard let color = sampledColor(
                        appKitX: x,
                        appKitY: y,
                        bitmap: bitmap,
                        bounds: bounds
                    )?.usingColorSpace(.sRGB) else {
                        continue
                    }

                    let redBin = Int((color.redComponent * 255).rounded()) / 16
                    let greenBin = Int((color.greenComponent * 255).rounded()) / 16
                    let blueBin = Int((color.blueComponent * 255).rounded()) / 16
                    let key = (redBin << 16) | (greenBin << 8) | blueBin
                    counts[key, default: 0] += 1
                    redSums[key, default: 0] += color.redComponent
                    greenSums[key, default: 0] += color.greenComponent
                    blueSums[key, default: 0] += color.blueComponent
                }
            }
        }

        guard
            let dominant = counts.max(by: { $0.value < $1.value }),
            dominant.value >= 2
        else {
            return nil
        }

        let count = CGFloat(dominant.value)
        return NSColor(
            srgbRed: redSums[dominant.key, default: 0] / count,
            green: greenSums[dominant.key, default: 0] / count,
            blue: blueSums[dominant.key, default: 0] / count,
            alpha: 1
        )
    }

    static func sampledForegroundColor(
        in rects: [CGRect],
        bitmap: NSBitmapImageRep,
        backgroundColor: NSColor,
        bounds: CGRect
    ) -> NSColor? {
        var candidates: [(color: NSColor, distance: CGFloat)] = []

        for rect in rects where rect.width > 1 && rect.height > 1 {
            // Sparse grids repeatedly hit antialiased edges on short/thin
            // words. Sample at native pixel centers, with a bounded budget
            // for large regions, so solid stroke interiors can establish ink.
            let scaleX = CGFloat(bitmap.pixelsWide) / bounds.width
            let scaleY = CGFloat(bitmap.pixelsHigh) / bounds.height
            let left = max(0, Int(floor(rect.minX * scaleX)))
            let right = min(bitmap.pixelsWide, Int(ceil(rect.maxX * scaleX)))
            let top = max(0, Int(floor((bounds.maxY - rect.maxY) * scaleY)))
            let bottom = min(bitmap.pixelsHigh, Int(ceil((bounds.maxY - rect.minY) * scaleY)))
            let area = max(0, right - left) * max(0, bottom - top)
            let step = max(1, Int(ceil(sqrt(Double(area) / 16_384))))

            for y in stride(from: top, to: bottom, by: step) {
                for x in stride(from: left, to: right, by: step) {
                    guard let sampled = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                          sampled.alphaComponent > 0.1 else {
                        continue
                    }

                    let distance = rgbDistance(sampled, backgroundColor)
                    if distance >= 0.10 {
                        candidates.append((sampled, distance))
                    }
                }
            }
        }

        guard !candidates.isEmpty else {
            return nil
        }

        // Find the dominant ink first: a bold black page number must not
        // recolor an otherwise gray footer, nor should a dark speck win.
        let buckets = Dictionary(grouping: candidates) { candidate in
            let color = candidate.color
            let r = Int((color.redComponent * 255).rounded()) / 12
            let g = Int((color.greenComponent * 255).rounded()) / 12
            let b = Int((color.blueComponent * 255).rounded()) / 12
            return (r << 16) | (g << 8) | b
        }
        let dominant = buckets.values.max {
            if $0.count != $1.count { return $0.count < $1.count }
            return ($0.map(\.distance).max() ?? 0) < ($1.map(\.distance).max() ?? 0)
        } ?? candidates
        let sorted = dominant.sorted { $0.distance > $1.distance }
        // Estimate the stroke core, not a fixed average of core and edge
        // pixels. A percentile tolerates a few darker specks; the narrow
        // contrast band retains genuine gray/colored text and works on dark
        // backgrounds too, without snapping everything to black or white.
        let coreDistance = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.05))].distance
        return averageColor(sorted.prefix { $0.distance >= coreDistance - 0.025 }.map(\.color))
    }

    static func rgbDistance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        guard
            let lhs = lhs.usingColorSpace(.sRGB),
            let rhs = rhs.usingColorSpace(.sRGB)
        else {
            return 0
        }

        let red = lhs.redComponent - rhs.redComponent
        let green = lhs.greenComponent - rhs.greenComponent
        let blue = lhs.blueComponent - rhs.blueComponent
        return sqrt(red * red + green * green + blue * blue)
    }

    static func sampledBackgroundColor(
        in rect: CGRect,
        bitmap: NSBitmapImageRep,
        bounds: CGRect
    ) -> NSColor? {
        let sampleOffset = max(2, min(10, rect.height * 0.20))
        let fractions: [CGFloat] = [0.08, 0.22, 0.38, 0.5, 0.62, 0.78, 0.92]
        var points: [CGPoint] = []

        for fraction in fractions {
            points.append(CGPoint(x: rect.minX + rect.width * fraction, y: rect.minY - sampleOffset))
            points.append(CGPoint(x: rect.minX + rect.width * fraction, y: rect.maxY + sampleOffset))
            points.append(CGPoint(x: rect.minX - sampleOffset, y: rect.minY + rect.height * fraction))
            points.append(CGPoint(x: rect.maxX + sampleOffset, y: rect.minY + rect.height * fraction))
        }

        let colors = points.compactMap { point in
            sampledColor(appKitX: point.x, appKitY: point.y, bitmap: bitmap, bounds: bounds)
        }

        return dominantBackgroundColor(colors) ?? averageColor(colors)
    }

    static func averageColor(_ colors: [NSColor]) -> NSColor? {
        guard !colors.isEmpty else {
            return nil
        }

        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        var count: CGFloat = 0

        for rawColor in colors {
            guard let color = rawColor.usingColorSpace(.sRGB) else {
                continue
            }

            red += color.redComponent
            green += color.greenComponent
            blue += color.blueComponent
            alpha += color.alphaComponent
            count += 1
        }

        guard count > 0 else {
            return nil
        }

        return NSColor(
            srgbRed: red / count,
            green: green / count,
            blue: blue / count,
            alpha: alpha / count
        )
    }

    static func dominantBackgroundColor(_ colors: [NSColor]) -> NSColor? {
        let converted = colors.compactMap { color -> NSColor? in
            color.usingColorSpace(.sRGB)
        }
        guard !converted.isEmpty else {
            return nil
        }

        // Flat screenshot backgrounds usually occupy most sample points. Keep
        // that observed color instead of averaging in nearby text antialiasing
        // or overlay controls. Apply the same rule to light, dark, and colored
        // backgrounds; only fall back to luminance trimming without a majority.
        let colorGroups = Dictionary(grouping: converted) { color in
            let red = Int((color.redComponent * 255).rounded())
            let green = Int((color.greenComponent * 255).rounded())
            let blue = Int((color.blueComponent * 255).rounded())
            return [red, green, blue]
        }
        if let majority = colorGroups.values.max(by: { $0.count < $1.count }),
           majority.count > converted.count / 2 {
            return averageColor(majority)
        }

        let sorted = converted.sorted { lhs, rhs in
            luminance(lhs) < luminance(rhs)
        }
        let median = luminance(sorted[sorted.count / 2])
        let selected: [NSColor]

        if median < 0.5 {
            let count = max(1, Int(ceil(Double(sorted.count) * 0.68)))
            selected = Array(sorted.prefix(count))
        } else {
            let count = max(1, Int(ceil(Double(sorted.count) * 0.68)))
            selected = Array(sorted.suffix(count))
        }

        return averageColor(selected)
    }

    static func luminance(_ color: NSColor) -> CGFloat {
        0.2126 * color.redComponent
            + 0.7152 * color.greenComponent
            + 0.0722 * color.blueComponent
    }

    static func blendedColor(from start: NSColor, to end: NSColor, progress: CGFloat) -> NSColor {
        guard
            let start = start.usingColorSpace(.sRGB),
            let end = end.usingColorSpace(.sRGB)
        else {
            return start
        }

        let clampedProgress = min(max(progress, 0), 1)
        return NSColor(
            srgbRed: start.redComponent + (end.redComponent - start.redComponent) * clampedProgress,
            green: start.greenComponent + (end.greenComponent - start.greenComponent) * clampedProgress,
            blue: start.blueComponent + (end.blueComponent - start.blueComponent) * clampedProgress,
            alpha: start.alphaComponent + (end.alphaComponent - start.alphaComponent) * clampedProgress
        )
    }

    static func sampledColor(
        appKitX: CGFloat,
        appKitY: CGFloat,
        bitmap: NSBitmapImageRep,
        bounds: CGRect
    ) -> NSColor? {
        let clampedX = min(max(bounds.minX, appKitX), bounds.maxX - 1)
        let clampedY = min(max(bounds.minY, appKitY), bounds.maxY - 1)
        let normalizedX = (clampedX - bounds.minX) / max(bounds.width, 1)
        let normalizedY = (clampedY - bounds.minY) / max(bounds.height, 1)
        let x = min(
            max(0, Int((normalizedX * CGFloat(bitmap.pixelsWide)).rounded(.down))),
            bitmap.pixelsWide - 1
        )
        let y = min(
            max(
                0,
                bitmap.pixelsHigh - 1
                    - Int((normalizedY * CGFloat(bitmap.pixelsHigh)).rounded(.down))
            ),
            bitmap.pixelsHigh - 1
        )
        return bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
    }

    static func color(from hex: String?) -> NSColor? {
        guard let hex else {
            return nil
        }

        let cleaned = hex
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let expanded: String

        if cleaned.count == 3 {
            expanded = cleaned.map { "\($0)\($0)" }.joined()
        } else {
            expanded = cleaned
        }

        guard expanded.count == 6, let value = Int(expanded, radix: 16) else {
            return nil
        }

        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1
        )
    }

    static func readableTextColor(on backgroundColor: NSColor) -> NSColor {
        guard let color = backgroundColor.usingColorSpace(.sRGB) else {
            return .labelColor
        }

        let luminance = 0.2126 * color.redComponent
            + 0.7152 * color.greenComponent
            + 0.0722 * color.blueComponent
        return luminance > 0.55 ? .black : .white
    }

}
