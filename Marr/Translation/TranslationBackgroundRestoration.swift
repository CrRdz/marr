import AppKit
import CoreText
import Foundation

enum TranslationBackgroundRestoration {
    private struct BackgroundSample {
        let x: Double
        let y: Double
        let color: SIMD3<Double>
        var opacity: Double = 1
    }

    struct BackgroundRaster {
        let width: Int
        let height: Int
        let colorSpace: CGColorSpace
        let pixels: [UInt8]

        init?(image: CGImage) {
            let width = image.width
            let height = image.height
            let sourceColorSpace = image.colorSpace?.model == .rgb
                ? image.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
            // AppKit can supply extended-range RGB even for ordinary SDR
            // content. Eight-bit sampling needs the same primaries in standard
            // range; otherwise CGContext fails and disables local recovery.
            let colorSpace = CGColorSpaceUsesExtendedRange(sourceColorSpace)
                ? CGColorSpaceCreateCopyWithStandardRange(sourceColorSpace) : sourceColorSpace
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { return nil }
            self.width = width
            self.height = height
            self.colorSpace = colorSpace
            pixels = bytes
        }

        func color(x: Int, y: Int) -> SIMD3<Double>? {
            let offset = (y * width + x) * 4
            let alpha = Double(pixels[offset + 3])
            guard alpha > 0 else { return nil }
            return SIMD3(Double(pixels[offset]), Double(pixels[offset + 1]), Double(pixels[offset + 2])) / alpha
        }
    }

    private struct BackgroundSurface {
        let origin: SIMD3<Double>
        let dx: SIMD3<Double>
        let dy: SIMD3<Double>

        func color(x: Double, y: Double) -> SIMD3<Double> { origin + dx * x + dy * y }
    }

    private struct BackgroundField {
        let surfaces: [(center: Double, surface: BackgroundSurface)]

        func color(x: Double, y: Double) -> SIMD3<Double> {
            guard surfaces.count > 1 else { return surfaces[0].surface.color(x: x, y: y) }
            guard let upper = surfaces.firstIndex(where: { $0.center >= x }) else {
                return surfaces[surfaces.count - 1].surface.color(x: x, y: y)
            }
            guard upper > 0 else { return surfaces[0].surface.color(x: x, y: y) }
            let lhs = surfaces[upper - 1], rhs = surfaces[upper]
            let progress = (x - lhs.center) / max(0.0001, rhs.center - lhs.center)
            return lhs.surface.color(x: x, y: y) * (1 - progress) + rhs.surface.color(x: x, y: y) * progress
        }
    }

    static func hasUniformFormulaBackground(
        in rect: CGRect, raster: BackgroundRaster?, bounds: CGRect, excludingInk: [CGRect] = []
    ) -> Bool {
        guard let raster else { return false }
        var samples: [BackgroundSample] = []
        var rowFractions = (0..<6).map { (Double($0) + 0.5) / 6 }
        if !excludingInk.isEmpty {
            // Dense prose can leave only a one-pixel gutter above its glyphs.
            // A cell-center grid misses it and sees background on just one
            // side of the row. Include both inner edges, without sampling a
            // neighboring line or weakening the two-axis coverage check.
            let edge = min(0.05, 0.5 / max(1, Double(rect.height / bounds.height) * Double(raster.height)))
            rowFractions += [edge, 1 - edge]
        }
        for v in rowFractions {
            for column in 0..<12 {
                let u = (Double(column) + 0.5) / 12
                let point = CGPoint(x: rect.minX + rect.width * u, y: rect.maxY - rect.height * v)
                // Foreground letters are not background texture. Sample the
                // gutters around measured ink, while still requiring coverage
                // across both axes to detect gradients and changing opacity.
                if excludingInk.contains(where: { $0.contains(point) }) { continue }
                let x = min(raster.width - 1, max(0, Int((rect.minX + rect.width * u) / bounds.width * CGFloat(raster.width))))
                let y = min(raster.height - 1, max(0, Int((bounds.maxY - rect.maxY + rect.height * v) / bounds.height * CGFloat(raster.height))))
                if let color = raster.color(x: x, y: y) {
                    let opacity = Double(raster.pixels[(y * raster.width + x) * 4 + 3]) / 255
                    samples.append(BackgroundSample(x: u, y: v, color: color, opacity: opacity))
                }
            }
        }
        guard samples.count >= 12,
              (samples.map(\.x).max()! - samples.map(\.x).min()!) >= 0.6,
              (samples.map(\.y).max()! - samples.map(\.y).min()!) >= 0.5 else { return false }
        guard let surface = robustBackgroundSurface(samples) else { return false }
        // A constant average can hide visible texture. Moving its rectangular
        // crop would still create a seam, even if the fitted plane is flat.
        let flatSamples = samples.filter {
            channelDistance($0.color, surface.color(x: $0.x, y: $0.y)) <= 2.0 / 255
        }
        guard flatSamples.count * 100 >= samples.count * 80,
              let opacity = robustBackgroundSurface(samples.map {
                  BackgroundSample(x: $0.x, y: $0.y, color: SIMD3(repeating: $0.opacity))
              }) else { return false }
        guard samples.filter({
            abs($0.opacity - opacity.color(x: $0.x, y: $0.y).x) <= 2.0 / 255
        }).count * 100 >= samples.count * 80 else { return false }
        let origin = surface.color(x: 0, y: 0)
        return [(1.0, 0.0), (0.0, 1.0), (1.0, 1.0)].allSatisfy {
            channelDistance(origin, surface.color(x: $0.0, y: $0.1)) <= 2.0 / 255
                && abs(opacity.origin.x - opacity.color(x: $0.0, y: $0.1).x) <= 2.0 / 255
        }
    }

    private static func backgroundField(samples: [BackgroundSample], aspectRatio: Double) -> BackgroundField? {
        guard !samples.isEmpty else { return nil }
        let global = robustBackgroundSurface(samples)
            ?? robustBackgroundSurface(samples, tolerance: 0.025)
        if let global {
            let agreement = samples.filter {
                channelDistance($0.color, global.color(x: $0.x, y: $0.y)) < 0.012
            }.count
            if agreement * 100 >= samples.count * 65 {
                return BackgroundField(surfaces: [(0.5, global)])
            }
        }
        // Curved lighting and photographic shading are not a single plane.
        // Overlapping local fits follow that variation without repainting
        // untouched pixels or extending one sampled color across the line.
        let count = max(2, min(12, Int(ceil(aspectRatio / 1.5))))
        var surfaces: [(center: Double, surface: BackgroundSurface)] = []
        for index in 0..<count {
            let center = (Double(index) + 0.5) / Double(count)
            let local = samples.filter { abs($0.x - center) <= 0.85 / Double(count) }
            if let surface = robustBackgroundSurface(local)
                ?? robustBackgroundSurface(local, tolerance: 0.025) { surfaces.append((center, surface)) }
        }
        if surfaces.count >= 2 { return BackgroundField(surfaces: surfaces) }
        if let global { return BackgroundField(surfaces: [(0.5, global)]) }
        // On highly textured backgrounds use a robust color only to identify
        // contrasting ink; never use this fallback to fill the whole OCR box.
        let colors = (0..<3).map { channel in samples.map { $0.color[channel] }.sorted() }
        let median = SIMD3(colors[0][samples.count / 2], colors[1][samples.count / 2], colors[2][samples.count / 2])
        return BackgroundField(surfaces: [(0.5, BackgroundSurface(origin: median, dx: .zero, dy: .zero))])
    }

    static func channelDistance(_ lhs: SIMD3<Double>, _ rhs: SIMD3<Double>) -> Double {
        let delta = lhs - rhs
        return max(abs(delta.x), abs(delta.y), abs(delta.z))
    }

    private static func matchesSourceInk(
        _ observed: SIMD3<Double>, background: SIMD3<Double>,
        palette: [SIMD3<Double>], tolerance: Double = 0.035
    ) -> Bool {
        let delta = observed - background
        return palette.contains { ink in
            let direction = ink - background
            let squared = direction.x * direction.x + direction.y * direction.y + direction.z * direction.z
            guard squared > 0.0001 else { return false }
            let projection = (delta.x * direction.x + delta.y * direction.y + delta.z * direction.z) / squared
            guard projection > 0, projection < 1.5 else { return false }
            return channelDistance(observed, background + direction * projection) < tolerance
        }
    }

    private static func fittedBackgroundSurface(_ samples: [BackgroundSample]) -> BackgroundSurface? {
        guard samples.count >= 3 else { return nil }
        let count = Double(samples.count)
        let mx = samples.reduce(0) { $0 + $1.x } / count
        let my = samples.reduce(0) { $0 + $1.y } / count
        let mean = samples.reduce(SIMD3<Double>.zero) { $0 + $1.color } / count
        var xx = 0.0, xy = 0.0, yy = 0.0
        var cx = SIMD3<Double>.zero, cy = SIMD3<Double>.zero
        for sample in samples {
            let x = sample.x - mx, y = sample.y - my
            xx += x * x; xy += x * y; yy += y * y
            cx += (sample.color - mean) * x
            cy += (sample.color - mean) * y
        }
        let determinant = xx * yy - xy * xy
        guard determinant > 0.00001 else { return nil }
        let dx = (cx * yy - cy * xy) / determinant
        let dy = (cy * xx - cx * xy) / determinant
        return BackgroundSurface(origin: mean - dx * mx - dy * my, dx: dx, dy: dy)
    }

    /// Fit the low-frequency surface from a consensus of actual source pixels.
    /// Text and antialiasing are outliers; a constant is a special case of the
    /// same model, so a card's tint never gets replaced by the page's color.
    private static func robustBackgroundSurface(_ samples: [BackgroundSample], tolerance: Double = 0.012) -> BackgroundSurface? {
        guard samples.count >= 12 else { return nil }
        var best: BackgroundSurface?
        var bestCount = 0
        var bestError = Double.infinity
        func consider(_ surface: BackgroundSurface) {
            var count = 0, error = 0.0
            for sample in samples {
                let distance = channelDistance(sample.color, surface.color(x: sample.x, y: sample.y))
                if distance < tolerance { count += 1; error += distance }
            }
            if count > bestCount || (count == bestCount && error < bestError) {
                best = surface; bestCount = count; bestError = error
            }
        }
        // A deterministic sequence keeps screenshots and regression outputs
        // stable. Sampling well-spread triples also handles two-axis gradients.
        var state: UInt64 = 0x6d617272
        for _ in 0..<64 {
            var triple: [BackgroundSample] = []
            for _ in 0..<3 {
                state = state &* 6364136223846793005 &+ 1
                triple.append(samples[Int((state >> 32) % UInt64(samples.count))])
            }
            if let surface = fittedBackgroundSurface(triple) { consider(surface) }
        }
        guard var surface = best, bestCount >= max(12, samples.count * 45 / 100) else { return nil }
        for _ in 0..<3 {
            let inliers = samples.filter {
                channelDistance($0.color, surface.color(x: $0.x, y: $0.y)) < tolerance
            }
            guard let refined = fittedBackgroundSurface(inliers) else { break }
            surface = refined
        }
        return surface
    }

    static func restoreLocalBackground(
        in rect: CGRect,
        samplingRect: CGRect,
        raster: BackgroundRaster?,
        bounds: CGRect,
        sourceImage: NSImage,
        fallbackSourceRect: CGRect?,
        fallbackColor: NSColor,
        modelBackgroundHint: NSColor? = nil
    ) {
        guard let raster else {
            paintBackgroundPatch(in: rect, sourceImage: sourceImage,
                                 sourceRect: fallbackSourceRect, color: fallbackColor)
            return
        }
        let scaleX = CGFloat(raster.width) / bounds.width
        let scaleY = CGFloat(raster.height) / bounds.height
        let x0 = max(0, Int(floor(rect.minX * scaleX)))
        let x1 = min(raster.width, Int(ceil(rect.maxX * scaleX)))
        let y0 = max(0, Int(floor((bounds.maxY - rect.maxY) * scaleY)))
        let y1 = min(raster.height, Int(ceil((bounds.maxY - rect.minY) * scaleY)))
        guard x1 > x0, y1 > y0 else { return }
        func pixel(_ x: Int, _ y: Int) -> SIMD3<Double>? {
            raster.color(x: x, y: y)
        }
        let core = samplingRect.intersection(bounds)
        let columns = max(4, min(48, Int(core.width * scaleX)))
        let rows = max(4, min(24, Int(core.height * scaleY)))
        var samples: [BackgroundSample] = []
        var transparentSamples = 0
        for row in 0..<rows {
            for column in 0..<columns {
                let x = min(raster.width - 1, max(0, Int((core.minX + core.width * (CGFloat(column) + 0.5) / CGFloat(columns)) * scaleX)))
                let y = min(raster.height - 1, max(0, Int((bounds.maxY - core.maxY + core.height * (CGFloat(row) + 0.5) / CGFloat(rows)) * scaleY)))
                let opacity = Double(raster.pixels[(y * raster.width + x) * 4 + 3]) / 255
                if opacity < 0.01 { transparentSamples += 1 }
                if let color = pixel(x, y) {
                    samples.append(BackgroundSample(x: (Double(x - x0) + 0.5) / Double(x1 - x0),
                        y: (Double(y - y0) + 0.5) / Double(y1 - y0), color: color, opacity: opacity))
                }
            }
        }
        if transparentSamples * 100 >= columns * rows * 50 {
            // Text-only PNGs have no surface to sample. Restore transparency,
            // respecting the caller's immutable math/code clipping paths.
            NSGraphicsContext.current?.cgContext.clear(rect)
            return
        }
        guard var surface = backgroundField(samples: samples, aspectRatio: Double(rect.width / max(rect.height, 1))) else {
            paintBackgroundPatch(in: rect, sourceImage: sourceImage,
                                 sourceRect: fallbackSourceRect, color: fallbackColor)
            return
        }
        // The image-only fallback may supply a box completely occupied by
        // foreground, with no OCR token ownership. In that ambiguous case a
        // model hint is usable only when actual surrounding pixels corroborate
        // it; the pixels, never the approximate metadata, provide the fill.
        if let colorSpace = NSColorSpace(cgColorSpace: raster.colorSpace),
           let hint = modelBackgroundHint?.usingColorSpace(colorSpace) {
            let expected = SIMD3(Double(hint.redComponent), Double(hint.greenComponent), Double(hint.blueComponent))
            var exterior: [BackgroundSample] = []
            for index in 0..<12 {
                let u = (Double(index) + 0.5) / 12
                for yy in [y0 - 2, y1 + 1] where yy >= 0 && yy < raster.height {
                    let xx = min(raster.width - 1, max(0, x0 + Int(u * Double(x1 - x0))))
                    if let color = pixel(xx, yy) {
                        exterior.append(BackgroundSample(x: (Double(xx - x0) + 0.5) / Double(x1 - x0),
                            y: (Double(yy - y0) + 0.5) / Double(y1 - y0), color: color))
                    }
                }
            }
            if let outside = robustBackgroundSurface(exterior),
               channelDistance(expected, outside.color(x: 0.5, y: 0.5)) < 0.16,
               channelDistance(expected, surface.color(x: 0.5, y: 0.5)) > 0.20 {
                surface = BackgroundField(surfaces: [(0.5, outside)])
            }
        }

        // Collect source ink colors, not the requested target text color.
        // This also excludes a white page beyond a colored card's edge: it is
        // not an antialiased mixture of the card background and its lettering.
        let residuals = samples.map { channelDistance($0.color, surface.color(x: $0.x, y: $0.y)) }.sorted()
        // Include the tails of background variation and local extrapolation at
        // OCR padding. Flat surfaces still use the separate 2/255 floor below.
        let textureTolerance = min(0.16, residuals[residuals.count / 2] * 4)
        var outliers = samples.filter {
            channelDistance($0.color, surface.color(x: $0.x, y: $0.y)) > max(0.02, textureTolerance)
        }
        let coreX0 = max(0, Int(floor(core.minX * scaleX)))
        let coreX1 = min(raster.width, Int(ceil(core.maxX * scaleX)))
        let coreY0 = max(0, Int(floor((bounds.maxY - core.maxY) * scaleY)))
        let coreY1 = min(raster.height, Int(ceil((bounds.maxY - core.minY) * scaleY)))
        let corePixels = max(0, coreX1 - coreX0) * max(0, coreY1 - coreY0)
        let useDenseInkSamples = corePixels > 0 && corePixels <= 65_536
        if useDenseInkSamples {
            // Small JPEG labels can mix a colored glyph with an adjacent dark
            // curve in only a few pixels. Learn those real shades at full pixel
            // resolution, while retaining the robust, sparse BACKGROUND fit.
            // The area limit bounds both the work and temporary storage.
            outliers.removeAll(keepingCapacity: true)
            for y in coreY0..<coreY1 {
                guard !Task.isCancelled else { return }
                for x in coreX0..<coreX1 {
                    guard let color = pixel(x, y) else { continue }
                    let u = (Double(x - x0) + 0.5) / Double(x1 - x0)
                    let v = (Double(y - y0) + 0.5) / Double(y1 - y0)
                    if channelDistance(color, surface.color(x: u, y: v)) > max(0.02, textureTolerance) {
                        outliers.append(BackgroundSample(x: u, y: v, color: color))
                    }
                }
            }
        }
        // Keep a sampled shade whenever the existing palette cannot explain
        // it. Fixed hue bins discard clipped/resampled blue fringes; raw color
        // frequency instead lets common antialiasing shades crowd out red text.
        // Strong ink is selected first, then weaker antialiasing blends share
        // its representative. The tighter training error leaves a margin for
        // unsampled pixels without relaxing the actual erasure threshold.
        var ranked: [(index: Int, sample: BackgroundSample, strength: Double)] = []
        ranked.reserveCapacity(outliers.count)
        for (index, sample) in outliers.enumerated() {
            let delta = sample.color - surface.color(x: sample.x, y: sample.y)
            let strength = delta.x * delta.x + delta.y * delta.y + delta.z * delta.z
            ranked.append((index: index, sample: sample, strength: strength))
        }
        ranked.sort {
            $0.strength == $1.strength ? $0.index < $1.index : $0.strength > $1.strength
        }
        var inkColors: [SIMD3<Double>] = []
        for candidate in ranked {
            let sample = candidate.sample
            guard !matchesSourceInk(sample.color, background: surface.color(x: sample.x, y: sample.y),
                                    palette: inkColors, tolerance: 0.02) else { continue }
            inkColors.append(sample.color)
            if inkColors.count >= (useDenseInkSamples ? 128 : 64) { break }
        }
        // With no source ink there is nothing to erase. In particular, retain
        // every pixel of a blank or subtly shaded region supplied by OCR.
        guard !inkColors.isEmpty else { return }
        let opacitySamples = samples.map {
            BackgroundSample(x: $0.x, y: $0.y, color: SIMD3(repeating: $0.opacity))
        }
        let opacitySurface = samples.contains(where: { $0.opacity < 1 })
            ? robustBackgroundSurface(opacitySamples) : nil
        let opacities = samples.map(\.opacity).sorted()
        let fallbackOpacity = opacities[opacities.count / 2]
        let width = x1 - x0, height = y1 - y0
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            guard !Task.isCancelled else { return }
            for x in 0..<width {
                guard let observed = pixel(x0 + x, y0 + y) else { continue }
                let estimated = surface.color(x: (Double(x) + 0.5) / Double(width),
                                              y: (Double(y) + 0.5) / Double(height))
                guard channelDistance(observed, estimated) > max(2.0 / 255, textureTolerance) else { continue }
                guard matchesSourceInk(observed, background: estimated, palette: inkColors) else { continue }
                let index = (y * width + x) * 4
                for channel in 0..<3 {
                    pixels[index + channel] = UInt8((min(1, max(0, estimated[channel])) * 255).rounded())
                }
                pixels[index + 3] = 255
            }
        }
        preserveBackgroundBoundaries(in: &pixels, width: width, height: height)
        // Copy compositing can lower opacity back to a translucent surface.
        // Clip to the ink mask: copying untouched ORIGINAL pixels would bring
        // back glyphs already erased by an overlapping region in this pass.
        var inkRuns: [CGRect] = []
        for y in 0..<height {
            var runStart: Int?
            func appendRun(endingAt end: Int) {
                guard let start = runStart else { return }
                inkRuns.append(CGRect(x: CGFloat(x0 + start) / scaleX,
                    y: bounds.maxY - CGFloat(y0 + y + 1) / scaleY,
                    width: CGFloat(end - start) / scaleX, height: 1 / scaleY))
                runStart = nil
            }
            for x in 0..<width {
                let index = (y * width + x) * 4
                if pixels[index + 3] == 0 {
                    appendRun(endingAt: x)
                } else {
                    if runStart == nil { runStart = x }
                    let alpha = min(1, max(0, opacitySurface?.color(
                        x: (Double(x) + 0.5) / Double(width), y: (Double(y) + 0.5) / Double(height)
                    ).x ?? fallbackOpacity))
                    for channel in 0..<3 { pixels[index + channel] = UInt8((Double(pixels[index + channel]) * alpha).rounded()) }
                    pixels[index + 3] = UInt8((alpha * 255).rounded())
                }
            }
            appendRun(endingAt: width)
        }
        guard !inkRuns.isEmpty else { return }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let patch = CGImage(width: width, height: height, bitsPerComponent: 8,
                  bitsPerPixel: 32, bytesPerRow: width * 4, space: raster.colorSpace,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return }
        let target = CGRect(x: CGFloat(x0) / scaleX, y: bounds.maxY - CGFloat(y1) / scaleY,
                            width: CGFloat(width) / scaleX, height: CGFloat(height) / scaleY)
        let context = NSGraphicsContext.current?.cgContext
        context?.saveGState()
        context?.setShouldAntialias(false)
        context?.addRects(inkRuns)
        context?.clip()
        context?.setBlendMode(.copy)
        context?.interpolationQuality = .none
        context?.draw(patch, in: target)
        context?.restoreGState()
    }

    /// A neighboring panel can have the same color as the lettering. Color
    /// alone cannot distinguish them: retain broad components connected to
    /// the patch boundary, while interior glyph components remain erasable.
    private static func preserveBackgroundBoundaries(in pixels: inout [UInt8], width: Int, height: Int) {
        var visited = [Bool](repeating: false, count: width * height)
        var queue: [Int] = []
        for start in visited.indices where !visited[start] && pixels[start * 4 + 3] != 0 {
            queue.removeAll(keepingCapacity: true)
            queue.append(start)
            visited[start] = true
            var cursor = 0
            var minX = start % width, maxX = minX, minY = start / width, maxY = minY
            while cursor < queue.count {
                let index = queue[cursor]
                cursor += 1
                let x = index % width, y = index / width
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                for (xx, yy) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                    guard xx >= 0, xx < width, yy >= 0, yy < height else { continue }
                    let next = yy * width + xx
                    if !visited[next], pixels[next * 4 + 3] != 0 {
                        visited[next] = true
                        queue.append(next)
                    }
                }
            }
            let edges = [minX == 0, maxX == width - 1, minY == 0, maxY == height - 1].filter { $0 }.count
            let spanX = maxX - minX + 1, spanY = maxY - minY + 1
            let fill = Double(queue.count) / Double(spanX * spanY)
            var spansBoundary = false
            if edges >= 3 {
                var top = [Bool](repeating: false, count: width)
                var bottom = top
                var left = [Bool](repeating: false, count: height)
                var right = left
                for index in queue {
                    let x = index % width, y = index / width
                    if y == 0 { top[x] = true }
                    if y == height - 1 { bottom[x] = true }
                    if x == 0 { left[y] = true }
                    if x == width - 1 { right[y] = true }
                }
                // A panel or hollow frame follows a substantial part of an
                // edge. Thin chart strokes can touch three edges while also
                // connecting to lettering; those glyphs must remain erasable.
                spansBoundary = [top, bottom, left, right].contains { edge in
                    var run = 0
                    for occupied in edge {
                        run = occupied ? run + 1 : 0
                        if Double(run) >= Double(edge.count) * 0.65 { return true }
                    }
                    return false
                }
            }
            if (edges >= 3 && spansBoundary) || (edges > 0 && fill > 0.65
                && (Double(spanX) > Double(width) * 0.85 || Double(spanY) > Double(height) * 0.85)) {
                for index in queue {
                    // The patch uses premultiplied alpha; transparent pixels
                    // must also have zero RGB or source-over adds their color.
                    for channel in 0..<4 { pixels[index * 4 + channel] = 0 }
                }
            }
        }
    }

    private static func paintBackgroundPatch(
        in rect: CGRect,
        sourceImage: NSImage,
        sourceRect: CGRect?,
        color: NSColor
    ) {
        if let sourceRect, sourceRect.width > 0, sourceRect.height > 0 {
            sourceImage.draw(
                in: rect,
                from: sourceRect,
                operation: .copy,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.none]
            )
            return
        }

        // Keep the color tagged. Interpreting sRGB components as device RGB
        // changes the fill on color-managed screenshots.
        color.setFill()
        NSBezierPath(rect: rect).fill()
    }

    /// Selects an untouched source pixel near the text block so erasing old text
    /// preserves the screenshot's exact color profile instead of repainting an
    /// approximately matching `NSColor` that can shift after ColorSync conversion.
    static func backgroundPatchSourceRect(
        around rect: CGRect,
        matching backgroundColor: NSColor,
        bitmap: NSBitmapImageRep,
        bounds: CGRect
    ) -> CGRect? {
        let sampleOffset = max(2, min(10, rect.height * 0.20))
        let fractions: [CGFloat] = [0.08, 0.22, 0.38, 0.5, 0.62, 0.78, 0.92]
        var points = fractions.flatMap { x in
            fractions.map { y in CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y) }
        }

        for fraction in fractions {
            points.append(CGPoint(x: rect.minX + rect.width * fraction, y: rect.minY - sampleOffset))
            points.append(CGPoint(x: rect.minX + rect.width * fraction, y: rect.maxY + sampleOffset))
            points.append(CGPoint(x: rect.minX - sampleOffset, y: rect.minY + rect.height * fraction))
            points.append(CGPoint(x: rect.maxX + sampleOffset, y: rect.minY + rect.height * fraction))
        }

        let candidates = points.compactMap { point -> (point: CGPoint, distance: CGFloat)? in
            guard bounds.contains(point), let color = TranslationColorSampling.sampledColor(
                appKitX: point.x,
                appKitY: point.y,
                bitmap: bitmap,
                bounds: bounds
            ) else {
                return nil
            }
            return (point, TranslationColorSampling.rgbDistance(color, backgroundColor))
        }
        guard let candidate = candidates.min(by: { $0.distance < $1.distance }),
              candidate.distance < 0.08 else {
            return nil
        }

        // The sampled pixel and copied pixel must be identical. Rounding to
        // logical points selected neighboring text pixels at 1.5x/2x scale,
        // stretching a single black/red pixel across the entire erase area.
        let pixelWidth = bounds.width / CGFloat(max(bitmap.pixelsWide, 1))
        let pixelHeight = bounds.height / CGFloat(max(bitmap.pixelsHigh, 1))
        return CGRect(
            x: bounds.minX + floor((candidate.point.x - bounds.minX) / pixelWidth) * pixelWidth,
            y: bounds.minY + floor((candidate.point.y - bounds.minY) / pixelHeight) * pixelHeight,
            width: pixelWidth,
            height: pixelHeight
        ).intersection(bounds)
    }

}
