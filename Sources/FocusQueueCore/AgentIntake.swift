import Foundation

/// A launch receipt exists before a provider has a conversation UUID. Optional
/// metadata never grants permission to resume, complete, or delete anything.
public struct AgentIntakeReceipt: Decodable, Identifiable, Sendable {
    public let launchID: String
    public let createdAt: String?
    public let cwd: String
    public let title: String?
    public let role: String?
    public let phase: String?
    public let note: String?
    public let processID: Int32?
    public let processStartedAt: String?
    public let sessionID: String?
    public let taskID: String?
    public let agentID: String?
    public let repositoryPath: String?
    public let branch: String?
    public let baseBranch: String?
    public let baseCommit: String?
    public let workspacePolicy: String?
    public let reference: TmuxSessionReference?
    public var id: String { "intake-" + launchID }

    private enum CodingKeys: String, CodingKey {
        case launchID, createdAt, cwd, title, role, phase, note, processID, processStartedAt, sessionID, taskID, agentID
        case repositoryPath, branch, baseBranch, baseCommit, workspacePolicy, reference
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        launchID = try values.decode(String.self, forKey: .launchID)
        createdAt = try? values.decodeIfPresent(String.self, forKey: .createdAt)
        cwd = (try? values.decodeIfPresent(String.self, forKey: .cwd)) ?? ""
        title = try? values.decodeIfPresent(String.self, forKey: .title)
        role = try? values.decodeIfPresent(String.self, forKey: .role)
        phase = try? values.decodeIfPresent(String.self, forKey: .phase)
        note = try? values.decodeIfPresent(String.self, forKey: .note)
        processID = try? values.decodeIfPresent(Int32.self, forKey: .processID)
        processStartedAt = try? values.decodeIfPresent(String.self, forKey: .processStartedAt)
        sessionID = try? values.decodeIfPresent(String.self, forKey: .sessionID)
        taskID = try? values.decodeIfPresent(String.self, forKey: .taskID)
        agentID = try? values.decodeIfPresent(String.self, forKey: .agentID)
        repositoryPath = try? values.decodeIfPresent(String.self, forKey: .repositoryPath)
        branch = try? values.decodeIfPresent(String.self, forKey: .branch)
        baseBranch = try? values.decodeIfPresent(String.self, forKey: .baseBranch)
        baseCommit = try? values.decodeIfPresent(String.self, forKey: .baseCommit)
        workspacePolicy = try? values.decodeIfPresent(String.self, forKey: .workspacePolicy)
        reference = try? values.decodeIfPresent(TmuxSessionReference.self, forKey: .reference)
    }

    /// App-created launches already have a task-owned agent row. Trust that
    /// identity only while it still names an active Codex agent in the exact
    /// task from this receipt. Inherited or stale shell variables must not
    /// attach a new process to an unrelated row.
    public func effectiveSubtaskID(in context: TaskContext?) -> String {
        guard let context, let taskID,
            context.ticketID.caseInsensitiveCompare(taskID) == .orderedSame,
            let agentID,
            context.subtasks.contains(where: {
                guard $0.id == agentID, $0.provider == .codex, !$0.isAssignmentOnly,
                    $0.agentRemovedAt == nil, $0.status != .completed else { return false }
                guard let existingSessionID = $0.sessionID, let sessionID else { return true }
                return existingSessionID.caseInsensitiveCompare(sessionID) == .orderedSame
            }) else { return launchID }
        return agentID
    }

    public func discoveryEnvironment(in context: TaskContext?) -> [String: String] {
        guard let taskID else { return [:] }
        return ["FOCUS_QUEUE_TASK_ID": taskID,
            "FOCUS_QUEUE_SUBTASK_ID": effectiveSubtaskID(in: context)]
    }

    public func provisionalSubtask(
        subtaskID: String? = nil, merging existing: TaskSubtask? = nil,
        now: Date = Date()
    ) -> TaskSubtask {
        let name = TaskSubtask.agentName(prompt: title ?? "Codex agent", provider: .codex)
        var subtask = existing ?? TaskSubtask(id: subtaskID ?? launchID, title: name,
            assignmentDescription: note ?? title ?? name, provider: .codex,
            status: phase == "blocked" ? .blocked : .working,
            progressSummary: phase == "blocked" ? (note ?? "Launch needs attention.")
                : phase == "ready" ? "Codex started; waiting for its session ID."
                : "Preparing the isolated workspace.",
            lastHeartbeatAt: now, includeInitializationPrompt: false, tmux: reference,
            runtimeMode: reference == nil ? nil : .tmux)
        if existing == nil { subtask.tracksCompletion = false }
        if subtask.lastHeartbeatAt == nil { subtask.lastHeartbeatAt = now }
        if subtask.status != .completed { subtask.status = phase == "blocked" ? .blocked : .working }
        if subtask.progressSummary.isEmpty {
            subtask.progressSummary = phase == "blocked" ? (note ?? "Launch needs attention.")
                : phase == "ready" ? "Codex started; waiting for its session ID."
                : "Preparing the isolated workspace."
        }
        if let sessionID, let exact = UUID(uuidString: sessionID)?.uuidString.lowercased() {
            subtask.sessionID = exact
        }
        if let reference { subtask.tmux = reference; subtask.runtimeMode = .tmux }
        if subtask.workspace == nil, cwd.hasPrefix("/") {
            subtask.workspace = AgentWorkspace(path: cwd, repositoryPath: repositoryPath ?? cwd,
                branch: branch, baseBranch: baseBranch, baseCommit: baseCommit,
                managed: workspacePolicy == "isolated")
        }
        return subtask
    }

    public var pendingRegistration: ExternalAgentRegistration {
        ExternalAgentRegistration(id: id, provider: .codex, sessionID: nil, agentID: launchID,
            cwd: cwd, title: title?.isEmpty == false ? title! : "Codex agent",
            workDescription: note ?? title ?? "Codex agent awaiting launch details.",
            taskID: taskID, subtaskID: launchID,
            reason: note ?? "Tracked launch. Waiting for provider identity and optional task details.",
            eventName: phase ?? "pending", updatedAt: .distantPast, registeredAt: .distantPast, tmux: reference)
    }

    /// Unresolved launch receipts remain visible until the user dismisses them
    /// or an exact provider identity resolves them. Age and a failed phase do
    /// not prove that the recorded process or its workspace is safe to forget.
    public var isTerminal: Bool { isTerminal(at: Date()) }

    public func isTerminal(at now: Date, staleAfter: TimeInterval = 300) -> Bool {
        _ = now; _ = staleAfter
        return false
    }

    public var isReadyForDiscovery: Bool { reference != nil && phase != "blocked" }

    public var discoveryKey: String? {
        guard let reference, isReadyForDiscovery else { return nil }
        return [launchID, reference.name, String(reference.serverPID), String(reference.createdAt),
            reference.paneID, String(reference.panePID), reference.tty, reference.executable]
            .joined(separator: "|")
    }

    private static func date(_ value: String) -> Date? {
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let result = precise.date(from: value) { return result }
        return ISO8601DateFormatter().date(from: value)
    }
}

public enum AgentIntakeStore {
    public static func load(root: URL) -> [AgentIntakeReceipt] {
        let directory = root.appendingPathComponent("tracking/launches")
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return [] }
        return urls.compactMap { url in
            guard url.pathExtension == "json",
                (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                let data = try? Data(contentsOf: url),
                let receipt = try? JSONDecoder().decode(AgentIntakeReceipt.self, from: data),
                UUID(uuidString: receipt.launchID) != nil else { return nil }
            return receipt
        }
    }

    /// Exact pane identity connects the provisional receipt to an already
    /// verified native session ID. CWD or process ancestry is never sufficient.
    public static func match(_ process: KnownProviderProcess, tmux: TmuxSessionReference?,
                             receipts: [AgentIntakeReceipt], parents: [Int32: ProcessIdentity],
                             candidateSessionsForProcess: Set<String> = []) -> AgentIntakeReceipt? {
        let matches = receipts.filter { receipt in
            guard receipt.phase != "blocked" else { return false }
            guard receipt.cwd.hasPrefix("/") else { return false }
            if let exact = receipt.sessionID, exact.lowercased() != process.sessionID.lowercased() { return false }
            // A provider can own a parent and several child threads in one PID.
            // Process/pane identity alone cannot select the launch's root UUID.
            if candidateSessionsForProcess.count > 1 && receipt.sessionID == nil { return false }
            guard let reference = receipt.reference else { return false }
            return reference == tmux
        }
        _ = parents // Retained for source compatibility with older callers.
        return matches.count == 1 ? matches[0] : nil
    }

    public struct ProcessIdentity: Sendable {
        public let parent: Int32
        public let startedAt: String
        public init(parent: Int32, startedAt: String) { self.parent = parent; self.startedAt = startedAt }
    }

    public static func processParents(runner: any ProcessRunning = FoundationProcessRunner()) async throws -> [Int32: ProcessIdentity] {
        let result = try await runner.run(.init(executable: "/bin/ps", arguments: ["-axo", "pid=,ppid=,lstart="], timeoutSeconds: 10))
        guard result.succeeded else { throw TaskContextError.commandFailed("Could not inspect launch process ancestry.") }
        return Dictionary(result.standardOutput.split(separator: "\n").compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 3, let pid = Int32(fields[0]), let parent = Int32(fields[1]) else { return nil }
            return (pid, ProcessIdentity(parent: parent, startedAt: fields.dropFirst(2).joined(separator: " ")))
        }, uniquingKeysWith: { _, last in last })
    }

    public static func resolve(_ receipt: AgentIntakeReceipt, sessionID: String, root: URL) throws {
        guard UUID(uuidString: sessionID) != nil else { throw TaskContextError.invalidIdentifier }
        let directory = root.appendingPathComponent("tracking/resolutions")
        guard (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw TaskContextError.commandFailed("Tracking resolution storage is redirected.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent(receipt.launchID + ".json")
        let data = try JSONSerialization.data(withJSONObject: ["launchID": receipt.launchID, "sessionID": sessionID.lowercased()], options: .sortedKeys)
        if let existing = try? Data(contentsOf: path), existing != data {
            throw TaskContextError.commandFailed("This launch already has a different resolved identity; retained for review.")
        }
        if (try? Data(contentsOf: path)) != data {
            try data.write(to: path, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        }
    }

    public static func unresolved(root: URL) -> [AgentIntakeReceipt] {
        load(root: root).filter { !isResolved($0, root: root) }
    }

    private static func isResolved(_ receipt: AgentIntakeReceipt, root: URL) -> Bool {
        let path = root.appendingPathComponent("tracking/resolutions/\(receipt.launchID).json")
        guard let data = try? Data(contentsOf: path),
            let value = try? JSONSerialization.jsonObject(with: data) as? [String: String],
            value["launchID"] == receipt.launchID,
            value["sessionID"].flatMap(UUID.init(uuidString:)) != nil else { return false }
        return true
    }

    public static func pending(root: URL) -> [ExternalAgentRegistration] {
        unresolved(root: root).filter { !$0.isTerminal }.map(\.pendingRegistration)
    }
}
