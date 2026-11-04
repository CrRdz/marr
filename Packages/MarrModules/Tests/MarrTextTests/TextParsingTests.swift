import Foundation
import XCTest
@testable import MarrText

final class TextParsingTests: XCTestCase {
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
                       [.code("print('ok')", language: "python title")])
        XCTAssertEqual(MarkdownBlockParser.parse("```markdown\n    ```\ntext\n```"),
                       [.code("    ```\ntext", language: "markdown")])
        XCTAssertEqual(MarkdownBlockParser.parse("```swift\nlet x = 1\n   ```\nAfter"),
                       [.code("let x = 1", language: "swift"), .paragraph("After")])
    }

    func testFenceFilenameMetadataIsRetainedWithoutChangingCodeOrMisclassifyingLanguage() {
        let info = "swift title=\"Sources/模型.swift\""
        let source = "let value = \"保留内容\""
        XCTAssertEqual(MarkdownBlockParser.parse("```\(info)\n\(source)\n```"), [.code(source, language: info)])
        let header = MarrCodeHeader(language: info)
        XCTAssertEqual(header.language, "swift")
        XCTAssertEqual(header.filename, "Sources/模型.swift")
        XCTAssertEqual(MarrCodeHeader(language: "javascript title=report.diff").language, "javascript")
        XCTAssertEqual(MarrCodeHeader(language: "src/main.py").language, "python")
        XCTAssertEqual(MarrCodeHeader(language: "src/main.py").filename, "src/main.py")
        XCTAssertEqual(MarrCodeHeader(language: nil, filename: "Query.sql").language, "sql")
        XCTAssertNil(MarrCodeHeader(language: "swift").filename)
        XCTAssertNil(MarrCodeHeader(language: "swift", filename: "bad\npath.swift").filename)
    }

    func testLexicalHighlightingCoversOriginalTextExactlyIncludingUnicodeAndIncompleteStreams() {
        let samples: [(String, String)] = [
            ("swift", "let café = \"👩🏽‍💻 // text\"\r\n/* 注释\n仍在注释 */\nreturn 1.5\n"),
            ("python", "def hello():\n\treturn '''unfinished\n中文"),
            ("javascript", "const value = `line\\` value`; // tail\n"),
            ("json", #"{"message":"escaped \"quote\"", "valid":true}"#),
            ("sql", "SELECT 'not -- a comment' FROM records -- comment"),
            ("html", "<!-- comment --><div title=\"中文\">Hello</div>")
        ]
        for (language, source) in samples {
            let tokens = MarrCodeHighlighter.tokens(source, language: language)
            var expectedLocation = 0
            for token in tokens {
                XCTAssertEqual(token.range.location, expectedLocation, "No gaps or overlaps for \(language)")
                XCTAssertGreaterThan(token.range.length, 0)
                expectedLocation = NSMaxRange(token.range)
            }
            XCTAssertEqual(expectedLocation, source.utf16.count)
            XCTAssertEqual(tokens.map { (source as NSString).substring(with: $0.range) }.joined(), source)
        }
        let quoted = #"let text = "// keep this as text" // comment"#
        let tokens = MarrCodeHighlighter.tokens(quoted, language: "swift")
        XCTAssertEqual(tokens.filter { $0.kind == .comment }.map { (quoted as NSString).substring(with: $0.range) }, ["// comment"])
        XCTAssertTrue(tokens.contains { $0.kind == .string })
    }

    func testSyntaxHighlightingBudgetsAndUnknownLanguagesFallBackWithoutDroppingText() {
        let source = "let value = 123; // sample"
        for tokens in [MarrCodeHighlighter.tokens(source, language: "swift", characterLimit: 8),
                       MarrCodeHighlighter.tokens(source, language: "swift", tokenLimit: 1),
                       MarrCodeHighlighter.tokens(source, language: "unknown"),
                       MarrCodeHighlighter.tokens(source, language: nil)] {
            XCTAssertEqual(tokens, [MarrCodeToken(range: NSRange(location: 0, length: source.utf16.count), kind: .plain)])
        }
        XCTAssertEqual(MarrCodeHighlighter.tokens("", language: "swift"), [])
        let preview = MarrCodePreview("one\r\ntwo\rthree\n", lineLimit: 3)
        XCTAssertEqual(preview.text, "one\ntwo\nthree")
        XCTAssertEqual(preview.lineCount, 3)
        XCTAssertTrue(preview.isTruncated)
        XCTAssertEqual(MarrCodePreview("one\n").lineCount, 2)
        XCTAssertEqual(MarrCodePreview("abcdef", characterLimit: 3).text, "abc")
    }

    func testPreviewBudgetsRespectUnicodeScalarsWithoutScanningAnUnboundedGrapheme() {
        XCTAssertEqual(MarrCodePreview("A👩B", characterLimit: 2).text, "A")
        XCTAssertEqual(MarrCodePreview("A👩B", characterLimit: 3).text, "A👩")
        let combining = "a" + String(repeating: "\u{301}", count: 20_000)
        let preview = MarrCodePreview(combining, characterLimit: 17)
        XCTAssertEqual(preview.text.utf16.count, 17)
        XCTAssertTrue(preview.isTruncated)
        XCTAssertFalse(preview.text.contains("\u{FFFD}"))
        XCTAssertTrue(MarrDiffDocument(combining, characterLimit: 17).isTruncated)
        XCTAssertEqual(MarrBoundedSource("👩", utf16Limit: 1).text, "")
        XCTAssertEqual(MarrCodePreview("text", characterLimit: -1).text, "")
        XCTAssertTrue(MarrCodePreview("text", lineLimit: 0).isTruncated)
    }

    func testCancelledLexingAndDiffWorkStopsBeforeBuildingStaleResults() {
        let source = "let value = \"" + String(repeating: "x", count: 40_000)
        var polls = 0
        let tokens = MarrCodeHighlighter.tokens(source, language: "swift", isCancelled: {
            polls += 1
            return polls >= 8
        })
        XCTAssertEqual(tokens, [MarrCodeToken(range: NSRange(location: 0, length: source.utf16.count), kind: .plain)])
        XCTAssertEqual(polls, 8)
        let empty = MarrDiffDocument("@@ -1 +1 @@\n-old\n+new", isCancelled: { true })
        XCTAssertTrue(empty.files.isEmpty)
        let file = MarrDiffDocument("@@ -1 +1 @@\n-old\n+new").files[0]
        XCTAssertTrue(MarrDiffPairing.rows(file.lines, isCancelled: { true }).isEmpty)
    }

    func testSplitDiffPairsUnequalRunsAndPreservesEachSidesOrderAndLineNumbers() throws {
        let source = "@@ -4,5 +7,4 @@\n same\n-old one\n-old two\n+new one\n tail\n-last\n+new last"
        let file = try XCTUnwrap(MarrDiffDocument(source).files.first)
        let rows = MarrDiffPairing.rows(file.lines)
        let left = rows.compactMap(\.left)
        let right = rows.compactMap(\.right)
        XCTAssertEqual(left, file.lines.filter { $0.kind == .context || $0.kind == .deletion })
        XCTAssertEqual(right, file.lines.filter { $0.kind == .context || $0.kind == .addition })
        let changed = rows.filter { $0.left?.kind == .deletion || $0.right?.kind == .addition }
        XCTAssertEqual(changed.count, 3)
        XCTAssertEqual(changed[0].left?.text, "-old one")
        XCTAssertEqual(changed[0].right?.text, "+new one")
        XCTAssertEqual(changed[0].left?.oldLine, 5)
        XCTAssertEqual(changed[0].right?.newLine, 8)
        XCTAssertEqual(changed[1].left?.text, "-old two")
        XCTAssertNil(changed[1].right)
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
    }

    func testSplitDiffNeverPairsAcrossHunksOrMetadata() throws {
        let source = "@@ -1 +0,0 @@\n-gone\n\\ No newline at end of file\n@@ -3,0 +3 @@\n+new"
        let file = try XCTUnwrap(MarrDiffDocument(source).files.first)
        let rows = MarrDiffPairing.rows(file.lines)
        XCTAssertFalse(rows.contains { $0.left?.kind == .deletion && $0.right?.kind == .addition })
        XCTAssertEqual(rows.compactMap(\.shared), file.lines.filter { $0.kind == .hunk || $0.kind == .metadata })
        XCTAssertEqual(rows.compactMap(\.left).map(\.text), ["-gone"])
        XCTAssertEqual(rows.compactMap(\.right).map(\.text), ["+new"])
        XCTAssertTrue(MarrDiffPairing.rows([]).isEmpty)
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

}
