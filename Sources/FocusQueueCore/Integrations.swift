import Foundation

enum WorkerFailureDiagnostics {
    static func knownDetail(from result: ProcessResult) -> String? {
        let raw = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? result.standardOutput
            : result.standardError
        let normalized = raw.lowercased()
        if normalized.contains("mail_reader_busy") || normalized.contains("mail reader is busy") {
            return "the Mail reader is busy with another request. The current request will continue; retry after it finishes"
        }
        if normalized.contains("mail_reader_timeout") || normalized.contains("mail reader timed out") {
            return "the protected Mail reader timed out. Confirm the configured mail provider is available, then retry"
        }
        if normalized.contains("gmail_authorization_required") {
            return "Gmail authorization expired or is missing. Run focus-mail authorize, then retry"
        }
        if normalized.contains("gmail_permission_denied") {
            return "Gmail denied the read-only request. Reauthorize the configured account and confirm Gmail API access"
        }
        if normalized.contains("gmail_rate_limited") {
            return "Gmail temporarily rate-limited the connector. Retry after a short delay"
        }
        if normalized.contains("gmail_account_mismatch") {
            return "the authorized Gmail account does not match the configured emailAddress"
        }
        if normalized.contains("gmail_oauth_client") {
            return "the Gmail Desktop-app OAuth client is missing, invalid, or not private"
        }
        if normalized.contains("gmail_network_failed") {
            return "the Gmail API could not be reached. Check the network connection and retry"
        }
        if normalized.contains("mail_permission_required")
            || normalized.contains("not authorized to send apple events")
            || normalized.contains("-1743") {
            return "Mail access needs approval for ECC Focus Mail Reader > Mail in System Settings > Privacy & Security > Automation. Older applet and python entries are separate identities"
        }
        if normalized.contains("mailbox_not_configured") || normalized.contains("mailbox is not configured") {
            return "the requested mailbox is outside the configured Mail scope. Choose a configured mailbox or update emailMailboxes in ingestion settings, then retry"
        }
        if normalized.contains("mail_account_unavailable") {
            return "the configured account is unavailable in Apple Mail. Confirm its address and enabled status, then retry"
        }
        if normalized.contains("mailbox_unavailable") {
            return "the configured mailboxes were not found in Apple Mail. Review the mailbox names in ingestion settings, then retry"
        }
        if normalized.contains("mail_runtime_permission_required") || normalized.contains("operation not permitted") {
            return "the worker was denied access to a local process or file. Review the private diagnostic log for the blocked resource"
        }
        if normalized.contains("mail_reader_not_installed")
            || normalized.contains("mail reader app is not installed") {
            return "the protected Mail reader is missing. Reinstall Focus Queue, then retry"
        }
        if normalized.contains("classification failed")
            || normalized.contains("no-tools")
            || normalized.contains("classifier manifest")
            || normalized.contains("rejected the required no-tools controls") {
            return "the message classifier failed its safety or compatibility check. Update Focus Queue or Codex, then retry"
        }
        if normalized.contains("missing ingestion settings") || normalized.contains("configuration") {
            return "the worker configuration is incomplete or invalid. Review its settings, then retry"
        }
        return nil
    }

    static func detail(from result: ProcessResult) -> String {
        knownDetail(from: result)
            ?? "the worker exited with code \(result.exitCode). See the private diagnostic log for details"
    }
}

public enum DailyReportAutomation {
    public struct Presentation: Equatable, Sendable {
        public let message: String
        public let isError: Bool

        public init(message: String, isError: Bool) {
            self.message = message
            self.isError = isError
        }
    }

    public static func arguments(
        scriptPath: String,
        configurationPath: String,
        runtimePath: String,
        request: DailyReportRunRequest,
        agentProvider: AgentProvider? = nil,
        agentModel: String? = nil,
        agentEffort: String? = nil
    ) -> [String] {
        var arguments = [
            scriptPath,
            "run",
            "--config", configurationPath,
            "--runtime", runtimePath,
            "--trigger", request.trigger.rawValue,
        ]
        if request.comprehensive {
            arguments.append("--comprehensive")
        } else {
            for platform in request.platforms.sorted(by: { $0.rawValue < $1.rawValue }) {
                arguments.append(contentsOf: ["--platform", platform.rawValue])
            }
        }
        if request.recheck {
            arguments.append("--recheck")
        }
        if let agentProvider {
            arguments.append(contentsOf: ["--agent-provider", agentProvider.rawValue])
        }
        if let agentModel, !agentModel.isEmpty {
            arguments.append(contentsOf: ["--agent-model", agentModel])
        }
        if let agentEffort, !agentEffort.isEmpty {
            arguments.append(contentsOf: ["--agent-effort", agentEffort])
        }
        return arguments
    }

    public static func presentation(
        for result: ProcessResult,
        hasMatchingReport: Bool
    ) -> Presentation {
        if result.timedOut {
            return Presentation(
                message: "The daily report timed out after 15 minutes. It will retry automatically; any completed partial report remains available.",
                isError: true
            )
        }
        if [0, 2].contains(result.exitCode), !hasMatchingReport {
            return Presentation(
                message: "Daily report receipt validation failed. It will retry automatically; the prior report remains available.",
                isError: true
            )
        }
        if result.exitCode == 0 {
            return Presentation(message: "Daily report completed.", isError: false)
        }
        if result.exitCode == 2 {
            if let detail = WorkerFailureDiagnostics.knownDetail(from: result) {
                return Presentation(
                    message: "Daily report completed with partial platform coverage: \(detail). It will retry automatically.",
                    isError: true
                )
            }
            return Presentation(
                message: "Daily report completed with partial platform coverage and will retry automatically.",
                isError: true
            )
        }
        let detail = safeDiagnosticDetail(from: result)
        return Presentation(
            message: "Daily report failed: \(detail). It will retry automatically.",
            isError: true
        )
    }

    private static func safeDiagnosticDetail(from result: ProcessResult) -> String {
        WorkerFailureDiagnostics.detail(from: result)
    }
}

public struct WezTermPane: Codable, Equatable, Sendable {
    public let windowID: Int
    public let tabID: Int?
    public let paneID: Int
    public let cwd: String
    public let isActive: Bool?
    public let title: String?
    public let tabTitle: String?
    public let windowTitle: String?
    public let ttyName: String?
    /// Pane numbers are scoped to a mux, never globally unique on this Mac.
    public var socketPath: String?

    public init(
        windowID: Int,
        tabID: Int? = nil,
        paneID: Int,
        cwd: String,
        isActive: Bool? = nil,
        title: String? = nil,
        tabTitle: String? = nil,
        windowTitle: String? = nil,
        ttyName: String? = nil,
        socketPath: String? = nil
    ) {
        self.windowID = windowID
        self.tabID = tabID
        self.paneID = paneID
        self.cwd = cwd
        self.isActive = isActive
        self.title = title
        self.tabTitle = tabTitle
        self.windowTitle = windowTitle
        self.ttyName = ttyName
        self.socketPath = socketPath
    }

    private enum CodingKeys: String, CodingKey {
        case windowID = "window_id"
        case tabID = "tab_id"
        case paneID = "pane_id"
        case cwd
        case isActive = "is_active"
        case title
        case tabTitle = "tab_title"
        case windowTitle = "window_title"
        case ttyName = "tty_name"
        case socketPath = "focus_queue_socket_path"
    }
}

public struct RunningAgentSession: Identifiable, Equatable, Sendable {
    public var id: String { "\(provider.rawValue):\(sessionID):\(pane.paneID)" }
    public let provider: AgentProvider
    public let sessionID: String
    public let parentSessionID: String?
    public let isSubagent: Bool
    public let promptHint: String?
    public let workingDirectory: String
    public let tabTitle: String
    public let pane: WezTermPane

    public init(
        provider: AgentProvider,
        sessionID: String,
        parentSessionID: String? = nil,
        isSubagent: Bool = false,
        promptHint: String? = nil,
        workingDirectory: String,
        tabTitle: String,
        pane: WezTermPane
    ) {
        self.provider = provider
        self.sessionID = sessionID
        self.parentSessionID = parentSessionID
        self.isSubagent = isSubagent
        self.promptHint = promptHint
        self.workingDirectory = workingDirectory
        self.tabTitle = tabTitle
        self.pane = pane
    }
}

public struct KnownProviderProcess: Sendable, Equatable {
    public let provider: AgentProvider
    public let sessionID: String
    public let parentSessionID: String?
    public let isSubagent: Bool
    public let promptHint: String?
    public let processID: Int32
    public let tty: String?
    public let cwd: String

    public init(provider: AgentProvider, sessionID: String, parentSessionID: String? = nil,
                isSubagent: Bool = false, promptHint: String? = nil,
                processID: Int32, tty: String?, cwd: String) {
        self.provider = provider; self.sessionID = sessionID; self.processID = processID
        self.parentSessionID = parentSessionID; self.isSubagent = isSubagent
        self.promptHint = promptHint; self.tty = tty; self.cwd = cwd
    }
}

/// A live provider process whose session identity could not be verified.
/// Ownership checks must fail closed only when one of these could plausibly
/// own the requested session; unrelated processes never block a safe resume.
public struct UnresolvedProviderProcess: Sendable, Equatable {
    public let provider: AgentProvider
    public let processID: Int32
    public let tty: String?
    public let cwd: String?

    public init(provider: AgentProvider, processID: Int32, tty: String?, cwd: String?) {
        self.provider = provider
        self.processID = processID
        self.tty = tty
        self.cwd = cwd
    }
}

public struct ProviderProcessScan: Sendable, Equatable {
    public let resolved: [KnownProviderProcess]
    public let unresolved: [UnresolvedProviderProcess]

    public init(resolved: [KnownProviderProcess], unresolved: [UnresolvedProviderProcess]) {
        self.resolved = resolved
        self.unresolved = unresolved
    }
}

public enum TerminalActionResult: Equatable, Sendable {
    case focused(paneID: Int)
    case spawned(paneID: Int?)
    case resumed(provider: AgentProvider, sessionID: String, paneID: Int?)

    public var paneID: Int? {
        switch self {
        case .focused(let paneID):
            paneID
        case .spawned(let paneID):
            paneID
        case .resumed(_, _, let paneID):
            paneID
        }
    }

    public var message: String {
        switch self {
        case .focused:
            "Focused the matching WezTerm pane."
        case .spawned:
            "Opened a new WezTerm window in the task directory."
        case .resumed(let provider, _, _):
            "Resumed the \(provider.displayName) session in a new WezTerm window."
        }
    }
}

public protocol WezTermControlling: Sendable {
    func focusPane(_ pane: WezTermPane, configuration: WezTermConfiguration) async throws

    func listAttachablePanes(
        configuration: WezTermConfiguration
    ) async throws -> [WezTermPane]

    func listRunningAgents(
        configuration: WezTermConfiguration
    ) async throws -> [RunningAgentSession]

    func attach(
        paneID: Int,
        tabTitle: String,
        windowTitle: String,
        configuration: WezTermConfiguration
    ) async throws

    func focusOrSpawn(
        directory: String,
        taskID: String,
        taskTitle: String,
        configuration: WezTermConfiguration
    ) async throws -> TerminalActionResult

    func focusOrResume(
        session: TaskAgentSession,
        taskID: String,
        configuration: WezTermConfiguration
    ) async throws -> TerminalActionResult

    func openManagedRuntime(
        _ tmux: TmuxSessionReference,
        taskID: String,
        provider: AgentProvider,
        taskTitle: String,
        configuration: WezTermConfiguration
    ) async throws -> TerminalActionResult

    func openManagedAgentRuntime(
        _ tmux: TmuxSessionReference,
        taskID: String,
        subtaskID: String,
        provider: AgentProvider,
        taskTitle: String,
        configuration: WezTermConfiguration
    ) async throws -> TerminalActionResult

    func labelTmuxClients(
        session: TaskAgentSession,
        configuration: WezTermConfiguration
    ) async throws

    func openAgentRuntime(_ subtask: TaskSubtask, taskID: String, taskTitle: String,
                          configuration: WezTermConfiguration) async throws -> TerminalActionResult

    func openDirectRuntime(
        paneID: Int,
        socketPath: String?,
        taskID: String,
        provider: AgentProvider,
        taskTitle: String,
        configuration: WezTermConfiguration
    ) async throws -> TerminalActionResult
}

public extension WezTermControlling {
    func labelTmuxClients(
        session: TaskAgentSession,
        configuration: WezTermConfiguration
    ) async throws {}

    func openAgentRuntime(_ subtask: TaskSubtask, taskID: String, taskTitle: String,
                          configuration: WezTermConfiguration) async throws -> TerminalActionResult {
        if let tmux = subtask.tmux {
            return try await openManagedAgentRuntime(tmux, taskID: taskID,
                subtaskID: subtask.id, provider: subtask.provider, taskTitle: taskTitle,
                configuration: configuration)
        }
        guard let paneID = subtask.terminalPaneID else { throw WezTermError.runtimeClosed }
        return try await openDirectRuntime(paneID: paneID, socketPath: subtask.terminalSocketPath,
            taskID: taskID, provider: subtask.provider, taskTitle: taskTitle,
            configuration: configuration)
    }

    func focusPane(_ pane: WezTermPane, configuration: WezTermConfiguration) async throws {
        throw WezTermError.actionFailed("This terminal integration does not support browsing panes.")
    }

    func openManagedRuntime(
        _ tmux: TmuxSessionReference,
        taskID: String,
        provider: AgentProvider,
        taskTitle: String,
        configuration: WezTermConfiguration
    ) async throws -> TerminalActionResult {
        throw TmuxError.unavailable("This terminal integration cannot open managed sessions.")
    }

    func openManagedAgentRuntime(
        _ tmux: TmuxSessionReference,
        taskID: String,
        subtaskID: String,
        provider: AgentProvider,
        taskTitle: String,
        configuration: WezTermConfiguration
    ) async throws -> TerminalActionResult {
        try await openManagedRuntime(
            tmux, taskID: taskID, provider: provider, taskTitle: taskTitle,
            configuration: configuration)
    }

    func openDirectRuntime(
        paneID: Int,
        socketPath: String?,
        taskID: String,
        provider: AgentProvider,
        taskTitle: String,
        configuration: WezTermConfiguration
    ) async throws -> TerminalActionResult {
        throw WezTermError.actionFailed("This terminal integration cannot open direct sessions.")
    }
}

public enum WezTermError: Error, LocalizedError {
    case invalidList(String)
    case actionFailed(String)
    case runtimeClosed

    public var errorDescription: String? {
        switch self {
        case .runtimeClosed: "The saved terminal has closed. Reopen the agent to resume its conversation."
        case .invalidList(let detail):
            "Could not read WezTerm panes: \(detail)"
        case .actionFailed(let detail):
            "WezTerm action failed: \(detail)"
        }
    }
}

public actor WezTermController: WezTermControlling {
    private let runner: any ProcessRunning
    private let candidateSockets: [String]?
    private let labelAttempts: Int
    private let claudeRootOverride: URL?
    private let codexRootOverride: URL?
    private let kimiRootOverride: URL?
    private static let processSnapshotTTL: TimeInterval = 3
    private var processSnapshots: [String: (fetchedAt: Date, result: ProcessResult)] = [:]
    private var processSnapshotTasks: [String: Task<ProcessResult, Error>] = [:]
    private var resolvedSockets: [String: String] = [:]

    public init(runner: any ProcessRunning = FoundationProcessRunner(), candidateSockets: [String]? = nil,
                verificationAttempts: Int = 10, claudeRoot: URL? = nil, codexRoot: URL? = nil,
                kimiRoot: URL? = nil) {
        self.runner = runner
        self.candidateSockets = candidateSockets
        self.labelAttempts = max(1, min(verificationAttempts, 10))
        self.claudeRootOverride = claudeRoot
        self.codexRootOverride = codexRoot
        self.kimiRootOverride = kimiRoot
    }

    private var claudeRoot: URL {
        claudeRootOverride
            ?? ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    }

    private var codexRoot: URL {
        codexRootOverride
            ?? ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    private var kimiRoot: URL {
        kimiRootOverride
            ?? ProcessInfo.processInfo.environment["KIMI_CODE_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kimi-code", isDirectory: true)
    }

    /// Reuses a socket that already answered this controller so refresh passes
    /// do not re-probe every candidate. A stale entry costs one bounded probe.
    func resolveConnection(
        configuration: WezTermConfiguration
    ) async throws -> (configuration: WezTermConfiguration, result: ProcessResult) {
        if configuration.socketPath == nil, let cached = resolvedSockets[configuration.executable] {
            var pinned = configuration
            pinned.socketPath = cached
            let probe = try await runner.run(ProcessSpecification(
                executable: pinned.executable, arguments: WezTermConnection.paneArguments(for: pinned),
                environment: pinned.cliEnvironment, timeoutSeconds: WezTermConnection.probeTimeoutSeconds))
            if WezTermConnection.hasValidPanes(probe) { return (pinned, probe) }
            resolvedSockets[configuration.executable] = nil
        }
        let connection = try await WezTermConnection.resolve(
            configuration: configuration, runner: runner, candidateSockets: candidateSockets)
        if configuration.socketPath == nil, WezTermConnection.hasValidPanes(connection.result),
           let socket = connection.configuration.socketPath {
            resolvedSockets[configuration.executable] = socket
        }
        return connection
    }

    /// Read-only process inspection shares one in-flight call and a few-second
    /// result so a refresh pass does not rerun identical ps/lsof invocations.
    private func runSharedProcess(_ specification: ProcessSpecification) async throws -> ProcessResult {
        let key = ([specification.executable] + specification.arguments).joined(separator: "\u{1F}")
        if let cached = processSnapshots[key],
           Date().timeIntervalSince(cached.fetchedAt) < Self.processSnapshotTTL {
            return cached.result
        }
        if let inFlight = processSnapshotTasks[key] { return try await inFlight.value }
        let task = Task { try await runner.run(specification) }
        processSnapshotTasks[key] = task
        do {
            let result = try await task.value
            processSnapshotTasks[key] = nil
            if result.succeeded {
                processSnapshots[key] = (Date(), result)
            }
            return result
        } catch {
            processSnapshotTasks[key] = nil
            throw error
        }
    }

    public func focusPane(_ pane: WezTermPane, configuration: WezTermConfiguration) async throws {
        var requested = configuration
        requested.socketPath = pane.socketPath ?? configuration.socketPath
        let connection = try await resolveConnection(configuration: requested)
        guard connection.result.succeeded else { throw WezTermError.actionFailed(Self.failureDetail(connection.result)) }
        if let socketPath = pane.socketPath, connection.configuration.socketPath != socketPath {
            throw WezTermError.actionFailed("The selected terminal connection is unavailable. Refresh the browser before choosing another pane.")
        }
        let current = try Self.decodePanes(from: connection.result)
        let configuration = connection.configuration
        guard current.contains(where: {
            $0.paneID == pane.paneID && $0.windowID == pane.windowID && $0.tabID == pane.tabID
                && $0.ttyName == pane.ttyName
        }) else {
            throw WezTermError.actionFailed("This terminal has closed or moved. Refresh the terminal browser.")
        }
        // Browsing must preserve task-owned labels and must never resume or spawn an agent.
        let result = try await runner.run(ProcessSpecification(executable: configuration.executable,
            arguments: ["cli", "activate-pane", "--pane-id", String(pane.paneID)],
            environment: configuration.cliEnvironment, timeoutSeconds: 10))
        guard result.succeeded else { throw WezTermError.actionFailed(Self.failureDetail(result)) }
        let raised = try await bringApplicationForward(named: configuration.applicationName)
        guard raised.succeeded else { throw WezTermError.actionFailed(Self.failureDetail(raised)) }
    }

    public func listAttachablePanes(
        configuration: WezTermConfiguration
    ) async throws -> [WezTermPane] {
        let connection = try await resolveConnection(configuration: configuration)
        let result = connection.result
        guard result.succeeded else {
            throw WezTermError.actionFailed(Self.failureDetail(result))
        }
        return Self.attachablePanes(in: try Self.decodePanes(from: result).map { pane in
            var located = pane; located.socketPath = connection.configuration.socketPath; return located
        })
    }

    public func listRunningAgents(
        configuration: WezTermConfiguration
    ) async throws -> [RunningAgentSession] {
        let connection = try await resolveConnection(configuration: configuration)
        let result = connection.result
        guard result.succeeded else {
            throw WezTermError.actionFailed(Self.failureDetail(result))
        }
        return try await discoverAgents(in: Self.decodePanes(from: result).map { pane in
            var located = pane; located.socketPath = connection.configuration.socketPath; return located
        })
    }

    public func attach(
        paneID: Int,
        tabTitle: String,
        windowTitle: String,
        configuration: WezTermConfiguration
    ) async throws {
        for arguments in [
            ["cli", "set-tab-title", "--pane-id", String(paneID), tabTitle],
            ["cli", "set-window-title", "--pane-id", String(paneID), windowTitle],
        ] {
            let result = try await runner.run(ProcessSpecification(
                executable: configuration.executable,
                arguments: arguments,
                environment: configuration.cliEnvironment,
                timeoutSeconds: 10
            ))
            guard result.succeeded else {
                throw WezTermError.actionFailed(Self.failureDetail(result))
            }
        }
    }

    public func focusOrSpawn(
        directory: String,
        taskID: String,
        taskTitle: String = "",
        configuration: WezTermConfiguration
    ) async throws -> TerminalActionResult {
        let listResult = try await listPanes(using: configuration)

        let panes: [WezTermPane]
        if listResult.succeeded {
            panes = try Self.decodePanes(from: listResult)
        } else {
            panes = []
        }

        if let pane = Self.bestMatchingPane(in: panes, directory: directory, taskID: taskID) {
            _ = try? await runner.run(ProcessSpecification(
                executable: configuration.executable,
                arguments: [
                    "cli", "set-tab-title", "--pane-id", String(pane.paneID),
                    AgentTerminalLabels.tabTitle(ticketID: taskID, paneID: pane.paneID, taskTitle: taskTitle),
                ],
                timeoutSeconds: 10
            ))
            _ = try? await runner.run(ProcessSpecification(
                executable: configuration.executable,
                arguments: [
                    "cli", "set-window-title", "--pane-id", String(pane.paneID),
                    AgentTerminalLabels.windowTitle(ticketID: taskID, taskTitle: taskTitle),
                ],
                timeoutSeconds: 10
            ))
            let activation = try await runner.run(ProcessSpecification(
                executable: configuration.executable,
                arguments: ["cli", "activate-pane", "--pane-id", String(pane.paneID)],
                timeoutSeconds: 10
            ))
            guard activation.succeeded else {
                throw WezTermError.actionFailed(Self.failureDetail(activation))
            }
            _ = try? await bringApplicationForward(named: configuration.applicationName)
            return .focused(paneID: pane.paneID)
        }

        if listResult.succeeded {
            let spawn = try await runner.run(ProcessSpecification(
                executable: configuration.executable,
                arguments: ["cli", "spawn", "--new-window", "--cwd", directory],
                timeoutSeconds: 15
            ))
            if spawn.succeeded {
                let paneID = Int(spawn.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))
                if let paneID {
                    _ = try? await runner.run(ProcessSpecification(
                        executable: configuration.executable,
                        arguments: [
                            "cli", "set-tab-title", "--pane-id", String(paneID),
                            AgentTerminalLabels.tabTitle(ticketID: taskID, paneID: paneID, taskTitle: taskTitle),
                        ],
                        timeoutSeconds: 10
                    ))
                    _ = try? await runner.run(ProcessSpecification(
                        executable: configuration.executable,
                        arguments: [
                            "cli", "set-window-title", "--pane-id", String(paneID),
                            AgentTerminalLabels.windowTitle(ticketID: taskID, taskTitle: taskTitle),
                        ],
                        timeoutSeconds: 10
                    ))
                    _ = try? await runner.run(ProcessSpecification(
                        executable: configuration.executable,
                        arguments: ["cli", "activate-pane", "--pane-id", String(paneID)],
                        timeoutSeconds: 10
                    ))
                }
                _ = try? await bringApplicationForward(named: configuration.applicationName)
                return .spawned(paneID: paneID)
            }
        }

        let fallback = try await runner.run(ProcessSpecification(
            executable: "/usr/bin/open",
            arguments: [
                "-na", configuration.applicationName, "--args", "start", "--always-new-process",
                "--cwd", directory,
            ],
            timeoutSeconds: 15
        ))
        guard fallback.succeeded else {
            throw WezTermError.actionFailed(Self.failureDetail(fallback))
        }
        return .spawned(paneID: nil)
    }

    /// Opens only the process that Focus Queue created and still owns in tmux.
    /// There is deliberately no provider transcript discovery or `resume` fallback.
    public func focusOrResume(
        session: TaskAgentSession,
        taskID: String,
        configuration: WezTermConfiguration
    ) async throws -> TerminalActionResult {
        guard session.ticketID.caseInsensitiveCompare(taskID) == .orderedSame,
              let tmux = session.tmux else {
            throw TmuxError.unavailable(
                "This entry predates managed sessions and cannot be reopened. Start a new, clearly named agent from Focus Queue.")
        }
        if let subtaskID = session.subtaskID {
            return try await openManagedAgentRuntime(
                tmux, taskID: taskID, subtaskID: subtaskID,
                provider: session.provider, taskTitle: session.taskTitle ?? "",
                configuration: configuration,
                workingDirectory: session.workingDirectory)
        }
        return try await openManagedRuntime(
            tmux, taskID: taskID, provider: session.provider,
            taskTitle: session.taskTitle ?? "", configuration: configuration,
            workingDirectory: session.workingDirectory)
    }

    public func openAgentRuntime(_ subtask: TaskSubtask, taskID: String,
                                 taskTitle: String = "",
                                 configuration: WezTermConfiguration) async throws -> TerminalActionResult {
        let title = subtask.sessionID.map {
            AgentTerminalLabels.tabTitle(ticketID: taskID, provider: subtask.provider,
                sessionID: $0, taskTitle: taskTitle)
        }
        if let tmux = subtask.tmux {
            return try await openManagedRuntime(tmux, taskID: taskID,
                subtaskID: subtask.id, provider: subtask.provider,
                configuration: configuration, tabTitle: title, taskTitle: taskTitle,
                workingDirectory: subtask.workspace?.path)
        }
        guard let paneID = subtask.terminalPaneID else { throw WezTermError.runtimeClosed }
        return try await openDirectRuntime(paneID: paneID, socketPath: subtask.terminalSocketPath,
            taskID: taskID, provider: subtask.provider, taskTitle: taskTitle,
            configuration: configuration, tabTitle: title)
    }

    public func openManagedRuntime(
        _ saved: TmuxSessionReference,
        taskID: String,
        provider: AgentProvider,
        taskTitle: String = "",
        configuration: WezTermConfiguration
    ) async throws -> TerminalActionResult {
        try await openManagedRuntime(saved, taskID: taskID, subtaskID: nil,
            provider: provider, configuration: configuration, tabTitle: nil,
            taskTitle: taskTitle, workingDirectory: nil)
    }

    public func openManagedAgentRuntime(
        _ saved: TmuxSessionReference,
        taskID: String,
        subtaskID: String,
        provider: AgentProvider,
        taskTitle: String = "",
        configuration: WezTermConfiguration
    ) async throws -> TerminalActionResult {
        try await openManagedRuntime(saved, taskID: taskID, subtaskID: subtaskID,
            provider: provider, configuration: configuration, tabTitle: nil,
            taskTitle: taskTitle, workingDirectory: nil)
    }

    private func openManagedAgentRuntime(
        _ saved: TmuxSessionReference,
        taskID: String,
        subtaskID: String,
        provider: AgentProvider,
        taskTitle: String,
        configuration: WezTermConfiguration,
        workingDirectory: String
    ) async throws -> TerminalActionResult {
        try await openManagedRuntime(saved, taskID: taskID, subtaskID: subtaskID,
            provider: provider, configuration: configuration, tabTitle: nil,
            taskTitle: taskTitle, workingDirectory: workingDirectory)
    }

    private func openManagedRuntime(
        _ saved: TmuxSessionReference,
        taskID: String,
        provider: AgentProvider,
        taskTitle: String,
        configuration: WezTermConfiguration,
        workingDirectory: String
    ) async throws -> TerminalActionResult {
        try await openManagedRuntime(saved, taskID: taskID, subtaskID: nil,
            provider: provider, configuration: configuration, tabTitle: nil,
            taskTitle: taskTitle, workingDirectory: workingDirectory)
    }

    private func openManagedRuntime(_ saved: TmuxSessionReference, taskID: String,
                                    subtaskID: String?, provider: AgentProvider,
                                    configuration: WezTermConfiguration, tabTitle: String?,
                                    taskTitle: String,
                                    workingDirectory: String?) async throws -> TerminalActionResult {
        if saved.name.hasPrefix("fq-task-"), saved.name != (try TmuxController.taskSessionName(taskID: taskID)) {
            throw TmuxError.changed
        }
        let runtime = TmuxController(runner: runner)
        let live: TmuxSessionReference
        if saved.name.hasPrefix("fq-task-") {
            guard let subtaskID else { throw TmuxError.changed }
            live = try await runtime.verifyAgent(
                saved, taskID: taskID, subtaskID: subtaskID, executable: saved.executable)
        } else {
            live = try await runtime.verify(saved)
        }
        // Externally created sessions can also have several panes or windows.
        // Selecting the saved identity is required before attaching its view.
        try await runtime.select(live)
        if configuration.terminalApp.requiresTmux {
            let result = try await ManagedTerminalLauncher.open(
                reference: live, configuration: configuration, runner: runner)
            _ = try await runtime.verify(live)
            return result
        }

        let directory = try await managedDirectory(
            workingDirectory, runtime: runtime, reference: live)
        let result = try await locateOrAttachManagedRuntime(
            live, taskID: taskID, directory: directory,
            taskTitle: taskTitle, configuration: configuration, runtime: runtime)
        // Opening a desktop view is not allowed to weaken runtime identity.
        // If the pane changed during launch, report that exact conflict.
        _ = try await runtime.verify(live)
        return result
    }

    private func managedDirectory(
        _ preferred: String?, runtime: TmuxController,
        reference: TmuxSessionReference
    ) async throws -> String {
        guard let preferred else { return try await runtime.workingDirectory(for: reference) }
        let path = URL(fileURLWithPath: preferred).standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard preferred.hasPrefix("/"), !preferred.contains("\0"),
              FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ProcessRunnerError.invalidWorkingDirectory(preferred)
        }
        return path
    }

    private func locateOrAttachManagedRuntime(
        _ reference: TmuxSessionReference,
        taskID: String,
        directory: String,
        taskTitle: String,
        configuration: WezTermConfiguration,
        runtime: TmuxController
    ) async throws -> TerminalActionResult {
        let connection = try await resolveConnection(configuration: configuration)
        guard !connection.result.timedOut else {
            throw WezTermError.actionFailed(
                "WezTerm lookup timed out. The managed agent remains available in tmux.")
        }

        if connection.result.succeeded {
            let pinned = connection.configuration
            let panes = try Self.decodePanes(from: connection.result)
            let clients = try await runtime.clientTTYs(for: reference)
            if let pane = Self.managedClientPane(in: panes, clientTTYs: clients, directory: directory) {
                try await focus(
                    pane: pane,
                    tabTitle: AgentTerminalLabels.managedTabTitle(ticketID: taskID, taskTitle: taskTitle),
                    windowTitle: AgentTerminalLabels.windowTitle(
                        ticketID: taskID.uppercased(), taskTitle: taskTitle),
                    configuration: pinned)
                return .focused(paneID: pane.paneID)
            }

            let command = try TmuxController.attachCommand(reference: reference)
            let spawn = try await runner.run(ProcessSpecification(
                executable: pinned.executable,
                arguments: ["cli", "spawn", "--new-window", "--domain-name", "local",
                    "--cwd", directory, "--"] + command,
                workingDirectory: directory, environment: pinned.cliEnvironment,
                timeoutSeconds: 15))
            guard spawn.succeeded,
                  let paneID = Int(spawn.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)),
                  paneID >= 0 else {
                throw WezTermError.actionFailed(
                    "The managed agent is still running, but WezTerm could not attach its exact tmux pane.")
            }
            if let pane = try await waitForManagedClient(
                paneID: paneID, reference: reference, directory: directory,
                configuration: pinned, runtime: runtime) {
                try await focus(
                    pane: pane,
                    tabTitle: AgentTerminalLabels.managedTabTitle(ticketID: taskID, taskTitle: taskTitle),
                    windowTitle: AgentTerminalLabels.windowTitle(
                        ticketID: taskID.uppercased(), taskTitle: taskTitle),
                    configuration: pinned)
                return .focused(paneID: paneID)
            }
            _ = try? await runner.run(ProcessSpecification(
                executable: pinned.executable,
                arguments: ["cli", "kill-pane", "--pane-id", String(paneID)],
                environment: pinned.cliEnvironment, timeoutSeconds: 10))
            throw WezTermError.actionFailed(
                "WezTerm did not attach the new view to the saved tmux pane, so Focus Queue closed that view.")
        }

        let previousClients = try await runtime.clientTTYs(for: reference)
        let command = try TmuxController.attachCommand(reference: reference)
        // `wezterm start` stays in the foreground for the window's lifetime, so
        // running it directly let the runner's deadline kill the new window.
        // Launch Services owns the GUI instead; only the attach is awaited.
        let started = try await runner.run(ProcessSpecification(
            executable: "/usr/bin/open",
            arguments: ["-na", configuration.applicationName, "--args", "--skip-config", "start",
                "--always-new-process", "--cwd", directory, "--"] + command,
            workingDirectory: directory, timeoutSeconds: 15))
        guard started.succeeded else {
            let detail = started.timedOut ? "the launch timed out" : Self.failureDetail(started)
            throw WezTermError.actionFailed(
                "The managed agent remains in tmux, but WezTerm could not attach it: \(detail)")
        }
        // A cold GUI start after a restart takes seconds, not milliseconds.
        for _ in 0..<100 {
            let clients = try await runtime.clientTTYs(for: reference)
            if !clients.subtracting(previousClients).isEmpty {
                return .spawned(paneID: nil)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw WezTermError.actionFailed(
            "WezTerm did not attach to the saved tmux pane. Focus Queue did not open a fallback shell.")
    }

    private func waitForManagedClient(
        paneID: Int,
        reference: TmuxSessionReference,
        directory: String,
        configuration: WezTermConfiguration,
        runtime: TmuxController
    ) async throws -> WezTermPane? {
        for _ in 0..<12 {
            let snapshot = try await listPanes(using: configuration)
            if snapshot.succeeded {
                let clients = try await runtime.clientTTYs(for: reference)
                let panes = try Self.decodePanes(from: snapshot)
                if let pane = panes.first(where: {
                    $0.paneID == paneID && $0.ttyName.map(clients.contains) == true
                }) { return pane }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    private static func managedClientPane(
        in panes: [WezTermPane], clientTTYs: Set<String>, directory: String
    ) -> WezTermPane? {
        panes.filter { $0.ttyName.map(clientTTYs.contains) == true }.sorted {
            let leftPath = standardizedPath(pathFromWezTermCWD($0.cwd))
            let rightPath = standardizedPath(pathFromWezTermCWD($1.cwd))
            let target = standardizedPath(directory)
            let left = ($0.isActive == true ? 0 : 1, leftPath == target ? 0 : 1, $0.paneID)
            let right = ($1.isActive == true ? 0 : 1, rightPath == target ? 0 : 1, $1.paneID)
            return left < right
        }.first
    }

    public func openDirectRuntime(
        paneID: Int,
        socketPath: String?,
        taskID: String,
        provider: AgentProvider,
        taskTitle: String = "",
        configuration: WezTermConfiguration
    ) async throws -> TerminalActionResult {
        try await openDirectRuntime(paneID: paneID, socketPath: socketPath, taskID: taskID,
            provider: provider, taskTitle: taskTitle, configuration: configuration, tabTitle: nil)
    }

    private func openDirectRuntime(paneID: Int, socketPath: String?, taskID: String, provider: AgentProvider,
                                   taskTitle: String,
                                   configuration: WezTermConfiguration, tabTitle: String?) async throws -> TerminalActionResult {
        guard paneID >= 0 else {
            throw WezTermError.actionFailed("The saved direct terminal identity is invalid.")
        }
        var requested = configuration
        requested.socketPath = socketPath ?? requested.socketPath
        let connection = try await resolveConnection(configuration: requested)
        guard connection.result.succeeded else {
            if !connection.result.timedOut,
               ["Connection refused", "No such file or directory", "no running GUI"].contains(where: connection.result.standardError.contains) {
                throw WezTermError.runtimeClosed
            }
            throw WezTermError.actionFailed("Could not inspect the saved terminal connection. Retry when WezTerm is available.")
        }
        if let socketPath, connection.configuration.socketPath != socketPath {
            throw WezTermError.runtimeClosed
        }
        let pane = try Self.decodePanes(from: connection.result).first { $0.paneID == paneID }
        guard let pane else {
            throw WezTermError.runtimeClosed
        }
        let directLabel = AgentTerminalLabels.readableTaskTitle(taskTitle, fallback: taskID.uppercased())
        try await focus(
            pane: pane,
            tabTitle: tabTitle ?? "\(directLabel) · \(provider.displayName) · direct",
            windowTitle: AgentTerminalLabels.windowTitle(
                ticketID: taskID.uppercased(), taskTitle: taskTitle),
            configuration: connection.configuration)
        return .focused(paneID: paneID)
    }

    public static func sessionID(
        for provider: AgentProvider,
        inLsofOutput output: String
    ) -> String? {
        sessionCandidates(for: provider, inLsofOutput: output).first?.sessionID
    }

    private static func sessionCandidates(
        for provider: AgentProvider,
        inLsofOutput output: String
    ) -> [AgentSessionCandidate] {
        var candidates: [AgentSessionCandidate] = []
        for rawLine in output.split(whereSeparator: \Character.isNewline) {
            let line = String(rawLine)
            guard line.first == "n" else { continue }
            let path = String(line.dropFirst())
            if provider == .codex,
               path.contains("/.codex/thread-writer-locks/"),
               path.hasSuffix(".lock") {
                let candidate = URL(fileURLWithPath: path)
                    .deletingPathExtension().lastPathComponent
                if UUID(uuidString: candidate) != nil {
                    let sessionID = candidate.lowercased()
                    if !candidates.contains(where: { $0.sessionID == sessionID && $0.isWriterLock }) {
                        candidates.append(AgentSessionCandidate(
                            sessionID: sessionID,
                            path: path,
                            isWriterLock: true
                        ))
                    }
                }
                continue
            }

            let isProviderTranscript = switch provider {
            case .codex:
                path.contains("/.codex/sessions/") || path.contains("/.codex/archived_sessions/")
            case .claude:
                path.contains("/.claude/projects/")
            case .kimi:
                path.contains("/.kimi-code/sessions/")
            }
            guard isProviderTranscript else { continue }
            if provider == .kimi {
                // A running kimi keeps its per-session files open; the session
                // directory name is the provider session ID.
                guard let component = path.split(separator: "/")
                    .map(String.init)
                    .first(where: { AgentProvider.kimi.isValidSessionID($0) })
                else { continue }
                if !candidates.contains(where: { $0.sessionID == component }) {
                    candidates.append(AgentSessionCandidate(
                        sessionID: component,
                        path: path,
                        isWriterLock: false
                    ))
                }
                continue
            }
            guard path.hasSuffix(".jsonl") else { continue }
            let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            let groups = stem.split(separator: "-")
            guard groups.count >= 5 else { continue }
            let candidate = groups.suffix(5).joined(separator: "-")
            if UUID(uuidString: candidate) != nil {
                let sessionID = candidate.lowercased()
                // Keep the writer lock alongside its transcript. The transcript
                // supplies root metadata; the lock supplies active ownership.
                if !candidates.contains(where: { $0.sessionID == sessionID && !$0.isWriterLock }) {
                    candidates.append(AgentSessionCandidate(
                        sessionID: sessionID,
                        path: path,
                        isWriterLock: false
                    ))
                }
            }
        }
        return candidates
    }

    public static func bestMatchingPane(
        in panes: [WezTermPane],
        directory: String,
        taskID: String? = nil
    ) -> WezTermPane? {
        let target = standardizedPath(directory)

        if let taskID, let canonicalTaskID = canonicalTaskID(taskID) {
            let tabLabeled = panes.filter {
                $0.tabTitle.flatMap(taskID(fromTerminalTitle:)) == canonicalTaskID
            }
            if let pane = bestCandidate(in: tabLabeled, target: target) { return pane }

            let windowLabeled = panes.filter { pane in
                [pane.windowTitle, pane.title]
                    .compactMap { $0.flatMap(taskID(fromTerminalTitle:)) }
                    .contains(canonicalTaskID)
            }
            if let pane = bestCandidate(in: windowLabeled, target: target) { return pane }
        }

        let candidates = panes.filter { pane in
            let panePath = standardizedPath(pathFromWezTermCWD(pane.cwd))
            return panePath == target || panePath.hasPrefix(target + "/")
        }
        guard !candidates.isEmpty else { return nil }

        let exact = candidates.filter {
            standardizedPath(pathFromWezTermCWD($0.cwd)) == target
        }
        if Set(exact.map(\.windowID)).count == 1,
           let pane = bestCandidate(in: exact, target: target) {
            return pane
        }
        guard Set(candidates.map(\.windowID)).count == 1 else { return nil }
        return bestCandidate(in: candidates, target: target)
    }

    private static func taskID(fromTerminalTitle title: String) -> String? {
        let components = title.split(separator: "·", omittingEmptySubsequences: false).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let first = components.first,
              let ticketID = canonicalTaskID(first)
        else { return nil }
        if components.count == 1 { return ticketID }

        if components.count == 2 {
            let fields = components[1].split(whereSeparator: \.isWhitespace)
            guard fields.count == 2,
                  fields[0].caseInsensitiveCompare("Tab") == .orderedSame,
                  fields[1].count <= 10,
                  fields[1].allSatisfy({ $0.isASCII && $0.isNumber }),
                  Int(fields[1]) != nil
            else { return nil }
            return ticketID
        }

        guard components.count == 3,
              ["codex", "claude"].contains(components[1].lowercased())
        else { return nil }
        let suffix = components[2]
        let isShortSessionSuffix = suffix.count == 6 && suffix.allSatisfy {
            $0.isASCII && $0.isHexDigit
        }
        return isShortSessionSuffix || UUID(uuidString: suffix) != nil ? ticketID : nil
    }

    private static func canonicalTaskID(_ value: String) -> String? {
        let normalized = value.uppercased()
        let components = normalized.split(
            separator: "-", maxSplits: 1, omittingEmptySubsequences: false
        )
        guard components.count == 2,
              components[0] == "ECC",
              (1...8).contains(components[1].count),
              components[1].allSatisfy({ $0.isASCII && $0.isNumber })
        else { return nil }
        return normalized
    }

    public static func attachablePanes(in panes: [WezTermPane]) -> [WezTermPane] {
        let grouped = Dictionary(grouping: panes) { pane in
            TabIdentity(windowID: pane.windowID, tabID: pane.tabID ?? pane.paneID)
        }
        return grouped.values.compactMap { tabPanes in
            tabPanes.sorted {
                (
                    $0.isActive == true ? 0 : 1,
                    $0.paneID
                ) < (
                    $1.isActive == true ? 0 : 1,
                    $1.paneID
                )
            }.first
        }.sorted {
            (
                $0.windowID,
                $0.tabID ?? $0.paneID,
                $0.paneID
            ) < (
                $1.windowID,
                $1.tabID ?? $1.paneID,
                $1.paneID
            )
        }
    }

    private static func bestCandidate(in panes: [WezTermPane], target: String) -> WezTermPane? {
        panes.sorted {
            let leftPath = standardizedPath(pathFromWezTermCWD($0.cwd))
            let rightPath = standardizedPath(pathFromWezTermCWD($1.cwd))
            return (
                leftPath == target ? 0 : 1,
                $0.isActive == true ? 0 : 1,
                $0.paneID
            ) < (
                rightPath == target ? 0 : 1,
                $1.isActive == true ? 0 : 1,
                $1.paneID
            )
        }.first
    }

    public func agents(onTTY tty: String, preferredSession: TaskAgentSession? = nil) async throws -> [RunningAgentSession] {
        try await discoverAgents(in: [WezTermPane(windowID: 0, paneID: 0, cwd: "", ttyName: tty)], preferredSession: preferredSession)
    }

    /// One process list and one lsof call cover terminals, tmux, and IDE shells.
    /// Multiple Codex writer locks are separate exact thread identities.
    public func locateProviderProcess(provider: AgentProvider, sessionID: String,
                                      attempts: Int = 4, retryDelay: Duration = .milliseconds(250)) async throws -> KnownProviderProcess? {
        // A process can release its writer lock before exiting. Reinspect that
        // transient state rather than asking the user to click Open repeatedly.
        // A failed/partial final scan never authorizes a second conversation.
        let limit = max(1, min(attempts, 4))
        for attempt in 0..<limit {
            try Task.checkCancellation()
            do {
                let scan = try await knownProviderProcesses(provider: provider, requireComplete: true)
                if let match = scan.resolved.first(where: {
                    $0.sessionID.caseInsensitiveCompare(sessionID) == .orderedSame
                }) { return match }
                // Only an unresolved process that could plausibly own the
                // requested session blocks a resume; unrelated identity-less
                // processes (another project's agent, a daemon) never do.
                let blockers = scan.unresolved.filter { unresolvedProcessCouldOwn($0, sessionID: sessionID) }
                guard !blockers.isEmpty else { return nil }
                guard attempt + 1 < limit else {
                    throw WezTermError.actionFailed("A provider process has no exact session identity yet. Retry after startup.")
                }
                try await Task.sleep(for: retryDelay)
            } catch is CancellationError { throw CancellationError() }
            catch {
                guard attempt + 1 < limit else { throw error }
                try await Task.sleep(for: retryDelay)
            }
        }
        throw WezTermError.actionFailed("Provider ownership could not be verified.")
    }

    /// A process with an unverified working directory, or of a provider whose
    /// ownership cannot be scoped to a project, always plausibly owns the
    /// target. A Claude process is scoped by its project directory: it can own
    /// the target only when the target transcript lives in the same project.
    /// A Codex process is scoped by the working directories its rollout
    /// records: it can own the target only when it runs in one of them.
    public func unresolvedProcessCouldOwn(_ process: UnresolvedProviderProcess, sessionID: String) -> Bool {
        guard let cwd = process.cwd else { return true }
        switch process.provider {
        case .claude:
            guard let projectDirectory = claudeProjectDirectory(containingTranscript: sessionID) else { return true }
            return Self.claudeProjectDirectoryName(forWorkingDirectory: cwd) == projectDirectory
        case .codex:
            let recorded = codexSessionWorkingDirectories(sessionID: sessionID)
            guard !recorded.isEmpty else { return true }
            let processPath = Self.standardizedPath(cwd, resolvingSymlinks: true)
            return recorded.contains { Self.standardizedPath($0, resolvingSymlinks: true) == processPath }
        case .kimi:
            guard let recorded = kimiWorkingDirectory(sessionID: sessionID) else { return true }
            return Self.standardizedPath(cwd, resolvingSymlinks: true)
                == Self.standardizedPath(recorded, resolvingSymlinks: true)
        }
    }

    /// Kimi Code closes its session files between turns. Its index maps a
    /// session to a work directory, but cannot distinguish two sessions in one
    /// directory, so those remain unresolved.
    private func kimiSessions(in cwd: String) -> [String] {
        guard let data = try? Data(contentsOf: kimiRoot.appendingPathComponent("session_index.jsonl")),
              data.count <= 4_000_000, let text = String(data: data, encoding: .utf8) else { return [] }
        let normalized = Self.standardizedPath(cwd, resolvingSymlinks: true)
        let sessionsRoot = kimiRoot.appendingPathComponent("sessions", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL.path + "/"
        var ids = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            guard let value = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = value["sessionId"] as? String, AgentProvider.kimi.isValidSessionID(id),
                  let workDir = value["workDir"] as? String,
                  Self.standardizedPath(workDir, resolvingSymlinks: true) == normalized,
                  let directory = value["sessionDir"] as? String else { continue }
            let session = URL(fileURLWithPath: directory).resolvingSymlinksInPath().standardizedFileURL
            guard session.path.hasPrefix(sessionsRoot), session.lastPathComponent == id,
                  let state = try? Data(contentsOf: session.appendingPathComponent("state.json")),
                  let record = try? JSONSerialization.jsonObject(with: state) as? [String: Any],
                  record["id"] as? String == id,
                  let stateCWD = record["cwd"] as? String,
                  Self.standardizedPath(stateCWD, resolvingSymlinks: true) == normalized,
                  record["archived"] as? Bool != true else { continue }
            ids.insert(id)
        }
        return ids.sorted()
    }

    private func kimiWorkingDirectory(sessionID: String) -> String? {
        guard let data = try? Data(contentsOf: kimiRoot.appendingPathComponent("session_index.jsonl")),
              data.count <= 4_000_000, let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            guard let value = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  value["sessionId"] as? String == sessionID,
                  let cwd = value["workDir"] as? String,
                  kimiSessions(in: cwd).contains(sessionID) else { continue }
            return cwd
        }
        return nil
    }

    /// Every working directory a Codex conversation has used, from its saved
    /// rollout. A resumed session may record additional directories in later
    /// turn contexts, so all of them identify plausible owners.
    private func codexSessionWorkingDirectories(sessionID: String) -> [String] {
        let target = sessionID.lowercased()
        guard UUID(uuidString: target) != nil else { return [] }
        for subdirectory in ["sessions", "archived_sessions"] {
            let root = codexRoot.appendingPathComponent(subdirectory, isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }
            for case let file as URL in enumerator
            where file.pathExtension == "jsonl" && file.lastPathComponent.lowercased().contains(target) {
                guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
                defer { try? handle.close() }
                guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8)
                else { return [] }
                var directories: [String] = []
                for line in text.split(whereSeparator: \Character.isNewline) {
                    guard line.contains("\"cwd\""),
                          let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                          let payload = record["payload"] as? [String: Any],
                          let cwd = payload["cwd"] as? String, cwd.hasPrefix("/"),
                          !directories.contains(cwd)
                    else { continue }
                    directories.append(cwd)
                }
                return directories
            }
        }
        return []
    }

    public func knownProviderProcesses(provider: AgentProvider? = nil,
                                       requireComplete: Bool = false) async throws -> ProviderProcessScan {
        let psSpec = ProcessSpecification(executable: "/bin/ps",
            arguments: ["-axo", "pid=,tty=,args="], timeoutSeconds: 3)
        // Ownership verification always inspects fresh processes; discovery
        // polls may reuse a snapshot taken moments ago.
        let processes = requireComplete
            ? try await runner.run(psSpec)
            : try await runSharedProcess(psSpec)
        guard processes.succeeded else { throw WezTermError.actionFailed("Could not inspect provider processes.") }
        let providers = Self.agentProcesses(in: processes.standardOutput).filter {
            !$0.isInfrastructure && (provider == nil || $0.provider == provider)
        }
        guard !providers.isEmpty else { return ProviderProcessScan(resolved: [], unresolved: []) }
        let lsofSpec = ProcessSpecification(executable: "/usr/sbin/lsof",
            arguments: ["-a", "-p", providers.map { String($0.pid) }.joined(separator: ","), "-Fpnf"], timeoutSeconds: 3)
        let files = requireComplete
            ? try await runner.run(lsofSpec)
            : try await runSharedProcess(lsofSpec)
        guard files.succeeded else { throw WezTermError.actionFailed("Provider ownership lookup failed; running state is unknown.") }
        var lines: [Int32: [String]] = [:]
        var directories: [Int32: String] = [:]
        var currentPID: Int32?
        var isCWD = false
        for line in files.standardOutput.split(separator: "\n").map(String.init) {
            if line.hasPrefix("p") { currentPID = Int32(line.dropFirst()); isCWD = false }
            else if let currentPID {
                if line.hasPrefix("f") { isCWD = line == "fcwd" }
                if line.hasPrefix("n"), isCWD { directories[currentPID] = String(line.dropFirst()) }
                lines[currentPID, default: []].append(line)
            }
        }
        var result: [KnownProviderProcess] = []
        var unresolved: [UnresolvedProviderProcess] = []
        var seen = Set<String>()
        var claudeDiskFallback: [(process: AgentProcess, cwd: String)] = []
        var kimiDiskFallback: [(process: AgentProcess, cwd: String)] = []
        for process in providers {
            let tty = process.tty == "??" ? nil : "/dev/" + process.tty
            guard let cwd = directories[process.pid], cwd.hasPrefix("/") else {
                unresolved.append(UnresolvedProviderProcess(
                    provider: process.provider, processID: process.pid, tty: tty, cwd: nil))
                continue
            }
            let candidates = Self.sessionCandidates(for: process.provider,
                inLsofOutput: (lines[process.pid] ?? []).joined(separator: "\n"))
            let ids: Set<String>
            if process.provider == .codex {
                // Reading an older transcript does not make this process its owner.
                ids = Set(candidates.filter(\.isWriterLock).map(\.sessionID))
            } else {
                let all = Set(candidates.map(\.sessionID))
                ids = all.count == 1 ? all : []
            }
            guard !ids.isEmpty else {
                // Claude 2.1+ does not hold its transcript open. A process with
                // no open candidates can still be identified from its project
                // directory on disk when it is the only candidate there.
                if process.provider == .claude, candidates.isEmpty {
                    claudeDiskFallback.append((process, cwd))
                } else if process.provider == .kimi, candidates.isEmpty {
                    kimiDiskFallback.append((process, cwd))
                } else {
                    unresolved.append(UnresolvedProviderProcess(
                        provider: process.provider, processID: process.pid, tty: tty, cwd: cwd))
                }
                continue
            }
            let codexMetadata = process.provider == .codex
                ? codexSessionMetadataByID(from: candidates) : [:]
            for sessionID in ids.sorted() where seen.insert(process.provider.rawValue + ":" + sessionID).inserted {
                let metadata = codexMetadata[sessionID]
                result.append(KnownProviderProcess(provider: process.provider, sessionID: sessionID,
                    parentSessionID: metadata?.parentSessionID,
                    isSubagent: metadata?.isSubagent == true,
                    promptHint: metadata?.promptHint,
                    processID: process.pid, tty: tty, cwd: cwd))
            }
        }
        let fallbackByProject = Dictionary(grouping: claudeDiskFallback) {
            Self.claudeProjectDirectoryName(forWorkingDirectory: $0.cwd)
        }
        for (projectDirectory, group) in fallbackByProject {
            // Two live processes in one project can each own a different
            // transcript; attributing the newest file to either would be a guess.
            guard group.count == 1, let entry = group.first,
                  let sessionID = latestClaudeTranscriptID(inProjectDirectory: projectDirectory)
            else {
                for entry in group {
                    unresolved.append(UnresolvedProviderProcess(
                        provider: entry.process.provider, processID: entry.process.pid,
                        tty: entry.process.tty == "??" ? nil : "/dev/" + entry.process.tty,
                        cwd: entry.cwd))
                }
                continue
            }
            if seen.insert(AgentProvider.claude.rawValue + ":" + sessionID).inserted {
                result.append(KnownProviderProcess(provider: .claude, sessionID: sessionID,
                    processID: entry.process.pid,
                    tty: entry.process.tty == "??" ? nil : "/dev/" + entry.process.tty,
                    cwd: entry.cwd))
            }
        }
        for (cwd, group) in Dictionary(grouping: kimiDiskFallback, by: { $0.cwd }) {
            let sessions = kimiSessions(in: cwd)
            guard group.count == 1, sessions.count == 1,
                  let entry = group.first, let sessionID = sessions.first else {
                unresolved += group.map { UnresolvedProviderProcess(provider: .kimi,
                    processID: $0.process.pid,
                    tty: $0.process.tty == "??" ? nil : "/dev/" + $0.process.tty,
                    cwd: $0.cwd) }
                continue
            }
            if seen.insert("kimi:" + sessionID).inserted {
                result.append(KnownProviderProcess(provider: .kimi, sessionID: sessionID,
                    processID: entry.process.pid,
                    tty: entry.process.tty == "??" ? nil : "/dev/" + entry.process.tty,
                    cwd: entry.cwd))
            }
        }
        return ProviderProcessScan(resolved: result, unresolved: unresolved)
    }

    /// Claude Code escapes a project directory name by replacing every
    /// non-alphanumeric character with a dash; runs are not collapsed.
    static func claudeProjectDirectoryName(forWorkingDirectory cwd: String) -> String {
        String(cwd.map { character in
            character.isASCII && (character.isLetter || character.isNumber) ? character : "-"
        })
    }

    private func latestClaudeTranscriptID(inProjectDirectory name: String) -> String? {
        let directory = claudeRoot
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let newest = files.filter { $0.pathExtension == "jsonl" }.max {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return (left, $0.lastPathComponent) < (right, $1.lastPathComponent)
        }
        guard let stem = newest?.deletingPathExtension().lastPathComponent,
              UUID(uuidString: stem) != nil
        else { return nil }
        return stem.lowercased()
    }

    private func claudeProjectDirectory(containingTranscript sessionID: String) -> String? {
        let root = claudeRoot.appendingPathComponent("projects", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return nil }
        let fileName = sessionID.lowercased() + ".jsonl"
        for entry in entries
        where (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            if FileManager.default.fileExists(atPath: entry.appendingPathComponent(fileName).path) {
                return entry.lastPathComponent
            }
        }
        return nil
    }

    public func labelTmuxClients(session: TaskAgentSession, configuration: WezTermConfiguration) async throws {
        guard let reference = session.tmux else { return }
        let taskTitle = await Self.resolvedTaskTitle(for: session)
        var lastError: (any Error)?
        for attempt in 0..<labelAttempts {
            do {
                let clients = try await TmuxController(runner: runner).clientTTYs(for: reference)
                if !clients.isEmpty {
                    let connection = try await resolveConnection(configuration: configuration)
                    if connection.result.succeeded {
                        let panes = try Self.decodePanes(from: connection.result).filter {
                            $0.ttyName.map(clients.contains) == true
                        }
                        if !panes.isEmpty {
                            let tabTitle = reference.name.hasPrefix("fq-task-")
                                ? AgentTerminalLabels.managedTabTitle(
                                    ticketID: session.ticketID, taskTitle: taskTitle)
                                : AgentTerminalLabels.tabTitle(
                                    ticketID: session.ticketID, provider: session.provider,
                                    sessionID: session.sessionID, taskTitle: taskTitle)
                            let windowTitle = AgentTerminalLabels.windowTitle(
                                ticketID: session.ticketID, taskTitle: taskTitle)
                            for pane in panes {
                                try await attach(paneID: pane.paneID,
                                    tabTitle: tabTitle,
                                    windowTitle: windowTitle,
                                    configuration: connection.configuration)
                            }
                            return
                        }
                    }
                }
            } catch { lastError = error }
            if attempt + 1 < labelAttempts { try await Task.sleep(for: .milliseconds(200)) }
        }
        if let lastError { throw lastError }
    }

    /// The session record carries the task title when the app enriched it from the
    /// task context; CLI-registered sessions recover it from the context store.
    private static func resolvedTaskTitle(for session: TaskAgentSession) async -> String {
        if let taskTitle = session.taskTitle,
           !taskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return taskTitle
        }
        guard let supportDirectory = session.supportDirectory else { return "" }
        let store = TaskContextStore(root: URL(fileURLWithPath: supportDirectory, isDirectory: true))
        return (try? await store.load(ticketID: session.ticketID)?.title) ?? ""
    }

    private func discoverAgents(
        in panes: [WezTermPane],
        preferredSession: TaskAgentSession? = nil
    ) async throws -> [RunningAgentSession] {
        let processResult = try await runSharedProcess(ProcessSpecification(
            executable: "/bin/ps",
            arguments: ["-axo", "pid=,tty=,args="],
            timeoutSeconds: 3
        ))
        guard processResult.succeeded else {
            throw WezTermError.actionFailed(Self.failureDetail(processResult))
        }

        let panesByTTY = Dictionary(
            uniqueKeysWithValues: panes.compactMap { pane -> (String, WezTermPane)? in
                guard let ttyName = pane.ttyName else { return nil }
                return (URL(fileURLWithPath: ttyName).lastPathComponent, pane)
            }
        )
        let paneProcesses = Self.agentProcesses(in: processResult.standardOutput).filter {
            !$0.isInfrastructure && panesByTTY[$0.tty] != nil
        }
        guard !paneProcesses.isEmpty else { return [] }

        let providersByPID = Dictionary(
            uniqueKeysWithValues: paneProcesses.map { ($0.pid, $0.provider) }
        )
        let processIDs = paneProcesses.map { String($0.pid) }.joined(separator: ",")
        let lsofResult = try await runSharedProcess(ProcessSpecification(
            executable: "/usr/sbin/lsof",
            arguments: ["-a", "-p", processIDs, "-Fn"],
            timeoutSeconds: 3
        ))
        guard lsofResult.succeeded else {
            throw WezTermError.actionFailed("Could not verify agent process ownership. No absence was assumed. \(Self.failureDetail(lsofResult))")
        }
        let sessionsByPID = sessionIdentitiesByProcess(
            inLsofOutput: lsofResult.standardOutput,
            providersByPID: providersByPID,
            preferredSession: preferredSession
        )

        var discovered: [RunningAgentSession] = []
        var seenSessions: Set<String> = []

        for process in paneProcesses {
            guard let pane = panesByTTY[process.tty] else { continue }
            for session in sessionsByPID[process.pid] ?? [] {
                let identity = "\(process.provider.rawValue):\(session.sessionID)"
                guard seenSessions.insert(identity).inserted else { continue }

                discovered.append(RunningAgentSession(
                    provider: process.provider,
                    sessionID: session.sessionID,
                    parentSessionID: session.parentSessionID,
                    isSubagent: session.isSubagent,
                    promptHint: session.promptHint,
                    workingDirectory: Self.pathFromWezTermCWD(pane.cwd),
                    tabTitle: Self.displayTitle(for: pane),
                    pane: pane
                ))
            }
        }

        // Claude 2.1+ does not hold its transcript open, so lsof yields no
        // session candidate for it. Recover the disk identity the resume
        // guard uses, restricted to processes in this pane listing; the
        // shared scan keeps multi-process projects ambiguous.
        let unidentified = paneProcesses.filter {
            ($0.provider == .claude || $0.provider == .kimi)
                && (sessionsByPID[$0.pid] ?? []).isEmpty
        }
        for provider in [AgentProvider.claude, .kimi]
        where unidentified.contains(where: { $0.provider == provider }) {
            guard let scan = try? await knownProviderProcesses(provider: provider) else { continue }
            let diskIdentityByPID = Dictionary(
                uniqueKeysWithValues: scan.resolved.map { ($0.processID, $0.sessionID) })
            for process in unidentified where process.provider == provider {
                guard let pane = panesByTTY[process.tty],
                      let sessionID = diskIdentityByPID[process.pid],
                      seenSessions.insert("\(process.provider.rawValue):\(sessionID)").inserted else { continue }
                discovered.append(RunningAgentSession(
                    provider: process.provider,
                    sessionID: sessionID,
                    workingDirectory: Self.pathFromWezTermCWD(pane.cwd),
                    tabTitle: Self.displayTitle(for: pane),
                    pane: pane
                ))
            }
        }

        return discovered.sorted {
            ($0.pane.windowID, $0.pane.tabID ?? $0.pane.paneID, $0.pane.paneID)
                < ($1.pane.windowID, $1.pane.tabID ?? $1.pane.paneID, $1.pane.paneID)
        }
    }

    private static func agentProcesses(in output: String) -> [AgentProcess] {
        output.split(whereSeparator: \Character.isNewline).compactMap { rawLine in
            let fields = rawLine.split(maxSplits: 2, whereSeparator: \Character.isWhitespace)
            guard fields.count == 3, let pid = Int32(fields[0]) else { return nil }
            let invocation = fields[2].split(whereSeparator: \Character.isWhitespace)
            guard let executable = invocation.first else { return nil }
            let executablePath = String(executable)
            let command = URL(fileURLWithPath: executablePath).lastPathComponent.lowercased()
            let provider: AgentProvider
            switch command {
            case "codex": provider = .codex
            case "claude": provider = .claude
            case "kimi", "kimi-code": provider = .kimi
            default: return nil
            }
            let arguments = invocation.dropFirst().map(String.init)
            return AgentProcess(pid: pid, tty: String(fields[1]), provider: provider,
                isInfrastructure: Self.isProviderInfrastructure(
                    provider: provider, executablePath: executablePath, arguments: arguments))
        }
    }

    /// Provider daemons share the interactive executable's name but never own a
    /// conversation identity, so they must not poison ownership scans. Codex
    /// 0.157+ runs a persistent `codex app-server` daemon from its package
    /// directory; both shapes are infrastructure, never interactive sessions.
    private static func isProviderInfrastructure(
        provider: AgentProvider, executablePath: String, arguments: [String]
    ) -> Bool {
        guard provider == .codex else { return false }
        if executablePath.contains("/.codex/packages/") { return true }
        return arguments.first == "app-server" || arguments.first == "daemon"
    }

    private func sessionIdentitiesByProcess(
        inLsofOutput output: String,
        providersByPID: [Int32: AgentProvider],
        preferredSession: TaskAgentSession?
    ) -> [Int32: [DiscoveredSessionIdentity]] {
        var currentPID: Int32?
        var outputByPID: [Int32: [String]] = [:]

        for rawLine in output.split(whereSeparator: \Character.isNewline) {
            let line = String(rawLine)
            if line.first == "p" {
                currentPID = Int32(line.dropFirst())
                continue
            }
            guard let currentPID else { continue }
            outputByPID[currentPID, default: []].append(line)
        }

        var sessions: [Int32: [DiscoveredSessionIdentity]] = [:]
        for (pid, lines) in outputByPID {
            guard let provider = providersByPID[pid] else { continue }
            let candidates = Self.sessionCandidates(
                for: provider,
                inLsofOutput: lines.joined(separator: "\n")
            )
            let identities = resolvedSessionIdentities(
                provider: provider,
                candidates: candidates,
                preferredSession: preferredSession
            )
            if !identities.isEmpty { sessions[pid] = identities }
        }
        return sessions
    }

    private func resolvedSessionIdentities(
        provider: AgentProvider,
        candidates: [AgentSessionCandidate],
        preferredSession: TaskAgentSession?
    ) -> [DiscoveredSessionIdentity] {
        let codexMetadata = provider == .codex
            ? codexSessionMetadataByID(from: candidates) : [:]
        if provider == .codex {
            let locks = candidates.filter(\.isWriterLock)
            if !locks.isEmpty {
                // An open historical transcript is evidence of reading, not
                // ownership. Only locked threads may identify this process.
                return Dictionary(grouping: locks, by: \.sessionID).keys.sorted().map { sessionID in
                    let metadata = codexMetadata[sessionID]
                    return DiscoveredSessionIdentity(
                        sessionID: sessionID, parentSessionID: metadata?.parentSessionID,
                        isSubagent: metadata?.isSubagent == true,
                        promptHint: metadata?.promptHint)
                }
            }

            let transcriptRoots = Set(candidates.compactMap {
                Self.canonicalCodexSessionID(for: $0, metadataBySessionID: codexMetadata)
            })
            if transcriptRoots.count > 1 { return [] }
            if let root = transcriptRoots.first {
                return [.init(sessionID: root, parentSessionID: nil, isSubagent: false,
                    promptHint: nil)]
            }
        }

        if let preferredSession,
           preferredSession.provider == provider {
            let preferredID = preferredSession.sessionID.lowercased()
            if candidates.contains(where: { $0.sessionID == preferredID }) {
                return [.init(sessionID: preferredID, parentSessionID: nil, isSubagent: false,
                    promptHint: nil)]
            }
            if provider == .codex,
               codexMetadata.values.contains(where: {
                   ($0.parentSessionID ?? $0.sessionID) == preferredID
               }) {
                return [.init(sessionID: preferredID, parentSessionID: nil, isSubagent: false,
                    promptHint: nil)]
            }
        }

        guard provider == .codex else {
            let sessionIDs = Set(candidates.map(\.sessionID))
            return sessionIDs.count == 1
                ? [.init(sessionID: sessionIDs.first!, parentSessionID: nil, isSubagent: false,
                    promptHint: nil)] : []
        }

        let transcriptRoots = Set(candidates.compactMap { candidate in
            candidate.isWriterLock ? nil : Self.canonicalCodexSessionID(
                for: candidate, metadataBySessionID: codexMetadata)
        })
        if transcriptRoots.count == 1 {
            return [.init(sessionID: transcriptRoots.first!, parentSessionID: nil,
                isSubagent: false, promptHint: nil)]
        }
        if transcriptRoots.count > 1 { return [] }

        let writerLockSessions = Set(
            candidates.filter(\.isWriterLock).map(\.sessionID)
        )
        return writerLockSessions.count == 1
            ? [.init(sessionID: writerLockSessions.first!, parentSessionID: nil,
                isSubagent: false, promptHint: nil)] : []
    }

    private static func canonicalCodexSessionID(
        for candidate: AgentSessionCandidate,
        metadataBySessionID: [String: CodexSessionMetadata]
    ) -> String? {
        guard let metadata = metadataBySessionID[candidate.sessionID] else { return nil }
        return metadata.parentSessionID ?? metadata.sessionID
    }

    private func codexSessionMetadataByID(
        from candidates: [AgentSessionCandidate]
    ) -> [String: CodexSessionMetadata] {
        var result: [String: CodexSessionMetadata] = [:]
        for candidate in candidates where !candidate.isWriterLock {
            guard result[candidate.sessionID] == nil,
                  let metadata = codexSessionMetadata(from: candidate)
            else { continue }
            result[metadata.sessionID] = metadata
        }
        return result
    }

    private func codexSessionMetadata(
        from candidate: AgentSessionCandidate
    ) -> CodexSessionMetadata? {
        guard !candidate.isWriterLock,
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: candidate.path))
        else { return nil }
        defer { try? handle.close() }
        guard let line = Self.firstLineData(from: handle),
              let object = try? JSONSerialization.jsonObject(with: line),
              let envelope = object as? [String: Any],
              envelope["type"] as? String == "session_meta",
              let payload = envelope["payload"] as? [String: Any]
        else { return nil }

        let sourceIsSubagent = (payload["source"] as? [String: Any])?["subagent"] != nil
            || payload["thread_source"] as? String == "subagent"
            || payload["parent_thread_id"] is String
        var sessionID: String?
        for key in ["id", "session_id"] {
            guard let value = payload[key] as? String,
                  UUID(uuidString: value) != nil
            else { continue }
            sessionID = value.lowercased()
            break
        }
        guard let sessionID else { return nil }
        var parentSessionID: String?
        if sourceIsSubagent {
            for key in ["parent_thread_id", "session_id"] {
                guard let value = payload[key] as? String,
                      UUID(uuidString: value) != nil,
                      value.caseInsensitiveCompare(sessionID) != .orderedSame
                else { continue }
                parentSessionID = value.lowercased()
                break
            }
        }
        return CodexSessionMetadata(
            sessionID: sessionID, parentSessionID: parentSessionID,
            isSubagent: sourceIsSubagent,
            promptHint: sourceIsSubagent ? Self.codexSubagentPromptHint(payload: payload) : nil)
    }

    private static func codexSubagentPromptHint(payload: [String: Any]) -> String? {
        guard let source = payload["source"] as? [String: Any],
              let subagent = source["subagent"] as? [String: Any]
        else { return nil }
        let threadSpawn = subagent["thread_spawn"] as? [String: Any]
        for container in [threadSpawn, subagent].compactMap({ $0 }) {
            for key in ["agent_path"] {
                guard var value = container[key] as? String else { continue }
                value = value.split(separator: "/").last.map(String.init) ?? value
                value = value.replacingOccurrences(of: "_", with: " ")
                    .replacingOccurrences(of: "-", with: " ")
                let normalized = value.split(whereSeparator: \.isWhitespace)
                    .joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty, !normalized.contains("\0") else { continue }
                return String(normalized.prefix(200))
            }
        }
        for container in [threadSpawn, subagent].compactMap({ $0 }) {
            for key in ["nickname", "agent_nickname"] {
                guard var value = container[key] as? String else { continue }
                value = value.replacingOccurrences(of: "_", with: " ")
                    .replacingOccurrences(of: "-", with: " ")
                let normalized = value.split(whereSeparator: \.isWhitespace)
                    .joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty, !normalized.contains("\0") else { continue }
                return String(normalized.prefix(200))
            }
        }
        return nil
    }

    private static func firstLineData(
        from handle: FileHandle,
        maximumBytes: Int = 2 * 1_024 * 1_024
    ) -> Data? {
        var line = Data()
        while line.count < maximumBytes {
            let bytesRemaining = maximumBytes - line.count
            guard let chunk = try? handle.read(upToCount: min(65_536, bytesRemaining)),
                  !chunk.isEmpty
            else { return line.isEmpty ? nil : line }
            if let newline = chunk.firstIndex(of: 0x0A) {
                line.append(contentsOf: chunk[..<newline])
                return line
            }
            line.append(chunk)
        }
        return nil
    }

    private static func displayTitle(for pane: WezTermPane) -> String {
        for value in [pane.tabTitle, pane.title, pane.windowTitle] {
            if let value {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return "Terminal tab"
    }

    private func focus(
        pane: WezTermPane,
        tabTitle: String,
        windowTitle: String,
        configuration: WezTermConfiguration
    ) async throws {
        try await labelAndActivate(
            paneID: pane.paneID,
            tabTitle: tabTitle,
            windowTitle: windowTitle,
            configuration: configuration
        )
        let revealed = try await runner.run(ProcessSpecification(
            executable: "/usr/bin/open",
            arguments: WezTermConnection.revealArguments(configuration: configuration),
            timeoutSeconds: 10))
        guard revealed.succeeded else {
            throw WezTermError.actionFailed("The terminal process is running, but its window could not open. \(Self.failureDetail(revealed))")
        }
    }

    private func labelAndActivate(
        paneID: Int,
        tabTitle: String,
        windowTitle: String,
        configuration: WezTermConfiguration
    ) async throws {
        for arguments in [
            ["cli", "set-tab-title", "--pane-id", String(paneID), tabTitle],
            ["cli", "activate-pane", "--pane-id", String(paneID)],
            ["cli", "set-window-title", "--pane-id", String(paneID), windowTitle],
        ] {
            let result = try await runner.run(ProcessSpecification(
                executable: configuration.executable,
                arguments: arguments,
                environment: configuration.cliEnvironment,
                timeoutSeconds: 10
            ))
            guard result.succeeded else {
                throw WezTermError.actionFailed(Self.failureDetail(result))
            }
        }
    }

    private func bringApplicationForward(named applicationName: String) async throws -> ProcessResult {
        try await runner.run(ProcessSpecification(
            executable: "/usr/bin/open",
            arguments: ["-a", applicationName],
            timeoutSeconds: 10
        ))
    }

    private func listPanes(using configuration: WezTermConfiguration) async throws -> ProcessResult {
        try await runner.run(ProcessSpecification(
            executable: configuration.executable,
            arguments: WezTermConnection.paneArguments(for: configuration),
            environment: configuration.cliEnvironment,
            timeoutSeconds: 10
        ))
    }

    private static func decodePanes(from result: ProcessResult) throws -> [WezTermPane] {
        guard let data = result.standardOutput.data(using: .utf8) else {
            throw WezTermError.invalidList("output was not UTF-8")
        }
        do {
            return try JSONDecoder().decode([WezTermPane].self, from: data)
        } catch {
            throw WezTermError.invalidList(error.localizedDescription)
        }
    }

    private static func pathFromWezTermCWD(_ cwd: String) -> String {
        guard let url = URL(string: cwd), url.isFileURL else { return cwd }
        return url.path
    }

    private static func standardizedPath(_ path: String, resolvingSymlinks: Bool = false) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return (resolvingSymlinks ? url.resolvingSymlinksInPath() : url).path
    }

    private static func failureDetail(_ result: ProcessResult) -> String {
        let detail = result.standardError.isEmpty ? result.standardOutput : result.standardError
        return detail.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct TabIdentity: Hashable {
    let windowID: Int
    let tabID: Int
}

private struct AgentProcess {
    let pid: Int32
    let tty: String
    let provider: AgentProvider
    let isInfrastructure: Bool
}

private struct AgentSessionCandidate {
    let sessionID: String
    let path: String
    let isWriterLock: Bool
}

private struct DiscoveredSessionIdentity {
    let sessionID: String
    let parentSessionID: String?
    let isSubagent: Bool
    let promptHint: String?
}

private struct CodexSessionMetadata {
    let sessionID: String
    let parentSessionID: String?
    let isSubagent: Bool
    let promptHint: String?
}

extension VerifierConfiguration {
    /// Environment for a headless Codex run, such as the pre-push review.
    public var agentEnvironment: [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var environment = ["PATH": "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"]
        if let directory = supportDirectory { environment["FOCUS_QUEUE_SUPPORT_DIR"] = directory }
        environment["FOCUS_QUEUE_PROJECT_ID"] = projectScopeID ?? ""
        return environment
    }
}

public protocol PullRequestQueueLoading: Sendable {
    func load(repository: String, closedSince: String) async throws -> PullRequestQueueSnapshot
}

public enum PullRequestQueueError: Error, LocalizedError {
    case commandFailed(String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let detail):
            "Could not refresh recurring PR progress: \(detail)"
        case .invalidResponse(let detail):
            "Could not read recurring PR progress: \(detail)"
        }
    }
}

public actor GitHubPullRequestQueueLoader: PullRequestQueueLoading {
    private let runner: any ProcessRunning
    private let executable: String

    public init(
        runner: any ProcessRunning = FoundationProcessRunner(),
        executable: String? = nil
    ) {
        self.runner = runner
        self.executable = executable ?? Self.defaultExecutable
    }

    public func load(
        repository: String,
        closedSince: String
    ) async throws -> PullRequestQueueSnapshot {
        let openResult = try await runner.run(ProcessSpecification(
            executable: executable,
            arguments: [
                "pr", "list",
                "--repo", repository,
                "--state", "open",
                "--limit", "1000",
                "--json", "number,title,url,state,isDraft,updatedAt"
            ],
            timeoutSeconds: 30,
            maximumOutputBytes: 1_000_000
        ))
        guard openResult.succeeded else {
            throw PullRequestQueueError.commandFailed(Self.failureDetail(openResult))
        }

        let resolvedResult = try await runner.run(ProcessSpecification(
            executable: executable,
            arguments: [
                "pr", "list",
                "--repo", repository,
                "--state", "closed",
                "--limit", "1000",
                "--search", "closed:>=\(closedSince)",
                "--json", "number,title,url,state,isDraft,mergedAt,closedAt"
            ],
            timeoutSeconds: 30,
            maximumOutputBytes: 1_000_000
        ))
        guard resolvedResult.succeeded else {
            throw PullRequestQueueError.commandFailed(Self.failureDetail(resolvedResult))
        }

        do {
            let decoder = JSONDecoder()
            let open = try decoder.decode(
                [PullRequestResolution].self,
                from: Data(openResult.standardOutput.utf8)
            )
            let resolved = try decoder.decode(
                [PullRequestResolution].self,
                from: Data(resolvedResult.standardOutput.utf8)
            )
            return PullRequestQueueSnapshot(
                repository: repository,
                openCount: open.count,
                resolvedThisWeek: resolved
            )
        } catch {
            throw PullRequestQueueError.invalidResponse(error.localizedDescription)
        }
    }

    private static var defaultExecutable: String {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
            .first(where: FileManager.default.isExecutableFile(atPath:))
            ?? "/opt/homebrew/bin/gh"
    }

    private static func failureDetail(_ result: ProcessResult) -> String {
        if result.timedOut { return "GitHub CLI timed out" }
        let output = result.standardError.isEmpty ? result.standardOutput : result.standardError
        let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? "GitHub CLI exited with code \(result.exitCode)" : detail
    }
}

public struct QueueAgentReply: Equatable, Sendable {
    public let message: String
    public let log: String

    public init(message: String, log: String) {
        self.message = message
        self.log = log
    }
}

public protocol QueueAgentChatting: Sendable {
    func send(
        message: String,
        dashboardPath: String,
        workspace: String,
        visibleOrder: [String],
        deferredTicketIDs: [String],
        configuration: VerifierConfiguration,
        model: String?,
        effort: String?
    ) async throws -> QueueAgentReply
    func reset(configuration: VerifierConfiguration) async throws
}

public enum QueueAgentError: Error, LocalizedError {
    case disabled(AgentProvider)
    case failed(AgentProvider, String)

    public var errorDescription: String? {
        switch self {
        case .disabled(let provider):
            "\(provider.displayName) Queue chat is disabled in config.json."
        case .failed(let provider, let detail):
            "\(provider.displayName) Queue chat failed: \(detail)"
        }
    }
}

/// Proof-receipt rules are identical for every provider's queue agent, so
/// verification lives in one shared verifier rather than with any harness.
struct QueueAgentEvidenceVerifier {
    // The Python connectors write proofs under the home folder's support
    // directory, so these follow the home folder rather than an override.
    private static let supportDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ECC Focus Queue", isDirectory: true)
    static let mailEvidenceURL = supportDirectory.appendingPathComponent("mail-proofs/mail-response.json")
    static let discordEvidenceURL = supportDirectory.appendingPathComponent("connector-proofs/discord-response.json")

    struct MailEvidenceReceipt: Decodable {
        struct Message: Decodable {
            let id: String
            let messageId: String
            let mailbox: String
            let receivedAt: String
        }

        let status: String
        let verified: Bool
        let operation: String
        let connector: String
        let account: String
        let retrievedAt: String
        let nonce: String
        let opened: Bool?
        let message: Message?
    }

    struct DiscordEvidenceReceipt: Decodable {
        struct Guild: Decodable {
            let id: String
            let name: String?
        }

        struct Channel: Decodable {
            let id: String
            let name: String
        }

        struct Message: Decodable {
            let id: String
            let channelId: String
            let channel: String
            let timestamp: String
            let url: String
        }

        let status: String
        let verified: Bool
        let operation: String
        let connector: String
        let retrievedAt: String
        let nonce: String
        let guild: Guild
        let message: Message?
        let inaccessibleChannels: [Channel]?
    }

    let files: any FileAccessing
    let provider: AgentProvider

    static func requiresMailEvidence(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return [
            "email", "e-mail", "mailbox", "inbox", "apple mail", "himalaya",
            "@ecc.tools", "message id", "message link", "recent message",
            "customer message", "customer response", "my response", "their response",
        ].contains { normalized.contains($0) }
    }

    static func requiredMailOperation(for message: String) -> String? {
        let normalized = message.lowercased()
        if normalized.contains("open") { return "open" }
        if ["read", "what did", "said", "wrote", "reply", "response", "content", "quote"]
            .contains(where: { normalized.contains($0) }) {
            return "read"
        }
        if ["status", "connected", "connection", "available", "working"]
            .contains(where: { normalized.contains($0) }) {
            return "status"
        }
        return "search"
    }

    static func requiresDiscordEvidence(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("discord") || normalized.contains("discord.com/channels/")
    }

    static func requiredDiscordOperation(for message: String) -> String? {
        let normalized = message.lowercased()
        if ["read", "what did", "said", "wrote", "content", "quote"]
            .contains(where: { normalized.contains($0) }) {
            return "read"
        }
        if ["search", "find", "latest", "recent", "check"]
            .contains(where: { normalized.contains($0) }) {
            return "search"
        }
        return nil
    }

    static func isBlockedMailResponse(_ output: String) -> Bool {
        let normalized = output.lowercased()
        return normalized.contains("blocked")
            && [
                "focus-mail", "mail reader", "mail connector", "verified connector",
                "operation not permitted", "timed out",
            ].contains(where: normalized.contains)
    }

    func verifyMailEvidence(
        in output: String,
        for message: String,
        requestStartedAt: Date
    ) throws -> String {
        defer { try? files.removeItem(at: Self.mailEvidenceURL) }
        let proofPrefix = "MAIL_PROOF:"
        let lines = output.components(separatedBy: .newlines)
        guard let proofLine = lines.last(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix(proofPrefix)
        }) else {
            throw QueueAgentError.failed(
                provider,
                "mail answer withheld because \(provider.displayName) did not provide current-turn verified mail evidence"
            )
        }
        let nonce = proofLine
            .trimmingCharacters(in: .whitespaces)
            .dropFirst(proofPrefix.count)
            .trimmingCharacters(in: .whitespaces)
        guard !nonce.isEmpty,
              let modifiedAt = try files.modificationDate(at: Self.mailEvidenceURL),
              modifiedAt >= requestStartedAt.addingTimeInterval(-1),
              let receipt = try? JSONDecoder().decode(
                MailEvidenceReceipt.self,
                from: files.read(from: Self.mailEvidenceURL)
              ),
              receipt.nonce == nonce,
              receipt.status == "ok",
              receipt.verified,
              receipt.connector == "ecc-focus-mail-reader",
              !receipt.account.isEmpty
        else {
            throw QueueAgentError.failed(
                provider,
                "mail answer withheld because its proof receipt was missing, stale, or invalid"
            )
        }
        if let requiredOperation = Self.requiredMailOperation(for: message),
           receipt.operation != requiredOperation {
            throw QueueAgentError.failed(
                provider,
                "mail answer withheld because \(provider.displayName) performed \(receipt.operation), not the required \(requiredOperation) operation"
            )
        }
        if receipt.operation == "open", receipt.opened != true {
            throw QueueAgentError.failed(
                provider,
                "mail answer withheld because Apple Mail did not confirm the open request"
            )
        }
        if ["read", "open"].contains(receipt.operation),
           (receipt.message?.id.isEmpty != false || receipt.message?.messageId.isEmpty != false) {
            throw QueueAgentError.failed(
                provider,
                "mail answer withheld because the read receipt lacked stable message identifiers"
            )
        }

        let answer = lines
            .filter { $0.trimmingCharacters(in: .whitespaces) != proofLine.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let verification: String
        if let mail = receipt.message {
            verification = "Verified mail evidence: \(receipt.account) · \(mail.mailbox) · \(mail.receivedAt) · \(mail.messageId) · retrieved \(receipt.retrievedAt)"
        } else {
            verification = "Verified mail evidence: \(receipt.account) · \(receipt.operation) · retrieved \(receipt.retrievedAt)"
        }
        return "\(answer)\n\n\(verification)"
    }

    func verifyDiscordEvidence(
        in output: String,
        for message: String,
        requestStartedAt: Date
    ) throws -> String {
        defer { try? files.removeItem(at: Self.discordEvidenceURL) }
        let proofPrefix = "DISCORD_PROOF:"
        let lines = output.components(separatedBy: .newlines)
        guard let proofLine = lines.last(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix(proofPrefix)
        }) else {
            throw QueueAgentError.failed(
                provider,
                "Discord answer withheld because \(provider.displayName) did not provide current-turn verified Discord evidence"
            )
        }
        let nonce = proofLine
            .trimmingCharacters(in: .whitespaces)
            .dropFirst(proofPrefix.count)
            .trimmingCharacters(in: .whitespaces)
        guard !nonce.isEmpty,
              let modifiedAt = try files.modificationDate(at: Self.discordEvidenceURL),
              modifiedAt >= requestStartedAt.addingTimeInterval(-1),
              let receipt = try? JSONDecoder().decode(
                DiscordEvidenceReceipt.self,
                from: files.read(from: Self.discordEvidenceURL)
              ),
              receipt.nonce == nonce,
              ["ok", "partial"].contains(receipt.status),
              receipt.verified,
              receipt.connector == "ecc-focus-discord-reader",
              !receipt.guild.id.isEmpty
        else {
            throw QueueAgentError.failed(
                provider,
                "Discord answer withheld because its proof receipt was missing, stale, or invalid"
            )
        }
        if let requiredOperation = Self.requiredDiscordOperation(for: message),
           receipt.operation != requiredOperation {
            throw QueueAgentError.failed(
                provider,
                "Discord answer withheld because \(provider.displayName) performed \(receipt.operation), not the required \(requiredOperation) operation"
            )
        }
        if receipt.operation == "read",
           (receipt.message?.id.isEmpty != false || receipt.message?.channelId.isEmpty != false) {
            throw QueueAgentError.failed(
                provider,
                "Discord answer withheld because the read receipt lacked stable message identifiers"
            )
        }

        let answer = lines
            .filter { $0.trimmingCharacters(in: .whitespaces) != proofLine.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let inaccessible = receipt.inaccessibleChannels ?? []
        let coverage: String
        if receipt.operation == "read", receipt.status == "partial" {
            coverage = "single-message read verified; server coverage partial; inaccessible: \(inaccessible.map(\.name).joined(separator: ", "))"
        } else if receipt.operation == "read" {
            coverage = "single-message read verified"
        } else if receipt.status == "partial" {
            coverage = "partial coverage; inaccessible: \(inaccessible.map(\.name).joined(separator: ", "))"
        } else {
            coverage = "all bot-visible channels readable"
        }
        let detail: String
        if let discordMessage = receipt.message {
            detail = "#\(discordMessage.channel) · \(discordMessage.timestamp) · \(discordMessage.id)"
        } else {
            detail = receipt.operation
        }
        return "\(answer)\n\nVerified Discord evidence: \(receipt.guild.name ?? receipt.guild.id) · \(detail) · \(coverage) · retrieved \(receipt.retrievedAt)"
    }
}

/// The queue-chat system prompt is provider-neutral except for its identity
/// line, so every provider enforces the same queue, project, and evidence rules.
public enum QueueAgentPrompt {
    /// Separates app-built context (snapshot, recap, document sources) from the
    /// user's own words, so evidence rules and timeouts react only to the request.
    public static let userRequestMarker = "\n\nUser request:\n"

    public static func userRequest(in message: String) -> String {
        guard let marker = message.range(of: userRequestMarker, options: .backwards) else { return message }
        return String(message[marker.upperBound...])
    }

    public static func build(
        provider: AgentProvider,
        message: String,
        dashboardPath: String,
        workspace: String,
        visibleOrder: [String],
        deferredTicketIDs: [String]
    ) -> String {
        let order = visibleOrder.isEmpty ? "none" : visibleOrder.joined(separator: ", ")
        let deferred = deferredTicketIDs.isEmpty
            ? "none"
            : deferredTicketIDs.joined(separator: ", ")
        // Connector contracts ride along only when the request needs them.
        let request = userRequest(in: message)
        let mailContract = QueueAgentEvidenceVerifier.requiresMailEvidence(request) ? Self.mailContract : ""
        let discordContract = QueueAgentEvidenceVerifier.requiresDiscordEvidence(request) ? Self.discordContract : ""
        return """
        You are the \(provider.displayName) Queue agent for Focus Queue.

        The user controls the local queue order. You are authorized to reorder tasks when the user requests it, including choosing an order when they ask you to prioritize the queue. Use `focus-queue-session queue list` to read the current order, then apply your chosen order with a single `focus-queue-session queue reorder <TASK-ID> [<TASK-ID> ...]` listing every visible task in the new order (omitted open tasks keep their relative order at the end), or make individual adjustments with `focus-queue-session queue move <TASK-ID> top|bottom` or `focus-queue-session queue move <TASK-ID> before|after <TARGET-ID>`. Moves and reorders are temporary adjustments to the current automatic sequence: the selected recent-activity, recent-interaction, recent-output, or triage mode remains active, and the adjustment expires when that automatic order changes. Pinned tasks always remain in their newest-pin-first top tier. Use `focus-queue-session queue pin <TASK-ID>` only when the user explicitly wants a task to stay at the top until it closes, and `focus-queue-session queue unpin <TASK-ID>` to remove that durable preference. Use `focus-queue-session queue reset` only when asked to discard a temporary adjustment. Run queue list afterward to verify the resulting order matches what you report; if it does not, fix it before replying. These commands save local presentation state on this Mac and the app refreshes automatically. New tasks enter according to the active automatic mode. Do not edit state.json, task context JSON, or the canonical dashboard to reorder or pin tasks.

        You can edit any task field the user can edit. Rename a task with `focus-queue-session task rename <TASK-ID> <new title>`. Change a task's canonical priority with `focus-queue-session task priority <TASK-ID> <critical|high|medium|low>`. Change a task's status with `focus-queue-session task status <TASK-ID> <status>`. These commands find the task across all configured project dashboards, save the change atomically, and the app refreshes automatically. Prefer them over hand-editing dashboards; only fall back to a direct dashboard edit for fields they do not cover. Never report a rename, priority, or status change as done unless the command succeeded in this turn.

        Projects are separate dashboards with their own workspace and queue order. When the user explicitly asks to create a project and move tasks into it, first run `focus-queue-session projects list`. Use the unambiguous lowercase hyphenated slug of the requested project name as its ID. An existing absolute workspace may be taken from the requested tasks only when they all name the same worktree; otherwise ask one concise clarification question. Require an unambiguous project name, source project, and exact task IDs. Then use `focus-queue-session projects create --id <id> --name <name> --workspace <absolute-path> --from <source-project-id> --task <TASK-ID> [--task <TASK-ID> ...]`. Run `focus-queue-session projects list` afterward and report a project creation only when the receipt and refreshed list verify it. Never substitute a category label or projectID field for a project. Never hand-edit config.json or dashboards to create or move a project. If any required value is ambiguous, ask one concise clarification question instead of guessing.

        Selected dashboard: \(dashboardPath)
        The central chat can read every configured project dashboard listed in the message, regardless of the UI selection. Read the requested project's dashboard or task context before answering about it. Never claim a project is inaccessible solely because another project is selected. Edits remain scoped to the selected dashboard. For an explicitly requested edit there, preserve projectID and every unknown field, use its adjacent hidden lock for an exclusive flock, re-read under the lock, and write atomically. New tasks use the selected project's ID, or the reserved Other project if unassigned. The queue ordering helper changes only the selected project's local order.
        Workspace: \(workspace)
        Current visible open-task order: \(order)
        Current local deferred task IDs: \(deferred)

        Answer clarifying questions from the relevant project dashboard and workspace. On explicit request, you may create a task with a unique ID using the existing schema, clarify task fields including taskType and doneWhen, add links, or update a task's central plan in the selected project. Edit the selected dashboard only when the user's message directly and unambiguously requests that exact change. Preserve the dashboard schema and existing ticket IDs. Do not resolve, cancel, or invent completion evidence. Do not turn a disagreement with local order into a canonical priority change unless the user explicitly asks for that canonical change. Keep the response concise and state any file change you made.

        Every task has durable context under the Focus Queue support directory's tasks/<ticket-id>/ folder. When the user message includes a Task scope and central plan path, restrict the turn to that task and read its plan before proposing changes. Keep the central plan bare: What/Why/How (one sentence each), Success criteria, a Progress checklist of what is actually done, and Context links to crucial evidence. If missing, create that outline. Keep decisions and rationale, configuration, detailed progress, checks, and handoffs in the adjacent agent-log.md; read relevant entries on demand instead of injecting the full log. Registered agents append with focus-queue-session log <ticket-id> <agent-id> "entry"; never invent an agent identity to log. Preserve historical plans until safely archived. Use focus-queue-session context <ticket-id> to read context and the helper's add/rename/progress/complete commands for subtask state instead of overwriting context.json. The helper defaults to the standard support directory; use FOCUS_QUEUE_SUPPORT_DIR when provided. Only record completed after evidence has been verified. Task types are task, long-running, subtask, and customer-concern. A customer concern needs the user's response/review before closure. Never send external messages without an explicit request. Worktree merging requires the task's explicit approval terms; leave cleanup to the host. A lightweight orchestrator maintains authorized task context and behavior, and answers questions; application-code changes and autonomous agent deployment require a separate user request.

        Each registered work item is one titled, briefly described record that may own its agent runtime, provider session, and immutable workspace. Do not create a second assignment row for the same launched agent. Legacy isAssignmentOnly and parentSubtaskID pairs remain readable and may be reconciled at review boundaries. A single provider conversation may be associated with additional legacy assignments using focus-queue-session associate <ticket-id> <agent-record-id> <subtask-id>. Retain mergedIntoSubtaskID aliases, launch locations, and history. Never copy one agent's runtime into another work item. Progress/result/attention reports describe agent activity; a finished response alone does not complete its work item.

        Truth is a hard operational invariant. Never claim or imply that you checked, searched, found, read, opened, sent, changed, or verified an external source unless a successful tool result in this turn proves that exact action. Earlier chat turns, memory, dashboard text, task links, and plausible inference are not current verification. Name the source actually checked. If a tool fails, state `blocked` and its exact error. If evidence is incomplete, state `unverified`. Never fill a missing fact with a likely answer.

        The host app owns terminal labels and progress UI. Do not call `tabname`, inspect unrelated configuration, or run setup commands. Call only the narrow source command needed for the user's request, plus workspace reads or explicitly requested dashboard edits.

        Keep each turn cheap. The task snapshot in the message is current app state the host read for this turn, so it counts as verified for task, agent, status, and session facts; answer from it directly when it covers the request, and name it as the source. Recent conversation is history, not verification. Otherwise make the fewest tool calls that answer it, combining related reads into one shell command. Use absolute paths in shell commands; the shell may not start in the workspace.
        \(mailContract)\(discordContract)
        User message follows between literal delimiters:
        <queue-user-message>
        \(message)
        </queue-user-message>
        """
    }

    /// Where the installer writes the focus-mail and focus-discord wrappers.
    private static let localBin = FileManager.default.homeDirectoryForCurrentUser.path + "/.local/bin"

    static let mailContract = """

        <mail-evidence-contract>
        For every question involving email, mail, an inbox, a sender, a customer message, or a message link, load the `ecc-focus-mail` skill and use `\(localBin)/focus-mail`. Use the provider selected in ingestion settings and do not use Himalaya. Search results are excerpts only: call `focus-mail read` before describing or quoting a message body. Call `focus-mail open` only when the user explicitly asks and the selected provider supports it. A mail claim is verified only when the current-turn result contains `status: ok`, `verified: true`, `connector: ecc-focus-mail-reader`, a nonempty `account`, and `retrievedAt`; read/open claims also require the stable message `id` and `messageId`, and open requires `opened: true`. Include account, mailbox, received time, and message ID when reporting a message as read.
        On every successful mail-related request, copy the exact `nonce` from the final successful `focus-mail` result into a standalone final line formatted exactly as `MAIL_PROOF: <nonce>`. Never invent or reuse a nonce. The app will withhold the entire mail answer unless that nonce matches a fresh local proof receipt. If the user asks what a message said, to read it, for its contents, response, reply, or a quote, the final operation must be `read`. If the user asks to open it, the final operation must be `open` with `opened: true`. If the user asks whether the connector is available or working, the final operation must be `status`. Every other mail or inbox check must end with `search`.
        </mail-evidence-contract>
        """

    static let discordContract = """

        <discord-evidence-contract>
        For every question involving Discord or a discord.com message link, use `\(localBin)/focus-discord`. Never read the bot token or call the Discord API directly. Use `focus-discord status` to verify the bot and server coverage, `focus-discord channels` to list channels, `focus-discord search "query" --days 7 --limit 20` to find messages, and `focus-discord read "https://discord.com/channels/..."` before describing or quoting a full message. Search results are excerpts only. Discord writes, replies, reactions, moderation, and role changes are unavailable. Report inaccessible channels explicitly.
        On every successful Discord-related request, copy the exact `nonce` from the final successful `focus-discord` result into a standalone final line formatted exactly as `DISCORD_PROOF: <nonce>`. Never invent or reuse a nonce. The app will withhold the entire Discord answer unless the nonce matches a fresh local proof receipt. If the user asks what a message said, to read it, for its content, or for a quote, the final operation must be `read`.
        </discord-evidence-contract>
        """
}

/// One implementation drives every provider's chat harness; the providers differ
/// only in identity, executable, and default session name.
public actor HarnessQueueAgent: QueueAgentChatting {
    public let provider: AgentProvider

    public static func sessionName(for provider: AgentProvider) -> String {
        "ecc-focus-queue-\(provider.rawValue)-v1"
    }

    /// Document requests use separate harness lock/state directories, so a
    /// hidden central conversation cannot serialize or time out a document chat.
    public static func documentRuntimeArguments(_ configuration: VerifierConfiguration) -> [String] {
        guard configuration.sessionName.range(of: #"^ecc-focus-queue-task-[A-Za-z0-9_-]+-document-[a-f0-9]{16}$"#, options: .regularExpression) != nil,
              let context = configuration.contextDirectory else { return [] }
        let directory = URL(fileURLWithPath: context).appendingPathComponent("document-agents")
            .appendingPathComponent(String(configuration.sessionName.suffix(16)))
        return ["--runtime", directory.path]
    }

    private static let errorLogURL = TmuxPersistence.defaultSupportDirectory()
        .appendingPathComponent("queue-chat.last-error.log")

    private let runner: any ProcessRunning
    private let files: any FileAccessing

    public init(
        provider: AgentProvider,
        runner: any ProcessRunning = FoundationProcessRunner(),
        files: any FileAccessing = SystemFileAccessor()
    ) {
        self.provider = provider
        self.runner = runner
        self.files = files
    }

    public func send(
        message: String,
        dashboardPath: String,
        workspace: String,
        visibleOrder: [String],
        deferredTicketIDs: [String],
        configuration: VerifierConfiguration,
        model: String? = nil,
        effort: String? = nil
    ) async throws -> QueueAgentReply {
        guard configuration.enabled else { throw QueueAgentError.disabled(provider) }

        let promptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("focus-queue-chat-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: promptURL) }
        let usageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("focus-queue-chat-usage-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: usageURL) }
        let runID = UUID().uuidString
        let source = Self.documentRuntimeArguments(configuration).isEmpty ? "queue_chat" : "document_chat"
        let isReader = configuration.documentReader == true
        let forkSource = isReader ? nil : configuration.forkSourceSessionID.flatMap { $0.isEmpty ? nil : $0 }
        // A forked agent keeps its own identity and instructions; only the queue agent gets the queue prompt.
        let prompt = forkSource != nil || isReader ? message : QueueAgentPrompt.build(
            provider: provider,
            message: message,
            dashboardPath: dashboardPath,
            workspace: workspace,
            visibleOrder: visibleOrder,
            deferredTicketIDs: deferredTicketIDs
        )
        try files.write(Data(prompt.utf8), to: promptURL)
        if let support = configuration.supportDirectory {
            PromptUsageMetrics.record(PromptUsageEvent(source: source, component: "app_context",
                provider: provider.rawValue, model: model,
                characters: max(0, prompt.count - message.count), runID: runID), in: URL(fileURLWithPath: support))
            if source == "document_chat",
               let marker = message.range(of: QueueAgentPrompt.userRequestMarker, options: .backwards) {
                let requestCharacters = message[marker.upperBound...].count
                PromptUsageMetrics.record(PromptUsageEvent(source: source,
                    component: "document_sources_plan_and_history", provider: provider.rawValue,
                    model: model, characters: max(0, message.count - requestCharacters),
                    runID: runID), in: URL(fileURLWithPath: support))
            }
        }

        let requestStartedAt = Date()
        let request = QueueAgentPrompt.userRequest(in: message)
        let runTimeoutSeconds = Self.runTimeoutSeconds(
            for: request,
            configuredTimeoutSeconds: configuration.timeoutSeconds
        )
        let requestedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedEffort = effort?.trimmingCharacters(in: .whitespacesAndNewlines)
        var arguments = Self.documentRuntimeArguments(configuration) + ["chat"]
        // Callers send their own bounded recap, so no provider session is
        // resumed and history cannot grow across turns. A fork is the
        // exception: its value is the source conversation it continues.
        if forkSource == nil { arguments.append("--fresh") }
        if isReader { arguments.append("--reader") }
        arguments += [
            "--session", Self.resolvedSessionName(for: configuration, provider: provider),
            "--workspace", workspace,
            "--prompt-file", promptURL.path,
            "--usage-file", usageURL.path,
            "--timeout", String(runTimeoutSeconds),
        ]
        if let contextDirectory = configuration.contextDirectory {
            arguments.append(contentsOf: ["--context-dir", contextDirectory])
        }
        for directory in configuration.writableDirectories ?? [] where !isReader && !directory.isEmpty {
            arguments.append(contentsOf: ["--writable-dir", directory])
        }
        if let requestedModel, !requestedModel.isEmpty {
            arguments.append(contentsOf: ["--model", requestedModel])
        }
        if let requestedEffort, !requestedEffort.isEmpty {
            arguments.append(contentsOf: ["--effort", requestedEffort])
        }
        if let forkSource { arguments.append(contentsOf: ["--fork-from", forkSource]) }
        let result = try await runner.run(ProcessSpecification(
            executable: configuration.executable,
            arguments: arguments,
            workingDirectory: workspace,
            environment: configuration.agentEnvironment,
            timeoutSeconds: runTimeoutSeconds + 15
        ))
        if let support = configuration.supportDirectory,
           let data = try? Data(contentsOf: usageURL),
           let usage = try? JSONSerialization.jsonObject(with: data) as? [String: Int] {
            PromptUsageMetrics.record(PromptUsageEvent(
                source: source, component: "provider_usage", provider: provider.rawValue, model: model,
                actualInputTokens: usage["inputTokens"], actualOutputTokens: usage["outputTokens"],
                actualTotalTokens: usage["totalTokens"], cachedInputTokens: usage["cachedInputTokens"],
                runID: runID, scope: "provider"), in: URL(fileURLWithPath: support))
        }

        let output = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let log = [result.standardOutput, result.standardError]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        guard result.succeeded, !output.isEmpty else {
            preservePrivateFailureLog(log)
            throw QueueAgentError.failed(provider, Self.safeFailureDetail(
                from: result,
                message: request,
                runTimeoutSeconds: runTimeoutSeconds
            ))
        }
        let evidence = QueueAgentEvidenceVerifier(files: files, provider: provider)
        var verifiedOutput = output
        if !isReader && QueueAgentEvidenceVerifier.requiresMailEvidence(request) {
            if QueueAgentEvidenceVerifier.isBlockedMailResponse(verifiedOutput) {
                preservePrivateFailureLog(log)
                throw QueueAgentError.failed(provider, Self.safeFailureDetail(
                    from: result,
                    message: request,
                    runTimeoutSeconds: runTimeoutSeconds
                ))
            }
            verifiedOutput = try evidence.verifyMailEvidence(
                in: verifiedOutput,
                for: request,
                requestStartedAt: requestStartedAt
            )
        }
        if !isReader && QueueAgentEvidenceVerifier.requiresDiscordEvidence(request) {
            verifiedOutput = try evidence.verifyDiscordEvidence(
                in: verifiedOutput,
                for: request,
                requestStartedAt: requestStartedAt
            )
        }
        return QueueAgentReply(message: verifiedOutput, log: log)
    }

    public func reset(configuration: VerifierConfiguration) async throws {
        guard configuration.enabled else { throw QueueAgentError.disabled(provider) }
        let result = try await runner.run(ProcessSpecification(
            executable: configuration.executable,
            arguments: Self.documentRuntimeArguments(configuration) + [
                "reset",
                "--session", Self.resolvedSessionName(for: configuration, provider: provider),
            ],
            environment: configuration.agentEnvironment,
            timeoutSeconds: 30
        ))
        guard result.succeeded else {
            throw QueueAgentError.failed(provider, WorkerFailureDiagnostics.detail(from: result))
        }
    }

    private static func resolvedSessionName(
        for configuration: VerifierConfiguration,
        provider: AgentProvider
    ) -> String {
        configuration.sessionName.hasPrefix("ecc-focus-queue-task-")
            ? configuration.sessionName : sessionName(for: provider)
    }

    static func safeFailureDetail(
        from result: ProcessResult,
        message: String,
        runTimeoutSeconds: Int
    ) -> String {
        // The harness enforces the run budget itself and exits 1 before the
        // host's longer process timeout fires, so its message also means timeout.
        let harnessTimedOut = [result.standardError, result.standardOutput]
            .contains { $0.contains("-second run budget") }
        if result.timedOut || harnessTimedOut {
            if QueueAgentEvidenceVerifier.requiresMailEvidence(message) {
                return "Mail check timed out after \(runTimeoutSeconds) seconds. Confirm the Mail helper is available, then retry."
            }
            return "the request timed out after \(runTimeoutSeconds) seconds. Queue chat suits short queue and task edits; ask for one step at a time or start an agent for multi-step setup work"
        }
        return WorkerFailureDiagnostics.detail(from: result)
    }

    private func preservePrivateFailureLog(_ log: String) {
        guard !log.isEmpty else { return }
        try? files.write(Data(log.utf8), to: Self.errorLogURL)
    }

    static func runTimeoutSeconds(
        for message: String,
        configuredTimeoutSeconds: Int
    ) -> Int {
        let normalized = message.lowercased()
        let bulkInboxPhrases = [
            "entire inbox", "whole inbox", "all my inbox", "all of my inbox",
            "catch up", "caught up", "scan my inbox", "scan through my inbox",
            "inbox backlog", "add relevant tasks", "create tasks from",
        ]
        guard QueueAgentEvidenceVerifier.requiresMailEvidence(message) else {
            return configuredTimeoutSeconds
        }
        if bulkInboxPhrases.contains(where: normalized.contains) {
            return max(configuredTimeoutSeconds, 600)
        }
        return max(configuredTimeoutSeconds, 180)
    }

    static func isDailyReportRunRequest(_ message: String) -> Bool {
        DailyReportChatCommand.parse(
            message,
            enabledPlatforms: DailyReportPlatform.allCases
        ) != nil
    }
}

public actor CodexQueueAgent: QueueAgentChatting {
    public static let sessionName = HarnessQueueAgent.sessionName(for: .codex)

    public static func documentRuntimeArguments(_ configuration: VerifierConfiguration) -> [String] {
        HarnessQueueAgent.documentRuntimeArguments(configuration)
    }

    public static func prompt(
        message: String,
        dashboardPath: String,
        workspace: String,
        visibleOrder: [String],
        deferredTicketIDs: [String]
    ) -> String {
        QueueAgentPrompt.build(
            provider: .codex,
            message: message,
            dashboardPath: dashboardPath,
            workspace: workspace,
            visibleOrder: visibleOrder,
            deferredTicketIDs: deferredTicketIDs
        )
    }

    static func safeFailureDetail(
        from result: ProcessResult,
        message: String,
        runTimeoutSeconds: Int
    ) -> String {
        HarnessQueueAgent.safeFailureDetail(
            from: result,
            message: message,
            runTimeoutSeconds: runTimeoutSeconds
        )
    }

    static func runTimeoutSeconds(
        for message: String,
        configuredTimeoutSeconds: Int
    ) -> Int {
        HarnessQueueAgent.runTimeoutSeconds(
            for: message,
            configuredTimeoutSeconds: configuredTimeoutSeconds
        )
    }

    static func isDailyReportRunRequest(_ message: String) -> Bool {
        HarnessQueueAgent.isDailyReportRunRequest(message)
    }

    private let harness: HarnessQueueAgent

    public init(
        runner: any ProcessRunning = FoundationProcessRunner(),
        files: any FileAccessing = SystemFileAccessor()
    ) {
        harness = HarnessQueueAgent(provider: .codex, runner: runner, files: files)
    }

    public func send(
        message: String,
        dashboardPath: String,
        workspace: String,
        visibleOrder: [String],
        deferredTicketIDs: [String],
        configuration: VerifierConfiguration,
        model: String? = nil,
        effort: String? = nil
    ) async throws -> QueueAgentReply {
        try await harness.send(
            message: message,
            dashboardPath: dashboardPath,
            workspace: workspace,
            visibleOrder: visibleOrder,
            deferredTicketIDs: deferredTicketIDs,
            configuration: configuration,
            model: model,
            effort: effort
        )
    }

    public func reset(configuration: VerifierConfiguration) async throws {
        try await harness.reset(configuration: configuration)
    }
}

public actor ClaudeQueueAgent: QueueAgentChatting {
    public static let sessionName = HarnessQueueAgent.sessionName(for: .claude)

    private let harness: HarnessQueueAgent

    public init(
        runner: any ProcessRunning = FoundationProcessRunner(),
        files: any FileAccessing = SystemFileAccessor()
    ) {
        harness = HarnessQueueAgent(provider: .claude, runner: runner, files: files)
    }

    public func send(
        message: String,
        dashboardPath: String,
        workspace: String,
        visibleOrder: [String],
        deferredTicketIDs: [String],
        configuration: VerifierConfiguration,
        model: String? = nil,
        effort: String? = nil
    ) async throws -> QueueAgentReply {
        try await harness.send(
            message: message,
            dashboardPath: dashboardPath,
            workspace: workspace,
            visibleOrder: visibleOrder,
            deferredTicketIDs: deferredTicketIDs,
            configuration: configuration,
            model: model,
            effort: effort
        )
    }

    public func reset(configuration: VerifierConfiguration) async throws {
        try await harness.reset(configuration: configuration)
    }
}

public actor KimiQueueAgent: QueueAgentChatting {
    public static let sessionName = HarnessQueueAgent.sessionName(for: .kimi)

    private let harness: HarnessQueueAgent

    public init(
        runner: any ProcessRunning = FoundationProcessRunner(),
        files: any FileAccessing = SystemFileAccessor()
    ) {
        harness = HarnessQueueAgent(provider: .kimi, runner: runner, files: files)
    }

    public func send(
        message: String,
        dashboardPath: String,
        workspace: String,
        visibleOrder: [String],
        deferredTicketIDs: [String],
        configuration: VerifierConfiguration,
        model: String? = nil,
        effort: String? = nil
    ) async throws -> QueueAgentReply {
        try await harness.send(
            message: message,
            dashboardPath: dashboardPath,
            workspace: workspace,
            visibleOrder: visibleOrder,
            deferredTicketIDs: deferredTicketIDs,
            configuration: configuration,
            model: model,
            effort: effort
        )
    }

    public func reset(configuration: VerifierConfiguration) async throws {
        try await harness.reset(configuration: configuration)
    }
}
