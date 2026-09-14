import Foundation
import Darwin

/// Only the fixed provider name is shell syntax. Task text remains positional data.
public enum InteractiveAgentShell {
  public static func executable(preferred: String? = nil) -> String {
    let loginShell = getpwuid(getuid()).flatMap { $0.pointee.pw_shell }.map { String(cString: $0) }
    for candidate in [preferred, loginShell, ProcessInfo.processInfo.environment["SHELL"], "/bin/zsh"].compactMap({ $0 }) {
      if ["zsh", "bash"].contains(URL(fileURLWithPath: candidate).lastPathComponent),
         candidate.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return "/bin/zsh"
  }

  public static func command(provider: AgentProvider, arguments: [String], shellPath: String? = nil,
                             workingDirectory: String? = nil) -> [String] {
    // Literal command words are expanded through the user's aliases and shell functions.
    // An exec prefix would bypass functions; interpolating arbitrary text would permit injection.
    var script = ""
    var positional: [String] = []
    if let workingDirectory {
      // Login profiles are allowed to change directory; restore the saved path
      // afterwards, using positional data instead of interpolating shell code.
      script = "builtin cd -- \"$1\" || exit 72; shift; "
      positional.append(workingDirectory)
    }
    script += "\(provider.executableName) \"$@\""
    return [executable(preferred: shellPath), "-lic", script, "focus-queue-agent"] + positional + arguments
  }
}

public struct DirectAgentLaunchReceipt: Equatable, Sendable {
  public let paneID: Int
  public let socketPath: String?
}

/// Launches a provider with a concrete assignment. No task content is shell code.
public actor TaskAgentLauncher {
  private let runner: any ProcessRunning
  private let candidateSockets: [String]?
  public init(
    runner: any ProcessRunning = FoundationProcessRunner(),
    candidateSockets: [String]? = nil
  ) {
    self.runner = runner
    self.candidateSockets = candidateSockets
  }

  public static func command(context: TaskContext, subtask: TaskSubtask, supportDirectory: URL,
                             includePrompt: Bool = true, shellPath: String? = nil) throws -> [String] {
    guard let directory = context.worktreePath, directory.hasPrefix("/") else {
      throw TaskContextError.unsafeWorktree("Choose a task worktree before launching an agent.")
    }
    var providerArguments = ["--add-dir", context.contextDirectory.path]
    if includePrompt && subtask.includeInitializationPrompt {
      if subtask.provider == .claude { providerArguments.append("--") }
      providerArguments.append(context.agentPrompt(subtask: subtask))
    }
    return ["/usr/bin/env", "FOCUS_QUEUE_SUPPORT_DIR=\(supportDirectory.path)",
            "FOCUS_QUEUE_PROVIDER=\(subtask.provider.rawValue)",
            "FOCUS_QUEUE_SUBTASK_ID=\(subtask.id)", "FOCUS_QUEUE_TASK_ID=\(context.ticketID)"]
      + ["FOCUS_QUEUE_RUNTIME_MODE=\(subtask.runtimeMode?.rawValue ?? "legacy")"]
      + InteractiveAgentShell.command(provider: subtask.provider, arguments: providerArguments,
          shellPath: shellPath, workingDirectory: directory)
  }

  /// Starts the provider inside a dedicated tmux session and returns its exact
  /// identity. Callers persist this value before opening any terminal view.
  public func startManagedSession(
    context: TaskContext, subtask: TaskSubtask, supportDirectory: URL,
    includePrompt: Bool = true, tmuxExecutable: String
  ) async throws -> TmuxSessionReference {
    let command = try Self.command(
      context: context, subtask: subtask, supportDirectory: supportDirectory,
      includePrompt: includePrompt)
    let name = try TmuxController.sessionName(subtaskID: subtask.id)
    let runtime = TmuxController(runner: runner)
    return try await runtime.start(
      name: name, directory: context.worktreePath!, command: command,
      executable: tmuxExecutable)
  }

  /// Starts an ordinary terminal-owned provider process. Closing that terminal
  /// ends the live runtime, so the returned pane is the only recall target.
  public func launchDirect(
    context: TaskContext, subtask: TaskSubtask,
    configuration: WezTermConfiguration, supportDirectory: URL,
    includePrompt: Bool = true
  ) async throws -> DirectAgentLaunchReceipt {
    let command = try Self.command(
      context: context, subtask: subtask, supportDirectory: supportDirectory,
      includePrompt: includePrompt)
    var connection = try await WezTermConnection.resolve(
      configuration: configuration, runner: runner, candidateSockets: candidateSockets)
    guard !connection.result.timedOut else {
      throw WezTermError.actionFailed("WezTerm lookup timed out. No direct agent launch was attempted.")
    }
    if !connection.result.succeeded {
      let bootstrap = try await runner.run(ProcessSpecification(
        executable: "/usr/bin/open", arguments: ["-a", configuration.applicationName],
        workingDirectory: context.worktreePath, timeoutSeconds: 15))
      guard bootstrap.succeeded else {
        throw WezTermError.actionFailed(
          "Could not start WezTerm. \(String(bootstrap.standardError.prefix(1_000)))")
      }
      for _ in 0..<5 {
        connection = try await WezTermConnection.resolve(
          configuration: configuration, runner: runner, candidateSockets: candidateSockets)
        if connection.result.succeeded || connection.result.timedOut { break }
        try await Task.sleep(for: .milliseconds(300))
      }
      guard connection.result.succeeded else {
        throw WezTermError.actionFailed(
          "WezTerm opened without a usable connection. No direct agent launch was confirmed.")
      }
    }
    let pinned = connection.configuration
    let result = try await runner.run(ProcessSpecification(
      executable: pinned.executable,
      arguments: [
        "cli", "spawn", "--new-window", "--domain-name", "local", "--cwd",
        context.worktreePath!, "--",
      ] + command,
      workingDirectory: context.worktreePath, environment: pinned.cliEnvironment,
      timeoutSeconds: 15))
    guard result.succeeded else {
      throw WezTermError.actionFailed(result.timedOut
        ? "Direct agent launch timed out. Check WezTerm before retrying."
        : String(result.standardError.prefix(1_000)))
    }
    guard let paneID = Int(result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)),
      paneID >= 0 else {
      throw WezTermError.actionFailed("WezTerm did not return a valid pane identity.")
    }
    return DirectAgentLaunchReceipt(paneID: paneID, socketPath: pinned.socketPath)
  }
}
