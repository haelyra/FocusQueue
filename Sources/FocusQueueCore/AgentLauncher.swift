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

/// Codex refuses to resume an unloaded multi-agent sub-agent thread directly;
/// only the root conversation of its lineage accepts a native resume. Rollout
/// metadata records each thread's parent, so the resumable identity for any
/// saved session is the root ancestor of its family.
public enum CodexSessionLineage {
  public static func root(of sessionID: String, codexRoot: URL? = nil) -> String {
    let home = codexRoot
      ?? ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    var current = sessionID.lowercased()
    var visited: Set<String> = [current]
    var resolved = false
    while let parent = parentThreadID(of: current, codexRoot: home), !visited.contains(parent) {
      visited.insert(parent)
      current = parent
      resolved = true
    }
    // Without rollout evidence the saved identity is already the resume target;
    // preserve it byte-for-byte, including case.
    return resolved ? current : sessionID
  }

  private static func parentThreadID(of sessionID: String, codexRoot: URL) -> String? {
    guard UUID(uuidString: sessionID) != nil else { return nil }
    for subdirectory in ["sessions", "archived_sessions"] {
      let root = codexRoot.appendingPathComponent(subdirectory, isDirectory: true)
      guard let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles, .skipsPackageDescendants])
      else { continue }
      for case let file as URL in enumerator {
        guard file.pathExtension == "jsonl",
              file.lastPathComponent.lowercased().contains(sessionID),
              let handle = try? FileHandle(forReadingFrom: file),
              let line = try? handle.readLine(),
              let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let payload = record["payload"] as? [String: Any]
        else { continue }
        try? handle.close()
        for key in ["parent_thread_id", "session_id"] {
          if let parent = (payload[key] as? String)?.lowercased(),
             parent != sessionID, UUID(uuidString: parent) != nil {
            return parent
          }
        }
        return nil
      }
    }
    return nil
  }
}

extension FileHandle {
  fileprivate func readLine() throws -> String? {
    var data = Data()
    while let byte = try read(upToCount: 1), !byte.isEmpty {
      if byte[0] == 0x0A { break }
      data.append(byte)
    }
    return data.isEmpty ? nil : String(data: data, encoding: .utf8)
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
  private let processController: WezTermController
  public init(
    runner: any ProcessRunning = FoundationProcessRunner(),
    candidateSockets: [String]? = nil,
    tmuxServerName: String = TmuxController.serverName
  ) {
    self.runner = runner
    self.candidateSockets = candidateSockets
    self.tmuxServerName = tmuxServerName
    self.processController = WezTermController(runner: runner, candidateSockets: candidateSockets)
  }

  public static func command(context: TaskContext, subtask: TaskSubtask, supportDirectory: URL,
                             includePrompt: Bool = true, shellPath: String? = nil,
                             usageBarEnabled: Bool = true, codexRoot: URL? = nil) throws -> [String] {
    guard let directory = (subtask.workspace?.path ?? context.worktreePath), directory.hasPrefix("/") else {
      throw TaskContextError.unsafeWorktree("Choose a task worktree before launching an agent.")
    }
    // Managed Codex sessions run without the shared app-server daemon so the
    // pane keeps its own rollout writer lock, session identity, and environment.
    var providerArguments: [String] = subtask.provider == .codex ? ["--no-daemon"] : []
    if let model = subtask.launchConfiguration?.model?.trimmingCharacters(in: .whitespacesAndNewlines),
       !model.isEmpty {
      providerArguments += ["--model", model]
    }
    if let effort = subtask.launchConfiguration?.effort?.trimmingCharacters(in: .whitespacesAndNewlines),
       !effort.isEmpty {
      providerArguments += subtask.provider.effortArguments(effort: effort)
    }
    providerArguments += subtask.provider.pluginArguments(
      overrides: subtask.launchConfiguration?.pluginOverrides ?? [:])
    providerArguments += ["--add-dir", context.contextDirectory.path]
    if let sessionID = subtask.sessionID {
      guard subtask.provider.isValidSessionID(sessionID) else {
        throw TaskContextError.commandFailed("The saved provider session ID is invalid.")
      }
      providerArguments = subtask.provider == .codex
        ? ["resume", CodexSessionLineage.root(of: sessionID, codexRoot: codexRoot), "--cd", directory] + providerArguments
        : subtask.provider.resumeArguments(sessionID: sessionID) + providerArguments
    } else if includePrompt && subtask.includeInitializationPrompt {
      providerArguments += promptArguments(for: subtask.provider, prompt: context.agentPrompt(subtask: subtask))
    } else if includePrompt {
      providerArguments += promptArguments(for: subtask.provider, prompt: context.agentBootstrap(subtask: subtask))
    }
    var focusEnvironment = [
            "/usr/bin/env", "FOCUS_QUEUE_SUPPORT_DIR=\(supportDirectory.path)",
            "FOCUS_QUEUE_USAGE_BAR=\(usageBarEnabled ? "on" : "off")",
            "FOCUS_QUEUE_PROVIDER=\(subtask.provider.rawValue)",
            "FOCUS_QUEUE_SUBTASK_ID=\(subtask.id)", "FOCUS_QUEUE_TASK_ID=\(context.ticketID)"]
    focusEnvironment.append("FOCUS_QUEUE_RUNTIME_MODE=\(subtask.runtimeMode?.rawValue ?? "legacy")")
    if let launchID = subtask.launchConfiguration?.routeID ?? subtask.launchConfiguration?.launchID,
       UUID(uuidString: launchID) != nil {
      let capsule = supportDirectory.appendingPathComponent("tracking/placements")
        .appendingPathComponent(launchID.lowercased() + ".json")
      focusEnvironment += ["FOCUS_QUEUE_LAUNCH_ID=\(launchID.lowercased())",
                           "FOCUS_QUEUE_AGENT_CONTEXT=\(capsule.path)"]
    }
    return focusEnvironment + InteractiveAgentShell.command(provider: subtask.provider, arguments: providerArguments,
          shellPath: shellPath, workingDirectory: directory)
  }

  /// Codex takes a positional prompt, Claude one after `--`; Kimi only accepts
  /// prompts through `--prompt` (non-interactive mode, exits when done).
  private static func promptArguments(for provider: AgentProvider, prompt: String) -> [String] {
    switch provider {
    case .codex: [prompt]
    case .claude: ["--", prompt]
    case .kimi: ["--prompt", prompt]
    }
  }

  public func identify(subtask: TaskSubtask, configuration: WezTermConfiguration) async throws -> String? {
    let controller = processController
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
      let connection = try await processController.resolveConnection(configuration: requested)
      guard connection.result.succeeded else { throw WezTermError.actionFailed("Could not inspect the agent terminal.") }
      guard subtask.terminalSocketPath == nil || connection.configuration.socketPath == subtask.terminalSocketPath else { return nil }
      let panes = try JSONDecoder().decode([WezTermPane].self, from: Data(connection.result.standardOutput.utf8))
      guard let pane = panes.first(where: { $0.paneID == paneID }) else { return .interrupted }
      guard let sessionID = subtask.sessionID, let tty = pane.ttyName else { return nil }
      let agents = try await processController.agents(onTTY: tty)
      guard agents.contains(where: { $0.provider == subtask.provider && $0.sessionID.lowercased() == sessionID.lowercased() }) else { return nil }
      output = try await runner.run(.init(executable: connection.configuration.executable,
        arguments: ["cli", "get-text", "--pane-id", String(paneID)], environment: connection.configuration.cliEnvironment))
    } else { return nil }
    guard output.succeeded else { return nil }
    return Self.terminalAttention(output.standardOutput)
  }

  /// Terminal state captured once per refresh tick: one tmux pane listing per
  /// executable and one WezTerm connection per socket cover every subtask.
  public struct RuntimeSnapshot: Sendable {
    var tmuxPanes: [String: [TmuxPaneSnapshot]] = [:]
    var connections: [String: (configuration: WezTermConfiguration, panes: [WezTermPane])] = [:]

    static func socketKey(_ socketPath: String?) -> String { socketPath ?? "" }
  }

  public func runtimeSnapshot(subtasks: [TaskSubtask], configuration: WezTermConfiguration) async -> RuntimeSnapshot {
    var snapshot = RuntimeSnapshot()
    for executable in Set(subtasks.compactMap(\.tmux?.executable))
    where FileManager.default.isExecutableFile(atPath: executable) {
      if let panes = try? await TmuxController(runner: runner, serverName: tmuxServerName)
        .panes(executable: executable) {
        snapshot.tmuxPanes[executable] = panes
      }
    }
    let sockets = Set(subtasks.filter { $0.tmux == nil && $0.terminalPaneID != nil }
      .map { RuntimeSnapshot.socketKey($0.terminalSocketPath ?? configuration.socketPath) })
    for key in sockets {
      var requested = configuration
      requested.socketPath = key.isEmpty ? nil : key
      guard let connection = try? await processController.resolveConnection(configuration: requested),
            connection.result.succeeded,
            let panes = try? JSONDecoder().decode([WezTermPane].self, from: Data(connection.result.standardOutput.utf8))
      else { continue }
      snapshot.connections[key] = (connection.configuration, panes)
    }
    return snapshot
  }

  /// One shared listing answers every subtask check. Presence in the result
  /// means the runtime state was determined; a fresh heartbeat skips the pane
  /// capture because structured events already report attention.
  public func runtimeAttention(
    subtasks: [TaskSubtask], configuration: WezTermConfiguration, snapshot: RuntimeSnapshot,
    heartbeatGraceSeconds: TimeInterval = 15
  ) async -> [String: AgentAttention?] {
    var results: [String: AgentAttention?] = [:]
    for subtask in subtasks {
      guard case .report(let attention) = try? await probedAttention(
        subtask: subtask, configuration: configuration,
        snapshot: snapshot, heartbeatGraceSeconds: heartbeatGraceSeconds)
      else { continue }
      results[subtask.id] = attention
    }
    return results
  }

  /// Identity lookups share the tick's pane listing; direct panes keep their
  /// per-subtask connection probe because they are rare next to tmux runtimes.
  public func identify(
    subtasks: [TaskSubtask], configuration: WezTermConfiguration, snapshot: RuntimeSnapshot
  ) async -> [String: String] {
    var identities: [String: String] = [:]
    for subtask in subtasks {
      let identity: String?
      if subtask.tmux != nil {
        identity = try? await identifyManaged(subtask: subtask, snapshot: snapshot)
      } else {
        identity = try? await identify(subtask: subtask, configuration: configuration)
      }
      if let identity { identities[subtask.id] = identity }
    }
    return identities
  }

  private enum TmuxRuntimeState { case verified, stopped, unknown }

  /// Listing-based equivalent of TmuxController.verify: exact pane identity
  /// verifies, a missing pane on a live server or a dead server PID stops, and
  /// anything else stays unknown rather than guessing.
  private static func tmuxRuntimeState(
    _ saved: TmuxSessionReference, listing: [TmuxPaneSnapshot]?
  ) -> TmuxRuntimeState {
    guard let listing,
          saved.serverPID > 0, saved.serverPID <= Int(Int32.max),
          saved.paneID.range(of: "^%[0-9]+$", options: .regularExpression) != nil,
          (try? TmuxController.validateName(saved.name)) != nil
    else { return .unknown }
    if let match = listing.first(where: { $0.reference.paneID == saved.paneID }) {
      return match.reference == saved ? .verified : .unknown
    }
    if listing.contains(where: { $0.reference.name == saved.name }) { return .stopped }
    if kill(pid_t(saved.serverPID), 0) == -1 && errno == ESRCH { return .stopped }
    return .unknown
  }

  private static func hasRecentHeartbeat(
    _ subtask: TaskSubtask, graceSeconds: TimeInterval, now: Date = Date()
  ) -> Bool {
    guard let heartbeat = subtask.lastHeartbeatAt else { return false }
    return now.timeIntervalSince(heartbeat) <= graceSeconds
  }

  private enum AttentionProbe { case skip, report(AgentAttention?) }

  private func probedAttention(
    subtask: TaskSubtask, configuration: WezTermConfiguration,
    snapshot: RuntimeSnapshot, heartbeatGraceSeconds: TimeInterval
  ) async throws -> AttentionProbe {
    let output: ProcessResult
    if let tmux = subtask.tmux {
      switch Self.tmuxRuntimeState(tmux, listing: snapshot.tmuxPanes[tmux.executable]) {
      case .stopped: return .report(.interrupted)
      case .unknown:
        throw TmuxError.unavailable("Could not verify the agent terminal from the shared pane listing.")
      case .verified: break
      }
      guard !Self.hasRecentHeartbeat(subtask, graceSeconds: heartbeatGraceSeconds) else { return .skip }
      output = try await runner.run(.init(executable: tmux.executable,
        arguments: ["-L", tmuxServerName, "capture-pane", "-p", "-t", tmux.paneID],
        environment: ["TMUX_TMPDIR": "/tmp"]))
    } else if let paneID = subtask.terminalPaneID {
      let key = RuntimeSnapshot.socketKey(subtask.terminalSocketPath ?? configuration.socketPath)
      guard let connection = snapshot.connections[key] else {
        throw WezTermError.actionFailed("Could not inspect the agent terminal.")
      }
      guard subtask.terminalSocketPath == nil || connection.configuration.socketPath == subtask.terminalSocketPath
      else { return .report(nil) }
      guard let pane = connection.panes.first(where: { $0.paneID == paneID }) else { return .report(.interrupted) }
      guard let sessionID = subtask.sessionID, let tty = pane.ttyName else { return .report(nil) }
      let agents = try await processController.agents(onTTY: tty)
      guard agents.contains(where: {
        $0.provider == subtask.provider && $0.sessionID.lowercased() == sessionID.lowercased()
      }) else { return .report(nil) }
      guard !Self.hasRecentHeartbeat(subtask, graceSeconds: heartbeatGraceSeconds) else { return .skip }
      output = try await runner.run(.init(executable: connection.configuration.executable,
        arguments: ["cli", "get-text", "--pane-id", String(paneID)],
        environment: connection.configuration.cliEnvironment))
    } else { return .report(nil) }
    guard output.succeeded else { return .report(nil) }
    return .report(Self.terminalAttention(output.standardOutput))
  }

  private func identifyManaged(subtask: TaskSubtask, snapshot: RuntimeSnapshot) async throws -> String? {
    guard let tmux = subtask.tmux else { return nil }
    guard FileManager.default.isExecutableFile(atPath: tmux.executable) else { return nil }
    guard Self.tmuxRuntimeState(tmux, listing: snapshot.tmuxPanes[tmux.executable]) == .verified else { return nil }
    let matching = try await processController.agents(onTTY: tmux.tty)
      .filter { $0.provider == subtask.provider }
    return matching.count == 1 ? matching.first?.sessionID : nil
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
          .finish(saved, subtaskID: subtask.id, message: message))
      } catch TmuxError.stopped { return .absent }
    }
    guard let paneID = subtask.terminalPaneID else { return .absent }
    var requested = configuration
    requested.socketPath = subtask.terminalSocketPath ?? configuration.socketPath
    let connection = try await processController.resolveConnection(configuration: requested)
    guard connection.result.succeeded,
          subtask.terminalSocketPath == nil || connection.configuration.socketPath == subtask.terminalSocketPath else {
      throw WezTermError.actionFailed("Could not verify the completed agent terminal; it was retained.")
    }
    let panes = try JSONDecoder().decode([WezTermPane].self, from: Data(connection.result.standardOutput.utf8))
    guard let pane = panes.first(where: { $0.paneID == paneID }) else { return .absent }
    guard let tty = pane.ttyName, let session = subtask.sessionID else {
      throw WezTermError.actionFailed("The completed terminal has no verifiable provider identity; it was retained.")
    }
    let agents = try await processController.agents(onTTY: tty)
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
    let connection = try await processController.resolveConnection(configuration: requested)
    guard connection.result.succeeded else { throw WezTermError.actionFailed("Could not inspect the terminal for cleanup.") }
    if let socket = subtask.terminalSocketPath, connection.configuration.socketPath != socket { return }
    let panes = try JSONDecoder().decode([WezTermPane].self, from: Data(connection.result.standardOutput.utf8))
    guard let pane = panes.first(where: { $0.paneID == paneID }) else { return }
    guard let tty = pane.ttyName, let sessionID = subtask.sessionID else {
      throw WezTermError.actionFailed("Agent removed from the list. Its terminal was retained because its provider identity could not be verified.")
    }
    let agents = try await processController.agents(onTTY: tty)
    guard agents.contains(where: { $0.provider == subtask.provider && $0.sessionID.caseInsensitiveCompare(sessionID) == .orderedSame }) else { return }
    let result = try await runner.run(.init(executable: connection.configuration.executable,
      arguments: ["cli", "kill-pane", "--pane-id", String(paneID)], environment: connection.configuration.cliEnvironment))
    guard result.succeeded else { throw WezTermError.actionFailed("Could not close the agent terminal.") }
  }

  /// Starts the provider inside a dedicated tmux session and returns its exact
  /// identity. Callers persist this value before opening any terminal view.
  public func startManagedSession(
    context: TaskContext, subtask: TaskSubtask, supportDirectory: URL,
    includePrompt: Bool = true, tmuxExecutable: String,
    usageBarEnabled: Bool = true
  ) async throws -> TmuxSessionReference {
    if let workspace = subtask.workspace { try await TaskWorktreeManager().validate(workspace) }
    if subtask.tmux != nil, subtask.sessionID == nil {
      throw TaskContextError.commandFailed("This stopped agent has no saved conversation to resume. Start New Agent with a fresh assignment.")
    }
    let command = try Self.command(
      context: context, subtask: subtask, supportDirectory: supportDirectory,
      includePrompt: includePrompt, usageBarEnabled: usageBarEnabled)
    let persistence = FileManager.default.isExecutableFile(atPath: tmuxExecutable)
      ? try TmuxPersistence.prepare(executable: tmuxExecutable, serverName: tmuxServerName,
          supportDirectory: supportDirectory) : nil
    let runtime = TmuxController(runner: runner, serverName: tmuxServerName,
      configurationPath: persistence?.configurationURL.path ?? "/dev/null")
    let reference = try await runtime.startAgent(
      taskID: context.ticketID, subtaskID: subtask.id, taskTitle: context.title,
      agentTitle: "\(subtask.provider.displayName): \(subtask.title)",
      directory: (subtask.workspace?.path ?? context.worktreePath)!, command: command,
      executable: tmuxExecutable)
    // Give process discovery the same prompt source the shell entry points
    // record, so naming works even when provider hooks are not installed.
    let trimmedInitialPrompt = subtask.initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let metadataPrompt: String? = {
      guard subtask.sessionID == nil, includePrompt else { return nil }
      if subtask.includeInitializationPrompt {
        return trimmedInitialPrompt.isEmpty ? subtask.title : trimmedInitialPrompt
      }
      return trimmedInitialPrompt.isEmpty ? nil : trimmedInitialPrompt
    }()
    try? ExternalAgentLaunchMetadata(
      initialPrompt: metadataPrompt, reference: reference,
      provider: subtask.provider, cwd: subtask.workspace?.path ?? context.worktreePath
    ).save(name: "\(reference.name)-\(subtask.id)", supportDirectory: supportDirectory)
    try? await runtime.label(reference, title: "\(subtask.provider.displayName): \(subtask.title)")
    try? await configureManagedPresentation(
      context: context, supportDirectory: supportDirectory,
      usageBarEnabled: usageBarEnabled, tmuxExecutable: tmuxExecutable)
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

  public func configureManagedPresentation(
    context: TaskContext, supportDirectory: URL, usageBarEnabled: Bool,
    tmuxExecutable requestedExecutable: String? = nil
  ) async throws {
    guard let executable = requestedExecutable
      ?? context.subtasks.compactMap(\.tmux).first?.executable else { return }
    let installed = supportDirectory.appendingPathComponent("shell/focus_queue_codex_bar.js")
    let bundled = Bundle.main.bundleURL
      .appendingPathComponent("Contents/Resources/shell/focus_queue_codex_bar.js")
    guard let renderer = [installed, bundled].first(where: {
      (try? FileManager.default.attributesOfItem(atPath: $0.path)[.type] as? FileAttributeType)
        == .typeRegular
    }), let node = SetupEnvironment.executable("node") else { return }
    try await TmuxController(runner: runner, serverName: tmuxServerName)
      .configureTaskPresentation(
        taskID: context.ticketID, taskTitle: context.title,
        contextPath: context.contextDirectory.appendingPathComponent("context.json").path,
        rendererPath: renderer.path, nodePath: node,
        usageBarEnabled: usageBarEnabled, executable: executable)
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
    var connection = try await processController.resolveConnection(
      configuration: configuration)
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
        connection = try await processController.resolveConnection(
          configuration: configuration)
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
