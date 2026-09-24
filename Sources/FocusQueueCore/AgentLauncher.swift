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
  private let tmuxServerName: String
  public init(
    runner: any ProcessRunning = FoundationProcessRunner(),
    candidateSockets: [String]? = nil,
    tmuxServerName: String = TmuxController.serverName
  ) {
    self.runner = runner
    self.candidateSockets = candidateSockets
    self.tmuxServerName = tmuxServerName
  }

  public static func command(context: TaskContext, subtask: TaskSubtask, supportDirectory: URL,
                             includePrompt: Bool = true, shellPath: String? = nil) throws -> [String] {
    guard let directory = (subtask.workspace?.path ?? context.worktreePath), directory.hasPrefix("/") else {
      throw TaskContextError.unsafeWorktree("Choose a task worktree before launching an agent.")
    }
    var providerArguments: [String] = []
    if let model = subtask.launchConfiguration?.model?.trimmingCharacters(in: .whitespacesAndNewlines),
       !model.isEmpty {
      providerArguments += ["--model", model]
    }
    if let effort = subtask.launchConfiguration?.effort?.trimmingCharacters(in: .whitespacesAndNewlines),
       !effort.isEmpty {
      providerArguments += subtask.provider == .codex
        ? ["-c", "model_reasoning_effort=\(effort)"]
        : ["--effort", effort]
    }
    providerArguments += ["--add-dir", context.contextDirectory.path]
    if let sessionID = subtask.sessionID {
      guard UUID(uuidString: sessionID) != nil else {
        throw TaskContextError.commandFailed("The saved provider session ID is invalid.")
      }
      providerArguments = subtask.provider == .codex
        ? ["resume", sessionID, "--cd", directory] + providerArguments
        : ["--resume", sessionID] + providerArguments
    } else if includePrompt && subtask.includeInitializationPrompt {
      if subtask.provider == .claude { providerArguments.append("--") }
      providerArguments.append(context.agentPrompt(subtask: subtask))
    } else if includePrompt {
      if subtask.provider == .claude { providerArguments.append("--") }
      providerArguments.append(context.agentBootstrap(subtask: subtask))
    }
    var focusEnvironment = [
            "/usr/bin/env", "-u", "FOCUS_QUEUE_ROUTER", "-u", "FOCUS_QUEUE_ROUTER_SOURCE",
            "-u", "FOCUS_QUEUE_ROUTER_CAPABILITY",
            "FOCUS_QUEUE_SUPPORT_DIR=\(supportDirectory.path)",
            "FOCUS_QUEUE_PROVIDER=\(subtask.provider.rawValue)",
            "FOCUS_QUEUE_SUBTASK_ID=\(subtask.id)", "FOCUS_QUEUE_TASK_ID=\(context.ticketID)"]
    focusEnvironment.append("FOCUS_QUEUE_RUNTIME_MODE=\(subtask.runtimeMode?.rawValue ?? "legacy")")
    if let routeID = subtask.launchConfiguration?.routeID,
       UUID(uuidString: routeID) != nil {
      let capsule = supportDirectory.appendingPathComponent("tracking/placements")
        .appendingPathComponent(routeID.lowercased() + ".json")
      focusEnvironment += ["FOCUS_QUEUE_LAUNCH_ID=\(routeID.lowercased())",
                           "FOCUS_QUEUE_AGENT_CONTEXT=\(capsule.path)"]
    }
    return focusEnvironment + InteractiveAgentShell.command(provider: subtask.provider, arguments: providerArguments,
          shellPath: shellPath, workingDirectory: directory)
  }

  public func identify(subtask: TaskSubtask, configuration: WezTermConfiguration) async throws -> String? {
    let controller = WezTermController(runner: runner, candidateSockets: candidateSockets)
    let candidates: [RunningAgentSession]
    if let tmux = subtask.tmux {
      guard FileManager.default.isExecutableFile(atPath: tmux.executable) else { return nil }
      _ = try await TmuxController(runner: runner, serverName: tmuxServerName).verify(tmux)
      candidates = try await controller.agents(onTTY: tmux.tty)
    } else if let paneID = subtask.terminalPaneID {
      guard FileManager.default.isExecutableFile(atPath: configuration.executable) else { return nil }
      var requested = configuration
      requested.socketPath = subtask.terminalSocketPath ?? requested.socketPath
      candidates = try await controller.listRunningAgents(configuration: requested).filter {
        $0.pane.paneID == paneID && (subtask.terminalSocketPath == nil || $0.pane.socketPath == subtask.terminalSocketPath)
      }
    } else { return nil }
    let matching = candidates.filter { $0.provider == subtask.provider }
    return matching.count == 1 ? matching.first?.sessionID : nil
  }

  /// Read-only inspection. A failed connection is not evidence that a process ended.
  public func runtimeAttention(subtask: TaskSubtask, configuration: WezTermConfiguration) async throws -> AgentAttention? {
    let output: ProcessResult
    if let tmux = subtask.tmux {
      do { _ = try await TmuxController(runner: runner, serverName: tmuxServerName).verify(tmux) }
      catch TmuxError.stopped { return .interrupted }
      output = try await runner.run(.init(executable: tmux.executable,
        arguments: ["-L", tmuxServerName, "capture-pane", "-p", "-t", tmux.paneID],
        environment: ["TMUX_TMPDIR": "/tmp"]))
    } else if let paneID = subtask.terminalPaneID {
      var requested = configuration
      requested.socketPath = subtask.terminalSocketPath ?? configuration.socketPath
      let connection = try await WezTermConnection.resolve(configuration: requested, runner: runner, candidateSockets: candidateSockets)
      guard connection.result.succeeded else { throw WezTermError.actionFailed("Could not inspect the agent terminal.") }
      guard subtask.terminalSocketPath == nil || connection.configuration.socketPath == subtask.terminalSocketPath else { return nil }
      let panes = try JSONDecoder().decode([WezTermPane].self, from: Data(connection.result.standardOutput.utf8))
      guard let pane = panes.first(where: { $0.paneID == paneID }) else { return .interrupted }
      guard let sessionID = subtask.sessionID, let tty = pane.ttyName else { return nil }
      let agents = try await WezTermController(runner: runner).agents(onTTY: tty)
      guard agents.contains(where: { $0.provider == subtask.provider && $0.sessionID.lowercased() == sessionID.lowercased() }) else { return nil }
      output = try await runner.run(.init(executable: connection.configuration.executable,
        arguments: ["cli", "get-text", "--pane-id", String(paneID)], environment: connection.configuration.cliEnvironment))
    } else { return nil }
    guard output.succeeded else { return nil }
    return Self.terminalAttention(output.standardOutput)
  }

  public static func terminalAttention(_ text: String) -> AgentAttention? {
    let lines = text.split(separator: "\n").suffix(24).map {
      $0.trimmingCharacters(in: .whitespaces).lowercased()
    }
    // Require both a provider confirmation prompt and its choice control, not just prose.
    let prompt = lines.contains { line in
      ["would you like to run the following command?", "do you want to proceed?",
       "do you want to make this edit?", "do you want to allow this?"].contains(line)
    }
    let choices = lines.contains { $0.contains("1. yes") } && lines.contains { $0.contains("esc") || $0.contains("no") }
    return prompt && choices ? .approval : nil
  }

  /// Completion preserves a terminal shell and exact resume instructions. Explicit
  /// removal continues to use closeRuntime instead.
  public func finishRuntime(context: TaskContext, subtask: TaskSubtask, taskCompleted: Bool,
                            configuration: WezTermConfiguration) async throws -> AgentCompletionTerminal {
    guard subtask.tmux != nil || subtask.terminalPaneID != nil else { return .absent }
    let message = try AgentCompletionMessage(context: context, subtask: subtask, taskCompleted: taskCompleted)
    if let saved = subtask.tmux {
      do {
        return .managed(try await TmuxController(runner: runner, serverName: tmuxServerName)
          .finish(saved, message: message))
      } catch TmuxError.stopped { return .absent }
    }
    guard let paneID = subtask.terminalPaneID else { return .absent }
    var requested = configuration
    requested.socketPath = subtask.terminalSocketPath ?? configuration.socketPath
    let connection = try await WezTermConnection.resolve(configuration: requested, runner: runner, candidateSockets: candidateSockets)
    guard connection.result.succeeded,
          subtask.terminalSocketPath == nil || connection.configuration.socketPath == subtask.terminalSocketPath else {
      throw WezTermError.actionFailed("Could not verify the completed agent terminal; it was retained.")
    }
    let panes = try JSONDecoder().decode([WezTermPane].self, from: Data(connection.result.standardOutput.utf8))
    guard let pane = panes.first(where: { $0.paneID == paneID }) else { return .absent }
    guard let tty = pane.ttyName, let session = subtask.sessionID else {
      throw WezTermError.actionFailed("The completed terminal has no verifiable provider identity; it was retained.")
    }
    let agents = try await WezTermController(runner: runner).agents(onTTY: tty)
    guard agents.contains(where: { $0.provider == subtask.provider && $0.sessionID.caseInsensitiveCompare(session) == .orderedSame }) else {
      throw WezTermError.actionFailed("The terminal's conversation changed; it was retained.")
    }
    // Direct WezTerm panes cannot be respawned. Create the completion shell in
    // the same window before removing the verified provider pane.
    let result = try await runner.run(.init(executable: connection.configuration.executable,
      arguments: ["cli", "split-pane", "--pane-id", String(paneID), "--cwd", message.directory, "--"] + message.command(),
      environment: connection.configuration.cliEnvironment))
    guard result.succeeded, let completionPane = Int(result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)),
          completionPane >= 0, completionPane != paneID else {
      throw WezTermError.actionFailed("Could not open the completion shell; the agent terminal was retained.")
    }
    try await closeRuntime(subtask: subtask, configuration: connection.configuration)
    return .direct(.init(paneID: completionPane, socketPath: connection.configuration.socketPath))
  }

  /// Close only a verified runtime; a reused terminal identity is never sufficient.
  public func closeRuntime(subtask: TaskSubtask, configuration: WezTermConfiguration) async throws {
    if let tmux = subtask.tmux {
      try await TmuxController(runner: runner, serverName: tmuxServerName).stop(tmux)
      return
    }
    guard let paneID = subtask.terminalPaneID else { return }
    var requested = configuration
    requested.socketPath = subtask.terminalSocketPath ?? configuration.socketPath
    let connection = try await WezTermConnection.resolve(configuration: requested, runner: runner, candidateSockets: candidateSockets)
    guard connection.result.succeeded else { throw WezTermError.actionFailed("Could not inspect the terminal for cleanup.") }
    if let socket = subtask.terminalSocketPath, connection.configuration.socketPath != socket { return }
    let panes = try JSONDecoder().decode([WezTermPane].self, from: Data(connection.result.standardOutput.utf8))
    guard let pane = panes.first(where: { $0.paneID == paneID }) else { return }
    guard let tty = pane.ttyName, let sessionID = subtask.sessionID else {
      throw WezTermError.actionFailed("Agent removed from the list. Its terminal was retained because its provider identity could not be verified.")
    }
    let agents = try await WezTermController(runner: runner).agents(onTTY: tty)
    guard agents.contains(where: { $0.provider == subtask.provider && $0.sessionID.caseInsensitiveCompare(sessionID) == .orderedSame }) else { return }
    let result = try await runner.run(.init(executable: connection.configuration.executable,
      arguments: ["cli", "kill-pane", "--pane-id", String(paneID)], environment: connection.configuration.cliEnvironment))
    guard result.succeeded else { throw WezTermError.actionFailed("Could not close the agent terminal.") }
  }

  /// Starts the provider inside a dedicated tmux session and returns its exact
  /// identity. Callers persist this value before opening any terminal view.
  public func startManagedSession(
    context: TaskContext, subtask: TaskSubtask, supportDirectory: URL,
    includePrompt: Bool = true, tmuxExecutable: String
  ) async throws -> TmuxSessionReference {
    if let workspace = subtask.workspace { try await TaskWorktreeManager().validate(workspace) }
    if subtask.tmux != nil, subtask.sessionID == nil {
      throw TaskContextError.commandFailed("This stopped agent has no saved conversation to resume. Start New Agent with a fresh assignment.")
    }
    let command = try Self.command(
      context: context, subtask: subtask, supportDirectory: supportDirectory,
      includePrompt: includePrompt)
    let persistence = FileManager.default.isExecutableFile(atPath: tmuxExecutable)
      ? try TmuxPersistence.prepare(executable: tmuxExecutable, serverName: tmuxServerName,
          supportDirectory: supportDirectory) : nil
    let runtime = TmuxController(runner: runner, serverName: tmuxServerName,
      configurationPath: persistence?.configurationURL.path ?? "/dev/null")
    let reference = try await runtime.startAgent(
      taskID: context.ticketID, subtaskID: subtask.id,
      directory: (subtask.workspace?.path ?? context.worktreePath)!, command: command,
      executable: tmuxExecutable)
    try? await runtime.label(reference, title: "\(subtask.provider.displayName): \(subtask.title)")
    if let persistence {
      // Persistence is supplementary. Once the provider is live, a setup
      // warning must never turn success into a retry that can duplicate it.
      do { try await persistence.enable(runner: runner) }
      catch { NSLog("Focus Queue tmux persistence setup warning: %@", error.localizedDescription) }
    }
    let bundledHelper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/focus-queue-session").path
    if let helper = [bundledHelper, SetupEnvironment.executable("focus-queue-session")].compactMap({ $0 })
      .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
      try? await runtime.configureTask(name: reference.name, executable: tmuxExecutable,
        helper: helper, supportDirectory: supportDirectory)
    }
    return reference
  }

  /// Starts a terminal-owned provider process and records its transient pane.
  /// A later launch can resume the independently saved provider conversation.
  public func launchDirect(
    context: TaskContext, subtask: TaskSubtask,
    configuration: WezTermConfiguration, supportDirectory: URL,
    includePrompt: Bool = true
  ) async throws -> DirectAgentLaunchReceipt {
    if let workspace = subtask.workspace {
      try await TaskWorktreeManager().validate(workspace)
    }
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
        workingDirectory: (subtask.workspace?.path ?? context.worktreePath), timeoutSeconds: 15))
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
        (subtask.workspace?.path ?? context.worktreePath)!, "--",
      ] + command,
      workingDirectory: (subtask.workspace?.path ?? context.worktreePath), environment: pinned.cliEnvironment,
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
