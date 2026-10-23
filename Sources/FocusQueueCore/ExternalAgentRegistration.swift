import CryptoKit
import Foundation

public struct ExternalAgentLaunchMetadata: Codable, Sendable {
    public var schemaVersion: Int?
    public var provider: String?
    public var cwd: String?
    public var launchedAt: String?
    public var initialPrompt: String?
    public var reference: TmuxSessionReference

    public init(initialPrompt: String?, reference: TmuxSessionReference,
                provider: AgentProvider? = nil, cwd: String? = nil) {
        schemaVersion = 1
        self.provider = provider?.rawValue
        self.cwd = cwd
        launchedAt = ISO8601DateFormatter().string(from: Date())
        self.initialPrompt = initialPrompt
        self.reference = reference
    }

    /// Shared task sessions store one metadata file per pane/agent, while
    /// older single-agent sessions used only the tmux session name. Resolve
    /// by the full immutable pane reference and retain the legacy fast path.
    public static func load(
        matching reference: TmuxSessionReference, supportDirectory: URL
    ) throws -> Self? {
        try TmuxController.validateName(reference.name)
        let directory = supportDirectory.appendingPathComponent("shell/launch-metadata", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        guard (try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw TaskContextError.commandFailed("Launch metadata storage is redirected.")
        }
        func decode(_ url: URL) -> Self? {
            guard url.pathExtension == "json",
                (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                let data = try? Data(contentsOf: url),
                let metadata = try? JSONDecoder().decode(Self.self, from: data),
                metadata.reference == reference else { return nil }
            return metadata
        }
        let legacy = directory.appendingPathComponent(reference.name + ".json")
        if let metadata = decode(legacy) { return metadata }
        let matches = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey])
            .filter { $0.lastPathComponent != legacy.lastPathComponent }
            .compactMap(decode)
        return matches.count == 1 ? matches[0] : nil
    }

    /// App-side launches record the same metadata the shell entry points write
    /// so process discovery has a prompt source even without provider hooks.
    public func save(name: String, supportDirectory: URL) throws {
        guard !name.isEmpty,
              name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }) else {
            throw TaskContextError.invalidIdentifier
        }
        let directory = supportDirectory.appendingPathComponent("shell/launch-metadata", isDirectory: true)
        guard (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw TaskContextError.commandFailed("Launch metadata storage is redirected.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(name + ".json")
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw TaskContextError.commandFailed("Launch metadata storage is redirected.")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public struct ExternalAgentEvent: Codable, Sendable {
    public var sessionID: String
    public var cwd: String
    public var hookEventName: String
    public var prompt: String?
    public var agentID: String?
    public var parentSessionID: String?
    public var discoveredAsSubagent: Bool?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id", cwd, hookEventName = "hook_event_name", prompt
        case agentID = "agent_id", parentSessionID = "parent_session_id"
        case discoveredAsSubagent = "focus_queue_discovered_subagent"
    }

    public init(sessionID: String, cwd: String, hookEventName: String,
                prompt: String? = nil, agentID: String? = nil, parentSessionID: String? = nil,
                discoveredAsSubagent: Bool? = nil) {
        self.sessionID = sessionID; self.cwd = cwd; self.hookEventName = hookEventName
        self.prompt = prompt; self.agentID = agentID; self.parentSessionID = parentSessionID
        self.discoveredAsSubagent = discoveredAsSubagent
    }

    public var isSubagent: Bool {
        discoveredAsSubagent == true || parentSessionID?.isEmpty == false
            || ["SubagentStart", "SubagentStop"].contains(hookEventName)
    }
    public var providerSessionID: String? {
        let candidate = ["SubagentStart", "SubagentStop"].contains(hookEventName)
            ? agentID : sessionID
        return candidate.flatMap { UUID(uuidString: $0) == nil ? nil : $0.lowercased() }
    }
}

public struct ExternalAgentRegistration: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var provider: AgentProvider
    public var sessionID: String?
    public var agentID: String?
    public var parentSessionID: String?
    public var cwd: String
    public var title: String
    public var workDescription: String? = nil
    public var taskID: String?
    public var subtaskID: String?
    public var reason: String?
    public var eventName: String
    public var updatedAt: Date
    /// First time this exact provider identity was seen; preserved across updates.
    public var registeredAt: Date
    public var tmux: TmuxSessionReference?
    public var paneID: Int?
    public var socketPath: String?

    public init(id: String, provider: AgentProvider, sessionID: String?, agentID: String? = nil,
                parentSessionID: String? = nil, cwd: String, title: String,
                workDescription: String? = nil, taskID: String? = nil, subtaskID: String? = nil,
                reason: String? = nil, eventName: String, updatedAt: Date,
                registeredAt: Date? = nil, tmux: TmuxSessionReference? = nil,
                paneID: Int? = nil, socketPath: String? = nil) {
        self.id = id; self.provider = provider; self.sessionID = sessionID
        self.agentID = agentID; self.parentSessionID = parentSessionID; self.cwd = cwd
        self.title = title; self.workDescription = workDescription
        self.taskID = taskID; self.subtaskID = subtaskID; self.reason = reason
        self.eventName = eventName; self.updatedAt = updatedAt
        self.registeredAt = registeredAt ?? updatedAt
        self.tmux = tmux; self.paneID = paneID; self.socketPath = socketPath
    }

    private enum CodingKeys: String, CodingKey {
        case id, provider, sessionID, agentID, parentSessionID, cwd, title, workDescription
        case taskID, subtaskID, reason, eventName, updatedAt, registeredAt, tmux, paneID, socketPath
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        provider = try values.decode(AgentProvider.self, forKey: .provider)
        sessionID = try values.decodeIfPresent(String.self, forKey: .sessionID)
        agentID = try values.decodeIfPresent(String.self, forKey: .agentID)
        parentSessionID = try values.decodeIfPresent(String.self, forKey: .parentSessionID)
        cwd = try values.decode(String.self, forKey: .cwd)
        title = try values.decode(String.self, forKey: .title)
        workDescription = try values.decodeIfPresent(String.self, forKey: .workDescription)
        taskID = try values.decodeIfPresent(String.self, forKey: .taskID)
        subtaskID = try values.decodeIfPresent(String.self, forKey: .subtaskID)
        reason = try values.decodeIfPresent(String.self, forKey: .reason)
        eventName = try values.decode(String.self, forKey: .eventName)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        // Records saved before first-seen tracking fall back to their last update.
        registeredAt = try values.decodeIfPresent(Date.self, forKey: .registeredAt) ?? updatedAt
        tmux = try values.decodeIfPresent(TmuxSessionReference.self, forKey: .tmux)
        paneID = try values.decodeIfPresent(Int.self, forKey: .paneID)
        socketPath = try values.decodeIfPresent(String.self, forKey: .socketPath)
    }

    public var status: String { taskID == nil ? "unassigned" : "registered" }
    public var session: TaskAgentSession? {
        guard let taskID, let sessionID, let subtaskID else { return nil }
        return TaskAgentSession(ticketID: taskID, provider: provider, sessionID: sessionID,
            tabTitle: title, workingDirectory: cwd, paneID: paneID, subtaskID: subtaskID, tmux: tmux)
    }
}

/// Hook receipts live separately from cached app state. Their identity is supplied
/// by the provider or a process-owned file, never a newest-transcript heuristic.
public actor ExternalAgentRegistry {
    public let root: URL
    private var directory: URL { root.appendingPathComponent("external-agent-sessions", isDirectory: true) }

    public init(root: URL) { self.root = root }

    public static let codexSubagentReason =
        "Codex sub-agent threads share their parent agent's registration and are not added as agents."

    public func registrations() throws -> [ExternalAgentRegistration] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(ExternalAgentRegistration.self, from: data)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    @discardableResult
    public func register(_ event: ExternalAgentEvent, provider: AgentProvider,
                         explicitTaskID: String? = nil, environment: [String: String] = [:],
                         tmux: TmuxSessionReference? = nil, paneID: Int? = nil,
                         socketPath: String? = nil) async throws -> ExternalAgentRegistration {
        guard UUID(uuidString: event.sessionID) != nil,
              event.cwd.hasPrefix("/"), !event.cwd.contains("\0") else {
            throw TaskContextError.commandFailed("Registration requires the provider's exact session UUID and absolute working directory.")
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: event.cwd, isDirectory: &isDirectory), !isDirectory.boolValue {
            throw ProcessRunnerError.invalidWorkingDirectory(event.cwd)
        }
        let cwd = Self.normalized(event.cwd)
        let key = provider.rawValue + ":" + (event.providerSessionID
            ?? "child:\(event.sessionID.lowercased()):\(event.agentID ?? "unknown")")
        let id = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let lockID = SHA256.hash(data: Data((root.path + ":" + id).utf8))
            .map { String(format: "%02x", $0) }.joined()
        let lock = try await TmuxOrganizerLock.acquire(name: "registration-" + lockID)
        defer { lock.release() }
        if provider == .codex, event.isSubagent {
            // A Codex sub-agent thread is part of its root agent's work, not
            // another agent. Its writer lock and its own UUID would otherwise give
            // one Codex agent a row per spawned explorer or reviewer. Receipts
            // saved before this rule are removed so they stop listing as unassigned.
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(id + ".json"))
            let parent = ["SubagentStart", "SubagentStop"].contains(event.hookEventName)
                ? event.sessionID : event.parentSessionID
            return ExternalAgentRegistration(id: id, provider: provider,
                sessionID: event.providerSessionID, agentID: event.agentID,
                parentSessionID: parent?.lowercased(), cwd: cwd,
                title: "Subagent · \((event.agentID ?? event.sessionID).suffix(6))",
                reason: Self.codexSubagentReason, eventName: event.hookEventName, updatedAt: Date())
        }
        let previous = try registrations().first { $0.id == id }
        let contexts = try await TaskContextStore(root: root).loadAvailableForDiscovery()
        let parent = event.isSubagent ? (event.parentSessionID ?? event.sessionID).lowercased() : nil
        let hasParent = parent != nil || previous?.parentSessionID != nil
        let now = Date()
        var record = ExternalAgentRegistration(id: id, provider: provider, sessionID: event.providerSessionID,
            agentID: event.agentID ?? previous?.agentID, parentSessionID: parent ?? previous?.parentSessionID, cwd: cwd,
            title: previous?.title ?? "\(event.isSubagent ? "Subagent" : provider.displayName) · \((event.agentID ?? event.sessionID).suffix(6))",
            workDescription: previous?.workDescription
                ?? "Continue the \(provider.displayName) session in \(URL(fileURLWithPath: cwd).lastPathComponent).",
            reason: nil, eventName: event.hookEventName, updatedAt: now,
            registeredAt: previous?.registeredAt ?? now,
            tmux: hasParent ? nil : tmux ?? previous?.tmux,
            paneID: hasParent ? nil : paneID ?? previous?.paneID,
            socketPath: hasParent ? nil : socketPath ?? previous?.socketPath)
        if let prompt = event.prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            record.title = TaskSubtask.agentName(prompt: prompt, provider: provider)
            record.workDescription = TaskSubtask.agentDescription(prompt: prompt)
        }
        // Tracking survives an incomplete task or a failed enrichment step.
        if previous == nil { try save(record) }
        guard let sessionID = record.sessionID else {
            record.reason = "The provider supplied a child ID without a resumable session UUID."
            try save(record); return record
        }
        let sessionKey = provider.rawValue + ":" + sessionID
        let explicit = explicitTaskID?.uppercased()
        let inheritedTask = environment["FOCUS_QUEUE_TASK_ID"]?.uppercased()
        let inheritedSubtask = event.isSubagent ? nil : environment["FOCUS_QUEUE_SUBTASK_ID"]
        let priorContext = previous?.taskID.flatMap { id in contexts.first { $0.ticketID == id } }
        let priorDeleted = previous?.subtaskID.map { id in
            priorContext?.subtasks.contains { $0.id == id && $0.agentRemovedAt == nil } != true
        } ?? false
        let tombstoned = contexts.contains { ($0.removedAgentSessionKeys ?? []).contains(sessionKey) }
        let candidates = contexts.filter { context in
            let paths = [context.worktreePath, context.repositoryPath].compactMap { $0 }
                + context.subtasks.compactMap { $0.workspace?.path }
            return paths.contains { Self.contains(directory: $0, path: cwd) }
        }
        let existing = contexts.filter { context in
            context.subtasks.contains { $0.provider == provider && $0.sessionID?.lowercased() == sessionID
                && $0.agentRemovedAt == nil && $0.status != .completed }
        }
        let inherited = inheritedTask.flatMap { name in candidates.first { $0.ticketID == name } }
        let staleInherited = inheritedSubtask != nil && inherited.map { context in
            !context.subtasks.contains { $0.id == inheritedSubtask && $0.provider == provider && $0.agentRemovedAt == nil }
        } != false
        let chosen: TaskContext?
        if existing.count > 1 {
            chosen = nil
            record.reason = "Several active tasks claim this provider session. Resolve the duplicate ownership before attaching it."
        } else if let explicit {
            chosen = contexts.first { $0.ticketID == explicit }
            if chosen == nil { record.reason = "Task context is missing or incomplete. Session retained for placement." }
        } else if (priorDeleted || tombstoned || staleInherited) && existing.isEmpty {
            chosen = nil
            record.reason = "The previous task association was cleared. Choose a task to attach this live session."
        } else if existing.count == 1 { chosen = existing[0] }
        else if let inherited { chosen = inherited }
        else if let parent {
            let parents = contexts.filter { $0.subtasks.contains { $0.provider == provider
                && $0.sessionID?.lowercased() == parent && $0.agentRemovedAt == nil } }
            chosen = parents.count == 1 ? parents[0] : nil
        } else { chosen = candidates.count == 1 ? candidates[0] : nil }

        if let chosen {
            let store = TaskContextStore(root: root)
            if explicit != nil {
                // Explicit task switching moves the live association, preserving
                // the old task's work history without leaving two active owners.
                for old in existing where old.ticketID != chosen.ticketID {
                    _ = try await store.detachSession(ticketID: old.ticketID, provider: provider, sessionID: sessionID)
                }
            }
            let context = try await store.registerExternalSession(
                ticketID: chosen.ticketID, provider: provider, sessionID: sessionID,
                title: record.title, description: record.workDescription ?? record.title,
                cwd: cwd, preferredSubtaskID: inheritedTask == chosen.ticketID ? inheritedSubtask : nil,
                allowFreshAssociation: explicit != nil, tmux: record.tmux,
                paneID: record.paneID, socketPath: record.socketPath,
                eventName: event.hookEventName)
            if let subtask = context.subtasks.first(where: { $0.provider == provider
                && $0.sessionID?.lowercased() == sessionID && $0.agentRemovedAt == nil && $0.status != .completed }) {
                record.taskID = context.ticketID; record.subtaskID = subtask.id
                record.title = subtask.title
                record.workDescription = subtask.workDescription
                if let session = record.session?.withContext(context, subtask: subtask, supportDirectory: root) {
                    try await AgentRegistrationInbox(directory: root.appendingPathComponent("agent-registrations")).submit(session)
                }
            } else { record.reason = "This session's previous work is complete. Choose a task for new work." }
        } else if record.reason == nil {
            record.reason = candidates.count > 1 ? "Several tasks use this workspace. Choose the task." : "Choose a task for this session."
        }
        try save(record)
        return record
    }

    private func save(_ record: ExternalAgentRegistration) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = directory.appendingPathComponent(record.id + ".json")
        try encoder.encode(record).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    public static func contains(directory: String, path: String) -> Bool {
        let directory = normalized(directory), path = normalized(path)
        return path == directory || path.hasPrefix(directory.hasSuffix("/") ? directory : directory + "/")
    }
}
