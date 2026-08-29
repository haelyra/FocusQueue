import Foundation

public struct WezTermPane: Codable, Equatable, Sendable {
    public let windowID: Int
    public let paneID: Int
    public let cwd: String
    public let isActive: Bool?
    public let title: String?
    public let tabTitle: String?
    public let windowTitle: String?

    public init(
        windowID: Int,
        paneID: Int,
        cwd: String,
        isActive: Bool? = nil,
        title: String? = nil,
        tabTitle: String? = nil,
        windowTitle: String? = nil
    ) {
        self.windowID = windowID
        self.paneID = paneID
        self.cwd = cwd
        self.isActive = isActive
        self.title = title
        self.tabTitle = tabTitle
        self.windowTitle = windowTitle
    }

    private enum CodingKeys: String, CodingKey {
        case windowID = "window_id"
        case paneID = "pane_id"
        case cwd
        case isActive = "is_active"
        case title
        case tabTitle = "tab_title"
        case windowTitle = "window_title"
    }
}

public enum TerminalActionResult: Equatable, Sendable {
    case focused(paneID: Int)
    case spawned(paneID: Int?)

    public var paneID: Int? {
        switch self {
        case .focused(let paneID):
            paneID
        case .spawned(let paneID):
            paneID
        }
    }

    public var message: String {
        switch self {
        case .focused:
            "Focused the matching WezTerm pane."
        case .spawned:
            "Opened a new WezTerm window in the task directory."
        }
    }
}

public protocol WezTermControlling: Sendable {
    func focusOrSpawn(
        directory: String,
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

    public func focusOrSpawn(
        directory: String,
        taskID: String,
        configuration: WezTermConfiguration
    ) async throws -> TerminalActionResult {
        let listResult = try await runner.run(ProcessSpecification(
            executable: configuration.executable,
            arguments: ["cli", "list", "--format", "json"],
            timeoutSeconds: 10
        ))

        let panes: [WezTermPane]
        if listResult.succeeded {
            guard let data = listResult.standardOutput.data(using: .utf8) else {
                throw WezTermError.invalidList("output was not UTF-8")
            }
            do {
                panes = try JSONDecoder().decode([WezTermPane].self, from: data)
            } catch {
                throw WezTermError.invalidList(error.localizedDescription)
            }
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

    public static func bestMatchingPane(
        in panes: [WezTermPane],
        directory: String,
        taskID: String? = nil
    ) -> WezTermPane? {
        let target = standardizedPath(directory)
        let candidates = panes.filter { pane in
            let panePath = standardizedPath(pathFromWezTermCWD(pane.cwd))
            return panePath == target || panePath.hasPrefix(target + "/")
        }
        guard !candidates.isEmpty else { return nil }

        if let taskID, !taskID.isEmpty {
            let label = taskID.lowercased()
            let labeled = candidates.filter { pane in
                [pane.tabTitle, pane.windowTitle, pane.title]
                    .compactMap { $0?.lowercased() }
                    .contains { $0.contains(label) }
            }
            if let pane = bestCandidate(in: labeled, target: target) { return pane }
        }

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

    private func bringApplicationForward(named applicationName: String) async throws -> ProcessResult {
        try await runner.run(ProcessSpecification(
            executable: "/usr/bin/open",
            arguments: ["-a", applicationName],
            timeoutSeconds: 10
        ))
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

public actor HermesCompletionVerifier: CompletionVerifying {
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
                summary: "Hermes completion review is disabled in config.json.",
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
                "chat",
                "--quiet",
                "--continue", configuration.sessionName,
                "--create-if-missing",
                "--in", workspace,
                "--source", "tool",
                "--checkpoints",
                "--max-turns", String(configuration.maxTurns),
                "--run-budget", String(configuration.timeoutSeconds),
                "--query-file", promptURL.path
            ],
            workingDirectory: workspace,
            timeoutSeconds: configuration.timeoutSeconds + 15
        ))

        let combinedLog = [result.standardOutput, result.standardError]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let trimmedOutput = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = result.timedOut
            ? "Hermes review timed out and remains pending."
            : "Hermes review failed with exit code \(result.exitCode)."
        return VerificationRunResult(
            succeeded: result.succeeded,
            summary: trimmedOutput.isEmpty ? fallback : trimmedOutput,
            log: combinedLog.isEmpty ? fallback : combinedLog
        )
    }
}
