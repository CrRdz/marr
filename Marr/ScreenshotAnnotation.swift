import AppKit
import SwiftUI

enum ScreenshotAnnotationTool: String, CaseIterable {
    case rectangle, arrow, number, pen

    var symbol: String {
        switch self {
        case .rectangle: "rectangle"
        case .arrow: "arrow.up.right"
        case .number: "number.circle"
        case .pen: "pencil.tip"
        }
    }

    var title: String {
        switch self {
        case .rectangle: "Draw rectangle"
        case .arrow: "Draw arrow"
        case .number: "Add number"
        case .pen: "Draw freehand"
        }
    }
}

/// Points are relative to the crop, so marks follow selection moves and resizes.
struct ScreenshotAnnotation: Equatable {
    let tool: ScreenshotAnnotationTool
    var points: [CGPoint]
    var number: Int = 0
}

extension ScreenshotAnnotation {
    func interactionPath(in size: CGSize) -> Path {
        let points = points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
        guard let start = points.first, let end = points.last else { return Path() }
        var path = Path()
        switch tool {
        case .rectangle:
            path.addRect(CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                width: abs(end.x - start.x), height: abs(end.y - start.y)))
        case .arrow:
            path.move(to: start)
            path.addLine(to: end)
            let angle = atan2(end.y - start.y, end.x - start.x)
            let length = min(14, hypot(end.x - start.x, end.y - start.y) * 0.4)
            for offset in [-CGFloat.pi / 6, CGFloat.pi / 6] {
                path.move(to: CGPoint(x: end.x - length * cos(angle + offset), y: end.y - length * sin(angle + offset)))
                path.addLine(to: end)
            }
        case .number:
            let radius = min(26, size.width, size.height) / 2
            let center = CGPoint(x: min(max(start.x, radius), size.width - radius),
                                 y: min(max(start.y, radius), size.height - radius))
            return Path(ellipseIn: CGRect(x: center.x - radius - 5, y: center.y - radius - 5,
                                         width: radius * 2 + 10, height: radius * 2 + 10))
        case .pen:
            return Path()
        }
        return path.strokedPath(StrokeStyle(lineWidth: 16, lineCap: .round, lineJoin: .round))
    }

    func translated(by delta: CGSize, in size: CGSize) -> Self {
        guard !points.isEmpty, size.width > 0, size.height > 0 else { return self }
        let dx = min(max(delta.width / size.width, -(points.map(\.x).min() ?? 0)), 1 - (points.map(\.x).max() ?? 1))
        let dy = min(max(delta.height / size.height, -(points.map(\.y).min() ?? 0)), 1 - (points.map(\.y).max() ?? 1))
        var copy = self
        copy.points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        return copy
    }
}

struct ScreenshotAnnotationHitShape: Shape {
    let annotations: [ScreenshotAnnotation]
    let includesBackground: Bool

    func path(in rect: CGRect) -> Path {
        if includesBackground { return Path(rect) }
        var path = Path()
        for annotation in annotations { path.addPath(annotation.interactionPath(in: rect.size)) }
        return path
    }
}

struct ScreenshotAnnotationCanvas: View {
    let annotations: [ScreenshotAnnotation]
    var selectedIndex: Int? = nil

    var body: some View {
        Canvas { context, size in
            for (index, annotation) in annotations.enumerated() {
                let points = annotation.points.map {
                    CGPoint(x: $0.x * size.width, y: $0.y * size.height)
                }
                guard let start = points.first, let end = points.last else { continue }
                let color = Color(red: 1, green: 0.22, blue: 0.23)
                var path = Path()
                switch annotation.tool {
                case .rectangle:
                    path.addRect(CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                        width: abs(end.x - start.x), height: abs(end.y - start.y)))
                case .arrow:
                    path.move(to: start)
                    path.addLine(to: end)
                    let angle = atan2(end.y - start.y, end.x - start.x)
                    let length = min(14, hypot(end.x - start.x, end.y - start.y) * 0.4)
                    for offset in [-CGFloat.pi / 6, CGFloat.pi / 6] {
                        path.move(to: CGPoint(x: end.x - length * cos(angle + offset),
                                              y: end.y - length * sin(angle + offset)))
                        path.addLine(to: end)
                    }
                case .pen:
                    path.move(to: start)
                    for point in points.dropFirst() { path.addLine(to: point) }
                    if points.allSatisfy({ $0 == start }) {
                        context.fill(Path(ellipseIn: CGRect(x: start.x - 1.5, y: start.y - 1.5,
                                                            width: 3, height: 3)), with: .color(color))
                    }
                case .number:
                    let diameter = min(26, size.width, size.height)
                    let radius = diameter / 2
                    let center = CGPoint(x: min(max(start.x, radius), size.width - radius),
                                         y: min(max(start.y, radius), size.height - radius))
                    let circle = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                       width: diameter, height: diameter))
                    context.fill(circle, with: .color(color))
                    context.stroke(circle, with: .color(.white), lineWidth: 1.5)
                    context.draw(Text("\(annotation.number)")
                        .font(.system(size: annotation.number > 99 ? 10 : 14, weight: .bold))
                        .foregroundColor(.white), at: center)
                }
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                if selectedIndex == index {
                    let bounds = annotation.interactionPath(in: size).boundingRect.insetBy(dx: -3, dy: -3)
                    context.stroke(Path(roundedRect: bounds, cornerRadius: 5), with: .color(.white), lineWidth: 2)
                    context.stroke(Path(roundedRect: bounds, cornerRadius: 5), with: .color(.blue),
                                   style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

struct ScreenshotToolsLayout {
    let frame: CGRect
    let isOnLeft: Bool

    static func resolve(selection: CGRect, bounds: CGSize, expanded: Bool, avoiding prompt: CGRect = .null) -> Self {
        // Include the padding around the circular buttons in collision detection.
        let width: CGFloat = 50
        let height: CGFloat = expanded ? 350 : 100
        let gap: CGFloat = 12
        let inset: CGFloat = 8
        let availableHeight = max(0, bounds.height - inset * 2)
        let visibleHeight = min(height, availableHeight)
        let obstacle = prompt.isNull ? CGRect.null : prompt.insetBy(dx: -8, dy: -8)
        let leftFits = selection.minX >= width + gap + inset
        let rightFits = bounds.width - selection.maxX >= width + gap + inset
        let preferLeft = !rightFits && leftFits
        let preferredY = expanded ? selection.minY : selection.midY - visibleHeight / 2
        var candidates: [Self] = []
        for left in [preferLeft, !preferLeft] {
            let proposedX = left ? selection.minX - gap - width : selection.maxX + gap
            let x = min(max(inset, proposedX), max(inset, bounds.width - width - inset))
            let y = min(max(inset, preferredY), max(inset, bounds.height - visibleHeight - inset))
            let candidate = CGRect(x: x, y: y, width: width, height: visibleHeight)
            if obstacle.isNull || !candidate.intersects(obstacle) {
                candidates.append(Self(frame: candidate, isOnLeft: left))
                continue
            }
            // A wide composer can cross both side lanes. Keep the tools beside the
            // selection and scroll the shorter lane instead of moving the whole
            // toolbar below the composer just to preserve its expanded height.
            let lanes = [
                CGRect(x: x, y: inset, width: width, height: max(0, obstacle.minY - inset)),
                CGRect(x: x, y: max(inset, obstacle.maxY), width: width,
                       height: max(0, bounds.height - inset - max(inset, obstacle.maxY)))
            ]
            for lane in lanes {
                guard lane.height > 0 else { continue }
                let minimumHeight = min(50, visibleHeight, lane.height)
                let adjustedY = min(max(preferredY, lane.minY), lane.maxY - minimumHeight)
                let h = min(visibleHeight, lane.maxY - adjustedY)
                candidates.append(Self(frame: CGRect(x: x, y: adjustedY, width: width, height: h), isOnLeft: left))
            }
        }
        let usable = candidates.filter { $0.frame.height >= min(50, visibleHeight) }
        return (usable.isEmpty ? candidates : usable).min { first, second in
            let firstDistance = abs(first.frame.minY - preferredY)
            let secondDistance = abs(second.frame.minY - preferredY)
            if abs(firstDistance - secondDistance) > 0.5 { return firstDistance < secondDistance }
            if abs(first.frame.height - second.frame.height) > 0.5 { return first.frame.height > second.frame.height }
            return first.isOnLeft == preferLeft && second.isOnLeft != preferLeft
        }
            ?? Self(frame: .zero, isOnLeft: preferLeft)
    }

}

extension ScreenCapture {
    @MainActor
    static func annotating(_ image: PickedImage, with annotations: [ScreenshotAnnotation], selectionSize: CGSize) -> PickedImage? {
        guard !annotations.isEmpty else { return image }
        guard selectionSize.width > 0, selectionSize.height > 0 else { return nil }
        // Preserve the screenshot pixels and composite a transparent vector layer
        // at the same pixel scale as the captured image.
        guard let source = image.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let content = ScreenshotAnnotationCanvas(annotations: annotations)
            .frame(width: selectionSize.width, height: selectionSize.height)
        let renderer = ImageRenderer(content: content)
        renderer.scale = CGFloat(source.width) / selectionSize.width
        guard let overlay = renderer.cgImage,
              let context = CGContext(data: nil, width: source.width, height: source.height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        context.draw(source, in: rect)
        context.draw(overlay, in: rect)
        guard let rendered = context.makeImage() else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: rendered)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return PickedImage(data: data, mimeType: "image/png", fileName: "Annotated Screen Capture.png",
                           image: NSImage(cgImage: rendered, size: image.image.size))
    }
}

struct ScreenshotToolColumn<Content: View>: View {
    let frame: CGRect
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 8) { content }
                .padding(.vertical, 4)
        }
        // Clip scrolling content with the native viewport. Its extra width
        // preserves the circles' shadows without shifting the logical tool lane.
        .frame(width: frame.width + 32, height: frame.height)
        .contentShape(.interaction, Rectangle())
        .position(x: frame.midX, y: frame.midY)
    }
}

struct ScreenshotToolButton: View {
    let symbol: String
    let title: String
    var selected = false
    var disabled = false
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 42, height: 42)
                .contentShape(Circle())
        }
        .buttonStyle(ScreenshotToolPressStyle(reduceMotion: reduceMotion))
        .scaleEffect(selected ? 1.06 : 1)
        // An opaque foreground keeps the glyph independent of glass vibrancy,
        // the captured page, and the user's bubble tint.
        .foregroundStyle(selected ? Color.white : Color(white: colorScheme == .dark ? 0.94 : 0.12))
        .background {
            if selected { Circle().fill(Color(red: 1, green: 0.22, blue: 0.23)) }
        }
        .marrGlassSurface(cornerRadius: 21, isClear: false)
        .overlay(Circle().stroke(selected ? Color.red : .white.opacity(0.22), lineWidth: 1))
        .opacity(disabled ? 0.35 : 1)
        .disabled(disabled)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

struct ScreenshotToolPressStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.65), value: configuration.isPressed)
    }
}
