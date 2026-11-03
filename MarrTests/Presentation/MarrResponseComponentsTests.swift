import AppKit
import ImageIO
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers
import Vision
import XCTest
@testable import Marr

final class MarrResponseComponentsTests: XCTestCase {
    @MainActor
    func testMarkdownImagesRenderAutomaticallyAndResetWhenSourceChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        func fixture(_ color: NSColor, type: UTType) throws -> Data {
            let context = try XCTUnwrap(CGContext(data: nil, width: 120, height: 60, bitsPerComponent: 8,
                bytesPerRow: 480, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(try XCTUnwrap(color.usingColorSpace(.deviceRGB)).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 60))
            let data = NSMutableData()
            let frameCount = type == .gif ? 2 : 1
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, frameCount, nil))
            for _ in 0..<frameCount { CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil) }
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            return data as Data
        }
        let png = try fixture(.red, type: .png)
        let gif = try fixture(.green, type: .gif)
        let pngURL = directory.appendingPathComponent("本地 预览.png")
        let gifURL = directory.appendingPathComponent("动画 首帧.gif")
        try png.write(to: pngURL)
        try gif.write(to: gifURL)

        for scheme in [ColorScheme.light, .dark] {
            let frame = NSRect(x: 0, y: 0, width: 356, height: 380)
            func content(_ source: String) -> some View {
                CodexMarkdownImageView(source: source, label: "新版翻译流程预览")
                    .padding(12).frame(width: frame.width, height: frame.height, alignment: .topLeading)
                    .background(scheme == .dark ? Color.black : .white)
                    .environment(\.colorScheme, scheme)
            }
            let host = NSHostingView(rootView: content(pngURL.path))
            host.frame = frame
            let window = MarrOffscreenTestWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.contentView = nil; window.close() }
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = host

            for (source, expectedColor) in [
                (pngURL.path, "red"), (gifURL.absoluteString, "green"),
                ("data:image/png;base64," + png.base64EncodedString(), "red"),
                ("https://example.invalid/explicit-preview.png", "none"),
                (directory.appendingPathComponent("missing.png").path, "error")
            ] {
                host.rootView = content(source)
                let bitmap = try stableOffscreenBitmap(host, window: window)
                let sampled = try XCTUnwrap(bitmap.converting(to: .deviceRGB, renderingIntent: .default))
                var redPixels = 0, greenPixels = 0
                for y in stride(from: 0, to: sampled.pixelsHigh, by: 4) {
                    for x in stride(from: 0, to: sampled.pixelsWide, by: 4) {
                        guard let color = sampled.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                        if color.redComponent > 0.8 && color.greenComponent < 0.2 && color.blueComponent < 0.2 { redPixels += 1 }
                        if color.greenComponent > 0.8 && color.redComponent < 0.2 && color.blueComponent < 0.2 { greenPixels += 1 }
                    }
                }
                if expectedColor == "red" { XCTAssertGreaterThan(redPixels, 100) }
                else { XCTAssertEqual(redPixels, 0, "A replaced image must not remain visible") }
                if expectedColor == "green" { XCTAssertGreaterThan(greenPixels, 100) }
                else { XCTAssertEqual(greenPixels, 0) }
                if expectedColor == "none" || expectedColor == "error" {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage)).perform([request])
                    let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                    if expectedColor == "error" {
                        XCTAssertTrue(text.contains("Retry preview"), text)
                        XCTAssertTrue(text.contains("could not be read"), text)
                    } else {
                        XCTAssertFalse(text.contains("Retry preview"), "Remote images must wait for a click: \(text)")
                    }
                }
                let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                                               uniformTypeIdentifier: UTType.png.identifier)
                attachment.name = "markdown-image-\(expectedColor)-\(scheme)"
                attachment.lifetime = .keepAlways
                add(attachment)
                XCTAssertFalse(window.isVisible)
                XCTAssertFalse(window.isKeyWindow)
            }
        }
    }

    func testThoughtPreviewIsBoundedWithoutChangingTheOriginal() {
        let short = "A short summary with `inline code`."
        XCTAssertEqual(MarrThoughtPreview(short).text, short)
        XCTAssertFalse(MarrThoughtPreview(short).isTruncated)
        let large = String(repeating: "检查布局和图片恢复。", count: 10_000)
        let preview = MarrThoughtPreview(large)
        XCTAssertTrue(preview.isTruncated)
        XCTAssertLessThanOrEqual(preview.text.count, 800)
        XCTAssertTrue(large.hasPrefix(preview.text))
        let lines = (1...30).map { "Line \($0)" }.joined(separator: "\n")
        XCTAssertEqual(MarrThoughtPreview(lines).text.components(separatedBy: "\n").count, 10)
        XCTAssertTrue(MarrThoughtPreview(lines).isTruncated)
        XCTAssertTrue(MarrThoughtPreview("").text.isEmpty)
    }

    func testThoughtTimelineNeverLabelsUnfinishedOrFailedWorkAsDone() {
        func ending(_ activities: [WorkActivity] = [], active: Bool = false,
                    input: Bool = false, uncertain: Bool = false, answer: Bool = false) -> String {
            MarrProcessEnding(activities: activities, active: active, needsInput: input,
                uncertain: uncertain, hasAnswer: answer).title
        }
        XCTAssertEqual(ending(answer: true), "Done")
        XCTAssertEqual(ending(), "Finished")
        XCTAssertEqual(ending(active: true, answer: true), "Working")
        XCTAssertEqual(ending(active: true, input: true), "Needs your input")
        XCTAssertEqual(ending(uncertain: true, answer: true), "Checking status")
        XCTAssertEqual(ending([WorkActivity(kind: .error, title: "Codex task interrupted")]), "Interrupted")
        XCTAssertEqual(ending([WorkActivity(kind: .error, title: "Failed")], answer: true), "Stopped with an error")
        XCTAssertEqual(ending([WorkActivity(kind: .status, title: "Codex task completed")]), "Done")
    }

    @MainActor
    func testReadingTypographyPreservesInlineContentLinksAndCachesEachSize() throws {
        let cache = MarrMarkdownRenderCache()
        let source = "中文 **重点**、*说明*、`file.swift` 与 [文档](https://example.com)。"
        let body = cache.inline(source, fontSize: 14)
        XCTAssertEqual(String(body.characters), "中文 重点、说明、file.swift 与 文档。")
        XCTAssertEqual(body.runs.compactMap(\.link), [URL(string: "https://example.com")!])
        XCTAssertTrue(body.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
        XCTAssertTrue(body.runs.contains { $0.font == .system(size: 13, weight: .regular, design: .monospaced) })
        XCTAssertTrue(body.runs.contains { $0.font == .system(size: 14, weight: .semibold, design: .default) })
        _ = cache.inline(source, fontSize: 18)
        for _ in 0..<20 { XCTAssertEqual(cache.inline(source, fontSize: 14), body) }
        XCTAssertEqual(cache.inlineParseCount, 2, "Layout reuses typography variants without reparsing Markdown")
    }

    @MainActor
    func testBilingualAnswerTypographyRendersAtReadingAndCompactWidths() throws {
        let source = """
        # 对话区排版 · Reading experience

        正文应当清楚、平静，重点放在内容本身。中英文使用同一套字体层级，**重要结论适度强调**，而不是每一段都变成标题。

        This paragraph checks English rhythm alongside 中文、numbers 123 and `inline code`. The answer stays readable without oversized headings or widely separated list items.

        ## 改进内容

        - 提问与回答保持一致的正文比例，换行后仍然有舒适的行距。
        - 列表采用紧凑的条目间距，较长的条目与正文保持相同节奏。

        ### 操作步骤

        1. 打开项目，选择需要继续的对话。
        2. 查看最终结果，按需展开过程记录。

        > 补充说明与正文同字号，用颜色和左侧细线区分，不额外放大。

        ```swift
        let message = "你好，Marr"
        print(message)
        ```

        | 内容 | 状态 |
        | --- | --- |
        | 字体 / Typography | 已统一 |
        | 行距 / Leading | 已调整 |
        """
        for scheme in [ColorScheme.light, .dark] {
            for width in [CGFloat(420), CGFloat(760)] {
                let root = MarkdownResponseView(source: source)
                    .padding(24)
                    .frame(width: width, height: 1000, alignment: .topLeading)
                    .background(scheme == .dark ? Color(white: 0.12) : .white)
                    .environment(\.colorScheme, scheme)
                let frame = NSRect(x: 0, y: 0, width: width, height: 1000)
                let host = NSHostingView(rootView: root)
                host.frame = frame
                let window = MarrOffscreenTestWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                defer { window.contentView = nil; window.close() }
                window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                window.contentView = host
                let bitmap = try stableOffscreenBitmap(host, window: window)
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("marr-agent-ui-preview")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appendingPathComponent("typography-\(Int(width))-\(scheme == .dark ? "dark" : "light").png")
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
                XCTAssertFalse(window.isVisible)
                XCTAssertFalse(window.isKeyWindow)
                let attachment = XCTAttachment(contentsOfFile: url)
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    func testThreadUsageUsesLastRequestNotCumulativeTotalsAndRejectsInvalidData() throws {
        let snapshot: [String: Any] = [
            "last": ["inputTokens": 80, "outputTokens": 20, "cachedInputTokens": 60, "totalTokens": 100],
            "total": ["totalTokens": 50_000],
            "modelContextWindow": 1_000
        ]
        let usage = try XCTUnwrap(CodexThreadTokenUsage(json: snapshot, model: "runtime-model"))
        XCTAssertEqual(usage.lastTotalTokens, 100)
        XCTAssertEqual(usage.lastCachedInputTokens, 60)
        XCTAssertEqual(usage.lastRequestFraction, 0.1)
        var unknown = snapshot
        unknown["modelContextWindow"] = NSNull()
        XCTAssertNil(CodexThreadTokenUsage(json: unknown, model: "m")?.lastRequestFraction)
        unknown["modelContextWindow"] = 0
        XCTAssertNil(CodexThreadTokenUsage(json: unknown, model: "m")?.contextWindow)
        unknown["last"] = ["inputTokens": true, "outputTokens": 0, "cachedInputTokens": 0, "totalTokens": 0]
        XCTAssertNil(CodexThreadTokenUsage(json: unknown, model: "m"))
    }

    @MainActor
    func testCodeAndDiffRenderAtCompactWidthInBothAppearances() throws {
        // These windows never enter the window list or take keyboard focus.
        // Exercise narrow unified fallback and a requested wide split layout.
        for scheme in [ColorScheme.light, .dark] {
            for width in [CGFloat(356), CGFloat(900)] {
                let root = VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("Please review this change.")
                            .font(MarrTypography.font(.body))
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                        MarrMessageActions(text: "Please review this change.", copyTitle: "Copy message", onEdit: {})
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("The response stays in focus; actions sit quietly below.")
                            .font(MarrTypography.font(.answer))
                        MarrMessageActions(text: "The response stays in focus; actions sit quietly below.")
                    }
                    MarrCodeBlock(code: "let greeting = \"Hello, 世界👩🏽‍💻\"\nprint(greeting)",
                                  language: "swift filename=Greeting.swift", initiallyShowsLineNumbers: true)
                    MarrDiffView(source: "diff --git a/a.swift b/a.swift\n--- a/a.swift\n+++ b/a.swift\n@@ -1,2 +1 @@\n-let a = 1\n-let removed = true\n+let a = 2",
                                 initialMode: .sideBySide)
                }
                .padding(20)
                .frame(width: width, height: 610, alignment: .top)
                .background(scheme == .dark ? Color.black : Color.white)
                .environment(\.colorScheme, scheme)
                .transaction { transaction in
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
                let frame = NSRect(x: 0, y: 0, width: width, height: 610)
                let appearance = try XCTUnwrap(NSAppearance(named: scheme == .dark ? .darkAqua : .aqua))
                let host = NSHostingView(rootView: root)
                host.frame = frame
                host.appearance = appearance
                host.autoresizingMask = [.width, .height]
                let window = MarrOffscreenTestWindow(contentRect: frame, styleMask: [.borderless],
                                                     backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = appearance
                window.backgroundColor = scheme == .dark ? .black : .white
                window.contentView = host
                window.setContentSize(frame.size)
                defer { window.close() }
                XCTAssertFalse(window.isVisible)
                XCTAssertFalse(window.isKeyWindow)
                let bitmap = try stableOffscreenBitmap(host, window: window)
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("marr-agent-ui-preview")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appendingPathComponent("response-components-\(Int(width))-\(scheme == .dark ? "dark" : "light").png")
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url, options: .atomic)
                XCTAssertEqual(host.bounds.width, width)
                XCTAssertFalse(window.isVisible)
                XCTAssertFalse(window.isKeyWindow)
                let attachment = XCTAttachment(contentsOfFile: url)
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    /// SwiftUI's async render tasks and AppKit's layer display transactions can
    /// complete on separate run-loop passes. A fixed sleep can capture only a
    /// subset of those layers, even after the view's geometry has stabilized.
    @MainActor
    private func stableOffscreenBitmap<Content: View>(
        _ host: NSHostingView<Content>, window: MarrOffscreenTestWindow
    ) throws -> NSBitmapImageRep {
        let start = Date()
        let deadline = start.addingTimeInterval(3)
        var previousPixels: Data?
        var consecutiveMatches = 0
        var result: NSBitmapImageRep?

        func invalidateDisplay(_ view: NSView) {
            view.needsDisplay = true
            view.subviews.forEach(invalidateDisplay)
        }

        repeat {
            // Let the code/diff background tasks publish state and let SwiftUI
            // reconcile it before forcing the next complete offscreen display.
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
            invalidateDisplay(host)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            host.effectiveAppearance.performAsCurrentDrawingAppearance {
                window.displayIfNeeded()
                host.displayIfNeeded()
                host.layer?.layoutIfNeeded()
                host.layer?.displayIfNeeded()
            }
            CATransaction.commit()
            CATransaction.flush()

            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.effectiveAppearance.performAsCurrentDrawingAppearance {
                host.cacheDisplay(in: host.bounds, to: bitmap)
            }
            let pixels = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            consecutiveMatches = pixels == previousPixels ? consecutiveMatches + 1 : 0
            previousPixels = pixels
            result = bitmap
            XCTAssertFalse(window.isVisible)
            XCTAssertFalse(window.isKeyWindow)

            // The minimum settling interval prevents three fast empty frames
            // from winning before the async component tasks have had a turn.
            if Date().timeIntervalSince(start) >= 0.35, consecutiveMatches >= 3 {
                return bitmap
            }
        } while Date() < deadline

        XCTFail("Offscreen response components did not reach a stable rendered state within three seconds.")
        return try XCTUnwrap(result)
    }

}
