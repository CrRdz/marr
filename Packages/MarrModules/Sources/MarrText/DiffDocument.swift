import Foundation

public struct MarrDiffLine: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case context, addition, deletion, hunk, metadata }
    public let id: Int
    public let text: String
    public let kind: Kind
    public let oldLine: Int?
    public let newLine: Int?
}

public struct MarrDiffFile: Identifiable, Equatable, Sendable {
    public let id: Int
    public internal(set) var path: String
    public internal(set) var lines: [MarrDiffLine]
    public var additions: Int { lines.filter { $0.kind == .addition }.count }
    public var deletions: Int { lines.filter { $0.kind == .deletion }.count }
}

/// A bounded presentation of unified diffs; raw text remains available for copying.
/// Headers and binary/rename metadata are retained instead of inventing line numbers.
public struct MarrDiffDocument: Equatable, Sendable {
    public let files: [MarrDiffFile]
    public let isTruncated: Bool

    public init(_ source: String, characterLimit: Int = 200_000, lineLimit: Int = 5_000,
         isCancelled: () -> Bool = { false }) {
        let preview = MarrCodePreview(source, characterLimit: characterLimit, lineLimit: lineLimit, isCancelled: isCancelled)
        let rawLines = preview.text.components(separatedBy: "\n")
        isTruncated = preview.isTruncated
        var result: [MarrDiffFile] = []
        var current = MarrDiffFile(id: 0, path: "Changes", lines: [])
        var oldNumber: Int?
        var newNumber: Int?
        var oldRemaining = 0
        var newRemaining = 0
        var oldPath: String?
        var hasFileHeaders = false
        var hasHunk = false
        let hunk = try? NSRegularExpression(pattern: #"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"#)
        let gitHeader = try? NSRegularExpression(pattern: #"^diff --git ("(?:[^"\\]|\\.)*"|\S+) ("(?:[^"\\]|\\.)*"|\S+)$"#)

        // Git quotes paths with C escapes and octal UTF-8 bytes, not JSON escapes.
        func unquote(_ value: String) -> String? {
            let bytes = Array(value.utf8)
            guard bytes.first == 34, bytes.last == 34, bytes.count >= 2 else { return nil }
            var decoded: [UInt8] = []
            var index = 1
            while index < bytes.count - 1 {
                let byte = bytes[index]
                index += 1
                guard byte == 92 else { decoded.append(byte); continue }
                guard index < bytes.count - 1 else { return nil }
                let escaped = bytes[index]
                index += 1
                if (48...55).contains(escaped) {
                    var octal = Int(escaped - 48)
                    var digits = 1
                    while digits < 3, index < bytes.count - 1, (48...55).contains(bytes[index]) {
                        octal = octal * 8 + Int(bytes[index] - 48)
                        index += 1
                        digits += 1
                    }
                    guard let byte = UInt8(exactly: octal) else { return nil }
                    decoded.append(byte)
                } else {
                    let escapes: [UInt8: UInt8] = [97: 7, 98: 8, 116: 9, 110: 10, 118: 11,
                                                  102: 12, 114: 13, 92: 92, 34: 34]
                    guard let byte = escapes[escaped] else { return nil }
                    decoded.append(byte)
                }
            }
            return String(bytes: decoded, encoding: .utf8)
        }

        func path(_ raw: String, stripDiffPrefix: Bool = true) -> String? {
            var value = raw.components(separatedBy: "\t")[0]
            if value == "/dev/null" { return nil }
            if value.hasPrefix("\""), let decoded = unquote(value) {
                value = decoded
            }
            if stripDiffPrefix, value.hasPrefix("a/") || value.hasPrefix("b/") { value = String(value.dropFirst(2)) }
            return value.isEmpty ? nil : value
        }

        let visibleLines = Array(rawLines.prefix(max(0, lineLimit)))
        for (index, line) in visibleLines.enumerated() {
            if isCancelled() { break }
            let isGitHeader = line.hasPrefix("diff --git ")
            let isNextFileHeader = oldRemaining == 0 && newRemaining == 0
                && (hasFileHeaders || hasHunk) && line.hasPrefix("--- ")
                && index + 1 < visibleLines.count && visibleLines[index + 1].hasPrefix("+++ ")
            if isGitHeader || isNextFileHeader {
                if !current.lines.isEmpty { result.append(current) }
                current = MarrDiffFile(id: result.count, path: "Changes", lines: [])
                oldNumber = nil
                newNumber = nil
                oldRemaining = 0
                newRemaining = 0
                oldPath = nil
                hasFileHeaders = false
                hasHunk = false
            }
            if isGitHeader {
                if let match = gitHeader?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                   let range = Range(match.range(at: 2), in: line) {
                    current.path = path(String(line[range])) ?? "Changes"
                } else if let separator = line.range(of: " b/", options: .backwards) {
                    current.path = String(line[separator.lowerBound...].dropFirst(3))
                }
            }
            var kind = MarrDiffLine.Kind.metadata
            var old: Int?
            var new: Int?
            if let match = hunk?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let oldRange = Range(match.range(at: 1), in: line),
               let newRange = Range(match.range(at: 3), in: line) {
                func count(at group: Int) -> Int {
                    guard let range = Range(match.range(at: group), in: line) else { return 1 }
                    return Int(line[range]) ?? 0
                }
                oldNumber = Int(line[oldRange])
                newNumber = Int(line[newRange])
                oldRemaining = count(at: 2)
                newRemaining = count(at: 4)
                hasHunk = true
                kind = .hunk
            } else if oldRemaining > 0 || newRemaining > 0 {
                if line.hasPrefix("+"), newRemaining > 0 {
                    kind = .addition; new = newNumber
                    newNumber = newNumber.flatMap { $0 < Int.max ? $0 + 1 : nil }
                    newRemaining -= 1
                } else if line.hasPrefix("-"), oldRemaining > 0 {
                    kind = .deletion; old = oldNumber
                    oldNumber = oldNumber.flatMap { $0 < Int.max ? $0 + 1 : nil }
                    oldRemaining -= 1
                } else if line.hasPrefix(" "), oldRemaining > 0, newRemaining > 0 {
                    kind = .context; old = oldNumber; new = newNumber
                    oldNumber = oldNumber.flatMap { $0 < Int.max ? $0 + 1 : nil }
                    newNumber = newNumber.flatMap { $0 < Int.max ? $0 + 1 : nil }
                    oldRemaining -= 1
                    newRemaining -= 1
                } else if !line.hasPrefix("\\") {
                    oldNumber = nil; newNumber = nil
                    oldRemaining = 0; newRemaining = 0
                }
            }
            if kind == .metadata {
                if line.hasPrefix("--- ") { oldPath = path(String(line.dropFirst(4))) }
                if line.hasPrefix("+++ ") {
                    current.path = path(String(line.dropFirst(4))) ?? oldPath ?? current.path
                    hasFileHeaders = true
                }
                if line.hasPrefix("rename to ") {
                    current.path = path(String(line.dropFirst(10)), stripDiffPrefix: false) ?? current.path
                }
            }
            current.lines.append(MarrDiffLine(id: index, text: line, kind: kind, oldLine: old, newLine: new))
        }
        if !current.lines.isEmpty { result.append(current) }
        files = result
    }
}

public struct MarrDiffSplitRow: Identifiable, Equatable, Sendable {
    public let id: Int
    public let left: MarrDiffLine?
    public let right: MarrDiffLine?
    public let shared: MarrDiffLine?
}

/// Pairs contiguous change runs by ordinal position, without inventing an
/// intraline diff or pairing changes across hunk/metadata/context boundaries.
public enum MarrDiffPairing {
    public static func rows(_ lines: [MarrDiffLine], isCancelled: () -> Bool = { false }) -> [MarrDiffSplitRow] {
        var result: [MarrDiffSplitRow] = []
        var removed: [MarrDiffLine] = []
        var added: [MarrDiffLine] = []
        func flush() {
            for index in 0..<max(removed.count, added.count) {
                result.append(MarrDiffSplitRow(id: result.count,
                                               left: index < removed.count ? removed[index] : nil,
                                               right: index < added.count ? added[index] : nil,
                                               shared: nil))
            }
            removed.removeAll(keepingCapacity: true)
            added.removeAll(keepingCapacity: true)
        }
        for line in lines {
            if isCancelled() { return [] }
            switch line.kind {
            case .deletion: removed.append(line)
            case .addition: added.append(line)
            case .context:
                flush()
                result.append(MarrDiffSplitRow(id: result.count, left: line, right: line, shared: nil))
            case .hunk, .metadata:
                flush()
                result.append(MarrDiffSplitRow(id: result.count, left: nil, right: nil, shared: line))
            }
        }
        flush()
        return result
    }
}
