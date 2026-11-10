import Foundation
import Testing

@testable import FocusQueueCore

private actor ChatTurnRecordingRunner: ProcessRunning {
  private(set) var specifications: [ProcessSpecification] = []
  func run(_ specification: ProcessSpecification) throws -> ProcessResult {
    specifications.append(specification)
    return ProcessResult(exitCode: 0, standardOutput: "done", standardError: "", timedOut: false)
  }
}

private func temporaryRoot() throws -> URL {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("qchat-tests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root
}

private func tmuxPath() -> String? {
  ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
    .first { FileManager.default.isExecutableFile(atPath: $0) }
}

private func killServer(_ tmux: String, _ server: String) async {
  _ = try? await FoundationProcessRunner().run(ProcessSpecification(
    executable: tmux, arguments: ["-L", server, "kill-server"], environment: ["TMUX_TMPDIR": "/tmp"],
    timeoutSeconds: 10))
  try? FileManager.default.removeItem(atPath: "/tmp/tmux-\(getuid())/\(server)")
}

/// Runs a test body against a private tmux server and always removes the
/// server and its socket, even when the body fails.
private func withPrivateServer(
  _ body: (_ tmux: String, _ server: String, _ root: URL) async throws -> Void
) async throws {
  guard let tmux = tmuxPath() else { return }
  let root = try temporaryRoot()
  let server = "fq-qchat-test-\(UUID().uuidString.prefix(8))"
  do {
    try await body(tmux, server, root)
  } catch {
    await killServer(tmux, server)
    try? FileManager.default.removeItem(at: root)
    throw error
  }
  await killServer(tmux, server)
  try? FileManager.default.removeItem(at: root)
}

/// Polls until `condition` holds, so tmux startup under load cannot flake a test.
private func waitUntil(
  line: Int = #line, seconds: Double = 15,
  _ condition: () async throws -> Bool
) async throws {
  let deadline = Date().addingTimeInterval(seconds)
  while try await !condition() {
    guard Date() < deadline else { Issue.record("condition at line \(line) timed out"); return }
    try await Task.sleep(for: .milliseconds(50))
  }
}

private func sessionExists(_ tmux: String, _ server: String, _ name: String) async throws -> Bool {
  try await FoundationProcessRunner().run(ProcessSpecification(
    executable: tmux, arguments: ["-L", server, "has-session", "-t", "=\(name)"],
    environment: ["TMUX_TMPDIR": "/tmp"], timeoutSeconds: 10)).succeeded
}

@Test("A QChat turn passes no run budget to the harness, even without tmux")
func chatTurnHasNoRunBudget() async throws {
  let root = try temporaryRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let runner = ChatTurnRecordingRunner()
  var configuration = VerifierConfiguration(enabled: true, executable: "/mock/claude", sessionName: "s")
  configuration.chatTurn = QueueChatTurnTarget(
    conversation: "tab:main", sessionName: "fq-qchat-main", rootDirectory: root.path, tmuxExecutable: nil,
    serverName: "unused")
  let reply = try await HarnessQueueAgent(provider: .claude, runner: runner).send(
    message: "User request:\nReorganize every project", dashboardPath: "/d", workspace: root.path,
    visibleOrder: [], deferredTicketIDs: [], configuration: configuration, model: nil, effort: nil)

  #expect(reply.message == "done")
  let invocation = try #require(await runner.specifications.first)
  let timeout = try #require(invocation.arguments.firstIndex(of: "--timeout"))
  #expect(invocation.arguments[timeout + 1] == "0")
  #expect(invocation.timeoutSeconds >= Int(Int32.max))
  // The collected turn leaves no files behind.
  #expect(QueueChatSessions.pendingTurns(root: root).isEmpty)
}

@Test("Session names separate QChat tabs from task chats and fit tmux limits")
func chatSessionNames() throws {
  #expect(QueueChatSessions.sessionName(conversation: "tab:main") == "fq-qchat-main")
  #expect(QueueChatSessions.sessionName(conversation: "task:FOC-120") == "fq-qchat-task-foc-120")
  let long = QueueChatSessions.sessionName(conversation: "tab:" + String(repeating: "a", count: 200))
  try TmuxController.validateName(long)
  let other = QueueChatSessions.serverName(supportDirectory: URL(fileURLWithPath: "/tmp/elsewhere"))
  #expect(other.hasPrefix(QueueChatSessions.serverName + "-"))
  #expect(other != QueueChatSessions.serverName(supportDirectory: URL(fileURLWithPath: "/tmp/elsewhere-2")))
}

@Test("A QChat turn runs in its conversation's tmux session and returns its output")
func chatTurnRunsInTmux() async throws {
  try await withPrivateServer { tmux, server, root in
    let target = QueueChatTurnTarget(
      conversation: "tab:main", sessionName: "fq-qchat-main", rootDirectory: root.path,
      tmuxExecutable: tmux, serverName: server)
    let turn = try QueueChatSessions.prepare(
      target: target, provider: .claude, prompt: "prompt", request: "it's a 'quoted' request",
      model: nil, usageSource: "queue_chat", runID: "run", supportDirectory: nil)
    let sessions = QueueChatSessions(serverName: server, pollInterval: .milliseconds(50))
    let result = try await sessions.run(turn, specification: ProcessSpecification(
      executable: "/bin/sh", arguments: ["-c", "sleep 1; printf \"reply from $GREETING\"; printf warn >&2"],
      workingDirectory: root.path, environment: ["GREETING": "the session's shell"]))

    #expect(result.exitCode == 0)
    #expect(result.standardOutput == "reply from the session's shell")
    #expect(result.standardError == "warn")
    #expect(try await sessionExists(tmux, server, "fq-qchat-main"))
    let log = try String(contentsOf: root.appendingPathComponent("sessions/fq-qchat-main/activity.log"), encoding: .utf8)
    #expect(log.contains("started") && log.contains("finished (exit 0)"))

    await sessions.close(sessionName: "fq-qchat-main", executable: tmux)
    #expect(try await !sessionExists(tmux, server, "fq-qchat-main"))
  }
}

@Test("Stopping a QChat turn closes its window and stops the command")
func chatTurnCancellationStopsCommand() async throws {
  try await withPrivateServer { tmux, server, root in
    let marker = root.appendingPathComponent("stopped")
    let target = QueueChatTurnTarget(
      conversation: "tab:abc", sessionName: "fq-qchat-abc", rootDirectory: root.path,
      tmuxExecutable: tmux, serverName: server)
    let turn = try QueueChatSessions.prepare(
      target: target, provider: .codex, prompt: "p", request: "r", model: nil,
      usageSource: "queue_chat", runID: "run", supportDirectory: nil)
    let sessions = QueueChatSessions(serverName: server, pollInterval: .milliseconds(50))
    let running = Task {
      try await sessions.run(turn, specification: ProcessSpecification(
        executable: "/bin/sh",
        arguments: ["-c", "trap 'touch \(marker.path); exit 3' HUP TERM; sleep 60 & wait"],
        workingDirectory: root.path))
    }
    // Cancel only once the command is running in its window.
    try await waitUntil { QueueChatSessions.pendingTurns(root: root).first?.paneID != nil }
    try await waitUntil {
      (try? String(contentsOf: root.appendingPathComponent("sessions/fq-qchat-abc/activity.log"),
        encoding: .utf8))?.contains("started") == true
    }
    try await Task.sleep(for: .milliseconds(300))
    running.cancel()
    await #expect(throws: CancellationError.self) { try await running.value }
    try await waitUntil { FileManager.default.fileExists(atPath: marker.path) }
    // The session itself stays open for the next turn.
    #expect(try await sessionExists(tmux, server, "fq-qchat-abc"))
  }
}

@Test("A turn whose session closed reports an interruption; a finished one is recovered")
func chatTurnRecovery() async throws {
  try await withPrivateServer { tmux, server, root in
    let target = QueueChatTurnTarget(
      conversation: "task:FOC-1", sessionName: "fq-qchat-task-foc-1", rootDirectory: root.path,
      tmuxExecutable: tmux, serverName: server)
    let sessions = QueueChatSessions(serverName: server, pollInterval: .milliseconds(50))

    // Simulate an app quit mid-turn: launch, then stop waiting without cancelling the turn.
    let turn = try QueueChatSessions.prepare(
      target: target, provider: .claude, prompt: "p", request: "r", model: nil,
      usageSource: "queue_chat", runID: "run", supportDirectory: nil)
    let waiting = Task {
      try await sessions.run(turn, specification: ProcessSpecification(
        executable: "/bin/sh", arguments: ["-c", "sleep 3; printf recovered"], workingDirectory: root.path))
    }
    try await waitUntil { QueueChatSessions.pendingTurns(root: root).first?.paneID != nil }
    let saved = try #require(QueueChatSessions.pendingTurns(root: root).first)
    #expect(saved.paneID != nil)
    // A fresh waiter, like the app after a restart, collects the reply.
    let recovered = try await QueueChatSessions(serverName: server, pollInterval: .milliseconds(50)).wait(for: saved)
    #expect(recovered.standardOutput == "recovered")
    _ = try? await waiting.value
    QueueChatSessions.discard(saved)
    #expect(QueueChatSessions.pendingTurns(root: root).isEmpty)

    // Clearing the conversation closes the session; a waiter reports the interruption.
    let second = try QueueChatSessions.prepare(
      target: target, provider: .claude, prompt: "p", request: "r", model: nil,
      usageSource: "queue_chat", runID: "run", supportDirectory: nil)
    let blocked = Task {
      try await sessions.run(second, specification: ProcessSpecification(
        executable: "/bin/sh", arguments: ["-c", "sleep 60"], workingDirectory: root.path))
    }
    try await waitUntil {
      QueueChatSessions.pendingTurns(root: root).first { $0.id == second.id }?.paneID != nil
    }
    await QueueChatSessions(serverName: server).close(sessionName: "fq-qchat-task-foc-1", executable: tmux)
    do {
      let result = try await blocked.value
      // The trap may record its stop before the window closes.
      #expect(result.exitCode == 143)
    } catch {
      #expect(error as? QueueChatSessionError == .interrupted)
    }
  }
}

/// Opt-in live check (FOCUS_QUEUE_LIVE_QCHAT=1): a real Claude QChat turn runs
/// in tmux past the old 120-second budget. Uses a scratch support folder and a
/// private tmux server, so the installed app's sessions are never touched.
@Test("Live: a real Claude QChat turn outlasts the old 120-second budget")
func liveClaudeTurnOutlastsOldBudget() async throws {
  guard ProcessInfo.processInfo.environment["FOCUS_QUEUE_LIVE_QCHAT"] == "1", let tmux = tmuxPath() else { return }
  let root = try temporaryRoot()
  let support = root.appendingPathComponent("support", isDirectory: true)
  let workspace = root.appendingPathComponent("workspace", isDirectory: true)
  try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
  // A real job, not a bare sleep, which Claude Code's shell tool refuses.
  let check = workspace.appendingPathComponent("slow-check.sh")
  try Data("""
    #!/bin/sh
    # Checksums a generated file once per second for about 70 seconds.
    end=$(( $(date +%s) + 70 ))
    n=0
    while [ "$(date +%s)" -lt "$end" ]; do head -c 200000 /dev/urandom | shasum >/dev/null; n=$((n+1)); /bin/sleep 1; done
    echo "slow-check passed $n rounds"

    """.utf8).write(to: check)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: check.path)
  let server = QueueChatSessions.serverName(supportDirectory: support)
  let harness = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Scripts/focus-queue-claude").path
  var configuration = VerifierConfiguration(enabled: true, executable: harness, sessionName: "live")
  configuration.supportDirectory = support.path
  configuration.runtimeDirectory = support.appendingPathComponent("agent-claude").path
  configuration.chatTurn = QueueChatTurnTarget(
    conversation: "tab:live", sessionName: "fq-qchat-live", rootDirectory: support.appendingPathComponent("qchat").path,
    tmuxExecutable: tmux, serverName: server)
  let token = String(UUID().uuidString.prefix(6))
  let started = Date()
  let reply = try await HarnessQueueAgent(provider: .claude).send(
    message: "User request:\nRun the workspace check `./slow-check.sh` in \(workspace.path) two times, one after the other, in the foreground (each run takes about 70 seconds; use a 200000 ms tool timeout). Do nothing else. After both runs pass, reply with exactly LIVE-\(token)",
    dashboardPath: support.appendingPathComponent("dashboard.json").path, workspace: workspace.path,
    visibleOrder: [], deferredTicketIDs: [], configuration: configuration,
    model: ProcessInfo.processInfo.environment["FOCUS_QUEUE_LIVE_QCHAT_MODEL"] ?? "claude-sonnet-5", effort: "low")
  let elapsed = Date().timeIntervalSince(started)
  print("LIVE QCHAT elapsed=\(Int(elapsed))s server=\(server) reply=\(reply.message)")
  #expect(elapsed > 130)
  #expect(reply.message.contains("LIVE-\(token)"))
  #expect(QueueChatSessions.pendingTurns(root: support.appendingPathComponent("qchat")).isEmpty)
  await killServer(tmux, server)
  try? FileManager.default.removeItem(at: root)
}
