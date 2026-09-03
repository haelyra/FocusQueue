import CoreGraphics
import Foundation
import Testing

@testable import FocusQueueCore

@Test("Dashboard decoding keeps source-backed progress and open state")
func dashboardDecoding() throws {
  let json = """
    {
      "updatedAt": "2026-08-29",
      "tickets": [
        {
          "id": "ECC-035",
          "title": "Ship Focus Queue",
          "priority": "critical",
          "status": "in-progress",
          "summary": "Build the panel",
          "resolutionPrs": [99],
          "prs": [{"number": 99, "title": "Queue", "url": "https://example.test/99", "state": "OPEN"}],
          "steps": [
            {"id": "plan", "label": "Approve", "status": "done", "evidence": ["/tmp/plan.md"]},
            {"id": "build", "label": "Build", "status": "in-progress", "evidence": []}
          ]
        }
      ]
    }
    """

  let dashboard = try JSONDecoder().decode(DashboardDocument.self, from: Data(json.utf8))
  let ticket = try #require(dashboard.tickets.first)

  #expect(ticket.isOpen)
  #expect(ticket.priorityRank == 0)
  #expect(ticket.progressLabel == "1/2")
  #expect(ticket.prs.first?.isMerged == false)
}

@Test("PR progress is used only when no explicit step ledger exists")
func pullRequestProgress() {
  let ticket = DashboardTicket(
    id: "ECC-100",
    title: "Merge work",
    status: "in-progress",
    summary: "",
    resolutionPrs: [1, 2],
    prs: [
      DashboardPR(number: 1, title: "One", url: "https://example.test/1", state: "MERGED"),
      DashboardPR(number: 2, title: "Two", url: "https://example.test/2", state: "OPEN"),
    ]
  )

  #expect(ticket.progressLabel == "1/2 PRs")
}

@Test("Weekly PR resolution tasks are typed and linked to their repository")
func recurringPullRequestTaskTyping() {
  let inferred = DashboardTicket(
    id: "ECC-043",
    title: "Run weekly ECC pull-request resolution goal",
    status: "in-progress",
    summary: "",
    links: [
      DashboardLink(
        label: "ECC pull requests",
        url: "https://github.com/affaan-m/ECC/pulls",
        type: "github"
      )
    ]
  )
  let explicit = DashboardTicket(
    id: "ECC-100",
    title: "Maintainer rotation",
    status: "in-progress",
    summary: "",
    taskType: "recurring",
    recurrence: DashboardRecurrence(
      kind: "pull-request-resolution",
      cadence: "daily",
      repository: "example/project"
    )
  )

  #expect(inferred.isRecurringPullRequestTask)
  #expect(inferred.pullRequestRepository == "affaan-m/ECC")
  #expect(explicit.isRecurringPullRequestTask)
  #expect(explicit.pullRequestRepository == "example/project")
}

@Test("Recurring PR targets adapt to backlog without inventing work")
func recurringPullRequestTargetPolicy() throws {
  #expect(PullRequestTargetPolicy.dailyTarget(openCount: 0) == 0)
  #expect(PullRequestTargetPolicy.dailyTarget(openCount: 3) == 3)
  #expect(PullRequestTargetPolicy.dailyTarget(openCount: 20) == 5)
  #expect(PullRequestTargetPolicy.dailyTarget(openCount: 40) == 10)
  #expect(PullRequestTargetPolicy.dailyTarget(openCount: 81) == 15)
  #expect(PullRequestTargetPolicy.weeklyTarget(openCount: 81, resolvedThisWeek: 5) == 75)

  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
  let now = try Date("2026-08-31T23:00:00Z", strategy: .iso8601)
  let progress = RecurringPullRequestProgress(
    snapshot: PullRequestQueueSnapshot(
      repository: "affaan-m/ECC",
      openCount: 81,
      resolvedThisWeek: [
        PullRequestResolution(
          number: 1, title: "Merged today", url: "https://example.test/1",
          state: "MERGED", mergedAt: "2026-08-31T20:00:00Z",
          closedAt: "2026-08-31T20:00:00Z"),
        PullRequestResolution(
          number: 2, title: "Closed today", url: "https://example.test/2",
          state: "CLOSED", closedAt: "2026-08-31T18:00:00Z"),
        PullRequestResolution(
          number: 3, title: "Earlier", url: "https://example.test/3",
          state: "MERGED", mergedAt: "2026-08-30T18:00:00Z"),
      ]
    ),
    now: now,
    calendar: calendar
  )

  #expect(progress.dailyTarget == 15)
  #expect(progress.weeklyTarget == 75)
  #expect(progress.resolvedToday.map(\.number) == [1, 2])
  #expect(progress.resolvedThisWeek.count == 3)
}

@Test("Completed tickets prefer a canonical completion timestamp")
func completedTicketTimestamp() {
  let canonical = DashboardTicket(
    id: "ECC-101",
    title: "Canonical completion",
    status: "resolved",
    summary: "",
    updatedAt: "2026-08-29",
    completedAt: "2026-08-30T14:00:00Z"
  )
  let legacy = DashboardTicket(
    id: "ECC-102",
    title: "Legacy completion",
    status: "cancelled",
    summary: "",
    updatedAt: "2026-08-28"
  )

  #expect(canonical.isCompleted)
  #expect(canonical.completionTimestamp == "2026-08-30T14:00:00Z")
  #expect(canonical.completionDay == "2026-08-30")
  #expect(legacy.completionDay == "2026-08-28")
}

@Test("Local queue overrides demote tasks without changing canonical fields")
func localQueueOverrides() {
  let tickets = [
    DashboardTicket(
      id: "ECC-001", title: "Newest critical", priority: "critical",
      status: "in-progress", summary: "", updatedAt: "2026-08-30"),
    DashboardTicket(
      id: "ECC-002", title: "High", priority: "high",
      status: "backlog", summary: "", updatedAt: "2026-08-29"),
    DashboardTicket(
      id: "ECC-003", title: "Low", priority: "low",
      status: "backlog", summary: "", updatedAt: "2026-08-28"),
    DashboardTicket(
      id: "ECC-004", title: "Closed", priority: "critical",
      status: "resolved", summary: "", updatedAt: "2026-08-30"),
  ]

  let canonical = DashboardOrdering.openTickets(in: tickets)
  let overridden = DashboardOrdering.openTickets(
    in: tickets,
    deferredTicketIDs: ["ECC-003", "ECC-001"]
  )

  #expect(canonical.map(\.id) == ["ECC-001", "ECC-002", "ECC-003"])
  #expect(overridden.map(\.id) == ["ECC-002", "ECC-003", "ECC-001"])
  #expect(overridden.last?.priority == "critical")
}

@Test("Local state survives a new repository instance")
func localStatePersistence() async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("focus-queue-test-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let url = root.appendingPathComponent("state.json")
  let request = CompletionRequest(
    ticketID: "ECC-035",
    requestFilePath: root.appendingPathComponent("request.json").path
  )
  let agentSession = TaskAgentSession(
    id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
    ticketID: "ECC-035",
    provider: .codex,
    sessionID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
    tabTitle: "ECC focus queue",
    workingDirectory: "/Users/hira/Documents/Github/ECCFocusQueue",
    windowID: 11,
    tabID: 20,
    paneID: 33
  )
  let expected = LocalState(
    routineDate: "2026-08-29",
    completedRoutineIDs: ["review-prs"],
    completionRequests: [request],
    window: WindowSnapshot(
      x: 10,
      y: 20,
      width: 420,
      height: 680,
      placement: .upperRight,
      displayIdentifier: "display-123"
    ),
    appearance: .dark,
    accentStyle: .pastel,
    agentSessions: [agentSession]
  )

  let writer = JSONLocalStateStore(url: url)
  try await writer.save(expected)
  let reader = JSONLocalStateStore(url: url)

  #expect(try await reader.load() == expected)
}

@Test("Existing local state without an appearance remains compatible")
func legacyLocalStateDecoding() throws {
  let data = Data(
    """
    {
      "routineDate": "2026-08-29",
      "completedRoutineIDs": [],
      "completionRequests": []
    }
    """.utf8
  )

  let state = try JSONDecoder().decode(LocalState.self, from: data)
  #expect(state.appearance == nil)
  #expect(state.accentStyle == nil)
  #expect(state.deferredTicketIDs.isEmpty)
  #expect(state.agentSessions.isEmpty)
}

@Test("Existing window snapshots without a display identifier remain compatible")
func legacyWindowSnapshotDecoding() throws {
  let data = Data(
    """
    {"x":10,"y":20,"width":420,"height":680,"placement":"upper-right"}
    """.utf8
  )

  let snapshot = try JSONDecoder().decode(WindowSnapshot.self, from: data)
  #expect(snapshot.displayIdentifier == nil)
}

@Test("VS Code file links resolve to local files")
func vscodeFileLinkResolution() throws {
  let rawValue = "vscode://file/Users/hira/Documents/ECC/release%20approval.pdf"
  let url = try #require(ResourceLocator.url(for: rawValue))

  #expect(url.isFileURL)
  #expect(url.path == "/Users/hira/Documents/ECC/release approval.pdf")
}

@Test("Markdown renderer creates a styled browser page with relative resource support")
func markdownHTMLRendering() {
  let sourceURL = URL(fileURLWithPath: "/Users/test/Project & Notes/README.md")
  let markdown = """
    # Release notes

    - **Ready**

    | Item | State |
    | --- | --- |
    | App | Done |
    """

  let html = MarkdownHTMLRenderer.page(markdown: markdown, sourceURL: sourceURL)

  #expect(html.contains("<title>README.md</title>"))
  #expect(html.contains("<base href=\"file:///Users/test/Project%20&amp;%20Notes/\">"))
  #expect(html.contains("<h1>Release notes</h1>"))
  #expect(html.contains("<strong>Ready</strong>"))
  #expect(html.contains("<table>"))
  #expect(html.contains("color-scheme: light dark"))
}

@Test("WezTerm matching prefers an exact task directory")
func wezTermPaneMatching() {
  let panes = [
    WezTermPane(windowID: 1, paneID: 7, cwd: "file:///Users/hira/project", isActive: false),
    WezTermPane(windowID: 2, paneID: 9, cwd: "file:///Users/hira/project/Sources", isActive: true),
    WezTermPane(windowID: 3, paneID: 11, cwd: "file:///Users/hira/other", isActive: true),
  ]

  let result = WezTermController.bestMatchingPane(in: panes, directory: "/Users/hira/project")
  #expect(result?.paneID == 7)
}

@Test("WezTerm matching uses the task label to disambiguate windows")
func wezTermTaskLabelMatching() {
  let panes = [
    WezTermPane(
      windowID: 1, paneID: 7, cwd: "file:///Users/hira/project", isActive: true,
      tabTitle: "Other work"),
    WezTermPane(
      windowID: 2, paneID: 9, cwd: "file:///Users/hira/project/Sources", isActive: false,
      tabTitle: "ECC-035"),
  ]

  let result = WezTermController.bestMatchingPane(
    in: panes,
    directory: "/Users/hira/project",
    taskID: "ECC-035"
  )
  #expect(result?.paneID == 9)
}

@Test("A manually attached task label overrides directory matching")
func wezTermAttachedPaneMatching() {
  let panes = [
    WezTermPane(
      windowID: 1, tabID: 1, paneID: 7, cwd: "file:///Users/hira/unrelated",
      tabTitle: "ECC-035"),
    WezTermPane(
      windowID: 2, tabID: 2, paneID: 9, cwd: "file:///Users/hira/project",
      tabTitle: "Other work"),
  ]

  let result = WezTermController.bestMatchingPane(
    in: panes,
    directory: "/Users/hira/project",
    taskID: "ECC-035"
  )

  #expect(result?.paneID == 7)
}

@Test("Attachable terminals include one active pane per tab")
func wezTermAttachablePanes() {
  let panes = [
    WezTermPane(
      windowID: 1, tabID: 4, paneID: 8, cwd: "file:///Users/hira/project",
      isActive: true, tabTitle: "Main"),
    WezTermPane(
      windowID: 1, tabID: 4, paneID: 9, cwd: "file:///Users/hira/project",
      isActive: false, title: "helper"),
    WezTermPane(
      windowID: 2, tabID: 5, paneID: 12, cwd: "file:///Users/hira/other",
      isActive: true, tabTitle: "Other"),
  ]

  let result = WezTermController.attachablePanes(in: panes)

  #expect(result.map(\.paneID) == [8, 12])
}

@Test("WezTerm matching rejects ambiguous unlabeled windows")
func wezTermAmbiguousWindowMatching() {
  let panes = [
    WezTermPane(
      windowID: 1, paneID: 7, cwd: "file:///Users/hira/project", isActive: true,
      tabTitle: "Other work"),
    WezTermPane(
      windowID: 2, paneID: 9, cwd: "file:///Users/hira/project", isActive: false,
      tabTitle: "Another task"),
  ]

  let result = WezTermController.bestMatchingPane(
    in: panes,
    directory: "/Users/hira/project",
    taskID: "ECC-035"
  )
  #expect(result == nil)
}

@Test("WezTerm attachment labels the selected tab and window")
func wezTermAttachArguments() async throws {
  let runner = MockProcessRunner(results: [
    ProcessResult(exitCode: 0, standardOutput: "", standardError: "", timedOut: false),
    ProcessResult(exitCode: 0, standardOutput: "", standardError: "", timedOut: false),
  ])
  let controller = WezTermController(runner: runner)

  try await controller.attach(
    paneID: 17,
    taskID: "ECC-035",
    configuration: WezTermConfiguration(executable: "/mock/wezterm")
  )
  let invocations = await runner.specifications

  #expect(invocations.map(\.arguments) == [
    ["cli", "set-tab-title", "--pane-id", "17", "ECC-035"],
    ["cli", "set-window-title", "--pane-id", "17", "ECC-035"],
  ])
}

@Test("Running WezTerm agents resolve exact Codex session IDs from their TTY")
func wezTermAgentDiscovery() async throws {
  let sessionID = "01a064d7-3bc1-7681-8fb5-ca280b1aac96"
  let panes = """
    [{"window_id":11,"tab_id":20,"pane_id":33,
      "cwd":"file:///Users/hira/Documents/Github/ECCFocusQueue",
      "is_active":true,"tab_title":"ECC-035","tty_name":"/dev/ttys027"}]
    """
  let processList = "30447 ttys027  codex\n"
  let lsof = """
    p30447
    n/Users/hira/.codex/sessions/2026/09/02/rollout-2026-09-02T21-17-02-\(sessionID).jsonl
    """
  let runner = MockProcessRunner(results: [
    ProcessResult(exitCode: 0, standardOutput: panes, standardError: "", timedOut: false),
    ProcessResult(exitCode: 0, standardOutput: processList, standardError: "", timedOut: false),
    ProcessResult(exitCode: 0, standardOutput: lsof, standardError: "", timedOut: false),
  ])
  let controller = WezTermController(runner: runner)

  let agents = try await controller.listRunningAgents(
    configuration: WezTermConfiguration(executable: "/mock/wezterm")
  )

  let agent = try #require(agents.first)
  #expect(agent.provider == .codex)
  #expect(agent.sessionID == sessionID)
  #expect(agent.tabTitle == "ECC-035")
  #expect(agent.workingDirectory == "/Users/hira/Documents/Github/ECCFocusQueue")
  #expect(agent.pane.paneID == 33)
  #expect(WezTermController.sessionID(
    for: .claude,
    inLsofOutput:
      "n/Users/hira/.claude/projects/-Users-hira-project/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.jsonl"
  ) == "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
  #expect(WezTermController.sessionID(
    for: .codex,
    inLsofOutput:
      "n/Users/hira/.codex/thread-writer-locks/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.lock"
  ) == "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
}

@Test("Agent resume commands use the saved provider, session, and working directory")
func wezTermAgentResumeCommands() {
  let codex = TaskAgentSession(
    ticketID: "ECC-035",
    provider: .codex,
    sessionID: "11111111-2222-3333-4444-555555555555",
    tabTitle: "Focus queue",
    workingDirectory: "/Users/test/codex-worktree"
  )
  let claude = TaskAgentSession(
    ticketID: "ECC-035",
    provider: .claude,
    sessionID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
    tabTitle: "Focus queue review",
    workingDirectory: "/Users/test/claude-worktree"
  )

  #expect(WezTermController.resumeSpawnArguments(for: codex) == [
    "cli", "spawn", "--new-window", "--cwd", "/Users/test/codex-worktree", "--",
    "/usr/bin/env", "codex", "resume", "11111111-2222-3333-4444-555555555555",
  ])
  #expect(WezTermController.resumeSpawnArguments(for: claude) == [
    "cli", "spawn", "--new-window", "--cwd", "/Users/test/claude-worktree", "--",
    "/usr/bin/env", "claude", "--resume", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
  ])
}

@Test("Config rejects relative source paths")
func configValidation() {
  var config = AppConfiguration.eccDefault(homeDirectory: URL(fileURLWithPath: "/Users/test"))
  config.dashboardPath = "relative/dashboard.json"

  #expect(throws: ConfigurationError.pathsMustBeAbsolute) {
    try config.validated()
  }
}

@Test("Codex review is bounded and uses the local harness")
func codexReviewArguments() async throws {
  let runner = MockProcessRunner(results: [
    ProcessResult(
      exitCode: 0, standardOutput: "More evidence is needed.", standardError: "", timedOut: false)
  ])
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("focus-queue-codex-test-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let request = root.appendingPathComponent("request.json")
  try Data("{}".utf8).write(to: request)

  let verifier = CodexCompletionVerifier(runner: runner)
  let result = try await verifier.verify(
    ticketID: "ECC-035",
    requestFile: request,
    workspace: root.path,
    configuration: VerifierConfiguration(
      enabled: true,
      executable: "/mock/focus-queue-codex",
      sessionName: "focus-codex-verifier",
      timeoutSeconds: 60,
      maxTurns: 12
    )
  )
  let invocation = try #require(await runner.specifications.first)

  #expect(result.succeeded)
  #expect(invocation.arguments.contains("focus-codex-verifier"))
  #expect(invocation.arguments.contains("--timeout"))
  #expect(invocation.arguments.contains("--prompt-file"))
  #expect(invocation.arguments.contains("workspace-write"))
}

@Test("Codex Queue chat uses a separate bounded session and explicit edit boundary")
func codexQueueAgentArguments() async throws {
  let runner = MockProcessRunner(results: [
    ProcessResult(
      exitCode: 0, standardOutput: "ECC-002 follows ECC-001 because it is high priority.",
      standardError: "", timedOut: false)
  ])
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("focus-queue-agent-test-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

  let agent = CodexQueueAgent(runner: runner)
  let reply = try await agent.send(
    message: "Why is ECC-002 second? Do not edit anything.",
    dashboardPath: root.appendingPathComponent("dashboard.json").path,
    workspace: root.path,
    visibleOrder: ["ECC-001", "ECC-002"],
    deferredTicketIDs: ["ECC-009"],
    configuration: VerifierConfiguration(
      enabled: true,
      executable: "/mock/focus-queue-codex",
      sessionName: "completion-session",
      timeoutSeconds: 60,
      maxTurns: 12
    )
  )
  let invocation = try #require(await runner.specifications.first)
  let prompt = CodexQueueAgent.prompt(
    message: "Add the supplied link to ECC-002.",
    dashboardPath: "/tmp/dashboard.json",
    workspace: "/tmp/workspace",
    visibleOrder: ["ECC-001", "ECC-002"],
    deferredTicketIDs: ["ECC-009"]
  )

  #expect(reply.message.contains("ECC-002"))
  #expect(invocation.arguments.contains(CodexQueueAgent.sessionName))
  #expect(invocation.arguments.contains("--timeout"))
  #expect(invocation.arguments.contains("--prompt-file"))
  #expect(prompt.contains("Edit the canonical dashboard only when"))
  #expect(prompt.contains("Current local deferred task IDs: ECC-009"))
  #expect(prompt.contains("Truth is a hard operational invariant"))
  #expect(prompt.contains("/Users/hira/.local/bin/focus-mail"))
  #expect(prompt.contains("Do not use Himalaya for this mailbox"))
  #expect(prompt.contains("MAIL_PROOF: <nonce>"))
  #expect(prompt.contains("/Users/hira/.local/bin/focus-discord"))
  #expect(prompt.contains("DISCORD_PROOF: <nonce>"))
  #expect(CodexQueueAgent.sessionName == "ecc-focus-queue-codex-v1")
  #expect(prompt.contains("<queue-user-message>"))
}

@Test("Queue chat accepts fresh verified mail proof and adds a deterministic receipt")
func codexQueueAgentAcceptsVerifiedMailProof() async throws {
  let receipt = Data(
    """
    {
      "status":"ok",
      "verified":true,
      "operation":"read",
      "connector":"ecc-focus-mail-reader",
      "account":"haley@ecc.tools",
      "retrievedAt":"2026-09-03T00:50:43Z",
      "nonce":"proof-123",
      "message":{
        "id":"mail:3082",
        "messageId":"<message@example.com>",
        "mailbox":"INBOX",
        "receivedAt":"2026-09-02T08:26:13Z"
      }
    }
    """.utf8
  )
  let runner = MockProcessRunner(results: [
    ProcessResult(
      exitCode: 0,
      standardOutput: "Retrieved the requested email.\nMAIL_PROOF: proof-123",
      standardError: "",
      timedOut: false
    )
  ])
  let agent = CodexQueueAgent(
    runner: runner,
    files: MockFileAccessor(data: receipt, modificationDate: .distantFuture)
  )

  let reply = try await agent.send(
    message: "Read my recent email.",
    dashboardPath: "/tmp/dashboard.json",
    workspace: "/tmp",
    visibleOrder: [],
    deferredTicketIDs: [],
    configuration: VerifierConfiguration(
      enabled: true,
      executable: "/mock/focus-queue-codex",
      sessionName: "unused",
      timeoutSeconds: 60,
      maxTurns: 12
    )
  )

  #expect(!reply.message.contains("MAIL_PROOF"))
  #expect(reply.message.contains("Verified mail evidence: haley@ecc.tools"))
  #expect(reply.message.contains("<message@example.com>"))
}

@Test("Queue chat withholds mail claims that lack a fresh proof receipt")
func codexQueueAgentRejectsUnsupportedMailClaim() async {
  let runner = MockProcessRunner(results: [
    ProcessResult(
      exitCode: 0,
      standardOutput: "I read the customer email and everything is fine.",
      standardError: "",
      timedOut: false
    )
  ])
  let agent = CodexQueueAgent(
    runner: runner,
    files: MockFileAccessor(data: Data(), modificationDate: .distantPast)
  )

  do {
    _ = try await agent.send(
      message: "What did the customer email say?",
      dashboardPath: "/tmp/dashboard.json",
      workspace: "/tmp",
      visibleOrder: [],
      deferredTicketIDs: [],
      configuration: VerifierConfiguration(
        enabled: true,
        executable: "/mock/focus-queue-codex",
        sessionName: "unused",
        timeoutSeconds: 60,
        maxTurns: 12
      )
    )
    Issue.record("Unsupported mail claim was not withheld")
  } catch {
    #expect(error.localizedDescription.contains("mail answer withheld"))
  }
}

@Test("Queue chat accepts fresh verified Discord proof and reports partial coverage")
func codexQueueAgentAcceptsVerifiedDiscordProof() async throws {
  let receipt = Data(
    """
    {
      "status":"partial",
      "verified":true,
      "operation":"read",
      "connector":"ecc-focus-discord-reader",
      "retrievedAt":"2026-09-03T01:20:00Z",
      "nonce":"discord-proof-123",
      "guild":{"id":"1496644400590094540","name":"ECC"},
      "message":{
        "id":"1234567890",
        "channelId":"9876543210",
        "channel":"general",
        "timestamp":"2026-09-03T01:19:00Z",
        "url":"https://discord.com/channels/1/2/3"
      },
      "inaccessibleChannels":[{"id":"4","name":"moderator-only"}]
    }
    """.utf8
  )
  let runner = MockProcessRunner(results: [
    ProcessResult(
      exitCode: 0,
      standardOutput: "Retrieved the requested Discord message.\nDISCORD_PROOF: discord-proof-123",
      standardError: "",
      timedOut: false
    )
  ])
  let agent = CodexQueueAgent(
    runner: runner,
    files: MockFileAccessor(data: receipt, modificationDate: .distantFuture)
  )

  let reply = try await agent.send(
    message: "Read this Discord message.",
    dashboardPath: "/tmp/dashboard.json",
    workspace: "/tmp",
    visibleOrder: [],
    deferredTicketIDs: [],
    configuration: VerifierConfiguration(
      enabled: true,
      executable: "/mock/focus-queue-codex",
      sessionName: "unused",
      timeoutSeconds: 60,
      maxTurns: 12
    )
  )

  #expect(!reply.message.contains("DISCORD_PROOF"))
  #expect(reply.message.contains("Verified Discord evidence: ECC"))
  #expect(reply.message.contains("moderator-only"))
}

@Test("GitHub recurring PR loader reads open backlog and weekly resolutions")
func githubPullRequestQueueArguments() async throws {
  let runner = MockProcessRunner(results: [
    ProcessResult(
      exitCode: 0,
      standardOutput: """
        [
          {"number":11,"title":"Open one","url":"https://example.test/11","state":"OPEN"},
          {"number":12,"title":"Open two","url":"https://example.test/12","state":"OPEN"}
        ]
        """,
      standardError: "",
      timedOut: false
    ),
    ProcessResult(
      exitCode: 0,
      standardOutput: """
        [
          {"number":10,"title":"Merged","url":"https://example.test/10","state":"MERGED","mergedAt":"2026-08-31T12:00:00Z","closedAt":"2026-08-31T12:00:00Z"}
        ]
        """,
      standardError: "",
      timedOut: false
    ),
  ])
  let loader = GitHubPullRequestQueueLoader(runner: runner, executable: "/mock/gh")
  let snapshot = try await loader.load(
    repository: "affaan-m/ECC",
    closedSince: "2026-08-31"
  )
  let invocations = await runner.specifications

  #expect(snapshot.openCount == 2)
  #expect(snapshot.resolvedThisWeek.map(\.number) == [10])
  #expect(invocations.count == 2)
  #expect(invocations[0].arguments.contains("open"))
  #expect(invocations[1].arguments.contains("closed:>=2026-08-31"))
  #expect(invocations.allSatisfy { !$0.arguments.contains("--web") })
}

@Test("WezTerm controller focuses a matching pane without spawning")
func wezTermFocusArguments() async throws {
  let panes = """
    [{"window_id":4,"pane_id":17,"cwd":"file:///Users/test/project","is_active":true}]
    """
  let runner = MockProcessRunner(results: [
    ProcessResult(exitCode: 0, standardOutput: panes, standardError: "", timedOut: false),
    ProcessResult(exitCode: 0, standardOutput: "", standardError: "", timedOut: false),
    ProcessResult(exitCode: 0, standardOutput: "", standardError: "", timedOut: false),
    ProcessResult(exitCode: 0, standardOutput: "", standardError: "", timedOut: false),
  ])
  let controller = WezTermController(runner: runner)

  let result = try await controller.focusOrSpawn(
    directory: "/Users/test/project",
    taskID: "ECC-035",
    configuration: WezTermConfiguration(executable: "/mock/wezterm")
  )
  let invocations = await runner.specifications

  #expect(result == .focused(paneID: 17))
  #expect(invocations.count == 4)
  #expect(invocations[1].arguments == [
    "cli", "set-window-title", "--pane-id", "17", "ECC-035",
  ])
  #expect(invocations[2].arguments == ["cli", "activate-pane", "--pane-id", "17"])
  #expect(!invocations.flatMap(\.arguments).contains("spawn"))
}

@Test("WezTerm controller creates and labels a new window when no pane is associated")
func wezTermNewWindowArguments() async throws {
  let panes = """
    [{"window_id":4,"pane_id":17,"cwd":"file:///Users/test/other","is_active":true}]
    """
  let runner = MockProcessRunner(results: [
    ProcessResult(exitCode: 0, standardOutput: panes, standardError: "", timedOut: false),
    ProcessResult(exitCode: 0, standardOutput: "22\n", standardError: "", timedOut: false),
    ProcessResult(exitCode: 0, standardOutput: "", standardError: "", timedOut: false),
    ProcessResult(exitCode: 0, standardOutput: "", standardError: "", timedOut: false),
    ProcessResult(exitCode: 0, standardOutput: "", standardError: "", timedOut: false),
    ProcessResult(exitCode: 0, standardOutput: "", standardError: "", timedOut: false),
  ])
  let controller = WezTermController(runner: runner)

  let result = try await controller.focusOrSpawn(
    directory: "/Users/test/project",
    taskID: "ECC-035",
    configuration: WezTermConfiguration(executable: "/mock/wezterm")
  )
  let invocations = await runner.specifications

  #expect(result == .spawned(paneID: 22))
  #expect(invocations[1].arguments == [
    "cli", "spawn", "--new-window", "--cwd", "/Users/test/project",
  ])
  #expect(invocations[2].arguments == [
    "cli", "set-tab-title", "--pane-id", "22", "ECC-035",
  ])
  #expect(invocations[3].arguments == [
    "cli", "set-window-title", "--pane-id", "22", "ECC-035",
  ])
  #expect(!invocations[1].arguments.contains("--window-id"))
}

@Test("WezTerm controller has a detached app fallback when the mux is unavailable")
func wezTermStandaloneFallback() async throws {
  let runner = MockProcessRunner(results: [
    ProcessResult(exitCode: 1, standardOutput: "", standardError: "no mux", timedOut: false),
    ProcessResult(exitCode: 0, standardOutput: "", standardError: "", timedOut: false),
  ])
  let controller = WezTermController(runner: runner)

  let result = try await controller.focusOrSpawn(
    directory: "/Users/test/project",
    taskID: "ECC-035",
    configuration: WezTermConfiguration(executable: "/mock/wezterm")
  )
  let invocation = try #require(await runner.specifications.last)

  #expect(result == .spawned(paneID: nil))
  #expect(invocation.executable == "/usr/bin/open")
  #expect(invocation.arguments == [
    "-na", "WezTerm", "--args", "start", "--always-new-process", "--cwd",
    "/Users/test/project",
  ])
}

@Test("View Agent focuses the pane that owns the saved session ID")
func wezTermFocusesSavedAgentSession() async throws {
  let sessionID = "01a064d7-3bc1-7681-8fb5-ca280b1aac96"
  let panes = """
    [{"window_id":11,"tab_id":20,"pane_id":33,"cwd":"file:///Users/test/project",
      "tab_title":"ECC-035","tty_name":"/dev/ttys027"}]
    """
  let runner = MockProcessRunner(results: [
    ProcessResult(exitCode: 0, standardOutput: panes, standardError: "", timedOut: false),
    ProcessResult(
      exitCode: 0, standardOutput: "30447 ttys027 codex\n", standardError: "", timedOut: false),
    ProcessResult(
      exitCode: 0,
      standardOutput:
        "n/Users/test/.codex/sessions/2026/09/02/rollout-2026-09-02T21-17-02-\(sessionID).jsonl\n",
      standardError: "", timedOut: false),
    ProcessResult(exitCode: 0, standardOutput: "", standardError: "", timedOut: false),
    ProcessResult(exitCode: 0, standardOutput: "", standardError: "", timedOut: false),
    ProcessResult(exitCode: 0, standardOutput: "", standardError: "", timedOut: false),
  ])
  let controller = WezTermController(runner: runner)
  let session = TaskAgentSession(
    ticketID: "ECC-035", provider: .codex, sessionID: sessionID,
    tabTitle: "ECC-035", workingDirectory: "/Users/test/project", paneID: 99
  )

  let result = try await controller.focusOrResume(
    session: session,
    taskID: "ECC-035",
    configuration: WezTermConfiguration(executable: "/mock/wezterm")
  )
  let invocations = await runner.specifications

  #expect(result == .focused(paneID: 33))
  #expect(invocations[3].arguments == [
    "cli", "activate-pane", "--pane-id", "33",
  ])
  #expect(invocations[4].arguments == [
    "cli", "set-window-title", "--pane-id", "33",
    "ECC-035 · Codex · \(sessionID)",
  ])
  #expect(invocations.contains { $0.arguments == [
    "cli", "activate-pane", "--pane-id", "33",
  ] })
  #expect(!invocations.flatMap(\.arguments).contains("spawn"))
}

@Test("View Agent resumes a missing session in its saved worktree")
func wezTermResumesMissingAgentSession() async throws {
  let sessionID = "11111111-2222-3333-4444-555555555555"
  let runner = MockProcessRunner(results: [
    ProcessResult(exitCode: 0, standardOutput: "[]", standardError: "", timedOut: false),
    ProcessResult(exitCode: 0, standardOutput: "", standardError: "", timedOut: false),
    ProcessResult(exitCode: 0, standardOutput: "41\n", standardError: "", timedOut: false),
    ProcessResult(exitCode: 0, standardOutput: "", standardError: "", timedOut: false),
    ProcessResult(exitCode: 0, standardOutput: "", standardError: "", timedOut: false),
    ProcessResult(exitCode: 0, standardOutput: "", standardError: "", timedOut: false),
    ProcessResult(exitCode: 0, standardOutput: "", standardError: "", timedOut: false),
  ])
  let controller = WezTermController(runner: runner)
  let session = TaskAgentSession(
    ticketID: "ECC-035", provider: .codex, sessionID: sessionID,
    tabTitle: "ECC-035", workingDirectory: "/Users/test/project", paneID: 33
  )

  let result = try await controller.focusOrResume(
    session: session,
    taskID: "ECC-035",
    configuration: WezTermConfiguration(executable: "/mock/wezterm")
  )
  let invocations = await runner.specifications

  #expect(result == .resumed(provider: .codex, sessionID: sessionID, paneID: 41))
  #expect(invocations[2].arguments == [
    "cli", "spawn", "--new-window", "--cwd", "/Users/test/project", "--",
    "/usr/bin/env", "codex", "resume", sessionID,
  ])
  #expect(invocations[5].arguments == [
    "cli", "set-window-title", "--pane-id", "41",
    "ECC-035 · Codex · \(sessionID)",
  ])
}

@Test("Terminal focus geometry centers and caps the terminal window")
func terminalFocusCenteredFrame() {
  let result = TerminalFocusGeometry.centeredFrame(
    currentFrame: CGRect(x: 0, y: 0, width: 1_600, height: 1_200),
    visibleFrame: CGRect(x: 100, y: 200, width: 1_000, height: 800)
  )

  #expect(result == CGRect(x: 180, y: 264, width: 840, height: 672))
}

@Test("Queue monitor selection cycles through connected screens")
func queueNextScreen() {
  let screens = [
    CGRect(x: -1_920, y: 0, width: 1_920, height: 1_080),
    CGRect(x: 0, y: 0, width: 1_512, height: 982),
  ]

  #expect(DisplayGeometry.nextScreenIndex(
    currentScreenFrame: screens[0],
    orderedScreenFrames: screens
  ) == 1)
  #expect(DisplayGeometry.nextScreenIndex(
    currentScreenFrame: screens[1],
    orderedScreenFrames: screens
  ) == 0)
  #expect(DisplayGeometry.nextScreenIndex(
    currentScreenFrame: screens[0],
    orderedScreenFrames: [screens[0]]
  ) == nil)
}

@Test("Queue placement stays fully inside different display sizes")
func queuePanelFrameIsVisible() {
  let compactDisplay = CGRect(x: 1_500, y: -20, width: 700, height: 500)
  let right = DisplayGeometry.panelFrame(
    preferredWidth: 620,
    visibleFrame: compactDisplay,
    placement: .upperRight
  )
  let centered = DisplayGeometry.panelFrame(
    preferredWidth: 900,
    visibleFrame: CGRect(x: -1_920, y: 0, width: 1_920, height: 1_080),
    placement: .center
  )

  #expect(compactDisplay.contains(right))
  #expect(right == CGRect(x: 1_568, y: -8, width: 620, height: 476))
  #expect(centered.midX == -960)
  #expect(centered.width == 620)
}

@Test("Every queue placement stays in the supplied display coordinate space")
func everyQueuePlacementStaysOnCurrentDisplay() {
  let currentDisplay = CGRect(x: -2_560, y: 180, width: 2_560, height: 1_440)

  for placement in QueueWindowPlacement.allCases {
    let frame = DisplayGeometry.panelFrame(
      preferredWidth: 440,
      visibleFrame: currentDisplay,
      placement: placement
    )

    #expect(currentDisplay.contains(frame))
  }
}

private actor MockProcessRunner: ProcessRunning {
  private var results: [ProcessResult]
  private(set) var specifications: [ProcessSpecification] = []

  init(results: [ProcessResult]) {
    self.results = results
  }

  func run(_ specification: ProcessSpecification) throws -> ProcessResult {
    specifications.append(specification)
    guard !results.isEmpty else {
      return ProcessResult(exitCode: 0, standardOutput: "", standardError: "", timedOut: false)
    }
    return results.removeFirst()
  }
}

private struct MockFileAccessor: FileAccessing {
  let data: Data
  let modificationDate: Date

  func read(from url: URL) throws -> Data { data }
  func write(_ data: Data, to url: URL) throws {}
  func createDirectory(at url: URL) throws {}
  func fileExists(at url: URL) -> Bool { true }
  func modificationDate(at url: URL) throws -> Date? { modificationDate }
}
