import Foundation

/// One exact replacement on one line of a document.
public struct DocumentEdit: Codable, Equatable, Sendable {
    public let line: Int
    public let find: String
    public let replace: String

    public init(line: Int, find: String, replace: String) {
        self.line = line; self.find = find; self.replace = replace
    }
}

/// What a tool-free document editor returns. Text that is not the expected
/// JSON is a plain answer with no edits, so a malformed reply never changes a file.
public struct DocumentEditReply: Equatable, Sendable {
    public var reply: String
    public var edits: [DocumentEdit]
    public var needsFullDocument: Bool

    private struct Payload: Decodable {
        var reply: String?
        var edits: [DocumentEdit]?
        var needsFullDocument: Bool?
    }

    public static func parse(_ text: String) -> DocumentEditReply {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let plain = DocumentEditReply(reply: trimmed, edits: [], needsFullDocument: false)
        guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"), start < end,
              let payload = try? JSONDecoder().decode(Payload.self, from: Data(trimmed[start...end].utf8)),
              payload.reply != nil || payload.edits != nil || payload.needsFullDocument != nil else { return plain }
        return DocumentEditReply(reply: payload.reply ?? "", edits: payload.edits ?? [],
            needsFullDocument: payload.needsFullDocument ?? false)
    }
}

public enum DocumentEditError: Error, Equatable, LocalizedError {
    case lineOutOfRange(Int)
    case textNotFoundOnce(line: Int, find: String)

    public var errorDescription: String? {
        switch self {
        case .lineOutOfRange(let line): "the document has no line \(line)"
        case .textNotFoundOnce(let line, let find): "line \(line) does not contain “\(find.prefix(60))” exactly once"
        }
    }
}

public enum DocumentEditing {
    /// Documents this short are always sent whole.
    public static let windowThresholdCharacters = 6_000
    /// A line must hold this share of the selection's words to stand in for it.
    static let windowMatchThreshold = 0.8
    static let windowWordLimit = 30

    /// Splits on newlines only, so `\r` line endings survive a round trip.
    public static func lines(of text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    /// Zero-based indexes of the lines worth sending for a selection: the line
    /// holding it, its section heading, and a table's header. Nil means send
    /// the whole document, which covers short documents and any selection that
    /// spans lines, such as a whole table.
    public static func window(lines: [String], excerpt: String) -> [Int]? {
        guard lines.reduce(0, { $0 + $1.count + 1 }) > windowThresholdCharacters else { return nil }
        var seen = Set<String>()
        let wanted = words(in: excerpt).filter { seen.insert($0).inserted }.prefix(windowWordLimit)
        guard !wanted.isEmpty else { return nil }
        var best: (index: Int, score: Double)?
        for (index, line) in lines.enumerated() {
            let present = Set(words(in: line))
            let score = Double(wanted.filter(present.contains).count) / Double(wanted.count)
            if score > (best?.score ?? 0) { best = (index, score) }
        }
        guard let best, best.score >= windowMatchThreshold else { return nil }
        var kept: Set<Int> = [best.index]
        if isTableRow(lines[best.index]) {
            var first = best.index
            while first > 0, isTableRow(lines[first - 1]) { first -= 1 }
            kept.insert(first)
            if first + 1 < lines.count { kept.insert(first + 1) }
        } else {
            kept.formUnion(max(0, best.index - 2)...min(lines.count - 1, best.index + 2))
        }
        if let heading = lines[...best.index].lastIndex(where: { $0.hasPrefix("#") }) { kept.insert(heading) }
        return kept.sorted()
    }

    /// Lines as `number<TAB>text`, stopping at `limit` characters so a huge
    /// document cannot grow the prompt without bound.
    public static func numbered(lines: [String], indexes: [Int]? = nil, limit: Int = 48_000) -> String {
        var result: [String] = [], used = 0
        for index in indexes ?? Array(lines.indices) {
            let entry = "\(index + 1)\t\(lines[index])"
            used += entry.count + 1
            guard used <= limit else { break }
            result.append(entry)
        }
        return result.joined(separator: "\n")
    }

    /// Applies every edit or none. `line` numbers refer to the original text,
    /// so a replacement that adds lines never shifts a later edit.
    public static func apply(_ edits: [DocumentEdit], to text: String) throws -> String {
        var result = lines(of: text)
        for edit in edits {
            guard result.indices.contains(edit.line - 1) else { throw DocumentEditError.lineOutOfRange(edit.line) }
            let parts = result[edit.line - 1].components(separatedBy: edit.find)
            guard !edit.find.isEmpty, parts.count == 2 else {
                throw DocumentEditError.textNotFoundOnce(line: edit.line, find: edit.find)
            }
            result[edit.line - 1] = parts.joined(separator: edit.replace)
        }
        return result.joined(separator: "\n")
    }

    private static func isTableRow(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("|")
    }

    private static func words(in text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 }
    }
}
