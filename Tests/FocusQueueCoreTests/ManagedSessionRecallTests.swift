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
      tabTitle: "Implement managed session recall", workingDirectory: "/tmp/worktree",
      subtaskID: "implement", tmux: reference)
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

  @Test("Recall focuses the terminal attached to the exact tmux client")
  func focusExistingClient() async throws {
    let panes = #"[{"window_id":12,"tab_id":21,"pane_id":41,"cwd":"file:///tmp/worktree","tty_name":"/dev/ttys028"}]"#
    let runner = ManagedRecallRunner([
      result(tmuxOutput), result(panes), result("/dev/ttys028\n"),
      result(), result(), result(), result(),
    ])

    let action = try await WezTermController(runner: runner, candidateSockets: []).focusOrResume(
      session: session(), taskID: "ECC-1", configuration: .init(executable: "/mock/wezterm"))

    #expect(action == .focused(paneID: 41))
    let calls = await runner.calls
    #expect(calls.contains { $0.arguments == ["cli", "activate-pane", "--pane-id", "41"] })
    #expect(!calls.flatMap(\.arguments).contains("resume"))
    #expect(!calls.flatMap(\.arguments).contains("new-session"))
    #expect(!calls.contains { $0.executable == "/usr/sbin/lsof" || $0.executable == "/bin/ps" })
  }

  @Test("Recall opens a new view by attaching only to the saved runtime")
  func reopenDetachedRuntime() async throws {
    let detachedPanes = "[]"
    let reopenedPanes = #"[{"window_id":12,"tab_id":21,"pane_id":41,"cwd":"file:///tmp/worktree","tty_name":"/dev/ttys028"}]"#
    let runner = ManagedRecallRunner([
      result(tmuxOutput), result(detachedPanes), result(), result("41\n"),
      result(tmuxOutput), result(reopenedPanes), result(), result(), result(), result(),
    ])

    let action = try await WezTermController(runner: runner, candidateSockets: []).focusOrResume(
      session: session(), taskID: "ECC-1", configuration: .init(executable: "/mock/wezterm"))

    #expect(action == .focused(paneID: 41))
    let calls = await runner.calls
    let spawn = try #require(calls.first { $0.arguments.starts(with: ["cli", "spawn"]) })
    #expect(spawn.arguments.contains("attach-session"))
    #expect(spawn.arguments.contains("=fq-implement"))
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
