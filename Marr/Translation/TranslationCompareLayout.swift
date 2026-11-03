import AppKit
import Carbon
import SwiftUI

enum TranslationCompareLayout {
    static func resizedOriginalFrame(
        currentFrame: CGRect,
        sourceSize: CGSize,
        scale: CGFloat,
        visibleFrame: CGRect
    ) -> CGRect {
        guard sourceSize.width > 0, sourceSize.height > 0, scale.isFinite else { return currentFrame }
        let available = visibleFrame.insetBy(dx: 8, dy: 8)
        guard available.width > 0, available.height > 0 else { return currentFrame }
        let maximum = min(4, available.width / sourceSize.width, available.height / sourceSize.height)
        let minimum = min(maximum, min(1, 120 / max(sourceSize.width, sourceSize.height)))
        let resolved = min(maximum, max(minimum, scale))
        let size = CGSize(width: sourceSize.width * resolved, height: sourceSize.height * resolved)
        return CGRect(
            x: min(max(currentFrame.midX - size.width / 2, available.minX), available.maxX - size.width),
            y: min(max(currentFrame.midY - size.height / 2, available.minY), available.maxY - size.height),
            width: size.width,
            height: size.height
        )
    }

    static func originalFrame(
        anchorFrame: CGRect,
        visibleFrame: CGRect,
        margin: CGFloat = 12,
        gap: CGFloat = 8
    ) -> CGRect {
        let availableFrame = visibleFrame.insetBy(dx: margin, dy: margin)
        let sourceFrame = anchorFrame.integral
        guard sourceFrame.width > 0, sourceFrame.height > 0 else {
            return sourceFrame
        }

        let candidates = [
            CGRect(
                x: sourceFrame.minX - gap - sourceFrame.width,
                y: sourceFrame.minY,
                width: sourceFrame.width,
                height: sourceFrame.height
            ),
            CGRect(
                x: sourceFrame.maxX + gap,
                y: sourceFrame.minY,
                width: sourceFrame.width,
                height: sourceFrame.height
            ),
            CGRect(
                x: sourceFrame.minX,
                y: sourceFrame.maxY + gap,
                width: sourceFrame.width,
                height: sourceFrame.height
            ),
            CGRect(
                x: sourceFrame.minX,
                y: sourceFrame.minY - gap - sourceFrame.height,
                width: sourceFrame.width,
                height: sourceFrame.height
            )
        ]

        if let nonOverlappingFrame = candidates.first(where: { candidate in
            availableFrame.contains(candidate) && !candidate.intersects(sourceFrame)
        }) {
            return nonOverlappingFrame.integral
        }

        return candidates
            .map { clampedFrame($0, to: availableFrame) }
            .enumerated()
            .min { lhs, rhs in
                let lhsOverlap = overlapArea(lhs.element, sourceFrame)
                let rhsOverlap = overlapArea(rhs.element, sourceFrame)
                if lhsOverlap != rhsOverlap {
                    return lhsOverlap < rhsOverlap
                }
                return lhs.offset < rhs.offset
            }?
            .element
            .integral ?? sourceFrame
    }

    private static func clampedFrame(_ frame: CGRect, to bounds: CGRect) -> CGRect {
        return CGRect(
            x: min(max(frame.minX, bounds.minX), bounds.maxX - frame.width),
            y: min(max(frame.minY, bounds.minY), bounds.maxY - frame.height),
            width: frame.width,
            height: frame.height
        )
    }

    private static func overlapArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else {
            return 0
        }
        return intersection.width * intersection.height
    }
}
