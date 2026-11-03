import Foundation

/// Fence metadata is display information, never a path to open or execute.
public struct MarrCodeHeader: Equatable, Sendable {
    public let language: String?
    public let filename: String?

    public init(language hint: String?, filename explicitFilename: String? = nil) {
        let info = MarrBoundedSource(hint ?? "", utf16Limit: 4_096).text.trimmingCharacters(in: .whitespacesAndNewlines)
        let first = info.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        var name = Self.validFilename(explicitFilename)
        if name == nil, let expression = try? NSRegularExpression(pattern: #"(?:^|\s)(?:filename|file|title)=(?:"([^"]+)"|'([^']+)'|(\S+))"#),
           let match = expression.firstMatch(in: info, range: NSRange(info.startIndex..., in: info)) {
            for group in 1...3 where match.range(at: group).location != NSNotFound {
                if let range = Range(match.range(at: group), in: info) {
                    name = Self.validFilename(String(info[range]))
                }
            }
        }
        let inferred = Self.languageForFilename(first)
        if name == nil, inferred != nil { name = Self.validFilename(first) }
        filename = name
        let candidate = first.isEmpty || first.contains("=") ? nil : first.lowercased()
        language = inferred ?? candidate ?? name.flatMap(Self.languageForFilename)
    }

    private static func validFilename(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf16.count <= 1_024,
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return trimmed
    }

    public static func languageForFilename(_ value: String) -> String? {
        let ext = (value as NSString).pathExtension.lowercased()
        return ["swift": "swift", "py": "python", "js": "javascript", "jsx": "javascript",
                "ts": "typescript", "tsx": "typescript", "json": "json", "yml": "yaml", "yaml": "yaml",
                "sh": "shell", "bash": "shell", "zsh": "shell", "rb": "ruby", "rs": "rust", "go": "go",
                "c": "c", "h": "c", "cpp": "cpp", "hpp": "cpp", "cs": "csharp", "java": "java",
                "kt": "kotlin", "sql": "sql", "css": "css", "html": "html", "xml": "xml",
                "diff": "diff", "patch": "diff"][ext]
    }
}

public struct MarrCodeToken: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case plain, keyword, string, comment, number }
    public internal(set) var range: NSRange
    public let kind: Kind
}

/// A bounded lexical colorizer, not an AST or language validator. Every UTF-16
/// unit belongs to exactly one span, including incomplete strings and comments.
public enum MarrCodeHighlighter {
    public static let characterLimit = 60_000
    public static let tokenLimit = 1_200

    public static func tokens(_ source: String, language hint: String?,
                       characterLimit: Int = characterLimit, tokenLimit: Int = tokenLimit,
                       isCancelled: () -> Bool = { false }) -> [MarrCodeToken] {
        let length = source.utf16.count
        guard length > 0 else { return [] }
        let fallback = [MarrCodeToken(range: NSRange(location: 0, length: length), kind: .plain)]
        guard !isCancelled(), length <= max(0, characterLimit), tokenLimit > 0,
              let language = normalizedLanguage(MarrCodeHeader(language: hint).language) else { return fallback }
        let units = Array(source.utf16)
        var result: [MarrCodeToken] = []
        var index = 0
        let hashComments = ["python", "shell", "ruby", "yaml", "toml"].contains(language)
        let slashComments = !["python", "shell", "ruby", "yaml", "toml", "json", "sql", "html", "xml"].contains(language)
        let keywords = keywordSet(for: language)

        func matches(_ ascii: [UInt16], at offset: Int) -> Bool {
            guard offset + ascii.count <= units.count else { return false }
            for index in ascii.indices where units[offset + index] != ascii[index] { return false }
            return true
        }
        func identifierStart(_ value: UInt16) -> Bool {
            (65...90).contains(value) || (97...122).contains(value) || value == 95 || value == 36
        }
        func identifierPart(_ value: UInt16) -> Bool { identifierStart(value) || (48...57).contains(value) }
        func add(_ kind: MarrCodeToken.Kind, from start: Int) {
            if let last = result.last, last.kind == kind, NSMaxRange(last.range) == start {
                result[result.count - 1].range.length += index - start
            } else {
                result.append(MarrCodeToken(range: NSRange(location: start, length: index - start), kind: kind))
            }
        }

        while index < units.count {
            if result.count >= tokenLimit || isCancelled() { return fallback }
            let start = index
            let value = units[index]
            if (hashComments && value == 35) || (slashComments && matches([47, 47], at: index))
                || (language == "sql" && matches([45, 45], at: index)) {
                while index < units.count, units[index] != 10, units[index] != 13 {
                    if index & 255 == 0, isCancelled() { return fallback }
                    index += 1
                }
                add(.comment, from: start)
            } else if (slashComments && matches([47, 42], at: index))
                        || (["html", "xml"].contains(language) && matches([60, 33, 45, 45], at: index)) {
                let markup = value == 60
                let closing: [UInt16] = markup ? [45, 45, 62] : [42, 47]
                index += markup ? 4 : 2
                while index < units.count, !matches(closing, at: index) {
                    if index & 255 == 0, isCancelled() { return fallback }
                    index += 1
                }
                if index < units.count { index += closing.count }
                add(.comment, from: start)
            } else if value == 34 || value == 39 || (value == 96 && ["javascript", "typescript", "shell"].contains(language)) {
                let triple = ["python", "swift", "kotlin"].contains(language) && matches([value, value, value], at: index)
                let closing = Array(repeating: value, count: triple ? 3 : 1)
                index += closing.count
                while index < units.count {
                    if index & 255 == 0, isCancelled() { return fallback }
                    if units[index] == 92 { index = min(units.count, index + 2); continue }
                    if matches(closing, at: index) { index += closing.count; break }
                    index += 1
                }
                add(.string, from: start)
            } else if (48...57).contains(value) {
                index += 1
                while index < units.count, identifierPart(units[index]) || units[index] == 46 {
                    if index & 255 == 0, isCancelled() { return fallback }
                    index += 1
                }
                add(.number, from: start)
            } else if identifierStart(value) {
                index += 1
                while index < units.count, identifierPart(units[index]) {
                    if index & 255 == 0, isCancelled() { return fallback }
                    index += 1
                }
                let word = String(decoding: units[start..<index], as: UTF16.self)
                add(keywords.contains(language == "sql" ? word.lowercased() : word) ? .keyword : .plain, from: start)
            } else {
                index += 1
                add(.plain, from: start)
            }
        }
        return result
    }

    private static func normalizedLanguage(_ value: String?) -> String? {
        guard let value else { return nil }
        let aliases = ["js": "javascript", "jsx": "javascript", "ts": "typescript", "tsx": "typescript",
                       "py": "python", "sh": "shell", "bash": "shell", "zsh": "shell", "rb": "ruby",
                       "rs": "rust", "c++": "cpp", "c#": "csharp", "yml": "yaml"]
        let language = aliases[value] ?? value
        return ["swift", "javascript", "typescript", "python", "shell", "ruby", "rust", "go", "c", "cpp",
                "csharp", "java", "kotlin", "json", "yaml", "toml", "sql", "css", "html", "xml"].contains(language) ? language : nil
    }

    private static func keywordSet(for language: String) -> Set<String> {
        if language == "json" { return ["true", "false", "null"] }
        if language == "sql" {
            return Set("select from where join left right inner outer on as insert into values update set delete create table alter drop group by order having limit distinct union and or not null true false case when then else end asc desc".split(separator: " ").map(String.init))
        }
        return Set("actor async await as break case catch class const continue def defer do else enum except export extends false final finally fn for from func function guard if impl import in init interface internal is let match mut new nil none None null package private protocol public raise repeat return self Self static struct super switch throw throws true try type typeof var void while with yield".split(separator: " ").map(String.init))
    }
}

/// Limits UTF-16 storage while stopping only at a Unicode scalar boundary.
/// Unlike Character.prefix/count, this does not scan an unbounded grapheme (for
/// example a base character followed by millions of combining marks), or the
/// rest of a very large response merely to decide whether it was truncated.
public struct MarrBoundedSource: Equatable, Sendable {
    public let text: String
    public let isTruncated: Bool

    public init(_ source: String, utf16Limit: Int, isCancelled: () -> Bool = { false }) {
        let scalars = source.unicodeScalars
        var end = scalars.startIndex
        var units = 0
        let limit = max(0, utf16Limit)
        while end < scalars.endIndex {
            if units & 255 == 0, isCancelled() { break }
            let count = scalars[end].value > 0xFFFF ? 2 : 1
            guard count <= limit - units else { break }
            units += count
            scalars.formIndex(after: &end)
        }
        text = String(scalars[..<end])
        isTruncated = end < scalars.endIndex
    }
}

/// Rendering is bounded independently of highlighting. Copy always uses the
/// original code, even when this display prefix is limited. The storage budget
/// is UTF-16 units; supplementary scalars are never split or replaced.
public struct MarrCodePreview: Equatable, Sendable {
    public let text: String
    public let lineCount: Int
    public let isTruncated: Bool

    public init(_ source: String, characterLimit: Int = 200_000, lineLimit: Int = 5_000,
         isCancelled: () -> Bool = { false }) {
        let prefix = MarrBoundedSource(source, utf16Limit: characterLimit, isCancelled: isCancelled)
        let bounded = prefix.text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = bounded.components(separatedBy: "\n")
        let visible = Array(lines.prefix(max(0, lineLimit)))
        text = visible.joined(separator: "\n")
        lineCount = visible.count
        isTruncated = prefix.isTruncated || lines.count > max(0, lineLimit)
    }
}
