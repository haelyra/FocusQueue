import Darwin
import Foundation

public struct TmuxSessionReference: Codable, Equatable, Sendable {
  public var name: String
  public var serverPID: Int
  public var createdAt: Int
  public var paneID: String
  public var panePID: Int
  public var tty: String
  public var executable: String
}

public enum TmuxError: Error, LocalizedError {
  case invalidName
  case stopped
  case unavailable(String)
  case startedButUnconfirmed(name: String, executable: String, attempts: Int, lastDetail: String)
  case changed
  public var mayHaveStarted: Bool {
    if case .startedButUnconfirmed = self { return true }
    return false
  }
  public var errorDescription: String? {
    switch self {
    case .stopped: "The tmux agent has stopped."
    case .invalidName: "Session names must contain 1 to 80 letters, numbers, hyphens or underscores, starting with a letter or number."
    case .unavailable(let detail): "tmux could not open the agent session: \(detail)"
    case .startedButUnconfirmed(let name, _, let attempts, let lastDetail):
      "tmux created session \(name), but Focus Queue could not confirm its final pane process and terminal device after \(attempts) checks. The agent may still be starting, so Focus Queue will not create a duplicate. Last check: \(lastDetail)"
    case .changed:
      "The saved tmux session no longer has the same server, pane process, and terminal device. Focus Queue did not start a replacement."
    }
  }
}

/// One dedicated server, with no user tmux configuration or existing sessions modified.
public actor TmuxController {
  public static let serverName = "ecc-focus-queue"
  public static let managedHistoryLimit = 50_000
  // Non-UTF-8 tmux clients replace control characters (including tabs) with
  // underscores. GUI apps often have no locale, so use a printable delimiter.
  public static let format = "#{session_name}|#{pid}|#{session_created}|#{pane_id}|#{pane_pid}|#{pane_tty}|#{pane_dead}"
  private let runner: any ProcessRunning
  let serverName: String
  private let confirmationAttempts: Int
  private let confirmationDelayMilliseconds: Int
  private let requiredStableObservations: Int
  private let configurationPath: String
  public init(
    runner: any ProcessRunning = FoundationProcessRunner(),
    serverName: String = TmuxController.serverName,
    confirmationAttempts: Int = 120,
    confirmationDelayMilliseconds: Int = 250,
    requiredStableObservations: Int = 3,
    configurationPath: String = "/dev/null"
  ) {
    self.runner = runner
    self.serverName = serverName
    self.confirmationAttempts = max(1, confirmationAttempts)
    self.confirmationDelayMilliseconds = max(0, confirmationDelayMilliseconds)
    self.requiredStableObservations = max(1, requiredStableObservations)
    self.configurationPath = configurationPath
  }

  public static func sessionName(subtaskID: String) throws -> String {
    let normalized = subtaskID.lowercased().replacingOccurrences(
      of: "[^a-z0-9_-]", with: "-", options: .regularExpression)
    let name = "fq-" + String(normalized.prefix(75))
    try validateName(name)
    return name
  }

  public static func validateName(_ name: String) throws {
    guard name.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$", options: .regularExpression) != nil else {
      throw TmuxError.invalidName
    }
  }

  public static func decode(_ output: String, executable: String) throws -> [TmuxSessionReference] {
    let lines = output.split(separator: "\n")
    guard !lines.isEmpty else {
      throw TmuxError.unavailable("tmux returned no pane record.")
    }
    return try lines.map { line in
      // Retain support for older tab-delimited records, with the same identity checks.
      let separator: Character = line.contains("|") ? "|" : "\t"
      let fields = line.split(separator: separator, omittingEmptySubsequences: false).map(String.init)
      guard fields.count == 7 else {
        throw TmuxError.unavailable(
          "tmux returned \(fields.count) pane fields; Focus Queue requires 7 to distinguish the exact running process.")
      }
      var invalid: [String] = []
      let server = Int(fields[1])
      let created = Int(fields[2])
      let panePID = Int(fields[4])
      if server.map({ $0 > 0 && $0 <= Int(Int32.max) }) != true { invalid.append("server PID") }
      if created == nil { invalid.append("session creation time") }
      if fields[3].range(of: "^%[0-9]+$", options: .regularExpression) == nil {
        invalid.append("pane number")
      }
      if panePID.map({ $0 > 0 && $0 <= Int(Int32.max) }) != true { invalid.append("pane process PID") }
      if !fields[5].hasPrefix("/dev/") { invalid.append("terminal device") }
      if fields[6] != "0" { invalid.append("running pane state") }
      guard invalid.isEmpty, let server, let created, let panePID else {
        throw TmuxError.unavailable(
          "tmux has not reported a valid \(invalid.joined(separator: ", ")) for this pane yet.")
      }
      try validateName(fields[0])
      return .init(name: fields[0], serverPID: server, createdAt: created, paneID: fields[3],
        panePID: panePID, tty: fields[5], executable: executable)
    }
  }

  public func list(executable: String) async throws -> [TmuxSessionReference] {
    let result = try await run(executable, ["list-panes", "-a", "-F", Self.format])
    if !result.succeeded {
      if !result.timedOut && ["no server running", "No such file or directory", "no current target"]
        .contains(where: result.standardError.contains) { return [] }
      throw TmuxError.unavailable(String(result.standardError.prefix(800)))
    }
    return try Self.decode(result.standardOutput, executable: executable)
  }

  public func inspect(name: String, executable: String) async throws -> TmuxSessionReference {
    try Self.validateName(name)
    return try await inspectTarget("=\(name):", name: name, executable: executable)
  }

  func inspectTarget(_ target: String, name: String, executable: String, allowDifferentSession: Bool = false) async throws -> TmuxSessionReference {
    let result = try await run(executable, ["display-message", "-p", "-t", target, Self.format])
    if !result.succeeded, !result.timedOut,
       ["no server running", "No such file or directory", "can't find", "no sessions",
        "no current target"].contains(where: result.standardError.contains) {
      throw TmuxError.stopped
    }
    guard result.succeeded else {
      throw TmuxError.unavailable("Could not determine whether the saved agent is running. Retry before starting another process.")
    }
    do {
      guard let reference = try Self.decode(result.standardOutput, executable: executable).first,
        (allowDifferentSession || reference.name == name) else {
        throw TmuxError.unavailable("Could not determine whether the saved agent is running. Retry before starting another process.")
      }
      return reference
    } catch {
      // display-message can succeed with empty context fields for a removed
      // target. Confirm absence with an authoritative enumeration; malformed
      // metadata or failed transport alone never authorizes a replacement.
      let isPane = target.hasPrefix("%")
      let probe = try await run(executable, isPane
        ? ["list-panes", "-a", "-F", "#{pane_id}"]
        : ["list-sessions", "-F", "#{session_name}"])
      let identities = probe.standardOutput.split(separator: "\n").map(String.init)
      let valid = identities.allSatisfy {
        $0.range(of: isPane ? "^%[0-9]+$" : "^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$", options: .regularExpression) != nil
      }
      if probe.succeeded, valid, !identities.contains(isPane ? target : name) { throw TmuxError.stopped }
      throw error
    }
  }

  public func verify(_ saved: TmuxSessionReference) async throws -> TmuxSessionReference {
    try Self.validateName(saved.name)
    guard saved.serverPID > 0, saved.serverPID <= Int(Int32.max) else { throw TmuxError.changed }
    guard saved.paneID.range(of: "^%[0-9]+$", options: .regularExpression) != nil else { throw TmuxError.changed }
    let current = try await inspectTarget(saved.paneID, name: saved.name, executable: saved.executable, allowDifferentSession: true)
    if current.serverPID != saved.serverPID,
       kill(pid_t(saved.serverPID), 0) == -1, errno == ESRCH { throw TmuxError.stopped }
    guard current == saved else { throw TmuxError.changed }
    return current
  }

  /// Replace only the verified provider pane, preserving its window and siblings.
  public func finish(
    _ saved: TmuxSessionReference, subtaskID: String? = nil,
    message: AgentCompletionMessage
  ) async throws -> TmuxSessionReference {
    _ = try await verify(saved)
    let result = try await run(saved.executable,
      ["respawn-pane", "-k", "-t", saved.paneID, "-c",
       message.directory.replacingOccurrences(of: "#", with: "##"), "--"] + message.command())
    guard result.succeeded else { throw TmuxError.unavailable("Could not show the completed agent terminal. Its record was retained.") }
    let completed = try await inspectTarget(
      saved.paneID, name: saved.name, executable: saved.executable,
      allowDifferentSession: true)
    if saved.name.hasPrefix("fq-task-"), let subtaskID {
      try Self.validateName(subtaskID)
      try await checked(saved.executable, [
        "set-option", "-p", "-t", saved.paneID,
        "@focus-queue-completed-agent", subtaskID,
      ])
      try await checked(saved.executable, [
        "set-option", "-p", "-u", "-t", saved.paneID,
        "@focus-queue-agent",
      ])
      try await checked(saved.executable, [
        "set-option", "-p", "-u", "-t", saved.paneID,
        "@focus-queue-restored-agent",
      ])
      // The completion terminal is already durable. A layout warning must not
      // make completion retryable or respawn the provider.
      try? await reflow(name: saved.name, executable: saved.executable, force: true)
    }
    return completed
  }

  public func stop(_ saved: TmuxSessionReference) async throws {
    do { _ = try await verify(saved) } catch TmuxError.stopped { return }
    let result = try await run(saved.executable, ["kill-pane", "-t", saved.paneID])
    guard result.succeeded else { throw TmuxError.unavailable("Could not close the completed agent runtime.") }
    if saved.name.hasPrefix("fq-task-") {
      try? await reflow(name: saved.name, executable: saved.executable)
    }
  }

  public func clientTTYs(for reference: TmuxSessionReference) async throws -> Set<String> {
    try Self.validateName(reference.name)
    let result = try await run(reference.executable, ["list-clients", "-t", "=\(reference.name)", "-F", "#{client_tty}"])
    guard result.succeeded else { throw TmuxError.unavailable("Could not inspect attached clients.") }
    return Set(result.standardOutput.split(separator: "\n").map(String.init).filter { $0.hasPrefix("/dev/") })
  }

  public func workingDirectory(for reference: TmuxSessionReference) async throws -> String {
    _ = try await verify(reference)
    let result = try await run(reference.executable, [
      "display-message", "-p", "-t", reference.paneID, "#{pane_current_path}",
    ])
    let path = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    var isDirectory: ObjCBool = false
    guard result.succeeded, path.hasPrefix("/"), !path.contains("\0"),
      FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue
    else {
      throw TmuxError.unavailable("The managed pane did not report a usable workspace path.")
    }
    return URL(fileURLWithPath: path).standardizedFileURL.path
  }

  public static func startArguments(name: String, directory: String, command: [String]) throws -> [String] {
    try validateName(name)
    guard directory.hasPrefix("/"), !command.isEmpty else { throw TmuxError.unavailable("An absolute directory and a command are required.") }
    // Use multiple arguments so tmux executes argv directly rather than interpreting shell code.
    // -c accepts tmux formats, so a literal # in a filesystem path needs escaping.
    return ["new-session", "-d", "-P", "-F", format, "-s", name, "-c", directory.replacingOccurrences(of: "#", with: "##"),
      "--", "/usr/bin/env", "-u", "WEZTERM_PANE", "-u", "WEZTERM_UNIX_SOCKET",
      "-u", "CODEX_SESSION_ID", "-u", "CODEX_THREAD_ID", "-u", "CLAUDE_SESSION_ID",
      "FOCUS_QUEUE_TMUX_NAME=\(name)"] + command
  }

  public func start(name: String, directory: String, command: [String], executable: String) async throws -> TmuxSessionReference {
    try Self.validateName(name)
    guard !name.lowercased().hasPrefix("fq-task-") else {
      throw TmuxError.unavailable("Task session names are reserved for tracked agent launches.")
    }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
      throw ProcessRunnerError.invalidWorkingDirectory(directory)
    }
    try await configureManagedScrollback(executable: executable)
    let result = try await run(executable, Self.startArguments(name: name, directory: directory, command: command))
    guard result.succeeded else {
      throw TmuxError.unavailable(result.timedOut
        ? "Launch timed out. Run tmux list before retrying; a process may already exist."
        : String(result.standardError.prefix(800)))
    }
    // User shell aliases can replace the initial pane process while the provider
    // wrapper starts. Require three identical observations so we persist the
    // final process rather than an intermediate shell PID.
    var lastError: (any Error)?
    var previous: TmuxSessionReference?
    var stableObservations = 0
    let attempts = confirmationAttempts
    for attempt in 0..<attempts {
      do {
        let current = try await inspect(name: name, executable: executable)
        if current == previous { stableObservations += 1 }
        else { previous = current; stableObservations = 1 }
        if stableObservations >= requiredStableObservations { return current }
      }
      catch {
        lastError = error
        previous = nil
        stableObservations = 0
      }
      if attempt < attempts - 1, confirmationDelayMilliseconds > 0 {
        try await Task.sleep(for: .milliseconds(confirmationDelayMilliseconds))
      }
    }
    throw TmuxError.startedButUnconfirmed(
      name: name, executable: executable, attempts: attempts,
      lastDetail: lastError?.localizedDescription ?? "the pane details continued changing")
  }

  public static func attachCommand(name: String, executable: String) throws -> [String] {
    try validateName(name)
    return ["/usr/bin/env", "-u", "TMUX", "TMUX_TMPDIR=/tmp", executable, "-L", serverName, "attach-session", "-t", "=\(name)"]
  }

  /// Selects and attaches the exact verified pane in one tmux command queue.
  /// This keeps a sibling pane from silently replacing the requested agent
  /// between verification and client attachment.
  public static func attachCommand(reference: TmuxSessionReference) throws -> [String] {
    try validateName(reference.name)
    guard reference.paneID.range(of: "^%[0-9]+$", options: .regularExpression) != nil else {
      throw TmuxError.changed
    }
    return ["/usr/bin/env", "-u", "TMUX", "TMUX_TMPDIR=/tmp", reference.executable,
      "-L", serverName,
      "select-window", "-t", reference.paneID, ";",
      "select-pane", "-t", reference.paneID, ";",
      "attach-session", "-t", "=\(reference.name)"]
  }

  /// The complete remote command is quoted as one SSH argument. Unknown/changed host keys fail closed.
  public static func sshCommand(host: String, name: String) throws -> String {
    try validateName(name)
    guard host.range(of: "^(?:[A-Za-z0-9_][A-Za-z0-9_-]*@)?[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil,
      host.count <= 255 else { throw TmuxError.unavailable("Use an SSH host alias or user@hostname without shell syntax.") }
    let remote = "exec \"$HOME/.local/bin/focus-queue-session\" tmux attach \(name)"
    let arguments = ["ssh", "-t", "-o", "StrictHostKeyChecking=yes", "-o", "ForwardAgent=no",
      "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3", host, remote]
    return arguments.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
  }

  func run(_ executable: String, _ arguments: [String]) async throws -> ProcessResult {
    // tmux parses a trailing semicolon as a command separator even in an argv
    // array. Escape that parser layer; tmux removes this one backslash before
    // passing the original value to the command or child process.
    let literalArguments = arguments.map { argument in
      argument.hasSuffix(";") ? String(argument.dropLast()) + "\\;" : argument
    }
    return try await runner.run(.init(executable: executable, arguments: ["-f", configurationPath, "-L", serverName] + literalArguments,
      environment: ["TMUX_TMPDIR": "/tmp"], timeoutSeconds: 10))
  }

  /// Starts the dedicated server without a user configuration and establishes
  /// scrolling defaults before any managed pane is created. Keeping the empty
  /// server alive preserves those defaults between agent sessions.
  func configureManagedScrollback(executable: String) async throws {
    let arguments = [
      "-f", configurationPath, "-L", serverName,
      "start-server", ";",
      "set-option", "-g", "exit-empty", "off", ";",
      "set-option", "-g", "mouse", "on", ";",
      "set-option", "-g", "history-limit", String(Self.managedHistoryLimit),
    ]
    let result = try await runner.run(.init(
      executable: executable, arguments: arguments,
      environment: ["TMUX_TMPDIR": "/tmp"], timeoutSeconds: 10))
    guard result.succeeded else {
      throw TmuxError.unavailable(
        result.timedOut
          ? "Timed out while enabling managed terminal scrolling."
          : String(result.standardError.prefix(800)))
    }
  }
}
