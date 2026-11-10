import Foundation

/// Where one QChat turn runs. Set at runtime on the chat configuration; never
/// saved to config.json.
public struct QueueChatTurnTarget: Codable, Equatable, Sendable {
  /// Stable conversation key: `tab:<id>` for a QChat tab, `task:<ID>` for task chat.
  public var conversation: String
  /// The conversation's tmux session on the dedicated QChat server.
  public var sessionName: String
  /// `<support>/qchat`: turn manifests, outputs, and session activity logs.
  public var rootDirectory: String
  /// tmux binary; nil or missing runs the turn as a plain child process.
  public var tmuxExecutable: String?
  /// The QChat tmux server (`-L`), scoped to the support directory.
  public var serverName: String

  public init(
    conversation: String, sessionName: String, rootDirectory: String, tmuxExecutable: String?,
    serverName: String = QueueChatSessions.serverName
  ) {
    self.conversation = conversation
    self.sessionName = sessionName
    self.rootDirectory = rootDirectory
    self.tmuxExecutable = tmuxExecutable
    self.serverName = serverName
  }
}

/// A launched QChat turn. Its manifest stays on disk until the app collects the
/// reply, so a turn that outlives an app restart still reaches its conversation.
public struct QueueChatTurn: Codable, Equatable, Sendable, Identifiable {
  public var id: String
  public var conversation: String
  public var sessionName: String
  public var provider: AgentProvider
  public var directory: String
  public var tmuxExecutable: String?
  public var serverName: String?
  public var paneID: String?
  /// The user's request, used for evidence checks and failure wording.
  public var request: String
  public var startedAt: Date
  public var model: String?
  public var usageSource: String
  public var runID: String
  public var supportDirectory: String?

  public var promptURL: URL { URL(fileURLWithPath: directory).appendingPathComponent("prompt.txt") }
  public var usageURL: URL { URL(fileURLWithPath: directory).appendingPathComponent("usage.json") }
  var standardOutputURL: URL { URL(fileURLWithPath: directory).appendingPathComponent("stdout") }
  var standardErrorURL: URL { URL(fileURLWithPath: directory).appendingPathComponent("stderr") }
  var exitCodeURL: URL { URL(fileURLWithPath: directory).appendingPathComponent("exit-code") }
  var scriptURL: URL { URL(fileURLWithPath: directory).appendingPathComponent("run.sh") }
  static func manifestURL(_ directory: URL) -> URL { directory.appendingPathComponent("turn.json") }
}

public enum QueueChatSessionError: Error, LocalizedError, Equatable {
  case interrupted
  case unavailable(String)

  public var errorDescription: String? {
    switch self {
    case .interrupted:
      "The chat session closed before the reply finished. Send the message again to retry."
    case .unavailable(let detail):
      "Could not start the chat session: \(detail)"
    }
  }
}

/// Runs QChat turns inside tmux sessions on a dedicated server, one session per
/// conversation, the way task agents run in task sessions. A turn has no
/// deadline: it runs until the provider finishes, the user stops it, or the
/// conversation is cleared, which closes the session.
public actor QueueChatSessions {
  public static let serverName = "ecc-focus-queue-qchat"
  static let holdingWindowName = "qchat"
  public static let pollInterval: Duration = .milliseconds(400)
  /// Pane liveness is a tmux call; files are checked every poll, panes less often.
  static let paneCheckEvery = 5

  private let runner: any ProcessRunning
  private let serverName: String
  private let pollInterval: Duration

  public init(
    runner: any ProcessRunning = FoundationProcessRunner(),
    serverName: String = QueueChatSessions.serverName,
    pollInterval: Duration = QueueChatSessions.pollInterval
  ) {
    self.runner = runner
    self.serverName = serverName
    self.pollInterval = pollInterval
  }

  /// The live app's support directory uses the shared QChat server. Any other
  /// support directory (tests, isolated QA copies) gets its own server, so it
  /// can never close or reuse the live app's chat sessions.
  public static func serverName(supportDirectory: URL) -> String {
    // The installed app's own folder, ignoring FOCUS_QUEUE_SUPPORT_DIR overrides.
    let live = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/ECC Focus Queue", isDirectory: true)
      .standardizedFileURL.path
    let path = supportDirectory.standardizedFileURL.path
    guard path != live else { return serverName }
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in path.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
    return serverName + "-" + String(String(hash, radix: 16).suffix(8))
  }

  /// `fq-qchat-<tab>` for a QChat tab and `fq-qchat-task-<id>` for task chat.
  public static func sessionName(conversation: String) -> String {
    let parts = conversation.split(separator: ":", maxSplits: 1).map(String.init)
    let kind = parts.first ?? "tab"
    let value = parts.count > 1 ? parts[1] : conversation
    let slug = value.lowercased().replacingOccurrences(
      of: "[^a-z0-9_-]", with: "-", options: .regularExpression)
    let prefix = kind == "task" ? "fq-qchat-task-" : "fq-qchat-"
    return prefix + String(slug.prefix(80 - prefix.count))
  }

  public static func turnsDirectory(root: URL) -> URL { root.appendingPathComponent("turns") }

  /// Writes the turn's manifest and prompt. The caller launches it with `run`.
  public static func prepare(
    target: QueueChatTurnTarget, provider: AgentProvider, prompt: String, request: String,
    model: String?, usageSource: String, runID: String, supportDirectory: String?
  ) throws -> QueueChatTurn {
    let id = UUID().uuidString.lowercased()
    let directory = turnsDirectory(root: URL(fileURLWithPath: target.rootDirectory))
      .appendingPathComponent(id, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let turn = QueueChatTurn(
      id: id, conversation: target.conversation, sessionName: target.sessionName, provider: provider,
      directory: directory.path, tmuxExecutable: target.tmuxExecutable, serverName: target.serverName,
      paneID: nil, request: request,
      startedAt: Date(), model: model, usageSource: usageSource, runID: runID,
      supportDirectory: supportDirectory)
    try writePrivate(Data(prompt.utf8), to: turn.promptURL)
    try saveManifest(turn)
    return turn
  }

  /// Launches the harness command in a new window of the conversation's session
  /// and waits, without a deadline, for its exit code.
  public func run(_ turn: QueueChatTurn, specification: ProcessSpecification) async throws -> ProcessResult {
    guard let tmux = turn.tmuxExecutable, FileManager.default.isExecutableFile(atPath: tmux) else {
      // No tmux: still no run budget, only a plain child process that ends with the app.
      return try await runner.run(ProcessSpecification(
        executable: specification.executable, arguments: specification.arguments,
        workingDirectory: specification.workingDirectory, environment: specification.environment,
        timeoutSeconds: Int(Int32.max), maximumOutputBytes: 4_000_000))
    }
    var launched = turn
    try Self.writePrivate(Data(Self.script(for: turn, specification: specification).utf8), to: turn.scriptURL)
    try await ensureSession(turn.sessionName, log: Self.activityLogURL(for: turn), executable: tmux)
    let window = Self.windowName(turn)
    let result: ProcessResult
    do {
      result = try await tmuxCommand(tmux, [
        "new-window", "-d", "-t", "=\(turn.sessionName):", "-n", window,
        "-P", "-F", "#{pane_id}",
        "-c", turn.directory.replacingOccurrences(of: "#", with: "##"),
        "--", "/bin/sh", turn.scriptURL.path,
      ])
    } catch {
      // A stop during launch may still have opened the window; close it by name.
      await Task {
        _ = try? await self.tmuxCommand(tmux, ["kill-window", "-t", "=\(turn.sessionName):\(window)"])
      }.value
      throw error
    }
    let paneID = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard result.succeeded, paneID.range(of: "^%[0-9]+$", options: .regularExpression) != nil else {
      throw QueueChatSessionError.unavailable(Self.detail(result))
    }
    launched.paneID = paneID
    try Self.saveManifest(launched)
    return try await wait(for: launched)
  }

  /// Waits for a launched turn, including one recovered after an app restart.
  /// Cancelling the waiting task stops the turn by closing its window, even
  /// when the cancellation surfaces from an in-flight tmux check.
  public func wait(for turn: QueueChatTurn) async throws -> ProcessResult {
    do {
      return try await poll(turn)
    } catch {
      guard Task.isCancelled || error is CancellationError else { throw error }
      await stopOutsideCancellation(turn)
      throw CancellationError()
    }
  }

  private func poll(_ turn: QueueChatTurn) async throws -> ProcessResult {
    var polls = 0
    while true {
      if let result = Self.collect(turn) { return result }
      try Task.checkCancellation()
      if polls % Self.paneCheckEvery == 0, let tmux = turn.tmuxExecutable, let paneID = turn.paneID {
        if try await !paneIsAlive(paneID, executable: tmux) {
          // The window may finish writing just before it closes.
          if let result = Self.collect(turn) { return result }
          throw QueueChatSessionError.interrupted
        }
      } else if turn.paneID == nil, polls > 0 {
        throw QueueChatSessionError.interrupted
      }
      polls += 1
      try await Task.sleep(for: pollInterval)
    }
  }

  /// The process runner aborts commands in a cancelled task, which would skip
  /// the kill-pane itself; a fresh task carries no cancellation.
  private func stopOutsideCancellation(_ turn: QueueChatTurn) async {
    await Task { await self.stop(turn) }.value
  }

  /// Closes a running turn's window; its trap stops the provider.
  public func stop(_ turn: QueueChatTurn) async {
    guard let tmux = turn.tmuxExecutable, let paneID = turn.paneID else { return }
    _ = try? await tmuxCommand(tmux, ["kill-pane", "-t", paneID])
  }

  /// Ensures the conversation's session exists and returns the argv that
  /// attaches a terminal to it, so the user can watch its turns.
  public func attachCommand(target: QueueChatTurnTarget) async throws -> [String] {
    guard let tmux = target.tmuxExecutable, FileManager.default.isExecutableFile(atPath: tmux) else {
      throw QueueChatSessionError.unavailable("tmux is not installed.")
    }
    let log = URL(fileURLWithPath: target.rootDirectory).appendingPathComponent("sessions")
      .appendingPathComponent(target.sessionName).appendingPathComponent("activity.log")
    try await ensureSession(target.sessionName, log: log, executable: tmux)
    return ["/usr/bin/env", "-u", "TMUX", "TMUX_TMPDIR=/tmp", tmux, "-L", serverName,
            "attach-session", "-t", "=\(target.sessionName)"]
  }

  /// Closes a conversation's session and every turn running in it.
  public func close(sessionName: String, executable: String?) async {
    guard let executable, FileManager.default.isExecutableFile(atPath: executable) else { return }
    _ = try? await tmuxCommand(executable, ["kill-session", "-t", "=\(sessionName)"])
  }

  /// Saved turns whose replies were never collected, oldest first.
  public static func pendingTurns(root: URL) -> [QueueChatTurn] {
    let directory = turnsDirectory(root: root)
    let entries = (try? FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil)) ?? []
    return entries.compactMap { entry in
      guard let data = try? Data(contentsOf: QueueChatTurn.manifestURL(entry)) else { return nil }
      return try? Self.decoder.decode(QueueChatTurn.self, from: data)
    }.sorted { $0.startedAt < $1.startedAt }
  }

  /// Removes a collected or abandoned turn's files.
  public static func discard(_ turn: QueueChatTurn) {
    let directory = URL(fileURLWithPath: turn.directory).standardizedFileURL
    guard directory.deletingLastPathComponent().lastPathComponent == "turns" else { return }
    try? FileManager.default.removeItem(at: directory)
  }

  // MARK: - Internals

  static func collect(_ turn: QueueChatTurn) -> ProcessResult? {
    guard let code = try? String(contentsOf: turn.exitCodeURL, encoding: .utf8),
          let exitCode = Int32(code.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
    let output = (try? String(contentsOf: turn.standardOutputURL, encoding: .utf8)) ?? ""
    let error = (try? String(contentsOf: turn.standardErrorURL, encoding: .utf8)) ?? ""
    return ProcessResult(exitCode: exitCode, standardOutput: output, standardError: error, timedOut: false)
  }

  static func script(for turn: QueueChatTurn, specification: ProcessSpecification) -> String {
    let directory = shellQuoted(turn.directory)
    let log = shellQuoted(activityLogURL(for: turn).path)
    let exports = (specification.environment ?? [:]).sorted { $0.key < $1.key }
      .filter { $0.key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil }
      .map { "export \($0.key)=\(shellQuoted($0.value))" }.joined(separator: "\n")
    let command = ([specification.executable] + specification.arguments).map(shellQuoted).joined(separator: " ")
    let workspace = specification.workingDirectory.map(shellQuoted) ?? directory
    let label = shellQuoted(String(turn.request.split(whereSeparator: \.isNewline).first ?? "").prefix(120).description)
    return """
      #!/bin/sh
      # Focus Queue QChat turn \(turn.id): no run budget; closing this window stops it.
      unset TMUX TMUX_PANE WEZTERM_PANE WEZTERM_UNIX_SOCKET CODEX_SESSION_ID CODEX_THREAD_ID CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID
      \(exports)
      turn=\(directory)
      log=\(log)
      child=
      finish() { printf '%s' "$1" > "$turn/exit-code.tmp"; mv -f "$turn/exit-code.tmp" "$turn/exit-code"; }
      note() { printf '%s  %s\\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$log"; }
      stop() {
        trap - HUP TERM INT
        if [ -n "$child" ]; then kill -TERM "$child" 2>/dev/null; wait "$child" 2>/dev/null; fi
        note "stopped"
        finish 143
        exit 143
      }
      trap stop HUP TERM INT
      cd \(workspace) || { printf 'Working directory is missing.\\n' > "$turn/stderr"; finish 1; exit 1; }
      note "\(turn.provider.displayName) started: "\(label)
      printf 'QChat turn running with %s. Closing this window stops it.\\n' \(shellQuoted(turn.provider.displayName))
      \(command) > "$turn/stdout" 2> "$turn/stderr" < /dev/null &
      child=$!
      wait "$child"
      status=$?
      finish "$status"
      note "finished (exit $status)"

      """
  }

  /// One window per turn, named so a stop during launch can still find it.
  static func windowName(_ turn: QueueChatTurn) -> String { "turn-" + String(turn.id.prefix(8)) }

  static func activityLogURL(for turn: QueueChatTurn) -> URL {
    URL(fileURLWithPath: turn.directory).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("sessions").appendingPathComponent(turn.sessionName)
      .appendingPathComponent("activity.log")
  }

  private func ensureSession(_ name: String, log: URL, executable: String) async throws {
    try TmuxController.validateName(name)
    try FileManager.default.createDirectory(
      at: log.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    if !FileManager.default.fileExists(atPath: log.path) {
      try Self.writePrivate(Data(), to: log)
    }
    let probe = try await tmuxCommand(executable, ["has-session", "-t", "=\(name)"])
    if probe.succeeded { return }
    // The holding window keeps the session open between turns and shows its activity.
    let result = try await tmuxCommand(executable, [
      "new-session", "-d", "-s", name, "-n", Self.holdingWindowName, "-x", "160", "-y", "40",
      "--", "/usr/bin/tail", "-n", "200", "-F", log.path,
    ])
    guard result.succeeded || result.standardError.contains("duplicate session") else {
      throw QueueChatSessionError.unavailable(Self.detail(result))
    }
  }

  private func paneIsAlive(_ paneID: String, executable: String) async throws -> Bool {
    let result = try await tmuxCommand(executable, ["list-panes", "-a", "-F", "#{pane_id}"])
    if !result.succeeded {
      if ["no server running", "No such file or directory", "no sessions", "no current target"]
        .contains(where: result.standardError.contains) { return false }
      // An unreadable listing is not proof the turn ended; keep waiting.
      return true
    }
    return result.standardOutput.split(separator: "\n").contains { $0 == paneID }
  }

  private func tmuxCommand(_ executable: String, _ arguments: [String]) async throws -> ProcessResult {
    // A trailing semicolon is a tmux command separator even inside argv.
    let literal = arguments.map { $0.hasSuffix(";") ? String($0.dropLast()) + "\\;" : $0 }
    return try await runner.run(ProcessSpecification(
      executable: executable, arguments: ["-f", "/dev/null", "-L", serverName] + literal,
      environment: ["TMUX_TMPDIR": "/tmp"], timeoutSeconds: 10))
  }

  private static func detail(_ result: ProcessResult) -> String {
    let text = (result.standardError.isEmpty ? result.standardOutput : result.standardError)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? "tmux exited with code \(result.exitCode)" : String(text.prefix(400))
  }

  static func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  static func saveManifest(_ turn: QueueChatTurn) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try writePrivate(encoder.encode(turn), to: QueueChatTurn.manifestURL(URL(fileURLWithPath: turn.directory)))
  }

  private static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  static func writePrivate(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}
