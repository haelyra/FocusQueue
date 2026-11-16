import Foundation

/// Reference cards turn a shorthand code an agent writes (B3, M7, FC2) into a
/// page the user can open: the diagram that shows it, outlined, above its
/// definition. A card is a Markdown file in the task's evidence folder, so it
/// also appears among the task's new outputs. Agents link it as
/// `focusqueue://ref/<TASK>/<CODE>`; the app opens that link in split view.
public enum ReferenceCards {
    public static let scheme = "focusqueue"
    static let host = "ref"
    static let folder = "evidence/refs"

    /// A code is letters then digits, optionally dotted or hyphenated (B3, FC12, M4.1, P-3).
    public static func isValidCode(_ code: String) -> Bool {
        code.count <= 24 && code.range(of: #"^[A-Za-z]+[A-Za-z0-9]*(?:[.-][A-Za-z0-9]+)*$"#,
                                        options: .regularExpression) != nil
            && code.contains(where: \.isNumber)
    }

    public static func link(taskID: String, code: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/\(taskID.uppercased())/\(code)"
        return components.url!
    }

    public static func markdownLink(taskID: String, code: String) -> String {
        "[\(code)](\(link(taskID: taskID, code: code).absoluteString))"
    }

    /// `focusqueue://ref/FOC-133/B3` → ("FOC-133", "B3").
    public static func parse(_ url: URL) -> (taskID: String, code: String)? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == host else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count == 2, isValidCode(parts[1]),
              parts[0].range(of: #"^[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil
        else { return nil }
        return (parts[0].uppercased(), parts[1])
    }

    public static func cardURL(root: URL, taskID: String, code: String) -> URL {
        root.appendingPathComponent("tasks", isDirectory: true)
            .appendingPathComponent(taskID.uppercased(), isDirectory: true)
            .appendingPathComponent(folder, isDirectory: true)
            .appendingPathComponent("\(code).md")
    }

    /// Where to look for definitions, most authoritative first: explicit
    /// documents, then the project's planning files, its module files, any
    /// other project Markdown, and finally the task plan.
    public static func sourceDocuments(projectDirectory: URL?, taskPlan: URL?, explicit: [URL] = []) -> [URL] {
        var urls = explicit.map(\.standardizedFileURL)
        if let projectDirectory {
            let fileManager = FileManager.default
            let names = (try? fileManager.contentsOfDirectory(atPath: projectDirectory.path)) ?? []
            let markdown = names.filter { $0.lowercased().hasSuffix(".md") && !$0.hasPrefix(".") }
            let ranked = ["technical-design", "master-plan", "prd", "design", "devplan", "concept",
                          "architecture", "research", "plan"]
            func rank(_ name: String) -> Int {
                let lower = name.lowercased()
                return ranked.firstIndex(where: { lower.contains($0) }) ?? ranked.count
            }
            for name in markdown.sorted(by: { (rank($0), $0) < (rank($1), $1) }) where name != "data.md" {
                urls.append(projectDirectory.appendingPathComponent(name).standardizedFileURL)
            }
            let modules = projectDirectory.appendingPathComponent("modules", isDirectory: true)
            for name in ((try? fileManager.contentsOfDirectory(atPath: modules.path)) ?? []).sorted()
            where name.lowercased().hasSuffix(".md") {
                urls.append(modules.appendingPathComponent(name).standardizedFileURL)
            }
        }
        if let taskPlan { urls.append(taskPlan.standardizedFileURL) }
        var seen = Set<String>()
        return urls.filter { seen.insert($0.path).inserted }
    }

    /// The task's own documents to search, from its saved context. Reads only
    /// the two paths it needs, so it is safe from any thread.
    public static func sourceDocuments(root: URL, taskID: String, explicit: [URL] = []) -> [URL] {
        let contextURL = root.appendingPathComponent("tasks/\(taskID.uppercased())/context.json")
        let object = (try? SafeFileRead.data(at: contextURL, limit: FileReadLimits.metadataBytes))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let projectPlan = (object?["projectPlanPath"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let plan = (object?["planPath"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? contextURL.deletingLastPathComponent().appendingPathComponent("plan.md").path
        return sourceDocuments(
            projectDirectory: projectPlan.map { URL(fileURLWithPath: $0).deletingLastPathComponent() },
            taskPlan: object == nil ? nil : URL(fileURLWithPath: plan), explicit: explicit)
    }

    /// Builds and saves the card for `code`, or returns nil when no document defines it.
    @discardableResult
    public static func write(root: URL, taskID: String, code: String, documents: [URL],
                             now: Date = Date()) throws -> ReferenceCard? {
        let sources = documents.compactMap(ReferenceSource.load)
        guard let card = build(code: code, taskID: taskID, sources: sources, now: now) else { return nil }
        let url = cardURL(root: root, taskID: taskID, code: code)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Rewriting an unchanged card would announce it as a new output again.
        if (try? String(contentsOf: url, encoding: .utf8)).map(strippingStamp) != strippingStamp(card.markdown) {
            try Data(card.markdown.utf8).write(to: url, options: .atomic)
        }
        return card
    }

    /// The card at its usual place, built first when it is missing.
    public static func ensureCard(root: URL, taskID: String, code: String) -> URL? {
        let url = cardURL(root: root, taskID: taskID, code: code)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let documents = sourceDocuments(root: root, taskID: taskID)
        return (try? write(root: root, taskID: taskID, code: code, documents: documents)) != nil ? url : nil
    }

    /// The defining document named in a card's header comment.
    public static func definitionSource(ofCard url: URL) -> URL? {
        guard let text = try? SafeFileRead.data(at: url, limit: 1_000_000),
              let first = String(data: text, encoding: .utf8)?.split(separator: "\n", maxSplits: 1).first,
              let range = first.range(of: #"source="([^"]+)""#, options: .regularExpression)
        else { return nil }
        let value = first[range].dropFirst("source=\"".count).dropLast()
        let path = value.replacingOccurrences(of: "&quot;", with: "\"")
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : nil
    }

    static func strippingStamp(_ markdown: String) -> String {
        markdown.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix(stampPrefix) }.joined(separator: "\n")
    }

    static let stampPrefix = "<sub>Generated by `focus-queue-session ref`"

    // MARK: - Building

    static func build(code: String, taskID: String, sources: [ReferenceSource], now: Date) -> ReferenceCard? {
        guard let definition = definition(of: code, in: sources) else { return nil }
        let related = relatedCodes(in: definition, sources: sources)
        let diagram = diagram(for: code, definition: definition, related: related, sources: sources)
        let markdown = render(code: code, taskID: taskID, definition: definition, related: related,
                              diagram: diagram, now: now)
        return ReferenceCard(code: code, definition: definition, related: related, diagram: diagram, markdown: markdown)
    }

    /// Strongest match wins: a heading that starts with the code, then a table
    /// row keyed by it, then a list item or line that starts with it, then any
    /// heading that mentions it. Ties go to the earlier document and line.
    static func definition(of code: String, in sources: [ReferenceSource]) -> ReferenceDefinition? {
        var best: (score: Int, definition: ReferenceDefinition)?
        for source in sources {
            for index in source.lines.indices where !source.fenced[index] {
                guard let score = definitionScore(code: code, line: source.lines[index]),
                      best == nil || score > best!.score else { continue }
                best = (score, source.definition(code: code, at: index, score: score))
                if score == 4 { break }
            }
            if best?.score == 4 { break }
        }
        return best?.definition
    }

    static func definitionScore(code: String, line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let heading = ReferenceSource.headingText(line) {
            if startsWithCode(code, ReferenceSource.plain(heading)) { return 4 }
            return containsCode(code, heading) ? 1 : nil
        }
        if trimmed.hasPrefix("|") {
            let cells = ReferenceSource.cells(trimmed)
            return cells.first.map { ReferenceSource.plain($0) == code } == true ? 3 : nil
        }
        let item = trimmed.replacingOccurrences(of: #"^(?:[-*+]|\d+[.)])\s+"#, with: "", options: .regularExpression)
        let plain = ReferenceSource.plain(item)
        guard startsWithCode(code, plain) else { return nil }
        // "B3." or "B3:" or "**B3**" or "B3 —": the code labels the line.
        let rest = plain.dropFirst(code.count).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty || [":", ".", "—", "–", "-", "(", "="].contains(where: rest.hasPrefix) ? 2 : nil
    }

    static func codePattern(_ code: String) -> String {
        #"(?<![A-Za-z0-9_.-])"# + NSRegularExpression.escapedPattern(for: code) + #"(?![A-Za-z0-9_])(?!\.[A-Za-z0-9])"#
    }

    static func containsCode(_ code: String, _ text: String) -> Bool {
        text.range(of: codePattern(code), options: .regularExpression) != nil
    }

    static func startsWithCode(_ code: String, _ text: String) -> Bool {
        text.range(of: "^" + codePattern(code), options: .regularExpression) != nil
    }

    /// Other codes the definition cites that some document also defines.
    static func relatedCodes(in definition: ReferenceDefinition, sources: [ReferenceSource]) -> [String] {
        let text = definition.excerpt + " " + definition.title
        guard let expression = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9_.-])[A-Z]{1,4}-?[0-9]{1,3}(?:\.[0-9]+)?(?![A-Za-z0-9_])"#)
        else { return [] }
        var codes: [String] = []
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            let candidate = String(text[range])
            guard candidate != definition.code, !codes.contains(candidate) else { continue }
            if let found = Self.definition(of: candidate, in: sources), found.score >= 2 { codes.append(candidate) }
            if codes.count == 8 { break }
        }
        return codes
    }

    /// The diagram to show: one that names the code, then one in the code's
    /// own section, then one that names or sits in a related code's section.
    static func diagram(for code: String, definition: ReferenceDefinition, related: [String],
                       sources: [ReferenceSource]) -> ReferenceDiagram? {
        let home = sources.first { $0.url == definition.source }
        let ordered = (home.map { [$0] } ?? []) + sources.filter { $0.url != definition.source }
        func nearest(_ blocks: [MermaidBlock]) -> MermaidBlock? {
            blocks.min { abs($0.start - definition.line) < abs($1.start - definition.line) }
        }
        for source in ordered {
            let naming = source.mermaid.filter { $0.mentions(code) }
            let inSection = naming.filter { definition.sectionRange.contains($0.start) && source.url == definition.source }
            if let block = inSection.first ?? (source.url == definition.source ? nearest(naming) : naming.first) {
                return ReferenceDiagram(source: source, block: block, highlight: code, reason: .namesCode)
            }
        }
        if let home, let block = home.mermaid.first(where: { definition.sectionRange.contains($0.start) }) {
            return ReferenceDiagram(source: home, block: block, highlight: code, reason: .sameSection)
        }
        // A related code's own section (a pipeline with its diagram) beats a
        // diagram that only mentions a related code in passing.
        let relatedDefinitions = related.compactMap { other in Self.definition(of: other, in: sources).map { (other, $0) } }
        for (other, found) in relatedDefinitions where found.score == 4 {
            if let source = sources.first(where: { $0.url == found.source }),
               let block = source.mermaid.first(where: { found.sectionRange.contains($0.start) }) {
                return ReferenceDiagram(source: source, block: block, highlight: other, reason: .related(other, section: found.section))
            }
        }
        for (other, found) in relatedDefinitions {
            for source in ordered {
                if let block = source.mermaid.first(where: { $0.mentions(other) }) {
                    return ReferenceDiagram(source: source, block: block, highlight: other, reason: .related(other, section: found.section))
                }
            }
        }
        return nil
    }

    static func render(code: String, taskID: String, definition: ReferenceDefinition, related: [String],
                       diagram: ReferenceDiagram?, now: Date) -> String {
        let source = definition.source
        let escapedPath = source.path.replacingOccurrences(of: "\"", with: "&quot;")
        var lines = ["<!-- focus-queue-ref code=\"\(code)\" task=\"\(taskID.uppercased())\" source=\"\(escapedPath)\" line=\"\(definition.line + 1)\" -->"]
        lines.append(definition.title.isEmpty ? "# \(code)" : "# \(code) · \(definition.title)")
        lines.append("")
        var located = "**Defined in** [\(source.lastPathComponent)](\(source.absoluteString)), line \(definition.line + 1)"
        if let section = definition.section, section != definition.headingText { located += ", under “\(section)”" }
        lines.append(located + ".")
        if !related.isEmpty {
            lines.append("")
            lines.append("**Related:** " + related.map { markdownLink(taskID: taskID, code: $0) }.joined(separator: " · "))
        }
        lines += ["", "## Diagram", ""]
        if let diagram {
            let file = "[\(diagram.source.url.lastPathComponent)](\(diagram.source.url.absoluteString))"
            let place = diagram.block.section.map { " “\($0)”" } ?? ""
            switch diagram.reason {
            case .namesCode, .sameSection:
                let outlined = diagram.highlighted.isEmpty
                    ? "\(code) has no node of its own here."
                    : "\(code) is outlined in orange."
                lines.append("From \(file)\(place). \(outlined)")
            case .related(let other, _):
                let outlined = diagram.highlighted.isEmpty ? "" : " \(other) is outlined with a dashed line."
                lines.append("No diagram names \(code). This one is from related \(other), in \(file)\(place).\(outlined)")
            }
            lines += ["", "```mermaid", diagram.mermaid, "```"]
        } else {
            lines.append("No diagram in the searched documents shows \(code) or a related code.")
        }
        lines += ["", "## Definition", "", definition.excerpt, ""]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        lines.append("\(stampPrefix) for \(taskID.uppercased()) on \(formatter.string(from: now)). Run it again after the source changes.</sub>")
        return lines.joined(separator: "\n") + "\n"
    }
}

public struct ReferenceCard: Sendable {
    public let code: String
    public let definition: ReferenceDefinition
    public let related: [String]
    public let diagram: ReferenceDiagram?
    public let markdown: String
}

public struct ReferenceDefinition: Sendable, Equatable {
    public let code: String
    public let source: URL
    /// Zero-based line of the defining heading, row, or item.
    public let line: Int
    let score: Int
    /// The nearest heading above the definition, or the defining heading itself.
    public let section: String?
    let headingText: String?
    public let title: String
    public let excerpt: String
    /// Lines the definition's section spans, used to find its own diagram.
    let sectionRange: Range<Int>
}

public struct ReferenceDiagram: Sendable {
    enum Reason: Sendable, Equatable {
        case namesCode
        case sameSection
        case related(String, section: String?)
    }

    let source: ReferenceSource
    let block: MermaidBlock
    let reason: Reason
    /// Node IDs outlined in the diagram.
    public let highlighted: [String]
    public let mermaid: String

    init(source: ReferenceSource, block: MermaidBlock, highlight code: String, reason: Reason) {
        self.source = source
        self.block = block
        self.reason = reason
        let dashed: Bool = if case .related = reason { true } else { false }
        let nodes = block.nodes(mentioning: code)
        highlighted = nodes
        let style = dashed ? "stroke:#f76707,stroke-width:3px,stroke-dasharray:5 3" : "stroke:#f76707,stroke-width:4px"
        mermaid = ([block.body] + nodes.map { "  style \($0) \(style)" }).joined(separator: "\n")
    }

    public var sourceURL: URL { source.url }
}

struct MermaidBlock: Sendable, Equatable {
    let start: Int
    let body: String
    let section: String?

    func mentions(_ code: String) -> Bool { ReferenceCards.containsCode(code, body) }

    var isFlowchart: Bool {
        let first = body.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let keyword = first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        return keyword.hasPrefix("flowchart") || keyword.hasPrefix("graph")
    }

    /// Flowchart node IDs whose ID or label names the code. Labels are
    /// stripped before an ID match, so a code that only appears inside a
    /// label never gets a `style` line that would invent a new node.
    func nodes(mentioning code: String) -> [String] {
        guard isFlowchart, let opener = try? NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9_])([A-Za-z_][A-Za-z0-9_]*)\s*(\[\[|\[\(|\[|\(\(|\(\[|\(|\{\{|\{|>)"#)
        else { return [] }
        var ids: [String] = []
        func add(_ id: String) { if !ids.contains(id), !Self.keywords.contains(id.lowercased()) { ids.append(id) } }
        for raw in body.split(separator: "\n").map(String.init) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("%%") || line.lowercased().hasPrefix("style ") || line.lowercased().hasPrefix("classdef ") { continue }
            let range = NSRange(line.startIndex..., in: line)
            for match in opener.matches(in: line, range: range) {
                guard let idRange = Range(match.range(at: 1), in: line),
                      let openRange = Range(match.range(at: 2), in: line) else { continue }
                let label = Self.label(in: line, after: openRange.upperBound)
                let id = String(line[idRange])
                if id == code || ReferenceCards.containsCode(code, label) { add(id) }
            }
            if line.lowercased().hasPrefix("subgraph ") {
                let rest = String(line.dropFirst("subgraph ".count)).trimmingCharacters(in: .whitespaces)
                if let id = rest.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") }).first,
                   rest.hasPrefix(id), ReferenceCards.containsCode(code, rest) { add(String(id)) }
                continue
            }
            let bare = Self.strippingLabels(line)
            if ReferenceCards.containsCode(code, bare),
               code.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil { add(code) }
        }
        return ids
    }

    static let keywords: Set<String> = ["flowchart", "graph", "subgraph", "end", "style", "class", "classdef",
                                        "click", "linkstyle", "direction"]

    static func label(in line: String, after index: String.Index) -> String {
        let rest = line[index...]
        if rest.first == "\"" {
            let body = rest.dropFirst()
            return String(body.prefix { $0 != "\"" })
        }
        return String(rest.prefix { !"])}".contains($0) })
    }

    /// The line with bracketed labels, edge labels, and quoted text blanked.
    static func strippingLabels(_ line: String) -> String {
        var output = ""
        var depth = 0
        var inQuote = false
        var inPipe = false
        for character in line {
            if character == "\"" { inQuote.toggle(); output.append(" "); continue }
            if inQuote { output.append(" "); continue }
            if character == "|" { inPipe.toggle(); output.append(" "); continue }
            if inPipe { output.append(" "); continue }
            if "[({".contains(character) { depth += 1; output.append(" "); continue }
            if "])}".contains(character) { depth = max(0, depth - 1); output.append(" "); continue }
            output.append(depth > 0 ? " " : character)
        }
        return output
    }
}

/// One Markdown document split into lines, with its headings and Mermaid blocks.
struct ReferenceSource: Sendable, Equatable {
    let url: URL
    let lines: [String]
    /// True for lines inside a fenced code block, fences included.
    let fenced: [Bool]
    let headings: [(line: Int, level: Int, text: String)]
    let mermaid: [MermaidBlock]

    static func == (lhs: ReferenceSource, rhs: ReferenceSource) -> Bool { lhs.url == rhs.url }

    static func load(_ url: URL) -> ReferenceSource? {
        guard let data = try? SafeFileRead.data(at: url, limit: FileReadLimits.editableDocumentBytes),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return ReferenceSource(url: url, text: text)
    }

    init(url: URL, text: String) {
        self.url = url.standardizedFileURL
        lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var fenced = Array(repeating: false, count: lines.count)
        var headings: [(line: Int, level: Int, text: String)] = []
        var blocks: [MermaidBlock] = []
        var fence: (start: Int, marker: String, mermaid: Bool)?
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                fenced[index] = true
                if trimmed.hasPrefix(open.marker), trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "`~")).isEmpty {
                    if open.mermaid {
                        let body = lines[(open.start + 1)..<index].joined(separator: "\n")
                        let section = headings.last { $0.line < open.start }?.text
                        blocks.append(MermaidBlock(start: open.start, body: body, section: section))
                    }
                    fence = nil
                }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker = String(trimmed.prefix { $0 == trimmed.first })
                let info = trimmed.dropFirst(marker.count).trimmingCharacters(in: .whitespaces).lowercased()
                fence = (index, marker, info.hasPrefix("mermaid"))
                fenced[index] = true
                continue
            }
            if let text = Self.headingText(line) {
                headings.append((line: index, level: line.prefix { $0 == "#" }.count, text: text))
            }
        }
        self.fenced = fenced
        self.headings = headings
        mermaid = blocks
    }

    static func headingText(_ line: String) -> String? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix { $0 == "#" }.count
        guard hashes <= 6, line.dropFirst(hashes).first == " " else { return nil }
        return line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
    }

    /// Text without emphasis, code ticks, or link targets.
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "__", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    static func cells(_ row: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var previous: Character?
        for character in row {
            if character == "|", previous != "\\" { cells.append(current); current = "" }
            else { current.append(character) }
            previous = character
        }
        cells.append(current)
        var trimmed = cells.map { $0.trimmingCharacters(in: .whitespaces) }
        if row.hasPrefix("|") { trimmed.removeFirst() }
        if row.hasSuffix("|"), !row.hasSuffix("\\|") { trimmed.removeLast() }
        return trimmed
    }

    /// The heading above `line` and the lines its section spans.
    func section(containing line: Int) -> (text: String?, range: Range<Int>) {
        guard let heading = headings.last(where: { $0.line <= line }) else { return (nil, 0..<lines.count) }
        let end = headings.first { $0.line > heading.line && $0.level <= heading.level }?.line ?? lines.count
        return (heading.text, heading.line..<end)
    }

    func definition(code: String, at index: Int, score: Int) -> ReferenceDefinition {
        let line = lines[index]
        let (sectionText, sectionRange) = section(containing: index)
        let title: String
        let excerpt: String
        var headingText: String?
        if let heading = Self.headingText(line) {
            headingText = heading
            title = Self.title(after: code, in: Self.plain(heading)) ?? Self.plain(heading)
            excerpt = excerptLines(sectionRange.dropFirst())
        } else if line.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
            var top = index
            while top > 0, lines[top - 1].trimmingCharacters(in: .whitespaces).hasPrefix("|") { top -= 1 }
            let header = Self.cells(lines[top].trimmingCharacters(in: .whitespaces)).map(Self.plain)
            let values = Self.cells(line.trimmingCharacters(in: .whitespaces))
            title = values.count > 1 ? Self.shortened(Self.plain(values[1])) : ""
            excerpt = values.indices.dropFirst().map { column in
                let name = column < header.count && !header[column].isEmpty ? header[column] : "Column \(column + 1)"
                let value = values[column].replacingOccurrences(of: "<br/>", with: " ")
                    .replacingOccurrences(of: "<br>", with: " ").replacingOccurrences(of: "\\|", with: "|")
                return "- **\(name):** \(value)"
            }.joined(separator: "\n")
        } else {
            let indent = line.prefix { $0 == " " || $0 == "\t" }.count
            var end = index + 1
            while end < lines.count {
                let next = lines[end]
                let nextIndent = next.prefix { $0 == " " || $0 == "\t" }.count
                if next.trimmingCharacters(in: .whitespaces).isEmpty || Self.headingText(next) != nil { break }
                let isItem = next.trimmingCharacters(in: .whitespaces)
                    .range(of: #"^(?:[-*+]|\d+[.)])\s"#, options: .regularExpression) != nil
                if isItem, nextIndent <= indent { break }
                end += 1
                if end - index >= 30 { break }
            }
            let plainLine = Self.plain(line.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: #"^(?:[-*+]|\d+[.)])\s+"#, with: "", options: .regularExpression))
            title = Self.title(after: code, in: plainLine) ?? ""
            excerpt = lines[index..<end].map { String($0.dropFirst(min(indent, $0.prefix { $0 == " " || $0 == "\t" }.count))) }
                .joined(separator: "\n")
        }
        return ReferenceDefinition(code: code, source: url, line: index, score: score, section: sectionText,
                                   headingText: headingText, title: title,
                                   excerpt: excerpt.isEmpty ? "_The heading has no body text._" : excerpt,
                                   sectionRange: sectionRange)
    }

    /// The section body, without Mermaid blocks (the card shows its diagram
    /// separately), capped so a long section stays a card.
    private func excerptLines(_ range: Range<Int>.SubSequence) -> String {
        var output: [String] = []
        var skipping = false
        for index in range {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if fenced[index], trimmed.lowercased().hasPrefix("```mermaid") || trimmed.lowercased().hasPrefix("~~~mermaid") {
                skipping = true; continue
            }
            if skipping { if fenced[index], trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { skipping = false }; continue }
            output.append(lines[index])
            if output.count >= 60 { output += ["", "_Continues in the source document._"]; break }
        }
        while output.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { output.removeFirst() }
        while output.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { output.removeLast() }
        return output.joined(separator: "\n")
    }

    /// "M7 — Agent resource library" → "Agent resource library".
    static func title(after code: String, in text: String) -> String? {
        guard ReferenceCards.startsWithCode(code, text) else { return nil }
        let rest = text.dropFirst(code.count).trimmingCharacters(in: CharacterSet(charactersIn: " :.—–-=*"))
        return rest.isEmpty ? nil : shortened(rest)
    }

    static func shortened(_ text: String) -> String {
        let firstSentence = text.split(separator: ".", maxSplits: 1).first.map(String.init) ?? text
        let value = firstSentence.count < text.count && firstSentence.count >= 12 ? firstSentence : text
        return value.count > 90 ? String(value.prefix(87)).trimmingCharacters(in: .whitespaces) + "…" : value
    }
}
