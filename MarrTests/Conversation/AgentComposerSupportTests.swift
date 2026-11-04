import Foundation
import XCTest
@testable import Marr

final class AgentComposerSupportTests: XCTestCase {
    func testCatalogCoversEntireUpstreamSnapshotWithoutPretendingTerminalSupport() {
        let expected = "model presets daybreak ide permissions keymap vim setup-default-sandbox experimental approve memories skills import hooks review rename new archive delete resume fork worktree app init compact config recap plan voice goal agents side btw copy export raw tui diff mention status daemon warnings cd pwd usage debug-config title statusline theme pets mcp apps plugins logout quit exit feedback rollout ps stop clear test-approval subagents debug-m-drop debug-m-update".split(separator: " ").map(String.init)
        XCTAssertEqual(AgentComposerCatalog.commands.filter(\.isUpstream).map(\.name), expected)
        XCTAssertEqual(Set(AgentComposerCatalog.commands.map(\.id)).count, AgentComposerCatalog.commands.count)
        XCTAssertEqual(AgentComposerCatalog.command(named: "/clean")?.name, "stop")
        XCTAssertEqual(AgentComposerCatalog.command(named: "pet")?.name, "pets")
        XCTAssertEqual(AgentComposerCatalog.command(named: "cwd")?.name, "pwd")
        XCTAssertEqual(AgentComposerCatalog.command(named: "/goooooal")?.name, "goal")
        XCTAssertNil(AgentComposerCatalog.command(named: "g0al"))
        XCTAssertNil(AgentComposerCatalog.command(named: "gal"))
        XCTAssertEqual(AgentComposerCatalog.command(named: "goal")?.support, .runtime)
        for name in ["stop", "delete", "logout", "quit", "exit", "worktree", "approve"] {
            XCTAssertEqual(AgentComposerCatalog.command(named: name)?.support, .terminalOnly, name)
        }
        XCTAssertEqual(AgentComposerCatalog.command(named: "help")?.isUpstream, false)
        XCTAssertEqual(AgentComposerCatalog.command(named: "default")?.isUpstream, false)
        XCTAssertEqual(AgentComposerCatalog.command(named: "default")?.support, .runtime)
        XCTAssertEqual(AgentComposerCatalog.command(named: "default")?.allowedWhileRunning, false)
        XCTAssertNil(AgentComposerCatalog.command(named: "nonexistent"))
    }

    func testSlashIsRestrictedToLeadingCommandAndCaretReplacesWholeWord() throws {
        let text = "/review base main"
        let token = try XCTUnwrap(AgentComposerCompletion.parse(text: text, caretUTF16: 3))
        XCTAssertEqual(Set([token, token]).count, 1)
        XCTAssertEqual(token.kind, .slash)
        XCTAssertEqual(token.query, "re")
        XCTAssertEqual(token.originalText, "/review")
        let edit = try XCTUnwrap(AgentComposerCompletion.replace(text: text, token: token, with: "/rename"))
        XCTAssertEqual(edit.text, "/rename base main")
        XCTAssertEqual(edit.caretUTF16, 8)
        for text in ["Explain /review", "hello\n/review", "/review base"] {
            XCTAssertNil(AgentComposerCompletion.token(in: text, caretUTF16: text.utf16.count), text)
        }
        XCTAssertEqual(AgentComposerCompletion.token(in: "  /pl", caretUTF16: 5)?.query, "pl")
    }

    func testBarePrefixesAndCJKEmojiOffsetsAreValid() throws {
        for (text, kind) in [("/", AgentComposerTokenKind.slash), ("看这里 🧑🏽‍💻 @", .file), ("请使用 $", .skill)] {
            let token = try XCTUnwrap(AgentComposerCompletion.token(in: text, caretUTF16: text.utf16.count))
            XCTAssertEqual(token.kind, kind)
            XCTAssertEqual(token.query, "")
            let edit = try XCTUnwrap(AgentComposerCompletion.replacing(token: token, in: text, with: "@文件.swift"))
            XCTAssertEqual(edit.caretUTF16, edit.text.utf16.count)
        }
        XCTAssertNil(AgentComposerCompletion.token(in: "😀 @foo", caretUTF16: 1))
        XCTAssertNil(AgentComposerCompletion.token(in: "@foo", caretUTF16: -1))
        XCTAssertNil(AgentComposerCompletion.token(in: "@foo", caretUTF16: 100))
    }

    func testFileCompletionPreservesTextOnBothSidesOfCaret() throws {
        let text = "检查 🐈 @src/old.swift 并修改测试"
        let caret = (text as NSString).range(of: "old").location + 1
        let token = try XCTUnwrap(AgentComposerCompletion.token(in: text, caretUTF16: caret))
        XCTAssertEqual(token.query, "src/o")
        let edit = try XCTUnwrap(AgentComposerCompletion.replacing(token: token, in: text, with: "@src/new.swift"))
        XCTAssertEqual(edit.text, "检查 🐈 @src/new.swift 并修改测试")
        XCTAssertEqual(edit.caretUTF16, (edit.text as NSString).range(of: "并").location)
    }

    func testEmailURLsAndEscapedSigilsDoNotTrigger() {
        for text in ["name@example.com", "https://example.com/@path", "prefix$skill", "\\@source", "\\$skill", "\\/review", "@name@example.com"] {
            XCTAssertNil(AgentComposerCompletion.token(in: text, caretUTF16: text.utf16.count), text)
        }
        XCTAssertEqual(AgentComposerCompletion.token(in: "查看 (@file", caretUTF16: 9)?.kind, .file)
    }

    func testInlineAndFencedCodeSuppressCompletionOnlyWithinCode() {
        for text in ["use `@file", "use ``text ` $skill", "```swift\n@file", "~~~text\n$skill", "```\ntext\n/review"] {
            XCTAssertNil(AgentComposerCompletion.token(in: text, caretUTF16: text.utf16.count), text)
        }
        for text in ["`@code` @source", "```\n$code\n```\n$skill", "~~~\n@code\n~~~\n@source", "``text ` text`` $skill"] {
            XCTAssertNotNil(AgentComposerCompletion.token(in: text, caretUTF16: text.utf16.count), text)
        }
    }

    func testShellSyntaxDoesNotBecomeSkillCompletion() {
        for text in ["$HOME", "$PATH", "$XDG_CONFIG_HOME", "$1", "$123", "$-", "$_", "${HOME}", "$(whoami", "$?", "$!"] {
            XCTAssertNil(AgentComposerCompletion.token(in: text, caretUTF16: text.utf16.count), text)
        }
        for text in ["$home", "$home:search", "$plugin:skill", "$2d-plot", "$Skill"] {
            XCTAssertEqual(AgentComposerCompletion.token(in: text, caretUTF16: text.utf16.count)?.kind, .skill, text)
        }
    }

    func testQuotedFileNamesRoundTripAndReplaceCompleteQuotedToken() throws {
        let candidate = AgentComposerCandidate.file(path: "/tmp/My Files/a.swift", displayPath: "My Files/a.swift")
        XCTAssertEqual(candidate.insertion, "@\"My Files/a.swift\"")
        let text = "Read @\"My Files/old.swift\" next"
        let caret = (text as NSString).range(of: "old").location + 1
        let token = try XCTUnwrap(AgentComposerCompletion.token(in: text, caretUTF16: caret))
        XCTAssertEqual(token.query, "My Files/o")
        XCTAssertEqual(token.originalText, "@\"My Files/old.swift\"")
        XCTAssertEqual(AgentComposerCompletion.replacing(token: token, in: text, with: candidate.insertion)?.text, "Read @\"My Files/a.swift\" next")
        let escaped = AgentComposerCandidate.file(path: "/tmp/a\"b.swift", displayPath: "a\"b.swift")
        XCTAssertEqual(escaped.insertion, "@\"a\\\"b.swift\"")
        let escapedToken = try XCTUnwrap(AgentComposerCompletion.token(in: escaped.insertion, caretUTF16: escaped.insertion.utf16.count))
        XCTAssertEqual(escapedToken.query, "a\"b.swift")
        let sigil = AgentComposerCandidate.file(path: "/tmp/name@example.txt", displayPath: "name@example.txt")
        XCTAssertEqual(sigil.insertion, "@\"name@example.txt\"")
        XCTAssertEqual(AgentComposerCompletion.token(in: sigil.insertion, caretUTF16: sigil.insertion.utf16.count)?.query, "name@example.txt")
    }

    func testCompletionKeepsNewlineAndReusesOneHorizontalSeparator() throws {
        for (text, expected, caret) in [("@old\nnext", "@new \nnext", 5), ("@old\t next", "@new\t next", 5), ("(@old)", "(@new )", 6)] {
            let pos = (text as NSString).range(of: "old").location + 3
            let token = try XCTUnwrap(AgentComposerCompletion.token(in: text, caretUTF16: pos))
            let edit = try XCTUnwrap(AgentComposerCompletion.replacing(token: token, in: text, with: "@new"))
            XCTAssertEqual(edit.text, expected)
            XCTAssertEqual(edit.caretUTF16, caret)
        }
    }

    func testDelayedCompletionCannotOverwriteChangedToken() throws {
        let token = try XCTUnwrap(AgentComposerCompletion.token(in: "@old", caretUTF16: 4))
        XCTAssertNil(AgentComposerCompletion.replacing(token: token, in: "@new", with: "@replacement"))
        XCTAssertNil(AgentComposerCompletion.replacing(token: token, in: "", with: "@replacement"))
    }

    func testCandidatesRankExactThenPrefixSegmentSubstringAndSubsequence() {
        let files = ["a/p-l-a-n.swift", "explanner.swift", "src/plan.swift", "planner.swift", "plan"].map { AgentComposerCandidate.file(path: $0) }
        XCTAssertEqual(AgentComposerCompletion.rankedCandidates(query: "plan", candidates: files).map(\.id), ["plan", "planner.swift", "src/plan.swift", "explanner.swift", "a/p-l-a-n.swift"])
        XCTAssertTrue(AgentComposerCompletion.rankedCandidates(query: "no-match-xyz", candidates: files).isEmpty)
        XCTAssertEqual(AgentComposerCompletion.rankedCandidates(query: "plan", candidates: files, limit: 2).count, 2)
        XCTAssertTrue(AgentComposerCompletion.rankedCandidates(query: "", candidates: files, limit: 0).isEmpty)
    }

    func testSkillNamesUseIdentityPathsAndStableCaseInsensitiveRanking() {
        let skills = [AgentComposerCandidate.skill(name: "Résumé", path: "/b/SKILL.md"), .skill(name: "resume", path: "/a/SKILL.md"), .skill(name: "other", path: "/other", description: "resume workflows")]
        XCTAssertEqual(AgentComposerCompletion.rankedCandidates(query: "RESUME", candidates: skills).map(\.id), ["/a/SKILL.md", "/b/SKILL.md", "/other"])
        XCTAssertEqual(AgentComposerCompletion.rankedCandidates(query: "", candidates: skills + [skills[0]]).count, 3)
        XCTAssertEqual(skills[0].insertion, "$Résumé")
    }

    func testKindFiltersAndBusyCommandsPreserveExplicitDisabledReasons() throws {
        let slash = try XCTUnwrap(AgentComposerCompletion.token(in: "/", caretUTF16: 1))
        let commands = AgentComposerCompletion.candidates(for: slash, isRunning: true, limit: 100)
        XCTAssertEqual(commands.first(where: { $0.id == "review" })?.isEnabled, false)
        XCTAssertNotNil(commands.first(where: { $0.id == "review" })?.disabledReason)
        XCTAssertEqual(commands.first(where: { $0.id == "goal" })?.isEnabled, true)
        XCTAssertEqual(commands.first(where: { $0.id == "stop" })?.disabledReason, "此客户端尚未接入")
        XCTAssertNil(commands.first(where: { $0.id == "test-approval" }))
        let token = try XCTUnwrap(AgentComposerCompletion.token(in: "$", caretUTF16: 1))
        let skill = AgentComposerCandidate.skill(name: "test", path: "/skills/test")
        let file = AgentComposerCandidate.file(path: "test.swift")
        XCTAssertEqual(AgentComposerCompletion.candidates(for: token, skills: [skill, file], files: [file]), [skill])
    }

    func testAliasesSearchCanonicalInsertionAndUpstreamBusyMetadataRemainsVisible() throws {
        let token = try XCTUnwrap(AgentComposerCompletion.token(in: "/cwd", caretUTF16: 4))
        XCTAssertEqual(AgentComposerCompletion.candidates(for: token).first?.insertion, "/pwd")
        let archive = try XCTUnwrap(AgentComposerCatalog.command(named: "archive"))
        XCTAssertTrue(archive.upstreamAllowedWhileRunning)
        XCTAssertFalse(archive.allowedWhileRunning)
        XCTAssertTrue(AgentComposerCatalog.command(named: "plan")!.supportsInlineArguments)
        XCTAssertFalse(AgentComposerCatalog.command(named: "goal")!.debugOnly)
    }
}
