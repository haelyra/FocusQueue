import Foundation

/// A prompt Focus Queue itself sends to a model, outside any project's signed
/// contracts: the queue agent, task placement, durable-fact extraction, the
/// development steward, the contract generator, and the planning guideline
/// generators. Like the built-in contracts, the app writes each one out in full
/// so people can read it in the document viewer; agents never read these copies.
public enum BuiltInAgentPrompt: String, CaseIterable, Identifiable, Sendable {
    case queueAgent, taskPlacement, dataExtraction, developmentSteward, contractGenerator
    case documentEditor, documentReader, documentFork, pushReview
    case dailyClassification, dailyAnalysis, claudeEditor, kimiProfiles, copilotInstructions, canvasRelay
    case conceptGuideline, researchGuideline, designGuideline, prdGuideline
    case technicalDesignGuideline, moduleGuideline, devplanGuideline

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .documentEditor: "Document editor prompt"
        case .documentReader: "Document reader prompt"
        case .documentFork: "Document creator fork prompt"
        case .pushReview: "Push review prompt"
        case .dailyClassification: "Daily report classification prompt"
        case .dailyAnalysis: "Customer concern analysis prompt"
        case .claudeEditor: "Claude document editor system prompt"
        case .kimiProfiles: "Kimi chat and document profiles"
        case .copilotInstructions: "Copilot editor and tool-free instructions"
        case .canvasRelay: "Canvas feedback prompt"
        case .queueAgent: "Queue agent prompt"
        case .taskPlacement: "Task placement prompt"
        case .dataExtraction: "Data extraction prompt"
        case .developmentSteward: "Development steward prompt"
        case .contractGenerator: "Contract generator prompt"
        case .conceptGuideline: "Concept generator prompt"
        case .researchGuideline: "Research generator prompt"
        case .designGuideline: "System design generator prompt"
        case .prdGuideline: "PRD generator prompt"
        case .technicalDesignGuideline: "Technical design generator prompt"
        case .moduleGuideline: "Module design generator prompt"
        case .devplanGuideline: "Development plan generator prompt"
        }
    }

    /// When this prompt runs, stated above the copy.
    public var delivery: String {
        switch self {
        case .documentEditor: "A tool-free model turn proposes edits to a document when you request changes. The app validates and applies the edits."
        case .documentReader: "A fresh reader answers questions about a selected document using supplied context and read-only searches."
        case .documentFork: "Document chat can fork the creator's saved conversation with these extra instructions."
        case .pushReview: "The review-push command requests a read-only review of a committed feature diff before remote delivery."
        case .dailyClassification: "Daily ingestion classifies collected sources into task proposals. Braced fields below are runtime placeholders, not saved source data."
        case .dailyAnalysis: "A deep daily-report pass analyzes customer concerns. Braced fields below are runtime placeholders."
        case .claudeEditor: "Claude's tool-free document editor receives this system prompt alongside the document editor instructions."
        case .kimiProfiles: "The Kimi harness selects a built-in profile for chat, read-only chat, document reading, editing, or tool-free requests."
        case .copilotInstructions: "The Copilot harness prepends these instructions to tool-free document edits and tool-free requests; Copilot has no system-prompt flag."
        case .canvasRelay: "Canvas feedback reaches its agent with these instructions. Runtime feedback, paths, and conversation fill the placeholders."
        case .queueAgent:
            "Every QChat and task-chat reply runs on this prompt, wrapped around the user's message; the identity line names the chat's provider."
        case .taskPlacement:
            "One small model call places each new agent and checks the + task creator's description: it joins a matching open task or creates a titled one."
        case .dataExtraction:
            "After each agent prompt, a background model call saves lasting preferences and deferred requirements to user, project, or task data. Settings \u{203A} Task placement \u{203A} Save durable facts from prompts turns it on."
        case .developmentSteward:
            "A background model pass keeps a project's development-process tracker current by linking new tasks and files to steps."
        case .contractGenerator:
            "The Project tab's Generate button drafts a project's engineering and orchestrator contracts with this prompt; nothing reaches agents before sign-off."
        case .conceptGuideline, .researchGuideline, .designGuideline, .prdGuideline,
             .technicalDesignGuideline, .moduleGuideline, .devplanGuideline:
            "The generator prompt inside the bundled planning guideline (experimental). The full guideline, with the format, self-check, and review checklist, opens from the step's chips in the Project tab."
        }
    }

    public var fileName: String {
        switch self {
        case .documentEditor: "document-editor-prompt.md"
        case .documentReader: "document-reader-prompt.md"
        case .documentFork: "document-fork-prompt.md"
        case .pushReview: "push-review-prompt.md"
        case .dailyClassification: "daily-classification-prompt.md"
        case .dailyAnalysis: "daily-analysis-prompt.md"
        case .claudeEditor: "claude-editor-prompt.md"
        case .kimiProfiles: "kimi-profiles.md"
        case .copilotInstructions: "copilot-instructions.md"
        case .canvasRelay: "canvas-feedback-prompt.md"
        case .queueAgent: "queue-agent-prompt.md"
        case .taskPlacement: "task-placement-prompt.md"
        case .dataExtraction: "data-extraction-prompt.md"
        case .developmentSteward: "development-steward-prompt.md"
        case .contractGenerator: "contract-generator-prompt.md"
        case .conceptGuideline: "concept-generator-prompt.md"
        case .researchGuideline: "research-generator-prompt.md"
        case .designGuideline: "design-generator-prompt.md"
        case .prdGuideline: "prd-generator-prompt.md"
        case .technicalDesignGuideline: "technical-design-generator-prompt.md"
        case .moduleGuideline: "module-generator-prompt.md"
        case .devplanGuideline: "devplan-generator-prompt.md"
        }
    }

    /// The guideline file this prompt comes from, for the guideline cases.
    private var guidelineName: String? {
        switch self {
        case .conceptGuideline: "concept-guideline.md"
        case .researchGuideline: "research-guideline.md"
        case .designGuideline: "design-guideline.md"
        case .prdGuideline: "prd-guideline.md"
        case .technicalDesignGuideline: "technical-design-guideline.md"
        case .moduleGuideline: "module-guideline.md"
        case .devplanGuideline: "devplan-guideline.md"
        default: nil
        }
    }

    /// The bundled Python script that holds this prompt, relative to the
    /// resources root: `shell/` in the installed app, `Scripts/` in a checkout.
    private var scriptName: String? {
        switch self {
        case .taskPlacement, .developmentSteward: "focus_queue_placement.py"
        case .dataExtraction: "focus_queue_extractor.py"
        case .dailyClassification, .dailyAnalysis: "focus_queue_morning.py"
        case .claudeEditor: "focus_queue_claude.py"
        case .kimiProfiles: "focus_queue_kimi.py"
        case .copilotInstructions: "focus_queue_copilot.py"
        default: nil
        }
    }

    /// The Python constants that make up this prompt, in order.
    private var scriptConstants: [String] {
        switch self {
        case .taskPlacement: ["SYSTEM_PROMPT", "INSTRUCTIONS"]
        case .dataExtraction: ["SYSTEM_PROMPT", "INSTRUCTIONS"]
        case .developmentSteward: ["DEVELOPMENT_SYSTEM_PROMPT"]
        case .claudeEditor: ["EDITOR_SYSTEM_PROMPT"]
        case .kimiProfiles: ["LEAN_CHAT_AGENT", "LEAN_CHAT_READ_ONLY_AGENT", "READER_AGENT", "EDITOR_AGENT", "TOOL_FREE_AGENT"]
        case .copilotInstructions: ["EDITOR_INSTRUCTION", "TOOL_FREE_INSTRUCTION"]
        default: []
        }
    }

    public static func directory(root: URL) -> URL {
        root.appendingPathComponent("contracts", isDirectory: true)
            .appendingPathComponent("built-in", isDirectory: true)
    }

    public func url(root: URL) -> URL { Self.directory(root: root).appendingPathComponent(fileName) }

    /// Build-owned copies, never project-authored contracts.
    public static func isReadOnlyCopy(_ url: URL, root: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL == directory(root: root).standardizedFileURL
            && (allCases.map(\.fileName) + BuiltInAgentContract.allCases.map(\.fileName)).contains(url.lastPathComponent)
    }


    /// The bundled script, in the installed app's `shell/` folder or a
    /// checkout's `Scripts/` folder (tests pass the repository root).
    func scriptURL(resources: URL?) -> URL? {
        guard let resources, let scriptName else { return nil }
        for folder in ["shell", "automation/Scripts", "Scripts"] {
            let url = resources.appendingPathComponent(folder, isDirectory: true)
                .appendingPathComponent(scriptName)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// True when this build can produce the text: always for the compiled-in
    /// prompts, and when the bundled script exists for the script-based ones.
    public func isAvailable(resources: URL?) -> Bool {
        text(resources: resources) != nil
    }

    /// The full prompt text, or nil when a development build has no bundled script.
    public func text(resources: URL?) -> String? {
        if let guidelineName {
            guard let prompt = DevelopmentGuidelines.prompt(guidelineName) else { return nil }
            return "# \(title)\n\n\(prompt)\n"
        }
        if scriptURL(resources: resources) != nil || scriptName != nil {
            guard let script = scriptURL(resources: resources),
                  let source = try? String(contentsOf: script, encoding: .utf8) else { return nil }
            if self == .dailyClassification || self == .dailyAnalysis {
                let function = self == .dailyClassification ? "proposal_prompt" : "deep_pass_prompt"
                guard let start = source.range(of: "def \(function)("),
                      let open = source.range(of: "return f\"\"\"", range: start.upperBound..<source.endIndex),
                      let close = source.range(of: "\"\"\"", range: open.upperBound..<source.endIndex) else { return nil }
                return "# \(title)\n\n" + source[open.upperBound..<close.lowerBound] + "\n"
            }
            let parts = scriptConstants.compactMap { Self.pythonStringConstant(named: $0, in: source) }
            guard parts.count == scriptConstants.count else { return nil }
            return "# \(title)\n\n" + (parts + (self == .developmentSteward ? [DevelopmentSteward.message(projectName: "(project name)", process: DevelopmentProcess(enabled: true), tickets: [], files: [])] : [])).joined(separator: "\n\n") + "\n"
        }
        switch self {
        case .documentEditor:
            return "# \(title)\n\n" + DocumentAgentPrompts.editorPreamble
                + "\n## Partial document rule\n" + DocumentAgentPrompts.excerptRule
                + "\n## Complete document rule\n" + DocumentAgentPrompts.completeRule
                + "\n## Full-document retry\n" + DocumentAgentPrompts.fullDocumentRetry
        case .documentReader: return "# \(title)\n\n" + DocumentAgentPrompts.readerPreamble
        case .documentFork: return "# \(title)\n\n" + DocumentAgentPrompts.forkPreamble
        case .pushReview:
            return "# \(title)\n\n" + PushReviewer.prompt(taskID: "<task>", assignment: "<assignment>", request: "<request>", planPath: "<plan path>", base: "<base commit>", head: "<reviewed commit>", workspacePath: "<workspace>")
        case .canvasRelay: return "# \(title)\n\n" + UICanvasRelayPrompt.displayText
        case .queueAgent: return "# \(title)\n\n\(QueueAgentPrompt.displayText)\n"
        case .contractGenerator: return "# \(title)\n\n\(AgentContractGeneratorPrompt.template)\n"
        default: return nil
        }
    }

    /// The readable copy: a note on when the prompt runs, then the text in full.
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
    public static func writeAll(root: URL, resources: URL?) -> [BuiltInAgentPrompt: URL] {
        var written: [BuiltInAgentPrompt: URL] = [:]
        for prompt in allCases {
            if let url = try? prompt.write(root: root, resources: resources) { written[prompt] = url }
        }
        return written
    }

    /// Reads a module-level string constant from Python source: `NAME = """..."""`,
    /// `NAME = "..."`, or an adjacent-literal concatenation `NAME = ("..." "...")`.
    public static func pythonStringConstant(named name: String, in source: String) -> String? {
        let lines = source.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: {
            $0.hasPrefix("\(name) = ") || $0.hasPrefix("\(name)= ")
        }) else { return nil }
        var rest = String(lines[start].drop(while: { $0 != "=" }).dropFirst())
            .trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("\"\"\"") {
            rest = String(rest.dropFirst(3))
            var body: [String] = []
            while true {
                if let close = rest.range(of: "\"\"\"") {
                    body.append(String(rest[..<close.lowerBound]))
                    return body.joined(separator: "\n")
                }
                body.append(rest)
                guard let next = lines[safe: start + body.count] else { return nil }
                rest = next
            }
        }
        if rest.hasPrefix("(") {
            var gathered = rest
            var index = start
            while !gathered.trimmingCharacters(in: .whitespaces).hasSuffix(")") {
                index += 1
                guard let next = lines[safe: index] else { return nil }
                gathered += "\n" + next
            }
            return pythonStringLiterals(in: gathered).joined()
        }
        if rest.hasPrefix("\"") {
            return pythonStringLiterals(in: rest).first
        }
        return nil
    }

    /// The double-quoted string literals in a Python fragment, unescaped.
    static func pythonStringLiterals(in text: String) -> [String] {
        let pattern = #""((?:[^"\\]|\\.)*)""#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
