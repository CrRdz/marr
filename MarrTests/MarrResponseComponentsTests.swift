import AppKit
import SwiftUI
import XCTest
@testable import Marr

final class MarrResponseComponentsTests: XCTestCase {
    func testStreamingPipeTextDoesNotStallOrBecomeATablePrematurely() {
        XCTAssertEqual(MarkdownBlockParser.parse("result | pending"), [.paragraph("result | pending")])
        XCTAssertEqual(MarkdownBlockParser.parse("| Name | State |\n| ---"),
                       [.paragraph("| Name | State | | ---")])
        XCTAssertEqual(MarkdownBlockParser.parse("Intro\n| Name | State |\n| --- | --- |\n| A | Ready |"),
                       [.paragraph("Intro"), .table(headers: ["Name", "State"], rows: [["A", "Ready"]])])
        XCTAssertEqual(MarkdownBlockParser.parse("| Name | State |\r\n| --- | --- |\r\n| A\\|B | Ready |"),
                       [.table(headers: ["Name", "State"], rows: [["A\\|B", "Ready"]])])
    }

    func testCodeFencesRetainLanguageAndRespectLongerFenceWhenStreaming() {
        XCTAssertEqual(MarkdownBlockParser.parse("```swift\nlet x = 1"),
                       [.code("let x = 1", language: "swift")])
        XCTAssertEqual(MarkdownBlockParser.parse("````markdown\n```swift\nlet x = 1\n```\n````\nAfter"),
                       [.code("```swift\nlet x = 1\n```", language: "markdown"), .paragraph("After")])
        XCTAssertEqual(MarkdownBlockParser.parse("~~~python title\nprint('ok')\n~~~"),
                       [.code("print('ok')", language: "python")])
        XCTAssertEqual(MarkdownBlockParser.parse("```markdown\n    ```\ntext\n```"),
                       [.code("    ```\ntext", language: "markdown")])
        XCTAssertEqual(MarkdownBlockParser.parse("```swift\nlet x = 1\n   ```\nAfter"),
                       [.code("let x = 1", language: "swift"), .paragraph("After")])
    }

    func testDiffLineNumbersSurviveMultipleHunksFilesAndContentThatLooksLikeHeaders() {
        let diff = """
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ -3,2 +3,2 @@
         same
        -old
        +++new
        @@ -10 +12 @@
        -removed
        +added
        diff --git a/b.txt b/b.txt
        --- a/b.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -gone
        \\ No newline at end of file
        """
        let parsed = MarrDiffDocument(diff)
        XCTAssertEqual(parsed.files.map(\.path), ["a.txt", "b.txt"])
        XCTAssertEqual(parsed.files[0].additions, 2)
        XCTAssertEqual(parsed.files[0].deletions, 2)
        XCTAssertEqual(parsed.files[0].lines.first { $0.text == "+++new" }?.newLine, 4)
        XCTAssertEqual(parsed.files[0].lines.first { $0.text == "+added" }?.newLine, 12)
        XCTAssertEqual(parsed.files[1].lines.first { $0.text == "-gone" }?.oldLine, 1)
        XCTAssertNil(parsed.files[1].lines.last?.newLine)
        XCTAssertFalse(parsed.isTruncated)
        XCTAssertEqual(MarrDiffDocument(diff.replacingOccurrences(of: "\n", with: "\r\n")), parsed)
    }

    func testUnifiedDiffWithoutGitHeadersSeparatesFilesAfterConsumedHunks() {
        let diff = """
        --- a/one.txt
        +++ b/one.txt
        @@ -1 +1 @@
        --- old content
        +++ new content
        --- a/two.txt
        +++ b/two.txt
        @@ -5,2 +8,2 @@
         unchanged
        -old
        +new
        """
        let parsed = MarrDiffDocument(diff)
        XCTAssertEqual(parsed.files.map(\.path), ["one.txt", "two.txt"])
        XCTAssertEqual(parsed.files.map(\.additions), [1, 1])
        XCTAssertEqual(parsed.files.map(\.deletions), [1, 1])
        XCTAssertEqual(parsed.files[0].lines.first { $0.text == "--- old content" }?.kind, .deletion)
        XCTAssertEqual(parsed.files[0].lines.first { $0.text == "+++ new content" }?.kind, .addition)
        XCTAssertEqual(parsed.files[1].lines.first?.kind, .metadata)
        XCTAssertNil(parsed.files[1].lines.first?.oldLine)
        XCTAssertEqual(parsed.files[1].lines.first { $0.text == "-old" }?.oldLine, 6)
        XCTAssertEqual(parsed.files[1].lines.first { $0.text == "+new" }?.newLine, 9)
    }

    func testUnifiedDiffZeroLengthRangesDoNotConsumeNextFileHeaders() {
        let diff = """
        --- /dev/null
        +++ b/added.txt
        @@ -0,0 +1,2 @@
        +first
        +second
        --- a/deleted.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -gone
        \\ No newline at end of file
        --- a/last.txt
        +++ b/last.txt
        @@ -1 +1 @@
        -before
        +after
        """
        let parsed = MarrDiffDocument(diff)
        XCTAssertEqual(parsed.files.map(\.path), ["added.txt", "deleted.txt", "last.txt"])
        XCTAssertEqual(parsed.files.map(\.additions), [2, 0, 1])
        XCTAssertEqual(parsed.files.map(\.deletions), [0, 1, 1])
        XCTAssertEqual(parsed.files[0].lines.first { $0.text == "+second" }?.newLine, 2)
        XCTAssertEqual(parsed.files[1].lines.first { $0.text == "-gone" }?.oldLine, 1)
    }

    func testGitQuotedPathsDecodeOctalUTF8AndRenameEscapes() {
        let diff = #"""
        diff --git "a/\344\270\255.txt" "b/\344\270\255.txt"
        --- "a/\344\270\255.txt"
        +++ "b/\344\270\255.txt"
        @@ -1 +1 @@
        -old
        +new
        diff --git "a/\346\227\247.png" "b/\346\226\260.png"
        similarity index 100%
        rename from "\346\227\247.png"
        rename to "b/\346\226\260\t\"name\".png"
        """#
        let parsed = MarrDiffDocument(diff)
        XCTAssertEqual(parsed.files.map(\.path), ["中.txt", "b/新\t\"name\".png"])
        XCTAssertEqual(parsed.files.map(\.additions), [1, 0])
        XCTAssertEqual(parsed.files.map(\.deletions), [1, 0])
        XCTAssertEqual(MarrDiffDocument(#"diff --git "a/\344\270\255.png" "b/\344\270\255.png""#)
            .files.first?.path, "中.png")
    }

    func testDiffBoundsAndRenameMetadataDoNotInventAdditions() {
        let parsed = MarrDiffDocument("diff --git a/old b/new\nsimilarity index 100%\nrename from old\nrename to new")
        XCTAssertEqual(parsed.files.first?.path, "new")
        XCTAssertEqual(parsed.files.first?.additions, 0)
        XCTAssertEqual(MarrDiffDocument("diff --git a/tool b/tool\nold mode 100644\nnew mode 100755").files.first?.path, "tool")
        XCTAssertEqual(MarrDiffDocument("diff --git \"a/image name.png\" \"b/image name.png\"\nBinary files differ").files.first?.path,
                       "image name.png")
        XCTAssertTrue(MarrDiffDocument(String(repeating: "a", count: 101), characterLimit: 100).isTruncated)
        XCTAssertTrue(MarrDiffDocument("a\nb\nc", lineLimit: 2).isTruncated)
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
        for scheme in [ColorScheme.light, .dark] {
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
                MarrCodeBlock(code: "let greeting = \"Hello, 世界\"\nprint(greeting)", language: "swift")
                MarrDiffView(source: "diff --git a/a.swift b/a.swift\n--- a/a.swift\n+++ b/a.swift\n@@ -1 +1 @@\n-let a = 1\n+let a = 2")
            }
            .padding(20)
            .frame(width: 356, height: 610, alignment: .top)
            .background(scheme == .dark ? Color.black : Color.white)
            .environment(\.colorScheme, scheme)
            let host = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 356, height: 610),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            defer { window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("marr-agent-ui-preview")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("response-components-\(scheme == .dark ? "dark" : "light").png")
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
            XCTAssertEqual(host.bounds.width, 356)
            let attachment = XCTAttachment(contentsOfFile: url)
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
