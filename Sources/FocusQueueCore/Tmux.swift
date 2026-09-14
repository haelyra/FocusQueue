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
  case invalidName, unavailable(String), changed
  public var errorDescription: String? {
    switch self {
    case .invalidName: "Session names must contain 1 to 80 letters, numbers, hyphens or underscores, starting with a letter or number."
    case .unavailable(let detail): "tmux session unavailable: \(detail)"
    case .changed: "The saved tmux execution has ended or changed. Its conversation is retained. Reconnect requires the original running session."
    }
  }
}

/// One dedicated server, with no user tmux configuration or existing sessions modified.
public actor TmuxController {
  public static let serverName = "ecc-focus-queue"
  public static let format = "#{session_name}\t#{pid}\t#{session_created}\t#{pane_id}\t#{pane_pid}\t#{pane_tty}\t#{pane_dead}"
  private let runner: any ProcessRunning
  private let serverName: String
  public init(runner: any ProcessRunning = FoundationProcessRunner(), serverName: String = TmuxController.serverName) {
    self.runner = runner
    self.serverName = serverName
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
    try output.split(separator: "\n").map { line in
      let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      guard fields.count == 7, let server = Int(fields[1]), server > 0,
        let created = Int(fields[2]), let panePID = Int(fields[4]), panePID > 0,
        fields[3].range(of: "^%[0-9]+$", options: .regularExpression) != nil,
        fields[5].hasPrefix("/dev/"), fields[6] == "0" else {
        throw TmuxError.unavailable("The execution is stopped or its identity could not be read.")
      }
      try validateName(fields[0])
      return .init(name: fields[0], serverPID: server, createdAt: created, paneID: fields[3],
        panePID: panePID, tty: fields[5], executable: executable)
    }
  }

  public func list(executable: String) async throws -> [TmuxSessionReference] {
    let result = try await run(executable, ["list-panes", "-a", "-F", Self.format])
    if !result.succeeded {
      if !result.timedOut && (result.standardError.contains("no server running") || result.standardError.contains("No such file or directory")) { return [] }
      throw TmuxError.unavailable(String(result.standardError.prefix(800)))
    }
    return try Self.decode(result.standardOutput, executable: executable)
  }

  public func inspect(name: String, executable: String) async throws -> TmuxSessionReference {
    try Self.validateName(name)
    let result = try await run(executable, ["display-message", "-p", "-t", "=\(name):0.0", Self.format])
    guard result.succeeded, let reference = try Self.decode(result.standardOutput, executable: executable).first,
      reference.name == name else { throw TmuxError.unavailable("The named session is not running. No replacement was started.") }
    return reference
  }

  public func verify(_ saved: TmuxSessionReference) async throws -> TmuxSessionReference {
    let current = try await inspect(name: saved.name, executable: saved.executable)
    guard current == saved else { throw TmuxError.changed }
    return current
  }

  public func clientTTYs(for reference: TmuxSessionReference) async throws -> Set<String> {
    try Self.validateName(reference.name)
    let result = try await run(reference.executable, ["list-clients", "-t", "=\(reference.name)", "-F", "#{client_tty}"])
    guard result.succeeded else { throw TmuxError.unavailable("Could not inspect attached clients.") }
    return Set(result.standardOutput.split(separator: "\n").map(String.init).filter { $0.hasPrefix("/dev/") })
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
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
      throw ProcessRunnerError.invalidWorkingDirectory(directory)
    }
    let result = try await run(executable, Self.startArguments(name: name, directory: directory, command: command))
    guard result.succeeded else {
      throw TmuxError.unavailable(result.timedOut
        ? "Launch timed out. Run tmux list before retrying; a process may already exist."
        : String(result.standardError.prefix(800)))
    }
    // tmux can return from new-session before the detached pane's TTY and PID
    // are readable in the -P receipt. Resolve the known unique name after
    // creation instead of treating that short initialization window as death.
    var lastError: (any Error)?
    for attempt in 0..<20 {
      do { return try await inspect(name: name, executable: executable) }
      catch {
        lastError = error
        if attempt < 19 { try await Task.sleep(for: .milliseconds(50)) }
      }
    }
    throw TmuxError.unavailable(
      "The session was created but its stable execution identity was not readable. \(lastError?.localizedDescription ?? "")")
  }

  public static func attachCommand(name: String, executable: String) throws -> [String] {
    try validateName(name)
    return ["/usr/bin/env", "-u", "TMUX", "TMUX_TMPDIR=/tmp", executable, "-L", serverName, "attach-session", "-t", "=\(name)"]
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

  private func run(_ executable: String, _ arguments: [String]) async throws -> ProcessResult {
    // tmux parses a trailing semicolon as a command separator even in an argv
    // array. Escape that parser layer; tmux removes this one backslash before
    // passing the original value to the command or child process.
    let literalArguments = arguments.map { argument in
      argument.hasSuffix(";") ? String(argument.dropLast()) + "\\;" : argument
    }
    return try await runner.run(.init(executable: executable, arguments: ["-f", "/dev/null", "-L", serverName] + literalArguments,
      environment: ["TMUX_TMPDIR": "/tmp"], timeoutSeconds: 10))
  }
}
