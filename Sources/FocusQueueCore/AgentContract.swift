import CryptoKit
import Foundation

/// Which project contract an agent follows. Task agents are engineering agents;
/// task chat, project-scoped QChat, and launches with the orchestrator role follow
/// the orchestrator contract. All-projects QChat follows neither, since projects differ.
public enum AgentContractRole: String, Codable, CaseIterable, Sendable, Identifiable {
    case engineering, orchestrator

    public var id: String { rawValue }

    /// Launch roles come from the shell entries (`coding`, `research`, `orchestrator`)
    /// and the app's launch options. Anything but orchestrator is engineering.
    public init(launchRole: String?) {
        let role = launchRole?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self = role == "orchestrator" ? .orchestrator : .engineering
    }

    /// The live file or its draft.
    public init?(fileName: String) {
        guard let match = Self.allCases.first(where: { $0.fileName == fileName || $0.draftFileName == fileName })
        else { return nil }
        self = match
    }

    public var fileName: String { self == .engineering ? "agent-contract.md" : "orchestration.md" }
    public var draftFileName: String { self == .engineering ? "agent-contract.draft.md" : "orchestration.draft.md" }
    public var title: String { self == .engineering ? "Engineering" : "Orchestrator" }
    public var other: AgentContractRole { self == .engineering ? .orchestrator : .engineering }
    /// Limits from the bundled generator prompt; lint reports them as warnings.
    public var essentialsRuleLimit: Int { self == .engineering ? 5 : 8 }
    public var essentialsCharacterLimit: Int { self == .engineering ? 1_000 : 1_600 }
    public static let recommendedRuleLimit = 7
}

/// The owner's sign-off. The signed text is kept so it stays live while a later,
/// unsigned edit of the file waits for review.
public struct AgentContractSignoff: Codable, Equatable, Sendable {
    public var sha256: String
    public var signedAt: Date
    public var signedBy: String
    public var text: String

    public init(text: String, signedAt: Date = Date(), signedBy: String = "human") {
        self.sha256 = AgentContract.digest(text); self.signedAt = signedAt
        self.signedBy = signedBy; self.text = text
    }
}

public enum AgentContractState: String, Equatable, Sendable {
    /// No file and no sign-off.
    case missing
    /// A file nobody signed off; agents get nothing from it.
    case unsigned
    /// The file is exactly the signed version.
    case live
    /// The file changed (or vanished) after sign-off; the signed version stays live.
    case pending
}

public struct AgentContractLintIssue: Equatable, Sendable, Identifiable {
    public var line: Int?
    public var message: String
    public var id: String { "\(line ?? 0):\(message)" }

    public init(line: Int?, message: String) { self.line = line; self.message = message }

    public var text: String { line.map { "Line \($0): \(message)" } ?? message }
}

public struct AgentContractStatus: Equatable, Sendable {
    public var role: AgentContractRole
    public var fileURL: URL
    public var draftURL: URL
    public var state: AgentContractState
    public var hasDraft: Bool
    public var signoff: AgentContractSignoff?
    /// Lint of the file on disk (the draft's lint when only a draft exists).
    public var lint: [AgentContractLintIssue]
}

/// What a brief or chat turn inlines for one role.
public struct AgentContractInjection: Equatable, Sendable {
    public var role: AgentContractRole
    public var lines: [String]
    /// Characters of contract text inlined, for prompt-usage analytics.
    public var inlinedCharacters: Int
}

public enum AgentContractError: Error, Equatable, LocalizedError {
    case changedOnDisk(String)
    case missingFile(String)
    case missingDraft(String)
    case redirected(String)
    case malformedOutput(String)

    public var errorDescription: String? {
        switch self {
        case .changedOnDisk(let name): "\(name) changed on disk after you opened it. Reload it, review the new text, then sign off."
        case .missingFile(let name): "\(name) does not exist yet. Generate or write it first."
        case .missingDraft(let name): "There is no draft \(name) to sign off."
        case .redirected(let name): "\(name) is a symbolic link; contracts must be regular files in the project folder."
        case .malformedOutput(let detail): "The generator reply could not be split into contracts: \(detail)"
        }
    }
}

public enum AgentContract {
    /// Each role's inlined Essentials stop here, with a pointer to the file. The
    /// orchestrator's own generator limit is higher, so Essentials that pass lint
    /// are always inlined whole.
    public static let injectionLimit = 1_500

    public static func injectionLimit(for role: AgentContractRole) -> Int {
        max(injectionLimit, role.essentialsCharacterLimit)
    }
    public static let reviewFileName = "contract-review.md"

    public static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func status(role: AgentContractRole, directory: URL,
                              signoff: AgentContractSignoff?) -> AgentContractStatus {
        let file = directory.appendingPathComponent(role.fileName)
        let draft = directory.appendingPathComponent(role.draftFileName)
        let text = try? String(contentsOf: file, encoding: .utf8)
        let draftText = try? String(contentsOf: draft, encoding: .utf8)
        let state: AgentContractState
        switch (text, signoff) {
        case (nil, nil): state = .missing
        case (.some, nil): state = .unsigned
        case (.some(let text), .some(let signoff)): state = digest(text) == signoff.sha256 ? .live : .pending
        case (nil, .some): state = .pending
        }
        let linted = text ?? draftText
        return AgentContractStatus(
            role: role, fileURL: file, draftURL: draft, state: state, hasDraft: draftText != nil,
            signoff: signoff,
            lint: linted.map { lint($0, role: role, directory: directory) } ?? [])
    }

    // MARK: - Injection

    /// The signed Essentials for `role`, capped, plus one path line for the other
    /// role's signed contract so orchestrators can brief and judge engineers.
    /// Nil when neither contract is signed off.
    public static func injection(role: AgentContractRole, directory: URL,
                                 process: DevelopmentProcess) -> AgentContractInjection? {
        var lines: [String] = []
        var characters = 0
        let path = directory.appendingPathComponent(role.fileName).path
        if let signoff = process.contracts[role.rawValue] {
            let essentials = absolutizingLinks(in: self.essentials(of: signoff.text), directory: directory)
            if !essentials.isEmpty {
                let current = (try? String(contentsOfFile: path, encoding: .utf8)).map(digest) == signoff.sha256
                let recommended = section(named: "recommended", in: signoff.text) != nil
                let source = current
                    ? (recommended ? "Essentials; Recommended practices in \(path)" : path)
                    : "signed version; \(path) has unsigned changes, follow this text"
                let body = capped(essentials, limit: injectionLimit(for: role), path: path)
                lines += ["\(role.title) contract (\(source)):", body]
                characters = body.count
            }
        }
        if process.contracts[role.other.rawValue] != nil {
            lines.append("\(role.other.title) contract: \(directory.appendingPathComponent(role.other.fileName).path)")
        }
        return lines.isEmpty ? nil : AgentContractInjection(role: role, lines: lines, inlinedCharacters: characters)
    }

    /// Whole rules up to `limit`, then a pointer to the file: a signed rule is never cut mid-sentence.
    static func capped(_ text: String, limit: Int, path: String) -> String {
        guard text.count > limit else { return text }
        var blocks: [String] = []
        for line in text.components(separatedBy: .newlines) {
            if isRule(line) || blocks.isEmpty { blocks.append(line) } else { blocks[blocks.count - 1] += "\n" + line }
        }
        var kept: [String] = []
        var length = 0
        for block in blocks {
            let added = (kept.isEmpty ? 0 : 1) + block.count
            if length + added > limit { break }
            kept.append(block); length += added
        }
        let body = kept.isEmpty ? String(text.prefix(limit)) : kept.joined(separator: "\n")
        return body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n… (truncated; read \(path) for the rest)"
    }

    /// The `## Essentials` section, or the whole body after the title when the
    /// file has no sections (an owner may write the rules alone).
    public static func essentials(of text: String) -> String {
        if let section = section(named: "essentials", in: text) { return section }
        var lines = text.components(separatedBy: .newlines)
        if let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           lines[first].hasPrefix("# ") {
            lines.removeSubrange(...first)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func section(named name: String, in text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { heading($0)?.hasPrefix(name) == true }) else { return nil }
        let end = lines[(start + 1)...].firstIndex(where: { $0.hasPrefix("# ") || $0.hasPrefix("## ") }) ?? lines.endIndex
        return lines[(start + 1)..<end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func heading(_ line: String) -> String? {
        guard line.hasPrefix("## ") else { return nil }
        return line.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Relative links name files beside the contract; inlined into a brief they
    /// would point nowhere, so they become absolute paths.
    static func absolutizingLinks(in text: String, directory: URL) -> String {
        let pattern = try! NSRegularExpression(pattern: #"\]\(([^)\s]+)\)"#)
        var result = text
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            let target = String(text[range])
            guard !target.hasPrefix("/"), !target.hasPrefix("#"), !target.contains("://"),
                  !target.hasPrefix("mailto:") else { continue }
            let resolved = directory.appendingPathComponent(target.removingPercentEncoding ?? target)
                .standardizedFileURL.path
            if let replace = Range(match.range(at: 1), in: result) { result.replaceSubrange(replace, with: resolved) }
        }
        return result
    }

    // MARK: - Lint

    /// Compiled once: the viewer lints the open contract on every render.
    private static let stateTerms: [(expression: NSRegularExpression, label: String)] = [
        (#"\bphase\s+(\d+\+?|n(\s*[-−]\s*1)?)(?![\w])"#, "names a phase", [.caseInsensitive]),
        (#"\b[A-Z][A-Z0-9]{1,6}-\d{1,5}\b"#, "names a task ID", []),
        (#"\b\d{4}-\d{2}-\d{2}\b"#, "names a date", []),
        (#"\b(January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{1,2}\b"#,
         "names a date", []),
        // A sentence may end right after the version, so only `.digit` continues it.
        (#"(?<![\w.])v?\d+\.\d+(\.\d+)*(?!\w|\.\d)"#, "names a version", []),
        (#"§\s*\d|\bsection\s+\d"#, "names a section number", [.caseInsensitive]),
        (#"\b(macOS|iOS|iPadOS|watchOS|visionOS|Windows|Linux|Android|Ubuntu)\b"#, "names a platform", []),
    ].map { (pattern: String, label: String, options: NSRegularExpression.Options) in
        (try! NSRegularExpression(pattern: pattern, options: options), label)
    }
    private static let emphasis = try! NSRegularExpression(
        pattern: #"\b(MUST|CRITICAL|IMPORTANT|NEVER|ALWAYS|SHALL|REQUIRED|WARNING)\b|!{2,}"#)
    private static let link = try! NSRegularExpression(pattern: #"\[[^\]]*\]\(([^)\s]+)\)"#)
    /// Backtick pairs, matched left to right so a link label's closing tick never opens a span.
    private static let codeSpan = try! NSRegularExpression(pattern: #"`([^`\n]+)`"#)

    /// Deterministic checks from the generator's self-check. Lint warns and never blocks.
    public static func lint(_ text: String, role: AgentContractRole, directory: URL) -> [AgentContractLintIssue] {
        var issues: [AgentContractLintIssue] = []
        let lines = text.components(separatedBy: .newlines)
        let headings = lines.enumerated().compactMap { index, line in heading(line).map { (index, $0) } }
        let names = headings.map(\.1)
        if !(names.count == 2 && names[0].hasPrefix("essentials") && names[1].hasPrefix("recommended")) {
            issues.append(AgentContractLintIssue(line: nil, message: names.isEmpty
                ? "No sections; expected Essentials, then Recommended."
                : "Sections are \(names.map { "“\($0)”" }.joined(separator: ", ")); expected Essentials, then Recommended."))
        }
        let essentials = section(named: "essentials", in: text) ?? (names.isEmpty ? self.essentials(of: text) : "")
        let essentialRules = rules(in: essentials)
        if essentialRules.count > role.essentialsRuleLimit {
            issues.append(AgentContractLintIssue(line: nil,
                message: "Essentials has \(essentialRules.count) rules; the limit is \(role.essentialsRuleLimit)."))
        }
        if essentials.count > role.essentialsCharacterLimit {
            issues.append(AgentContractLintIssue(line: nil,
                message: "Essentials is \(essentials.count) characters; the limit is \(role.essentialsCharacterLimit)."))
        }
        if let recommended = section(named: "recommended", in: text),
           rules(in: recommended).count > AgentContractRole.recommendedRuleLimit {
            issues.append(AgentContractLintIssue(line: nil,
                message: "Recommended has \(rules(in: recommended).count) rules; the limit is \(AgentContractRole.recommendedRuleLimit)."))
        }
        for (index, line) in lines.enumerated() where isRule(line) {
            let number = index + 1
            let plain = plainText(line)
            for sentence in sentences(in: plain) {
                let words = sentence.split(whereSeparator: \.isWhitespace).count
                if words > 25 {
                    issues.append(AgentContractLintIssue(line: number,
                        message: "A sentence has \(words) words; keep each at 25 or fewer."))
                }
            }
            let range = NSRange(plain.startIndex..., in: plain)
            for term in stateTerms {
                if let match = term.expression.firstMatch(in: plain, range: range), let found = Range(match.range, in: plain) {
                    issues.append(AgentContractLintIssue(line: number, message: "\(term.label) (“\(plain[found])”)."))
                }
            }
            let lineRange = NSRange(line.startIndex..., in: line)
            for match in codeSpan.matches(in: line, range: lineRange) {
                guard let found = Range(match.range(at: 1), in: line),
                      let whole = Range(match.range, in: line) else { continue }
                let span = String(line[found])
                // A link label and a file name in code style are references, not commands.
                let isLinkLabel = whole.lowerBound > line.startIndex
                    && line[line.index(before: whole.lowerBound)] == "["
                    && line[whole.upperBound...].hasPrefix("](")
                if isLinkLabel || span.range(of: #"\.[A-Za-z]{1,5}$"#, options: .regularExpression) != nil { continue }
                issues.append(AgentContractLintIssue(line: number, message: "names a command (“\(span)”)."))
            }
            if let match = emphasis.firstMatch(in: line, range: lineRange), let found = Range(match.range, in: line) {
                issues.append(AgentContractLintIssue(line: number, message: "uses emphasis (“\(line[found])”)."))
            }
        }
        for (index, line) in lines.enumerated() {
            for match in link.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                guard let found = Range(match.range(at: 1), in: line) else { continue }
                let target = String(line[found])
                guard !target.contains("://"), !target.hasPrefix("mailto:"), !target.hasPrefix("#") else { continue }
                let path = (target.components(separatedBy: "#").first ?? target).removingPercentEncoding ?? target
                let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path)
                if !FileManager.default.fileExists(atPath: url.path) {
                    issues.append(AgentContractLintIssue(line: index + 1, message: "link target does not exist: \(target)."))
                }
            }
        }
        return issues
    }

    static func isRule(_ line: String) -> Bool { line.hasPrefix("- ") || line.hasPrefix("* ") }

    static func rules(in section: String) -> [String] {
        section.components(separatedBy: .newlines).filter(isRule)
    }

    /// Markdown down to the words a reader sees: no bullets, emphasis, or link targets.
    static func plainText(_ line: String) -> String {
        var text = String(line.dropFirst(2))
        text = text.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        return text
    }

    static func sentences(in text: String) -> [String] {
        text.replacingOccurrences(of: #"(?<=[.!?])\s+(?=\S)"#, with: "\u{0}", options: .regularExpression)
            .components(separatedBy: "\u{0}")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Store

extension DevelopmentProcessStore {
    public func contractDirectory(projectID: String) throws -> URL {
        try url(projectID: projectID).deletingLastPathComponent()
    }

    public func contractStatus(role: AgentContractRole, projectID: String,
                               process: DevelopmentProcess?) throws -> AgentContractStatus {
        AgentContract.status(role: role, directory: try contractDirectory(projectID: projectID),
                             signoff: process?.contracts[role.rawValue])
    }

    /// The owner signs the exact text they read or saved; the file must still hold
    /// it, so an agent's concurrent write is never signed unseen. Signing also checks
    /// the document off in the Planning contract step.
    public func signContract(role: AgentContractRole, text: String, projectID: String,
                             now: Date = Date()) throws -> DevelopmentProcess {
        let file = try regularFile(role.fileName, projectID: projectID)
        guard let current = try? String(contentsOf: file, encoding: .utf8) else {
            throw AgentContractError.missingFile(role.fileName)
        }
        guard current == text else { throw AgentContractError.changedOnDisk(role.fileName) }
        return try mutate(projectID: projectID) { process in
            process.contracts[role.rawValue] = AgentContractSignoff(text: text, signedAt: now)
            try checkOffArtifact(role.fileName, in: &process, projectID: projectID)
        }
    }

    /// Replaces the live contract with the draft the owner read, signs it, and
    /// removes the draft. The live file changes only here.
    public func promoteContractDraft(role: AgentContractRole, text: String, projectID: String,
                                     now: Date = Date()) throws -> DevelopmentProcess {
        let draft = try regularFile(role.draftFileName, projectID: projectID)
        let file = try regularFile(role.fileName, projectID: projectID)
        guard let current = try? String(contentsOf: draft, encoding: .utf8) else {
            throw AgentContractError.missingDraft(role.draftFileName)
        }
        guard current == text else { throw AgentContractError.changedOnDisk(role.draftFileName) }
        let process = try mutate(projectID: projectID) { process in
            try Data(text.utf8).write(to: file, options: .atomic)
            process.contracts[role.rawValue] = AgentContractSignoff(text: text, signedAt: now)
            try checkOffArtifact(role.fileName, in: &process, projectID: projectID)
        }
        try? FileManager.default.removeItem(at: draft)
        return process
    }

    /// Stops injecting the contract until the owner signs it again.
    public func revokeContract(role: AgentContractRole, projectID: String) throws -> DevelopmentProcess {
        try mutate(projectID: projectID) { process in
            process.contracts.removeValue(forKey: role.rawValue)
            if var state = process.steps[Self.contractStepID] {
                state.checkedArtifacts.removeAll { $0 == role.fileName }
                process.steps[Self.contractStepID] = state
            }
        }
    }

    /// Stores a proposed contract as a draft beside the live file. Only the owner
    /// promotes it, so nothing an agent proposes reaches other agents unsigned.
    @discardableResult
    public func proposeContract(role: AgentContractRole, text: String, projectID: String) throws -> URL {
        let draft = try regularFile(role.draftFileName, projectID: projectID)
        try Data(text.utf8).write(to: draft, options: .atomic)
        return draft
    }

    public func discardContractDraft(role: AgentContractRole, projectID: String) throws {
        let draft = try regularFile(role.draftFileName, projectID: projectID)
        try? FileManager.default.removeItem(at: draft)
    }

    static let contractStepID = "contract"

    /// A path in the project folder that is not a symbolic link.
    func regularFile(_ name: String, projectID: String) throws -> URL {
        let directory = try contractDirectory(projectID: projectID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(name)
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw AgentContractError.redirected(name)
        }
        return url
    }
}

// MARK: - Generator

/// Drafts both contracts with the bundled prompt (`Config/contract-generator-prompt.md`)
/// as one read-only agent turn on the QChat provider, then writes drafts and a
/// review file with deterministic lint. Nothing it writes is injected unsigned.
public struct AgentContractGenerator: Sendable {
    public struct Inputs: Equatable, Sendable {
        public var project: String
        public var owner: String
        public var authorityDocs: [String]
        public var alreadyInjected: String
        public var enforced: String
        public var existing: String
    }

    public struct Output: Equatable, Sendable {
        public var engineering: String
        public var orchestrator: String
        public var reviewNotes: String
    }

    public struct Result: Equatable, Sendable {
        /// Files written for review, drafts first, then the review notes.
        public var files: [URL]
        public var reviewURL: URL
        public var lint: [AgentContractRole: [AgentContractLintIssue]]
        public var model: String
    }

    public let root: URL
    public let agent: any QueueAgentChatting

    public init(root: URL, agent: any QueueAgentChatting) {
        self.root = root; self.agent = agent
    }

    public static func prompt(_ inputs: Inputs) -> String {
        AgentContractGeneratorPrompt.template
            .replacingOccurrences(of: "{{PROJECT}}", with: inputs.project)
            .replacingOccurrences(of: "{{OWNER}}", with: inputs.owner)
            .replacingOccurrences(of: "{{AUTHORITY_DOCS}}",
                                  with: inputs.authorityDocs.isEmpty ? "(none found)" : "\n" + inputs.authorityDocs.map { "- \($0)" }.joined(separator: "\n") + "\n")
            .replacingOccurrences(of: "{{ALREADY_INJECTED}}", with: block(inputs.alreadyInjected))
            .replacingOccurrences(of: "{{ENFORCED}}", with: block(inputs.enforced))
            .replacingOccurrences(of: "{{EXISTING}}", with: block(inputs.existing))
    }

    private static func block(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "(empty)" : "\n<<<\n\(trimmed)\n>>>\n"
    }

    /// Splits the reply on its `=== … ===` markers. Code fences around a block are dropped.
    public static func parse(_ reply: String) throws -> Output {
        var blocks: [String: [String]] = [:]
        var current: String?
        for line in reply.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("==="), trimmed.hasSuffix("==="), trimmed.count > 6 {
                let name = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "= ")).lowercased()
                guard !name.isEmpty else { if let current { blocks[current, default: []].append(line) }; continue }
                current = name
                blocks[name] = []
                continue
            }
            if let current { blocks[current, default: []].append(line) }
        }
        func text(_ name: String) -> String {
            var lines = blocks[name] ?? []
            while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty
                    || first.trimmingCharacters(in: .whitespaces).hasPrefix("```") { lines.removeFirst() }
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty
                    || last.trimmingCharacters(in: .whitespaces).hasPrefix("```") { lines.removeLast() }
            return lines.joined(separator: "\n")
        }
        let engineering = text(AgentContractRole.engineering.fileName)
        let orchestrator = text(AgentContractRole.orchestrator.fileName)
        guard !engineering.isEmpty else { throw AgentContractError.malformedOutput("no agent-contract.md block") }
        guard !orchestrator.isEmpty else { throw AgentContractError.malformedOutput("no orchestration.md block") }
        return Output(engineering: engineering + "\n", orchestrator: orchestrator + "\n", reviewNotes: text("review notes"))
    }

    /// Fills the prompt inputs from what exists on disk; never reads code.
    public static func inputs(project: ProjectDefinition, root: URL, process: DevelopmentProcess?,
                              home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> Inputs {
        let store = DevelopmentProcessStore(root: root)
        let directory = try store.contractDirectory(projectID: project.id)
        let repository = project.repositoryPath.isEmpty ? nil : URL(fileURLWithPath: project.repositoryPath)
        let plan = directory.appendingPathComponent("plan.md")
        var sources = [plan]
        sources += DevelopmentPhase.allCases.flatMap { DevelopmentProcessCatalog.steps(in: $0) }
            .flatMap(\.artifacts)
            .filter { AgentContractRole(fileName: $0) == nil }
            .map { directory.appendingPathComponent($0) }
        sources = sources.filter { FileManager.default.fileExists(atPath: $0.path) }
        var docs: [String] = []
        // Repository documents the plan and step artifacts link to lead: the plan
        // names them as the design authority and decision register.
        for source in sources {
            for path in linkedDocuments(in: source, repository: repository) where !docs.contains(path) {
                docs.append(path)
            }
        }
        docs += sources.map(\.path).filter { !docs.contains($0) }
        let injected = [
            managedGlobalContract(home: home).map { "Global Focus Queue agent contract:\n\($0)" },
            TaskContext.sharedDataBlock(root: root, projectID: project.id, role: nil),
            process.map { "Development process brief (\($0.currentPhase.title)): " + DevelopmentProcessCatalog.brief(for: $0.currentPhase) },
        ].compactMap { $0 }.joined(separator: "\n\n")
        let existing = AgentContractRole.allCases.compactMap { role -> String? in
            guard let text = try? String(contentsOf: directory.appendingPathComponent(role.fileName), encoding: .utf8)
            else { return nil }
            return "=== \(role.fileName) (current, \(process?.contracts[role.rawValue] == nil ? "not signed off" : "signed off by \(owner(repository: repository))")) ===\n\(text)"
        }.joined(separator: "\n\n")
        return Inputs(project: project.name, owner: owner(repository: repository),
                      authorityDocs: Array(docs.prefix(12)), alreadyInjected: injected,
                      enforced: "", existing: existing)
    }

    /// The person who signs off: the repository's git author, else the account name.
    static func owner(repository: URL?) -> String {
        if let repository,
           let config = try? String(contentsOf: repository.appendingPathComponent(".git/config"), encoding: .utf8),
           let name = gitValue("name", section: "user", in: config) {
            return name.first.map { $0.uppercased() + name.dropFirst() } ?? name
        }
        if let global = try? String(contentsOf: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gitconfig"), encoding: .utf8),
           let name = gitValue("name", section: "user", in: global) {
            return name.first.map { $0.uppercased() + name.dropFirst() } ?? name
        }
        let full = NSFullUserName()
        return full.isEmpty ? "the owner" : full
    }

    private static func gitValue(_ key: String, section: String, in config: String) -> String? {
        var inSection = false
        for raw in config.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inSection = line.lowercased() == "[\(section)]"; continue }
            guard inSection, let equals = line.firstIndex(of: "=") else { continue }
            if line[..<equals].trimmingCharacters(in: .whitespaces).lowercased() == key {
                let value = line[line.index(after: equals)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t\""))
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    /// Markdown files a document links to, resolved beside it or from the repository root.
    static func linkedDocuments(in source: URL, repository: URL?) -> [String] {
        guard let text = try? String(contentsOf: source, encoding: .utf8) else { return [] }
        let pattern = try! NSRegularExpression(pattern: #"\]\(([^)\s#]+\.md)(#[^)]*)?\)"#)
        var found: [String] = []
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            let target = String(text[range]).removingPercentEncoding ?? String(text[range])
            guard !target.contains("://") else { continue }
            let candidates = target.hasPrefix("/")
                ? [URL(fileURLWithPath: target)]
                : [repository?.appendingPathComponent(target), source.deletingLastPathComponent().appendingPathComponent(target)].compactMap { $0 }
            if let hit = candidates.map(\.standardizedFileURL).first(where: { FileManager.default.fileExists(atPath: $0.path) }),
               !found.contains(hit.path) {
                found.append(hit.path)
            }
        }
        return found
    }

    /// The Focus Queue block every Claude or Codex agent already carries.
    static func managedGlobalContract(home: URL) -> String? {
        for file in [".claude/CLAUDE.md", ".codex/AGENTS.md"] {
            guard let text = try? String(contentsOf: home.appendingPathComponent(file), encoding: .utf8),
                  let start = text.range(of: "<!-- BEGIN ECC FOCUS QUEUE AGENT CONTRACT"),
                  let end = text.range(of: "<!-- END ECC FOCUS QUEUE AGENT CONTRACT", range: start.upperBound..<text.endIndex),
                  let open = text.range(of: "-->", range: start.upperBound..<end.lowerBound) else { continue }
            return text[open.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// Runs the generator and writes its drafts. A contract with no file yet is
    /// written in place (unsigned, so not injected); an existing one gets a
    /// `.draft.md` beside it, and the live file changes only on sign-off.
    public func generate(project: ProjectDefinition, configuration: AppConfiguration,
                         provider: AgentProvider, model: String?, effort: String?,
                         home: URL = FileManager.default.homeDirectoryForCurrentUser) async throws -> Result {
        let store = DevelopmentProcessStore(root: root)
        let process = try store.load(projectID: project.id)
        let directory = try store.contractDirectory(projectID: project.id)
        let inputs = try Self.inputs(project: project, root: root, process: process, home: home)
        var agentConfiguration = configuration.verifier
        agentConfiguration.executable = configuration.chatExecutable(for: provider)
        agentConfiguration.sessionName = "ecc-focus-queue-contracts-\(project.id)"
        agentConfiguration.timeoutSeconds = 600
        agentConfiguration.supportDirectory = root.path
        agentConfiguration.contextDirectory = directory.path
        agentConfiguration.projectScopeID = project.id
        agentConfiguration.writableDirectories = nil
        agentConfiguration.documentReader = true
        agentConfiguration.usageSource = "contract_generator"
        agentConfiguration.runtimeDirectory = root.appendingPathComponent("tracking/contract-generator").path
        let repository = project.repositoryPath.isEmpty ? directory.path : project.repositoryPath
        let workspace = FileManager.default.fileExists(atPath: repository) ? repository : directory.path
        let reply = try await agent.send(
            message: Self.prompt(inputs), dashboardPath: project.dashboardPath, workspace: workspace,
            visibleOrder: [], deferredTicketIDs: [], configuration: agentConfiguration,
            model: model, effort: effort)
        let output = try Self.parse(reply.message)
        var files: [URL] = []
        var lint: [AgentContractRole: [AgentContractLintIssue]] = [:]
        for role in AgentContractRole.allCases {
            let text = role == .engineering ? output.engineering : output.orchestrator
            let live = try store.regularFile(role.fileName, projectID: project.id)
            let target = FileManager.default.fileExists(atPath: live.path)
                ? try store.regularFile(role.draftFileName, projectID: project.id) : live
            try Data(text.utf8).write(to: target, options: .atomic)
            files.append(target)
            lint[role] = AgentContract.lint(text, role: role, directory: directory)
        }
        let modelLabel = "\(provider.rawValue)/\(model ?? "default")"
        let review = try store.regularFile(AgentContract.reviewFileName, projectID: project.id)
        try Data(Self.review(files: files, lint: lint, notes: output.reviewNotes, model: modelLabel).utf8)
            .write(to: review, options: .atomic)
        return Result(files: files, reviewURL: review, lint: lint, model: modelLabel)
    }

    static func review(files: [URL], lint: [AgentContractRole: [AgentContractLintIssue]],
                       notes: String, model: String, now: Date = Date()) -> String {
        var lines = ["# Agent contract review", "",
                     "Generated \(now.formatted(date: .abbreviated, time: .shortened)) by \(model). Lint warns and never blocks. Open each draft, edit it if needed, then sign it off in the document viewer; nothing reaches agents before that.",
                     "", "## Lint", ""]
        for (role, file) in zip(AgentContractRole.allCases, files) {
            lines.append("### [\(file.lastPathComponent)](\(file.lastPathComponent))")
            let issues = lint[role] ?? []
            lines += issues.isEmpty ? ["- No issues."] : issues.map { "- \($0.text)" }
            lines.append("")
        }
        lines += ["## Generator review notes", "", notes.isEmpty ? "None returned." : notes, ""]
        return lines.joined(separator: "\n")
    }
}
