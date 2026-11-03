import CoreGraphics
import Foundation

/// Value state for the history sidebar's one-time window expansion. Transfer
/// the whole value when rebuilding a panel so later toggles reuse the reserved
/// width, including when the rebuilt panel starts with its sidebar collapsed.
struct AnswerPanelSidebarLayout: Equatable, Sendable {
    /// Reserved column width, including the inset sidebar and its trailing gutter.
    static let sidebarWidth: CGFloat = 261
    static let collapsedMinimumWidth: CGFloat = 420

    private(set) var isExpanded = false
    private(set) var hasReservedSidebarSpace = false

    /// The screen is the hard bound. Normally the conversation retains at
    /// least 420 points; on a screen narrower than 681 points the expanded
    /// panel uses the available width, even if the conversation must be smaller.
    /// A missing/empty visible frame means screen geometry is not yet known.
    func minimumWidth(for visibleFrame: CGRect) -> CGFloat {
        let preferred = Self.collapsedMinimumWidth + (isExpanded ? Self.sidebarWidth : 0)
        guard let screen = Self.usableScreen(visibleFrame) else { return preferred }
        return min(preferred, screen.width)
    }

    /// The first expansion grows left to preserve the conversation's width when
    /// the current frame is below the expanded minimum. If the window already
    /// has enough room, the sidebar opens in place. Collapse keeps the current
    /// frame: the conversation takes over the sidebar's space. Later expansions
    /// reuse that width, growing only enough to meet the expanded minimum after
    /// a manual resize. Callers can pass an animation's logical destination when
    /// a rapid reversal should retain the width already promised by expansion.
    mutating func setExpanded(_ expanded: Bool, frame: CGRect, visibleFrame: CGRect) -> CGRect {
        let current = frame.standardized
        guard expanded != isExpanded else {
            return clamped(current, visibleFrame: visibleFrame)
        }

        isExpanded = expanded
        guard expanded else { return clamped(current, visibleFrame: visibleFrame) }

        let growth: CGFloat
        if hasReservedSidebarSpace {
            growth = max(0, minimumWidth(for: visibleFrame) - current.width)
        } else {
            hasReservedSidebarSpace = true
            growth = current.width >= minimumWidth(for: visibleFrame) ? 0 : Self.sidebarWidth
        }
        var proposed = current
        // Keep the right edge fixed. Screen clamping can move the window right
        // when there is insufficient space on its left.
        proposed.origin.x -= growth
        proposed.size.width += growth
        return clamped(proposed, visibleFrame: visibleFrame)
    }

    private func clamped(_ frame: CGRect, visibleFrame: CGRect) -> CGRect {
        var result = frame
        result.size.width = max(minimumWidth(for: visibleFrame), result.width)
        guard let screen = Self.usableScreen(visibleFrame) else { return result }
        result.size.width = min(result.width, screen.width)
        result.size.height = min(result.height, screen.height)
        result.origin.x = min(max(result.minX, screen.minX), screen.maxX - result.width)
        result.origin.y = min(max(result.minY, screen.minY), screen.maxY - result.height)
        return result
    }

    private static func usableScreen(_ frame: CGRect) -> CGRect? {
        guard frame.minX.isFinite, frame.minY.isFinite,
              frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0 else { return nil }
        return frame
    }
}

/// Fixed layout dimensions for one sidebar animation destination. Only the
/// origins depend on the animated reveal, so intermediate samples never ask
/// the conversation to wrap its text to another width.
struct AnswerPanelSidebarMotionGeometry: Equatable, Sendable {
    let canvasWidth: CGFloat
    let contentWidth: CGFloat

    init(canvasWidth: CGFloat, destinationRevealWidth: CGFloat) {
        self.canvasWidth = max(0, canvasWidth)
        contentWidth = max(0, self.canvasWidth - Self.clampedReveal(destinationRevealWidth))
    }

    func contentOriginX(revealWidth: CGFloat, viewportWidth: CGFloat? = nil) -> CGFloat {
        // Native window expansion changes the viewport, not the conversation's
        // measured width. A negative origin is intentional when it is clipped.
        ((viewportWidth ?? canvasWidth) - contentWidth) / 2 + Self.clampedReveal(revealWidth) / 2
    }

    func sidebarOriginX(revealWidth: CGFloat) -> CGFloat {
        Self.clampedReveal(revealWidth) - AnswerPanelSidebarLayout.sidebarWidth
    }

    func toggleOriginX(revealWidth: CGFloat) -> CGFloat {
        let sidebarWidth = AnswerPanelSidebarLayout.sidebarWidth
        return 76 + (sidebarWidth - 50 - 76) * (Self.clampedReveal(revealWidth) / sidebarWidth)
    }

    private static func clampedReveal(_ width: CGFloat) -> CGFloat {
        min(AnswerPanelSidebarLayout.sidebarWidth, max(0, width))
    }
}

/// During a native resize the actual viewport is the animation clock. Starting
/// a second SwiftUI timeline, even with matching easing, can put the content
/// ahead of the window and visibly push it sideways.
struct AnswerPanelSidebarWindowMotion: Equatable, Sendable {
    let fromWidth: CGFloat
    let toWidth: CGFloat
    let fromRevealWidth: CGFloat
    let toRevealWidth: CGFloat

    func revealWidth(at viewportWidth: CGFloat) -> CGFloat {
        let distance = toWidth - fromWidth
        guard abs(distance) > 0.5 else { return toRevealWidth }
        let progress = min(1, max(0, (viewportWidth - fromWidth) / distance))
        return fromRevealWidth + (toRevealWidth - fromRevealWidth) * progress
    }
}

/// A single interpolation for the native window and its revealed sidebar.
/// Retargeting begins at the current sample, preserving position continuity.
struct AnswerPanelSidebarTransition {
    struct Sample {
        let frame: CGRect
        let revealWidth: CGFloat
    }
    let fromFrame: CGRect
    let toFrame: CGRect
    let fromRevealWidth: CGFloat
    let toRevealWidth: CGFloat

    func sample(progress: Double) -> Sample {
        let t = CGFloat(min(1, max(0, progress)))
        let eased = t * t * (3 - 2 * t)
        func blend(_ from: CGFloat, _ to: CGFloat) -> CGFloat { from + (to - from) * eased }
        return Sample(frame: CGRect(
            x: blend(fromFrame.minX, toFrame.minX), y: blend(fromFrame.minY, toFrame.minY),
            width: blend(fromFrame.width, toFrame.width), height: blend(fromFrame.height, toFrame.height)
        ), revealWidth: blend(fromRevealWidth, toRevealWidth))
    }
}
