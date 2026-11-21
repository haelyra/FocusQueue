import CoreGraphics
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
  /// What `ps` reports for the WezTerm GUI process, or nil when it is gone.
  let guiCommand: String?
  var spawnedPane = false
  var detached = false

  init(reference: TmuxSessionReference, agentID: String, hasAttachedClient: Bool = true,
       guiCommand: String? = nil) {
    self.reference = reference
    self.agentID = agentID
    self.hasAttachedClient = hasAttachedClient
    self.guiCommand = guiCommand
  }

  func run(_ specification: ProcessSpecification) throws -> ProcessResult {
    calls.append(specification)
    if specification.executable == reference.executable {
      if specification.arguments.contains("show-options") {
        return success("ECC-1\n")
      }
      if specification.arguments.contains("list-panes") {
        return success(
          "\(reference.name)|\(reference.serverPID)|\(reference.createdAt)|\(reference.paneID)|\(reference.panePID)|\(reference.tty)|0|@1|0|160|50|0|0|80|24|\(agentID)|||1|auto||\n")
      }
      if specification.arguments.contains("list-clients") {
        if spawnedPane { return success("/dev/ttys501\n") }
        return success(hasAttachedClient && !detached ? "/dev/ttys500\n" : "")
      }
      if specification.arguments.contains("detach-client") {
        detached = true
        return success()
      }
      if specification.arguments.contains("display-message") {
        if specification.arguments.last == "#{pane_current_path}" { return success("/tmp\n") }
        return success(
          "\(reference.name)|\(reference.serverPID)|\(reference.createdAt)|\(reference.paneID)|\(reference.panePID)|\(reference.tty)|0\n")
      }
      return success()
    }
    if specification.executable == "/mock/wezterm" {
      if specification.arguments.suffix(3) == ["list", "--format", "json"] {
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
    if specification.executable == "/usr/bin/open" || specification.executable == "/bin/sh" {
      return success()
    }
    if specification.executable == "/bin/ps", let guiCommand {
      return success(guiCommand + "\n")
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

private actor RestartingWezTermRunner: ProcessRunning {
  private let inner: DeterministicRecallRunner
  private let startSucceeds: Bool
  private let timesOutAfterStart: Bool
  private(set) var calls: [ProcessSpecification] = []
  private var started = false

  init(reference: TmuxSessionReference, agentID: String, startSucceeds: Bool = true,
       timesOutAfterStart: Bool = false) {
    inner = DeterministicRecallRunner(reference: reference, agentID: agentID)
    self.startSucceeds = startSucceeds
    self.timesOutAfterStart = timesOutAfterStart
  }

  func run(_ specification: ProcessSpecification) async throws -> ProcessResult {
    calls.append(specification)
    if specification.executable == "/usr/bin/open", specification.arguments == ["-a", "WezTerm"] {
      guard startSucceeds else {
        return .init(exitCode: 1, standardOutput: "", standardError: "Unable to find application", timedOut: false)
      }
      started = true
      return .init(exitCode: 0, standardOutput: "", standardError: "", timedOut: false)
    }
    if specification.executable == "/mock/wezterm", specification.arguments.contains("list"),
       !started || timesOutAfterStart {
      return .init(exitCode: 1, standardOutput: "", standardError: "", timedOut: true)
    }
    return try await inner.run(specification)
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

  /// FOC-142: `activate-pane` left the last front WezTerm window in front, so
  /// clicking one task showed another task's window.
  @Test("Recall in a Focus Queue WezTerm raises the exact window it focuses")
  func managedGUIRaisesFocusedWindow() async throws {
    let support = FileManager.default.temporaryDirectory
      .appendingPathComponent("fq-raise-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: support) }
    let config = WezTermManagedConfig.fileURL(supportDirectory: support).path
    let reference = taskReference()
    let runner = DeterministicRecallRunner(reference: reference, agentID: "agent-one",
      guiCommand: "/Applications/WezTerm.app/Contents/MacOS/wezterm-gui --config-file \(config) start --always-new-process")
    var subtask = TaskSubtask(id: "agent-one", title: "Exact agent", provider: .codex,
      tmux: reference, runtimeMode: .tmux)
    subtask.workspace = AgentWorkspace(path: "/tmp", repositoryPath: "/tmp")

    let result = try await WezTermController(
      runner: runner, candidateSockets: [], supportDirectory: support).openAgentRuntime(
        subtask, taskID: "ECC-1",
        configuration: .init(executable: "/mock/wezterm", applicationName: "WezTerm",
          socketPath: "/tmp/gui-sock-4242"))

    #expect(result == .focused(paneID: 41))
    let calls = await runner.calls
    let raise = try #require(calls.first { $0.executable == "/bin/sh" })
    #expect(raise.arguments.last == "/dev/ttys500")
    #expect(raise.arguments.contains { $0.contains("SetUserVar=focus_queue_raise=") })
    let raiseIndex = try #require(calls.firstIndex { $0.executable == "/bin/sh" })
    let activateIndex = try #require(calls.firstIndex { $0.arguments.contains("activate-pane") })
    let revealIndex = try #require(calls.lastIndex { $0.executable == "/usr/bin/open" })
    #expect(activateIndex < raiseIndex && raiseIndex < revealIndex)
    #expect(!calls.contains { $0.arguments.contains("detach-client") })
    #expect(!calls.flatMap(\.arguments).contains("spawn"))
    // The running GUI reloads the refreshed config that holds the raise handler.
    #expect(FileManager.default.fileExists(atPath: config))
  }

  @Test("Recall in a WezTerm Focus Queue did not start replaces the hidden view with a front window")
  func unmanagedGUIReplacesHiddenView() async throws {
    let reference = taskReference()
    let runner = DeterministicRecallRunner(reference: reference, agentID: "agent-one",
      guiCommand: "/Applications/WezTerm.app/Contents/MacOS/wezterm-gui start")
    var subtask = TaskSubtask(id: "agent-one", title: "Exact agent", provider: .codex,
      tmux: reference, runtimeMode: .tmux)
    subtask.workspace = AgentWorkspace(path: "/tmp", repositoryPath: "/tmp")

    let result = try await WezTermController(
      runner: runner, candidateSockets: []).openAgentRuntime(
        subtask, taskID: "ECC-1",
        configuration: .init(executable: "/mock/wezterm", applicationName: "WezTerm",
          socketPath: "/tmp/gui-sock-4242"))

    #expect(result == .focused(paneID: 73))
    let calls = await runner.calls
    let detach = try #require(calls.firstIndex { $0.arguments.contains("detach-client") })
    #expect(calls[detach].arguments.suffix(2) == ["-t", "/dev/ttys500"])
    let spawn = try #require(calls.firstIndex { Array($0.arguments.prefix(2)) == ["cli", "spawn"] })
    #expect(detach < spawn)
    #expect(!calls.contains { $0.arguments == ["cli", "activate-pane", "--pane-id", "41"] })
  }

  @Test("The managed WezTerm config raises a window when its pane sets the raise variable")
  func managedConfigHasRaiseHandler() {
    #expect(WezTermManagedConfig.script.contains("wezterm.on(\"user-var-changed\""))
    #expect(WezTermManagedConfig.script.contains("name == \"focus_queue_raise\""))
    #expect(WezTermManagedConfig.script.contains("window:focus()"))
    let sequence = WezTermManagedConfig.raiseSequence(token: "abc")
    #expect(sequence == "\u{1B}]1337;SetUserVar=focus_queue_raise=YWJj\u{07}")
    #expect(WezTermManagedConfig.isManaged(
      guiCommand: "wezterm-gui --config-file /s/terminal/wezterm-managed.lua start",
      supportDirectory: URL(fileURLWithPath: "/s")))
    #expect(!WezTermManagedConfig.isManaged(
      guiCommand: "wezterm-gui start", supportDirectory: URL(fileURLWithPath: "/s")))
  }

  @Test("WezTerm recall labels the managed view with the task name")
  func deterministicWezTermRecipeUsesTaskName() async throws {
    let agentID = "agent-one"
    let reference = taskReference()
    let runner = DeterministicRecallRunner(reference: reference, agentID: agentID)
    var subtask = TaskSubtask(id: agentID, title: "Exact agent", provider: .codex,
      tmux: reference, runtimeMode: .tmux)
    subtask.workspace = AgentWorkspace(path: "/tmp", repositoryPath: "/tmp")

    let result = try await WezTermController(
      runner: runner, candidateSockets: []).openAgentRuntime(
        subtask, taskID: "ECC-1", taskTitle: "Polish the queue UI",
        configuration: .init(executable: "/mock/wezterm", applicationName: "WezTerm"))

    #expect(result == .focused(paneID: 41))
    let calls = await runner.calls
    #expect(calls.contains {
      $0.arguments == ["cli", "set-tab-title", "--pane-id", "41", "Polish the queue UI · tmux"] })
    #expect(calls.contains {
      $0.arguments == ["cli", "set-window-title", "--pane-id", "41", "Polish the queue UI"] })
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
    let pane = "\(reference.name)|\(reference.serverPID)|\(reference.createdAt)|\(reference.paneID)|\(reference.panePID)|\(reference.tty)|0|@1|0|160|50|0|0|80|24|agent-one|||1|auto||\n"
    let display = "\(reference.name)|\(reference.serverPID)|\(reference.createdAt)|\(reference.paneID)|\(reference.panePID)|\(reference.tty)|0\n"
    let runner = ManagedRecallRunner([
      result("ECC-1\n"), result(pane), result(display), result(display), result(), result(),
      result(exit: 1), result(), result(), result("/dev/ttys501\n"), result(display),
    ])
    var subtask = TaskSubtask(id: "agent-one", title: "Exact agent", provider: .codex,
      tmux: reference, runtimeMode: .tmux)
    subtask.workspace = AgentWorkspace(path: "/tmp", repositoryPath: "/tmp")

    let support = FileManager.default.temporaryDirectory
      .appendingPathComponent("fq-recall-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: support) }

    let action = try await WezTermController(
      runner: runner, candidateSockets: [], supportDirectory: support).openAgentRuntime(
        subtask, taskID: "ECC-1", taskTitle: "Fix recall",
        configuration: .init(executable: "/mock/wezterm", applicationName: "WezTerm"))

    #expect(action == .spawned(paneID: nil))
    let calls = await runner.calls
    // Launch Services owns the GUI; a runner deadline must never close it.
    let started = try #require(calls.first { $0.executable == "/usr/bin/open" })
    #expect(started.workingDirectory == "/tmp")
    // The managed config loads the user's own WezTerm settings and labels the
    // window, instead of `--skip-config` defaults titled "tmux".
    let configFile = WezTermManagedConfig.fileURL(supportDirectory: support)
    #expect(started.arguments.starts(with: [
      "-na", "WezTerm",
      "--env", "FOCUS_QUEUE_WEZTERM_TAB_TITLE=Fix recall · tmux",
      "--env", "FOCUS_QUEUE_WEZTERM_WINDOW_TITLE=Fix recall",
      "--args", "--config-file", configFile.path, "start", "--always-new-process", "--cwd", "/tmp", "--",
    ]))
    #expect(!started.arguments.contains("--skip-config"))
    #expect(FileManager.default.fileExists(atPath: configFile.path))
    #expect(started.arguments.contains("attach-session"))
    #expect(started.arguments.contains("=fq-task-ecc-1"))
    #expect(started.arguments.contains("%7"))
    #expect(!calls.contains { $0.executable == "/mock/wezterm" && $0.arguments.contains("start") })
    #expect(calls.filter { $0.executable == "/usr/bin/open" }.count == 1)
  }

  @Test("A lookup timeout starts WezTerm once, then focuses the exact agent")
  func timeoutStartsWezTermAndRetries() async throws {
    let reference = taskReference()
    let runner = RestartingWezTermRunner(reference: reference, agentID: "agent-one")
    var subtask = TaskSubtask(id: "agent-one", title: "Exact agent", provider: .codex,
      tmux: reference, runtimeMode: .tmux)
    subtask.workspace = AgentWorkspace(path: "/tmp", repositoryPath: "/tmp")

    let result = try await WezTermController(
      runner: runner, candidateSockets: [], startupPollInterval: .milliseconds(1)
    ).openAgentRuntime(
      subtask, taskID: "ECC-1",
      configuration: .init(executable: "/mock/wezterm", applicationName: "WezTerm"))

    #expect(result == .focused(paneID: 41))
    let calls = await runner.calls
    // The first `open -a` is the recovery start; focusing the pane activates the app again.
    let opens = calls.filter { $0.executable == "/usr/bin/open" }
    #expect(opens.first?.arguments == ["-a", "WezTerm"])
    #expect(opens.first?.workingDirectory == "/tmp")
    // The app start sits between the timed-out probe and the successful one.
    let listIndexes = calls.indices.filter { calls[$0].arguments.contains("list") && calls[$0].executable == "/mock/wezterm" }
    let openIndex = try #require(calls.firstIndex { $0.executable == "/usr/bin/open" })
    #expect(listIndexes.first! < openIndex && listIndexes.last! > openIndex)
    #expect(!calls.flatMap(\.arguments).contains("spawn"))
  }

  @Test("A lookup that still times out after the start reports it without a second start or a spawn")
  func timeoutAfterStartStops() async throws {
    let reference = taskReference()
    let runner = RestartingWezTermRunner(reference: reference, agentID: "agent-one", timesOutAfterStart: true)
    var subtask = TaskSubtask(id: "agent-one", title: "Exact agent", provider: .codex,
      tmux: reference, runtimeMode: .tmux)
    subtask.workspace = AgentWorkspace(path: "/tmp", repositoryPath: "/tmp")

    await #expect(throws: WezTermError.self) {
      try await WezTermController(
        runner: runner, candidateSockets: [], startupAttempts: 3,
        startupPollInterval: .milliseconds(1)
      ).openAgentRuntime(
        subtask, taskID: "ECC-1",
        configuration: .init(executable: "/mock/wezterm", applicationName: "WezTerm"))
    }
    let calls = await runner.calls
    #expect(calls.filter { $0.executable == "/usr/bin/open" }.count == 1)
    #expect(!calls.flatMap(\.arguments).contains("spawn"))
  }

  @Test("A failed WezTerm start surfaces its error and never spawns a view")
  func failedStartReportsDetail() async throws {
    let reference = taskReference()
    let runner = RestartingWezTermRunner(reference: reference, agentID: "agent-one", startSucceeds: false)
    var subtask = TaskSubtask(id: "agent-one", title: "Exact agent", provider: .codex,
      tmux: reference, runtimeMode: .tmux)
    subtask.workspace = AgentWorkspace(path: "/tmp", repositoryPath: "/tmp")

    do {
      _ = try await WezTermController(
        runner: runner, candidateSockets: [], startupPollInterval: .milliseconds(1)
      ).openAgentRuntime(
        subtask, taskID: "ECC-1",
        configuration: .init(executable: "/mock/wezterm", applicationName: "WezTerm"))
      Issue.record("Expected the failed start to throw")
    } catch let error as WezTermError {
      #expect(error.localizedDescription.contains("could not start WezTerm"))
      #expect(error.localizedDescription.contains("Unable to find application"))
    }
    #expect(!(await runner.calls).flatMap(\.arguments).contains("spawn"))
  }

  @Test("Ghostty recall opens a new window attached to the exact verified tmux pane")
  func deterministicGhosttyRecipe() async throws {
    let agentID = "agent-two"
    let reference = taskReference()
    let runner = DeterministicRecallRunner(reference: reference, agentID: agentID)
    let subtask = TaskSubtask(id: agentID, title: "Ghostty agent", provider: .codex,
      tmux: reference, runtimeMode: .tmux)

    let result = try await WezTermController(
      runner: runner, candidateSockets: []).openAgentRuntime(
        subtask, taskID: "ECC-1", taskTitle: "Fix recall",
        configuration: .init(executable: "/mock/wezterm", applicationName: "Ghostty"))

    #expect(result == .spawned(paneID: nil))
    let calls = await runner.calls
    let opened = try #require(calls.first { $0.executable == "/usr/bin/open" })
    #expect(opened.arguments.starts(with: [
      "-na", "Ghostty", "--args", "--quit-after-last-window-closed=true", "--title=Fix recall", "-e",
    ]))
    #expect(opened.arguments.contains("/mock/tmux"))
    #expect(opened.arguments.contains("attach-session"))
    #expect(opened.arguments.contains("=fq-task-ecc-1"))
    #expect(!calls.contains { $0.executable == "/mock/wezterm" })
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
        subtask, taskID: "ECC-1", taskTitle: "Fix recall",
        configuration: .init(executable: "/mock/wezterm", applicationName: "Terminal"))

    #expect(result == .spawned(paneID: nil))
    let calls = await runner.calls
    let opened = try #require(calls.first { $0.executable == "/usr/bin/open" })
    #expect(opened.arguments.starts(with: ["-a", "Terminal"]))
    // Starting Terminal must not reopen every window from its last session.
    #expect(opened.arguments.suffix(3) == ["--args", "-ApplePersistenceIgnoreState", "YES"])
    let scriptPath = try #require(opened.arguments.first { $0.hasSuffix(".command") })
    let script = try String(contentsOfFile: scriptPath, encoding: .utf8)
    #expect(script.hasPrefix("#!/bin/zsh\n"))
    #expect(script.contains("'/mock/tmux'"))
    #expect(script.contains("'attach-session'"))
    #expect(script.contains("'=fq-task-ecc-1'"))
    #expect(script.contains("'%7'"))
    #expect(script.contains("printf '\\033]0;%s\\007' 'Fix recall'\nif fq_tty="))
    // The window closer starts in its own session before tmux replaces the script.
    #expect(script.contains("POSIX::setsid()"))
    #expect(script.contains("-- \"$$\" \"$fq_tty\" "))
    #expect(script.contains(" &!\nfi\nexec "))
    #expect(!calls.contains { $0.executable == "/mock/wezterm" })
    let syntax = try await FoundationProcessRunner().run(.init(
      executable: "/bin/zsh", arguments: ["-n", scriptPath], timeoutSeconds: 10))
    #expect(syntax.succeeded, "\(syntax.standardError)")
    let permissions = try FileManager.default.attributesOfItem(atPath: scriptPath)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o700)
    try? FileManager.default.removeItem(atPath: scriptPath)
  }

  @Test("macOS Terminal window closer compiles as Perl and JavaScript")
  func macTerminalWindowCloserCompiles() async throws {
    let runner = FoundationProcessRunner()
    let perl = try await runner.run(.init(
      executable: "/usr/bin/perl", arguments: ["-c", "-e", TerminalCommandLauncher.windowCloser],
      timeoutSeconds: 10))
    #expect(perl.succeeded, "\(perl.standardError)")
    let output = FileManager.default.temporaryDirectory
      .appendingPathComponent("fq-closer-\(UUID().uuidString).scpt")
    defer { try? FileManager.default.removeItem(at: output) }
    let compiled = try await runner.run(.init(
      executable: "/usr/bin/osacompile",
      arguments: ["-l", "JavaScript", "-e", TerminalCommandLauncher.windowScript, "-o", output.path],
      timeoutSeconds: 20))
    #expect(compiled.succeeded, "\(compiled.standardError)")
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
    let pane = "fq-task-ecc-1|123|1000|%0|124|/dev/ttys099|0|@1|0|160|50|0|0|80|24|other-agent|||1|auto||\n"
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

    let support = FileManager.default.temporaryDirectory
      .appendingPathComponent("fq-recall-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: support) }

    await #expect(throws: WezTermError.self) {
      try await WezTermController(runner: runner, candidateSockets: [], supportDirectory: support).focusOrResume(
        session: session(), taskID: "ECC-1", configuration: .init(executable: "/mock/wezterm"))
    }
    let calls = await runner.calls
    let opened = calls.filter { $0.executable == "/usr/bin/open" }
    #expect(opened.count == 1)
    #expect(opened.first?.arguments.starts(with: ["-na", "WezTerm"]) == true)
    #expect(opened.first?.arguments.contains("--config-file") == true)
    #expect(opened.first?.arguments.contains("--skip-config") == false)
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

  /// Opt-in: needs WezTerm installed. An absent socket forces the path a
  /// restart takes, with no WezTerm GUI running. The window must outlive the
  /// launch command's 15-second deadline, attach through the user's own
  /// WezTerm config, and carry the task labels instead of "tmux".
  @Test("Live: recall without a WezTerm GUI keeps the new window attached",
    .enabled(if: ProcessInfo.processInfo.environment["ECC_FOCUS_QUEUE_LIVE_TERMINAL_TESTS"] == "1"))
  func liveRecallWithoutGUIKeepsWindow() async throws {
    let tmux = try #require(SetupEnvironment.executable("tmux"))
    let wezterm = try #require(SetupEnvironment.executable("wezterm"))
    let controller = TmuxController()
    let name = "fq-live-recall-\(UUID().uuidString.prefix(8).lowercased())"
    let reference = try await controller.start(
      name: name, directory: "/tmp", command: ["/bin/sleep", "600"], executable: tmux)
    do {
      // A socket with no GUI behind it is what a restart leaves; probing it
      // fails fast and recall takes the cold-start path.
      let absent = FileManager.default.temporaryDirectory
        .appendingPathComponent("fq-absent-\(UUID().uuidString.prefix(8))").path
      let result = try await WezTermController(candidateSockets: []).openManagedRuntime(
        reference, taskID: "FOC-077", provider: .claude, taskTitle: "Live recall check",
        configuration: .init(executable: wezterm, applicationName: "WezTerm", socketPath: absent))
      #expect(result == .spawned(paneID: nil))
      try await Task.sleep(for: .seconds(20))
      #expect(try await controller.clientTTYs(for: reference).count == 1)

      let runner = FoundationProcessRunner()
      let processes = try await runner.run(.init(
        executable: "/usr/bin/pgrep", arguments: ["-f", "wezterm-gui.*--config-file.*\(name)"],
        timeoutSeconds: 5))
      let pid = try #require(processes.standardOutput.split(separator: "\n").first.map(String.init))
      let socket = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/share/wezterm/gui-sock-\(pid)").path
      let listed = try await runner.run(.init(
        executable: wezterm, arguments: ["cli", "list", "--format", "json"],
        environment: ["WEZTERM_UNIX_SOCKET": socket], timeoutSeconds: 10))
      let panes = try #require(JSONSerialization.jsonObject(
        with: Data(listed.standardOutput.utf8)) as? [[String: Any]])
      #expect(panes.count == 1)
      #expect(panes.first?["tab_title"] as? String == "Live recall check · tmux")
      #expect(panes.first?["window_title"] as? String == "Live recall check")
      _ = try? await runner.run(.init(executable: "/bin/kill", arguments: [pid], timeoutSeconds: 5))
    } catch {
      try? await controller.stop(reference)
      throw error
    }
    try await controller.stop(reference)
  }

  /// FOC-142 end to end: two task windows in one Focus Queue WezTerm; opening
  /// the task behind must bring its own window to the front of WezTerm's
  /// window stack. Window order comes from CoreGraphics, front to back.
  @Test("Live: recall brings the task's own WezTerm window in front of another task's",
    .enabled(if: ProcessInfo.processInfo.environment["ECC_FOCUS_QUEUE_LIVE_TERMINAL_TESTS"] == "1"))
  func liveRecallRaisesExactWindow() async throws {
    let tmux = try #require(SetupEnvironment.executable("tmux"))
    let wezterm = try #require(SetupEnvironment.executable("wezterm"))
    let id = UUID().uuidString.prefix(8).lowercased()
    let support = FileManager.default.temporaryDirectory
      .appendingPathComponent("fq-live-raise-\(id)", isDirectory: true)
    let sessions = TmuxController()
    let first = try await sessions.start(
      name: "fq-live-raise-\(id)-a", directory: "/tmp", command: ["/bin/sleep", "600"], executable: tmux)
    let second = try await sessions.start(
      name: "fq-live-raise-\(id)-b", directory: "/tmp", command: ["/bin/sleep", "600"], executable: tmux)
    let runner = FoundationProcessRunner()
    var guiPID: String?
    func windows() -> [Int] {
      guard let pid = guiPID.flatMap(Int.init),
            let list = CGWindowListCopyWindowInfo(
              [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
      else { return [] }
      return list.filter { ($0[kCGWindowOwnerPID as String] as? Int) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
        .compactMap { $0[kCGWindowNumber as String] as? Int }
    }
    do {
      let controller = WezTermController(candidateSockets: [], supportDirectory: support)
      let absent = support.appendingPathComponent("no-gui").path
      _ = try await controller.openManagedRuntime(
        first, taskID: "FOC-142", provider: .claude, taskTitle: "First task",
        configuration: .init(executable: wezterm, applicationName: "WezTerm", socketPath: absent))
      var socket = ""
      for _ in 0..<60 where guiPID == nil {
        try await Task.sleep(for: .milliseconds(250))
        let found = try await runner.run(.init(executable: "/usr/bin/pgrep",
          arguments: ["-f", "wezterm-gui.*fq-live-raise-\(id)"], timeoutSeconds: 5))
        guiPID = found.standardOutput.split(separator: "\n").first.map(String.init)
      }
      let pid = try #require(guiPID)
      socket = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/share/wezterm/gui-sock-\(pid)").path
      for _ in 0..<40 where windows().isEmpty { try await Task.sleep(for: .milliseconds(250)) }
      let firstWindow = try #require(windows().first)
      let pinned = WezTermConfiguration(executable: wezterm, applicationName: "WezTerm", socketPath: socket)

      _ = try await controller.openManagedRuntime(
        second, taskID: "FOC-143", provider: .claude, taskTitle: "Second task", configuration: pinned)
      try await Task.sleep(for: .seconds(1))
      #expect(windows().count == 2)
      #expect(windows().first != firstWindow, "the second task's new window should open in front")

      let reopened = try await controller.openManagedRuntime(
        first, taskID: "FOC-142", provider: .claude, taskTitle: "First task", configuration: pinned)
      guard case .focused = reopened else {
        Issue.record("expected the existing view to be focused, got \(reopened)"); throw CancellationError()
      }
      try await Task.sleep(for: .seconds(1))
      #expect(windows().first == firstWindow, "the first task's window must come to the front")
    } catch {
      Issue.record(error)
    }
    if let guiPID { _ = try? await runner.run(.init(executable: "/bin/kill", arguments: [guiPID], timeoutSeconds: 5)) }
    try? await sessions.stop(first)
    try? await sessions.stop(second)
    try? FileManager.default.removeItem(at: support)
  }
}
