import Foundation

/// A contract Focus Queue adds on its own, outside any project's signed files:
/// each provider's global agent contract and the rules every orchestrator gets.
/// The app writes each one out in full so people can read it in the document
/// viewer; agents never read these copies.
public enum BuiltInAgentContract: String, CaseIterable, Identifiable, Sendable {
    case claude, codex, kimi, orchestrator

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .kimi: "Kimi"
        case .orchestrator: "Orchestrator rules"
        }
    }

    /// The bundled payload the installer merges into the provider's instructions file.
    public var resourceName: String? {
        switch self {
        case .claude: "CLAUDE_GLOBAL_INSTRUCTIONS.md"
        case .codex: "CODEX_GLOBAL_INSTRUCTIONS.md"
        case .kimi: "KIMI_GLOBAL_INSTRUCTIONS.md"
        case .orchestrator: nil
        }
    }

    public var fileName: String {
        self == .orchestrator ? "orchestrator-rules.md" : "\(rawValue)-agent-contract.md"
    }

    /// Where agents get the text, stated above the copy.
    public var delivery: String {
        switch self {
        case .claude: "Focus Queue installs this contract into `~/.claude/CLAUDE.md`, which every Claude agent reads."
        case .codex: "Focus Queue installs this contract into `~/.codex/AGENTS.md`, which every Codex agent reads."
        case .kimi:
            "Focus Queue installs this contract into `~/.kimi-code/AGENTS.md` (or `$KIMI_CODE_HOME/AGENTS.md`), which every Kimi agent reads."
        case .orchestrator:
            "Focus Queue adds these rules to every orchestrator's launch brief, prompt hook, task chat, and project QChat, beside the project's signed orchestrator contract."
        }
    }

    public static func directory(root: URL) -> URL {
        root.appendingPathComponent("contracts", isDirectory: true)
            .appendingPathComponent("built-in", isDirectory: true)
    }

    public func url(root: URL) -> URL { Self.directory(root: root).appendingPathComponent(fileName) }

    /// True when this build can produce the text: always for the orchestrator
    /// rules, and when the bundled payload exists for a provider's contract.
    public func isAvailable(resources: URL?) -> Bool {
        guard let resourceName else { return true }
        guard let resources else { return false }
        return FileManager.default.fileExists(atPath: resources.appendingPathComponent(resourceName).path)
    }

    /// The full contract text, or nil when a development build has no bundled payload.
    public func text(resources: URL?) -> String? {
        guard let resourceName else {
            return "# Focus Queue orchestrator rules\n\n\(FocusQueueOrchestratorRules.text)\n"
        }
        guard let resources else { return nil }
        return try? String(contentsOf: resources.appendingPathComponent(resourceName), encoding: .utf8)
    }

    /// The readable copy: a note on where agents get the text, then the text in full.
    public func copy(resources: URL?) -> String? {
        text(resources: resources).map { "> \(delivery) This copy is for reading; edits here are not used.\n\n\($0)" }
    }

    /// Writes the readable copy when it changed and returns its URL, or nil when
    /// the text is unavailable.
    @discardableResult
    public func write(root: URL, resources: URL?) throws -> URL? {
        guard let content = copy(resources: resources) else { return nil }
        let url = url(root: root)
        if (try? String(contentsOf: url, encoding: .utf8)) != content {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    /// Refreshes every copy whose text is available and returns the written URLs.
    @discardableResult
    public static func writeAll(root: URL, resources: URL?) -> [BuiltInAgentContract: URL] {
        var written: [BuiltInAgentContract: URL] = [:]
        for contract in allCases {
            if let url = try? contract.write(root: root, resources: resources) { written[contract] = url }
        }
        return written
    }
}
