import CoreGraphics
import Foundation
import XCTest
import MarrText

final class MarkdownLineLayoutTests: XCTestCase {
    func testMarkdownLineLayoutWrapsChineseToOriginalLineRects() throws {
        let lineRects = [
            CGRect(x: 0, y: 40, width: 30, height: 16),
            CGRect(x: 0, y: 20, width: 30, height: 16),
            CGRect(x: 0, y: 0, width: 30, height: 16)
        ]

        let lines = try XCTUnwrap(MarkdownLineLayout.lines(
            for: "拥有轮次截图资源",
            lineRects: lineRects,
            codeRects: [],
            availableWidth: { $0.width },
            measuredWidth: { text, _ in CGFloat(text.count * 10) }
        ))

        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines.joined(), "拥有轮次截图资源")
        XCTAssertTrue(lines.allSatisfy { !$0.contains(" ") })
    }

    func testMarkdownLineLayoutUsesOnlyNeededLeadingSourceRows() throws {
        let lineRects = [
            CGRect(x: 0, y: 60, width: 50, height: 16),
            CGRect(x: 0, y: 40, width: 50, height: 16),
            CGRect(x: 0, y: 20, width: 50, height: 16),
            CGRect(x: 0, y: 0, width: 50, height: 16)
        ]

        let lines = try XCTUnwrap(MarkdownLineLayout.lines(
            for: "翻译文字较短",
            lineRects: lineRects,
            codeRects: [],
            availableWidth: { $0.width },
            measuredWidth: { text, _ in CGFloat(text.count * 10) }
        ))

        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.joined(), "翻译文字较短")
    }

    func testMarkdownLineLayoutKeepsFixedListMarkerColumn() throws {
        let lineRects = [
            CGRect(x: 0, y: 20, width: 50, height: 16),
            CGRect(x: 12, y: 0, width: 38, height: 16)
        ]

        let lines = try XCTUnwrap(MarkdownLineLayout.lines(
            for: "• 第一项内容较长",
            lineRects: lineRects,
            codeRects: [],
            availableWidth: { $0.width },
            measuredWidth: { text, _ in CGFloat(text.count * 9) }
        ))

        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("•\t"))
        XCTAssertFalse(lines[1].contains("•"))
    }

    func testMarkdownLineLayoutAnchorsCodeToSourceLine() throws {
        let lineRects = [
            CGRect(x: 0, y: 40, width: 44, height: 16),
            CGRect(x: 0, y: 20, width: 44, height: 16),
            CGRect(x: 0, y: 0, width: 44, height: 16)
        ]
        let codeRects = [
            CGRect(x: 4, y: 20, width: 34, height: 16)
        ]

        let lines = try XCTUnwrap(MarkdownLineLayout.lines(
            for: "使用 `ConversationSession` 管理轮次和截图",
            lineRects: lineRects,
            codeRects: codeRects,
            availableWidth: { $0.width },
            measuredWidth: { text, _ in CGFloat(text.count * 6) }
        ))

        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0], "使用")
        XCTAssertEqual(lines[1], "`ConversationSession`")
        XCTAssertFalse(lines[0].contains("ConversationSession"))
        XCTAssertFalse(lines[2].contains("ConversationSession"))
    }

    func testMarkdownLineLayoutReflowsCodeWithoutSourceAnchors() throws {
        let lineRects = [
            CGRect(x: 0, y: 20, width: 90, height: 16),
            CGRect(x: 0, y: 0, width: 90, height: 16)
        ]

        let lines = try XCTUnwrap(MarkdownLineLayout.lines(
            for: "使用 `ConversationSession` 管理轮次和截图",
            lineRects: lineRects,
            codeRects: [],
            availableWidth: { $0.width },
            measuredWidth: { text, _ in CGFloat(text.count * 6) }
        ))

        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.filter { $0.contains("ConversationSession") }.count, 1)
        XCTAssertEqual(
            lines.joined().replacingOccurrences(of: " ", with: ""),
            "使用`ConversationSession`管理轮次和截图"
        )
    }

    func testMarkdownLineLayoutReflowsMultipleCodeChipsInTranslatedOrder() throws {
        let lineRects = [
            CGRect(x: 0, y: 40, width: 126, height: 16),
            CGRect(x: 0, y: 20, width: 126, height: 16),
            CGRect(x: 0, y: 0, width: 126, height: 16)
        ]

        let lines = try XCTUnwrap(MarkdownLineLayout.lines(
            for: "`VisionAIClient` 接收 `VisionRequest`，`InferenceClient` 负责编码",
            lineRects: lineRects,
            codeRects: [],
            availableWidth: { $0.width },
            measuredWidth: { text, _ in CGFloat(text.count * 5) }
        ))

        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines.filter { $0.contains("VisionAIClient") }.count, 1)
        XCTAssertEqual(lines.filter { $0.contains("VisionRequest") }.count, 1)
        XCTAssertEqual(lines.filter { $0.contains("InferenceClient") }.count, 1)
        let joined = lines.joined().replacingOccurrences(of: " ", with: "")
        XCTAssertLessThan(
            try XCTUnwrap(joined.range(of: "VisionAIClient")?.lowerBound),
            try XCTUnwrap(joined.range(of: "VisionRequest")?.lowerBound)
        )
        XCTAssertLessThan(
            try XCTUnwrap(joined.range(of: "VisionRequest")?.lowerBound),
            try XCTUnwrap(joined.range(of: "InferenceClient")?.lowerBound)
        )
    }

    func testMarkdownLineLayoutRejectsUnmatchedCodeRects() throws {
        let lines = MarkdownLineLayout.lines(
            for: "使用 `ConversationSession` 和 `VisionRequest`",
            lineRects: [
                CGRect(x: 0, y: 20, width: 100, height: 16),
                CGRect(x: 0, y: 0, width: 100, height: 16)
            ],
            codeRects: [
                CGRect(x: 4, y: 0, width: 34, height: 16)
            ],
            availableWidth: { $0.width },
            measuredWidth: { text, _ in CGFloat(text.count * 6) }
        )

        XCTAssertNil(lines)
    }

}
