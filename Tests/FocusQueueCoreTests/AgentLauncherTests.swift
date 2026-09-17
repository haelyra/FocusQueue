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

  let reference = try await TaskAgentLauncher(runner: runner).startManagedSession(
    context: context, subtask: subtask,
    supportDirectory: root.appendingPathComponent("support"), tmuxExecutable: "/test/tmux")

  #expect(reference.name == "fq-task-ecc-1")
  #expect(reference.panePID == 124)
  let calls = await runner.specifications
  #expect(calls.allSatisfy { $0.executable == "/test/tmux" })
  #expect(calls.filter { $0.arguments.contains("new-session") }.count == 1)
  #expect(calls.filter { $0.arguments.contains("display-message") }.count >= 4)
  #expect(!calls.flatMap(\.arguments).contains("resume"))
  #expect(!calls.flatMap(\.arguments).contains("spawn"))
}

@Test func managedAgentCreationTimeoutDoesNotAttemptASecondSession() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "managed-agent-timeout-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let runner = TaskPaneLaunchRunner(timeout: true)
  let context = TaskContext(
    ticketID: "ECC-1", title: "Launch", summary: "", successCriteria: "Checks pass",
    planPath: root.appendingPathComponent("plan.md").path, worktreePath: root.path,
    updatedAt: Date())

  await #expect(throws: TmuxError.self) {
    try await TaskAgentLauncher(runner: runner).startManagedSession(
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
