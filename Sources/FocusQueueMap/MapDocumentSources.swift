import Foundation

/// Bounded local Markdown indexing. No link fetching, transcript reading, or model
/// calls. A heading stands for its source links until explicitly expanded.
public final class MapDocumentSources {
    private var cache: [String: (Date?, Int, [SourceSection])] = [:]
    public struct SourceSection: Sendable {
        public var title: String
        public var links: [(String, String)]
    }
    public init() {}

    public static func sections(markdown: String) -> [SourceSection] {
        let heading = try! NSRegularExpression(pattern: #"^ {0,3}#{1,6}\s+(.+?)\s*#*$"#)
        let link = try! NSRegularExpression(pattern: #"(?<!!)\[([^\]]+)\]\(<?([^\s)>]+)>?(?:\s+\"[^\"]*\")?\)|<(https?://[^>]+)>"#)
        var result: [SourceSection] = [], title = "Links", links: [(String, String)] = []
        var fence: Character?, fenceCount = 0
        func flush() { if !links.isEmpty { result.append(.init(title: title, links: links)); links = [] } }
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line), trimmed = text.trimmingCharacters(in: .whitespaces)
            if let first = trimmed.first, first == "`" || first == "~" {
                let count = trimmed.prefix(while: { $0 == first }).count
                if count >= 3 {
                    if fence == nil { fence = first; fenceCount = count }
                    else if fence == first && count >= fenceCount { fence = nil }
                    continue
                }
            }
            guard fence == nil else { continue }
            let ns = text as NSString
            if let match = heading.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
                flush(); title = ns.substring(with: match.range(at: 1)); continue
            }
            for match in link.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let target = ns.substring(with: match.range(at: match.range(at: 3).location == NSNotFound ? 2 : 3))
                let label = match.range(at: 1).location == NSNotFound ? target : ns.substring(with: match.range(at: 1))
                if !links.contains(where: { $0.1 == target }), links.count < 100 { links.append((label, target)) }
            }
            if result.count >= 40 { break }
        }
        flush(); return Array(result.prefix(40))
    }

    /// This instance is owned and invoked only by WorkspaceCollector's actor.
    public func enrich(_ snapshot: MapSnapshot) -> MapSnapshot {
        var result = snapshot
        let inputIDs = Set(snapshot.relations.filter { $0.kind == .input || $0.kind == .output }.map { $0.kind == .input ? $0.from : $0.to })
        let documents = snapshot.nodes.filter {
            ($0.kind == .document || inputIDs.contains($0.id)) &&
            ["md", "markdown"].contains(URL(fileURLWithPath: $0.path ?? "").pathExtension.lowercased())
        }.sorted { $0.id < $1.id }.prefix(20)
        let nodeBudget = snapshot.nodes.count + 400
        for document in documents {
            guard result.nodes.count < nodeBudget else { result.omittedPaths += 1; break }
            guard let path = document.path else { continue }
            let file = URL(fileURLWithPath: path)
            guard let metadata = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let size = metadata.fileSize, size <= 128_000 else { continue }
            let sections: [SourceSection]
            if let cached = cache[path], cached.0 == metadata.contentModificationDate && cached.1 == size { sections = cached.2 }
            else {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                sections = Self.sections(markdown: text); cache[path] = (metadata.contentModificationDate, size, sections)
            }
            var occurrences: [String: Int] = [:]
            for section in sections {
                guard result.nodes.count < nodeBudget else { result.omittedPaths += 1; break }
                let ordinal = occurrences[section.title, default: 0]
                occurrences[section.title] = ordinal + 1
                let id = MapNode.identity(document.id, "section", section.title, String(ordinal))
                result.nodes.append(MapNode(id: id, parentID: document.id, kind: .section, label: section.title,
                    path: path, allowedRoot: document.allowedRoot, summary: "\(section.links.count) source links", evidence: "Heading in \(document.label)",
                    observedAt: metadata.contentModificationDate, destination: file.absoluteString))
                for (label, target) in section.links {
                    guard result.nodes.count < nodeBudget else { result.omittedPaths += 1; break }
                    guard let url = URL(string: target, relativeTo: file)?.absoluteURL,
                          ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else { continue }
                    result.nodes.append(MapNode(id: MapNode.identity(id, url.absoluteString), parentID: id, kind: .link,
                        label: label, path: url.isFileURL ? url.path : nil,
                        allowedRoot: url.isFileURL ? document.allowedRoot : nil, summary: url.host ?? url.lastPathComponent,
                        evidence: "Link in \(document.label) / \(section.title)", destination: url.absoluteString))
                }
            }
        }
        if cache.count > 40 { cache = cache.filter { key, _ in documents.contains { $0.path == key } } }
        return result
    }
}
