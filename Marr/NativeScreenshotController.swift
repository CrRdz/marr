import AppKit
import Foundation

final class NativeScreenshotController {
    private var process: Process?
    private var temporaryURL: URL?

    func capture(completion: @escaping (Result<PickedImage, Error>) -> Void) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Marr-\(UUID().uuidString)")
            .appendingPathExtension("png")
        temporaryURL = url

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", url.path]
        process.terminationHandler = { [weak self] process in
            guard let self else {
                return
            }

            let result = self.result(from: process, fileURL: url)
            self.cleanup()
            completion(result)
        }

        self.process = process

        do {
            NSApp.hide(nil)
            try process.run()
        } catch {
            cleanup()
            completion(.failure(error))
        }
    }

    func cancel() {
        process?.terminate()
        cleanup()
    }

    private func result(from process: Process, fileURL: URL) -> Result<PickedImage, Error> {
        guard process.terminationStatus == 0 else {
            return .failure(UserFacingError("Capture cancelled."))
        }

        do {
            let data = try Data(contentsOf: fileURL)
            guard let image = NSImage(data: data) else {
                return .failure(UserFacingError("Could not read the captured image."))
            }

            return .success(
                PickedImage(
                    data: data,
                    mimeType: "image/png",
                    fileName: "Screen Capture",
                    image: image
                )
            )
        } catch {
            return .failure(error)
        }
    }

    private func cleanup() {
        process = nil

        if let temporaryURL {
            try? FileManager.default.removeItem(at: temporaryURL)
        }

        temporaryURL = nil
    }
}

enum WindowCapture {
    static func captureFrontmostWindow() throws -> CapturedWindow {
        guard let candidate = captureCandidates().first else {
            throw UserFacingError("No capturable window found.")
        }

        return try capture(candidate)
    }

    static func capture(_ candidate: WindowCaptureCandidate) throws -> CapturedWindow {
        let cgImage: CGImage?
        if candidate.isStageManagerSurface {
            cgImage = CGWindowListCreateImage(
                candidate.captureRect,
                .optionOnScreenOnly,
                kCGNullWindowID,
                [.bestResolution]
            )
        } else {
            cgImage = CGWindowListCreateImage(
                .null,
                .optionIncludingWindow,
                candidate.windowID,
                [.boundsIgnoreFraming, .bestResolution]
            )
        }

        guard let cgImage else {
            throw UserFacingError("Could not capture this window. Check Screen Recording permission.")
        }

        let prepared = prepareForVision(cgImage)
        let bitmap = NSBitmapImageRep(cgImage: prepared)
        guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.88]) else {
            throw UserFacingError("Could not encode the captured window.")
        }

        let image = NSImage(cgImage: prepared, size: NSSize(width: prepared.width, height: prepared.height))

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
        guard let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else {
            return []
        }

        let currentProcessID = Int32(ProcessInfo.processInfo.processIdentifier)
        let candidates = windows.enumerated().compactMap { windowIndex, info -> WindowCaptureCandidate? in
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? NSNumber,
                  ownerPID.int32Value != currentProcessID,
                  let windowNumber = info[kCGWindowNumber as String] as? NSNumber,
                  let appName = info[kCGWindowOwnerName as String] as? String,
                  let layer = info[kCGWindowLayer as String] as? NSNumber,
                  let alpha = info[kCGWindowAlpha as String] as? NSNumber,
                  alpha.doubleValue > 0,
                  let cgBounds = cgRect(from: info) else {
                return nil
            }

            let isOnscreen = (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
            let windowName = info[kCGWindowName as String] as? String
            let isStageManagerSurface = isStageManagerSurface(ownerName: appName, windowName: windowName)

            guard !isStageManagerSurface else {
                return nil
            }

            guard isUsefulWindow(
                ownerName: appName,
                windowName: windowName,
                layer: layer.intValue,
                bounds: cgBounds,
                isOnscreen: isOnscreen
            ) else {
                return nil
            }

            let isStageManagerIconSurface = isStageManagerIconSurface(windowName: windowName)
            let title = displayTitle(ownerName: appName, windowName: windowName)
            let baseAnchorRect = anchorRect(from: info)
            let anchorRect = stageManagerAnchorRect(
                from: baseAnchorRect,
                isIconSurface: isStageManagerIconSurface
            )
            let captureRect = isStageManagerSurface
                ? cgCaptureRect(from: anchorRect)
                : cgBounds
            guard isStageManagerSurface || isVisibleOnAnyScreen(anchorRect) else {
                return nil
            }

            return WindowCaptureCandidate(
                windowID: CGWindowID(windowNumber.uint32Value),
                processID: ownerPID.int32Value,
                title: title,
                appName: appName,
                cgBounds: cgBounds,
                anchorRect: anchorRect,
                captureRect: captureRect,
                layer: layer.intValue,
                isStageManagerSurface: isStageManagerSurface,
                isStageManagerIconSurface: isStageManagerIconSurface,
                windowListIndex: windowIndex
            )
        }

        return deduplicateWindowCaptureCandidates(candidates).sorted { lhs, rhs in
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
        if isStageManagerSurface(ownerName: ownerName, windowName: windowName) {
            return isUsefulWindowManagerSurface(windowName: windowName, bounds: bounds)
        }

        guard !isIgnoredSystemSurface(ownerName: ownerName, windowName: windowName) else {
            return false
        }

        guard isOnscreen else {
            return false
        }

        if layer != 0 {
            return false
        }

        return bounds.width >= 120 && bounds.height >= 80
    }

    private static func isUsefulWindowManagerSurface(windowName: String?, bounds: CGRect) -> Bool {
        let name = windowName?.lowercased() ?? ""

        if name.contains("gesture blocking overlay") {
            return false
        }

        let minDimension = min(bounds.width, bounds.height)
        let maxDimension = max(bounds.width, bounds.height)
        return minDimension >= 36 && maxDimension >= 64
    }

    private static func displayTitle(ownerName: String, windowName: String?) -> String {
        if isStageManagerSurface(ownerName: ownerName, windowName: windowName) {
            return "WindowManager"
        }

        return windowName?.isEmpty == false ? windowName! : ownerName
    }

    private static func isStageManagerSurface(ownerName: String, windowName: String?) -> Bool {
        let owner = ownerName.lowercased()
        let name = windowName?.lowercased() ?? ""

        return owner.contains("windowmanager")
            || name.contains("windowmanager")
            || isStageManagerIconSurface(windowName: windowName)
    }

    private static func isStageManagerIconSurface(windowName: String?) -> Bool {
        let name = windowName?.lowercased() ?? ""
        return name.contains("app icon window")
    }

    private static func deduplicateWindowCaptureCandidates(
        _ candidates: [WindowCaptureCandidate]
    ) -> [WindowCaptureCandidate] {
        let regularCandidates = deduplicateRegularCandidates(candidates.filter { !$0.isStageManagerSurface })
        let stageManagerCandidates = deduplicateStageManagerCandidates(
            candidates.filter(\.isStageManagerSurface)
        ).filter { stageCandidate in
            !regularCandidates.contains { regularCandidate in
                regularWindowDuplicates(stageCandidate: stageCandidate, regularCandidate: regularCandidate)
            }
        }

        return regularCandidates + stageManagerCandidates
    }

    private static func deduplicateRegularCandidates(
        _ candidates: [WindowCaptureCandidate]
    ) -> [WindowCaptureCandidate] {
        var kept: [WindowCaptureCandidate] = []

        for candidate in candidates.sorted(by: regularCandidateSortsBeforeForDeduplication) {
            let duplicatesExisting = kept.contains { existing in
                regularCandidatesAreDuplicates(candidate, existing)
            }

            if !duplicatesExisting {
                kept.append(candidate)
            }
        }

        return kept
    }

    private static func regularCandidateSortsBeforeForDeduplication(
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

    private static func regularCandidatesAreDuplicates(
        _ lhs: WindowCaptureCandidate,
        _ rhs: WindowCaptureCandidate
    ) -> Bool {
        guard lhs.processID == rhs.processID || lhs.appName == rhs.appName else {
            return false
        }

        return overlapRatio(lhs.anchorRect, rhs.anchorRect) > 0.55
    }

    private static func deduplicateStageManagerCandidates(
        _ candidates: [WindowCaptureCandidate]
    ) -> [WindowCaptureCandidate] {
        var kept: [WindowCaptureCandidate] = []

        for candidate in candidates.sorted(by: sortsBeforeForDeduplication) {
            let overlapsExisting = kept.contains { existing in
                isDuplicateStageManagerCandidate(candidate, of: existing)
            }

            if !overlapsExisting {
                kept.append(candidate)
            }
        }

        return kept
    }

    private static func regularWindowDuplicates(
        stageCandidate: WindowCaptureCandidate,
        regularCandidate: WindowCaptureCandidate
    ) -> Bool {
        guard regularCandidate.layer == 0 else {
            return false
        }

        let verticalOverlap = stageCandidate.anchorRect.intersection(regularCandidate.anchorRect).height
        let minHeight = max(1, min(stageCandidate.anchorRect.height, regularCandidate.anchorRect.height))
        let verticalOverlapRatio = verticalOverlap / minHeight
        let centerDistanceY = abs(stageCandidate.anchorRect.midY - regularCandidate.anchorRect.midY)
        let sameVerticalArea = verticalOverlapRatio > 0.30 || centerDistanceY < minHeight * 0.45

        return overlapRatio(stageCandidate.anchorRect, regularCandidate.anchorRect) > 0.08
            || (sameVerticalArea && stageManagerRectsAreInSameStack(stageCandidate.anchorRect, regularCandidate.anchorRect))
    }

    private static func candidateArea(_ candidate: WindowCaptureCandidate) -> CGFloat {
        candidate.isStageManagerSurface ? area(candidate.anchorRect) : area(candidate.cgBounds)
    }

    private static func sortsBeforeForDeduplication(
        lhs: WindowCaptureCandidate,
        rhs: WindowCaptureCandidate
    ) -> Bool {
        if lhs.isStageManagerSurface && rhs.isStageManagerSurface {
            if lhs.isStageManagerIconSurface != rhs.isStageManagerIconSurface {
                return !lhs.isStageManagerIconSurface
            }

            if lhs.isStageManagerIconSurface == false, rhs.isStageManagerIconSurface == false {
                return lhs.windowListIndex < rhs.windowListIndex
            }
        }

        return candidateArea(lhs) > candidateArea(rhs)
    }

    private static func isDuplicateStageManagerCandidate(
        _ candidate: WindowCaptureCandidate,
        of existing: WindowCaptureCandidate
    ) -> Bool {
        if candidate.isStageManagerIconSurface || existing.isStageManagerIconSurface {
            return stageManagerRectsAreInSameStack(candidate.anchorRect, existing.anchorRect)
        }

        return overlapRatio(candidate.anchorRect, existing.anchorRect) > 0.18
            || stageManagerRectsAreInSameStack(candidate.anchorRect, existing.anchorRect)
    }

    private static func stageManagerRectsAreInSameStack(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let dx = abs(lhs.midX - rhs.midX)
        let dy = abs(lhs.midY - rhs.midY)
        let horizontalGap = max(0, max(lhs.minX, rhs.minX) - min(lhs.maxX, rhs.maxX))
        let widthReference = max(1, min(max(lhs.width, rhs.width), 300))
        let heightReference = max(1, min(max(lhs.height, rhs.height), 280))
        let sameVerticalBand = dy < max(120, heightReference * 0.92)
        let horizontallyRelated = dx < max(220, widthReference * 1.18)
            || horizontalGap < max(120, widthReference * 0.70)

        return sameVerticalBand && horizontallyRelated
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        max(0, rect.width) * max(0, rect.height)
    }

    private static func overlapRatio(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else {
            return 0
        }

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
            "Spotlight",
            "TextInputMenuAgent",
            "TextInputSwitcher",
            "KeyboardAccessAgent",
            "QuickLookUIService",
            "AutoFill",
            "Passwords"
        ]

        if ignoredOwners.contains(ownerName) {
            return true
        }

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
            "tooltip"
        ]

        return ignoredFragments.contains { fragment in
            owner.contains(fragment) || name.contains(fragment)
        }
    }

    private static func isVisibleOnAnyScreen(_ rect: CGRect) -> Bool {
        NSScreen.screens.contains { screen in
            screen.frame.intersects(rect)
        }
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

    private static func stageManagerAnchorRect(from rect: CGRect, isIconSurface: Bool) -> CGRect {
        guard isIconSurface else {
            return rect
        }

        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) ?? NSScreen.main else {
            return rect
        }

        let iconSize = max(1, min(rect.width, rect.height))
        let width = min(max(iconSize * 2.35, 176), screen.frame.width * 0.28)
        let height = min(max(iconSize * 2.55, 190), screen.frame.height * 0.32)
        let x = min(max(rect.minX + iconSize * 0.16, screen.frame.minX + 4), screen.frame.maxX - width - 4)
        let y = min(max(rect.minY + iconSize * 0.05, screen.frame.minY + 4), screen.frame.maxY - height - 4)

        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func cgCaptureRect(from appKitRect: CGRect) -> CGRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(appKitRect) } ?? NSScreen.main
        guard let screen else {
            return appKitRect
        }

        let clipped = appKitRect.intersection(screen.frame)
        let rect = clipped.isNull ? appKitRect : clipped
        return CGRect(
            x: rect.minX,
            y: screen.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
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
        let maxPixelDimension = 2200
        let maxDimension = max(image.width, image.height)

        guard maxDimension > maxPixelDimension else {
            return image
        }

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
