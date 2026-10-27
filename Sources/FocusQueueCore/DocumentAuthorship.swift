import Foundation

/// The task agent whose provider transcript records writing a document.
public struct DocumentAuthor: Equatable, Sendable {
    public let subtaskID: String
    public let provider: AgentProvider
    public let sessionID: String
    public let title: String
    /// When the transcript first wrote (or, lacking a write, first touched) the document.
    public let touchedAt: Date

    public init(subtaskID: String, provider: AgentProvider, sessionID: String, title: String, touchedAt: Date) {
        self.subtaskID = subtaskID
        self.provider = provider
        self.sessionID = sessionID
        self.title = title
        self.touchedAt = touchedAt
    }
}

/// Finds which agent created a document from the agents' own transcripts.
/// Focus Queue records no file ownership, so the transcript tool calls are
/// the only evidence. A write (an edit tool, a patch, or a shell redirect)
/// outranks any other tool call that names the path; among equals the
/// earliest wins. Another tool call, such as a generator script, counts only
/// when it ran just before the file appeared, so reading a file never makes
/// an agent its author.
public enum DocumentAuthorship {
    public struct Touch: Equatable, Sendable {
        public var firstWrite: Date?
        public var toolCalls: [Date] = []
    }

    /// How long before the file's creation a non-write tool call may run.
    static let creationWindow: ClosedRange<TimeInterval> = -120...5

    public static func author(of documentPath: String, agents: [(agent: TaskSubtask, transcript: URL)],
                              createdAt: Date? = nil) -> DocumentAuthor? {
        var best: (author: DocumentAuthor, wrote: Bool)?
        for (agent, transcript) in agents {
            guard let sessionID = agent.sessionID, !agent.isAssignmentOnly else { continue }
            var needles = [documentPath]
            if let workspace = agent.workspace?.path, !workspace.isEmpty,
               documentPath.hasPrefix(workspace.hasSuffix("/") ? workspace : workspace + "/") {
                // Codex patches name files relative to the workspace.
                needles.append(String(documentPath.dropFirst(workspace.count).drop { $0 == "/" }))
            }
            let touch = touches(in: transcript, needles: needles, provider: agent.provider)
            let creating = createdAt.flatMap { created in
                touch.toolCalls.filter { creationWindow.contains($0.timeIntervalSince(created)) }.min()
            }
            guard let date = touch.firstWrite ?? creating else { continue }
            let wrote = touch.firstWrite != nil
            if let current = best {
                if current.wrote && !wrote { continue }
                if current.wrote == wrote && current.author.touchedAt <= date { continue }
            }
            best = (DocumentAuthor(subtaskID: agent.id, provider: agent.provider, sessionID: sessionID,
                title: agent.title, touchedAt: date), wrote)
        }
        return best?.author
    }

    /// Scans a JSONL transcript for tool calls naming any of `needles`.
    public static func touches(in transcript: URL, needles: [String], provider: AgentProvider) -> Touch {
        var touch = Touch()
        let patterns = needles.filter { !$0.isEmpty }.map { Data($0.utf8) }
        guard !patterns.isEmpty,
              let data = try? Data(contentsOf: transcript, options: .alwaysMapped) else { return touch }
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 10) ?? data.endIndex
            let line = data[start..<end]
            start = end < data.endIndex ? data.index(after: end) : end
            guard patterns.contains(where: { line.range(of: $0) != nil }) else { continue }
            let text = String(decoding: line, as: UTF8.self)
            guard let kind = toolCallKind(text, provider: provider, needles: needles),
                  let date = timestamp(text, provider: provider) else { continue }
            if kind == .write, touch.firstWrite.map({ date < $0 }) ?? true { touch.firstWrite = date }
            touch.toolCalls.append(date)
        }
        return touch
    }

    enum ToolCallKind { case write, other }

    /// Shell text that writes the path that follows it. A double quote is
    /// JSON-escaped inside the transcript line.
    static let shellWritePrefixes = [">", "> ", ">>", ">> ", "> \\\"", ">> \\\"", "> '", ">> '",
                                     "tee ", "tee -a ", "-o ", "--output ", "--output="]

    static func toolCallKind(_ line: String, provider: AgentProvider, needles: [String]) -> ToolCallKind? {
        let writeTools: [String]
        switch provider {
        case .claude:
            guard line.contains("\"type\":\"assistant\""), line.contains("\"type\":\"tool_use\"") else { return nil }
            writeTools = ["Write", "Edit", "MultiEdit", "NotebookEdit"]
        case .codex:
            guard line.contains("\"type\":\"function_call\"") || line.contains("\"type\":\"custom_tool_call\"")
            else { return nil }
            writeTools = []
        case .kimi:
            guard line.contains("\"type\":\"tool.call\"") else { return nil }
            writeTools = ["Write", "Edit", "WriteFile", "StrReplaceFile"]
        }
        if writeTools.contains(where: { line.contains("\"name\":\"\($0)\"") }) { return .write }
        let prefixes = ["Add File: ", "Update File: ", "Move to: "] + shellWritePrefixes
        let writes = needles.contains { needle in prefixes.contains { line.contains($0 + needle) } }
        return writes ? .write : .other
    }

    static func timestamp(_ line: String, provider: AgentProvider) -> Date? {
        guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
        if provider == .kimi, let milliseconds = record["time"] as? Double {
            return Date(timeIntervalSince1970: milliseconds / 1000)
        }
        guard let value = record["timestamp"] as? String else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: value) { return date }
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from: value)
    }
}
