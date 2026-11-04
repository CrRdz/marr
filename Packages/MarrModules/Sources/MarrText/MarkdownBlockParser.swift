import Foundation

public enum MarkdownBlock: Equatable, Sendable {
    case image(label: String, source: String)
    case heading(level: Int, content: String)
    case paragraph(String)
    case unorderedList([String])
    case orderedList([String])
    case quote(String)
    case code(String, language: String?)
    case table(headers: [String], rows: [[String]])
    case divider
}

public enum MarkdownBlockParser {
    public static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var index = 0

        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                index += 1
                continue
            }

            if let fence = fence(in: trimmed) {
                index += 1
                var codeLines: [String] = []
                while index < lines.count {
                    let line = lines[index]
                    let indentation = line.prefix { $0 == " " }.count
                    let candidate = line.dropFirst(indentation)
                    let run = candidate.prefix { $0 == fence.marker }.count
                    if indentation <= 3, run >= fence.count,
                       candidate.dropFirst(run).trimmingCharacters(in: .whitespaces).isEmpty { break }
                    codeLines.append(lines[index])
                    index += 1
                }
                if index < lines.count {
                    index += 1
                }
                blocks.append(.code(codeLines.joined(separator: "\n"), language: fence.language))
                continue
            }

            if let image = image(from: trimmed) {
                blocks.append(.image(label: image.label, source: image.source))
                index += 1
                continue
            }

            if let heading = heading(from: trimmed) {
                blocks.append(.heading(level: heading.level, content: heading.content))
                index += 1
                continue
            }

            if index + 1 < lines.count,
               let headers = tableCells(from: lines[index]),
               isTableDivider(lines[index + 1]) {
                index += 2
                var rows: [[String]] = []
                while index < lines.count, let row = tableCells(from: lines[index]) {
                    rows.append(row)
                    index += 1
                }
                blocks.append(.table(headers: headers, rows: rows))
                continue
            }

            if isDivider(trimmed) {
                blocks.append(.divider)
                index += 1
                continue
            }

            if unorderedItem(from: trimmed) != nil {
                var items: [String] = []
                while index < lines.count, let item = unorderedItem(from: lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append(item)
                    index += 1
                }
                blocks.append(.unorderedList(items))
                continue
            }

            if orderedItem(from: trimmed) != nil {
                var items: [String] = []
                while index < lines.count, let item = orderedItem(from: lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append(item)
                    index += 1
                }
                blocks.append(.orderedList(items))
                continue
            }

            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while index < lines.count {
                    let line = lines[index].trimmingCharacters(in: .whitespaces)
                    guard line.hasPrefix(">") else { break }
                    quoteLines.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quoteLines.joined(separator: "\n")))
                continue
            }

            var paragraphLines: [String] = []
            while index < lines.count {
                let line = lines[index].trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, !startsBlock(line) else { break }
                if !paragraphLines.isEmpty, index + 1 < lines.count,
                   tableCells(from: line) != nil, isTableDivider(lines[index + 1]) { break }
                paragraphLines.append(line)
                index += 1
            }
            blocks.append(.paragraph(paragraphLines.joined(separator: " ")))
        }

        return blocks
    }

    private static func startsBlock(_ line: String) -> Bool {
        fence(in: line) != nil
            || image(from: line) != nil
            || line.hasPrefix(">")
            || heading(from: line) != nil
            || unorderedItem(from: line) != nil
            || orderedItem(from: line) != nil
            || isDivider(line)
    }

    private static func fence(in line: String) -> (marker: Character, count: Int, language: String?)? {
        guard let marker = line.first, marker == "`" || marker == "~" else { return nil }
        let count = line.prefix { $0 == marker }.count
        guard count >= 3 else { return nil }
        let info = line.dropFirst(count).trimmingCharacters(in: .whitespaces)
        guard marker != "`" || !info.contains("`") else { return nil }
        // Preserve display metadata (for example filename="Parser.swift").
        // Consumers interpret the first language token separately from it.
        return (marker, count, info.isEmpty ? nil : MarrBoundedSource(info, utf16Limit: 4_096).text)
    }

    private static func image(from line: String) -> (label: String, source: String)? {
        let pattern = #"^!\[([^\]]*)\]\((?:<([^>]+)>|(\S+?))(?:\s+\"[^\"]*\")?\)$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let labelRange = Range(match.range(at: 1), in: line),
              let sourceRange = Range(match.range(at: 2).location != NSNotFound ? match.range(at: 2) : match.range(at: 3), in: line)
        else { return nil }
        return (String(line[labelRange]), String(line[sourceRange]))
    }

    private static func heading(from line: String) -> (level: Int, content: String)? {
        let level = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level) else { return nil }
        let content = line.dropFirst(level)
        guard content.first?.isWhitespace == true else { return nil }
        return (level, content.trimmingCharacters(in: .whitespaces))
    }

    private static func unorderedItem(from line: String) -> String? {
        for prefix in ["- ", "* ", "+ "] where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        return nil
    }

    private static func orderedItem(from line: String) -> String? {
        guard let period = line.firstIndex(of: ".") else { return nil }
        let number = line[..<period]
        let remainder = line[line.index(after: period)...]
        guard Int(number) != nil, remainder.first?.isWhitespace == true else { return nil }
        return remainder.trimmingCharacters(in: .whitespaces)
    }

    private static func isDivider(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let marker = compact.first else { return false }
        return ["-", "*", "_"].contains(String(marker)) && compact.allSatisfy { $0 == marker }
    }

    private static func tableCells(from line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return nil }
        var cells: [String] = []
        var cell = ""
        var escaped = false
        for character in trimmed {
            if character == "|", !escaped {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
            } else {
                cell.append(character)
            }
            escaped = character == "\\" ? !escaped : false
        }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        if trimmed.hasPrefix("|"), cells.first?.isEmpty == true { cells.removeFirst() }
        if trimmed.hasSuffix("|"), cells.last?.isEmpty == true { cells.removeLast() }
        return cells.count >= 2 ? cells : nil
    }

    private static func isTableDivider(_ line: String) -> Bool {
        guard let cells = tableCells(from: line) else { return false }
        return cells.allSatisfy { cell in
            let marker = cell.replacingOccurrences(of: ":", with: "")
            return marker.count >= 3 && marker.allSatisfy { $0 == "-" }
        }
    }
}
