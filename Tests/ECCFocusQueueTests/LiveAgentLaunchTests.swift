import Darwin
import Foundation
import Testing
import FocusQueueCore
@testable import ECCFocusQueue

/// Runs the actual New Agent model workflow and installed login-shell Codex
/// command. Only the graphical WezTerm view is replaced by a headless tmux client.
@Test("Live New Agent matrix preserves provider identity through detach and reopen",
  .enabled(if: ProcessInfo.processInfo.environment["ECC_FOCUS_QUEUE_LIVE_AGENT_TESTS"] == "1"))
@MainActor
func liveManagedProviderSanity() async throws {
  let fixture = try LiveAgentFixture()
  defer { fixture.cleanup() }
  try await fixture.prepare()
  let launcher = TaskAgentLauncher(tmuxServerName: fixture.server)
  let terminal = LiveHeadlessTerminal(fixture: fixture)
  let model = QueueViewModel(paths: fixture.paths, terminalController: terminal, taskAgentLauncher: launcher)
  let ticket = DashboardTicket(id: fixture.taskID, title: "Headless launch sanity", status: "open",
    summary: "Reply SANITY_OK only. Do not use tools or edit files.")
  var observedSessions = Set<String>()
  var checkedVariants = 0
  for policy: AgentWorkspacePolicy in [.existingCheckout, .isolatedCommittedSnapshot] {
    let createWorktree = policy.createsWorktree
    // Reproduce the user's dirty task checkout with automatic isolation enabled.
    let localNote = fixture.source.appendingPathComponent("live-sanity-source-only.txt")
    if createWorktree { try Data("Preserve this uncommitted source work.\n".utf8).write(to: localNote) }
    for initialize in [false, true] {
      let subtaskID = UUID().uuidString
      let label = "worktree=\(createWorktree), initialization=\(initialize)"
      print("LIVE_AGENT_SANITY starting \(label), server=\(fixture.server)")
      var launched: Bool?
      model.launchAgent(for: ticket, title: "Sanity \(label)", provider: .codex,
        repositoryPath: fixture.source.path, includePrompt: initialize, useTmux: true,
        createWorktree: createWorktree,
        initialPrompt: "This is a launch sanity check. Reply with exactly SANITY_OK. Do not use tools, run commands, register sessions, inspect plans, or edit files. These constraints also apply to any supplemental task initialization below.",
        subtaskID: subtaskID, createAssignment: true, workspacePolicy: policy) { launched = $0 }
      try await liveEventually("New Agent did not finish: \(label)", seconds: 60) { launched != nil }
      try #require(launched == true, "\(model.actionMessages[fixture.taskID] ?? "No launch result")")
      var subtask = try #require(model.subtasks(for: fixture.taskID).first { $0.id == subtaskID })
      let reference = try #require(subtask.tmux, "Launch reported success without a saved runtime")
      let workspace = try #require(subtask.workspace)
      #expect(workspace.managed == createWorktree)
      #expect(subtask.includeInitializationPrompt == initialize)
      #expect(createWorktree ? workspace.path != fixture.source.path : workspace.path == fixture.source.path)
      if createWorktree {
        #expect(try String(contentsOf: localNote, encoding: .utf8) == "Preserve this uncommitted source work.\n")
        #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: workspace.path).appendingPathComponent(localNote.lastPathComponent).path))
      }
      #expect(await terminal.opened.last == reference)

      var sessionID: String?
      var capture = ""
      do {
        try await liveEventually("Codex did not produce a ready response: \(label)", seconds: 90) {
          sessionID = try await launcher.identify(subtask: subtask, configuration: model.config.wezTerm)
          capture = try await fixture.tmux(["capture-pane", "-p", "-S", "-200", "-t", reference.paneID])
          return sessionID.flatMap(UUID.init(uuidString:)) != nil
            && capture.contains("OpenAI Codex")
            && capture.range(of: #"(?m)^\s*•\s+SANITY_OK\s*$"#, options: .regularExpression) != nil
        }
      } catch {
        throw LiveAgentFailure("\(label): \(error.localizedDescription)\nPane output:\n\(capture.suffix(4_000))")
      }
      let nativeID = try #require(sessionID)
      let processesForTracking = try await WezTermController().knownProviderProcesses()
      let nativeProcess = try #require(processesForTracking.first { $0.sessionID.lowercased() == nativeID.lowercased() })
      let intake = try #require(AgentIntakeStore.match(nativeProcess, tmux: reference,
        receipts: AgentIntakeStore.load(root: fixture.support), parents: try await AgentIntakeStore.processParents()),
        "The real Codex process must bind to its mandatory pre-launch receipt")
      try AgentIntakeStore.resolve(intake, sessionID: nativeID, root: fixture.support)
      #expect(!AgentIntakeStore.pending(root: fixture.support).contains { $0.id == intake.id })
      #expect(observedSessions.insert(nativeID).inserted, "Each New Agent must create its own conversation")
      #expect(nativeID != ProcessInfo.processInfo.environment["CODEX_SESSION_ID"])
      subtask.sessionID = nativeID
      let persisted = try await TaskContextStore(root: fixture.support).recordAgentIdentity(
        ticketID: fixture.taskID, subtaskID: subtask.id, sessionID: nativeID)
      #expect(persisted.subtasks.first { $0.id == subtask.id }?.tmux == reference)

      let processes = try await fixture.run("/bin/ps", ["-axo", "pid=,tty=,command="])
      let tty = URL(fileURLWithPath: reference.tty).lastPathComponent
      let paneProcesses = processes.split(separator: "\n").filter { line in
        line.split(whereSeparator: \.isWhitespace).dropFirst().first == Substring(tty)
      }
      #expect(paneProcesses.contains { $0.contains("codex-wrapper") && $0.contains("--yolo") },
        "The installed Codex alias and usage bar must run inside the tmux pane")
      let statusRows = try await fixture.tmux(["show-options", "-v", "-t", reference.name, "status"])
        .trimmingCharacters(in: .whitespacesAndNewlines)
      #expect(statusRows == "4", "The live usage bar must reserve its four tmux status rows")
      let renderer = try await fixture.tmux([
        "show-environment", "-t", reference.name, "FOCUS_QUEUE_USAGE_BAR_PATH",
      ])
      #expect(renderer.hasPrefix("FOCUS_QUEUE_USAGE_BAR_PATH=") && renderer.hasSuffix("/codex-bar.js"),
        "The task session must retain the installed usage renderer path")
      for line in 1...3 {
        let format = try await fixture.tmux([
          "show-options", "-v", "-t", reference.name, "status-format[\(line)]",
        ])
        #expect(format.contains("$FOCUS_QUEUE_USAGE_BAR_PATH") && format.contains("--line \(line)"),
          "Usage row \(line) must render through the installed Codex bar")
      }
      let persistence = try TmuxPersistence.prepare(executable: fixture.executable,
        serverName: fixture.server, supportDirectory: fixture.support)
      let actualSaveDirectory = try await fixture.tmux(["show-options", "-gqv", "@resurrect-dir"])
      #expect(actualSaveDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        == persistence.stateDirectory.appendingPathComponent("resurrect").path)
      try await persistence.save()
      #expect(persistence.status().lastSavedAt != nil)

      await terminal.detachAll()
      #expect(try await fixture.controller.verify(reference) == reference)
      #expect(try await launcher.identify(subtask: subtask, configuration: model.config.wezTerm) == nativeID)
      let beforeOpenCount = await terminal.opened.count
      model.openSubtask(subtask, for: ticket, showResult: false)
      try await liveEventually("App did not reopen its saved runtime: \(label)", seconds: 20) {
        !model.launchingTaskIDs.contains(fixture.taskID)
      }
      #expect(await terminal.opened.count == beforeOpenCount + 1)
      #expect(await terminal.opened.last == reference)
      #expect(try await fixture.controller.verify(reference) == reference)
      #expect(try await launcher.identify(subtask: subtask, configuration: model.config.wezTerm) == nativeID)
      #expect(try await fixture.controller.inspectAgent(taskID: fixture.taskID,
        subtaskID: subtask.id, executable: fixture.executable) == reference)
      #expect(try await fixture.git(["status", "--porcelain", "--untracked-files=all"], at: workspace.path).isEmpty,
        "The sanity prompt must leave the workspace unchanged")
      print("LIVE_AGENT_SANITY passed \(label), session=\(nativeID), pane=\(reference.paneID), tty=\(reference.tty), alias=codex-wrapper --yolo, response=SANITY_OK, reopen=exact, persistence=isolated")
      await terminal.detachAll()
      try await launcher.closeRuntime(subtask: subtask, configuration: model.config.wezTerm)
      model.openSubtask(subtask, for: ticket, showResult: false)
      try await liveEventually("App did not resume the stopped conversation: \(label)", seconds: 60) {
        !model.launchingTaskIDs.contains(fixture.taskID)
      }
      let resumed = try #require(model.subtasks(for: fixture.taskID).first { $0.id == subtask.id })
      let successor = try #require(resumed.tmux)
      try #require(successor.paneID != reference.paneID,
        "\(model.actionMessages[fixture.taskID] ?? "The stopped runtime was not replaced")")
      try #require(resumed.sessionID == nativeID)
      #expect(resumed.workspace == subtask.workspace, "Resume must reuse the exact agent workspace")
      try await liveEventually("Stopped Codex conversation was not resumed: \(label)", seconds: 90) {
        let identity = try await launcher.identify(subtask: resumed, configuration: model.config.wezTerm)
        let output = try await fixture.tmux(["capture-pane", "-p", "-S", "-200", "-t", successor.paneID])
        return identity == nativeID && output.contains("OpenAI Codex") && output.contains("SANITY_OK")
      }
      #expect(await terminal.opened.last == successor)
      print("LIVE_AGENT_SANITY resumed \(label), session=\(nativeID), oldPane=\(reference.paneID), newPane=\(successor.paneID), conversation=unchanged")
      await terminal.detachAll()
      try await launcher.closeRuntime(subtask: resumed, configuration: model.config.wezTerm)
      #expect(try await fixture.controller.inspect(name: fixture.sibling,
        executable: fixture.executable) == fixture.siblingReference)
      checkedVariants += 1
    }
    if createWorktree {
      // Remove only our known fixture marker, after proving the agent preserved it.
      try #require(try String(contentsOf: localNote, encoding: .utf8) == "Preserve this uncommitted source work.\n")
      try FileManager.default.removeItem(at: localNote)
    }
  }
  #expect(checkedVariants == 4)
  #expect(observedSessions.count == 4)
  print("LIVE_AGENT_SANITY complete: 4 New Agent variants, 4 unique provider UUIDs, 4 exact detach/reopen checks, 4 stopped-conversation resumes, 4 isolated persistence saves, legacy sibling retained")
}

@MainActor
private func liveEventually(_ description: String, seconds: Int,
  condition: @MainActor () async throws -> Bool) async throws {
  let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
  while ContinuousClock.now < deadline {
    if try await condition() { return }
    try await Task.sleep(for: .milliseconds(500))
  }
  throw LiveAgentFailure(description)
}

private struct LiveAgentFailure: Error, LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

private final class LiveAgentFixture: @unchecked Sendable {
  let root: URL
  let executable: String
  let server: String
  let taskID: String
  let sibling = "legacy-sibling"
  let repository: URL
  var primaryRepository: URL?
  var siblingReference: TmuxSessionReference?
  var source: URL { root.appendingPathComponent("source") }
  var support: URL { root.appendingPathComponent("support") }
  var controller: TmuxController { TmuxController(serverName: server) }
  var paths: AppPaths {
    AppPaths(supportDirectory: support, configurationFile: support.appendingPathComponent("config.json"),
      stateFile: support.appendingPathComponent("state.json"), reviewsDirectory: support.appendingPathComponent("reviews"),
      agentRegistrationsDirectory: support.appendingPathComponent("agent-registrations"))
  }

  init() throws {
    let token = UUID().uuidString.lowercased()
    server = "fq-live-\(token)"
    taskID = "SANITY-\(token.prefix(8))"
    executable = try #require(SetupEnvironment.executable("tmux"))
    root = FileManager.default.temporaryDirectory.appendingPathComponent("focus-queue-live-\(token)")
    repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
  }

  func prepare() async throws {
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    // A linked checkout inherits the user's existing repository trust, while all
    // writable files and task support state remain in this test's unique root.
    _ = try await git(["worktree", "add", "--detach", source.path, "HEAD"], at: repository.path)
    let commonDirectory = try await git(
      ["rev-parse", "--path-format=absolute", "--git-common-dir"], at: source.path)
    primaryRepository = URL(fileURLWithPath: commonDirectory).deletingLastPathComponent()
    // Reproduce the real first-launch condition: another session already exists.
    siblingReference = try await controller.start(name: sibling, directory: root.path,
      command: ["/bin/sleep", "600"], executable: executable)
  }

  func tmux(_ arguments: [String]) async throws -> String {
    try await run(executable, ["-f", "/dev/null", "-L", server] + arguments)
  }

  func git(_ arguments: [String], at path: String) async throws -> String {
    try await run("/usr/bin/git", arguments, directory: path)
  }

  func run(_ executable: String, _ arguments: [String], directory: String? = nil) async throws -> String {
    let result = try await FoundationProcessRunner().run(.init(executable: executable,
      arguments: arguments, workingDirectory: directory, environment: ["TMUX_TMPDIR": "/tmp"], timeoutSeconds: 15))
    guard result.succeeded else { throw LiveAgentFailure("\(arguments.first ?? executable): \(result.standardError)") }
    return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func cleanup() {
    guard server.hasPrefix("fq-live-"), server != TmuxController.serverName else { return }
    func command(_ executable: String, _ arguments: [String]) -> Bool {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: executable)
      process.arguments = arguments
      process.environment = ProcessInfo.processInfo.environment.merging(["TMUX_TMPDIR": "/tmp"]) { _, new in new }
      process.currentDirectoryURL = repository
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      do { try process.run() } catch { return false }
      for _ in 0..<200 where process.isRunning { usleep(25_000) }
      if process.isRunning { process.terminate(); return false }
      return process.terminationStatus == 0
    }
    _ = command(executable, ["-f", "/dev/null", "-L", server, "kill-server"])
    // Managed isolation resolves linked worktrees back to the primary checkout.
    // Teardown must use that same root or its clean agent worktrees are left
    // registered beside the repository after a successful live sanity run.
    let managedRoot = TaskWorktreeManager.managedRoot(
      repositoryPath: primaryRepository?.path ?? repository.path)
    let taskRoot = managedRoot.appendingPathComponent(taskID.lowercased())
    let agentsRoot = taskRoot.appendingPathComponent("agents")
    let agentWorktrees = (try? FileManager.default.contentsOfDirectory(at: agentsRoot, includingPropertiesForKeys: nil)) ?? []
    var retained = false
    for worktree in agentWorktrees + [source] where FileManager.default.fileExists(atPath: worktree.path) {
      if !command("/usr/bin/git", ["worktree", "remove", worktree.path]) { retained = true }
    }
    for worktree in agentWorktrees {
      let branch = "focus-queue/\(taskID.lowercased())-\(worktree.lastPathComponent.lowercased())"
      _ = command("/usr/bin/git", ["branch", "-d", branch])
    }
    if agentWorktrees.allSatisfy({ !FileManager.default.fileExists(atPath: $0.path) }) {
      try? FileManager.default.removeItem(at: taskRoot)
    }
    if retained { Issue.record("Sanity cleanup retained changed fixture work at \(root.path)") }
    else { try? FileManager.default.removeItem(at: root) }
  }
}

private actor LiveHeadlessTerminal: WezTermControlling {
  let fixture: LiveAgentFixture
  private(set) var opened: [TmuxSessionReference] = []
  private var clients: [Process] = []
  init(fixture: LiveAgentFixture) { self.fixture = fixture }

  func openManagedRuntime(_ reference: TmuxSessionReference, taskID: String,
    provider: AgentProvider, configuration: WezTermConfiguration) async throws -> TerminalActionResult {
    #expect(reference.name == (try TmuxController.taskSessionName(taskID: fixture.taskID)))
    let context = try await TaskContextStore(root: fixture.support).load(ticketID: taskID)
    try #require(context?.subtasks.contains { $0.tmux == reference } == true,
      "Runtime must be persisted before a terminal view opens")
    _ = try await fixture.controller.verify(reference)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: fixture.executable)
    process.arguments = ["-f", "/dev/null", "-L", fixture.server, "-C", "attach-session", "-t", "=\(reference.name)"]
    process.environment = ["PATH": "/usr/bin:/bin:/opt/homebrew/bin", "TMUX_TMPDIR": "/tmp", "TERM": "xterm-256color"]
    process.standardInput = Pipe()
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    clients.append(process)
    for _ in 0..<40 {
      let current = try await fixture.tmux(["list-clients", "-t", "=\(reference.name)", "-F", "#{client_pid}"])
      if current.split(separator: "\n").contains(Substring(String(process.processIdentifier))) {
        opened.append(reference)
        return .focused(paneID: Int(reference.paneID.dropFirst())!)
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw LiveAgentFailure("Headless tmux client did not attach")
  }

  func detachAll() async {
    for process in clients {
      if process.isRunning { process.terminate() }
      for _ in 0..<100 where process.isRunning { try? await Task.sleep(for: .milliseconds(20)) }
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
    clients = []
  }

  func listAttachablePanes(configuration: WezTermConfiguration) async throws -> [WezTermPane] { [] }
  func listRunningAgents(configuration: WezTermConfiguration) async throws -> [RunningAgentSession] { [] }
  func attach(paneID: Int, tabTitle: String, windowTitle: String,
    configuration: WezTermConfiguration) async throws { throw LiveAgentFailure("Unexpected graphical action") }
  func focusOrSpawn(directory: String, taskID: String,
    configuration: WezTermConfiguration) async throws -> TerminalActionResult { throw LiveAgentFailure("Unexpected graphical action") }
  func focusOrResume(session: TaskAgentSession, taskID: String,
    configuration: WezTermConfiguration) async throws -> TerminalActionResult { throw LiveAgentFailure("Unexpected graphical action") }
}
