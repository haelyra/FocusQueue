import Darwin
import Foundation
import Testing
@testable import FocusQueueCore

@Test func agentLaunchTreatsAssignmentsAsLiteralArguments() throws {
  let context = TaskContext(ticketID: "ECC-1", title: "Literal $(touch /tmp/wrong)", summary: "",
    successCriteria: "Checks pass", planPath: "/tmp/task with spaces/plan.md", worktreePath: "/tmp/work tree",
    updatedAt: Date())
  let subtask = TaskSubtask(title: "Fix `quotes` and $HOME")
  let args = try TaskAgentLauncher.command(context: context, subtask: subtask,
    supportDirectory: URL(fileURLWithPath: "/tmp/support"))
  #expect(args.contains("builtin cd -- \"$1\" || exit 72; shift; codex \"$@\""))
  #expect(args.last?.contains("Fix `quotes` and $HOME") == true)
  #expect(args.contains("FOCUS_QUEUE_SUBTASK_ID=\(subtask.id)"))
  #expect(args.contains("/tmp/task with spaces"))
}

@Test func subtaskExplanationSurvivesPersistenceAndAppearsInTheAgentPrompt() throws {
  let context = TaskContext(
    ticketID: "ECC-1", title: "Expandable subtask", summary: "", successCriteria: "Checks pass",
    planPath: "/tmp/support/tasks/ECC-1/plan.md", worktreePath: "/tmp/worktree",
    updatedAt: Date())
  let subtask = TaskSubtask(
    id: "details", title: "Keep the full title visible",
    assignmentDescription: "Explain the interaction and retain archived results.")
  let decoded = try JSONDecoder().decode(TaskSubtask.self, from: JSONEncoder().encode(subtask))
  #expect(decoded.assignmentDescription == subtask.assignmentDescription)
  #expect(context.agentPrompt(subtask: decoded).contains("Assignment details: \(subtask.assignmentDescription)"))
}

@Test func agentShellAliasesAndFunctionsPreserveHostileArgumentsInBothPromptModes() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-shell-test-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let fixture = """
  focus_capture() { builtin printf '%s\\0' "$@"; }
  alias codex='focus_capture alias'
  claude() { focus_capture function "$@"; }
  kimi() { focus_capture function "$@"; }
  """
  let zshrc = root.appendingPathComponent(".zshrc")
  let bashrc = root.appendingPathComponent("bashrc")
  try Data(fixture.utf8).write(to: zshrc)
  try Data(fixture.utf8).write(to: bashrc)
  let sentinel = root.appendingPathComponent("must-not-exist")
  let hostile = "Literal $(touch '\(sentinel.path)') `echo wrong` $HOME ; \"quotes\"\nsecond line"
  let context = TaskContext(ticketID: "ECC-1", title: hostile, summary: "", successCriteria: "Checks pass",
    planPath: root.appendingPathComponent("plan with spaces.md").path, worktreePath: root.path, updatedAt: Date())
  for shell in ["/bin/zsh", "/bin/bash"] {
    for provider in AgentProvider.allCases {
      for includePrompt in [false, true] {
        let subtask = TaskSubtask(title: hostile, provider: provider)
        let launch = try TaskAgentLauncher.command(context: context, subtask: subtask,
          supportDirectory: root, includePrompt: includePrompt, shellPath: shell)
        let shellIndex = try #require(launch.firstIndex(of: shell))
        var shellArguments = Array(launch.dropFirst(shellIndex + 1))
        if shell == "/bin/bash" {
          // A dedicated rc file isolates the headless test from the user's startup files.
          shellArguments = ["--noprofile", "--rcfile", bashrc.path, "-ic"] + Array(shellArguments.dropFirst())
        }
        let result = try await FoundationProcessRunner().run(.init(executable: shell, arguments: shellArguments,
          environment: ["ZDOTDIR": root.path], timeoutSeconds: 10))
        #expect(result.succeeded, "\(shell): \(result.standardError)")
        let captured = result.standardOutput.split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)
        #expect(captured.first == (provider == .codex ? "alias" : "function"))
        #expect(captured.dropFirst().prefix(2) == ["--add-dir", context.contextDirectory.path])
        if includePrompt { #expect(captured.last?.contains(hostile) == true) }
        else { #expect(captured.count == 3) }
        #expect(!FileManager.default.fileExists(atPath: sentinel.path))
      }
    }
  }
}

@Test func agentPlainSessionPreferenceSurvivesPersistenceAndResume() throws {
  let context = TaskContext(ticketID: "ECC-1", title: "Normal session", summary: "", successCriteria: "Checks pass",
    planPath: "/tmp/support/tasks/ECC-1/plan.md", worktreePath: "/tmp/worktree", updatedAt: Date())
  let plain = TaskSubtask(title: "Human guided", includeInitializationPrompt: false)
  let decoded = try JSONDecoder().decode(TaskSubtask.self, from: JSONEncoder().encode(plain))
  #expect(!decoded.includeInitializationPrompt)
  let original = TaskAgentSession(ticketID: "ECC-1", provider: .codex, sessionID: "test-session",
    tabTitle: "task", workingDirectory: "/tmp/worktree")
  let resumed = original.withContext(context, subtask: decoded, supportDirectory: URL(fileURLWithPath: "/tmp/support"))
  #expect(resumed.resumePrompt == nil)
  #expect(resumed.contextDirectory == context.contextDirectory.path)
  let command = try TaskAgentLauncher.command(context: context, subtask: decoded,
    supportDirectory: URL(fileURLWithPath: "/tmp/support"))
  #expect(command.last == context.agentBootstrap(subtask: decoded))
  #expect(command.last?.contains("wait for my instruction") == true)
  let legacy = Data(#"{"id":"old","title":"Legacy","provider":"codex","status":"queued"}"#.utf8)
  let legacySubtask = try JSONDecoder().decode(TaskSubtask.self, from: legacy)
  #expect(legacySubtask.includeInitializationPrompt)
  #expect(legacySubtask.assignmentDescription.isEmpty)
}

@Test("Exact Codex resume keeps the saved workspace, UUID, alias, and native argument order")
func exactCodexResumeRecipe() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "exact-resume path 'quoted' \(UUID().uuidString)")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let zshrc = root.appendingPathComponent(".zshrc")
  try Data("alias codex='printf \"%s\\\\0\"'\n".utf8).write(to: zshrc)
  let sessionID = "11111111-2222-4333-8444-555555555555"
  let context = TaskContext(ticketID: "ECC-1", title: "Resume", summary: "",
    successCriteria: "Exact conversation", planPath: root.appendingPathComponent("plan.md").path,
    worktreePath: root.path, updatedAt: Date())
  var subtask = TaskSubtask(id: "resume-agent", title: "Resume exact", provider: .codex,
    sessionID: sessionID, includeInitializationPrompt: false, runtimeMode: .tmux)
  subtask.workspace = AgentWorkspace(path: root.path, repositoryPath: root.path)
  subtask.launchConfiguration = AgentLaunchConfiguration(model: "gpt-test", effort: "high")
  let launch = try TaskAgentLauncher.command(
    context: context, subtask: subtask, supportDirectory: root,
    includePrompt: false, shellPath: "/bin/zsh")
  let shellIndex = try #require(launch.firstIndex(of: "/bin/zsh"))
  let result = try await FoundationProcessRunner().run(.init(
    executable: "/bin/zsh", arguments: Array(launch.dropFirst(shellIndex + 1)),
    environment: ["ZDOTDIR": root.path], timeoutSeconds: 10))

  #expect(result.succeeded, "\(result.standardError)")
  let arguments = result.standardOutput.split(separator: "\0", omittingEmptySubsequences: false)
    .dropLast().map(String.init)
  #expect(arguments == ["resume", sessionID, "--cd", root.path,
    "--model", "gpt-test", "-c", "model_reasoning_effort=high",
    "--add-dir", context.contextDirectory.path])
}

@Test("A Codex sub-agent resume targets the root of its conversation lineage")
func subagentResumeTargetsLineageRoot() throws {
  let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(
    "lineage-resume-\(UUID().uuidString)", isDirectory: true)
  let sessions = fixture.appendingPathComponent("sessions/2026/09/24", isDirectory: true)
  try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: fixture) }
  let rootID = "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa"
  let middleID = "bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb"
  let leafID = "cccccccc-3333-4333-8333-cccccccccccc"
  for (name, id, parent) in [
    ("rollout-2026-09-24T01-00-00-\(rootID)", rootID, nil as String?),
    ("rollout-2026-09-24T01-10-00-\(middleID)", middleID, rootID),
    ("rollout-2026-09-24T01-20-00-\(leafID)", leafID, middleID),
  ] {
    let parentField = parent.map { ",\"parent_thread_id\":\"\($0)\"" } ?? ""
    try Data(("{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\"\(parentField),"
      + "\"source\":{\"subagent\":{\"thread_spawn\":{}}}}}\n").utf8)
      .write(to: sessions.appendingPathComponent("\(name).jsonl"))
  }
  #expect(CodexSessionLineage.root(of: leafID, codexRoot: fixture) == rootID)
  #expect(CodexSessionLineage.root(of: rootID, codexRoot: fixture) == rootID)
  #expect(CodexSessionLineage.root(of: "dddddddd-4444-4444-8444-dddddddddddd",
    codexRoot: fixture) == "dddddddd-4444-4444-8444-dddddddddddd")

  let workspace = fixture.appendingPathComponent("workspace", isDirectory: true)
  try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
  let context = TaskContext(ticketID: "ECC-1", title: "Resume", summary: "",
    successCriteria: "Exact conversation", planPath: workspace.appendingPathComponent("plan.md").path,
    worktreePath: workspace.path, updatedAt: Date())
  var subtask = TaskSubtask(id: "sub-agent", title: "Review sub-agent", provider: .codex,
    sessionID: leafID, includeInitializationPrompt: false, runtimeMode: .tmux)
  subtask.workspace = AgentWorkspace(path: workspace.path, repositoryPath: workspace.path)
  let launch = try TaskAgentLauncher.command(
    context: context, subtask: subtask, supportDirectory: fixture,
    includePrompt: false, shellPath: "/bin/zsh", codexRoot: fixture)
  let resumeIndex = try #require(launch.firstIndex(of: "resume"))
  #expect(launch[launch.index(after: resumeIndex)] == rootID)
  #expect(!launch.contains(leafID))
}

@Test("Kimi launches with --prompt, skips effort flags, and resumes through --session")
func kimiLaunchAndResumeRecipe() throws {
  let context = TaskContext(ticketID: "ECC-1", title: "Kimi launch", summary: "",
    successCriteria: "Checks pass", planPath: "/tmp/support/tasks/ECC-1/plan.md",
    worktreePath: "/tmp/worktree", updatedAt: Date())

  var fresh = TaskSubtask(title: "Fresh kimi", provider: .kimi)
  fresh.launchConfiguration = AgentLaunchConfiguration(model: "kimi-code/k3", effort: "high")
  let launch = try TaskAgentLauncher.command(context: context, subtask: fresh,
    supportDirectory: URL(fileURLWithPath: "/tmp/support"))
  let modelIndex = try #require(launch.firstIndex(of: "--model"))
  #expect(launch[launch.index(after: modelIndex)] == "kimi-code/k3")
  #expect(!launch.contains("--effort"))
  #expect(!launch.contains { $0.hasPrefix("model_reasoning_effort=") })
  // Kimi has no positional prompt; the prompt goes through --prompt with no `--`.
  let promptIndex = try #require(launch.firstIndex(of: "--prompt"))
  #expect(launch[launch.index(after: promptIndex)] == context.agentPrompt(subtask: fresh))
  #expect(!launch.contains("--"))

  for sessionID in ["session_11111111-2222-4333-8444-555555555555", "01HZ8KJ9X0AVBR1C2D3E4F5G6H"] {
    let resumed = TaskSubtask(title: "Resume kimi", provider: .kimi, sessionID: sessionID)
    let command = try TaskAgentLauncher.command(context: context, subtask: resumed,
      supportDirectory: URL(fileURLWithPath: "/tmp/support"), includePrompt: false)
    let sessionIndex = try #require(command.firstIndex(of: "--session"))
    #expect(command[command.index(after: sessionIndex)] == sessionID)
    #expect(!command.contains("--prompt"))
    #expect(!command.contains("--resume"))
  }

  let invalid = TaskSubtask(title: "Bad kimi", provider: .kimi, sessionID: "not a session")
  #expect(throws: TaskContextError.self) {
    try TaskAgentLauncher.command(context: context, subtask: invalid,
      supportDirectory: URL(fileURLWithPath: "/tmp/support"))
  }
}

private actor AgentLaunchRunner: ProcessRunning {
  var results: [ProcessResult]
  var specifications: [ProcessSpecification] = []
  init(_ results: [ProcessResult]) { self.results = results }
  func run(_ specification: ProcessSpecification) throws -> ProcessResult {
    specifications.append(specification)
    return results.removeFirst()
  }
}

private actor TaskPaneLaunchRunner: ProcessRunning {
  private(set) var specifications: [ProcessSpecification] = []
  var observations = 0
  let timeout: Bool
  init(timeout: Bool = false) { self.timeout = timeout }
  func run(_ specification: ProcessSpecification) -> ProcessResult {
    specifications.append(specification)
    if specification.arguments.contains("has-session") {
      return .init(exitCode: 1, standardOutput: "", standardError: "can't find session", timedOut: false)
    }
    if specification.arguments.contains("new-session") {
      return .init(exitCode: timeout ? 1 : 0,
        standardOutput: "fq-task-ecc-1|123|1000|%0|||0\n", standardError: "", timedOut: timeout)
    }
    if specification.arguments.contains("display-message") {
      observations += 1
      return .init(exitCode: 0,
        standardOutput: "fq-task-ecc-1|123|1000|%0|\(observations == 1 ? 120 : 124)|/dev/ttys099|0\n",
        standardError: "", timedOut: false)
    }
    return .init(exitCode: 0, standardOutput: "", standardError: "", timedOut: false)
  }
}

@Test func managedAgentCreationReturnsTheExactTmuxIdentityBeforeAnyTerminalWork() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "managed-agent-launch-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let runner = TaskPaneLaunchRunner()
  let context = TaskContext(
    ticketID: "ECC-1", title: "Launch", summary: "", successCriteria: "Checks pass",
    planPath: root.appendingPathComponent("plan.md").path, worktreePath: root.path,
    updatedAt: Date())
  let subtask = TaskSubtask(id: "implement", title: "Implement session ownership")
  let server = "managed-agent-" + UUID().uuidString.lowercased()
  let receipts = FileManager.default.temporaryDirectory.appendingPathComponent(
    "focus-queue-launches-\(server)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: receipts) }

  let reference = try await TaskAgentLauncher(runner: runner, tmuxServerName: server).startManagedSession(
    context: context, subtask: subtask,
    supportDirectory: root.appendingPathComponent("support"), tmuxExecutable: "/test/tmux")

  #expect(reference.name == "fq-task-ecc-1")
  #expect(reference.panePID == 124)
  let calls = await runner.specifications
  #expect(calls.allSatisfy { $0.executable == "/test/tmux" })
  #expect(calls.filter { $0.arguments.contains("new-session") }.count == 1)
  #expect(calls.filter { $0.arguments.contains("display-message") }.count >= 4)
  #expect(calls.first { $0.arguments.contains("new-session") }?.arguments.contains("FOCUS_QUEUE_MANAGED_TMUX=1") == true)
  #expect(!calls.flatMap(\.arguments).contains("resume"))
  #expect(!calls.flatMap(\.arguments).contains("spawn"))
}

@Test func managedAgentCreationTimeoutDoesNotAttemptASecondSession() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "managed-agent-timeout-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let runner = TaskPaneLaunchRunner(timeout: true)
  let server = "managed-timeout-" + UUID().uuidString.lowercased()
  let receipts = FileManager.default.temporaryDirectory.appendingPathComponent(
    "focus-queue-launches-\(server)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: receipts) }
  let context = TaskContext(
    ticketID: "ECC-1", title: "Launch", summary: "", successCriteria: "Checks pass",
    planPath: root.appendingPathComponent("plan.md").path, worktreePath: root.path,
    updatedAt: Date())

  await #expect(throws: TmuxError.self) {
    try await TaskAgentLauncher(runner: runner, tmuxServerName: server).startManagedSession(
      context: context, subtask: .init(id: "implement", title: "Implement session ownership"),
      supportDirectory: root.appendingPathComponent("support"), tmuxExecutable: "/test/tmux")
  }
  #expect(await runner.specifications.filter { $0.arguments.contains("new-session") }.count == 1)
}

@Test func directAgentCreationStoresTheExactPaneWithoutStartingTmux() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "direct-agent-launch-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let runner = AgentLaunchRunner([
    .init(exitCode: 0, standardOutput: "[]", standardError: "", timedOut: false),
    .init(exitCode: 0, standardOutput: "42\n", standardError: "", timedOut: false),
  ])
  let context = TaskContext(
    ticketID: "ECC-1", title: "Launch", summary: "", successCriteria: "Checks pass",
    planPath: root.appendingPathComponent("plan.md").path, worktreePath: root.path,
    updatedAt: Date())
  let subtask = TaskSubtask(
    id: "direct", title: "Run without tmux", includeInitializationPrompt: false,
    runtimeMode: .terminal)

  let receipt = try await TaskAgentLauncher(runner: runner, candidateSockets: []).launchDirect(
    context: context, subtask: subtask,
    configuration: .init(executable: "/mock/wezterm", socketPath: "/tmp/wezterm-focus.sock"),
    supportDirectory: root.appendingPathComponent("support"), includePrompt: false)

  #expect(receipt == DirectAgentLaunchReceipt(paneID: 42, socketPath: "/tmp/wezterm-focus.sock"))
  let calls = await runner.specifications
  #expect(calls.count == 2)
  #expect(calls[0].arguments == ["cli", "list", "--format", "json"])
  #expect(calls[1].arguments.starts(with: ["cli", "spawn", "--new-window"]))
  #expect(calls[1].arguments.contains("FOCUS_QUEUE_RUNTIME_MODE=terminal"))
  #expect(!calls[1].arguments.contains("FOCUS_QUEUE_TMUX_NAME=fq-direct"))
  #expect(!calls.flatMap(\.arguments).contains("new-session"))
  #expect(!calls[1].arguments.contains { $0.contains("Work on ECC-1") })
}

@Test func directAgentLaunchTimeoutNeverRetriesOrCreatesADuplicate() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "direct-agent-timeout-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let runner = AgentLaunchRunner([
    .init(exitCode: 0, standardOutput: "[]", standardError: "", timedOut: false),
    .init(exitCode: 1, standardOutput: "", standardError: "", timedOut: true),
  ])
  let context = TaskContext(
    ticketID: "ECC-1", title: "Launch", summary: "", successCriteria: "Checks pass",
    planPath: root.appendingPathComponent("plan.md").path, worktreePath: root.path,
    updatedAt: Date())

  await #expect(throws: WezTermError.self) {
    try await TaskAgentLauncher(runner: runner, candidateSockets: []).launchDirect(
      context: context,
      subtask: .init(id: "direct", title: "Run without tmux", runtimeMode: .terminal),
      configuration: .init(executable: "/mock/wezterm"),
      supportDirectory: root.appendingPathComponent("support"))
  }
  let calls = await runner.specifications
  #expect(calls.count == 2)
  #expect(calls.filter { $0.arguments.contains("spawn") }.count == 1)
}

@Test func managedLauncherKeepsStartAttentionAndCleanupOnItsInjectedServer() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("isolated-launcher-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let runner = TaskPaneLaunchRunner()
  let server = "launch-test-\(UUID().uuidString.lowercased())"
  let launcher = TaskAgentLauncher(runner: runner, tmuxServerName: server)
  let context = TaskContext(ticketID: "ECC-1", title: "Isolated launch", summary: "", successCriteria: "",
    planPath: root.appendingPathComponent("plan.md").path, worktreePath: root.path, updatedAt: Date())
  var subtask = TaskSubtask(id: "isolated", title: "Isolated provider", runtimeMode: .tmux)
  subtask.tmux = try await launcher.startManagedSession(context: context, subtask: subtask,
    supportDirectory: root, tmuxExecutable: "/test/tmux")
  _ = try await launcher.runtimeAttention(subtask: subtask, configuration: .init(executable: "/unused/wezterm"))
  try await launcher.closeRuntime(subtask: subtask, configuration: .init(executable: "/unused/wezterm"))
  let calls = await runner.specifications
  #expect(calls.contains { $0.arguments.contains("capture-pane") })
  #expect(calls.contains { $0.arguments.contains("kill-pane") })
  #expect(calls.allSatisfy { specification in
    guard let flag = specification.arguments.firstIndex(of: "-L") else { return false }
    return specification.arguments[flag + 1] == server
  })
}

@Test("Partial metadata for a still-present pane stays unavailable, preventing duplicate resume")
func managedRuntimeAttentionRetainsAnUnconfirmedLivePane() async throws {
  let runner = AgentLaunchRunner([
    .init(exitCode: 0, standardOutput: "fq-task-ecc-1|123|1000|%0|||0\n", standardError: "", timedOut: false),
    .init(exitCode: 0, standardOutput: "%0\n", standardError: "", timedOut: false)
  ])
  var subtask = TaskSubtask(id: "partial", title: "Partially ready pane", runtimeMode: .tmux)
  subtask.tmux = .init(name: "fq-task-ecc-1", serverPID: 123, createdAt: 1000,
    paneID: "%0", panePID: 124, tty: "/dev/ttys099", executable: "/test/tmux")
  let launcher = TaskAgentLauncher(runner: runner, tmuxServerName: "isolated-partial")
  // A stopped result is translated to .interrupted. The known present pane must
  // keep throwing unavailable until its metadata settles.
  await #expect(throws: TmuxError.self) {
    try await launcher.runtimeAttention(subtask: subtask, configuration: .init(executable: "/unused/wezterm"))
  }
  #expect(await runner.specifications.last?.arguments.suffix(4) == ["list-panes", "-a", "-F", "#{pane_id}"])
}

private actor BatchedAttentionRunner: ProcessRunning {
  private(set) var specifications: [ProcessSpecification] = []
  let paneListing: String
  let captureText: String
  init(paneListing: String, captureText: String) {
    self.paneListing = paneListing
    self.captureText = captureText
  }
  func run(_ specification: ProcessSpecification) -> ProcessResult {
    specifications.append(specification)
    if specification.arguments.contains("list-panes") {
      return .init(exitCode: 0, standardOutput: paneListing, standardError: "", timedOut: false)
    }
    if specification.arguments.contains("capture-pane") {
      return .init(exitCode: 0, standardOutput: captureText, standardError: "", timedOut: false)
    }
    return .init(exitCode: 0, standardOutput: "", standardError: "", timedOut: false)
  }
}

@Test("Batched attention shares one pane listing and skips captures for fresh heartbeats")
func batchedRuntimeAttentionSharesListingAndSkipsFreshHeartbeats() async throws {
  let paneListing = """
  fq-task-ecc-1|123|1000|%0|124|/dev/ttys099|0|@1|0|200|50|0|0|200|50||||1|
  fq-task-ecc-1|123|1000|%1|125|/dev/ttys100|0|@1|0|200|50|0|0|200|50||||0|
  """
  let runner = BatchedAttentionRunner(paneListing: paneListing,
    captureText: "Do you want to proceed?\n› 1. Yes\n  2. No (Esc)\n")
  let launcher = TaskAgentLauncher(runner: runner,
    tmuxServerName: "batched-" + UUID().uuidString.lowercased())
  var stale = TaskSubtask(id: "stale", title: "Stale", provider: .codex, runtimeMode: .tmux)
  stale.tmux = .init(name: "fq-task-ecc-1", serverPID: 123, createdAt: 1000, paneID: "%0",
    panePID: 124, tty: "/dev/ttys099", executable: "/bin/zsh")
  stale.lastHeartbeatAt = Date(timeIntervalSinceNow: -60)
  var fresh = TaskSubtask(id: "fresh", title: "Fresh", provider: .codex, runtimeMode: .tmux)
  fresh.tmux = .init(name: "fq-task-ecc-1", serverPID: 123, createdAt: 1000, paneID: "%1",
    panePID: 125, tty: "/dev/ttys100", executable: "/bin/zsh")
  fresh.lastHeartbeatAt = Date()
  var gone = TaskSubtask(id: "gone", title: "Gone", provider: .codex, runtimeMode: .tmux)
  gone.tmux = .init(name: "fq-task-ecc-1", serverPID: 123, createdAt: 1000, paneID: "%9",
    panePID: 126, tty: "/dev/ttys101", executable: "/bin/zsh")

  let configuration = WezTermConfiguration(executable: "/unused/wezterm")
  let snapshot = await launcher.runtimeSnapshot(subtasks: [stale, fresh, gone], configuration: configuration)
  let attentions = await launcher.runtimeAttention(subtasks: [stale, fresh, gone],
    configuration: configuration, snapshot: snapshot)

  #expect(attentions[stale.id]! == .approval)
  #expect(!attentions.keys.contains(fresh.id))
  #expect(attentions[gone.id]! == .interrupted)
  let calls = await runner.specifications
  #expect(calls.filter { $0.arguments.contains("list-panes") }.count == 1)
  #expect(calls.filter { $0.arguments.contains("capture-pane") }.count == 1)
}
