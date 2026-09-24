import Foundation
import Testing
@testable import FocusQueueCore

private actor ManagedRecallRunner: ProcessRunning {
  var responses: [ProcessResult]
  private(set) var calls: [ProcessSpecification] = []

  init(_ responses: [ProcessResult]) { self.responses = responses }

  func run(_ specification: ProcessSpecification) throws -> ProcessResult {
    calls.append(specification)
    guard !responses.isEmpty else {
      Issue.record("Unexpected managed-session command: \(specification.arguments)")
      throw WezTermError.actionFailed("Unexpected command")
    }
    return responses.removeFirst()
  }
}

private actor DeterministicRecallRunner: ProcessRunning {
  private(set) var calls: [ProcessSpecification] = []
  let reference: TmuxSessionReference
  let agentID: String
  let hasAttachedClient: Bool
  var spawnedPane = false

  init(reference: TmuxSessionReference, agentID: String, hasAttachedClient: Bool = true) {
    self.reference = reference
    self.agentID = agentID
    self.hasAttachedClient = hasAttachedClient
  }

  func run(_ specification: ProcessSpecification) throws -> ProcessResult {
    calls.append(specification)
    if specification.executable == reference.executable {
      if specification.arguments.contains("show-options") {
        return success("ECC-1\n")
      }
      if specification.arguments.contains("list-panes") {
        return success(
          "\(reference.name)|\(reference.serverPID)|\(reference.createdAt)|\(reference.paneID)|\(reference.panePID)|\(reference.tty)|0|@1|0|160|50|0|0|80|24|\(agentID)|||1|auto\n")
      }
      if specification.arguments.contains("list-clients") {
        if spawnedPane { return success("/dev/ttys501\n") }
        return success(hasAttachedClient ? "/dev/ttys500\n" : "")
      }
      if specification.arguments.contains("display-message") {
        if specification.arguments.last == "#{pane_current_path}" { return success("/tmp\n") }
        return success(
          "\(reference.name)|\(reference.serverPID)|\(reference.createdAt)|\(reference.paneID)|\(reference.panePID)|\(reference.tty)|0\n")
      }
      return success()
    }
    if specification.executable == "/mock/wezterm" {
      if specification.arguments == ["cli", "list", "--format", "json"] {
        let paneID = spawnedPane ? 73 : 41
        let tty = spawnedPane ? "/dev/ttys501" : "/dev/ttys500"
        let listedTTY = hasAttachedClient || spawnedPane ? tty : "/dev/ttys777"
        return success("[{\"window_id\":12,\"tab_id\":21,\"pane_id\":\(paneID),\"cwd\":\"file:///tmp\",\"is_active\":true,\"tty_name\":\"\(listedTTY)\"}]")
      }
      if Array(specification.arguments.prefix(2)) == ["cli", "spawn"] {
        spawnedPane = true
        return success("73\n")
      }
      return success()
    }
    if specification.executable == "/usr/bin/open" {
      return success()
    }
    return .init(
      exitCode: 1, standardOutput: "",
      standardError: "Unexpected GUI-specific command: \(specification.executable) \(specification.arguments)",
      timedOut: false)
  }

  private func success(_ output: String = "") -> ProcessResult {
    .init(exitCode: 0, standardOutput: output, standardError: "", timedOut: false)
  }
}

@Suite("Managed session recall")
struct ManagedSessionRecallTests {
  private let tmuxOutput = "fq-implement\t123\t1000\t%0\t124\t/dev/ttys099\t0\n"

  private func result(_ output: String = "", exit: Int32 = 0, timeout: Bool = false) -> ProcessResult {
    .init(
      exitCode: exit, standardOutput: output,
      standardError: exit == 0 ? "" : "Concrete transport failure", timedOut: timeout)
  }

  private func session() throws -> TaskAgentSession {
    let reference = try #require(
      TmuxController.decode(tmuxOutput, executable: "/mock/tmux").first)
    return .init(
      ticketID: "ECC-1", provider: .codex,
      sessionID: "11111111-2222-4333-8444-555555555555",
      tabTitle: "Implement managed session recall", workingDirectory: "/tmp",
      subtaskID: "implement", tmux: reference)
  }

  private func taskReference() -> TmuxSessionReference {
    .init(name: "fq-task-ecc-1", serverPID: 123, createdAt: 1000,
      paneID: "%7", panePID: 124, tty: "/dev/ttys099", executable: "/mock/tmux")
  }

  @Test("WezTerm recall focuses the existing client attached to the exact tmux session")
  func deterministicWezTermRecipe() async throws {
    let agentID = "agent-one"
    let reference = taskReference()
    let runner = DeterministicRecallRunner(reference: reference, agentID: agentID)
    var subtask = TaskSubtask(id: agentID, title: "Exact agent", provider: .codex,
      tmux: reference, runtimeMode: .tmux)
    subtask.workspace = AgentWorkspace(path: "/tmp", repositoryPath: "/tmp")

    let result = try await WezTermController(
      runner: runner, candidateSockets: []).openAgentRuntime(
        subtask, taskID: "ECC-1",
        configuration: .init(executable: "/mock/wezterm", applicationName: "WezTerm"))

    #expect(result == .focused(paneID: 41))
    let calls = await runner.calls
    #expect(calls.contains { $0.arguments == ["cli", "activate-pane", "--pane-id", "41"] })
    #expect(calls.contains { $0.arguments == ["cli", "set-tab-title", "--pane-id", "41", "ECC-1 · tmux"] })
    #expect(!calls.contains { $0.executable == "/usr/bin/open" && $0.arguments.contains("-na") })
    #expect(!calls.flatMap(\.arguments).contains("spawn"))
  }

  @Test("A detached task gets one exact WezTerm view in its recorded workspace")
  func attachDetachedRuntime() async throws {
    let reference = taskReference()
    let runner = DeterministicRecallRunner(
      reference: reference, agentID: "agent-one", hasAttachedClient: false)
    var subtask = TaskSubtask(id: "agent-one", title: "Exact agent", provider: .codex,
      tmux: reference, runtimeMode: .tmux)
    subtask.workspace = AgentWorkspace(path: "/tmp", repositoryPath: "/tmp")

    let result = try await WezTermController(
      runner: runner, candidateSockets: []).openAgentRuntime(
        subtask, taskID: "ECC-1",
        configuration: .init(executable: "/mock/wezterm", applicationName: "WezTerm"))

    #expect(result == .focused(paneID: 73))
    let calls = await runner.calls
    let spawn = try #require(calls.first { Array($0.arguments.prefix(2)) == ["cli", "spawn"] })
    #expect(spawn.workingDirectory == "/tmp")
    #expect(spawn.arguments.contains("--cwd") && spawn.arguments.contains("/tmp"))
    #expect(spawn.arguments.contains("attach-session"))
    #expect(spawn.arguments.contains("=fq-task-ecc-1"))
    #expect(spawn.arguments.contains("%7"))
    #expect(!calls.contains { $0.executable == "/usr/bin/open" && $0.arguments.contains("-na") })
  }

  @Test("With no WezTerm mux, recall starts only the exact tmux attachment and never a blank shell")
  func startExactAttachmentWithoutMux() async throws {
    let reference = taskReference()
    let pane = "\(reference.name)|\(reference.serverPID)|\(reference.createdAt)|\(reference.paneID)|\(reference.panePID)|\(reference.tty)|0|@1|0|160|50|0|0|80|24|agent-one|||1|auto\n"
    let display = "\(reference.name)|\(reference.serverPID)|\(reference.createdAt)|\(reference.paneID)|\(reference.panePID)|\(reference.tty)|0\n"
    let runner = ManagedRecallRunner([
      result("ECC-1\n"), result(pane), result(display), result(display), result(), result(),
      result(exit: 1), result(), result(), result("/dev/ttys501\n"), result(display),
    ])
    var subtask = TaskSubtask(id: "agent-one", title: "Exact agent", provider: .codex,
      tmux: reference, runtimeMode: .tmux)
    subtask.workspace = AgentWorkspace(path: "/tmp", repositoryPath: "/tmp")

    let action = try await WezTermController(
      runner: runner, candidateSockets: []).openAgentRuntime(
        subtask, taskID: "ECC-1",
        configuration: .init(executable: "/mock/wezterm", applicationName: "WezTerm"))

    #expect(action == .spawned(paneID: nil))
    let calls = await runner.calls
    let started = try #require(calls.first {
      $0.executable == "/mock/wezterm" && $0.arguments.starts(with: ["--skip-config", "start"])
    })
    #expect(started.workingDirectory == "/tmp")
    #expect(started.arguments.starts(with: [
      "--skip-config", "start", "--always-new-process", "--cwd", "/tmp", "--",
    ]))
    #expect(started.arguments.contains("attach-session"))
    #expect(started.arguments.contains("=fq-task-ecc-1"))
    #expect(started.arguments.contains("%7"))
    #expect(!calls.contains { $0.executable == "/usr/bin/open" && $0.arguments.contains("-na") })
  }

  @Test("macOS Terminal recall opens a command file for the exact verified tmux pane")
  func deterministicMacTerminalRecipe() async throws {
    let agentID = "agent-two"
    let reference = taskReference()
    let runner = DeterministicRecallRunner(reference: reference, agentID: agentID)
    let subtask = TaskSubtask(id: agentID, title: "Terminal agent", provider: .codex,
      tmux: reference, runtimeMode: .tmux)

    let result = try await WezTermController(
      runner: runner, candidateSockets: []).openAgentRuntime(
        subtask, taskID: "ECC-1",
        configuration: .init(executable: "/mock/wezterm", applicationName: "Terminal"))

    #expect(result == .spawned(paneID: nil))
    let calls = await runner.calls
    let opened = try #require(calls.first { $0.executable == "/usr/bin/open" })
    #expect(opened.arguments.starts(with: ["-na", "Terminal"]))
    let scriptPath = try #require(opened.arguments.last)
    let script = try String(contentsOfFile: scriptPath, encoding: .utf8)
    #expect(script.hasPrefix("#!/bin/zsh\n"))
    #expect(script.contains("'/mock/tmux'"))
    #expect(script.contains("'attach-session'"))
    #expect(script.contains("'=fq-task-ecc-1'"))
    #expect(script.contains("'%7'"))
    #expect(!calls.contains { $0.executable == "/mock/wezterm" })
    let syntax = try await FoundationProcessRunner().run(.init(
      executable: "/bin/zsh", arguments: ["-n", scriptPath], timeoutSeconds: 10))
    #expect(syntax.succeeded, "\(syntax.standardError)")
    let permissions = try FileManager.default.attributesOfItem(atPath: scriptPath)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o700)
    try? FileManager.default.removeItem(atPath: scriptPath)
  }

  @Test("Legacy entries are rejected without provider reconstruction")
  func legacyEntry() async {
    let runner = ManagedRecallRunner([])
    let legacy = TaskAgentSession(
      ticketID: "ECC-1", provider: .codex,
      sessionID: "11111111-2222-4333-8444-555555555555",
      tabTitle: "Legacy", workingDirectory: "/tmp/worktree")

    await #expect(throws: TmuxError.self) {
      try await WezTermController(runner: runner, candidateSockets: []).focusOrResume(
        session: legacy, taskID: "ECC-1", configuration: .init(executable: "/mock/wezterm"))
    }
    #expect(await runner.calls.isEmpty)
  }

  @Test("A task mismatch cannot open another task's runtime")
  func wrongTask() async throws {
    let runner = ManagedRecallRunner([])
    await #expect(throws: TmuxError.self) {
      try await WezTermController(runner: runner, candidateSockets: []).focusOrResume(
        session: session(), taskID: "ECC-2", configuration: .init(executable: "/mock/wezterm"))
    }
    #expect(await runner.calls.isEmpty)
  }

  @Test("A misbound task runtime is rejected before terminal selection")
  func misboundTaskRuntime() async throws {
    let runner = ManagedRecallRunner([])
    var saved = try #require(session().tmux)
    saved.name = "fq-task-ecc-2"
    await #expect(throws: TmuxError.self) {
      try await WezTermController(runner: runner, candidateSockets: []).openManagedRuntime(
        saved, taskID: "ECC-1", provider: .codex, configuration: .init(executable: "/mock/wezterm"))
    }
    #expect(await runner.calls.isEmpty)
  }

  @Test("A shared task pane must carry the exact agent tag before recall")
  func wrongAgentPane() async throws {
    let pane = "fq-task-ecc-1|123|1000|%0|124|/dev/ttys099|0|@1|0|160|50|0|0|80|24|other-agent|||1|auto\n"
    let runner = ManagedRecallRunner([result("ECC-1\n"), result(pane)])
    let reference = TmuxSessionReference(name: "fq-task-ecc-1", serverPID: 123,
      createdAt: 1000, paneID: "%0", panePID: 124, tty: "/dev/ttys099",
      executable: "/mock/tmux")
    let subtask = TaskSubtask(id: "expected-agent", title: "Expected", provider: .codex,
      tmux: reference, runtimeMode: .tmux)
    await #expect(throws: TmuxError.self) {
      try await WezTermController(runner: runner, candidateSockets: []).openAgentRuntime(
        subtask, taskID: "ECC-1", configuration: .init(executable: "/mock/wezterm"))
    }
    let calls = await runner.calls
    #expect(calls.first?.arguments.contains("show-options") == true)
    #expect(!calls.flatMap(\.arguments).contains("activate-pane"))
    #expect(!calls.flatMap(\.arguments).contains("spawn"))
  }

  @Test("A stopped or replaced runtime never starts a provider fallback")
  func endedRuntime() async throws {
    let runner = ManagedRecallRunner([result(exit: 1)])
    await #expect(throws: TmuxError.self) {
      try await WezTermController(runner: runner, candidateSockets: []).focusOrResume(
        session: session(), taskID: "ECC-1", configuration: .init(executable: "/mock/wezterm"))
    }
    let calls = await runner.calls
    #expect(calls.count == 1)
    #expect(calls[0].arguments.contains("display-message"))
    #expect(!calls.flatMap(\.arguments).contains("resume"))
    #expect(!calls.flatMap(\.arguments).contains("new-session"))
  }

  @Test("Recall focuses the exact attached client for legacy and external tmux sessions",
    arguments: ["fq-implement", "fq-codex-11111111-2222-4333-8444-555555555555"])
  func focusExistingClient(name: String) async throws {
    var saved = try session()
    saved.tmux?.name = name
    let reference = try #require(saved.tmux)
    let runner = DeterministicRecallRunner(reference: reference, agentID: "implement")

    let action = try await WezTermController(runner: runner, candidateSockets: []).focusOrResume(
      session: saved, taskID: "ECC-1", configuration: .init(executable: "/mock/wezterm"))

    #expect(action == .focused(paneID: 41))
    let calls = await runner.calls
    #expect(calls.contains { $0.arguments.suffix(3) == ["select-pane", "-t", "%0"] })
    #expect(calls.contains { $0.arguments.suffix(3) == ["select-window", "-t", "%0"] })
    #expect(calls.contains { $0.arguments == ["cli", "activate-pane", "--pane-id", "41"] })
    #expect(!calls.contains { $0.executable == "/usr/bin/open" && $0.arguments.contains("-na") })
    #expect(!calls.flatMap(\.arguments).contains("resume"))
    #expect(!calls.flatMap(\.arguments).contains("new-session"))
    #expect(!calls.contains { $0.executable == "/usr/sbin/lsof" || $0.executable == "/bin/ps" })
  }

  @Test("Recall transport failure leaves the verified managed runtime untouched")
  func reopenDetachedRuntime() async throws {
    let output = tmuxOutput
    let runner = ManagedRecallRunner([
      result(output), result(output), result(), result(), result(exit: 1), result(), result(exit: 1),
    ])

    await #expect(throws: WezTermError.self) {
      try await WezTermController(runner: runner, candidateSockets: []).focusOrResume(
        session: session(), taskID: "ECC-1", configuration: .init(executable: "/mock/wezterm"))
    }
    let calls = await runner.calls
    #expect(calls.filter { $0.executable == "/usr/bin/open" }.isEmpty)
    #expect(calls.contains {
      $0.executable == "/mock/wezterm" && $0.arguments.starts(with: ["--skip-config", "start"])
    })
    #expect(!calls.flatMap(\.arguments).contains("resume"))
    #expect(!calls.flatMap(\.arguments).contains("new-session"))
    #expect(!calls.contains { $0.executable == "/usr/sbin/lsof" || $0.executable == "/bin/ps" })
  }

  @Test("Direct recall focuses only the exact saved pane")
  func focusDirectRuntime() async throws {
    let panes = #"[{"window_id":12,"tab_id":21,"pane_id":41,"cwd":"file:///tmp/worktree"}]"#
    let runner = ManagedRecallRunner([
      result(panes), result(), result(), result(), result(),
    ])

    let action = try await WezTermController(
      runner: runner, candidateSockets: []).openDirectRuntime(
        paneID: 41, socketPath: nil, taskID: "ECC-1", provider: .codex,
        configuration: .init(executable: "/mock/wezterm"))

    #expect(action == .focused(paneID: 41))
    let calls = await runner.calls
    #expect(calls.contains { $0.arguments == ["cli", "activate-pane", "--pane-id", "41"] })
    #expect(!calls.flatMap(\.arguments).contains("resume"))
    #expect(!calls.flatMap(\.arguments).contains("spawn"))
    #expect(!calls.flatMap(\.arguments).contains("new-session"))
  }

  @Test("A closed direct pane never starts a replacement")
  func closedDirectRuntime() async {
    let runner = ManagedRecallRunner([result("[]")])

    await #expect(throws: WezTermError.self) {
      try await WezTermController(
        runner: runner, candidateSockets: []).openDirectRuntime(
          paneID: 41, socketPath: nil, taskID: "ECC-1", provider: .codex,
          configuration: .init(executable: "/mock/wezterm"))
    }
    let calls = await runner.calls
    #expect(calls.count == 1)
    #expect(!calls.flatMap(\.arguments).contains("resume"))
    #expect(!calls.flatMap(\.arguments).contains("spawn"))
    #expect(!calls.flatMap(\.arguments).contains("new-session"))
  }

  @Test("Agent recall retains the registered provider tab label")
  func registeredDirectLabel() async throws {
    let panes = #"[{"window_id":12,"tab_id":21,"pane_id":41,"cwd":"file:///tmp/worktree"}]"#
    let runner = ManagedRecallRunner([result(panes), result(), result(), result(), result()])
    let identity = "11111111-2222-4333-8444-555555555555"
    let subtask = TaskSubtask(title: "Resume", sessionID: identity, runtimeMode: .terminal, terminalPaneID: 41)
    _ = try await WezTermController(runner: runner, candidateSockets: []).openAgentRuntime(
      subtask, taskID: "ECC-1", configuration: .init(executable: "/mock/wezterm"))
    let calls = await runner.calls
    #expect(calls.contains { $0.arguments == ["cli", "set-tab-title", "--pane-id", "41", "ECC-1 · Codex · 555555"] })
    #expect(calls.contains { $0.arguments == ["cli", "set-window-title", "--pane-id", "41", "ECC-1"] })
  }

  @Test("Direct recall connects a GUI to the saved background mux")
  func revealBackgroundMux() async throws {
    let panes = #"[{"window_id":1,"tab_id":1,"pane_id":41,"cwd":"file:///tmp/worktree"}]"#
    let runner = ManagedRecallRunner([result(panes), result(), result(), result(), result()])
    let configuration = WezTermConfiguration(executable: "/mock/wezterm", socketPath: "/tmp/sock")
    let action = try await WezTermController(runner: runner, candidateSockets: []).openDirectRuntime(
      paneID: 41, socketPath: "/tmp/sock", taskID: "ECC-1", provider: .codex,
      configuration: configuration)
    #expect(action == .focused(paneID: 41))
    let calls = await runner.calls
    #expect(calls.last?.arguments == WezTermConnection.revealArguments(configuration: configuration))
    #expect(calls.last?.arguments.contains("connect") == true)
    #expect(!calls.flatMap(\.arguments).contains("spawn"))
  }

  @Test("Window opening failure is reported without restarting the direct agent")
  func failedReveal() async {
    let panes = #"[{"window_id":1,"tab_id":1,"pane_id":41,"cwd":"file:///tmp/worktree"}]"#
    let runner = ManagedRecallRunner([result(panes), result(), result(), result(), result(exit: 1)])
    await #expect(throws: WezTermError.self) {
      try await WezTermController(runner: runner, candidateSockets: []).openDirectRuntime(
        paneID: 41, socketPath: nil, taskID: "ECC-1", provider: .codex,
        configuration: .init(executable: "/mock/wezterm"))
    }
    #expect(await runner.calls.count == 5)
  }
}
