import Foundation
import Testing
@testable import FocusQueueCore

@Suite("Queue objective router")
struct QueueObjectiveRouterTests {
  @Test("Router command keeps the objective literal and clears inherited assignment identity")
  func literalCommand() throws {
    let repository = "/tmp/repository with spaces"
    let support = URL(fileURLWithPath: "/tmp/support with spaces")
    let hostile = "Fix $(touch /tmp/wrong) `echo wrong` $HOME ; 'quotes'\nsecond line"

    let command = QueueObjectiveRouter.command(
      objective: hostile, repositoryPath: repository,
      supportDirectory: support, shellPath: "/bin/zsh")

    #expect(command.filter { $0 == hostile }.count == 1)
    #expect(command.last == hostile)
    #expect(command.contains("FOCUS_QUEUE_ROUTER=1"))
    #expect(command.contains("FOCUS_QUEUE_ROUTER_SOURCE=queue-composer"))
    #expect(command.contains { $0.hasPrefix("FOCUS_QUEUE_ROUTER_CAPABILITY=") })
    #expect(command.contains("FOCUS_QUEUE_SUPPORT_DIR=\(support.path)"))
    for identity in ["FOCUS_QUEUE_TASK_ID", "FOCUS_QUEUE_SUBTASK_ID", "FOCUS_QUEUE_RUNTIME_MODE"] {
      #expect(command.indices.contains { index in
        command[index] == "-u" && command.index(after: index) < command.endIndex
          && command[command.index(after: index)] == identity
      })
    }
    #expect(command.contains(repository))
  }

  @Test("One composer submission starts exactly one router tmux session in the selected repository")
  func singleLaunch() async throws {
    let repository = FileManager.default.temporaryDirectory.appendingPathComponent(
      "queue-router-repository-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: repository) }
    let runner = QueueRouterRunner()
    let router = QueueObjectiveRouter(runner: runner, tmuxServerName: "queue-router-test")

    _ = try await router.launch(
      objective: "Route this objective", repositoryPath: repository.path,
      supportDirectory: repository.appendingPathComponent("support"),
      tmuxExecutable: "/mock/tmux", shellPath: "/bin/zsh")

    let starts = await runner.calls.filter { $0.arguments.contains("new-session") }
    #expect(starts.count == 1)
    #expect(starts[0].arguments.contains(repository.path))
  }

  @Test("A registered successor resolves the exact composer route")
  func registeredOutcome() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "queue-router-outcome-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let routeID = UUID().uuidString.lowercased()
    let subtaskID = UUID().uuidString.lowercased()
    let startedAt = Date()
    let tmux = TmuxSessionReference(
      name: "fq-router-outcome", serverPID: 1, createdAt: 1,
      paneID: "%1", panePID: 2, tty: "/dev/ttys001", executable: "/mock/tmux")
    let routeStore = AgentRouteStore(root: root)
    try routeStore.save(.init(
      routeID: routeID, prompt: "Route exact work", provider: .codex,
      source: .init(cwd: "/repo", tmuxName: tmux.name), origin: .queueComposer,
      inferredProjectID: "focus", repositoryPath: "/repo", createdAt: startedAt))
    try routeStore.claim(routeID: routeID, subtaskID: subtaskID)
    try routeStore.setDestination(routeID: routeID, taskID: "FOC-123")
    let receipts = AgentStartupReceiptStore(root: root)
    let workspace = AgentWorkspace(path: "/repo/worktree", repositoryPath: "/repo")
    let context = AgentStartupContextPaths(
      taskPlan: "/support/tasks/FOC-123/plan.md",
      taskContext: "/support/tasks/FOC-123/context.json",
      taskLog: "/support/tasks/FOC-123/agent-log.md")
    try receipts.save(.init(
      routeID: routeID, status: .launched, taskID: "FOC-123",
      subtaskID: subtaskID, title: "Exact work", description: "Do the work",
      provider: .codex, promptByteCount: 16,
      promptSHA256: AgentStartupReceipt.promptDigest("Route exact work"),
      workspace: workspace, runtime: .init(
        tmux: tmux, tmuxServerName: TmuxController.serverName,
        terminalApplication: "WezTerm", terminalSocketPath: nil,
        attachCommand: ["tmux", "attach"]), context: context,
      source: .init(cwd: "/repo", tmuxName: tmux.name)))
    try receipts.register(
      taskID: "FOC-123", subtaskID: subtaskID,
      providerSessionID: "11111111-2222-4333-8444-555555555555")
    let router = QueueObjectiveRouter()
    let pending = try await router.currentOutcome(
      .init(tmux: tmux, startedAt: startedAt), supportDirectory: root)
    #expect(pending == .waiting(
      routeID: routeID,
      recoveryPath: try receipts.url(taskID: "FOC-123", subtaskID: subtaskID).path))
    try receipts.markOrchestrationPrepared(taskID: "FOC-123", subtaskID: subtaskID)
    try receipts.completeHandoff(
      taskID: "FOC-123", subtaskID: subtaskID,
      expectedSessionID: "11111111-2222-4333-8444-555555555555")
    let outcome = try await router.currentOutcome(
      .init(tmux: tmux, startedAt: startedAt), supportDirectory: root)

    #expect(outcome == .registered(
      routeID: routeID, taskID: "FOC-123", subtaskID: subtaskID))
  }

  @Test("An unconfirmed tmux start persists its identity and never authorizes a retry")
  func unconfirmedStartPersistsRecovery() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "queue-router-unconfirmed-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let router = QueueObjectiveRouter(
      runner: UnconfirmedQueueRouterRunner(), tmuxServerName: "router-unconfirmed-test",
      confirmationAttempts: 1, confirmationDelayMilliseconds: 0)

    do {
      _ = try await router.launch(
        objective: "Keep one uncertain router", repositoryPath: root.path,
        supportDirectory: root.appendingPathComponent("support"),
        tmuxExecutable: "/mock/tmux", shellPath: "/bin/zsh")
      Issue.record("Expected an unconfirmed launch")
    } catch let error as QueueRouterLaunchUnconfirmedError {
      let loaded = try QueueRouterRuntimeStore(
        root: root.appendingPathComponent("support")).load()
      let stored = try #require(loaded)
      #expect(stored.tmuxName == error.runtime.tmuxName)
      #expect(stored.confirmedReference == nil)
    }
  }

  @Test("Router recovery survives a store round trip")
  func persistedRecoveryRoundTrip() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "queue-router-store-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = try QueueRouterRuntime(
      tmuxName: "fq-router-persisted", tmuxExecutable: "/mock/tmux",
      startedAt: Date(timeIntervalSince1970: 1_700_000_000),
      objectiveSHA256: AgentStartupReceipt.promptDigest("Persisted objective"))
    let store = QueueRouterRuntimeStore(root: root)

    try store.save(runtime)
    #expect(try store.load() == runtime)
    try store.clear(matching: runtime.tmuxName)
    #expect(try store.load() == nil)
  }

  @Test("An authorized composer routes the original objective when its agent paraphrases it")
  func authorizedComposerUsesOriginalObjective() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "queue-router-authoritative-prompt-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let original = """
      We need to refine the task description beneath ECC-035.
      Keep the complete rendered-data workflow context.
      """
    let paraphrase = "Refine the ECC-035 task description and rendered-data workflow."
    let runtime = try QueueRouterRuntime(
      tmuxName: "fq-router-authoritative", tmuxExecutable: "/mock/tmux",
      startedAt: Date(), objectiveSHA256: AgentStartupReceipt.promptDigest(original))
    let store = QueueRouterRuntimeStore(root: root)
    try store.save(runtime)
    var stored = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [String: Any])
    stored["objective"] = original
    try JSONSerialization.data(withJSONObject: stored, options: [.prettyPrinted, .sortedKeys])
      .write(to: store.url, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: store.url.path)
    var configuration = SetupEnvironment.starter(supportDirectory: root)
    configuration.projects = []

    let inspection = try await AgentRouteCoordinator(root: root).inspect(
      .init(
        prompt: paraphrase, provider: .codex,
        source: .init(cwd: root.path, tmuxName: runtime.tmuxName),
        origin: .queueComposer, composerCapability: runtime.capability),
      configuration: configuration)

    let intent = try #require(try AgentRouteStore(root: root).load(routeID: inspection.routeID))
    #expect(intent.prompt == original)
    #expect(intent.prompt != paraphrase)
  }

  @Test("An unconfirmed caller cannot recreate a missing active-router record")
  func missingUnconfirmedRecoveryIsRejected() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "queue-router-missing-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = try QueueRouterRuntime(
      tmuxName: "fq-router-missing", tmuxExecutable: "/mock/tmux", startedAt: Date(),
      objectiveSHA256: AgentStartupReceipt.promptDigest("Missing router"))

    await #expect(throws: TmuxError.self) {
      try await QueueObjectiveRouter(runner: QueueRouterRunner()).recoveryReference(
        runtime, supportDirectory: root)
    }
    #expect(try QueueRouterRuntimeStore(root: root).load() == nil)
  }

  @Test("A confirmed router identity is monotonic in its active record")
  func confirmedRuntimeCannotBeReplaced() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "queue-router-monotonic-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = TmuxSessionReference(
      name: "fq-router-monotonic", serverPID: 101, createdAt: 1,
      paneID: "%1", panePID: 201, tty: "/dev/ttys001", executable: "/mock/tmux")
    let second = TmuxSessionReference(
      name: first.name, serverPID: 102, createdAt: 2,
      paneID: "%2", panePID: 202, tty: "/dev/ttys002", executable: first.executable)
    let capability = UUID().uuidString.lowercased()
    let digest = AgentStartupReceipt.promptDigest("Monotonic router")
    let store = QueueRouterRuntimeStore(root: root)
    try store.save(.init(
      tmux: first, startedAt: Date(), capability: capability, objectiveSHA256: digest))

    #expect(throws: TaskContextError.self) {
      try store.save(.init(
        tmux: second, startedAt: Date(), capability: capability,
        objectiveSHA256: digest))
    }
    #expect(try store.load()?.confirmedReference == first)
  }

  @Test("An active router reservation prevents a second launcher from starting tmux")
  func activeReservationPreventsSecondLaunch() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "queue-router-reservation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let support = root.appendingPathComponent("support")
    let active = try QueueRouterRuntime(
      tmuxName: "fq-router-active", tmuxExecutable: "/mock/tmux", startedAt: Date(),
      objectiveSHA256: AgentStartupReceipt.promptDigest("First objective"))
    try QueueRouterRuntimeStore(root: support).save(active)
    let runner = QueueRouterRunner()
    let router = QueueObjectiveRouter(runner: runner)

    do {
      _ = try await router.launch(
        objective: "Second objective", repositoryPath: root.path,
        supportDirectory: support, tmuxExecutable: "/mock/tmux")
      Issue.record("Expected the existing active router to block launch")
    } catch let error as QueueRouterLaunchUnconfirmedError {
      #expect(error.runtime.tmuxName == active.tmuxName)
      #expect(error.runtime.capability == active.capability)
    }
    #expect(await runner.calls.isEmpty)
    let retained = try QueueRouterRuntimeStore(root: support).load()
    #expect(retained?.tmuxName == active.tmuxName)
    #expect(retained?.capability == active.capability)
  }

  @Test("Confirmed recovery rejects a replacement with the same tmux name")
  func confirmedRecoveryRejectsReplacement() async throws {
    let reference = TmuxSessionReference(
      name: "fq-router-exact", serverPID: Int(ProcessInfo.processInfo.processIdentifier),
      createdAt: 1, paneID: "%7", panePID: 456,
      tty: "/dev/ttys007", executable: "/mock/tmux")
    let runtime = QueueRouterRuntime(
      tmux: reference, startedAt: Date(),
      objectiveSHA256: AgentStartupReceipt.promptDigest("Exact recovery"))

    await #expect(throws: TmuxError.self) {
      try await QueueObjectiveRouter(runner: QueueRouterRunner()).recoveryReference(
        runtime, supportDirectory: FileManager.default.temporaryDirectory)
    }
  }

  @Test("An unconfirmed recovery promotes exact identity before later reopen attempts")
  func unconfirmedRecoveryPromotesExactIdentity() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "queue-router-promotion-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = try QueueRouterRuntime(
      tmuxName: "fq-router-promoted", tmuxExecutable: "/mock/tmux", startedAt: Date(),
      objectiveSHA256: AgentStartupReceipt.promptDigest("Promote exact identity"))
    try QueueRouterRuntimeStore(root: root).save(runtime)
    let router = QueueObjectiveRouter(runner: PromotedRouterRunner())

    let promoted = try await router.recoveryReference(runtime, supportDirectory: root)
    #expect(promoted.serverPID == Int(ProcessInfo.processInfo.processIdentifier))
    let saved = try QueueRouterRuntimeStore(root: root).load()
    #expect(saved?.confirmedReference == promoted)
    await #expect(throws: TmuxError.self) {
      try await router.recoveryReference(runtime, supportDirectory: root)
    }
  }

  @Test("A stopped router retires only its unstarted inspected route")
  func stoppedRouterRetiresUnstartedRoute() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "queue-router-retire-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let startedAt = Date()
    let reference = TmuxSessionReference(
      name: "fq-router-retired", serverPID: Int(ProcessInfo.processInfo.processIdentifier),
      createdAt: 1, paneID: "%8", panePID: 457,
      tty: "/dev/ttys008", executable: "/mock/tmux")
    let runtime = QueueRouterRuntime(
      tmux: reference, startedAt: startedAt,
      objectiveSHA256: AgentStartupReceipt.promptDigest("Retire this route"))
    try QueueRouterRuntimeStore(root: root).save(runtime)
    let routeID = UUID().uuidString.lowercased()
    try AgentRouteStore(root: root).save(.init(
      routeID: routeID, prompt: "Retire this route", provider: .codex,
      source: .init(cwd: "/repo", tmuxName: reference.name),
      origin: .queueComposer, composerCapability: runtime.capability,
      inferredProjectID: "focus", repositoryPath: "/repo", createdAt: startedAt))

    await #expect(throws: TmuxError.self) {
      try await QueueObjectiveRouter(runner: StoppedRouterRunner()).recoveryReference(
        runtime, supportDirectory: root)
    }
    #expect(try AgentRouteStore(root: root).load(routeID: routeID) == nil)
    #expect(try QueueRouterRuntimeStore(root: root).load() == nil)
  }

  @Test("A stopped router retains a released route with durable assignment state")
  func stoppedRouterRetainsSideEffectfulRoute() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "queue-router-retain-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let startedAt = Date()
    let reference = TmuxSessionReference(
      name: "fq-router-retained", serverPID: Int(ProcessInfo.processInfo.processIdentifier),
      createdAt: 1, paneID: "%9", panePID: 458,
      tty: "/dev/ttys009", executable: "/mock/tmux")
    let runtime = QueueRouterRuntime(
      tmux: reference, startedAt: startedAt,
      objectiveSHA256: AgentStartupReceipt.promptDigest("Retain this route"))
    try QueueRouterRuntimeStore(root: root).save(runtime)
    let routeID = UUID().uuidString.lowercased()
    let subtaskID = UUID().uuidString.lowercased()
    let routes = AgentRouteStore(root: root)
    try routes.save(.init(
      routeID: routeID, prompt: "Retain this route", provider: .codex,
      source: .init(cwd: "/repo", tmuxName: reference.name),
      origin: .queueComposer, composerCapability: runtime.capability,
      inferredProjectID: "focus", repositoryPath: "/repo", createdAt: startedAt))
    try routes.claim(routeID: routeID, subtaskID: subtaskID)
    try routes.setDestination(routeID: routeID, taskID: "FOC-123")
    try routes.releaseClaim(routeID: routeID, subtaskID: subtaskID)

    await #expect(throws: TmuxError.self) {
      try await QueueObjectiveRouter(runner: StoppedRouterRunner()).recoveryReference(
        runtime, supportDirectory: root)
    }
    let loaded = try routes.load(routeID: routeID)
    let retained = try #require(loaded)
    #expect(retained.taskID == "FOC-123")
    #expect(retained.subtaskID == subtaskID)
    #expect(try QueueRouterRuntimeStore(root: root).load() != nil)
  }

  @Test("A real detached tmux router completes authorized route inspection without opening a UI")
  func detachedRouterSanity() async throws {
    guard let tmuxExecutable = SetupEnvironment.executable("tmux") else { return }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "queue-router-live-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let support = root.appendingPathComponent("support", isDirectory: true)
    let git = try await FoundationProcessRunner().run(.init(
      executable: "/usr/bin/git", arguments: ["init", "--quiet"], workingDirectory: root.path))
    #expect(git.succeeded, "Git fixture initialization failed: \(git.standardError)")
    let project = ProjectConfiguration(
      id: "focus", name: "Focus Queue", taskPrefix: "FOC", repositoryPath: root.path)
    try JSONEncoder().encode(DashboardDocument(tickets: [
      DashboardTicket(
        id: "FOC-001", title: "Existing route target", status: "open",
        summary: "A candidate for the live inspection sanity check")
    ])).write(to: URL(fileURLWithPath: project.dashboardPath), options: .atomic)
    var configuration = SetupEnvironment.starter(supportDirectory: support)
    configuration.projects = [project]
    configuration.selectedProjectID = project.id
    configuration.automaticAgentRouting = false
    try await JSONConfigurationRepository(url: support.appendingPathComponent("config.json"))
      .save(configuration)
    let shellDirectory = root.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: shellDirectory, withIntermediateDirectories: true)
    let environmentCapture = root.appendingPathComponent("environment.txt")
    let argumentCapture = root.appendingPathComponent("arguments.txt")
    let inspectionCapture = root.appendingPathComponent("inspection.json")
    let sessionExecutable = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent(".build/debug/focus-queue-session")
    #expect(FileManager.default.isExecutableFile(atPath: sessionExecutable.path))
    let shell = shellDirectory.appendingPathComponent("zsh")
    let script = """
    #!/bin/zsh
    /usr/bin/printenv > "\(environmentCapture.path)"
    /usr/bin/printf '%s\\n' "$@" > "\(argumentCapture.path)"
    "\(sessionExecutable.path)" route inspect --prompt "${@: -1}" --cwd "$PWD" --provider codex > "\(inspectionCapture.path)"
    /bin/sleep 5
    """
    try Data(script.utf8).write(to: shell, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: shell.path)
    let server = "router-sanity-\(UUID().uuidString.lowercased())"
    let router = QueueObjectiveRouter(runner: FoundationProcessRunner(), tmuxServerName: server)
    let objective = "Sanity objective with spaces and $literal"
    let runtime = try await router.launch(
      objective: objective, repositoryPath: root.path,
      supportDirectory: support,
      tmuxExecutable: tmuxExecutable, shellPath: shell.path)

    for _ in 0..<40 where ![environmentCapture, argumentCapture, inspectionCapture]
      .allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) {
      try await Task.sleep(for: .milliseconds(50))
    }

    let environment = try String(contentsOf: environmentCapture, encoding: .utf8)
    let arguments = try String(contentsOf: argumentCapture, encoding: .utf8)
    #expect(environment.contains("FOCUS_QUEUE_ROUTER=1"))
    #expect(environment.contains("FOCUS_QUEUE_ROUTER_SOURCE=queue-composer"))
    #expect(environment.contains("FOCUS_QUEUE_ROUTER_CAPABILITY=\(runtime.capability)"))
    #expect(!environment.contains("FOCUS_QUEUE_TASK_ID="))
    #expect(arguments.contains(root.path))
    #expect(arguments.contains(objective))
    let inspection = try JSONDecoder().decode(
      AgentRouteInspection.self, from: Data(contentsOf: inspectionCapture))
    #expect(inspection.status == .ready)
    #expect(inspection.automaticRoutingEnabled == false)
    #expect(inspection.inferredProjectID == project.id)
    #expect(inspection.candidates.map(\.taskID) == ["FOC-001"])
    let loadedRuntime = try QueueRouterRuntimeStore(root: support).load()
    let savedRuntime = try #require(loadedRuntime)
    #expect(savedRuntime.claimedRouteID == inspection.routeID)
    let outcome = try await router.currentOutcome(runtime, supportDirectory: support)
    let recoveryPath = try AgentRouteStore(root: support)
      .intentURL(routeID: inspection.routeID).path
    #expect(outcome == .waiting(routeID: inspection.routeID, recoveryPath: recoveryPath))
    try await TmuxController(serverName: server).stop(try #require(runtime.confirmedReference))
  }
}

private actor QueueRouterRunner: ProcessRunning {
  private(set) var calls: [ProcessSpecification] = []
  private var sessionName: String?

  func run(_ specification: ProcessSpecification) -> ProcessResult {
    calls.append(specification)
    if let sessionIndex = specification.arguments.firstIndex(of: "-s"),
       specification.arguments.index(after: sessionIndex) < specification.arguments.endIndex {
      sessionName = specification.arguments[specification.arguments.index(after: sessionIndex)]
    }
    let name = sessionName ?? "fq-router-fixture"
    return .init(
      exitCode: 0,
      standardOutput: "\(name)|123|1000|%7|456|/dev/ttys007|0\n",
      standardError: "",
      timedOut: false)
  }
}

private actor UnconfirmedQueueRouterRunner: ProcessRunning {
  func run(_ specification: ProcessSpecification) -> ProcessResult {
    if specification.arguments.contains("new-session") {
      return .init(exitCode: 0, standardOutput: "", standardError: "", timedOut: false)
    }
    return .init(
      exitCode: 1, standardOutput: "", standardError: "temporary tmux transport failure",
      timedOut: true)
  }
}

private actor PromotedRouterRunner: ProcessRunning {
  private var callCount = 0

  func run(_ specification: ProcessSpecification) -> ProcessResult {
    callCount += 1
    let originalPID = Int(ProcessInfo.processInfo.processIdentifier)
    let serverPID = callCount == 1 ? originalPID : originalPID + 1
    return .init(
      exitCode: 0,
      standardOutput: "fq-router-promoted|\(serverPID)|1000|%7|456|/dev/ttys007|0\n",
      standardError: "", timedOut: false)
  }
}

private actor StoppedRouterRunner: ProcessRunning {
  func run(_ specification: ProcessSpecification) -> ProcessResult {
    .init(
      exitCode: 1, standardOutput: "", standardError: "no sessions",
      timedOut: false)
  }
}
