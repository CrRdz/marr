import AppKit
import Foundation
import ScreenCaptureKit

enum WindowCapture {
    static func capture(_ candidate: WindowCaptureCandidate) async throws -> CapturedWindow {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        )
        guard let window = content.windows.first(where: { $0.windowID == candidate.windowID }) else {
            throw UserFacingError("Could not capture this window. Check Screen Recording permission.")
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = max(1, Int(filter.contentRect.width * scale))
        configuration.height = max(1, Int(filter.contentRect.height * scale))
        configuration.showsCursor = false
        let cgImage = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )

        let prepared = prepareForVision(cgImage)
        let bitmap = NSBitmapImageRep(cgImage: prepared)
        guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.88]) else {
            throw UserFacingError("Could not encode the captured window.")
        }

        let image = NSImage(
            cgImage: prepared,
            size: NSSize(width: prepared.width, height: prepared.height)
        )
        return CapturedWindow(
            image: PickedImage(
                data: data,
                mimeType: "image/jpeg",
                fileName: "\(candidate.title) Window Capture",
                image: image
            ),
            title: candidate.title,
            appName: candidate.appName,
            anchorRect: candidate.anchorRect
        )
    }

    static func captureCandidates() -> [WindowCaptureCandidate] {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        let currentProcessID = Int32(ProcessInfo.processInfo.processIdentifier)
        let candidates = windows.enumerated().compactMap { index, info -> WindowCaptureCandidate? in
            guard
                let ownerPID = info[kCGWindowOwnerPID as String] as? NSNumber,
                ownerPID.int32Value != currentProcessID,
                let windowNumber = info[kCGWindowNumber as String] as? NSNumber,
                let appName = info[kCGWindowOwnerName as String] as? String,
                let layer = info[kCGWindowLayer as String] as? NSNumber,
                let alpha = info[kCGWindowAlpha as String] as? NSNumber,
                alpha.doubleValue > 0,
                let cgBounds = cgRect(from: info)
            else {
                return nil
            }

            let windowName = info[kCGWindowName as String] as? String
            let isOnscreen = (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
            guard isUsefulWindow(
                ownerName: appName,
                windowName: windowName,
                layer: layer.intValue,
                bounds: cgBounds,
                isOnscreen: isOnscreen
            ) else {
                return nil
            }

            let anchorRect = anchorRect(from: info)
            guard isVisibleOnAnyScreen(anchorRect) else { return nil }

            return WindowCaptureCandidate(
                windowID: CGWindowID(windowNumber.uint32Value),
                processID: ownerPID.int32Value,
                title: windowName?.isEmpty == false ? windowName! : appName,
                appName: appName,
                cgBounds: cgBounds,
                anchorRect: anchorRect,
                captureRect: cgBounds,
                layer: layer.intValue,
                isStageManagerSurface: false,
                isStageManagerIconSurface: false,
                windowListIndex: index
            )
        }

        return deduplicate(candidates).sorted { lhs, rhs in
            if lhs.layer != rhs.layer {
                return lhs.layer < rhs.layer
            }
            return lhs.cgBounds.minY < rhs.cgBounds.minY
        }
    }

    private static func isUsefulWindow(
        ownerName: String,
        windowName: String?,
        layer: Int,
        bounds: CGRect,
        isOnscreen: Bool
    ) -> Bool {
        guard
            isOnscreen,
            layer == 0,
            bounds.width >= 120,
            bounds.height >= 80,
            !isIgnoredSystemSurface(ownerName: ownerName, windowName: windowName)
        else {
            return false
        }
        return true
    }

    private static func deduplicate(
        _ candidates: [WindowCaptureCandidate]
    ) -> [WindowCaptureCandidate] {
        var kept: [WindowCaptureCandidate] = []

        for candidate in candidates.sorted(by: preferredForDeduplication) {
            let isDuplicate = kept.contains { existing in
                guard candidate.processID == existing.processID
                        || candidate.appName == existing.appName
                else {
                    return false
                }
                return overlapRatio(candidate.anchorRect, existing.anchorRect) > 0.55
            }
            if !isDuplicate {
                kept.append(candidate)
            }
        }
        return kept
    }

    private static func preferredForDeduplication(
        lhs: WindowCaptureCandidate,
        rhs: WindowCaptureCandidate
    ) -> Bool {
        let lhsUsesAppName = lhs.title == lhs.appName
        let rhsUsesAppName = rhs.title == rhs.appName
        if lhsUsesAppName != rhsUsesAppName {
            return lhsUsesAppName
        }

        let lhsArea = area(lhs.anchorRect)
        let rhsArea = area(rhs.anchorRect)
        if lhsArea != rhsArea {
            return lhsArea > rhsArea
        }
        return lhs.windowListIndex < rhs.windowListIndex
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        max(0, rect.width) * max(0, rect.height)
    }

    private static func overlapRatio(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return area(intersection) / max(1, min(area(lhs), area(rhs)))
    }

    private static func isIgnoredSystemSurface(ownerName: String, windowName: String?) -> Bool {
        let owner = ownerName.lowercased()
        let name = windowName?.lowercased() ?? ""
        let ignoredOwners: Set<String> = [
            "Dock",
            "SystemUIServer",
            "Control Center",
            "Notification Center",
            "Window Server",
            "WindowManager",
            "Spotlight",
            "TextInputMenuAgent",
            "TextInputSwitcher",
            "KeyboardAccessAgent",
            "QuickLookUIService",
            "AutoFill",
            "Passwords"
        ]
        guard !ignoredOwners.contains(ownerName) else { return true }

        let ignoredFragments = [
            "autofill",
            "auto fill",
            "app icon window",
            "gesture blocking overlay",
            "password",
            "textinput",
            "input menu",
            "candidate",
            "popover",
            "tooltip",
            "windowmanager"
        ]
        return ignoredFragments.contains { fragment in
            owner.contains(fragment) || name.contains(fragment)
        }
    }

    private static func isVisibleOnAnyScreen(_ rect: CGRect) -> Bool {
        NSScreen.screens.contains { $0.frame.intersects(rect) }
    }

    private static func anchorRect(from info: [String: Any]) -> CGRect {
        guard let bounds = cgRect(from: info) else {
            return NSScreen.main?.visibleFrame ?? .zero
        }

        for screen in NSScreen.screens {
            let converted = convertToAppKitRect(bounds, on: screen)
            if screen.frame.intersects(converted) {
                return converted
            }
        }
        return NSScreen.main?.visibleFrame ?? bounds
    }

    private static func cgRect(from info: [String: Any]) -> CGRect? {
        guard let bounds = info[kCGWindowBounds as String] as? NSDictionary else {
            return nil
        }
        var rect = CGRect.zero
        return CGRectMakeWithDictionaryRepresentation(bounds, &rect) ? rect : nil
    }

    private static func convertToAppKitRect(_ rect: CGRect, on screen: NSScreen) -> CGRect {
        CGRect(
            x: rect.minX,
            y: screen.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
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

struct CapturedWindow {
    let image: PickedImage
    let title: String
    let appName: String
    let anchorRect: CGRect
}

struct WindowCaptureCandidate: Identifiable, Hashable {
    var id: CGWindowID { windowID }

    let windowID: CGWindowID
    let processID: Int32
    let title: String
    let appName: String
    let cgBounds: CGRect
    let anchorRect: CGRect
    let captureRect: CGRect
    let layer: Int
    let isStageManagerSurface: Bool
    let isStageManagerIconSurface: Bool
    let windowListIndex: Int
}
