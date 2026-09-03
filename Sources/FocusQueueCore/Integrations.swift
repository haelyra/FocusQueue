import Foundation

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

    public init(
        windowID: Int,
        tabID: Int? = nil,
        paneID: Int,
        cwd: String,
        isActive: Bool? = nil,
        title: String? = nil,
        tabTitle: String? = nil,
        windowTitle: String? = nil,
        ttyName: String? = nil
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
    func listAttachablePanes(
        configuration: WezTermConfiguration
    ) async throws -> [WezTermPane]

    func listRunningAgents(
        configuration: WezTermConfiguration
    ) async throws -> [RunningAgentSession]

    func attach(
        paneID: Int,
        taskID: String,
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
}

public enum WezTermError: Error, LocalizedError {
    case invalidList(String)
    case actionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidList(let detail):
            "Could not read WezTerm panes: \(detail)"
        case .actionFailed(let detail):
            "WezTerm action failed: \(detail)"
        }
    }
}

public actor WezTermController: WezTermControlling {
    private let runner: any ProcessRunning

    public init(runner: any ProcessRunning = FoundationProcessRunner()) {
        self.runner = runner
    }

    public func listAttachablePanes(
        configuration: WezTermConfiguration
    ) async throws -> [WezTermPane] {
        let result = try await listPanes(using: configuration)
        guard result.succeeded else {
            throw WezTermError.actionFailed(Self.failureDetail(result))
        }
        return Self.attachablePanes(in: try Self.decodePanes(from: result))
    }

    public func listRunningAgents(
        configuration: WezTermConfiguration
    ) async throws -> [RunningAgentSession] {
        let result = try await listPanes(using: configuration)
        guard result.succeeded else {
            throw WezTermError.actionFailed(Self.failureDetail(result))
        }
        return try await discoverAgents(in: Self.decodePanes(from: result))
    }

    public func attach(
        paneID: Int,
        taskID: String,
        configuration: WezTermConfiguration
    ) async throws {
        for arguments in [
            ["cli", "set-tab-title", "--pane-id", String(paneID), taskID],
            ["cli", "set-window-title", "--pane-id", String(paneID), taskID],
        ] {
            let result = try await runner.run(ProcessSpecification(
                executable: configuration.executable,
                arguments: arguments,
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
                        arguments: ["cli", "set-tab-title", "--pane-id", String(paneID), taskID],
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

    public func focusOrResume(
        session: TaskAgentSession,
        taskID: String,
        configuration: WezTermConfiguration
    ) async throws -> TerminalActionResult {
        let listResult = try await listPanes(using: configuration)
        if listResult.succeeded {
            let panes = try Self.decodePanes(from: listResult)
            let runningAgents = try await discoverAgents(in: panes)
            if let running = runningAgents.first(where: {
                $0.provider == session.provider && $0.sessionID == session.sessionID
            }) {
                try await focus(
                    pane: running.pane,
                    windowTitle: session.terminalWindowTitle,
                    configuration: configuration
                )
                return .focused(paneID: running.pane.paneID)
            }

            let spawn = try await runner.run(ProcessSpecification(
                executable: configuration.executable,
                arguments: Self.resumeSpawnArguments(for: session),
                timeoutSeconds: 15
            ))
            if spawn.succeeded {
                let paneID = Int(spawn.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))
                if let paneID {
                    try await labelAndActivate(
                        paneID: paneID,
                        taskID: taskID,
                        windowTitle: session.terminalWindowTitle,
                        configuration: configuration
                    )
                }
                _ = try? await bringApplicationForward(named: configuration.applicationName)
                return .resumed(
                    provider: session.provider,
                    sessionID: session.sessionID,
                    paneID: paneID
                )
            }
        }

        let fallback = try await runner.run(ProcessSpecification(
            executable: "/usr/bin/open",
            arguments: Self.resumeStandaloneArguments(
                for: session,
                applicationName: configuration.applicationName
            ),
            timeoutSeconds: 15
        ))
        guard fallback.succeeded else {
            throw WezTermError.actionFailed(Self.failureDetail(fallback))
        }
        return .resumed(
            provider: session.provider,
            sessionID: session.sessionID,
            paneID: nil
        )
    }

    public static func resumeSpawnArguments(for session: TaskAgentSession) -> [String] {
        ["cli", "spawn", "--new-window", "--cwd", session.workingDirectory, "--", "/usr/bin/env",
         session.provider.executableName]
            + session.provider.resumeArguments(sessionID: session.sessionID)
    }

    public static func resumeStandaloneArguments(
        for session: TaskAgentSession,
        applicationName: String
    ) -> [String] {
        ["-na", applicationName, "--args", "start", "--always-new-process", "--cwd",
         session.workingDirectory, "--", "/usr/bin/env", session.provider.executableName]
            + session.provider.resumeArguments(sessionID: session.sessionID)
    }

    public static func sessionID(
        for provider: AgentProvider,
        inLsofOutput output: String
    ) -> String? {
        for rawLine in output.split(whereSeparator: \Character.isNewline) {
            let line = String(rawLine)
            guard line.first == "n" else { continue }
            let path = String(line.dropFirst())
            if provider == .codex,
               path.contains("/.codex/thread-writer-locks/"),
               path.hasSuffix(".lock") {
                let candidate = URL(fileURLWithPath: path)
                    .deletingPathExtension().lastPathComponent
                if UUID(uuidString: candidate) != nil { return candidate.lowercased() }
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
            if UUID(uuidString: candidate) != nil { return candidate.lowercased() }
        }
        return nil
    }

    public static func bestMatchingPane(
        in panes: [WezTermPane],
        directory: String,
        taskID: String? = nil
    ) -> WezTermPane? {
        let target = standardizedPath(directory)

        if let taskID, !taskID.isEmpty {
            let label = taskID.lowercased()
            let tabLabeled = panes.filter {
                $0.tabTitle?.lowercased().contains(label) == true
            }
            if let pane = bestCandidate(in: tabLabeled, target: target) { return pane }

            let windowLabeled = panes.filter { pane in
                [pane.windowTitle, pane.title]
                    .compactMap { $0?.lowercased() }
                    .contains { $0.contains(label) }
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

    private func discoverAgents(in panes: [WezTermPane]) async throws -> [RunningAgentSession] {
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
        let sessionsByPID = Self.sessionIDsByProcess(
            inLsofOutput: lsofResult.standardOutput,
            providersByPID: providersByPID
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

    private static func sessionIDsByProcess(
        inLsofOutput output: String,
        providersByPID: [Int32: AgentProvider]
    ) -> [Int32: String] {
        var currentPID: Int32?
        var sessions: [Int32: String] = [:]

        for rawLine in output.split(whereSeparator: \Character.isNewline) {
            let line = String(rawLine)
            if line.first == "p" {
                currentPID = Int32(line.dropFirst())
                continue
            }
            guard let currentPID,
                  sessions[currentPID] == nil,
                  let provider = providersByPID[currentPID],
                  let sessionID = sessionID(for: provider, inLsofOutput: line)
            else { continue }
            sessions[currentPID] = sessionID
        }
        return sessions
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
        windowTitle: String,
        configuration: WezTermConfiguration
    ) async throws {
        let activation = try await runner.run(ProcessSpecification(
            executable: configuration.executable,
            arguments: ["cli", "activate-pane", "--pane-id", String(pane.paneID)],
            timeoutSeconds: 10
        ))
        guard activation.succeeded else {
            throw WezTermError.actionFailed(Self.failureDetail(activation))
        }
        _ = try? await runner.run(ProcessSpecification(
            executable: configuration.executable,
            arguments: [
                "cli", "set-window-title", "--pane-id", String(pane.paneID), windowTitle,
            ],
            timeoutSeconds: 10
        ))
        _ = try? await bringApplicationForward(named: configuration.applicationName)
    }

    private func labelAndActivate(
        paneID: Int,
        taskID: String,
        windowTitle: String,
        configuration: WezTermConfiguration
    ) async throws {
        for arguments in [
            ["cli", "set-tab-title", "--pane-id", String(paneID), taskID],
            ["cli", "activate-pane", "--pane-id", String(paneID)],
            ["cli", "set-window-title", "--pane-id", String(paneID), windowTitle],
        ] {
            let result = try await runner.run(ProcessSpecification(
                executable: configuration.executable,
                arguments: arguments,
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
        Re-read the workspace instructions, canonical dashboard, repository evidence, PR state, and the ticket's doneWhen field yourself. Do not trust the checkbox as completion evidence. Update canonical state only if the normal workspace rules permit it, and never mark a ticket resolved while any resolutionPrs entry is unmerged. Return a concise verdict with remaining work or evidence accepted. Do not inspect or transmit unrelated private notes.
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
            ],
            workingDirectory: workspace,
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
    private static let mailEvidenceURL = URL(
        fileURLWithPath: "/Users/hira/Library/Application Support/ECC Focus Queue/ingestion/mail-response.json"
    )
    private static let discordEvidenceURL = URL(
        fileURLWithPath: "/Users/hira/Library/Application Support/ECC Focus Queue/ingestion/discord-response.json"
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
        let result = try await runner.run(ProcessSpecification(
            executable: configuration.executable,
            arguments: [
                "chat",
                "--session", Self.sessionName,
                "--workspace", workspace,
                "--prompt-file", promptURL.path,
                "--timeout", String(configuration.timeoutSeconds),
            ],
            workingDirectory: workspace,
            timeoutSeconds: configuration.timeoutSeconds + 15
        ))

        let output = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let error = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        let log = [result.standardOutput, result.standardError]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        guard result.succeeded, !output.isEmpty else {
            let detail: String
            if result.timedOut {
                detail = "the request timed out"
            } else if !error.isEmpty {
                detail = error
            } else if !output.isEmpty {
                detail = output
            } else {
                detail = "Codex exited with code \(result.exitCode) without a response"
            }
            throw QueueAgentError.failed(detail)
        }
        var verifiedOutput = output
        if Self.requiresMailEvidence(message) {
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
        return nil
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

    private func verifyDiscordEvidence(
        in output: String,
        for message: String,
        requestStartedAt: Date
    ) throws -> String {
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

        Answer clarifying questions from the dashboard and workspace. You may explain ordering, clarify or reword task fields, and add or correct task links. Edit the canonical dashboard only when the user's message directly and unambiguously requests that exact change. Preserve the dashboard schema and ticket IDs. Do not resolve, cancel, or invent completion evidence. Do not turn a disagreement with local order into a canonical priority change unless the user explicitly asks for that canonical change. Keep the response concise and state any file change you made.

        Truth is a hard operational invariant. Never claim or imply that you checked, searched, found, read, opened, sent, changed, or verified an external source unless a successful tool result in this turn proves that exact action. Earlier chat turns, memory, dashboard text, task links, and plausible inference are not current verification. Name the source actually checked. If a tool fails, state `blocked` and its exact error. If evidence is incomplete, state `unverified`. Never fill a missing fact with a likely answer.

        The host app owns terminal labels and progress UI. Do not call `tabname`, inspect unrelated configuration, or run setup commands. Call only the narrow source command needed for the user's request, plus workspace reads or explicitly requested dashboard edits.

        <mail-evidence-contract>
        For every question involving email, mail, an inbox, a sender, a customer message, or a message link for haley@ecc.tools, load the `ecc-focus-mail` skill and use `/Users/hira/.local/bin/focus-mail`. Do not use Himalaya for this mailbox. Search results are excerpts only: call `focus-mail read` before describing or quoting a message body. Call `focus-mail open` only when the user explicitly asks to open a message. A mail claim is verified only when the current-turn result contains `status: ok`, `verified: true`, `connector: ecc-focus-mail-reader`, `account: haley@ecc.tools`, and `retrievedAt`; read/open claims also require the stable message `id` and `messageId`, and open requires `opened: true`. Include account, mailbox, received time, and message ID when reporting a message as read.
        On every successful mail-related request, copy the exact `nonce` from the final successful `focus-mail` result into a standalone final line formatted exactly as `MAIL_PROOF: <nonce>`. Never invent or reuse a nonce. The app will withhold the entire mail answer unless that nonce matches a fresh local proof receipt. If the user asks what a message said, to read it, for its contents, response, reply, or a quote, the final operation must be `read`. If the user asks to open it, the final operation must be `open` with `opened: true`.
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
