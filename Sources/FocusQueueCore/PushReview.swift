import Foundation

public struct PushReviewReceipt: Codable, Sendable {
    public let taskID: String
    public let subtaskID: String
    public let commit: String
    public let baseCommit: String
    public let accepted: Bool
    public let explanation: String
    public let reviewedAt: Date
}

/// Explicit agent handoff: a rejected scan returns actionable feedback to the calling agent.
/// It never pushes, resets, or edits the working tree itself.
public actor PushReviewer {
    private let runner: any ProcessRunning
    public init(runner: any ProcessRunning = FoundationProcessRunner()) { self.runner = runner }

    public func review(context: TaskContext, subtask: TaskSubtask, configuration: VerifierConfiguration,
                       supportDirectory: URL) async throws -> PushReviewReceipt {
        guard configuration.enabled, let workspace = subtask.workspace,
              let base = workspace.baseCommit else {
            throw TaskContextError.commandFailed("Push review requires an enabled verifier and a saved agent workspace with a base commit.")
        }
        try await TaskWorktreeManager(runner: runner).validate(workspace)
        let head = try await git(["rev-parse", "HEAD"], path: workspace.path)
        let status = try await git(["status", "--porcelain", "--untracked-files=all"], path: workspace.path)
        guard status.isEmpty else { throw TaskContextError.commandFailed("Commit or preserve pending changes before requesting a push review.") }
        let directory = context.contextDirectory.appendingPathComponent("push-reviews")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let promptURL = directory.appendingPathComponent("\(id).prompt.txt")
        let prompt = """
        Perform a brief read-only pre-push review of task \(context.ticketID), assignment \(subtask.title).
        Initial request: \(subtask.initialPrompt ?? subtask.title)
        Read the central plan at \(context.planPath). Inspect git diff \(base)..\(head) in \(workspace.path), including the file list and relevant contents.
        Find accidental additions, unrelated edits, generated files, local context or logs, and changes outside the assignment. Preserve legitimate user and other-agent work. Do not edit, commit, push, reset, or change task status.
        Start the final response with exactly ACCEPT or REJECT on its own line, followed by a concise explanation and specific corrections. ACCEPT only after actually inspecting the diff. On REJECT, tell the calling agent precisely what to fix and ask it to run review-push again before pushing.
        """
        try Data(prompt.utf8).write(to: promptURL, options: .atomic)
        PromptUsageMetrics.record(PromptUsageEvent(source: "push_review", component: "app_context",
            provider: subtask.provider.rawValue, taskID: context.ticketID,
            characters: max(0, prompt.count - (subtask.initialPrompt?.count ?? 0)), runID: id), in: supportDirectory)
        var environment = CodexCompletionVerifier.agentEnvironment(configuration)
        environment["FOCUS_QUEUE_SUPPORT_DIR"] = supportDirectory.path
        environment["FOCUS_QUEUE_MODEL_USAGE_SOURCE"] = "push_review"
        environment["FOCUS_QUEUE_MODEL_USAGE_RUN_ID"] = id
        let result = try await runner.run(.init(executable: configuration.executable,
            arguments: ["run", "--workspace", workspace.path, "--prompt-file", promptURL.path,
                        "--timeout", String(configuration.timeoutSeconds), "--sandbox", "read-only",
                        "--label", "focus-queue-push-review", "--context-dir", context.contextDirectory.path],
            workingDirectory: workspace.path, environment: environment, timeoutSeconds: configuration.timeoutSeconds + 15))
        let output = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalHead = try await git(["rev-parse", "HEAD"], path: workspace.path)
        let finalStatus = try await git(["status", "--porcelain", "--untracked-files=all"], path: workspace.path)
        let unchanged = finalHead == head && finalStatus.isEmpty
        let accepted = result.succeeded && unchanged && output.components(separatedBy: "\n").first == "ACCEPT"
        let receipt = PushReviewReceipt(taskID: context.ticketID, subtaskID: subtask.id,
            commit: head, baseCommit: base, accepted: accepted,
            explanation: unchanged ? (output.isEmpty ? "Review failed: \(result.standardError)" : output)
                : "The checkout changed during review. Review the new commit before pushing.", reviewedAt: Date())
        try JSONEncoder().encode(receipt).write(to: directory.appendingPathComponent("\(id).json"), options: .atomic)
        return receipt
    }

    private func git(_ arguments: [String], path: String) async throws -> String {
        let result = try await runner.run(.init(executable: "/usr/bin/git", arguments: arguments, workingDirectory: path))
        guard result.succeeded else { throw TaskContextError.commandFailed(result.standardError) }
        return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
