import Darwin
import Foundation

/// Reaches agents through their managed tmux panes, the way `play` does: a
/// live pane gets the text typed in, a closed one reopens on the saved
/// conversation with the text as its prompt.
public struct TmuxDecisionAgentControl: DecisionAgentControlling {
    public let root: URL
    /// The `focus-queue-session` binary a deferred restart runs.
    public let sessionExecutable: String?
    /// Seconds a deferred restart waits, so the calling agent's command can return first.
    public static let deferredDelay = 3

    public init(root: URL, sessionExecutable: String? = nil) {
        self.root = root
        self.sessionExecutable = sessionExecutable
    }

    static func configuration(root: URL) -> AppConfiguration {
        let url = root.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url),
              let configuration = try? JSONDecoder().decode(AppConfiguration.self, from: data) else {
            return SetupEnvironment.starter(supportDirectory: root)
        }
        return configuration
    }

    public func deliver(_ text: String, taskID: String, agentID: String) async throws -> String {
        let store = TaskContextStore(root: root)
        let configuration = Self.configuration(root: root)
        guard let executable = configuration.tmuxExecutable ?? SetupEnvironment.executable("tmux") else {
            throw TmuxError.unavailable("Install tmux on this host, then choose its executable in setup.")
        }
        let context = try await store.load(ticketID: taskID)
        let agent = context?.subtasks.first { $0.id == agentID }
        let bypass = agent.map { configuration.bypassesPermissions(for: $0.provider, taskOverride: context?.bypassPermissions) } ?? false
        let noDaemon = agent?.provider == .codex ? (await CodexCatalog.load()?.supportsNoDaemon ?? true) : true
        let (updated, outcome) = try await AgentPauseController(store: store).play(
            ticketID: taskID, subtaskID: agentID, prompt: text, supportDirectory: root, tmuxExecutable: executable,
            usageBarEnabled: configuration.agentUsageBarEnabled, codexSupportsNoDaemon: noDaemon,
            bypassPermissions: bypass,
            isRunningElsewhere: { provider, sessionID in
                try await WezTermController().locateProviderProcess(provider: provider, sessionID: sessionID) != nil
            })
        _ = try? await DurableLibraryStore(root: root).reconcile(contexts: [updated])
        return outcome == .sent ? "sent" : "reopened"
    }

    public func restart(taskID: String, agentID: String, provider: AgentProvider, sessionID: String?,
                        forkNatively: Bool, prompt: String, deferred: Bool) async throws -> String {
        if deferred {
            guard let sessionExecutable else {
                throw DecisionTreeError.notAllowed("No focus-queue-session executable is known for a deferred restart.")
            }
            try Self.spawnDetached(
                sessionExecutable,
                arguments: ["decision", "restart", taskID, agentID, "--delay", String(Self.deferredDelay)],
                environment: Self.detachedEnvironment(root: root),
                log: try DecisionTreeStore(root: root).directory(taskID: taskID).appendingPathComponent("restart.log"))
            return "scheduled"
        }
        try await stopPane(taskID: taskID, agentID: agentID)
        return try await deliver(prompt, taskID: taskID, agentID: agentID)
    }

    /// Closes the agent's managed pane so `play` reopens it on the recorded session.
    func stopPane(taskID: String, agentID: String) async throws {
        guard let context = try await TaskContextStore(root: root).load(ticketID: taskID),
              let agent = context.subtasks.first(where: { $0.id == agentID }) else {
            throw TaskContextError.missingSubtask(agentID)
        }
        guard let reference = agent.tmux else {
            throw AgentPauseController.PauseError.noManagedPane(agent.title)
        }
        try await TmuxController().stop(reference)
    }

    /// The environment of a detached restart: the caller's, minus the identity
    /// and tmux variables of the agent pane it leaves behind.
    static func detachedEnvironment(root: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in ["FOCUS_QUEUE_SUBTASK_ID", "FOCUS_QUEUE_TASK_ID", "TMUX", "TMUX_PANE", "CLAUDE_CODE_SESSION_ID",
                    "FOCUS_QUEUE_AGENT_CONTEXT"] {
            environment.removeValue(forKey: key)
        }
        environment["FOCUS_QUEUE_SUPPORT_DIR"] = root.path
        return environment
    }

    /// Starts a process in its own session, so closing the agent's pane cannot hang it up.
    static func spawnDetached(_ executable: String, arguments: [String], environment: [String: String], log: URL) throws {
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, log.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        posix_spawn_file_actions_addopen(&actions, 2, log.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        guard status == 0 else {
            throw DecisionTreeError.notAllowed("Could not start the deferred restart: \(String(cString: strerror(status)))")
        }
    }
}
