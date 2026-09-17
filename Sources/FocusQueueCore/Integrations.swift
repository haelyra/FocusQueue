import Foundation

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
        request: DailyReportRunRequest
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
        let raw = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? result.standardOutput
            : result.standardError
        let normalized = raw.lowercased()
        if normalized.contains("mail_reader_busy") || normalized.contains("mail reader is busy") {
            return "the Mail reader is busy with another request. The current request will continue; retry after it finishes"
        }
        if normalized.contains("mail_reader_timeout") || normalized.contains("mail reader timed out") {
            return "the protected Mail reader timed out. Confirm Apple Mail is running, then retry"
        }
        if normalized.contains("mail_permission_required")
            || normalized.contains("not authorized to send apple events")
            || normalized.contains("-1743") {
            return "Mail access needs approval for ECC Focus Mail Reader > Mail in System Settings > Privacy & Security > Automation. Older applet and python entries are separate identities"
        }
        if normalized.contains("mailbox_not_configured") || normalized.contains("mailbox is not configured") {
            return "the requested mailbox is outside the configured Mail scope. Review emailMailboxes in ingestion settings, then retry"
        }
        if normalized.contains("mail_runtime_permission_required") || normalized.contains("operation not permitted") {
            return "the worker was denied access to a local process or file. Review the private daily report log for the blocked resource"
        }
        if normalized.contains("mail_reader_not_installed")
            || normalized.contains("mail reader app is not installed") {
            return "the protected Mail reader is missing. Reinstall ECC Focus Queue, then retry"
        }
        if normalized.contains("codex") || normalized.contains("classification failed") {
            return "the message classifier failed its safety or compatibility check. Update ECC Focus Queue or Codex, then retry"
        }
        if normalized.contains("missing ingestion settings") || normalized.contains("configuration") {
            return "the daily report configuration is incomplete or invalid. Review its settings, then retry"
        }
        return "the worker exited with code \(result.exitCode). See the private daily report log for details"
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
    public let workingDirectory: String
    public let tabTitle: String
    public let pane: WezTermPane

    public init(
        provider: AgentProvider,
        sessionID: String,
        workingDirectory: String,
        tabTitle: String,
        pane: WezTermPane
    ) {
        self.provider = provider
        self.sessionID = sessionID
        self.workingDirectory = workingDirectory
        self.tabTitle = tabTitle
        self.pane = pane
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
        configuration: WezTermConfiguration
    ) async throws -> TerminalActionResult

    func openAgentRuntime(_ subtask: TaskSubtask, taskID: String,
                          configuration: WezTermConfiguration) async throws -> TerminalActionResult

    func openDirectRuntime(
        paneID: Int,
        socketPath: String?,
        taskID: String,
        provider: AgentProvider,
        configuration: WezTermConfiguration
    ) async throws -> TerminalActionResult
}

public extension WezTermControlling {
    func openAgentRuntime(_ subtask: TaskSubtask, taskID: String,
                          configuration: WezTermConfiguration) async throws -> TerminalActionResult {
        if let tmux = subtask.tmux {
            return try await openManagedRuntime(tmux, taskID: taskID, provider: subtask.provider, configuration: configuration)
        }
        guard let paneID = subtask.terminalPaneID else { throw WezTermError.runtimeClosed }
        return try await openDirectRuntime(paneID: paneID, socketPath: subtask.terminalSocketPath,
            taskID: taskID, provider: subtask.provider, configuration: configuration)
    }

    func focusPane(_ pane: WezTermPane, configuration: WezTermConfiguration) async throws {
        throw WezTermError.actionFailed("This terminal integration does not support browsing panes.")
    }

    func openManagedRuntime(
        _ tmux: TmuxSessionReference,
        taskID: String,
        provider: AgentProvider,
        configuration: WezTermConfiguration
    ) async throws -> TerminalActionResult {
        throw TmuxError.unavailable("This terminal integration cannot open managed sessions.")
    }

    func openDirectRuntime(
        paneID: Int,
        socketPath: String?,
        taskID: String,
        provider: AgentProvider,
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

    public init(runner: any ProcessRunning = FoundationProcessRunner(), candidateSockets: [String]? = nil,
                verificationAttempts: Int = 10) {
        self.runner = runner
        self.candidateSockets = candidateSockets
        _ = verificationAttempts
    }

    public func focusPane(_ pane: WezTermPane, configuration: WezTermConfiguration) async throws {
        var requested = configuration
        requested.socketPath = pane.socketPath ?? configuration.socketPath
        let connection = try await WezTermConnection.resolve(configuration: requested,
            runner: runner, candidateSockets: candidateSockets)
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
        let connection = try await WezTermConnection.resolve(configuration: configuration,
            runner: runner, candidateSockets: candidateSockets)
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
        let connection = try await WezTermConnection.resolve(configuration: configuration,
            runner: runner, candidateSockets: candidateSockets)
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
                    AgentTerminalLabels.tabTitle(ticketID: taskID, paneID: pane.paneID),
                ],
                timeoutSeconds: 10
            ))
            _ = try? await runner.run(ProcessSpecification(
                executable: configuration.executable,
                arguments: [
                    "cli", "set-window-title", "--pane-id", String(pane.paneID), taskID,
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
                            AgentTerminalLabels.tabTitle(ticketID: taskID, paneID: paneID),
                        ],
                        timeoutSeconds: 10
                    ))
                    _ = try? await runner.run(ProcessSpecification(
                        executable: configuration.executable,
                        arguments: [
                            "cli", "set-window-title", "--pane-id", String(paneID), taskID,
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
        return try await openManagedRuntime(
            tmux, taskID: taskID, provider: session.provider, configuration: configuration)
    }

    public func openAgentRuntime(_ subtask: TaskSubtask, taskID: String,
                                 configuration: WezTermConfiguration) async throws -> TerminalActionResult {
        let title = subtask.sessionID.map { AgentTerminalLabels.tabTitle(ticketID: taskID, provider: subtask.provider, sessionID: $0) }
        if let tmux = subtask.tmux {
            return try await openManagedRuntime(tmux, taskID: taskID, provider: subtask.provider,
                configuration: configuration, tabTitle: title)
        }
        guard let paneID = subtask.terminalPaneID else { throw WezTermError.runtimeClosed }
        return try await openDirectRuntime(paneID: paneID, socketPath: subtask.terminalSocketPath,
            taskID: taskID, provider: subtask.provider, configuration: configuration, tabTitle: title)
    }

    public func openManagedRuntime(
        _ saved: TmuxSessionReference,
        taskID: String,
        provider: AgentProvider,
        configuration: WezTermConfiguration
    ) async throws -> TerminalActionResult {
        try await openManagedRuntime(saved, taskID: taskID, provider: provider, configuration: configuration, tabTitle: nil)
    }

    private func openManagedRuntime(_ saved: TmuxSessionReference, taskID: String, provider: AgentProvider,
                                    configuration: WezTermConfiguration, tabTitle: String?) async throws -> TerminalActionResult {
        if saved.name.hasPrefix("fq-task-"), saved.name != (try TmuxController.taskSessionName(taskID: taskID)) {
            throw TmuxError.changed
        }
        let runtime = TmuxController(runner: runner)
        let live = try await runtime.verify(saved)
        if live.name.hasPrefix("fq-task-") { try await runtime.select(live) }

        var connection = try await WezTermConnection.resolve(
            configuration: configuration, runner: runner, candidateSockets: candidateSockets)
        guard !connection.result.timedOut else {
            throw WezTermError.actionFailed(
                "WezTerm lookup timed out. The managed session remains running in tmux.")
        }
        if !connection.result.succeeded {
            let started = try await runner.run(ProcessSpecification(
                executable: "/usr/bin/open", arguments: ["-a", configuration.applicationName],
                timeoutSeconds: 15))
            guard started.succeeded else {
                throw WezTermError.actionFailed(Self.failureDetail(started))
            }
            for _ in 0..<5 {
                connection = try await WezTermConnection.resolve(
                    configuration: configuration, runner: runner, candidateSockets: candidateSockets)
                if connection.result.succeeded || connection.result.timedOut { break }
                try await Task.sleep(for: .milliseconds(300))
            }
            guard connection.result.succeeded else {
                throw WezTermError.actionFailed(
                    "WezTerm opened without a usable connection. The managed session remains running in tmux.")
            }
        }

        let pinned = connection.configuration
        let panes = try Self.decodePanes(from: connection.result)
        let clients = try await runtime.clientTTYs(for: live)
        let tabTitle = tabTitle ?? "\(taskID.uppercased()) · \(provider.displayName) · managed"
        if let pane = panes.first(where: { $0.ttyName.map(clients.contains) == true }) {
            try await focus(
                pane: pane, tabTitle: tabTitle, windowTitle: taskID.uppercased(),
                configuration: pinned)
            return .focused(paneID: pane.paneID)
        }

        let command = try TmuxController.attachCommand(
            name: live.name, executable: live.executable)
        let spawn = try await runner.run(ProcessSpecification(
            executable: pinned.executable,
            arguments: ["cli", "spawn", "--new-window", "--domain-name", "local", "--"] + command,
            environment: pinned.cliEnvironment, timeoutSeconds: 15))
        guard spawn.succeeded,
              let paneID = Int(spawn.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)),
              paneID >= 0 else {
            throw TmuxError.unavailable(
                "The process is still running, but its terminal view could not be opened. Use focus-queue-session tmux attach \(live.name).")
        }
        _ = try await runtime.verify(saved)
        let snapshot = try await listPanes(using: pinned)
        guard snapshot.succeeded,
              let pane = try Self.decodePanes(from: snapshot).first(where: { $0.paneID == paneID }) else {
            throw TmuxError.unavailable(
                "The new terminal view closed. The managed session remains running in tmux.")
        }
        try await focus(
            pane: pane, tabTitle: tabTitle, windowTitle: taskID.uppercased(),
            configuration: pinned)
        return .focused(paneID: paneID)
    }

    public func openDirectRuntime(
        paneID: Int,
        socketPath: String?,
        taskID: String,
        provider: AgentProvider,
        configuration: WezTermConfiguration
    ) async throws -> TerminalActionResult {
        try await openDirectRuntime(paneID: paneID, socketPath: socketPath, taskID: taskID,
            provider: provider, configuration: configuration, tabTitle: nil)
    }

    private func openDirectRuntime(paneID: Int, socketPath: String?, taskID: String, provider: AgentProvider,
                                   configuration: WezTermConfiguration, tabTitle: String?) async throws -> TerminalActionResult {
        guard paneID >= 0 else {
            throw WezTermError.actionFailed("The saved direct terminal identity is invalid.")
        }
        var requested = configuration
        requested.socketPath = socketPath ?? requested.socketPath
        let connection = try await WezTermConnection.resolve(
            configuration: requested, runner: runner, candidateSockets: candidateSockets)
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
        try await focus(
            pane: pane,
            tabTitle: tabTitle ?? "\(taskID.uppercased()) · \(provider.displayName) · direct",
            windowTitle: taskID.uppercased(), configuration: connection.configuration)
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
            }
            guard isProviderTranscript, path.hasSuffix(".jsonl") else { continue }
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

    public func labelTmuxClients(session: TaskAgentSession, configuration: WezTermConfiguration) async throws {
        guard let reference = session.tmux else { return }
        let clients = try await TmuxController(runner: runner).clientTTYs(for: reference)
        guard !clients.isEmpty else { return }
        let connection = try await WezTermConnection.resolve(configuration: configuration,
            runner: runner, candidateSockets: candidateSockets)
        guard connection.result.succeeded else { return }
        for pane in try Self.decodePanes(from: connection.result) where pane.ttyName.map(clients.contains) == true {
            try await attach(paneID: pane.paneID, tabTitle: session.terminalTabTitle,
                windowTitle: session.terminalWindowTitle, configuration: connection.configuration)
        }
    }

    private func discoverAgents(
        in panes: [WezTermPane],
        preferredSession: TaskAgentSession? = nil
    ) async throws -> [RunningAgentSession] {
        let processResult = try await runner.run(ProcessSpecification(
            executable: "/bin/ps",
            arguments: ["-axo", "pid=,tty=,comm="],
            timeoutSeconds: 10
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
            panesByTTY[$0.tty] != nil
        }
        guard !paneProcesses.isEmpty else { return [] }

        let providersByPID = Dictionary(
            uniqueKeysWithValues: paneProcesses.map { ($0.pid, $0.provider) }
        )
        let processIDs = paneProcesses.map { String($0.pid) }.joined(separator: ",")
        let lsofResult = try await runner.run(ProcessSpecification(
            executable: "/usr/sbin/lsof",
            arguments: ["-a", "-p", processIDs, "-Fn"],
            timeoutSeconds: 10
        ))
        guard lsofResult.succeeded else {
            throw WezTermError.actionFailed("Could not verify agent process ownership. No absence was assumed. \(Self.failureDetail(lsofResult))")
        }
        let sessionsByPID = sessionIDsByProcess(
            inLsofOutput: lsofResult.standardOutput,
            providersByPID: providersByPID,
            preferredSession: preferredSession
        )

        var discovered: [RunningAgentSession] = []
        var seenSessions: Set<String> = []

        for process in paneProcesses {
            guard let pane = panesByTTY[process.tty] else { continue }
            guard let sessionID = sessionsByPID[process.pid] else { continue }
            let identity = "\(process.provider.rawValue):\(sessionID)"
            guard seenSessions.insert(identity).inserted else { continue }

            discovered.append(RunningAgentSession(
                provider: process.provider,
                sessionID: sessionID,
                workingDirectory: Self.pathFromWezTermCWD(pane.cwd),
                tabTitle: Self.displayTitle(for: pane),
                pane: pane
            ))
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
            let commandPath = String(fields[2]).trimmingCharacters(in: .whitespaces)
            let command = URL(fileURLWithPath: commandPath).lastPathComponent.lowercased()
            let provider: AgentProvider
            switch command {
            case "codex": provider = .codex
            case "claude": provider = .claude
            default: return nil
            }
            return AgentProcess(pid: pid, tty: String(fields[1]), provider: provider)
        }
    }

    private func sessionIDsByProcess(
        inLsofOutput output: String,
        providersByPID: [Int32: AgentProvider],
        preferredSession: TaskAgentSession?
    ) -> [Int32: String] {
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

        var sessions: [Int32: String] = [:]
        for (pid, lines) in outputByPID {
            guard let provider = providersByPID[pid] else { continue }
            let candidates = Self.sessionCandidates(
                for: provider,
                inLsofOutput: lines.joined(separator: "\n")
            )
            guard let sessionID = resolvedSessionID(
                provider: provider,
                candidates: candidates,
                preferredSession: preferredSession
            ) else { continue }
            sessions[pid] = sessionID
        }
        return sessions
    }

    private func resolvedSessionID(
        provider: AgentProvider,
        candidates: [AgentSessionCandidate],
        preferredSession: TaskAgentSession?
    ) -> String? {
        if provider == .codex {
            let locks = candidates.filter(\.isWriterLock)
            if !locks.isEmpty {
                let ownedIDs = Set(locks.map(\.sessionID))
                let ownedRoots = Set(locks.map { lock in
                    candidates.first(where: { !$0.isWriterLock && $0.sessionID == lock.sessionID })
                        .flatMap { canonicalCodexSessionID(from: $0) } ?? lock.sessionID
                })
                if let preferredSession, preferredSession.provider == provider {
                    let preferredID = preferredSession.sessionID.lowercased()
                    if ownedIDs.contains(preferredID) || ownedRoots.contains(preferredID) {
                        return preferredID
                    }
                }
                // An open historical transcript is evidence of reading, not
                // ownership. Only locked threads may identify this process.
                return ownedRoots.count == 1 ? ownedRoots.first : nil
            }

            let transcriptRoots = Set(candidates.compactMap { canonicalCodexSessionID(from: $0) })
            if transcriptRoots.count > 1 { return nil }
            if let root = transcriptRoots.first { return root }
        }

        if let preferredSession,
           preferredSession.provider == provider {
            let preferredID = preferredSession.sessionID.lowercased()
            if candidates.contains(where: { $0.sessionID == preferredID }) {
                return preferredID
            }
            if provider == .codex,
               candidates.contains(where: {
                   canonicalCodexSessionID(from: $0) == preferredID
               }) {
                return preferredID
            }
        }

        guard provider == .codex else {
            let sessionIDs = Set(candidates.map(\.sessionID))
            return sessionIDs.count == 1 ? sessionIDs.first : nil
        }

        let transcriptRoots = Set(candidates.compactMap { candidate in
            candidate.isWriterLock ? nil : canonicalCodexSessionID(from: candidate)
        })
        if transcriptRoots.count == 1 { return transcriptRoots.first }
        if transcriptRoots.count > 1 { return nil }

        let writerLockSessions = Set(
            candidates.filter(\.isWriterLock).map(\.sessionID)
        )
        return writerLockSessions.count == 1 ? writerLockSessions.first : nil
    }

    private func canonicalCodexSessionID(from candidate: AgentSessionCandidate) -> String? {
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
        let identityKeys = sourceIsSubagent
            ? ["session_id", "parent_thread_id", "id"]
            : ["id", "session_id"]
        for key in identityKeys {
            guard let value = payload[key] as? String,
                  UUID(uuidString: value) != nil
            else { continue }
            return value.lowercased()
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
            arguments: ["cli", "list", "--format", "json"],
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

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
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
}

private struct AgentSessionCandidate {
    let sessionID: String
    let path: String
    let isWriterLock: Bool
}

public struct VerificationRunResult: Equatable, Sendable {
    public let succeeded: Bool
    public let summary: String
    public let log: String

    public init(succeeded: Bool, summary: String, log: String) {
        self.succeeded = succeeded
        self.summary = summary
        self.log = log
    }
}

public protocol CompletionVerifying: Sendable {
    func verify(
        ticketID: String,
        requestFile: URL,
        workspace: String,
        configuration: VerifierConfiguration
    ) async throws -> VerificationRunResult
}

public actor CodexCompletionVerifier: CompletionVerifying {
    private let runner: any ProcessRunning
    private let files: any FileAccessing

    public init(
        runner: any ProcessRunning = FoundationProcessRunner(),
        files: any FileAccessing = SystemFileAccessor()
    ) {
        self.runner = runner
        self.files = files
    }

    public func verify(
        ticketID: String,
        requestFile: URL,
        workspace: String,
        configuration: VerifierConfiguration
    ) async throws -> VerificationRunResult {
        guard configuration.enabled else {
            return VerificationRunResult(
                succeeded: false,
                summary: "Codex completion review is disabled in config.json.",
                log: "Verifier disabled."
            )
        }

        let promptURL = requestFile.deletingPathExtension().appendingPathExtension("prompt.txt")
        let prompt = """
        Review completion intent for ticket \(ticketID).
        The local request record is at \(requestFile.path).
        Read the request first. Lead your response with one short sentence stating the specific missing evidence or accepted result, then details. Do not lead with "Completion rejected", a subtask UUID, or a generic verdict.
        Re-read the workspace instructions and repository evidence. Do not trust the checkbox as completion evidence. For parent task closure only, read the canonical dashboard, PR state, and doneWhen; never resolve a parent while resolutionPrs is unmerged. For subtask closure, assess only that assignment and its recorded changes and checks. Do not require the entire parent's success criteria, merged PRs, or unrelated work to accept a subtask. A user-requested undo or cancellation is a valid completed assignment when verified. Do not require live UI automation where workspace instructions prohibit it; explain any remaining manual check concisely. Do not inspect or transmit unrelated private notes.
        The request may contain contextPath and subtaskID. Read the central plan and context.json in contextPath when present. If subtaskID is present, review only that named subtask; do not close the parent task. After checks actually pass, run focus-queue-session complete <ticketID> <subtaskID> "concise evidence and checks" using the request's actual identifiers. On disagreement, leave the subtask open and explain the missing evidence. For parent completion, require all subtasks completed. Preserve worktrees and branches: the host archives context and performs guarded cleanup after canonical completion. Never force-remove, reset, or merge branches as part of this review.
        """
        try files.write(Data(prompt.utf8), to: promptURL)

        let result = try await runner.run(ProcessSpecification(
            executable: configuration.executable,
            arguments: [
                "run",
                "--workspace", workspace,
                "--prompt-file", promptURL.path,
                "--timeout", String(configuration.timeoutSeconds),
                "--sandbox", "workspace-write",
                "--label", configuration.sessionName,
            ] + (configuration.contextDirectory.map { ["--context-dir", $0] } ?? []),
            workingDirectory: workspace,
            environment: Self.agentEnvironment(configuration),
            timeoutSeconds: configuration.timeoutSeconds + 15
        ))

        let combinedLog = [result.standardOutput, result.standardError]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let trimmedOutput = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = result.timedOut
            ? "Codex review timed out and remains pending."
            : "Codex review failed with exit code \(result.exitCode)."
        return VerificationRunResult(
            succeeded: result.succeeded,
            summary: trimmedOutput.isEmpty ? fallback : trimmedOutput,
            log: combinedLog.isEmpty ? fallback : combinedLog
        )
    }

    public static func agentEnvironment(_ configuration: VerifierConfiguration) -> [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var environment = ["PATH": "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"]
        if let directory = configuration.supportDirectory { environment["FOCUS_QUEUE_SUPPORT_DIR"] = directory }
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
        configuration: VerifierConfiguration
    ) async throws -> QueueAgentReply
}

public enum QueueAgentError: Error, LocalizedError {
    case disabled
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .disabled:
            "Codex Queue chat is disabled in config.json."
        case .failed(let detail):
            "Codex Queue chat failed: \(detail)"
        }
    }
}

public actor CodexQueueAgent: QueueAgentChatting {
    public static let sessionName = "ecc-focus-queue-codex-v1"
    /// Document requests use separate harness lock/state directories, so a
    /// hidden central conversation cannot serialize or time out a document chat.
    public static func documentRuntimeArguments(_ configuration: VerifierConfiguration) -> [String] {
        guard configuration.sessionName.range(of: #"^ecc-focus-queue-task-[A-Za-z0-9_-]+-document-[a-f0-9]{16}$"#, options: .regularExpression) != nil,
              let context = configuration.contextDirectory else { return [] }
        let directory = URL(fileURLWithPath: context).appendingPathComponent("document-agents")
            .appendingPathComponent(String(configuration.sessionName.suffix(16)))
        return ["--runtime", directory.path]
    }
    private static let errorLogURL = URL(
        fileURLWithPath: "/Users/hira/Library/Application Support/ECC Focus Queue/queue-chat.last-error.log"
    )
    private static let mailEvidenceURL = URL(
        fileURLWithPath: "/Users/hira/Library/Application Support/ECC Focus Queue/mail-proofs/mail-response.json"
    )
    private static let discordEvidenceURL = URL(
        fileURLWithPath: "/Users/hira/Library/Application Support/ECC Focus Queue/connector-proofs/discord-response.json"
    )

    private struct MailEvidenceReceipt: Decodable {
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

    private struct DiscordEvidenceReceipt: Decodable {
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

    private let runner: any ProcessRunning
    private let files: any FileAccessing

    public init(
        runner: any ProcessRunning = FoundationProcessRunner(),
        files: any FileAccessing = SystemFileAccessor()
    ) {
        self.runner = runner
        self.files = files
    }

    public func send(
        message: String,
        dashboardPath: String,
        workspace: String,
        visibleOrder: [String],
        deferredTicketIDs: [String],
        configuration: VerifierConfiguration
    ) async throws -> QueueAgentReply {
        guard configuration.enabled else { throw QueueAgentError.disabled }

        let promptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("focus-queue-chat-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: promptURL) }
        let prompt = Self.prompt(
            message: message,
            dashboardPath: dashboardPath,
            workspace: workspace,
            visibleOrder: visibleOrder,
            deferredTicketIDs: deferredTicketIDs
        )
        try files.write(Data(prompt.utf8), to: promptURL)

        let requestStartedAt = Date()
        let runTimeoutSeconds = Self.runTimeoutSeconds(
            for: message,
            configuredTimeoutSeconds: configuration.timeoutSeconds
        )
        let result = try await runner.run(ProcessSpecification(
            executable: configuration.executable,
            arguments: Self.documentRuntimeArguments(configuration) + [
                "chat",
                "--session", configuration.sessionName.hasPrefix("ecc-focus-queue-task-")
                    ? configuration.sessionName : Self.sessionName,
                "--workspace", workspace,
                "--prompt-file", promptURL.path,
                "--timeout", String(runTimeoutSeconds),
            ] + (configuration.contextDirectory.map { ["--context-dir", $0] } ?? []),
            workingDirectory: workspace,
            environment: CodexCompletionVerifier.agentEnvironment(configuration),
            timeoutSeconds: runTimeoutSeconds + 15
        ))

        let output = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let log = [result.standardOutput, result.standardError]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        guard result.succeeded, !output.isEmpty else {
            preservePrivateFailureLog(log)
            throw QueueAgentError.failed(Self.safeFailureDetail(
                from: result,
                message: message,
                runTimeoutSeconds: runTimeoutSeconds
            ))
        }
        var verifiedOutput = output
        if Self.requiresMailEvidence(message) {
            if Self.isBlockedMailResponse(verifiedOutput) {
                preservePrivateFailureLog(log)
                throw QueueAgentError.failed(Self.safeFailureDetail(
                    from: result,
                    message: message,
                    runTimeoutSeconds: runTimeoutSeconds
                ))
            }
            verifiedOutput = try verifyMailEvidence(
                in: verifiedOutput,
                for: message,
                requestStartedAt: requestStartedAt
            )
        }
        if Self.requiresDiscordEvidence(message) {
            verifiedOutput = try verifyDiscordEvidence(
                in: verifiedOutput,
                for: message,
                requestStartedAt: requestStartedAt
            )
        }
        return QueueAgentReply(message: verifiedOutput, log: log)
    }

    static func safeFailureDetail(
        from result: ProcessResult,
        message: String,
        runTimeoutSeconds: Int
    ) -> String {
        if result.timedOut {
            if requiresMailEvidence(message) {
                return "Mail check timed out after \(runTimeoutSeconds) seconds. Confirm the Mail helper is available, then retry."
            }
            return "the request timed out after \(runTimeoutSeconds) seconds; retry the request"
        }
        let raw = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? result.standardOutput
            : result.standardError
        let normalized = raw.lowercased()
        if normalized.contains("mail_reader_busy") || normalized.contains("mail reader is busy") {
            return "the Mail reader is busy with another request. The current request will continue; retry after it finishes"
        }
        if normalized.contains("mail_reader_timeout") || normalized.contains("mail reader timed out") {
            return "the protected Mail reader timed out. Confirm Apple Mail is running, then retry"
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
            return "the worker was denied access to a local process or file. Review the private Queue chat log for the blocked resource and retry the Mail status check"
        }
        if normalized.contains("mail_reader_not_installed")
            || normalized.contains("mail reader app is not installed") {
            return "the protected Mail reader is missing. Reinstall ECC Focus Queue, then retry"
        }
        if normalized.contains("codex") || normalized.contains("classification failed") {
            return "the Queue assistant failed its safety or compatibility check. Update ECC Focus Queue or Codex, then retry"
        }
        if normalized.contains("configuration") {
            return "the Queue assistant configuration is incomplete or invalid. Review its settings, then retry"
        }
        return "the worker exited with code \(result.exitCode). See the private Queue chat log for details"
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
        guard requiresMailEvidence(message) else {
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


    private static func requiresMailEvidence(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return [
            "email", "e-mail", "mailbox", "inbox", "apple mail", "himalaya",
            "@ecc.tools", "message id", "message link", "recent message",
            "customer message", "customer response", "my response", "their response",
        ].contains { normalized.contains($0) }
    }

    private static func requiredMailOperation(for message: String) -> String? {
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

    private static func requiresDiscordEvidence(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("discord") || normalized.contains("discord.com/channels/")
    }

    private static func requiredDiscordOperation(for message: String) -> String? {
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

    private func verifyMailEvidence(
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
                "mail answer withheld because Codex did not provide current-turn verified mail evidence"
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
              receipt.account == "haley@ecc.tools"
        else {
            throw QueueAgentError.failed(
                "mail answer withheld because its proof receipt was missing, stale, or invalid"
            )
        }
        if let requiredOperation = Self.requiredMailOperation(for: message),
           receipt.operation != requiredOperation {
            throw QueueAgentError.failed(
                "mail answer withheld because Codex performed \(receipt.operation), not the required \(requiredOperation) operation"
            )
        }
        if receipt.operation == "open", receipt.opened != true {
            throw QueueAgentError.failed(
                "mail answer withheld because Apple Mail did not confirm the open request"
            )
        }
        if ["read", "open"].contains(receipt.operation),
           (receipt.message?.id.isEmpty != false || receipt.message?.messageId.isEmpty != false) {
            throw QueueAgentError.failed(
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

    private static func isBlockedMailResponse(_ output: String) -> Bool {
        let normalized = output.lowercased()
        return normalized.contains("blocked")
            && [
                "focus-mail", "mail reader", "mail connector", "verified connector",
                "operation not permitted", "timed out",
            ].contains(where: normalized.contains)
    }

    private func verifyDiscordEvidence(
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
                "Discord answer withheld because Codex did not provide current-turn verified Discord evidence"
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
                "Discord answer withheld because its proof receipt was missing, stale, or invalid"
            )
        }
        if let requiredOperation = Self.requiredDiscordOperation(for: message),
           receipt.operation != requiredOperation {
            throw QueueAgentError.failed(
                "Discord answer withheld because Codex performed \(receipt.operation), not the required \(requiredOperation) operation"
            )
        }
        if receipt.operation == "read",
           (receipt.message?.id.isEmpty != false || receipt.message?.channelId.isEmpty != false) {
            throw QueueAgentError.failed(
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

    public static func prompt(
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
        return """
        You are the Codex Queue agent for ECC Focus Queue.

        The app itself computes the visible queue order by priority, then updatedAt, then task ID. Local drag overrides move deferred tasks behind the canonical order. You explain and assist with the queue, but you are not an autonomous authority over task order.

        Canonical dashboard: \(dashboardPath)
        Workspace: \(workspace)
        Current visible open-task order: \(order)
        Current local deferred task IDs: \(deferred)

        Answer clarifying questions from the dashboard and workspace. On explicit request, you may create a task with a unique ID using the existing schema, clarify task fields including taskType and doneWhen, add links, or update a task's central plan. Edit the canonical dashboard only when the user's message directly and unambiguously requests that exact change. Preserve the dashboard schema and existing ticket IDs. Do not resolve, cancel, or invent completion evidence. Do not turn a disagreement with local order into a canonical priority change unless the user explicitly asks for that canonical change. Keep the response concise and state any file change you made.

        Every task has durable context under the Focus Queue support directory's tasks/<ticket-id>/ folder. When the user message includes a Task scope and central plan path, restrict the turn to that task and read its plan before proposing changes. Keep one central plan as the source of truth and link supporting canvases from it. Persist decisions, success criteria, progress, checks, and next actions concisely. Use focus-queue-session context <ticket-id> to read context and the helper's add/rename/progress/complete commands for subtask state instead of overwriting context.json. The helper defaults to the standard support directory; use FOCUS_QUEUE_SUPPORT_DIR when provided. Only record completed after evidence has been verified. Task types are task, long-running, subtask, and customer-concern. A customer concern needs the user's response/review before closure. Never send external messages without an explicit request. Worktree merging requires the task's explicit approval terms; leave cleanup to the host.

        Subtasks are assignments, and agents are separately linked runtime records. New runtime records have parentSubtaskID; isAssignmentOnly records never identify a terminal. A single provider conversation may be associated with additional assignments using focus-queue-session associate <ticket-id> <agent-record-id> <subtask-id>. At review boundaries the host combines assignments handled by the same provider conversation and retains mergedIntoSubtaskID aliases, launch locations, and history. Read the refreshed context and reflect combined scope in the central plan when reviewing it. Keep provider session IDs and workspace paths on their own agent records. Never copy one agent's runtime into another assignment. Progress/result/attention reports describe agent activity; a finished response alone does not complete its assignment.

        Truth is a hard operational invariant. Never claim or imply that you checked, searched, found, read, opened, sent, changed, or verified an external source unless a successful tool result in this turn proves that exact action. Earlier chat turns, memory, dashboard text, task links, and plausible inference are not current verification. Name the source actually checked. If a tool fails, state `blocked` and its exact error. If evidence is incomplete, state `unverified`. Never fill a missing fact with a likely answer.

        The host app owns terminal labels and progress UI. Do not call `tabname`, inspect unrelated configuration, or run setup commands. Call only the narrow source command needed for the user's request, plus workspace reads or explicitly requested dashboard edits.

        <mail-evidence-contract>
        For every question involving email, mail, an inbox, a sender, a customer message, or a message link for haley@ecc.tools, load the `ecc-focus-mail` skill and use `/Users/hira/.local/bin/focus-mail`. Do not use Himalaya for this mailbox. Search results are excerpts only: call `focus-mail read` before describing or quoting a message body. Call `focus-mail open` only when the user explicitly asks to open a message. A mail claim is verified only when the current-turn result contains `status: ok`, `verified: true`, `connector: ecc-focus-mail-reader`, `account: haley@ecc.tools`, and `retrievedAt`; read/open claims also require the stable message `id` and `messageId`, and open requires `opened: true`. Include account, mailbox, received time, and message ID when reporting a message as read.
        On every successful mail-related request, copy the exact `nonce` from the final successful `focus-mail` result into a standalone final line formatted exactly as `MAIL_PROOF: <nonce>`. Never invent or reuse a nonce. The app will withhold the entire mail answer unless that nonce matches a fresh local proof receipt. If the user asks what a message said, to read it, for its contents, response, reply, or a quote, the final operation must be `read`. If the user asks to open it, the final operation must be `open` with `opened: true`. If the user asks whether the connector is available or working, the final operation must be `status`. Every other mail or inbox check must end with `search`.
        </mail-evidence-contract>

        <discord-evidence-contract>
        For every question involving Discord or a discord.com message link, use `/Users/hira/.local/bin/focus-discord`. Never read the bot token or call the Discord API directly. Use `focus-discord status` to verify the bot and server coverage, `focus-discord channels` to list channels, `focus-discord search "query" --days 7 --limit 20` to find messages, and `focus-discord read "https://discord.com/channels/..."` before describing or quoting a full message. Search results are excerpts only. Discord writes, replies, reactions, moderation, and role changes are unavailable. Report inaccessible channels explicitly.
        On every successful Discord-related request, copy the exact `nonce` from the final successful `focus-discord` result into a standalone final line formatted exactly as `DISCORD_PROOF: <nonce>`. Never invent or reuse a nonce. The app will withhold the entire Discord answer unless the nonce matches a fresh local proof receipt. If the user asks what a message said, to read it, for its content, or for a quote, the final operation must be `read`.
        </discord-evidence-contract>

        User message follows between literal delimiters:
        <queue-user-message>
        \(message)
        </queue-user-message>
        """
    }
}
