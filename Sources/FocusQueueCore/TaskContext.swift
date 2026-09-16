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
        let codex = (environment["CODEX_SESSION_ID"] ?? environment["CODEX_THREAD_ID"]).flatMap { $0.isEmpty ? nil : $0 }
        let claude = environment["CLAUDE_SESSION_ID"].flatMap { $0.isEmpty ? nil : $0 }
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

    public init(path: String, repositoryPath: String, branch: String? = nil,
                baseBranch: String? = nil, baseCommit: String? = nil, managed: Bool = false) {
        self.path = path; self.repositoryPath = repositoryPath; self.branch = branch
        self.baseBranch = baseBranch; self.baseCommit = baseCommit; self.managed = managed
    }
}

public struct TaskSubtask: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var provider: AgentProvider
    public var sessionID: String?
    public var status: TaskSubtaskStatus
    public var progressSummary: String
    public var lastHeartbeatAt: Date?
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

    public var hasManagedWorkspaces: Bool { workspace?.managed == true || workspaceHistory.contains(where: \.managed) }
    public var isAgentVisible: Bool { agentRemovedAt == nil && status != .completed }
    public static func agentName(prompt: String, provider: AgentProvider) -> String {
        let words = prompt.split(whereSeparator: \.isWhitespace).prefix(10).joined(separator: " ")
        return words.isEmpty ? "Blank \(provider.displayName) agent" : String(words.prefix(80))
    }

    public init(id: String = UUID().uuidString, title: String, provider: AgentProvider = .codex,
                sessionID: String? = nil, status: TaskSubtaskStatus = .queued,
                progressSummary: String = "", lastHeartbeatAt: Date? = nil,
                completionUnread: Bool = false, includeInitializationPrompt: Bool = true,
                tmux: TmuxSessionReference? = nil,
                runtimeMode: AgentRuntimeMode? = .tmux,
                terminalPaneID: Int? = nil, terminalSocketPath: String? = nil) {
        self.id = id; self.title = title; self.provider = provider; self.sessionID = sessionID
        self.status = status; self.progressSummary = progressSummary
        self.lastHeartbeatAt = lastHeartbeatAt; self.completionUnread = completionUnread
        self.includeInitializationPrompt = includeInitializationPrompt
        self.tmux = tmux
        self.runtimeMode = runtimeMode
        self.terminalPaneID = terminalPaneID
        self.terminalSocketPath = terminalSocketPath
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, provider, sessionID, status, progressSummary, lastHeartbeatAt, completionUnread, includeInitializationPrompt, tmux
        case runtimeMode, terminalPaneID, terminalSocketPath, workspace, workspaceHistory, initialPrompt, agentRemovedAt, tracksCompletion, completionOverrideAt
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        provider = try values.decode(AgentProvider.self, forKey: .provider)
        sessionID = try values.decodeIfPresent(String.self, forKey: .sessionID)
        status = try values.decode(TaskSubtaskStatus.self, forKey: .status)
        progressSummary = try values.decodeIfPresent(String.self, forKey: .progressSummary) ?? ""
        lastHeartbeatAt = try values.decodeIfPresent(Date.self, forKey: .lastHeartbeatAt)
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
    }

    /// A live terminal is not proof of activity. Only a recent explicit heartbeat is.
    public func effectiveStatus(now: Date = Date(), heartbeatLifetime: TimeInterval = 300) -> TaskSubtaskStatus {
        guard status == .working else { return status }
        guard let lastHeartbeatAt, now.timeIntervalSince(lastHeartbeatAt) <= heartbeatLifetime else { return .idle }
        return .working
    }
}

public struct TaskContext: Codable, Equatable, Sendable {
    public var schemaVersion = 1
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
    public var updatedAt: Date

    public var contextDirectory: URL { URL(fileURLWithPath: planPath).deletingLastPathComponent() }

    public func agentPrompt(subtask: TaskSubtask) -> String {
        let support = contextDirectory.deletingLastPathComponent().deletingLastPathComponent().path
        let quotedSupport = "'" + support.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        let command = "FOCUS_QUEUE_SUPPORT_DIR=\(quotedSupport) focus-queue-session"
        let mapHelper = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/ECC Focus Queue.app/Contents/MacOS/focus-queue-map").path
        let quotedMapHelper = "'" + mapHelper.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        let scopeInstruction = FileManager.default.isExecutableFile(atPath: mapHelper) ? """
        Keep your map scope current after registration and when your files change: FOCUS_QUEUE_SUPPORT_DIR=\(quotedSupport) \(quotedMapHelper) scope \(ticketID) \(subtask.id) --input <context-file> --output <output-file>
        Repeat --input/--output for multiple files; each call replaces your previous scope. Declare only your actual context and intended outputs. Git changes alone do not establish ownership.
        """ : ""
        if subtask.status == .completed {
            return """
            Resume \(ticketID): \(title). Your subtask \(subtask.title) (\(subtask.id)) is already completed.
            Read its central plan at \(planPath) and the recorded handoff in \(contextDirectory.appendingPathComponent("context.json").path).
            Review the completed handoff and await new user instructions. Keep the subtask completed; do not restart implementation or report working merely because the terminal was reopened.
            Register this pane: FOCUS_QUEUE_PROVIDER=\(subtask.provider.rawValue) FOCUS_QUEUE_TASK_ID=\(ticketID) FOCUS_QUEUE_SUBTASK_ID=\(subtask.id) \(command) attach \(ticketID)
            """
        }
        return """
        Work on \(ticketID): \(title). Your subtask is \(subtask.title) (\(subtask.id)).
        Read the central plan at \(planPath) and context at \(contextDirectory.appendingPathComponent("context.json").path) before acting. The central plan is the source of truth. Keep it current with decisions, checks, and handoff details; link supporting canvases from it.
        Initial request: \(subtask.initialPrompt ?? subtask.title)
        Workspace: \(subtask.workspace?.path ?? worktreePath ?? repositoryPath ?? "not configured")
        Assigned branch: \(subtask.workspace?.branch ?? branch ?? "not configured")
        Success criteria: \(successCriteria)
        Register this pane: FOCUS_QUEUE_PROVIDER=\(subtask.provider.rawValue) FOCUS_QUEUE_TASK_ID=\(ticketID) FOCUS_QUEUE_SUBTASK_ID=\(subtask.id) \(command) attach \(ticketID)
        Report concise progress and refresh activity at meaningful milestones (at least every 5 minutes while working): \(command) progress \(ticketID) \(subtask.id) working "short progress summary"
        \(scopeInstruction)
        Use idle or blocked when waiting. On completion: \(command) complete \(ticketID) \(subtask.id) "what changed and verification result"
        Before any push, run \(command) review-push \(ticketID) \(subtask.id). The orchestrator scans the committed diff for accidental files, unrelated additions, generated output, and missing checks. If rejected, correct only your changes and run review-push again. Push only after acceptance and only when the user authorized remote delivery. Never push directly to main unless explicitly requested.
        Propose scope, branch, or plan changes to the task orchestrator before acting. Record approved workspace changes with \(command) workspace \(ticketID) \(subtask.id) <absolute-path>.
        Complete only your assigned subtask. Preserve other agents' changes. Never force-remove a worktree or merge a branch without the task's approval terms. Task closure requires verification and safe cleanup.
        """
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
    public func refreshContexts(tickets: [DashboardTicket]) -> TaskContextRefreshSnapshot {
        let now = Date()
        var contexts: [String: TaskContext] = [:]
        var errors: [String: String] = [:]
        let activeIDs = Set(tickets.map(\.id))
        refreshCache = refreshCache.filter { activeIDs.contains($0.key) }
        for ticket in tickets {
            do {
                let url = try directory(ticketID: ticket.id).appendingPathComponent("context.json")
                let version = try fileVersion(at: url)
                let planURL = refreshCache[ticket.id]?.context.map { URL(fileURLWithPath: $0.planPath) }
                    ?? url.deletingLastPathComponent().appendingPathComponent("plan.md")
                let planVersion = try fileVersion(at: planURL)
                if let cached = refreshCache[ticket.id], cached.ticket == ticket,
                   cached.version == version, cached.planVersion == planVersion,
                   now.timeIntervalSince(cached.readAt) < 60 {
                    contexts[ticket.id] = cached.context
                    continue
                }
                let context: TaskContext?
                if ticket.isCompleted, version == nil { context = nil }
                else { context = try ensureContext(ticket: ticket) }
                // An agent may edit the Markdown or JSON directly. Retain the
                // changed source even when no dashboard fields require merging.
                if context != nil { try archive(ticketID: ticket.id) }
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
        return try JSONDecoder().decode(TaskContext.self, from: Data(contentsOf: url))
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

    @discardableResult public func ensureContext(ticket: DashboardTicket, worktreePath: String? = nil) throws -> TaskContext {
        try locked(ticketID: ticket.id) {
            if var existing = try load(ticketID: ticket.id) {
                let previous = existing
                existing.title = ticket.title
                existing.summary = ticket.summary
                existing.successCriteria = ticket.doneWhen ?? existing.successCriteria
                // A retained branch with no workspace records completed cleanup. Dashboard
                // metadata may still mention the former workspace until its next refresh.
                if existing.worktreePath == nil, existing.branch == nil { existing.worktreePath = worktreePath ?? ticket.worktree }
                if previous != existing { existing.updatedAt = Date(); try write(existing); try snapshot(existing) }
                else if !files.fileExists(atPath: existing.contextDirectory.appendingPathComponent("archive").path) { try snapshot(existing) }
                return existing
            }
            let directory = try directory(ticketID: ticket.id)
            let planURL = directory.appendingPathComponent("plan.md")
            let context = TaskContext(ticketID: ticket.id.uppercased(), title: ticket.title,
                                      summary: ticket.summary, successCriteria: ticket.doneWhen ?? "Confirm the requested behavior and record verification results.",
                                      planPath: planURL.path, worktreePath: worktreePath ?? ticket.worktree, updatedAt: Date())
            if !files.fileExists(atPath: planURL.path) {
                let links = ticket.links.map { "- [\($0.label)](\($0.url))" }.joined(separator: "\n")
                let steps = ticket.steps.map { "- [\($0.isDone ? "x" : " ")] \($0.label)" }.joined(separator: "\n")
                let markdown = """
                # \(ticket.id): \(ticket.title)

                ## Purpose

                \(ticket.summary)

                ## Success criteria

                \(context.successCriteria)

                ## Implementation plan

                \(steps.isEmpty ? "- [ ] Confirm scope and record the implementation approach." : steps)

                ## Progress and handoff

                \(ticket.next ?? "Record completed changes, current focus, blockers, and the next action here.")

                ## Decisions

                Record material decisions and their reasons here.

                ## Verification

                Record the sanity check for each completed behavior here.

                ## Supporting plans and references

                \(links)

                """
                try Data(markdown.utf8).write(to: planURL, options: .atomic)
            }
            try write(context)
            try snapshot(context)
            return context
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
        try mutate(ticketID: ticketID) { context in
            if let index = context.subtasks.firstIndex(where: { $0.id == subtask.id }) { context.subtasks[index] = subtask }
            else { context.subtasks.append(subtask) }
        }
    }

    @discardableResult public func renameSubtask(ticketID: String, subtaskID: String, title: String) throws -> TaskContext {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw TaskContextError.commandFailed("Give the subtask a readable name.") }
        return try mutate(ticketID: ticketID) { context in
            guard let index = context.subtasks.firstIndex(where: { $0.id == subtaskID }) else { throw TaskContextError.missingSubtask(subtaskID) }
            context.subtasks[index].title = String(title.prefix(200))
        }
    }

    @discardableResult public func setManagedRuntime(ticketID: String, subtaskID: String,
                                                      tmux: TmuxSessionReference) throws -> TaskContext {
        try mutate(ticketID: ticketID, archiveChanges: true) { context in
            guard let index = context.subtasks.firstIndex(where: { $0.id == subtaskID }) else {
                throw TaskContextError.missingSubtask(subtaskID)
            }
            context.subtasks[index].tmux = tmux
            context.subtasks[index].runtimeMode = .tmux
            context.subtasks[index].terminalPaneID = nil
            context.subtasks[index].terminalSocketPath = nil
            if context.subtasks[index].status != .completed {
                context.subtasks[index].status = .working
                context.subtasks[index].lastHeartbeatAt = Date()
                context.subtasks[index].progressSummary =
                    "Managed session started and remains available through tmux."
            }
        }
    }

    @discardableResult public func setDirectRuntime(
        ticketID: String, subtaskID: String, paneID: Int, socketPath: String?
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
            if context.subtasks[index].status != .completed {
                context.subtasks[index].status = .working
                context.subtasks[index].lastHeartbeatAt = Date()
                context.subtasks[index].progressSummary =
                    "Direct terminal session started. Closing its terminal ends the live process."
            }
        }
    }

    @discardableResult public func clearSubtasks(ticketID: String) throws -> TaskContext {
        try mutate(ticketID: ticketID, archiveChanges: true) { context in
            context.subtasks.removeAll()
        }
    }

    @discardableResult public func updateProgress(ticketID: String, subtaskID: String, status: TaskSubtaskStatus,
                                                  summary: String, sessionID: String? = nil, now: Date = Date()) throws -> TaskContext {
        try mutate(ticketID: ticketID, archiveChanges: true) { context in
            guard let index = context.subtasks.firstIndex(where: { $0.id == subtaskID }) else { throw TaskContextError.missingSubtask(subtaskID) }
            // A late worker/verifier report cannot undo an explicit user override.
            guard context.subtasks[index].completionOverrideAt == nil else { return }
            context.subtasks[index].status = status
            context.subtasks[index].progressSummary = String(summary.prefix(2_000))
            context.subtasks[index].lastHeartbeatAt = now
            if let sessionID { context.subtasks[index].sessionID = sessionID }
            context.subtasks[index].completionUnread = status == .completed
        }
    }

    /// Removing an agent never deletes its assignment, conversation identity, or workspace.
    @discardableResult public func removeAgent(ticketID: String, subtaskID: String) throws -> TaskContext {
        try mutate(ticketID: ticketID, archiveChanges: true) { context in
            guard let index = context.subtasks.firstIndex(where: { $0.id == subtaskID }) else { throw TaskContextError.missingSubtask(subtaskID) }
            context.subtasks[index].agentRemovedAt = Date()
        }
    }

    @discardableResult public func restoreAgent(ticketID: String, subtaskID: String) throws -> TaskContext {
        try mutate(ticketID: ticketID, archiveChanges: true) { context in
            guard let index = context.subtasks.firstIndex(where: { $0.id == subtaskID }) else { throw TaskContextError.missingSubtask(subtaskID) }
            context.subtasks[index].agentRemovedAt = nil
        }
    }

    @discardableResult public func overrideCompletion(ticketID: String, subtaskID: String) throws -> TaskContext {
        try mutate(ticketID: ticketID, archiveChanges: true) { context in
            guard let index = context.subtasks.firstIndex(where: { $0.id == subtaskID }) else { throw TaskContextError.missingSubtask(subtaskID) }
            context.subtasks[index].status = .completed
            context.subtasks[index].completionOverrideAt = Date()
            context.subtasks[index].completionUnread = true
            context.subtasks[index].lastHeartbeatAt = Date()
            context.subtasks[index].progressSummary = "Completed by user override. Previous review evidence is retained."
        }
    }

    @discardableResult public func setAgentWorkspace(ticketID: String, subtaskID: String, workspace: AgentWorkspace) throws -> TaskContext {
        try mutate(ticketID: ticketID, archiveChanges: true) { context in
            guard let index = context.subtasks.firstIndex(where: { $0.id == subtaskID }) else { throw TaskContextError.missingSubtask(subtaskID) }
            if let previous = context.subtasks[index].workspace, previous != workspace,
               !context.subtasks[index].workspaceHistory.contains(previous) {
                context.subtasks[index].workspaceHistory.append(previous)
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

    @discardableResult public func acknowledgeCompletion(ticketID: String, subtaskID: String) throws -> TaskContext {
        try mutate(ticketID: ticketID) { context in
            guard let index = context.subtasks.firstIndex(where: { $0.id == subtaskID }) else { throw TaskContextError.missingSubtask(subtaskID) }
            context.subtasks[index].completionUnread = false
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

    private func mutate(ticketID: String, archiveChanges: Bool = false, change: (inout TaskContext) throws -> Void) throws -> TaskContext {
        try locked(ticketID: ticketID) {
            guard var context = try load(ticketID: ticketID) else { throw TaskContextError.missingContext(ticketID) }
            try change(&context)
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
        var meaningfulContext = context
        meaningfulContext.updatedAt = Date(timeIntervalSince1970: 0)
        for index in meaningfulContext.subtasks.indices {
            meaningfulContext.subtasks[index].lastHeartbeatAt = nil
            meaningfulContext.subtasks[index].completionUnread = false
        }
        var content = try encoder.encode(meaningfulContext)
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
