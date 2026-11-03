import AppKit
import Combine
import MarrCore
import QuartzCore
import SwiftUI

enum AnswerPanelPlacement {
    private enum Direction: Int, CaseIterable {
        case right
        case left
        case above
        case below
    }

    private struct Candidate {
        let direction: Direction
        let score: CGFloat
        let frame: CGRect
    }

    static let gap: CGFloat = 14
    static let screenMargin: CGFloat = 12
    static let presentationOffset: CGFloat = 14

    static func initialFrame(
        panelSize: CGSize,
        anchorRect: CGRect,
        visibleFrame: CGRect
    ) -> CGRect {
        let safeFrame = visibleFrame.insetBy(dx: screenMargin, dy: screenMargin)
        guard panelSize.width > 0, panelSize.height > 0, !safeFrame.isEmpty else {
            return CGRect(origin: visibleFrame.origin, size: panelSize)
        }

        let candidates = Direction.allCases.map { direction in
            Candidate(
                direction: direction,
                score: availableSpace(
                    for: direction,
                    anchorRect: anchorRect,
                    safeFrame: safeFrame
                ) / requiredSpace(for: direction, panelSize: panelSize),
                frame: rawFrame(
                    for: direction,
                    panelSize: panelSize,
                    anchorRect: anchorRect
                )
            )
        }
        let best = candidates.max { lhs, rhs in
            if abs(lhs.score - rhs.score) > 0.001 {
                return lhs.score < rhs.score
            }
            return lhs.direction.rawValue > rhs.direction.rawValue
        } ?? candidates[0]

        return clamped(best.frame, to: safeFrame)
    }

    static func presentationStartFrame(
        targetFrame: CGRect,
        anchorRect: CGRect
    ) -> CGRect {
        let deltaX = anchorRect.midX - targetFrame.midX
        let deltaY = anchorRect.midY - targetFrame.midY
        let distance = hypot(deltaX, deltaY)
        guard distance > 0 else { return targetFrame }

        return targetFrame.offsetBy(
            dx: deltaX / distance * presentationOffset,
            dy: deltaY / distance * presentationOffset
        )
    }

    private static func availableSpace(
        for direction: Direction,
        anchorRect: CGRect,
        safeFrame: CGRect
    ) -> CGFloat {
        switch direction {
        case .right:
            safeFrame.maxX - anchorRect.maxX - gap
        case .left:
            anchorRect.minX - safeFrame.minX - gap
        case .above:
            safeFrame.maxY - anchorRect.maxY - gap
        case .below:
            anchorRect.minY - safeFrame.minY - gap
        }
    }

    private static func requiredSpace(
        for direction: Direction,
        panelSize: CGSize
    ) -> CGFloat {
        switch direction {
        case .right, .left:
            panelSize.width
        case .above, .below:
            panelSize.height
        }
    }

    private static func rawFrame(
        for direction: Direction,
        panelSize: CGSize,
        anchorRect: CGRect
    ) -> CGRect {
        let origin: CGPoint
        switch direction {
        case .right:
            origin = CGPoint(
                x: anchorRect.maxX + gap,
                y: anchorRect.midY - panelSize.height / 2
            )
        case .left:
            origin = CGPoint(
                x: anchorRect.minX - gap - panelSize.width,
                y: anchorRect.midY - panelSize.height / 2
            )
        case .above:
            origin = CGPoint(
                x: anchorRect.midX - panelSize.width / 2,
                y: anchorRect.maxY + gap
            )
        case .below:
            origin = CGPoint(
                x: anchorRect.midX - panelSize.width / 2,
                y: anchorRect.minY - gap - panelSize.height
            )
        }
        return CGRect(origin: origin, size: panelSize)
    }

    private static func clamped(_ frame: CGRect, to safeFrame: CGRect) -> CGRect {
        CGRect(
            x: min(
                max(frame.minX, safeFrame.minX),
                max(safeFrame.minX, safeFrame.maxX - frame.width)
            ),
            y: min(
                max(frame.minY, safeFrame.minY),
                max(safeFrame.minY, safeFrame.maxY - frame.height)
            ),
            width: frame.width,
            height: frame.height
        )
    }
}
