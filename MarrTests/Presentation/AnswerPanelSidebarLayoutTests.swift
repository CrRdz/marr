import CoreGraphics
import AppKit
import Foundation
import XCTest
@testable import Marr

final class AnswerPanelSidebarLayoutTests: XCTestCase {
    @MainActor
    func testWindowUsesNativeControlsAndParticipatesInStageManager() throws {
        let window = AnswerPanelWindow(contentRect: NSRect(x: 100, y: 100, width: 484, height: 596))
        defer { window.close() }
        XCTAssertEqual(window.level, .normal)
        XCTAssertTrue(window.styleMask.contains([.titled, .closable, .miniaturizable, .resizable]))
        XCTAssertTrue(window.collectionBehavior.contains([.managed, .primary, .fullScreenPrimary]))
        XCTAssertTrue(window.collectionBehavior.intersection([
            .canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications, .auxiliary, .stationary
        ]).isEmpty)
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let button = try XCTUnwrap(window.standardWindowButton(type))
            XCTAssertTrue(button.window === window)
            XCTAssertTrue(button.isEnabled)
            XCTAssertFalse(button.isHidden)
        }
        XCTAssertFalse(window.isVisible)
    }

    @MainActor
    func testNativeClosePreservesConversationCleanup() {
        let window = AnswerPanelWindow(contentRect: NSRect(x: 100, y: 100, width: 484, height: 596))
        defer { window.close() }
        var closeRequests = 0
        window.onCloseRequested = { [weak window] in closeRequests += 1; window?.close() }
        window.standardWindowButton(.closeButton)?.performClick(nil)
        XCTAssertEqual(closeRequests, 1)
        XCTAssertFalse(window.isVisible)
    }

    @MainActor
    func testNativeTrafficLightHoverRegionFollowsButtonsAfterResizeAndContentReplacement() throws {
        let window = AnswerPanelWindow(contentRect: NSRect(x: 100, y: 100, width: 484, height: 596))
        defer { window.contentView = nil; window.close() }
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let buttons = try types.map { try XCTUnwrap(window.standardWindowButton($0)) }
        let parents = buttons.map(\.superview)
        let targets = buttons.map(\.target)
        let actions = buttons.map(\.action)
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertEqual(window.toolbarStyle, .unified)
        XCTAssertEqual(window.titlebarSeparatorStyle, .none)
        for size in [NSSize(width: 484, height: 596), NSSize(width: 745, height: 720), NSSize(width: 484, height: 596)] {
            window.setContentSize(size)
            // Replacing a conversation must not remove the native hover owner.
            let content = NSView(frame: NSRect(origin: .zero, size: size))
            window.contentView = content
            let frameView = try XCTUnwrap(content.superview)
            frameView.layoutSubtreeIfNeeded()
            let rects = buttons.map { frameView.convert($0.bounds, from: $0) }
            let groupRect = rects.reduce(CGRect.null) { $0.union($1) }
            let groupTracking = try XCTUnwrap(frameView.trackingAreas.first {
                $0.owner === frameView && $0.rect == groupRect
                    && $0.options.contains(.mouseEnteredAndExited)
            }, "Native group hover must cover the current buttons, not their former title-bar coordinates")
            XCTAssertTrue(groupTracking.rect.contains(NSPoint(x: (rects[0].maxX + rects[1].minX) / 2,
                                                             y: groupRect.midY)))
            XCTAssertFalse(groupTracking.rect.contains(NSPoint(x: groupRect.maxX + 10, y: groupRect.midY)))
            for (index, button) in buttons.enumerated() {
                XCTAssertTrue(button.superview === parents[index])
                XCTAssertTrue(button.target === targets[index])
                XCTAssertEqual(button.action, actions[index])
                XCTAssertTrue(frameView.hitTest(NSPoint(x: rects[index].midX, y: rects[index].midY)) === button)
            }
            XCTAssertEqual(frameView.bounds.maxY - groupRect.midY,
                           MarrPanelShellLayout.toolbarTop + MarrPanelShellLayout.toolbarHeight / 2, accuracy: 2)
            let sidebarButton = NSButton(frame: NSRect(x: 92, y: content.bounds.height - 42, width: 30, height: 30))
            content.addSubview(sidebarButton)
            let point = frameView.convert(NSPoint(x: sidebarButton.frame.midX, y: sidebarButton.frame.midY), from: content)
            XCTAssertTrue(frameView.hitTest(point) === sidebarButton, "Native chrome must not intercept adjacent toolbar controls")
        }
    }

    private let screen = CGRect(x: 0, y: 24, width: 1440, height: 900)
    private let original = CGRect(x: 500, y: 150, width: 520, height: 600)

    func testNavigationRailPreservesChatWidthAndScreenPositionDuringExpansion() {
        let window = CGRect(x: 500, y: 150, width: MarrPanelShellLayout.windowSize.width, height: 596)
        let content = MarrPanelShellLayout.contentFrame(window)
        XCTAssertEqual(content.width, AnswerPanelConversationLayout.panelSize.width)
        XCTAssertEqual(MarrPanelShellLayout.windowFrame(content), window)
        var layout = AnswerPanelSidebarLayout()
        let expanded = MarrPanelShellLayout.windowFrame(layout.setExpanded(true, frame: content,
            visibleFrame: MarrPanelShellLayout.contentFrame(screen)))
        XCTAssertEqual(expanded.maxX, window.maxX)
        XCTAssertEqual(expanded.width - MarrPanelShellLayout.railWidth - AnswerPanelSidebarLayout.sidebarWidth, content.width)
        XCTAssertEqual(expanded.minX + MarrPanelShellLayout.railWidth + AnswerPanelSidebarLayout.sidebarWidth, content.minX)
        let motion = AnswerPanelSidebarWindowMotion(fromWidth: window.width, toWidth: expanded.width,
            fromRevealWidth: 0, toRevealWidth: AnswerPanelSidebarLayout.sidebarWidth)
        let inner = MarrPanelShellLayout.contentMotion(motion)!
        for progress: CGFloat in [0, 0.17, 0.54, 1] {
            let width = window.width + (expanded.width - window.width) * progress
            XCTAssertEqual(inner.revealWidth(at: width - MarrPanelShellLayout.railWidth), motion.revealWidth(at: width), accuracy: 0.001)
        }
    }

    func testFirstExpansionPreservesConversationAndCollapseKeepsExpandedFrame() {
        var layout = AnswerPanelSidebarLayout()
        let expanded = layout.setExpanded(true, frame: original, visibleFrame: screen)
        XCTAssertEqual(expanded, CGRect(x: 239, y: 150, width: 781, height: 600))
        XCTAssertEqual(expanded.minX + AnswerPanelSidebarLayout.sidebarWidth, original.minX)
        XCTAssertEqual(expanded.maxX, original.maxX)
        XCTAssertTrue(layout.isExpanded)
        XCTAssertTrue(layout.hasReservedSidebarSpace)
        XCTAssertEqual(layout.setExpanded(false, frame: expanded, visibleFrame: screen), expanded)
        XCTAssertFalse(layout.isExpanded)
        XCTAssertTrue(layout.hasReservedSidebarSpace)
    }

    func testLeftEdgeUsesRightHandSpaceAndCollapseKeepsThatPosition() {
        var layout = AnswerPanelSidebarLayout()
        let original = CGRect(x: 80, y: 150, width: 520, height: 600)
        let expanded = layout.setExpanded(true, frame: original, visibleFrame: screen)
        XCTAssertEqual(expanded, CGRect(x: 0, y: 150, width: 781, height: 600))
        XCTAssertEqual(expanded.maxX - original.maxX, 181)
        XCTAssertEqual(layout.setExpanded(false, frame: expanded, visibleFrame: screen), expanded)
        XCTAssertEqual(layout.setExpanded(true, frame: expanded, visibleFrame: screen), expanded)
    }

    func testFirstExpansionAtRightEdgeKeepsTheRightEdgeFixed() {
        var layout = AnswerPanelSidebarLayout()
        let original = CGRect(x: 900, y: 150, width: 540, height: 600)
        let expanded = layout.setExpanded(true, frame: original, visibleFrame: screen)
        XCTAssertEqual(expanded.maxX, screen.maxX)
        XCTAssertEqual(expanded.width, original.width + 261)
        XCTAssertEqual(layout.setExpanded(false, frame: expanded, visibleFrame: screen), expanded)
    }

    func testConstrainedExpansionRetainsOnlyTheWidthTheScreenAllowed() {
        let screen = CGRect(x: 0, y: 0, width: 700, height: 900)
        let original = CGRect(x: 50, y: 150, width: 600, height: 600)
        var layout = AnswerPanelSidebarLayout()
        let expanded = layout.setExpanded(true, frame: original, visibleFrame: screen)
        XCTAssertEqual(expanded, CGRect(x: 0, y: 150, width: 700, height: 600))
        XCTAssertEqual(layout.setExpanded(false, frame: expanded, visibleFrame: screen), expanded)
        XCTAssertEqual(layout.setExpanded(true, frame: expanded, visibleFrame: screen), expanded)
        XCTAssertTrue(layout.hasReservedSidebarSpace)
    }

    func testFullWidthPanelDoesNotChangeFrameWhenSidebarCannotGrow() {
        let screen = CGRect(x: -900, y: 24, width: 900, height: 900)
        let original = CGRect(x: -900, y: 150, width: 900, height: 600)
        var layout = AnswerPanelSidebarLayout()
        let expanded = layout.setExpanded(true, frame: original, visibleFrame: screen)
        XCTAssertEqual(expanded, original)
        XCTAssertTrue(layout.hasReservedSidebarSpace)
        XCTAssertEqual(layout.setExpanded(false, frame: expanded, visibleFrame: screen), original)
    }

    func testManualMoveAndRightResizeSurviveBothToggles() {
        var layout = AnswerPanelSidebarLayout()
        var expanded = layout.setExpanded(true, frame: original, visibleFrame: screen)
        expanded.origin.x += 37
        expanded.origin.y -= 20
        expanded.size.width += 100
        expanded.size.height += 30
        let collapsed = layout.setExpanded(false, frame: expanded, visibleFrame: screen)
        XCTAssertEqual(collapsed, CGRect(x: 276, y: 130, width: 881, height: 630))
        XCTAssertEqual(layout.setExpanded(true, frame: collapsed, visibleFrame: screen), collapsed)
    }

    func testManualLeftResizeSurvivesBothToggles() {
        var layout = AnswerPanelSidebarLayout()
        var expanded = layout.setExpanded(true, frame: original, visibleFrame: screen)
        expanded.origin.x -= 80
        expanded.size.width += 80
        let collapsed = layout.setExpanded(false, frame: expanded, visibleFrame: screen)
        XCTAssertEqual(collapsed, CGRect(x: 159, y: 150, width: 861, height: 600))
        XCTAssertEqual(collapsed.maxX, original.maxX)
        XCTAssertEqual(layout.setExpanded(true, frame: collapsed, visibleFrame: screen), collapsed)
    }

    func testManualShrinkAfterConstrainedExpansionRetainsTheActualFrame() {
        let screen = CGRect(x: 0, y: 0, width: 700, height: 900)
        var layout = AnswerPanelSidebarLayout()
        var expanded = layout.setExpanded(true, frame: CGRect(x: 50, y: 150, width: 600, height: 600), visibleFrame: screen)
        expanded.size.width -= 15
        let collapsed = layout.setExpanded(false, frame: expanded, visibleFrame: screen)
        XCTAssertEqual(collapsed, CGRect(x: 0, y: 150, width: 685, height: 600))
        XCTAssertEqual(layout.setExpanded(true, frame: collapsed, visibleFrame: screen), collapsed)
    }

    func testCollapsePreservesExternallyUndersizedWidthUntilReopened() {
        var layout = AnswerPanelSidebarLayout()
        var expanded = layout.setExpanded(true, frame: original, visibleFrame: screen)
        expanded.size.width = 600
        let collapsed = layout.setExpanded(false, frame: expanded, visibleFrame: screen)
        XCTAssertEqual(collapsed, expanded)
        let reopened = layout.setExpanded(true, frame: collapsed, visibleFrame: screen)
        XCTAssertEqual(reopened.width, 681)
        XCTAssertEqual(reopened.maxX, collapsed.maxX)
    }

    func testCollapsedManualResizeBelowMinimumOnlyAddsTheMissingWidthOnReopen() {
        for width in [CGFloat(420), 520, 680, 681, 800] {
            var layout = AnswerPanelSidebarLayout()
            let expanded = layout.setExpanded(true, frame: original, visibleFrame: screen)
            _ = layout.setExpanded(false, frame: expanded, visibleFrame: screen)
            let resized = CGRect(x: 500, y: 180, width: width, height: 650)
            let reopened = layout.setExpanded(true, frame: resized, visibleFrame: screen)
            XCTAssertEqual(reopened.width, max(681, width))
            XCTAssertEqual(reopened.maxX, resized.maxX)
            XCTAssertEqual(reopened.minY, resized.minY)
            XCTAssertEqual(reopened.height, resized.height)
            XCTAssertEqual(layout.setExpanded(false, frame: reopened, visibleFrame: screen), reopened)
        }
    }

    func testCollapsedManualMoveAndResizeAboveMinimumArePreservedExactly() {
        var layout = AnswerPanelSidebarLayout()
        let expanded = layout.setExpanded(true, frame: original, visibleFrame: screen)
        _ = layout.setExpanded(false, frame: expanded, visibleFrame: screen)
        let resized = CGRect(x: 450, y: 90, width: 850, height: 700)
        XCTAssertEqual(layout.setExpanded(true, frame: resized, visibleFrame: screen), resized)
        XCTAssertEqual(layout.setExpanded(false, frame: resized, visibleFrame: screen), resized)
    }

    func testRepeatedRequestsAndRoundTripsNeverAccumulateWidthOrPosition() {
        var layout = AnswerPanelSidebarLayout()
        let reservedFrame = layout.setExpanded(true, frame: original, visibleFrame: screen)
        var frame = reservedFrame
        for _ in 0..<20 {
            for _ in 0..<5 {
                XCTAssertEqual(layout.setExpanded(true, frame: frame, visibleFrame: screen), reservedFrame)
            }
            frame = layout.setExpanded(false, frame: frame, visibleFrame: screen)
            XCTAssertEqual(frame, reservedFrame)
            XCTAssertEqual(layout.setExpanded(false, frame: frame, visibleFrame: screen), reservedFrame)
            frame = layout.setExpanded(true, frame: frame, visibleFrame: screen)
            XCTAssertEqual(frame, reservedFrame)
        }
        XCTAssertTrue(layout.hasReservedSidebarSpace)
    }

    func testCopiedExpandedStatePreservesARebuiltPanelsConstrainedFrame() {
        let screen = CGRect(x: -700, y: 0, width: 700, height: 900)
        let original = CGRect(x: -650, y: 150, width: 600, height: 600)
        var originalLayout = AnswerPanelSidebarLayout()
        let expanded = originalLayout.setExpanded(true, frame: original, visibleFrame: screen)
        var rebuiltLayout = originalLayout
        XCTAssertEqual(rebuiltLayout.setExpanded(true, frame: expanded, visibleFrame: screen), expanded)
        XCTAssertEqual(rebuiltLayout.setExpanded(false, frame: expanded, visibleFrame: screen), expanded)
        XCTAssertTrue(originalLayout.isExpanded)
        XCTAssertFalse(rebuiltLayout.isExpanded)
    }

    func testCopiedCollapsedStateDoesNotExpandARebuiltWindowAgain() {
        var originalLayout = AnswerPanelSidebarLayout()
        let expanded = originalLayout.setExpanded(true, frame: original, visibleFrame: screen)
        let collapsed = originalLayout.setExpanded(false, frame: expanded, visibleFrame: screen)
        var rebuiltLayout = originalLayout
        XCTAssertFalse(rebuiltLayout.isExpanded)
        XCTAssertTrue(rebuiltLayout.hasReservedSidebarSpace)
        XCTAssertEqual(rebuiltLayout.setExpanded(true, frame: collapsed, visibleFrame: screen), expanded)
        XCTAssertFalse(originalLayout.isExpanded)
    }

    func testScreenChangeClampsBothAxesWithoutUndoingReservedWidth() {
        var layout = AnswerPanelSidebarLayout()
        let expanded = layout.setExpanded(true, frame: original, visibleFrame: screen)
        let otherScreen = CGRect(x: -1280, y: 40, width: 1280, height: 500)
        let collapsed = layout.setExpanded(false, frame: expanded, visibleFrame: otherScreen)
        XCTAssertEqual(collapsed.width, expanded.width)
        XCTAssertEqual(collapsed.height, otherScreen.height)
        XCTAssertEqual(collapsed.maxX, otherScreen.maxX)
        XCTAssertEqual(collapsed.minY, otherScreen.minY)
        XCTAssertTrue(otherScreen.contains(collapsed))
    }

    func testMinimumWidthsYieldToNarrowScreensWithoutOverflowOrShrinkingOnCollapse() {
        for width in [CGFloat(300), 600, 681, 1440] {
            let screen = CGRect(x: -width, y: 0, width: width, height: 500)
            let original = CGRect(x: -width, y: 0, width: min(420, width), height: 700)
            var layout = AnswerPanelSidebarLayout()
            XCTAssertEqual(layout.minimumWidth(for: screen), min(420, width))
            let expanded = layout.setExpanded(true, frame: original, visibleFrame: screen)
            XCTAssertEqual(layout.minimumWidth(for: screen), min(681, width))
            XCTAssertEqual(expanded.width, min(681, width))
            XCTAssertTrue(screen.contains(expanded))
            let collapsed = layout.setExpanded(false, frame: expanded, visibleFrame: screen)
            XCTAssertEqual(layout.minimumWidth(for: screen), min(420, width))
            XCTAssertEqual(collapsed, expanded)
            XCTAssertTrue(screen.contains(collapsed))
        }
    }

    func testRepeatedRequestReclampsChangedScreenWithoutAddingSidebarAgain() {
        var layout = AnswerPanelSidebarLayout()
        let expanded = layout.setExpanded(true, frame: original, visibleFrame: screen)
        let smaller = CGRect(x: 0, y: 24, width: 700, height: 600)
        let reclamped = layout.setExpanded(true, frame: expanded, visibleFrame: smaller)
        XCTAssertEqual(reclamped.width, 700)
        XCTAssertTrue(smaller.contains(reclamped))
        XCTAssertTrue(layout.hasReservedSidebarSpace)
        XCTAssertEqual(layout.setExpanded(true, frame: reclamped, visibleFrame: smaller), reclamped)
    }

    func testUnavailableScreenGeometryUsesNormalMinimumWithoutInventingBounds() {
        var layout = AnswerPanelSidebarLayout()
        XCTAssertEqual(layout.minimumWidth(for: .zero), 420)
        let expanded = layout.setExpanded(true, frame: original, visibleFrame: .zero)
        XCTAssertEqual(expanded, CGRect(x: 239, y: 150, width: 781, height: 600))
        XCTAssertEqual(layout.minimumWidth(for: .zero), 681)
        XCTAssertEqual(layout.setExpanded(false, frame: expanded, visibleFrame: .zero), expanded)
        XCTAssertEqual(layout.setExpanded(true, frame: expanded, visibleFrame: .zero), expanded)
    }

    func testFirstTransitionKeepsConversationWidthAndPositionThroughoutExpansion() {
        var layout = AnswerPanelSidebarLayout()
        let destination = layout.setExpanded(true, frame: original, visibleFrame: screen)
        let transition = AnswerPanelSidebarTransition(fromFrame: original, toFrame: destination,
                                                      fromRevealWidth: 0, toRevealWidth: 261)
        for progress in stride(from: 0.0, through: 1.0, by: 0.05) {
            let sample = transition.sample(progress: progress)
            XCTAssertEqual(sample.frame.width - sample.revealWidth, original.width, accuracy: 0.001)
            XCTAssertEqual(sample.frame.minX + sample.revealWidth, original.minX, accuracy: 0.001)
            XCTAssertEqual(sample.frame.maxX, original.maxX, accuracy: 0.001)
        }
        XCTAssertEqual(transition.sample(progress: -1).frame, original)
        XCTAssertEqual(transition.sample(progress: 2).frame, destination)
    }

    func testCollapseTransitionKeepsWindowFrameWhileConversationGainsSpace() {
        var layout = AnswerPanelSidebarLayout()
        let expanded = layout.setExpanded(true, frame: original, visibleFrame: screen)
        let collapsed = layout.setExpanded(false, frame: expanded, visibleFrame: screen)
        let transition = AnswerPanelSidebarTransition(fromFrame: expanded, toFrame: collapsed,
                                                      fromRevealWidth: 261, toRevealWidth: 0)
        var previousBodyWidth = original.width
        for progress in stride(from: 0.0, through: 1.0, by: 0.05) {
            let sample = transition.sample(progress: progress)
            XCTAssertEqual(sample.frame, expanded)
            XCTAssertGreaterThanOrEqual(sample.frame.width - sample.revealWidth, previousBodyWidth)
            previousBodyWidth = sample.frame.width - sample.revealWidth
        }
        XCTAssertEqual(previousBodyWidth, expanded.width)
    }

    func testReversingPartialFirstExpansionKeepsExpandedTargetWithoutPositionJump() {
        var layout = AnswerPanelSidebarLayout()
        let expanded = layout.setExpanded(true, frame: original, visibleFrame: screen)
        let opening = AnswerPanelSidebarTransition(fromFrame: original, toFrame: expanded,
                                                  fromRevealWidth: 0, toRevealWidth: 261)
        let interrupted = opening.sample(progress: 0.35)
        let collapsed = layout.setExpanded(false, frame: expanded, visibleFrame: screen)
        let closing = AnswerPanelSidebarTransition(fromFrame: interrupted.frame, toFrame: collapsed,
            fromRevealWidth: interrupted.revealWidth, toRevealWidth: 0)
        XCTAssertEqual(closing.sample(progress: 0).frame, interrupted.frame)
        XCTAssertEqual(closing.sample(progress: 0).revealWidth, interrupted.revealWidth)
        XCTAssertEqual(closing.sample(progress: 1).frame, expanded)
        XCTAssertEqual(closing.sample(progress: 1).revealWidth, 0)
        var previousBodyWidth = interrupted.frame.width - interrupted.revealWidth
        for progress in stride(from: 0.0, through: 1.0, by: 0.1) {
            let sample = closing.sample(progress: progress)
            XCTAssertEqual(sample.frame.maxX, original.maxX, accuracy: 0.001)
            XCTAssertGreaterThanOrEqual(sample.frame.width - sample.revealWidth, previousBodyWidth)
            previousBodyWidth = sample.frame.width - sample.revealWidth
        }
        XCTAssertEqual(layout.setExpanded(true, frame: collapsed, visibleFrame: screen), expanded)
    }

    func testReopeningDuringPartialCollapseOnlyChangesRevealWithoutFurtherWindowGrowth() {
        var layout = AnswerPanelSidebarLayout()
        let expanded = layout.setExpanded(true, frame: original, visibleFrame: screen)
        let collapsed = layout.setExpanded(false, frame: expanded, visibleFrame: screen)
        let closing = AnswerPanelSidebarTransition(fromFrame: expanded, toFrame: collapsed,
                                                  fromRevealWidth: 261, toRevealWidth: 0)
        let interrupted = closing.sample(progress: 0.4)
        let reopened = layout.setExpanded(true, frame: collapsed, visibleFrame: screen)
        let opening = AnswerPanelSidebarTransition(fromFrame: interrupted.frame, toFrame: reopened,
            fromRevealWidth: interrupted.revealWidth, toRevealWidth: 261)
        for progress in stride(from: 0.0, through: 1.0, by: 0.1) {
            XCTAssertEqual(opening.sample(progress: progress).frame, expanded)
        }
        XCTAssertEqual(opening.sample(progress: 0).revealWidth, interrupted.revealWidth)
        XCTAssertEqual(opening.sample(progress: 1).revealWidth, 261)
    }

    func testConstrainedFirstTransitionStaysOnScreenWithMonotonicWidth() {
        let smallScreen = CGRect(x: -700, y: 24, width: 700, height: 900)
        let original = CGRect(x: -650, y: 150, width: 600, height: 600)
        var layout = AnswerPanelSidebarLayout()
        let expanded = layout.setExpanded(true, frame: original, visibleFrame: smallScreen)
        let transition = AnswerPanelSidebarTransition(fromFrame: original, toFrame: expanded,
                                                      fromRevealWidth: 0, toRevealWidth: 261)
        var previous = original.width
        for progress in stride(from: 0.0, through: 1.0, by: 0.05) {
            let sample = transition.sample(progress: progress)
            XCTAssertGreaterThanOrEqual(sample.frame.width, previous)
            XCTAssertGreaterThanOrEqual(sample.frame.minX, smallScreen.minX)
            XCTAssertLessThanOrEqual(sample.frame.maxX, smallScreen.maxX)
            XCTAssertGreaterThanOrEqual(sample.frame.width - sample.revealWidth, 420)
            previous = sample.frame.width
        }
    }

    func testMotionContentWidthIsFixedThroughoutEachReveal() {
        for destination in [CGFloat(0), 261] {
            let geometry = AnswerPanelSidebarMotionGeometry(canvasWidth: 781, destinationRevealWidth: destination)
            for reveal in stride(from: CGFloat(0), through: 261, by: 13.05) {
                XCTAssertEqual(geometry.contentWidth, 781 - destination)
                // Its center follows the available region's center without
                // changing the already measured conversation width.
                XCTAssertEqual(geometry.contentOriginX(revealWidth: reveal) + geometry.contentWidth / 2,
                               (781 + reveal) / 2, accuracy: 0.001)
            }
        }
    }

    func testMotionEndpointOriginsMatchExpandedAndCollapsedLayouts() {
        let expanded = AnswerPanelSidebarMotionGeometry(canvasWidth: 781, destinationRevealWidth: 261)
        XCTAssertEqual(expanded.contentWidth, 520)
        XCTAssertEqual(expanded.contentOriginX(revealWidth: 0), 130.5)
        XCTAssertEqual(expanded.contentOriginX(revealWidth: 261), 261)
        XCTAssertEqual(expanded.contentOriginX(revealWidth: 261) + expanded.contentWidth, 781)

        let collapsed = AnswerPanelSidebarMotionGeometry(canvasWidth: 781, destinationRevealWidth: 0)
        XCTAssertEqual(collapsed.contentWidth, 781)
        XCTAssertEqual(collapsed.contentOriginX(revealWidth: 261), 130.5)
        XCTAssertEqual(collapsed.contentOriginX(revealWidth: 0), 0)

        for geometry in [expanded, collapsed] {
            XCTAssertEqual(geometry.sidebarOriginX(revealWidth: 0), -261)
            XCTAssertEqual(geometry.sidebarOriginX(revealWidth: 261), 0)
            XCTAssertEqual(geometry.toggleOriginX(revealWidth: 0), 76)
            XCTAssertEqual(geometry.toggleOriginX(revealWidth: 261), 211)
        }
    }

    func testMotionClampsRevealOvershootWithoutChangingMeasuredWidth() {
        let expanded = AnswerPanelSidebarMotionGeometry(canvasWidth: 781, destinationRevealWidth: 500)
        let collapsed = AnswerPanelSidebarMotionGeometry(canvasWidth: 781, destinationRevealWidth: -100)
        XCTAssertEqual(expanded.contentWidth, 520)
        XCTAssertEqual(collapsed.contentWidth, 781)
        for geometry in [expanded, collapsed] {
            XCTAssertEqual(geometry.contentOriginX(revealWidth: -100), geometry.contentOriginX(revealWidth: 0))
            XCTAssertEqual(geometry.contentOriginX(revealWidth: 500), geometry.contentOriginX(revealWidth: 261))
            XCTAssertEqual(geometry.sidebarOriginX(revealWidth: -100), -261)
            XCTAssertEqual(geometry.sidebarOriginX(revealWidth: 500), 0)
            XCTAssertEqual(geometry.toggleOriginX(revealWidth: -100), 76)
            XCTAssertEqual(geometry.toggleOriginX(revealWidth: 500), 211)
        }
    }

    func testMotionNarrowCanvasNeverProducesNegativeContentWidth() {
        for width in [CGFloat(0), 200, 261, 300, 600] {
            let expanded = AnswerPanelSidebarMotionGeometry(canvasWidth: width, destinationRevealWidth: 261)
            let collapsed = AnswerPanelSidebarMotionGeometry(canvasWidth: width, destinationRevealWidth: 0)
            XCTAssertEqual(expanded.contentWidth, max(0, width - 261))
            XCTAssertEqual(collapsed.contentWidth, width)
            XCTAssertEqual(collapsed.contentOriginX(revealWidth: 0), 0)
            for reveal in [CGFloat(0), 130.5, 261] {
                XCTAssertEqual(expanded.contentWidth, max(0, width - 261))
                XCTAssertEqual(expanded.contentOriginX(revealWidth: reveal),
                               (width - expanded.contentWidth + reveal) / 2)
            }
        }
        let invalidCanvas = AnswerPanelSidebarMotionGeometry(canvasWidth: -20, destinationRevealWidth: 261)
        XCTAssertEqual(invalidCanvas.canvasWidth, 0)
        XCTAssertEqual(invalidCanvas.contentWidth, 0)
    }

    func testMotionRapidReversalChangesWidthOnlyWhenDestinationChanges() {
        var layout = AnswerPanelSidebarLayout()
        let expandedFrame = layout.setExpanded(true, frame: original, visibleFrame: screen)
        let opening = AnswerPanelSidebarMotionGeometry(canvasWidth: expandedFrame.width, destinationRevealWidth: 261)
        let interruptedReveal: CGFloat = 90
        let collapsedFrame = layout.setExpanded(false, frame: expandedFrame, visibleFrame: screen)
        let closing = AnswerPanelSidebarMotionGeometry(canvasWidth: collapsedFrame.width, destinationRevealWidth: 0)
        XCTAssertEqual(expandedFrame, collapsedFrame)
        XCTAssertEqual(opening.contentWidth, 520)
        XCTAssertEqual(closing.contentWidth, 781)
        // Changing the destination changes layout once, but both destination
        // layouts put their content center at the same animated coordinate.
        XCTAssertEqual(opening.contentOriginX(revealWidth: interruptedReveal) + opening.contentWidth / 2,
                       closing.contentOriginX(revealWidth: interruptedReveal) + closing.contentWidth / 2)
        for reveal in [interruptedReveal, 60, 30, 0] {
            XCTAssertEqual(closing.contentWidth, 781)
            XCTAssertEqual(closing.contentOriginX(revealWidth: reveal), reveal / 2)
        }
        let reopenedFrame = layout.setExpanded(true, frame: collapsedFrame, visibleFrame: screen)
        let reopening = AnswerPanelSidebarMotionGeometry(canvasWidth: reopenedFrame.width, destinationRevealWidth: 261)
        XCTAssertEqual(reopenedFrame, expandedFrame)
        XCTAssertEqual(reopening, opening)
    }

    func testMotionFirstExpansionKeepsWorldContentPositionWhileViewportGrows() {
        let geometry = AnswerPanelSidebarMotionGeometry(canvasWidth: 681, destinationRevealWidth: 261)
        let initialWindowX: CGFloat = 500
        for reveal in stride(from: CGFloat(0), through: 261, by: 13.05) {
            let viewportWidth = 420 + reveal
            let windowX = initialWindowX - reveal
            XCTAssertEqual(geometry.contentWidth, 420)
            XCTAssertEqual(geometry.contentOriginX(revealWidth: reveal, viewportWidth: viewportWidth),
                           reveal, accuracy: 0.001)
            XCTAssertEqual(windowX + geometry.contentOriginX(revealWidth: reveal, viewportWidth: viewportWidth),
                           initialWindowX, accuracy: 0.001)
        }
        XCTAssertEqual(geometry.contentOriginX(revealWidth: 0, viewportWidth: 420), 0)
        XCTAssertEqual(geometry.contentOriginX(revealWidth: 261, viewportWidth: 681), 261)
        XCTAssertEqual(geometry.contentOriginX(revealWidth: 0, viewportWidth: 300), -60)
    }

    func testNativeViewportKeepsContentAnchoredWithoutASecondAnimationClock() {
        let motion = AnswerPanelSidebarWindowMotion(fromWidth: 420, toWidth: 681,
            fromRevealWidth: 0, toRevealWidth: 261)
        let geometry = AnswerPanelSidebarMotionGeometry(canvasWidth: 681, destinationRevealWidth: 261)
        // Irregular native frame delivery must not introduce horizontal drift.
        for width: CGFloat in [420, 423, 451, 500, 603, 649, 679.5, 681] {
            let reveal = motion.revealWidth(at: width)
            let windowX = 920 - width
            XCTAssertEqual(windowX + geometry.contentOriginX(revealWidth: reveal, viewportWidth: width),
                           500, accuracy: 0.001)
            XCTAssertEqual(geometry.contentWidth, 420)
        }
        XCTAssertEqual(motion.revealWidth(at: 400), 0)
        XCTAssertEqual(motion.revealWidth(at: 700), 261)
    }

    func testNativeViewportHandlesConstrainedGrowthAndReversal() {
        let opening = AnswerPanelSidebarWindowMotion(fromWidth: 600, toWidth: 700,
            fromRevealWidth: 0, toRevealWidth: 261)
        XCTAssertEqual(opening.revealWidth(at: 650), 130.5)
        let closing = AnswerPanelSidebarWindowMotion(fromWidth: 650, toWidth: 700,
            fromRevealWidth: opening.revealWidth(at: 650), toRevealWidth: 0)
        let openGeometry = AnswerPanelSidebarMotionGeometry(canvasWidth: 700, destinationRevealWidth: 261)
        let closedGeometry = AnswerPanelSidebarMotionGeometry(canvasWidth: 700, destinationRevealWidth: 0)
        XCTAssertEqual(openGeometry.contentOriginX(revealWidth: opening.revealWidth(at: 650), viewportWidth: 650)
                           + openGeometry.contentWidth / 2,
                       closedGeometry.contentOriginX(revealWidth: closing.revealWidth(at: 650), viewportWidth: 650)
                           + closedGeometry.contentWidth / 2)
        XCTAssertEqual(closing.revealWidth(at: 675), 65.25)
        XCTAssertEqual(closing.revealWidth(at: 700), 0)
        let noResize = AnswerPanelSidebarWindowMotion(fromWidth: 700, toWidth: 700,
            fromRevealWidth: 0, toRevealWidth: 261)
        XCTAssertEqual(noResize.revealWidth(at: 700), 261)
    }
}
