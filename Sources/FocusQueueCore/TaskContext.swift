import Darwin
import Foundation
import CryptoKit

public enum TaskSubtaskStatus: String, Codable, CaseIterable, Sendable {
    case queued, working, idle, blocked, completed
}

public enum AgentRuntimeMode: String, Codable, CaseIterable, Sendable {
    case tmux, terminal
}

public enum TaskSessionBinding {
    public static func providerSession(environment: [String: String]) -> (AgentProvider, String)? {
        let codex = (environment["CODEX_THREAD_ID"] ?? environment["CODEX_SESSION_ID"]).flatMap { $0.isEmpty ? nil : $0 }
        // Claude Code exports CLAUDE_CODE_SESSION_ID; CLAUDE_SESSION_ID stays as an explicit override.
        let claude = (environment["CLAUDE_SESSION_ID"] ?? environment["CLAUDE_CODE_SESSION_ID"]).flatMap { $0.isEmpty ? nil : $0 }
        if let hint = environment["FOCUS_QUEUE_PROVIDER"].flatMap(AgentProvider.init(rawValue:)) {
            return (hint == .codex ? codex : claude).map { (hint, $0) }
        }
        // Nested agents can inherit both providers' identities. Pane discovery resolves ambiguity.
        if codex != nil && claude != nil { return nil }
        if let codex { return (.codex, codex) }
        if let claude { return (.claude, claude) }
        return nil
    }
    /// A pane can switch tasks while retaining the original launch environment.
    /// Never bind that old subtask to the newly attached task.
    public static func subtaskID(ticketID: String, environment: [String: String]) -> String? {
        if let launchedTask = environment["FOCUS_QUEUE_TASK_ID"],
           launchedTask.caseInsensitiveCompare(ticketID) != .orderedSame { return nil }
        return environment["FOCUS_QUEUE_SUBTASK_ID"].flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// A launch location is retained independently of the task's current workspace.
public struct AgentWorkspace: Codable, Equatable, Sendable {
    public var path: String
    public var repositoryPath: String
    public var branch: String?
    public var baseBranch: String?
    public var baseCommit: String?
    public var managed: Bool
    /// Captured independently of a branch name so reopening cannot follow a
    /// replaced checkout or a symlink into another agent's worktree.
    public var gitDirectory: String?
    public var repositoryIdentity: String?

    public init(path: String, repositoryPath: String, branch: String? = nil,
                baseBranch: String? = nil, baseCommit: String? = nil, managed: Bool = false,
                gitDirectory: String? = nil, repositoryIdentity: String? = nil) {
        self.path = path; self.repositoryPath = repositoryPath; self.branch = branch
        self.baseBranch = baseBranch; self.baseCommit = baseCommit; self.managed = managed
        self.gitDirectory = gitDirectory; self.repositoryIdentity = repositoryIdentity
    }
}

public struct AgentLaunchConfiguration: Codable, Equatable, Sendable {
    public var routeID: String?
    public var model: String?
    public var effort: String?
    public var providerVersion: String?
    /// Placement capsule identity for launches started inside the app. Agents
    /// started by the retired router keep `routeID`, which names their capsule.
    public var launchID: String?
    /// Installed plugins switched on or off for this agent only, by plugin ID.
    public var pluginOverrides: [String: Bool]?

    public init(routeID: String? = nil, model: String? = nil, effort: String? = nil,
                providerVersion: String? = nil, launchID: String? = nil,
                pluginOverrides: [String: Bool]? = nil) {
        self.routeID = routeID
        self.model = model
        self.effort = effort
        self.providerVersion = providerVersion
        self.launchID = launchID
        self.pluginOverrides = pluginOverrides
    }
}

public struct TaskSubtask: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var assignmentDescription: String
    public var provider: AgentProvider
    public var sessionID: String?
    public var status: TaskSubtaskStatus
    public var progressSummary: String
    public var lastHeartbeatAt: Date?
    public var lastOutputAt: Date?
    /// When the person last sent this agent a prompt.
    public var lastPromptAt: Date?
    public var completionUnread: Bool
    public var includeInitializationPrompt: Bool
    public var tmux: TmuxSessionReference?
    public var runtimeMode: AgentRuntimeMode?
    public var terminalPaneID: Int?
    public var terminalSocketPath: String?
    public var workspace: AgentWorkspace?
    public var workspaceHistory: [AgentWorkspace] = []
    public var initialPrompt: String?
    public var agentRemovedAt: Date?
    public var tracksCompletion: Bool = true
    public var completionOverrideAt: Date?
    // New work items are one record; legacy assignment/runtime pairs remain readable.
    public var isAssignmentOnly: Bool = false
    public var parentSubtaskID: String?
    public var associatedSubtaskIDs: [String] = []
    public var mergedIntoSubtaskID: String?
    public var attention: AgentAttention?
    public var resultID: String?
    public var resultSummary: String?
    public var resultAt: Date?
    public var observedEventID: String?
    public var observedEventAt: Date?
    /// The latest provider hook event applied to this agent's status.
    public var lastHookEventAt: Date?
    public var completionTerminalRetained: Bool?
    public var completedRuntimeOpenedAt: Date?
    public var launchConfiguration: AgentLaunchConfiguration?
    /// When the person interrupted this agent from Focus Queue. Cleared by
    /// Resume or by any later prompt, so a pause never outlives new work.
    public var pausedAt: Date?

    public var isPaused: Bool { pausedAt != nil && status != .completed }

    public var hasAgent: Bool {
        !isAssignmentOnly && (parentSubtaskID != nil || sessionID != nil || tmux != nil || terminalPaneID != nil || lastHeartbeatAt != nil || status == .completed)
    }

    public var hasManagedWorkspaces: Bool {
        !isAssignmentOnly && (workspace?.managed == true || workspaceHistory.contains(where: \.managed))
    }
    public var isAgentVisible: Bool { agentRemovedAt == nil && (status != .completed || completedRuntimeOpenedAt != nil) }
    /// Finished work stays a work item until the person has seen its result.
    public var isCompletionSeen: Bool { status == .completed && !completionUnread }
    public var workDescription: String {
        for value in [assignmentDescription, initialPrompt, progressSummary] {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return "Work item: \(title.trimmingCharacters(in: .whitespacesAndNewlines))."
    }
    public static func agentName(prompt: String, provider: AgentProvider) -> String {
        let firstLine = prompt.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""
        var phrase = firstLine.replacingOccurrences(
            of: #"^\s*(?:[-*+>#]+|\d+[.)]|\[[ xX]\])\s*"#,
            with: "", options: .regularExpression)
        let requestPrefixes = [
            "could you please ", "would you please ", "can you please ",
            "i would like you to ", "i'd like you to ", "i need you to ", "i want you to ",
            "your task is to ", "could you ", "would you ", "can you ", "we need to ",
            "help me ", "please ",
        ]
        for prefix in requestPrefixes {
            if let range = phrase.range(of: prefix, options: [.anchored, .caseInsensitive]) {
                phrase.removeSubrange(range)
                break
            }
        }
        if let boundary = phrase.indices.first(where: { index in
            guard ".!?;".contains(phrase[index]) else { return false }
            let next = phrase.index(after: index)
            return next == phrase.endIndex || phrase[next].isWhitespace
        }) {
            phrase = String(phrase[..<boundary])
        }
        let candidates = phrase.split(whereSeparator: \.isWhitespace).map(String.init)
        var words: [String] = []
        for word in candidates.prefix(6) {
            let proposed = (words + [word]).joined(separator: " ")
            guard proposed.count <= 56 else { break }
            words.append(word)
        }
        let trailingFillers: Set<String> = [
            "a", "an", "and", "because", "but", "for", "from", "in", "into", "of", "on", "or",
            "so", "that", "the", "then", "to", "with",
        ]
        while words.count > 1, let last = words.last,
              trailingFillers.contains(last.lowercased()) {
            words.removeLast()
        }
        if words.isEmpty, let first = candidates.first {
            let token = first.trimmingCharacters(in: .punctuationCharacters)
            if !token.isEmpty { words = [String(token.prefix(56))] }
        }
        guard !words.isEmpty else {
            return firstLine.isEmpty
                ? "Blank \(provider.displayName) agent"
                : "Untitled \(provider.displayName) task"
        }
        var title = words.joined(separator: " ").trimmingCharacters(in: .punctuationCharacters)
        guard !title.isEmpty else { return "Untitled \(provider.displayName) task" }
        let firstWord = title.prefix { !$0.isWhitespace }
        let lowercaseTechnicalTerms: Set<String> = ["git", "npm", "tmux"]
        if let first = title.first, first.isLowercase,
           !firstWord.dropFirst().contains(where: \.isUppercase),
           !lowercaseTechnicalTerms.contains(firstWord.lowercased()) {
            title.replaceSubrange(title.startIndex...title.startIndex, with: String(first).uppercased())
        }
        return title
    }

    public static func agentDescription(prompt: String) -> String {
        let normalized = prompt.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
            .replacingOccurrences(
                of: #"^\s*(?:[-*+>#]+|\d+[.)]|\[[ xX]\])\s*"#,
                with: "", options: .regularExpression)
        guard !normalized.isEmpty else { return "Awaiting the first work request." }
        var firstSentence = ""
        normalized.enumerateSubstrings(
            in: normalized.startIndex..<normalized.endIndex,
            options: [.bySentences, .substringNotRequired]
        ) { _, range, _, stop in
            firstSentence = String(normalized[range])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            stop = true
        }
        let sentence = firstSentence.isEmpty ? normalized : firstSentence
        guard sentence.count > 240 else { return sentence }
        let prefix = String(sentence.prefix(239))
        let boundary = prefix.lastIndex(where: \.isWhitespace) ?? prefix.endIndex
        return String(prefix[..<boundary]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    static func hasDefaultAgentName(_ title: String) -> Bool {
        title.range(of: #"^Agent [1-9][0-9]*$"#, options: .regularExpression) != nil
            || title.range(of: #"^(Codex|Claude) agent( [1-9][0-9]*)?$"#, options: .regularExpression) != nil
    }

    public init(id: String = UUID().uuidString, title: String,
                assignmentDescription: String = "", provider: AgentProvider = .codex,
                sessionID: String? = nil, status: TaskSubtaskStatus = .queued,
                progressSummary: String = "", lastHeartbeatAt: Date? = nil,
                lastOutputAt: Date? = nil,
                completionUnread: Bool = false, includeInitializationPrompt: Bool = true,
                tmux: TmuxSessionReference? = nil,
                runtimeMode: AgentRuntimeMode? = .tmux,
                terminalPaneID: Int? = nil, terminalSocketPath: String? = nil) {
        self.id = id; self.title = title; self.assignmentDescription = assignmentDescription
        self.provider = provider; self.sessionID = sessionID
        self.status = status; self.progressSummary = progressSummary
        self.lastHeartbeatAt = lastHeartbeatAt; self.lastOutputAt = lastOutputAt
        self.completionUnread = completionUnread
        self.includeInitializationPrompt = includeInitializationPrompt
        self.tmux = tmux
        self.runtimeMode = runtimeMode
        self.terminalPaneID = terminalPaneID
        self.terminalSocketPath = terminalSocketPath
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, assignmentDescription, provider, sessionID, status, progressSummary, lastHeartbeatAt, lastOutputAt, lastPromptAt, completionUnread, includeInitializationPrompt, tmux
        case runtimeMode, terminalPaneID, terminalSocketPath, workspace, workspaceHistory, initialPrompt, agentRemovedAt, tracksCompletion, completionOverrideAt
        case completionTerminalRetained
        case isAssignmentOnly, parentSubtaskID, associatedSubtaskIDs, mergedIntoSubtaskID, attention, resultID, resultSummary, resultAt, observedEventID, observedEventAt, completedRuntimeOpenedAt
        case lastHookEventAt, launchConfiguration, pausedAt
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? "Agent awaiting details"
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { title = "Agent awaiting details" }
        assignmentDescription = try values.decodeIfPresent(String.self, forKey: .assignmentDescription) ?? ""
        provider = (try values.decodeIfPresent(String.self, forKey: .provider))?.isEmpty == true
            ? .codex : try values.decodeIfPresent(AgentProvider.self, forKey: .provider) ?? .codex
        sessionID = try values.decodeIfPresent(String.self, forKey: .sessionID)
        status = (try values.decodeIfPresent(String.self, forKey: .status))?.isEmpty == true
            ? .queued : try values.decodeIfPresent(TaskSubtaskStatus.self, forKey: .status) ?? .queued
        progressSummary = try values.decodeIfPresent(String.self, forKey: .progressSummary) ?? ""
        lastHeartbeatAt = try values.decodeIfPresent(Date.self, forKey: .lastHeartbeatAt)
        lastOutputAt = try values.decodeIfPresent(Date.self, forKey: .lastOutputAt)
        lastPromptAt = try values.decodeIfPresent(Date.self, forKey: .lastPromptAt)
        completionUnread = try values.decodeIfPresent(Bool.self, forKey: .completionUnread) ?? false
        includeInitializationPrompt = try values.decodeIfPresent(Bool.self, forKey: .includeInitializationPrompt) ?? true
        tmux = try values.decodeIfPresent(TmuxSessionReference.self, forKey: .tmux)
        runtimeMode = try values.decodeIfPresent(AgentRuntimeMode.self, forKey: .runtimeMode)
        terminalPaneID = try values.decodeIfPresent(Int.self, forKey: .terminalPaneID)
        terminalSocketPath = try values.decodeIfPresent(String.self, forKey: .terminalSocketPath)
        workspace = try values.decodeIfPresent(AgentWorkspace.self, forKey: .workspace)
        workspaceHistory = try values.decodeIfPresent([AgentWorkspace].self, forKey: .workspaceHistory) ?? []
        initialPrompt = try values.decodeIfPresent(String.self, forKey: .initialPrompt)
        agentRemovedAt = try values.decodeIfPresent(Date.self, forKey: .agentRemovedAt)
        tracksCompletion = try values.decodeIfPresent(Bool.self, forKey: .tracksCompletion) ?? true
        completionOverrideAt = try values.decodeIfPresent(Date.self, forKey: .completionOverrideAt)
        isAssignmentOnly = try values.decodeIfPresent(Bool.self, forKey: .isAssignmentOnly) ?? false
        parentSubtaskID = try values.decodeIfPresent(String.self, forKey: .parentSubtaskID)
        associatedSubtaskIDs = try values.decodeIfPresent([String].self, forKey: .associatedSubtaskIDs) ?? []
        mergedIntoSubtaskID = try values.decodeIfPresent(String.self, forKey: .mergedIntoSubtaskID)
        attention = try values.decodeIfPresent(AgentAttention.self, forKey: .attention)
        resultID = try values.decodeIfPresent(String.self, forKey: .resultID)
        resultSummary = try values.decodeIfPresent(String.self, forKey: .resultSummary)
        resultAt = try values.decodeIfPresent(Date.self, forKey: .resultAt)
        observedEventID = try values.decodeIfPresent(String.self, forKey: .observedEventID)
        observedEventAt = try values.decodeIfPresent(Date.self, forKey: .observedEventAt)
        lastHookEventAt = try values.decodeIfPresent(Date.self, forKey: .lastHookEventAt)
        completionTerminalRetained = try values.decodeIfPresent(Bool.self, forKey: .completionTerminalRetained)
        completedRuntimeOpenedAt = try values.decodeIfPresent(Date.self, forKey: .completedRuntimeOpenedAt)
        launchConfiguration = try values.decodeIfPresent(AgentLaunchConfiguration.self, forKey: .launchConfiguration)
        pausedAt = try values.decodeIfPresent(Date.self, forKey: .pausedAt)
    }

    /// A live terminal is not proof of activity. Only a recent explicit heartbeat is.
    /// Without fresh transcript records, Working decays to idle after five minutes.
    public static let heartbeatLifetime: TimeInterval = 300
    /// A confirmed live pane keeps Working through long silent tool calls, such
    /// as builds, test runs, or foreground sub-agents, for up to an hour.
    public static let liveRuntimeHeartbeatLifetime: TimeInterval = 3_600
    /// A turn a provider hook reported as running ends only with a hook or
    /// transcript turn end, so a live pane keeps it Working through long tools.
    public static let hookedRuntimeHeartbeatLifetime: TimeInterval = 4 * 3_600

    /// The current status came from a provider hook. Transcript records of the
    /// same moment can land slightly later, so a two-minute overlap still counts.
    public var statusFromHook: Bool {
        guard let lastHookEventAt else { return false }
        return lastHookEventAt >= (lastHeartbeatAt ?? .distantPast).addingTimeInterval(-120)
    }

    /// How long Working survives without a heartbeat. A live pane earns an hour;
    /// a live pane whose turn a hook opened, or whose title shows a running
    /// turn, keeps it until the turn's end is reported.
    public func heartbeatLifetime(liveRuntime: Bool, runtimeShowsWork: Bool = false) -> TimeInterval {
        guard liveRuntime else { return Self.heartbeatLifetime }
        return statusFromHook || runtimeShowsWork ? Self.hookedRuntimeHeartbeatLifetime : Self.liveRuntimeHeartbeatLifetime
    }

    public func effectiveStatus(now: Date = Date(), heartbeatLifetime: TimeInterval = TaskSubtask.heartbeatLifetime) -> TaskSubtaskStatus {
        guard status == .working else { return status }
        guard let lastHeartbeatAt, now.timeIntervalSince(lastHeartbeatAt) <= heartbeatLifetime else { return .idle }
        return .working
    }

    /// A live pane clears an "ended" marker; only a known start changes the status.
    mutating func recordRuntimeStart(status newStatus: TaskSubtaskStatus?, summary: String) {
        guard status != .completed else { return }
        guard let newStatus else {
            if attention == .interrupted {
                attention = nil
                if status == .blocked { status = .idle }
            }
            return
        }
        status = newStatus
        attention = nil
        lastHeartbeatAt = Date()
        progressSummary = summary
    }
}

public struct TaskContext: Codable, Equatable, Sendable {
    public var projectID: String?
    public var projectName: String?
    public var projectRepositoryPath: String?
    public var projectPlanPath: String?
    public static let currentSchemaVersion = 2
    public var schemaVersion = TaskContext.currentSchemaVersion
    public var ticketID: String
    public var title: String
    public var summary: String
    public var successCriteria: String
    public var planPath: String
    public var worktreePath: String?
    public var repositoryPath: String?
    public var branch: String?
    public var baseBranch: String?
    public var managedWorktree = false
    public var subtasks: [TaskSubtask] = []
    public var lastPromptAt: Date? = nil
    /// Most recent explicit context-viewer or agent-open interaction.
    public var lastInteractionAt: Date? = nil
    public var latestInteractionAt: Date? {
        [lastPromptAt, lastInteractionAt].compactMap { $0 }.max()
    }
    public var pinnedAt: Date? = nil
    /// Context-folder outputs the user opened or dismissed, keyed by relative
    /// path, with the modification date seen. A later edit marks one new again.
    public var reviewedOutputs: [String: Date]? = nil
    public var removedAgentSessionKeys: [String]?
    public var updatedAt: Date

    public var contextDirectory: URL { URL(fileURLWithPath: planPath).deletingLastPathComponent() }

    public var agentLogURL: URL { contextDirectory.appendingPathComponent("agent-log.md") }

    /// Cached task facts and test data, kept beside the plan so every task view and agent can find it.
    public var dataURL: URL { contextDirectory.appendingPathComponent("data.md") }

    /// The prompt a task was created from when no agent started with it.
    public var initialPromptURL: URL { contextDirectory.appendingPathComponent(Self.initialPromptFileName) }

    static let initialPromptFileName = "initial-prompt.md"
    static let initialPromptDivider = "\n---\n\n"

    /// The saved prompt text, or nil when the task was never saved without an agent.
    public var savedInitialPrompt: String? {
        guard let markdown = try? String(contentsOf: initialPromptURL, encoding: .utf8),
              let divider = markdown.range(of: Self.initialPromptDivider) else { return nil }
        let prompt = markdown[divider.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return prompt.isEmpty ? nil : prompt
    }
    public var userDataURL: URL {
        contextDirectory.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("user/data.md")
    }
    public var projectDataURL: URL? {
        guard let projectPlanPath, !projectPlanPath.isEmpty else { return nil }
        return URL(fileURLWithPath: projectPlanPath).deletingLastPathComponent()
            .appendingPathComponent("data.md")
    }

    /// The task data file leads the evidence list even when the dashboard records no links.
    public func evidenceLinks(_ ticketLinks: [DashboardLink]) -> [DashboardLink] {
        let data = dataURL.standardizedFileURL
        let others = ticketLinks.filter { link in
            guard let url = ResourceLocator.url(for: link.url), url.isFileURL else { return true }
            return url.standardizedFileURL != data
        }
        return [DashboardLink(label: "Task data (data.md)", url: data.path, type: "plan")] + others
    }

    public static func launchRemovalKey(_ launchID: String) -> String {
        "launch:" + launchID.lowercased()
    }

    /// An app-launched agent's intake receipt is keyed by its placement launch
    /// ID, not its row ID, so both must be retired or the receipt recreates it.
    static func launchRemovalKeys(for agent: TaskSubtask) -> [String] {
        [agent.id, agent.launchConfiguration?.launchID].compactMap { $0 }.map(launchRemovalKey)
    }

    public func hasDismissedLaunch(_ launchID: String) -> Bool {
        (removedAgentSessionKeys ?? []).contains(Self.launchRemovalKey(launchID))
    }

    /// The placeholder recorded when a task has no measurable completion test. It carries no
    /// information, so plans and launch briefs omit it.
    public static let genericSuccessCriteria = "Confirm the requested behavior and record verification results."

    /// Success criteria worth repeating to an agent, or nil when only the generic placeholder exists.
    public var specificSuccessCriteria: String? {
        let criteria = successCriteria.trimmingCharacters(in: .whitespacesAndNewlines)
        return criteria.isEmpty || criteria == Self.genericSuccessCriteria ? nil : criteria
    }

    /// The generated data.md body before any agent records a fact; briefs point to it instead of inlining it.
    static let dataTemplateBody = "Cached facts, inputs, and test data for this task. Agents read this before acting and add durable task facts here."

    /// Data is a small memory layer, not a second plan or a progress report.
    static let dataWritingRule = "Write only durable task-specific user facts or deferred requirements to task data, in one or two short sentences each. Keep current work in the plan; research, test results, and evidence in the agent log."

    /// Compact mode: identity and document pointers only. Document contents stay on disk.
    public func agentBootstrap(subtask: TaskSubtask) -> String {
        let prompt = subtask.initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var lines = [prompt.isEmpty ? "Prepare the task context, then wait for my instruction before implementing anything." : prompt, ""]
        lines += briefHeader(subtask: subtask, prompt: prompt)
        lines += ["Task plan: \(planPath) (read before acting). Task data: \(dataURL.path). Agent log: \(agentLogURL.path).",
                  Self.dataWritingRule]
        lines += scopedDataLines()
        lines.append("Read relevant saved facts before acting.")
        lines.append(artifactInstruction)
        lines.append("Register with `focus-queue-session attach`, then report with `focus-queue-session progress|complete`. Rules: `focus-queue-session rules`.")
        return lines.joined(separator: "\n")
    }

    /// Detailed mode: the project description and task plan are inlined so the agent starts grounded
    /// without spending turns reading files. Procedure beyond the lifecycle verbs lives in `rules`.
    public func agentPrompt(subtask: TaskSubtask) -> String {
        let trimmed = subtask.initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = trimmed.map { $0.isEmpty ? "Prepare the task context, then wait for my instruction before implementing anything." : $0 } ?? subtask.title
        if subtask.status == .completed {
            return """
            Resume \(ticketID): \(title). Your subtask \(subtask.title) (\(subtask.id)) is already completed.
            Task plan: \(planPath)
            Review the completed handoff and await new user instructions. Keep the subtask completed; do not restart implementation or report working merely because the terminal was reopened.
            Register this pane with `focus-queue-session attach`.
            """
        }
        var lines = [prompt, ""] + briefHeader(subtask: subtask, prompt: trimmed ?? "")
        if let project = Self.inlineDocument(atPath: projectPlanPath, limit: 1_500) {
            lines.append("About the project: \(project)")
        }
        lines += scopedDataLines(includeTask: false)
        if let plan = Self.inlineDocument(atPath: planPath, limit: 4_000, prompt: trimmed ?? "") {
            lines += ["Task plan (\(planPath)):", plan]
        } else {
            lines.append("Task plan: \(planPath)")
        }
        if let data = Self.inlineDocument(atPath: dataURL.path, limit: 2_000),
           data != Self.dataTemplateBody {
            lines += ["Task data (\(dataURL.path)):", data]
        } else {
            lines.append("Task data: \(dataURL.path).")
        }
        lines += [Self.dataWritingRule, artifactInstruction]
        lines += [
            "Before anything else run `focus-queue-session attach`.",
            "Report with `focus-queue-session <verb>`; task and agent IDs come from the environment: progress working|idle|blocked \"summary\" · attention approval|question \"summary\" · result \"summary\" · complete \"what changed and how it was verified\".",
            "Before reporting result or complete, update the task plan: fill empty What/Why/How lines and tick or add Progress items. Log decisions and evidence with `focus-queue-session log \"entry\"`.",
            "More rules: `focus-queue-session rules`.",
        ]
        return lines.joined(separator: "\n")
    }

    /// Every provider gets this line: the task card shows new files from the
    /// context folder, so a file saved only in the worktree never reaches the user.
    private var artifactInstruction: String {
        "Save every file meant for the user under \(contextDirectory.path)/evidence, not the worktree Docs folder; the task card announces each new file there."
    }

    /// Character counts for the documents actually inlined by the detailed launch brief.
    public func inlinedAgentContextCharacters(subtask: TaskSubtask) -> [String: Int] {
        guard subtask.status != .completed else { return [:] }
        let userPrompt = subtask.initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var parts: [String: Int] = [:]
        if subtask.includeInitializationPrompt,
           let value = Self.inlineDocument(atPath: projectPlanPath, limit: 1_500) {
            parts["project_plan"] = value.count
        }
        if subtask.includeInitializationPrompt,
           let value = Self.inlineDocument(atPath: planPath, limit: 4_000, prompt: userPrompt) {
            parts["task_plan"] = value.count
        }
        if let value = Self.inlineDocument(atPath: dataURL.path, limit: 2_000),
           (!subtask.includeInitializationPrompt || value != Self.dataTemplateBody) {
            parts["task_data"] = value.count
        }
        if let value = Self.inlineDocument(atPath: userDataURL.path, limit: 2_000) {
            parts["user_data"] = value.count
        }
        if let projectDataURL,
           let value = Self.inlineDocument(atPath: projectDataURL.path, limit: 3_000) {
            parts["project_data"] = value.count
        }
        return parts
    }

    private func scopedDataLines(includeTask: Bool = true) -> [String] {
        var lines: [String] = []
        if let data = Self.inlineDocument(atPath: userDataURL.path, limit: 2_000) {
            lines += ["User data (\(userDataURL.path)):", data]
        }
        if let projectDataURL,
           let data = Self.inlineDocument(atPath: projectDataURL.path, limit: 3_000) {
            lines += ["Project data (\(projectDataURL.path)):", data]
        }
        if includeTask, let data = Self.inlineDocument(atPath: dataURL.path, limit: 2_000) {
            lines += ["Task data (\(dataURL.path)):", data]
        }
        return lines
    }

    /// Identity lines shared by both prompt modes. Assignment text is repeated only when it says
    /// something the user's prompt does not.
    private func briefHeader(subtask: TaskSubtask, prompt: String) -> [String] {
        var lines = ["[Focus Queue] \(ticketID): \(title) · Project: \(projectName ?? projectID ?? "Other")"]
        if subtask.title != title { lines.append("Subtask: \(subtask.title)") }
        lines.append("Agent \(subtask.id) (\(subtask.provider.rawValue)) · Workspace: \(subtask.workspace?.path ?? worktreePath ?? repositoryPath ?? "not configured") · Branch: \(subtask.workspace?.branch ?? branch ?? "not configured")")
        let assignment = subtask.assignmentDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !assignment.isEmpty, !Self.restates(assignment, prompt) {
            lines.append("Assignment details: \(assignment)")
        }
        if let criteria = specificSuccessCriteria { lines.append("Success criteria: \(criteria)") }
        return lines
    }

    /// Assignment text is often the prompt itself, or the prompt truncated to the 2,000-character field limit.
    static func restates(_ assignment: String, _ prompt: String) -> Bool {
        guard !prompt.isEmpty else { return false }
        return prompt == assignment || prompt.hasPrefix(assignment) || assignment.hasPrefix(prompt)
    }

    static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Markdown body without its title heading, without empty `- **Label:**` placeholders, and capped.
    /// A label whose value merely restates the user's prompt points back to it instead of repeating it.
    static func inlineDocument(atPath path: String?, limit: Int, prompt: String = "") -> String? {
        guard let path, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: .newlines)
        if let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           lines[first].hasPrefix("# ") {
            lines.removeSubrange(...first)
        }
        lines.removeAll { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("- **") && trimmed.hasSuffix(":**")
        }
        lines = lines.map { line in
            guard line.hasPrefix("- **"), let end = line.range(of: ":** ") else { return line }
            let value = line[end.upperBound...].trimmingCharacters(in: .whitespaces)
            let flatPrompt = singleLine(prompt)
            guard value.count >= 40, restates(value, flatPrompt) || flatPrompt.contains(value) else { return line }
            return String(line[..<end.upperBound]) + "see the request above."
        }
        var body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        while body.contains("\n\n\n") { body = body.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        guard !body.isEmpty else { return nil }
        guard body.count > limit else { return body }
        return String(body.prefix(limit)) + "\n… (truncated; read \(path) for the rest)"
    }

    /// On-demand procedure for managed agents. Printed by `focus-queue-session rules` so launch
    /// prompts stay short.
    public static func agentRules(mapHelper: String? = installedMapHelper()?.path) -> String {
        var rules = """
        Focus Queue agent rules. Commands are `focus-queue-session <verb>`; omit <TASK-ID> <AGENT-ID> to use $FOCUS_QUEUE_TASK_ID and $FOCUS_QUEUE_SUBTASK_ID.

        Lifecycle
        - attach: register this pane before any other work.
        - progress queued|working|idle|blocked "summary": at meaningful milestones, at least every 5 minutes while working. Use idle or blocked when waiting; report working when resuming.
        - attention approval|question|interrupted|incomplete|failed "summary": anything that needs the user.
        - result "summary": a finished response that leaves the assignment open.
        - complete "what changed and how it was verified": only after verification.
        - log "entry": decisions, configuration, research, and verification evidence, appended to the task's agent-log.md. Read only relevant entries; never paste the whole log into the plan.

        Task plan (tasks/<TASK-ID>/plan.md)
        - Keep it bare: What/Why/How (one sentence each), success criteria, a Progress checklist, and links to crucial context or evidence.
        - Tick Progress items as they finish and add the next ones. Re-read before editing and preserve other agents' concurrent edits.

        Task data (tasks/<TASK-ID>/data.md)
        - \(dataWritingRule)
        - Record only information owned by this task. A project-wide preference belongs in project context; a separate deferred deliverable belongs in its own task.

        Workspace and scope
        - Your assigned workspace is immutable; a different checkout requires a new agent assignment. `workspace <TASK-ID> <AGENT-ID> <absolute-path>` only records the first assignment or refreshes metadata for the same path.
        - Complete only your assigned subtask and preserve other agents' changes. Update the plan within the agreed scope without an extra approval loop; ask before materially changing scope, ownership, branch strategy, or external delivery.
        - Push only when the user authorizes remote delivery, never directly to main unless explicitly requested. Never force-remove a worktree or merge a branch without the task's approval terms. Task closure requires verification and safe cleanup.

        UI Canvas
        - To preview a UI mockup, use `canvas open|await|typing|end <file.html>` in place of `ecc-ui-canvas`: same arguments and JSON, and it opens as a tab in this task's plan viewer instead of a browser.
        """
        if let mapHelper {
            rules += """


            Map scope
            - '\(mapHelper)' scope <TASK-ID> <AGENT-ID> --input <context-file> --output <output-file>
            - Repeat --input/--output for multiple files; each call replaces your previous scope. Declare only your actual context and intended outputs; git changes alone do not establish ownership.
            """
        }
        return rules + "\n"
    }

    static func installedMapHelperCandidates(homeDirectory: URL) -> [URL] {
        [
            "Applications/Focus Queue.app/Contents/MacOS/focus-queue-map",
            "Applications/ECC Focus Queue.app/Contents/MacOS/focus-queue-map",
        ].map { homeDirectory.appendingPathComponent($0) }
    }

    public static func installedMapHelper(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        installedMapHelperCandidates(homeDirectory: homeDirectory).first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }
}

public enum TaskContextError: Error, LocalizedError {
    case invalidIdentifier, missingContext(String), missingSubtask(String), unsafeWorktree(String), commandFailed(String), planConflict
    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier: "Task IDs must contain only letters, digits, hyphens, or underscores."
        case .missingContext(let id): "No saved context exists for \(id)."
        case .missingSubtask(let id): "No subtask named \(id) exists in this task."
        case .planConflict: "The plan changed since you opened it. Reload it before saving to preserve the agent's latest edits."
        case .unsafeWorktree(let reason), .commandFailed(let reason): reason
        }
    }
}

/// Canonical context lives outside Git worktrees so cleanup cannot erase the handoff.
/// Atomic writes plus an advisory lock serialize app and CLI updates across processes.
public struct TaskContextRefreshSnapshot: Sendable {
    public let contexts: [String: TaskContext]
    public let errors: [String: String]
}

public actor TaskContextStore {
    public let root: URL
    private let files = FileManager.default
    private struct FileVersion: Equatable {
        let modifiedAt: Date?
        let size: UInt64
        let inode: UInt64
    }
    private struct RefreshCacheEntry {
        let ticket: DashboardTicket
        let version: FileVersion?
        let planVersion: FileVersion?
        let context: TaskContext?
        let readAt: Date
    }
    private var refreshCache: [String: RefreshCacheEntry] = [:]
    public init(root: URL) { self.root = root }

    /// Poll all task files on this actor and cross back to the UI once. A file's
    /// inode also detects atomic replacement that preserves its timestamp/size.
    /// Periodic full reads cover editors that overwrite while preserving metadata.
    public func refreshContexts(tickets: [DashboardTicket], projects: [ProjectDefinition] = []) -> TaskContextRefreshSnapshot {
        let now = Date()
        var contexts: [String: TaskContext] = [:]
        var errors: [String: String] = [:]
        let activeIDs = Set(tickets.map(\.id))
        refreshCache = refreshCache.filter { activeIDs.contains($0.key) }
        for ticket in tickets {
            do {
                let contextProject = ticket.projectID.flatMap { projectID in
                    projects.first { $0.id == projectID }
                } ?? (projects.count == 1 ? projects[0] : nil)
                let url = try directory(ticketID: ticket.id).appendingPathComponent("context.json")
                let version = try fileVersion(at: url)
                let planURL = refreshCache[ticket.id]?.context.map { URL(fileURLWithPath: $0.planPath) }
                    ?? url.deletingLastPathComponent().appendingPathComponent("plan.md")
                let planVersion = try fileVersion(at: planURL)
                if let cached = refreshCache[ticket.id], cached.ticket == ticket,
                   cached.version == version, cached.planVersion == planVersion,
                   cached.context?.projectName == contextProject?.name,
                   cached.context?.projectRepositoryPath == contextProject?.repositoryPath,
                   cached.context?.projectPlanPath == contextProject.flatMap(
                    { try? ProjectContextStore(root: root).planURL(projectID: $0.id).path }),
                   now.timeIntervalSince(cached.readAt) < 60 {
                    contexts[ticket.id] = cached.context
                    continue
                }
                let context: TaskContext?
                if ticket.isCompleted, version == nil { context = nil }
                else { context = try ensureContext(ticket: ticket, project: contextProject) }
                // An agent may edit an open task's Markdown or JSON directly.
                // Completed-task cleanup intentionally stages this archive, so
                // background refreshes must not recreate it afterward.
                if context != nil, ticket.isOpen { try archive(ticketID: ticket.id) }
                let finalVersion = try fileVersion(at: url)
                let finalPlanURL = context.map { URL(fileURLWithPath: $0.planPath) } ?? planURL
                let finalPlanVersion = try fileVersion(at: finalPlanURL)
                // Never associate a pre-write document with a post-write file
                // version. Initial creation or concurrent writes get another
                // full read on the next poll before becoming cacheable.
                if version == finalVersion, planURL == finalPlanURL, planVersion == finalPlanVersion {
                    refreshCache[ticket.id] = RefreshCacheEntry(ticket: ticket,
                        version: finalVersion, planVersion: finalPlanVersion, context: context, readAt: now)
                } else { refreshCache[ticket.id] = nil }
                contexts[ticket.id] = context
            } catch {
                refreshCache[ticket.id] = nil
                errors[ticket.id] = error.localizedDescription
            }
        }
        return TaskContextRefreshSnapshot(contexts: contexts, errors: errors)
    }

    private func fileVersion(at url: URL) throws -> FileVersion? {
        do {
            let attributes = try files.attributesOfItem(atPath: url.path)
            return FileVersion(modifiedAt: attributes[.modificationDate] as? Date,
                size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
                inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }

    public func directory(ticketID: String) throws -> URL {
        guard !ticketID.isEmpty, ticketID.unicodeScalars.allSatisfy({
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0)
        }) else { throw TaskContextError.invalidIdentifier }
        return root.appendingPathComponent("tasks", isDirectory: true).appendingPathComponent(ticketID.uppercased(), isDirectory: true)
    }

    public func load(ticketID: String) throws -> TaskContext? {
        let url = try directory(ticketID: ticketID).appendingPathComponent("context.json")
        guard files.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard var value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TaskContextError.commandFailed("Task context must be a JSON object. The original file was preserved.")
        }
        let defaults: [String: Any] = ["ticketID": ticketID.uppercased(), "title": ticketID.uppercased(),
            "summary": "", "successCriteria": "", "planPath": url.deletingLastPathComponent().appendingPathComponent("plan.md").path,
            "managedWorktree": false, "subtasks": [], "updatedAt": 0, "schemaVersion": 2]
        for (key, fallback) in defaults where value[key] == nil || value[key] is NSNull
            || (["ticketID", "title", "planPath"].contains(key) && (value[key] as? String)?.isEmpty == true) {
            value[key] = fallback
        }
        if var rows = value["subtasks"] as? [[String: Any]] {
            for index in rows.indices where rows[index]["id"] == nil || rows[index]["id"] is NSNull || rows[index]["id"] as? String == "" {
                rows[index]["id"] = "unidentified-\(ticketID.uppercased())-\(index)"
            }
            value["subtasks"] = rows
        }
        return try JSONDecoder().decode(TaskContext.self, from: JSONSerialization.data(withJSONObject: value))
    }

    /// Discovery tolerates an unrelated damaged task. Destructive operations keep
    /// using strict loadAll(), so missing ownership evidence can never allow cleanup.
    public func loadAvailableForDiscovery() throws -> [TaskContext] {
        let tasks = root.appendingPathComponent("tasks")
        guard files.fileExists(atPath: tasks.path) else { return [] }
        return try files.contentsOfDirectory(at: tasks, includingPropertiesForKeys: [.isSymbolicLinkKey])
            .filter { (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true }
            .compactMap { try? load(ticketID: $0.lastPathComponent) }
    }

    public func loadAll() throws -> [TaskContext] {
        let tasks = root.appendingPathComponent("tasks", isDirectory: true)
        guard files.fileExists(atPath: tasks.path) else { return [] }
        return try files.contentsOfDirectory(
            at: tasks, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { entry in
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { return nil }
            let expected = try directory(ticketID: entry.lastPathComponent).standardizedFileURL
            guard expected == entry.standardizedFileURL else { return nil }
            return try load(ticketID: entry.lastPathComponent)
        }
    }

    public func clearAllSubtasks() throws -> [TaskContext] {
        let contexts = try loadAll()
        return try contexts.map { context in
            context.subtasks.isEmpty ? context : try clearSubtasks(ticketID: context.ticketID)
        }
    }

    public func isWorktreeAssigned(_ path: String, excluding ticketID: String) throws -> Bool {
        let directory = root.appendingPathComponent("tasks", isDirectory: true)
        guard files.fileExists(atPath: directory.path) else { return false }
        let candidate = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        for task in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            guard task.lastPathComponent != ticketID.uppercased(), files.fileExists(atPath: task.appendingPathComponent("context.json").path) else { continue }
            let other = try JSONDecoder().decode(TaskContext.self, from: Data(contentsOf: task.appendingPathComponent("context.json")))
            let paths = [other.worktreePath].compactMap { $0 } + other.subtasks.compactMap { $0.workspace?.path }
            if paths.contains(where: { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL == candidate }) { return true }
        }
        return false
    }

    @discardableResult public func ensureContext(ticket: DashboardTicket, worktreePath: String? = nil, project: ProjectDefinition? = nil) throws -> TaskContext {
        try locked(ticketID: ticket.id) {
            if var existing = try load(ticketID: ticket.id) {
                let previous = existing
                existing.separateLegacyAgentAssignments()
                existing.title = ticket.title
                // Callers that only know the task must not erase placement that
                // was established by the owning project dashboard.
                let effectiveProjectID = project?.id ?? ticket.projectID ?? existing.projectID
                if existing.projectID != effectiveProjectID {
                    existing.projectID = effectiveProjectID
                    existing.projectName = nil
                    existing.projectRepositoryPath = nil
                    existing.projectPlanPath = nil
                }
                if let project {
                    existing.projectName = project.name
                    existing.projectRepositoryPath = project.repositoryPath
                    existing.projectPlanPath = try ProjectContextStore(root: root).ensurePlan(for: project).path
                }
                existing.summary = ticket.summary
                existing.successCriteria = ticket.doneWhen ?? existing.successCriteria
                if !ticket.isOpen { existing.pinnedAt = nil }
                // A retained branch with no workspace records completed cleanup. Dashboard
                // metadata may still mention the former workspace until its next refresh.
                if existing.worktreePath == nil, existing.branch == nil { existing.worktreePath = worktreePath ?? ticket.worktree }
                try ensureDocuments(
                    context: existing,
                    ticket: ticket,
                    previousTitle: previous.title
                )
                if previous != existing { existing.updatedAt = Date(); try write(existing); try snapshot(existing) }
                else if ticket.isOpen,
                        !files.fileExists(atPath: existing.contextDirectory.appendingPathComponent("archive").path) {
                    try snapshot(existing)
                }
                return existing
            }
            let directory = try directory(ticketID: ticket.id)
            let planURL = directory.appendingPathComponent("plan.md")
            let projectPlanPath = try project.map { try ProjectContextStore(root: root).ensurePlan(for: $0).path }
            let context = TaskContext(projectID: project?.id ?? ticket.projectID, projectName: project?.name,
                                      projectRepositoryPath: project?.repositoryPath,
                                      projectPlanPath: projectPlanPath,
                                      ticketID: ticket.id.uppercased(), title: ticket.title,
                                      summary: ticket.summary, successCriteria: ticket.doneWhen ?? TaskContext.genericSuccessCriteria,
                                      planPath: planURL.path, worktreePath: worktreePath ?? ticket.worktree, updatedAt: Date())
            try ensureDocuments(context: context, ticket: ticket)
            try write(context)
            try snapshot(context)
            return context
        }
    }

    /// Launch inference only names task directories that already exist. This
    /// narrow recovery path fills in a missing context without creating a new
    /// task from untrusted receipt text.
    @discardableResult public func ensureTrackedLaunchContext(
        ticketID: String, title: String, summary: String = "Tracked external agent launch."
    ) throws -> TaskContext? {
        let directory = try directory(ticketID: ticketID)
        var isDirectory: ObjCBool = false
        guard files.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              (try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
        else { return nil }
        if let existing = try load(ticketID: ticketID) { return existing }
        return try ensureContext(ticket: DashboardTicket(
            id: ticketID.uppercased(),
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? ticketID.uppercased() : String(title.prefix(200)),
            status: "open", summary: String(summary.prefix(2_000))))
    }

    /// Called under the task lock. Authored bodies remain intact; only an exact generated heading is synchronized.
    private func ensureDocuments(
        context: TaskContext,
        ticket: DashboardTicket,
        previousTitle: String? = nil
    ) throws {
        let planURL = URL(fileURLWithPath: context.planPath)
        if !files.fileExists(atPath: planURL.path) || (try? files.attributesOfItem(atPath: planURL.path)[.size] as? NSNumber)?.intValue == 0 {
            let links = ticket.links.map { "- [\($0.label)](\($0.url))" }.joined(separator: "\n")
            let steps = ticket.steps.map { "- [\($0.isDone ? "x" : " ")] \($0.label)" }.joined(separator: "\n")
            let next = ticket.next?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let progress = !steps.isEmpty ? steps : "- [ ] \(next.isEmpty ? "Confirm scope and choose the first step." : next)"
            // Bare-bones grounding for every agent on the task. Empty Why/How lines are
            // filled by agents as they learn them and are omitted from launch briefs.
            let markdown = """
            # \(ticket.id): \(ticket.title)

            - **What:**\(ticket.summary.isEmpty ? "" : " " + TaskContext.singleLine(ticket.summary))
            - **Why:**
            - **How:**

            ## Success criteria

            \(context.specificSuccessCriteria.map { "- \($0)" } ?? "- Not recorded yet.")

            ## Progress

            \(progress)

            ## Context

            - [Agent log](agent-log.md): decisions, research, and verification evidence.
            - [Task data](data.md): durable task facts and test data.
            \(links)

            """
            try Data(markdown.utf8).write(to: planURL, options: .atomic)
        } else if let previousTitle, previousTitle != ticket.title,
                  (try? planURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true {
            let data = try Data(contentsOf: planURL)
            if var markdown = String(data: data, encoding: .utf8) {
                let oldHeading = "# \(ticket.id): \(previousTitle)"
                if markdown == oldHeading || markdown.hasPrefix(oldHeading + "\n") {
                    markdown.replaceSubrange(
                        markdown.startIndex..<markdown.index(markdown.startIndex, offsetBy: oldHeading.count),
                        with: "# \(ticket.id): \(ticket.title)"
                    )
                    try Data(markdown.utf8).write(to: planURL, options: .atomic)
                }
            }
        }
        try ensureAgentLog(context)
        try ensureDataFile(context)
    }

    private func ensureDataFile(_ context: TaskContext) throws {
        guard (try? context.dataURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw TaskContextError.commandFailed("The task data file must be a regular task-owned file, not a symbolic link.")
        }
        // Starts empty so only recorded facts appear. A file still holding the
        // earlier generated header is cleared; authored text is kept.
        let legacyHeader = "# \(context.ticketID) task data\n\n\(TaskContext.dataTemplateBody)\n"
        if !files.fileExists(atPath: context.dataURL.path)
            || (try? String(contentsOf: context.dataURL, encoding: .utf8)) == legacyHeader {
            try Data().write(to: context.dataURL, options: .atomic)
        }
    }

    private func ensureAgentLog(_ context: TaskContext) throws {
        guard (try? context.agentLogURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw TaskContextError.commandFailed("The agent log must be a regular task-owned file, not a symbolic link.")
        }
        if !files.fileExists(atPath: context.agentLogURL.path) {
            try Data("# \(context.ticketID) agent log\n\nAppend-only decisions, configuration, progress, and evidence. Keep the central plan brief; read this log selectively.\n".utf8)
                .write(to: context.agentLogURL, options: .atomic)
        }
    }

    /// Serializes app and CLI writers across processes without re-saving the plan.
    public func appendAgentLog(ticketID: String, subtaskID: String, entry: String, now: Date = Date()) throws {
        try locked(ticketID: ticketID) {
            guard let context = try load(ticketID: ticketID) else { throw TaskContextError.missingContext(ticketID) }
            guard let agent = context.subtasks.first(where: { $0.id == subtaskID }), !agent.isAssignmentOnly else {
                throw TaskContextError.missingSubtask(subtaskID)
            }
            let body = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { throw TaskContextError.commandFailed("Agent log entry cannot be empty.") }
            try ensureAgentLog(context)
            let heading = "\n## \(ISO8601DateFormatter().string(from: now)) | \(agent.provider.rawValue) | \(agent.id)\n\n"
            let descriptor = Darwin.open(context.agentLogURL.path, O_WRONLY | O_APPEND | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else { throw TaskContextError.commandFailed("Could not open the task-owned agent log for append.") }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
                throw TaskContextError.commandFailed("The agent log must be a regular task-owned file.")
            }
            try handle.write(contentsOf: Data((heading + body + "\n").utf8))
            try handle.synchronize()
        }
    }

    public func readPlan(ticketID: String) throws -> String {
        guard let context = try load(ticketID: ticketID) else { throw TaskContextError.missingContext(ticketID) }
        return try String(contentsOfFile: context.planPath, encoding: .utf8)
    }

    public func savePlan(ticketID: String, markdown: String, expectedMarkdown: String? = nil) throws {
        try locked(ticketID: ticketID) {
            guard let context = try load(ticketID: ticketID) else { throw TaskContextError.missingContext(ticketID) }
            if let expectedMarkdown, try readPlan(ticketID: ticketID) != expectedMarkdown { throw TaskContextError.planConflict }
            try snapshot(context)
            try Data(markdown.utf8).write(to: URL(fileURLWithPath: context.planPath), options: .atomic)
            try snapshot(context)
        }
    }

    @discardableResult public func upsertSubtask(ticketID: String, subtask: TaskSubtask) throws -> TaskContext {
        return try mutate(ticketID: ticketID) { context in
            if let index = context.subtasks.firstIndex(where: { $0.id == subtask.id }) { context.subtasks[index] = subtask }
            else { context.subtasks.append(subtask) }
        }
    }

    /// Registers a provider-supplied identity while holding the task's cross-process lock.
    /// Repeated hook events cannot create duplicate records or revive completed work.
    @discardableResult public func registerExternalSession(
        ticketID: String, provider: AgentProvider, sessionID: String, title: String,
        description: String = "", cwd: String,
        preferredSubtaskID: String?, allowFreshAssociation: Bool,
        tmux: TmuxSessionReference?, paneID: Int?, socketPath: String?, eventName: String
    ) throws -> TaskContext {
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let workDescription = String((description.isEmpty ? title : description).prefix(2_000))
        let now = Date()
        return try mutate(ticketID: ticketID) { context in
            let sameSession: (TaskSubtask) -> Bool = {
                $0.provider == provider && $0.sessionID?.lowercased() == sessionID.lowercased()
            }
            var index = context.subtasks.firstIndex {
                sameSession($0) && $0.agentRemovedAt == nil && $0.status != .completed
            }
            let dismissedLaunch = preferredSubtaskID.map(context.hasDismissedLaunch) ?? false
            if index == nil, let preferredSubtaskID {
                index = context.subtasks.firstIndex {
                    $0.id == preferredSubtaskID && $0.provider == provider && !$0.isAssignmentOnly
                        && $0.agentRemovedAt == nil && $0.status != .completed
                        && ($0.sessionID == nil || sameSession($0))
                        && ($0.workspace.map { ExternalAgentRegistry.contains(directory: $0.path, path: cwd) } ?? false)
                }
            }
            if index == nil {
                let key = provider.rawValue + ":" + sessionID.lowercased()
                guard !dismissedLaunch,
                    allowFreshAssociation || (!context.subtasks.contains(where: sameSession)
                    && !(context.removedAgentSessionKeys ?? []).contains(key)) else { return }
                var agent = TaskSubtask(title: title, assignmentDescription: workDescription,
                    provider: provider, sessionID: sessionID,
                    status: .idle, includeInitializationPrompt: false, runtimeMode: nil)
                agent.tracksCompletion = false
                agent.workspace = AgentWorkspace(path: cwd, repositoryPath: context.repositoryPath ?? cwd)
                context.subtasks.append(agent)
                index = context.subtasks.count - 1
            }
            guard let index else { return }
            context.subtasks[index].sessionID = sessionID.lowercased()
            let hasProvisionalIdentity = TaskSubtask.hasDefaultAgentName(context.subtasks[index].title)
                || context.subtasks[index].title.hasPrefix(provider.displayName + " ·")
                || context.subtasks[index].title.hasPrefix("Subagent ·")
            let adoptsFirstPrompt = eventName == "UserPromptSubmit" && hasProvisionalIdentity
            if adoptsFirstPrompt
                || context.subtasks[index].title.hasPrefix(provider.displayName + " ·")
                || context.subtasks[index].title.hasPrefix("Subagent ·") {
                context.subtasks[index].title = title
            }
            if adoptsFirstPrompt {
                context.subtasks[index].assignmentDescription = workDescription
            } else if context.subtasks[index].assignmentDescription
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                context.subtasks[index].assignmentDescription = workDescription
            }
            if let tmux { context.subtasks[index].tmux = tmux; context.subtasks[index].runtimeMode = .tmux }
            else if let paneID {
                context.subtasks[index].terminalPaneID = paneID
                context.subtasks[index].terminalSocketPath = socketPath
                context.subtasks[index].runtimeMode = .terminal
            }
            // A stopped response is not completed work. Completion remains explicit.
            if ["UserPromptSubmit", "SubagentStart"].contains(eventName) { context.subtasks[index].status = .working }
            else if ["Stop", "SubagentStop", "SessionEnd"].contains(eventName) { context.subtasks[index].status = .idle }
            if eventName == "UserPromptSubmit" {
                context.lastPromptAt = max(context.lastPromptAt ?? .distantPast, now)
                context.subtasks[index].lastPromptAt = max(context.subtasks[index].lastPromptAt ?? .distantPast, now)
            }
            if eventName != "ProcessDiscovery" || context.subtasks[index].lastHeartbeatAt == nil {
                context.subtasks[index].lastHeartbeatAt = now
            }
            if ["Stop", "SubagentStop"].contains(eventName) {
                context.subtasks[index].lastOutputAt = max(
                    context.subtasks[index].lastOutputAt ?? .distantPast, now)
            }
        }
    }

    @discardableResult public func renameSubtask(
        ticketID: String, subtaskID: String, title: String,
        assignmentDescription: String? = nil
    ) throws -> TaskContext {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw TaskContextError.commandFailed("Give the subtask a readable name.") }
        return try mutate(ticketID: ticketID) { context in
            guard let index = context.subtasks.firstIndex(where: { $0.id == subtaskID }) else { throw TaskContextError.missingSubtask(subtaskID) }
            context.subtasks[index].title = String(title.prefix(200))
            if let assignmentDescription {
                let description = assignmentDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !description.isEmpty else {
                    throw TaskContextError.commandFailed("Add a brief description of this work item.")
                }
                context.subtasks[index].assignmentDescription = String(description.prefix(2_000))
            }
        }
    }

    /// `status` is what the new process is doing: `.working` when it was sent
    /// a prompt, `.idle` when it waits for input (every resume). `nil` records a
    /// re-found or retained pane without changing what the agent is doing.
    @discardableResult public func setManagedRuntime(ticketID: String, subtaskID: String,
                                                      tmux: TmuxSessionReference,
                                                      status: TaskSubtaskStatus? = nil) throws -> TaskContext {
        try mutate(ticketID: ticketID, archiveChanges: true) { context in
            guard let index = context.subtasks.firstIndex(where: { $0.id == subtaskID }) else {
                throw TaskContextError.missingSubtask(subtaskID)
            }
            context.subtasks[index].tmux = tmux
            context.subtasks[index].runtimeMode = .tmux
            context.subtasks[index].terminalPaneID = nil
            context.subtasks[index].terminalSocketPath = nil
            context.subtasks[index].recordRuntimeStart(status: status, summary: status == .idle
                ? "Managed session is open in tmux and waiting for input."
                : "Managed session started and remains available through tmux.")
        }
    }

    @discardableResult public func setDirectRuntime(
        ticketID: String, subtaskID: String, paneID: Int, socketPath: String?,
        status: TaskSubtaskStatus? = nil
    ) throws -> TaskContext {
        guard paneID >= 0 else { throw TaskContextError.commandFailed("Terminal returned an invalid pane identity.") }
        return try mutate(ticketID: ticketID, archiveChanges: true) { context in
            guard let index = context.subtasks.firstIndex(where: { $0.id == subtaskID }) else {
                throw TaskContextError.missingSubtask(subtaskID)
            }
            context.subtasks[index].tmux = nil
            context.subtasks[index].runtimeMode = .terminal
            context.subtasks[index].terminalPaneID = paneID
            context.subtasks[index].terminalSocketPath = socketPath
            context.subtasks[index].recordRuntimeStart(status: status, summary: status == .idle
                ? "Direct terminal session is open and waiting for input."
                : "Direct terminal session started. Closing its terminal ends the live process.")
        }
    }

    @discardableResult public func clearSubtasks(ticketID: String) throws -> TaskContext {
        try mutate(
            ticketID: ticketID, archiveChanges: true, archiveBeforeChanges: true
        ) { context in
            let keys = context.subtasks.flatMap { subtask in
                [subtask.sessionID.map { subtask.provider.rawValue + ":" + $0.lowercased() }].compactMap { $0 }
                    + (subtask.hasAgent ? TaskContext.launchRemovalKeys(for: subtask) : [])
            }
            context.removedAgentSessionKeys = Array(Set((context.removedAgentSessionKeys ?? []) + keys)).sorted()
            context.subtasks.removeAll()
        }
    }

    @discardableResult public func removeSubtask(
        ticketID: String, subtaskID: String
    ) throws -> TaskContext {
        try mutate(
            ticketID: ticketID, archiveChanges: true, archiveBeforeChanges: true
        ) { context in
            guard let removed = context.subtasks.first(where: { $0.id == subtaskID }) else {
                throw TaskContextError.missingSubtask(subtaskID)
            }
            let targetID = context.canonicalSubtaskID(subtaskID)
            let linkedAgentIDs = Set(context.subtasks.compactMap { agent -> String? in
                guard agent.hasAgent, context.assignmentIDs(for: agent).contains(targetID) else {
                    return nil
                }
                let otherAssignments = context.assignmentIDs(for: agent).subtracting([targetID])
                return otherAssignments.isEmpty ? agent.id : nil
            })
            let removedSessionKeys = context.subtasks.filter { candidate in
                candidate.id == removed.id || linkedAgentIDs.contains(candidate.id)
            }.flatMap { agent in
                [agent.sessionID.map { agent.provider.rawValue + ":" + $0.lowercased() }].compactMap { $0 }
                    + (agent.hasAgent ? TaskContext.launchRemovalKeys(for: agent) : [])
            }
            context.removedAgentSessionKeys = Array(Set((context.removedAgentSessionKeys ?? []) + removedSessionKeys)).sorted()
            context.subtasks.removeAll { candidate in
                candidate.id == removed.id || linkedAgentIDs.contains(candidate.id)
            }
            let remainingAssignmentIDs = Set(context.subtasks.filter {
                $0.parentSubtaskID == nil && $0.mergedIntoSubtaskID == nil
            }.map(\.id))
            for index in context.subtasks.indices where context.subtasks[index].hasAgent {
                context.subtasks[index].associatedSubtaskIDs.removeAll { $0 == targetID }
                if context.subtasks[index].parentSubtaskID == targetID {
                    let replacement = context.subtasks[index].associatedSubtaskIDs.first {
                        remainingAssignmentIDs.contains($0)
                    }
                    context.subtasks[index].parentSubtaskID = replacement
                    if let replacement {
                        context.subtasks[index].associatedSubtaskIDs.removeAll { $0 == replacement }
                    }
                }
            }
        }
    }

    @discardableResult public func updateProgress(ticketID: String, subtaskID: String, status: TaskSubtaskStatus,
                                                  summary: String, sessionID: String? = nil, now: Date = Date()) throws -> TaskContext {
        try mutate(ticketID: ticketID, archiveChanges: true) { context in
            guard let index = context.subtasks.firstIndex(where: { $0.id == subtaskID }) else { throw TaskContextError.missingSubtask(subtaskID) }
            // A late worker/verifier report cannot undo an explicit user override.
            guard context.subtasks[index].completionOverrideAt == nil else { return }
            context.subtasks[index].status = status
            context.subtasks[index].completedRuntimeOpenedAt = nil
            context.subtasks[index].progressSummary = String(summary.prefix(2_000))
            context.subtasks[index].lastHeartbeatAt = now
            if let sessionID { context.subtasks[index].sessionID = sessionID }
            context.subtasks[index].attention = status == .blocked ? .failed : nil
            if status == .completed || status == .working { context.subtasks[index].pausedAt = nil }
            if status == .completed {
                context.subtasks[index].completionUnread = !context.subtasks[index].isAssignmentOnly
                context.subtasks[index].resultID = UUID().uuidString
                context.subtasks[index].resultSummary = String(summary.prefix(2_000))
                context.subtasks[index].resultAt = context.subtasks[index].lastHeartbeatAt
                context.subtasks[index].lastOutputAt = max(
                    context.subtasks[index].lastOutputAt ?? .distantPast, now)
                if context.subtasks[index].isAssignmentOnly {
                    let target = context.canonicalSubtaskID(subtaskID)
                    for i in context.subtasks.indices where context.subtasks[i].hasAgent && context.assignmentIDs(for: context.subtasks[i]).contains(target) {
                        context.subtasks[i].status = .completed
                        context.subtasks[i].attention = nil
                        context.subtasks[i].lastHeartbeatAt = now
                        context.subtasks[i].progressSummary = String(summary.prefix(2_000))
                        context.subtasks[i].completionUnread = true
                        context.subtasks[i].resultID = UUID().uuidString
                        context.subtasks[i].resultSummary = String(summary.prefix(2_000))
                        context.subtasks[i].resultAt = now
                        context.subtasks[i].lastOutputAt = max(
                            context.subtasks[i].lastOutputAt ?? .distantPast, now)
                    }
                }
            }
        }
    }

    /// Saves the prompt a task was created from when no agent starts with it,
    /// and links it from the plan so the first agent launched later finds it.
    /// An existing prompt file is evidence and is never overwritten.
    @discardableResult public func saveInitialPrompt(
        _ prompt: String, ticket: DashboardTicket, project: ProjectDefinition? = nil, at savedAt: Date = Date()
    ) throws -> URL {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw TaskContextError.commandFailed("The initial prompt is empty.") }
        let context = try ensureContext(ticket: ticket, project: project)
        return try locked(ticketID: ticket.id) {
            let url = context.initialPromptURL
            guard !files.fileExists(atPath: url.path) else { return url }
            let markdown = """
            # \(context.ticketID): initial prompt

            Saved \(ISO8601DateFormatter().string(from: savedAt)) when the task was created without starting an agent. Start the first agent with this prompt.
            \(TaskContext.initialPromptDivider)\(prompt)

            """
            try Data(markdown.utf8).write(to: url, options: .atomic)
            let planURL = URL(fileURLWithPath: context.planPath)
            if (try? planURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
               var plan = try? String(contentsOf: planURL, encoding: .utf8),
               !plan.contains("(\(TaskContext.initialPromptFileName))") {
                let link = "- [Initial prompt](\(TaskContext.initialPromptFileName)): the user's prompt; no agent has started with it yet.\n"
                // Join the generated Context list; an authored plan gets the link at its end.
                if let data = plan.range(of: "- [Task data](data.md)"),
                   let lineEnd = plan[data.upperBound...].firstIndex(of: "\n") {
                    plan.insert(contentsOf: link, at: plan.index(after: lineEnd))
                } else {
                    while plan.hasSuffix("\n") { plan.removeLast() }
                    plan += "\n" + link
                }
                try Data(plan.utf8).write(to: planURL, options: .atomic)
            }
            return url
        }
    }

    @discardableResult public func recordInteraction(
        ticketID: String, at date: Date = Date()
    ) throws -> TaskContext {
        try locked(ticketID: ticketID) {
            guard var context = try load(ticketID: ticketID) else { throw TaskContextError.missingContext(ticketID) }
            guard date > (context.lastInteractionAt ?? .distantPast) else { return context }
            let url = context.contextDirectory.appendingPathComponent("context.json")
            guard var document = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            context.lastInteractionAt = date
            context.updatedAt = Date()
            // This narrow presentation update preserves future fields and agent records verbatim.
            document["lastInteractionAt"] = date.timeIntervalSinceReferenceDate
            document["updatedAt"] = context.updatedAt.timeIntervalSinceReferenceDate
            try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                .write(to: url, options: .atomic)
            return context
        }
    }

    @discardableResult public func recordPrompt(
        ticketID: String, subtaskID: String? = nil, at promptAt: Date = Date()
    ) throws -> TaskContext {
        try mutate(ticketID: ticketID) { context in
            context.lastPromptAt = max(context.lastPromptAt ?? .distantPast, promptAt)
            if let index = context.subtasks.firstIndex(where: { $0.id == subtaskID }) {
                context.subtasks[index].lastPromptAt = max(context.subtasks[index].lastPromptAt ?? .distantPast, promptAt)
            }
        }
    }

    /// Archiving an agent never deletes its assignment, conversation identity, or workspace.
    @discardableResult public func archiveAgent(ticketID: String, subtaskID: String, automatically: Bool = false) throws -> TaskContext {
        try mutate(ticketID: ticketID, archiveChanges: true) { context in
            guard let index = context.subtasks.firstIndex(where: { $0.id == subtaskID }) else { throw TaskContextError.missingSubtask(subtaskID) }
            let session = context.subtasks[index].sessionID
            let provider = context.subtasks[index].provider
            context.removedAgentSessionKeys = Array(Set((context.removedAgentSessionKeys ?? [])
                + TaskContext.launchRemovalKeys(for: context.subtasks[index]))).sorted()
            for i in context.subtasks.indices where i == index || (session != nil && context.subtasks[i].provider == provider && context.subtasks[i].sessionID?.lowercased() == session?.lowercased()) {
                context.subtasks[i].completionTerminalRetained = automatically && context.subtasks[i].status == .completed
                context.subtasks[i].agentRemovedAt = Date()
                if !automatically { context.subtasks[i].completionUnread = false }
            }
        }
    }

    /// Compatibility spelling for callers that predate the archived-agent UI.
    @discardableResult public func removeAgent(ticketID: String, subtaskID: String, automatically: Bool = false) throws -> TaskContext {
        try archiveAgent(ticketID: ticketID, subtaskID: subtaskID, automatically: automatically)
    }

    /// Terminal launch receipts can arrive after a provisional row was shown.
    /// Hide that row and retain its launch identity so later polling cannot
    /// recreate it under either a provisional or provider session identity.
    @discardableResult public func dismissTrackedLaunch(
        ticketID: String, launchID: String
    ) throws -> TaskContext {
        try mutate(ticketID: ticketID, archiveChanges: true) { context in
            let key = TaskContext.launchRemovalKey(launchID)
            context.removedAgentSessionKeys = Array(Set((context.removedAgentSessionKeys ?? []) + [key])).sorted()
            if let index = context.subtasks.firstIndex(where: { $0.id == launchID }) {
                if context.subtasks[index].agentRemovedAt == nil {
                    context.subtasks[index].agentRemovedAt = Date()
                }
                context.subtasks[index].completionUnread = false
            }
        }
    }

    /// A launch-keyed provisional row is resolved once the launch's placement
    /// names a real agent row in the same task: the placeholder is retired
    /// into that row (even after the row completed), and the launch identity
    /// cannot recreate it. The merge alias keeps launch-keyed lookups working.
    @discardableResult public func mergeTrackedLaunch(
        ticketID: String, launchID: String, into subtaskID: String
    ) throws -> TaskContext {
        try mutate(ticketID: ticketID, archiveChanges: true) { context in
            guard let target = context.subtasks.first(where: {
                $0.id.caseInsensitiveCompare(subtaskID) == .orderedSame
            }), let index = context.subtasks.firstIndex(where: { $0.id == launchID }),
                context.subtasks[index].agentRemovedAt == nil else { return }
            let key = TaskContext.launchRemovalKey(launchID)
            context.removedAgentSessionKeys = Array(Set((context.removedAgentSessionKeys ?? []) + [key])).sorted()
            context.subtasks[index].mergedIntoSubtaskID = target.id
            context.subtasks[index].agentRemovedAt = Date()
            context.subtasks[index].completionUnread = false
        }
    }

    @discardableResult public func restoreAgent(ticketID: String, subtaskID: String) throws -> TaskContext {
        try mutate(ticketID: ticketID, archiveChanges: true) { context in
            guard let index = context.subtasks.firstIndex(where: { $0.id == subtaskID }) else { throw TaskContextError.missingSubtask(subtaskID) }
            context.subtasks[index].agentRemovedAt = nil
            if context.subtasks[index].status == .completed { context.subtasks[index].completedRuntimeOpenedAt = Date() }
        }
    }

    @discardableResult public func overrideCompletion(ticketID: String, subtaskID: String) throws -> TaskContext {
        try mutate(ticketID: ticketID, archiveChanges: true) { context in
            guard let index = context.subtasks.firstIndex(where: { $0.id == subtaskID }) else { throw TaskContextError.missingSubtask(subtaskID) }
            context.subtasks[index].status = .completed
            context.subtasks[index].completionOverrideAt = Date()
            context.subtasks[index].completionUnread = !context.subtasks[index].isAssignmentOnly
            context.subtasks[index].lastHeartbeatAt = Date()
            context.subtasks[index].progressSummary = "Marked complete by the user."
            let target = context.canonicalSubtaskID(subtaskID)
            for i in context.subtasks.indices where context.subtasks[i].parentSubtaskID != nil && context.assignmentIDs(for: context.subtasks[i]).contains(target) {
                context.subtasks[i].status = .completed
                context.subtasks[i].completionOverrideAt = Date()
                context.subtasks[i].attention = nil
            }
        }
    }

    @discardableResult public func setAgentWorkspace(ticketID: String, subtaskID: String, workspace: AgentWorkspace) throws -> TaskContext {
        try mutate(ticketID: ticketID, archiveChanges: true) { context in
            guard let index = context.subtasks.firstIndex(where: { $0.id == subtaskID }) else { throw TaskContextError.missingSubtask(subtaskID) }
            let previousWorkspace = context.subtasks[index].workspace
            if let previousWorkspace, previousWorkspace.path != workspace.path {
                throw TaskContextError.unsafeWorktree(
                    "Agent workspace assignments are immutable. Create a new agent assignment instead of moving \(subtaskID) from \(previousWorkspace.path) to \(workspace.path).")
            }
            let parentIDs = context.assignmentIDs(for: context.subtasks[index])
            for i in context.subtasks.indices where i != index && parentIDs.contains(context.subtasks[i].id)
                && (context.subtasks[i].workspace == nil || context.subtasks[i].workspace == previousWorkspace) {
                context.subtasks[i].workspace = workspace
            }
            context.subtasks[index].workspace = workspace
        }
    }

    @discardableResult public func detachSession(ticketID: String, provider: AgentProvider, sessionID: String) throws -> TaskContext {
        try mutate(ticketID: ticketID) { context in
            for index in context.subtasks.indices where context.subtasks[index].provider == provider
                && context.subtasks[index].sessionID?.caseInsensitiveCompare(sessionID) == .orderedSame {
                context.subtasks[index].agentRemovedAt = Date()
            }
        }
    }

    @discardableResult public func acknowledgeCompletion(ticketID: String, subtaskID: String, expectedResultID: String? = nil, expectedHeartbeat: Date? = nil) throws -> TaskContext {
        try mutate(ticketID: ticketID) { context in
            guard let index = context.subtasks.firstIndex(where: { $0.id == subtaskID }) else { throw TaskContextError.missingSubtask(subtaskID) }
            if let expectedResultID, context.subtasks[index].resultID != expectedResultID { return }
            if let expectedHeartbeat, context.subtasks[index].lastHeartbeatAt != expectedHeartbeat { return }
            context.subtasks[index].completionUnread = false
        }
    }

    @discardableResult public func reportAttention(ticketID: String, subtaskID: String,
        attention: AgentAttention?, summary: String, result: Bool = false, expectedHeartbeat: Date? = nil
    ) throws -> TaskContext {
        let now = Date()
        return try mutate(ticketID: ticketID, archiveChanges: true) { context in
            guard let index = context.subtasks.firstIndex(where: { $0.id == subtaskID }) else { throw TaskContextError.missingSubtask(subtaskID) }
            guard context.subtasks[index].status != .completed, context.subtasks[index].agentRemovedAt == nil else { return }
            if let expectedHeartbeat, context.subtasks[index].lastHeartbeatAt != expectedHeartbeat { return }
            context.subtasks[index].attention = attention
            context.subtasks[index].status = attention?.isProblem == true ? .blocked : .idle
            context.subtasks[index].progressSummary = String(summary.prefix(2_000))
            context.subtasks[index].lastHeartbeatAt = now
            if result {
                context.subtasks[index].completionUnread = true
                context.subtasks[index].resultID = UUID().uuidString
                context.subtasks[index].resultSummary = String(summary.prefix(2_000))
                context.subtasks[index].resultAt = context.subtasks[index].lastHeartbeatAt
                context.subtasks[index].lastOutputAt = max(
                    context.subtasks[index].lastOutputAt ?? .distantPast, now)
            }
        }
    }

    /// The approval dialog closed while its pane stayed live, so the person
    /// answered it. Claude sends no hook for an approval, so the approved step
    /// reads as Working until the next hook. The heartbeat stays put: a denial
    /// ends the turn with a later transcript marker, which must still apply.
    @discardableResult public func resolveApproval(ticketID: String, subtaskID: String) throws -> TaskContext {
        try mutate(ticketID: ticketID) { context in
            guard let index = context.subtasks.firstIndex(where: { $0.id == subtaskID }) else { throw TaskContextError.missingSubtask(subtaskID) }
            guard context.subtasks[index].status != .completed, context.subtasks[index].agentRemovedAt == nil,
                  context.subtasks[index].attention == .approval else { return }
            context.subtasks[index].attention = nil
            context.subtasks[index].status = .working
            context.subtasks[index].progressSummary = "Running the approved step."
        }
    }

    /// Records a pause or resume the person requested from Focus Queue. A
    /// pause reads as idle and dates the heartbeat, so hook events from the
    /// interrupted turn cannot mark the agent Working again. A resume that
    /// sent no prompt only clears the pause.
    @discardableResult public func setPaused(
        ticketID: String, subtaskID: String, paused: Bool, promptSent: Bool = true, at date: Date = Date()
    ) throws -> TaskContext {
        try mutate(ticketID: ticketID) { context in
            guard let index = context.subtasks.firstIndex(where: { $0.id == subtaskID }) else { throw TaskContextError.missingSubtask(subtaskID) }
            guard context.subtasks[index].status != .completed else { return }
            if paused {
                context.subtasks[index].pausedAt = date
                context.subtasks[index].status = .idle
                context.subtasks[index].attention = nil
                context.subtasks[index].lastHeartbeatAt = max(context.subtasks[index].lastHeartbeatAt ?? .distantPast, date)
            } else if !promptSent {
                context.subtasks[index].pausedAt = nil
            } else {
                context.subtasks[index].pausedAt = nil
                context.subtasks[index].status = .working
                context.subtasks[index].attention = nil
                context.subtasks[index].lastHeartbeatAt = max(context.subtasks[index].lastHeartbeatAt ?? .distantPast, date)
                context.subtasks[index].lastPromptAt = max(context.subtasks[index].lastPromptAt ?? .distantPast, date)
                context.lastPromptAt = max(context.lastPromptAt ?? .distantPast, date)
            }
        }
    }

    @discardableResult public func observeActivity(ticketID: String, subtaskID: String, event: AgentActivityEvent) throws -> TaskContext {
        try mutate(ticketID: ticketID) { context in
            guard let i = context.subtasks.firstIndex(where: { $0.id == subtaskID }) else { throw TaskContextError.missingSubtask(subtaskID) }
            // Hooks are optional, so transcript prompts also date the task's last
            // interaction, even when the agent's own status is already final.
            if case .prompt = event.kind, event.date > (context.lastPromptAt ?? .distantPast) {
                context.lastPromptAt = event.date
            }
            if case .prompt = event.kind, event.date > (context.subtasks[i].lastPromptAt ?? .distantPast) {
                context.subtasks[i].lastPromptAt = event.date
            }
            // Typing into a paused pane resumes it as surely as the Resume button.
            if case .prompt = event.kind, let pausedAt = context.subtasks[i].pausedAt, event.date > pausedAt {
                context.subtasks[i].pausedAt = nil
            }
            guard context.subtasks[i].observedEventID != event.id else { return }
            if context.subtasks[i].status == .completed {
                // A person's new prompt re-tasks a finished agent, including one
                // auto-archived with its terminal kept open. It outranks a user
                // completion override because it is the user's later action.
                // The agent's own output after `complete` never reopens it.
                let agent = context.subtasks[i]
                guard case .prompt = event.kind,
                      agent.agentRemovedAt == nil || agent.completionTerminalRetained == true,
                      event.date > (agent.lastHeartbeatAt ?? .distantPast) else { return }
                context.subtasks[i].status = .working
                context.subtasks[i].agentRemovedAt = nil
                context.subtasks[i].completionTerminalRetained = nil
                context.subtasks[i].completedRuntimeOpenedAt = nil
                context.subtasks[i].completionOverrideAt = nil
                context.subtasks[i].completionUnread = false
                context.subtasks[i].attention = nil
                context.subtasks[i].lastHeartbeatAt = event.date
                context.subtasks[i].observedEventID = event.id
                context.subtasks[i].observedEventAt = event.date
                if event.source == .hook { context.subtasks[i].lastHookEventAt = event.date }
                context.subtasks[i].progressSummary = "Working on a new prompt after completing."
                return
            }
            guard context.subtasks[i].isAgentVisible else { return }
            let isNewestObservedEvent = event.date >= (context.subtasks[i].observedEventAt ?? .distantPast)
            let isCurrentActivity = event.date >= (context.subtasks[i].lastHeartbeatAt ?? .distantPast)
            let isNewResult: Bool
            if case .result = event.kind {
                isNewResult = context.subtasks[i].resultID != event.id
                    && event.date >= (context.subtasks[i].resultAt ?? .distantPast)
            } else {
                isNewResult = false
            }
            guard (isNewestObservedEvent && isCurrentActivity) || isNewResult else { return }
            if event.source == .hook, isCurrentActivity { context.subtasks[i].lastHookEventAt = event.date }
            if isNewestObservedEvent {
                context.subtasks[i].observedEventID = event.id
                context.subtasks[i].observedEventAt = event.date
            }
            switch event.kind {
            case .working, .prompt:
                guard isCurrentActivity else { return }
                // A paused agent's interrupted turn can still flush tool events.
                if case .working = event.kind, context.subtasks[i].pausedAt != nil { return }
                context.subtasks[i].lastHeartbeatAt = event.date
                if !event.summary.isEmpty { context.subtasks[i].progressSummary = event.summary }
                context.subtasks[i].status = .working
                context.subtasks[i].attention = nil
                // Replying in the terminal means the person read the last result.
                if case .prompt = event.kind, event.date >= (context.subtasks[i].resultAt ?? .distantPast) {
                    context.subtasks[i].completionUnread = false
                }
            case .result:
                if isNewResult {
                    context.subtasks[i].completionUnread = true
                    context.subtasks[i].resultID = event.id
                    context.subtasks[i].resultSummary = event.summary
                    context.subtasks[i].resultAt = event.date
                    context.subtasks[i].lastOutputAt = max(
                        context.subtasks[i].lastOutputAt ?? .distantPast, event.date)
                }
                if isCurrentActivity {
                    context.subtasks[i].lastHeartbeatAt = event.date
                    if !event.summary.isEmpty { context.subtasks[i].progressSummary = event.summary }
                    context.subtasks[i].status = .idle
                    context.subtasks[i].attention = nil
                }
            case .attention(let attention):
                guard isCurrentActivity else { return }
                // Pause's own Esc is recorded as an interrupted turn; it is not a problem.
                if attention == .interrupted, context.subtasks[i].pausedAt != nil { return }
                context.subtasks[i].lastHeartbeatAt = event.date
                if !event.summary.isEmpty { context.subtasks[i].progressSummary = event.summary }
                context.subtasks[i].status = attention.isProblem ? .blocked : .idle
                context.subtasks[i].attention = attention
            }
        }
    }

    /// Correlates assignments without sharing their terminal identity or launch workspace.
    @discardableResult public func associateAgent(ticketID: String, agentID: String, subtaskID: String) throws -> TaskContext {
        try mutate(ticketID: ticketID, archiveChanges: true) { context in
            guard let index = context.subtasks.firstIndex(where: { $0.id == agentID }), context.subtasks[index].hasAgent,
                  let target = context.subtasks.first(where: { $0.id == subtaskID }), target.parentSubtaskID == nil else {
                throw TaskContextError.missingSubtask(subtaskID)
            }
            if !context.subtasks[index].associatedSubtaskIDs.contains(subtaskID) {
                context.subtasks[index].associatedSubtaskIDs.append(subtaskID)
            }
        }
    }

    /// Only an orchestrator boundary combines assignments. Aliases keep old CLI IDs valid.
    @discardableResult public func reconcileSubtasks(ticketID: String) throws -> TaskContext {
        try mutate(ticketID: ticketID, archiveChanges: true, archiveBeforeChanges: true) { context in
            context.separateLegacyAgentAssignments()
            context.mergeSharedAgentSubtasks()
        }
    }

    @discardableResult public func recordAgentIdentity(ticketID: String, subtaskID: String, sessionID: String) throws -> TaskContext {
        try mutate(ticketID: ticketID, archiveChanges: true) { context in
            guard let index = context.subtasks.firstIndex(where: { $0.id == subtaskID }) else { throw TaskContextError.missingSubtask(subtaskID) }
            context.subtasks[index].sessionID = sessionID
        }
    }

    @discardableResult public func attachSubtask(ticketID: String, subtaskID: String, provider: AgentProvider,
                                                 sessionID: String, now: Date = Date()) throws -> TaskContext {
        try mutate(ticketID: ticketID, archiveChanges: true) { context in
            guard let index = context.subtasks.firstIndex(where: { $0.id == subtaskID }) else { throw TaskContextError.missingSubtask(subtaskID) }
            guard context.subtasks[index].provider == provider else { throw TaskContextError.commandFailed("The session provider does not match this subtask's assignment.") }
            context.subtasks[index].sessionID = sessionID
            if context.subtasks[index].status != .completed {
                context.subtasks[index].status = .working
                context.subtasks[index].attention = nil
                context.subtasks[index].lastHeartbeatAt = now
                context.subtasks[index].progressSummary = "Agent attached to the task workspace."
            }
        }
    }

    @discardableResult public func setWorktree(ticketID: String, path: String?, branch: String?, baseBranch: String?, managed: Bool, repositoryPath: String? = nil) throws -> TaskContext {
        try mutate(ticketID: ticketID) { context in
            context.worktreePath = path; context.branch = branch; context.baseBranch = baseBranch; context.managedWorktree = managed
            if let repositoryPath { context.repositoryPath = repositoryPath }
        }
    }

    /// After completion cleanup the task keeps its plan, log, and agent
    /// records, but no longer claims a workspace or a tmux runtime.
    @discardableResult public func recordCompletionCleanup(ticketID: String) throws -> TaskContext {
        try mutate(ticketID: ticketID) { context in
            if context.managedWorktree, let path = context.worktreePath, !files.fileExists(atPath: path) {
                context.worktreePath = nil
                context.managedWorktree = false
            }
            for index in context.subtasks.indices {
                context.subtasks[index].tmux = nil
                context.subtasks[index].completionTerminalRetained = nil
            }
        }
    }

    /// Pin state shares the task context lock so app and CLI changes cannot
    /// overwrite concurrent context updates.
    @discardableResult public func setPinned(
        ticketID: String, at date: Date?
    ) throws -> TaskContext {
        try mutate(ticketID: ticketID) { context in
            context.pinnedAt = date
        }
    }

    /// Records outputs as seen at their current dates and forgets deleted files.
    @discardableResult public func markOutputsReviewed(
        ticketID: String, outputs: [TaskOutputFile]
    ) throws -> TaskContext {
        try mutate(ticketID: ticketID) { context in
            var reviewed = context.reviewedOutputs ?? [:]
            for output in outputs { reviewed[output.relativePath] = output.modifiedAt }
            context.reviewedOutputs = reviewed.filter {
                files.fileExists(atPath: context.contextDirectory.appendingPathComponent($0.key).path)
            }
        }
    }

    public func archive(ticketID: String) throws {
        try locked(ticketID: ticketID) {
            guard let context = try load(ticketID: ticketID) else { throw TaskContextError.missingContext(ticketID) }
            try snapshot(context)
        }
    }

    /// A reference and live plan link avoid competing copies. Existing user files are preserved.
    public func installWorktreeReference(ticketID: String) throws {
        guard let context = try load(ticketID: ticketID), let path = context.worktreePath else { return }
        let workspace = URL(fileURLWithPath: path, isDirectory: true)
        guard files.fileExists(atPath: workspace.path) else { throw TaskContextError.unsafeWorktree("Worktree does not exist: \(path)") }
        let localRoot = workspace.appendingPathComponent(".focus-queue", isDirectory: true)
        let reference = localRoot.appendingPathComponent(context.ticketID, isDirectory: true)
        for candidate in [localRoot, reference] {
            if (try? files.destinationOfSymbolicLink(atPath: candidate.path)) != nil {
                throw TaskContextError.unsafeWorktree("The local task context directory is a symbolic link. Preserve it and choose a regular task directory before installing references.")
            }
        }
        try files.createDirectory(at: reference, withIntermediateDirectories: true)
        let link = reference.appendingPathComponent("plan.md")
        if !files.fileExists(atPath: link.path) {
            try files.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: context.planPath))
        }
        let pointer = reference.appendingPathComponent("context.json")
        if !files.fileExists(atPath: pointer.path) {
            let data = try JSONSerialization.data(withJSONObject: ["taskID": context.ticketID,
                "canonicalContext": context.contextDirectory.appendingPathComponent("context.json").path,
                "canonicalPlan": context.planPath], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: pointer, options: .atomic)
        }
    }

    private func mutate(
        ticketID: String,
        archiveChanges: Bool = false,
        archiveBeforeChanges: Bool = false,
        change: (inout TaskContext) throws -> Void
    ) throws -> TaskContext {
        try locked(ticketID: ticketID) {
            guard var context = try load(ticketID: ticketID) else { throw TaskContextError.missingContext(ticketID) }
            if archiveBeforeChanges { try snapshot(context) }
            let original = context
            try change(&context)
            context.refreshAssignmentStatuses()
            guard context != original else { return context }
            context.updatedAt = Date()
            try write(context)
            if archiveChanges { try snapshot(context) }
            return context
        }
    }

    private func write(_ context: TaskContext) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(context).write(to: try directory(ticketID: context.ticketID).appendingPathComponent("context.json"), options: .atomic)
    }

    private func snapshot(_ context: TaskContext) throws {
        let archive = context.contextDirectory.appendingPathComponent("archive", isDirectory: true)
        let plan = try Data(contentsOf: URL(fileURLWithPath: context.planPath))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var content = try encoder.encode(context.withoutVolatileFields)
        content.append(plan)
        let fingerprint = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
        let destination = archive.appendingPathComponent("snapshot-\(fingerprint)", isDirectory: true)
        if files.fileExists(atPath: destination.appendingPathComponent("plan.md").path),
           files.fileExists(atPath: destination.appendingPathComponent("context.json").path) { return }
        try files.createDirectory(at: destination, withIntermediateDirectories: true)
        // These are independent copies. Worktree symlinks are convenient pointers, not backups.
        try plan.write(to: destination.appendingPathComponent("plan.md"), options: .atomic)
        try encoder.encode(context).write(to: destination.appendingPathComponent("context.json"), options: .atomic)
        let snapshots = try files.contentsOfDirectory(at: archive, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])
            .filter { $0.lastPathComponent.hasPrefix("snapshot-") && $0.lastPathComponent.count == 73 }
            .sorted {
                ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
                    > ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
            }
        for expired in snapshots.dropFirst(100) { try files.removeItem(at: expired) }
    }

    private func locked<T>(ticketID: String, body: () throws -> T) throws -> T {
        let directory = try directory(ticketID: ticketID)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = Darwin.open(directory.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}

extension TaskContext {
    /// The context without fields that change on every heartbeat or poll.
    /// Equal results describe the same work, so callers can skip rewriting
    /// snapshots and history when only these fields moved.
    public var withoutVolatileFields: TaskContext {
        var context = self
        context.updatedAt = Date(timeIntervalSince1970: 0)
        for index in context.subtasks.indices {
            context.subtasks[index].lastHeartbeatAt = nil
            context.subtasks[index].completionUnread = false
            context.subtasks[index].observedEventID = nil
            context.subtasks[index].observedEventAt = nil
            context.subtasks[index].lastHookEventAt = nil
        }
        return context
    }
}
