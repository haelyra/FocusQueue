import CoreGraphics
import Foundation
import Testing

@testable import FocusQueueCore

@Test("Morning reconciliation is due only after today's scheduled hour")
func morningRunPolicy() throws {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
  let before = try Date("2026-09-03T07:59:00Z", strategy: .iso8601)
  let after = try Date("2026-09-03T08:01:00Z", strategy: .iso8601)
  let yesterday = try Date("2026-09-02T12:00:00Z", strategy: .iso8601)
  let today = try Date("2026-09-03T08:00:30Z", strategy: .iso8601)

  #expect(!MorningRunPolicy.isDue(now: before, lastSuccessfulAt: yesterday, calendar: calendar))
  #expect(MorningRunPolicy.isDue(now: after, lastSuccessfulAt: nil, calendar: calendar))
  #expect(MorningRunPolicy.isDue(now: after, lastSuccessfulAt: yesterday, calendar: calendar))
  #expect(!MorningRunPolicy.isDue(now: after, lastSuccessfulAt: today, calendar: calendar))
}

@Test("A missed daily report asks for approval while an on-time report runs automatically")
func missedMorningRunPolicy() throws {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
  let onTime = try Date("2026-09-03T08:35:00Z", strategy: .iso8601)
  let pollingJitter = try Date("2026-09-03T08:35:01Z", strategy: .iso8601)
  let missed = try Date("2026-09-03T10:00:00Z", strategy: .iso8601)
  let completed = try Date("2026-09-03T08:31:00Z", strategy: .iso8601)
  let wokeAfterSchedule = try Date("2026-09-03T08:34:00Z", strategy: .iso8601)

  #expect(
    MorningRunPolicy.disposition(
      now: pollingJitter,
      lastSuccessfulAt: nil,
      hour: 8,
      minute: 30,
      automaticGraceMinutes: 10,
      calendar: calendar
    ) == .runAutomatically
  )
  #expect(
    MorningRunPolicy.disposition(
      now: onTime,
      lastSuccessfulAt: nil,
      hour: 8,
      minute: 30,
      automaticGraceMinutes: 10,
      availabilityResumedAt: wokeAfterSchedule,
      calendar: calendar
    ) == .requestApproval
  )
  #expect(
    MorningRunPolicy.disposition(
      now: onTime,
      lastSuccessfulAt: nil,
      hour: 8,
      minute: 30,
      automaticGraceMinutes: 15,
      calendar: calendar
    ) == .runAutomatically
  )
  #expect(
    MorningRunPolicy.disposition(
      now: missed,
      lastSuccessfulAt: nil,
      hour: 8,
      minute: 30,
      automaticGraceMinutes: 15,
      calendar: calendar
    ) == .requestApproval
  )
  #expect(
    MorningRunPolicy.disposition(
      now: missed,
      lastSuccessfulAt: completed,
      hour: 8,
      minute: 30,
      automaticGraceMinutes: 15,
      calendar: calendar
    ) == .notDue
  )
}

@Test("A failed scheduled report retries automatically after the grace window")
func failedMorningRunRetriesAutomatically() throws {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
  let failedAttempt = try Date("2026-09-03T08:35:00Z", strategy: .iso8601)
  let retryTick = try Date("2026-09-03T10:00:00Z", strategy: .iso8601)

  #expect(
    MorningRunPolicy.disposition(
      now: retryTick,
      lastSuccessfulAt: nil,
      lastUnsuccessfulAttemptAt: failedAttempt,
      hour: 8,
      minute: 30,
      automaticGraceMinutes: 10,
      calendar: calendar
    ) == .runAutomatically
  )
}

@Test("Legacy application configuration receives safe daily-report defaults")
func legacyDailyReportConfiguration() throws {
  let data = Data(
    """
    {
      "appName": "ECC Focus Queue",
      "dashboardPath": "/tmp/dashboard.json",
      "workspacePath": "/tmp/workspace",
      "defaultPlacement": "upper-right",
      "refreshIntervalSeconds": 2,
      "dailyRoutines": [],
      "wezTerm": {"executable": "/tmp/wezterm", "applicationName": "WezTerm"},
      "verifier": {
        "enabled": true,
        "executable": "/tmp/focus-queue-codex",
        "sessionName": "queue",
        "timeoutSeconds": 120,
        "maxTurns": 24
      }
    }
    """.utf8
  )

  let config = try JSONDecoder().decode(AppConfiguration.self, from: data)

  #expect(config.dailyReport.scheduleHour == 8)
  #expect(config.dailyReport.scheduleMinute == 0)
  #expect(config.dailyReport.maximumTokens == 75_000)
  #expect(Set(config.dailyReport.enabledPlatforms) == Set(DailyReportPlatform.allCases))
  #expect(config.agentModelChoices == AppConfiguration.defaultAgentModelChoices)
}

@Test("Configured agent model choices decode and round-trip")
func agentModelChoiceConfiguration() throws {
  let data = Data(
    """
    {
      "appName": "ECC Focus Queue",
      "dashboardPath": "/tmp/dashboard.json",
      "workspacePath": "/tmp/workspace",
      "defaultPlacement": "upper-right",
      "refreshIntervalSeconds": 2,
      "dailyRoutines": [],
      "wezTerm": {"executable": "/tmp/wezterm", "applicationName": "WezTerm"},
      "verifier": {
        "enabled": true,
        "executable": "/tmp/focus-queue-codex",
        "sessionName": "queue",
        "timeoutSeconds": 120,
        "maxTurns": 24
      },
      "agentModelChoices": [
        {"provider": "codex", "label": "Default"},
        {"provider": "codex", "label": "gpt-5.5", "model": "gpt-5.5"},
        {"provider": "claude", "label": "Big opus", "model": "opus", "effort": "high"}
      ]
    }
    """.utf8
  )

  let config = try JSONDecoder().decode(AppConfiguration.self, from: data)

  #expect(config.agentModelChoices == [
    AgentModelChoice(provider: .codex, label: "Default"),
    AgentModelChoice(provider: .codex, label: "gpt-5.5", model: "gpt-5.5"),
    AgentModelChoice(provider: .claude, label: "Big opus", model: "opus", effort: "high"),
  ])
  let roundTripped = try JSONDecoder().decode(
    AppConfiguration.self, from: JSONEncoder().encode(config))
  #expect(roundTripped.agentModelChoices == config.agentModelChoices)
  #expect(AppConfiguration.defaultAgentModelChoices.map(\.provider)
    == [.codex, .codex, .codex, .codex, .claude, .claude, .claude, .claude])
  #expect(AppConfiguration.defaultAgentModelChoices.first(where: { $0.model == nil && $0.provider == .claude })?.label == "Default")
}

@Test("Daily report documents retain platform counts, messages, tasks, and exact usage")
func dailyReportDecoding() throws {
  let data = Data(
    """
    {
      "version": 1,
      "runID": "run-123",
      "trigger": "scheduled",
      "mode": "unseen-only",
      "startedAt": "2026-09-03T12:00:00Z",
      "finishedAt": "2026-09-03T12:01:00Z",
      "status": "success",
      "summary": "Two customer requests created one high-priority task.",
      "tokenBudget": 75000,
      "usage": {
        "inputTokens": 1200,
        "cachedInputTokens": 200,
        "outputTokens": 300,
        "reasoningOutputTokens": 100,
        "totalTokens": 1500
      },
      "platforms": [{
        "platform": "email",
        "status": "ok",
        "collectedCount": 3,
        "newCount": 2,
        "alreadyProcessedCount": 1,
        "checkedCount": 2,
        "deferredCount": 0,
        "messages": [{
          "sourceKey": "email:<one@example.test>",
          "title": "Release request",
          "summary": "A customer requested the next release. The request needs maintainer review.",
          "timestamp": "2026-09-03T11:00:00Z",
          "url": "message://one",
          "tasks": [{"id": "ECC-100", "title": "Review release request"}]
        }]
      }],
      "errors": []
    }
    """.utf8
  )

  let report = try JSONDecoder().decode(DailyReportDocument.self, from: data)
  let platform = try #require(report.platforms.first)
  let message = try #require(platform.messages.first)

  #expect(report.usage?.totalTokens == 1_500)
  #expect(platform.newCount == 2)
  #expect(message.tasks.first?.id == "ECC-100")
  #expect(message.url == "message://one")
  #expect(report.covers([.email]))
  #expect(!report.covers([.email, .discord]))
}

@Test("Configuration updates and latest reports persist atomically")
func dailyReportPersistence() async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("focus-queue-report-test-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let configurationURL = root.appendingPathComponent("config.json")
  let reportURL = root.appendingPathComponent("latest-report.json")
  let configurationRepository = JSONConfigurationRepository(url: configurationURL)
  var configuration = AppConfiguration.eccDefault(homeDirectory: root)
  configuration.dailyReport.maximumTokens = 60_000

  try await configurationRepository.save(configuration)
  let reloaded = try await configurationRepository.loadOrCreate(default: .eccDefault(homeDirectory: root))

  let report = DailyReportDocument(
    runID: "run-persisted",
    trigger: .manual,
    mode: .unseenOnly,
    startedAt: "2026-09-03T12:00:00Z",
    finishedAt: "2026-09-03T12:01:00Z",
    status: .success,
    summary: "Report persisted.",
    tokenBudget: 60_000,
    usage: DailyReportTokenUsage(
      inputTokens: 10,
      cachedInputTokens: 0,
      outputTokens: 5,
      reasoningOutputTokens: 0,
      totalTokens: 15
    ),
    platforms: [],
    errors: []
  )
  let reportRepository = JSONDailyReportRepository(url: reportURL)
  try await reportRepository.save(report)

  #expect(reloaded.dailyReport.maximumTokens == 60_000)
  #expect(try await reportRepository.load()?.runID == "run-persisted")
  #expect((try FileManager.default.attributesOfItem(
    atPath: configurationURL.path
  )[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  #expect((try FileManager.default.attributesOfItem(
    atPath: reportURL.path
  )[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test("Agent provider fallback order filters unknown names and defaults to codex then claude")
func agentProviderFallbackDecoding() throws {
  let encoder = JSONEncoder()
  var configuration = AppConfiguration.eccDefault(homeDirectory: URL(fileURLWithPath: "/tmp/fallback-home"))
  #expect(configuration.agentProviderFallbackOrder == [.codex, .claude])
  #expect(configuration.agentEscalationAutoLaunch)

  // A legacy configuration without the new keys decodes to the defaults.
  var object = try #require(
    try JSONSerialization.jsonObject(with: encoder.encode(configuration)) as? [String: Any])
  object.removeValue(forKey: "agentProviderFallbackOrder")
  object.removeValue(forKey: "agentEscalationAutoLaunch")
  let legacy = try JSONDecoder().decode(
    AppConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
  #expect(legacy.agentProviderFallbackOrder == [.codex, .claude])
  #expect(legacy.agentEscalationAutoLaunch)

  // Unknown providers are skipped and duplicates collapse.
  object["agentProviderFallbackOrder"] = ["kimi", "claude", "claude", "codex"]
  object["agentEscalationAutoLaunch"] = false
  let filtered = try JSONDecoder().decode(
    AppConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
  #expect(filtered.agentProviderFallbackOrder == [.claude, .codex])
  #expect(!filtered.agentEscalationAutoLaunch)

  // An entirely unknown list falls back to the default instead of decoding empty.
  object["agentProviderFallbackOrder"] = ["kimi"]
  let unknown = try JSONDecoder().decode(
    AppConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
  #expect(unknown.agentProviderFallbackOrder == [.codex, .claude])

  // The configured order survives a save and reload round trip.
  configuration.agentProviderFallbackOrder = [.claude, .codex]
  let roundTrip = try JSONDecoder().decode(
    AppConfiguration.self, from: encoder.encode(configuration))
  #expect(roundTrip.agentProviderFallbackOrder == [.claude, .codex])
}

@Test("Missed-run approval is a portable persisted contract")
func dailyReportApprovalPersistence() async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("focus-queue-approval-test-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let repository = JSONDailyReportApprovalRepository(
    url: root.appendingPathComponent("pending-approval.json")
  )
  let request = DailyReportApprovalRequest(
    id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
    reportDate: "2026-09-03",
    requestedAt: "2026-09-03T14:00:00Z"
  )

  try await repository.save(request)
  let reloaded = try #require(try await repository.load())

  #expect(reloaded == request)
  #expect(reloaded.status == .pending)
  #expect(reloaded.isCurrent(reportDate: "2026-09-03"))
  #expect(!reloaded.isCurrent(reportDate: "2026-09-04"))
}

@Test("Daily report automation arguments are allowlisted and explicit")
func dailyReportAutomationArguments() {
  let request = DailyReportRunRequest(
    trigger: .chat,
    platforms: [.email, .discord],
    comprehensive: false,
    recheck: true
  )

  let arguments = DailyReportAutomation.arguments(
    scriptPath: "/support/focus_queue_morning.py",
    configurationPath: "/support/ingestion.json",
    runtimePath: "/support/ingestion",
    request: request
  )

  #expect(arguments.contains("--trigger"))
  #expect(arguments.contains("chat"))
  #expect(arguments.filter { $0 == "--platform" }.count == 2)
  #expect(arguments.contains("email"))
  #expect(arguments.contains("discord"))
  #expect(arguments.contains("--recheck"))
}

@Test("Queue chat distinguishes report runs from exact message reads")
func dailyReportChatIntent() {
  #expect(CodexQueueAgent.isDailyReportRunRequest(
    "Run my daily report for Discord and email"
  ))
  #expect(CodexQueueAgent.isDailyReportRunRequest(
    "Check GitHub and Telegram for the focus report"
  ))
  #expect(!CodexQueueAgent.isDailyReportRunRequest(
    "What did the latest Discord message say?"
  ))
  #expect(!CodexQueueAgent.isDailyReportRunRequest(
    "How many messages did the daily report check?"
  ))
  #expect(!CodexQueueAgent.isDailyReportRunRequest(
    "Did the daily report update this morning?"
  ))
  #expect(!CodexQueueAgent.isDailyReportRunRequest(
    "Update me on the daily report"
  ))
  #expect(!CodexQueueAgent.isDailyReportRunRequest(
    "Check whether the daily report ran"
  ))
  let parsed = DailyReportChatCommand.parse(
    "Please run the daily report for email and Discord and recheck already processed messages.",
    enabledPlatforms: DailyReportPlatform.allCases
  )
  #expect(parsed?.platforms == [.discord, .email])
  #expect(parsed?.comprehensive == false)
  #expect(parsed?.recheck == true)
  let disabledOverride = DailyReportChatCommand.parse(
    "Run the daily report for Telegram.",
    enabledPlatforms: [.email]
  )
  #expect(disabledOverride?.platforms == [.telegram])
  #expect(disabledOverride?.comprehensive == false)
  let wordBoundary = DailyReportChatCommand.parse(
    "Run the daily report mainly for today.",
    enabledPlatforms: [.discord, .email]
  )
  #expect(wordBoundary?.comprehensive == true)
  let noRecheck = DailyReportChatCommand.parse(
    "Run the daily report but do not recheck already checked messages.",
    enabledPlatforms: [.discord, .email]
  )
  #expect(noRecheck?.recheck == false)
  #expect(DailyReportChatCommand.parse(
    "Run the daily report without checking already processed messages.",
    enabledPlatforms: [.discord, .email]
  )?.recheck == false)
  let narrowed = DailyReportChatCommand.parse(
    "Run the daily report for email, not all platforms.",
    enabledPlatforms: [.discord, .email]
  )
  #expect(narrowed?.comprehensive == false)
  #expect(narrowed?.platforms == [.email])
  #expect(DailyReportChatCommand.parse(
    "Run the daily report, not all platforms.",
    enabledPlatforms: [.discord, .email]
  ) == nil)
  #expect(DailyReportChatCommand.parse(
    "Run the daily report for all platforms except email.",
    enabledPlatforms: [.discord, .email]
  ) == nil)
  #expect(DailyReportChatCommand.parse(
    "Run the daily report excluding email.",
    enabledPlatforms: [.discord, .email]
  ) == nil)
  #expect(DailyReportChatCommand.parse(
    "Run the daily report including already processed messages.",
    enabledPlatforms: [.discord, .email]
  )?.recheck == true)
  #expect(DailyReportChatCommand.parse(
    "Generate the daily message and update report",
    enabledPlatforms: [.discord, .email]
  )?.comprehensive == true)
  #expect(DailyReportChatCommand.parse(
    "Run the daily report for Slack",
    enabledPlatforms: [.discord, .email]
  ) == nil)
  #expect(DailyReportChatCommand.parse(
    "Run the daily report on Slack",
    enabledPlatforms: [.discord, .email]
  ) == nil)
  #expect(DailyReportChatCommand.parse(
    "Run the daily report for Slack and email",
    enabledPlatforms: [.discord, .email]
  ) == nil)
  #expect(DailyReportChatCommand.parse(
    "Run the daily report, don't check email",
    enabledPlatforms: [.discord, .email]
  ) == nil)
  #expect(DailyReportChatCommand.parse(
    "Run the daily report, with no email",
    enabledPlatforms: [.discord, .email]
  ) == nil)
  #expect(DailyReportChatCommand.parse(
    "Run the daily report, don’t recheck messages",
    enabledPlatforms: [.discord, .email]
  )?.recheck == false)
  #expect(DailyReportChatCommand.parse(
    "Run the daily report, not rechecking messages",
    enabledPlatforms: [.discord, .email]
  )?.recheck == false)
  #expect(DailyReportChatCommand.parse(
    "Run a comprehensive report",
    enabledPlatforms: [.discord, .email]
  )?.comprehensive == true)
  #expect(CodexQueueAgent.runTimeoutSeconds(
    for: "Generate the daily message report",
    configuredTimeoutSeconds: 120
  ) == 120)
}

@Test("Foundation process runner returns after a short-lived child exits")
func foundationProcessRunnerReturnsAfterExit() async throws {
  let result = try await FoundationProcessRunner().run(ProcessSpecification(
    executable: "/usr/bin/true",
    arguments: [],
    timeoutSeconds: 2
  ))

  #expect(result.succeeded)
  #expect(!result.timedOut)
}

@Test("Foundation process runner terminates a child at its deadline")
func foundationProcessRunnerEnforcesDeadline() async throws {
  let startedAt = Date()
  let result = try await FoundationProcessRunner().run(ProcessSpecification(
    executable: "/bin/sleep",
    arguments: ["5"],
    timeoutSeconds: 1
  ))

  #expect(result.timedOut)
  #expect(Date().timeIntervalSince(startedAt) < 3)
}

@Test("Foundation process runner allows a bounded graceful timeout cleanup")
func foundationProcessRunnerAllowsGracefulCleanup() async throws {
  let marker = FileManager.default.temporaryDirectory
    .appendingPathComponent("focus-queue-grace-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: marker) }
  let result = try await FoundationProcessRunner().run(ProcessSpecification(
    executable: "/bin/sh",
    arguments: [
      "-c",
      "trap 'printf done > \"$1\"; exit 0' TERM; while :; do sleep 0.05; done",
      "focus-queue-grace-test",
      marker.path,
    ],
    timeoutSeconds: 1,
    terminationGraceSeconds: 2
  ))

  #expect(result.timedOut)
  #expect(FileManager.default.fileExists(atPath: marker.path))
}

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

@Test("Dashboard decoding retains source-backed completion facts")
func completedTicketDecoding() throws {
  let json = """
    {
      "tickets": [{
        "id": "ECC-103",
        "title": "Completed task",
        "status": "resolved",
        "summary": "",
        "completedAt": "2026-09-03T14:00:00Z",
        "completion": {
          "outcome": "Merged the queue card update.",
          "reason": "All acceptance checks passed.",
          "resolutionPrs": [1234],
          "evidence": ["https://example.test/pull/1234"],
          "completedBy": "agent-42"
        }
      }]
    }
    """

  let dashboard = try JSONDecoder().decode(DashboardDocument.self, from: Data(json.utf8))
  let ticket = try #require(dashboard.tickets.first)

  #expect(ticket.completionTimestamp == "2026-09-03T14:00:00Z")
  #expect(ticket.completion?.reason == "All acceptance checks passed.")
  #expect(ticket.completion?.resolutionPrs == [1234])
  #expect(ticket.completion?.evidence == ["https://example.test/pull/1234"])
}

@Test("Partial completion facts do not require or invent missing details")
func partialCompletedTicketDecoding() throws {
  let json = """
    {
      "tickets": [{
        "id": "ECC-104",
        "title": "Partially described completion",
        "status": "cancelled",
        "summary": "",
        "completion": {"reason": "Superseded by ECC-105."}
      }]
    }
    """

  let dashboard = try JSONDecoder().decode(DashboardDocument.self, from: Data(json.utf8))
  let ticket = try #require(dashboard.tickets.first)

  #expect(ticket.completion?.reason == "Superseded by ECC-105.")
  #expect(ticket.completion?.outcome == nil)
  #expect(ticket.completion?.resolutionPrs.isEmpty == true)
  #expect(ticket.completion?.evidence.isEmpty == true)
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
    dismissedNotificationIDs: ["daily-report:run-1", "agent-update:worker-1"],
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
    programLogWindowVisible: true,
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
  #expect(!state.programLogWindowVisible)
  #expect(state.dismissedNotificationIDs.isEmpty)
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

    [Jump to status](#status)

    ## Status

    | Item | State |
    | --- | --- |
    | App | Done |

    ```mermaid
    flowchart LR
      A[Plan] --> B[Build]
    ```
    """

  let html = MarkdownHTMLRenderer.page(
    markdown: markdown, sourceURL: sourceURL, accentStyle: .pastel)

  #expect(html.contains("<title>README.md</title>"))
  #expect(html.contains("<base href=\"file:///Users/test/Project%20&amp;%20Notes/\">"))
  #expect(html.contains(#"<h1 id="release-notes">Release notes</h1>"#))
  #expect(html.contains("<strong>Ready</strong>"))
  #expect(html.contains("<table>"))
  #expect(html.contains(#"<h2 id="status">Status</h2>"#))
  #expect(html.contains("data-plan-canvas-diagram"))
  #expect(html.contains(#"<pre class="mermaid">"#))
  #expect(html.contains("A[Plan] --&gt; B[Build]"))
  #expect(html.contains("--accent: light-dark(#607bc7, #91adff)"))
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

@Test("WezTerm task matching rejects prefix collisions and incidental text")
func wezTermTaskLabelMatchingRejectsPartialTitles() {
  let panes = [
    WezTermPane(
      windowID: 1, paneID: 7, cwd: "file:///Users/hira/project", isActive: true,
      tabTitle: "ECC-0350"),
    WezTermPane(
      windowID: 2, paneID: 9, cwd: "file:///Users/hira/project", isActive: false,
      tabTitle: "working on ECC-035"),
  ]

  let result = WezTermController.bestMatchingPane(
    in: panes,
    directory: "/Users/hira/project",
    taskID: "ECC-035"
  )

  #expect(result == nil)
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
    tabTitle: "ECC-035 · Codex · 555555",
    windowTitle: "ECC-035",
    configuration: WezTermConfiguration(executable: "/mock/wezterm")
  )
  let invocations = await runner.specifications

  #expect(invocations.map(\.arguments) == [
    ["cli", "set-tab-title", "--pane-id", "17", "ECC-035 · Codex · 555555"],
    ["cli", "set-window-title", "--pane-id", "17", "ECC-035"],
  ])
}

@Test("Running WezTerm agents resolve exact Codex session IDs from their TTY")
func wezTermAgentDiscovery() async throws {
  let sessionID = "01a064d7-3bc1-7681-8fb5-ca280b1aac96"
  let fixtureRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("wezterm-agent-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: fixtureRoot) }
  let transcript = fixtureRoot
    .appendingPathComponent(".codex/sessions/2026/09/02", isDirectory: true)
    .appendingPathComponent("rollout-2026-09-02T21-17-02-\(sessionID).jsonl")
  try FileManager.default.createDirectory(
    at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
  try Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(sessionID)\"}}\n".utf8)
    .write(to: transcript)
  let panes = """
    [{"window_id":11,"tab_id":20,"pane_id":33,
      "cwd":"file:///Users/hira/Documents/Github/ECCFocusQueue",
      "is_active":true,"tab_title":"ECC-035","tty_name":"/dev/ttys027"}]
    """
  let processList = "30447 ttys027  codex\n"
  let lsof = """
    p30447
    n\(transcript.path)
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
  let invocations = await runner.specifications
  #expect(invocations.count == 3)
  #expect(invocations[2].arguments == ["-a", "-p", "30447", "-Fn"])
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

@Test("Running agent discovery inspects all processes in one batch")
func wezTermAgentDiscoveryIsBatched() async throws {
  let panes = """
    [{"window_id":11,"tab_id":20,"pane_id":33,"cwd":"file:///Users/hira/one",
      "tab_title":"One","tty_name":"/dev/ttys027"},
     {"window_id":12,"tab_id":21,"pane_id":34,"cwd":"file:///Users/hira/two",
      "tab_title":"Two","tty_name":"/dev/ttys029"}]
    """
  let processList = "30447 ttys027  codex\n64829 ttys029  codex\n"
  let lsof = """
    p30447
    n/Users/hira/.codex/thread-writer-locks/11111111-2222-3333-4444-555555555555.lock
    p64829
    n/Users/hira/.codex/thread-writer-locks/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.lock
    """
  let runner = MockProcessRunner(results: [
    ProcessResult(exitCode: 0, standardOutput: panes, standardError: "", timedOut: false),
    ProcessResult(exitCode: 0, standardOutput: processList, standardError: "", timedOut: false),
    ProcessResult(exitCode: 0, standardOutput: lsof, standardError: "", timedOut: false),
  ])

  let agents = try await WezTermController(runner: runner).listRunningAgents(
    configuration: WezTermConfiguration(executable: "/mock/wezterm")
  )
  let invocations = await runner.specifications

  #expect(agents.count == 2)
  #expect(invocations.count == 3)
  #expect(invocations[2].arguments == ["-a", "-p", "30447,64829", "-Fn"])
}

@Test("Running Codex discovery preserves a subagent identity and its canonical parent")
func wezTermCodexDiscoveryPreservesSubagentSession() async throws {
  let rootSessionID = "01a0696a-6348-79f0-8dbd-0c421c0bea7c"
  let subagentSessionID = "01a069ab-f291-75e2-836e-e9c47a86f0f6"
  let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
    "focus-queue-codex-sessions-\(UUID().uuidString)", isDirectory: true)
  let directory = fixtureRoot.appendingPathComponent(".codex/sessions", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: fixtureRoot) }
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let subagentURL = directory.appendingPathComponent("rollout-\(subagentSessionID).jsonl")
  let embeddedInstructions = String(repeating: "x", count: 70_000)
  try Data(
    """
    {"type":"session_meta","payload":{"id":"\(subagentSessionID)","session_id":"\(rootSessionID)","parent_thread_id":"\(rootSessionID)","source":{"subagent":{"thread_spawn":{"nickname":"registration-fix"}}},"base_instructions":"\(embeddedInstructions)"}}
    """.utf8
  ).write(to: subagentURL)

  let panes = """
    [{"window_id":11,"tab_id":20,"pane_id":33,"cwd":"file:///Users/test/project",
      "tab_title":"App Defect","tty_name":"/dev/ttys027"}]
    """
  let lsof = """
    p30447
    n\(fixtureRoot.path)/.codex/thread-writer-locks/\(subagentSessionID).lock
    n\(subagentURL.path)
    """
  let runner = MockProcessRunner(results: [
    ProcessResult(exitCode: 0, standardOutput: panes, standardError: "", timedOut: false),
    ProcessResult(
      exitCode: 0, standardOutput: "30447 ttys027  codex\n", standardError: "", timedOut: false),
    ProcessResult(exitCode: 0, standardOutput: lsof, standardError: "", timedOut: false),
  ])

  let agents = try await WezTermController(runner: runner).listRunningAgents(
    configuration: WezTermConfiguration(executable: "/mock/wezterm")
  )

  #expect(agents.map(\.sessionID) == [subagentSessionID])
  #expect(agents.map(\.parentSessionID) == [rootSessionID])
  #expect(agents.allSatisfy { $0.isSubagent })
  #expect(agents.map(\.promptHint) == ["registration fix"])
}

@Test("Running Codex discovery rejects multiple unrelated root sessions in one process")
func wezTermCodexDiscoveryRejectsAmbiguousRoots() async throws {
  let firstSessionID = "11111111-2222-4333-8444-555555555555"
  let secondSessionID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
  let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
    "focus-queue-codex-ambiguous-\(UUID().uuidString)", isDirectory: true)
  let directory = fixtureRoot.appendingPathComponent(".codex/sessions", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: fixtureRoot) }
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let firstURL = directory.appendingPathComponent("rollout-\(firstSessionID).jsonl")
  let secondURL = directory.appendingPathComponent("rollout-\(secondSessionID).jsonl")
  for (url, sessionID) in [(firstURL, firstSessionID), (secondURL, secondSessionID)] {
    try Data(
      """
      {"type":"session_meta","payload":{"id":"\(sessionID)","session_id":"\(sessionID)","source":"cli","thread_source":"user"}}
      """.utf8
    ).write(to: url)
  }
  let panes = """
    [{"window_id":11,"tab_id":20,"pane_id":33,"cwd":"file:///Users/test/project",
      "tab_title":"ECC-015","tty_name":"/dev/ttys027"}]
    """
  let lsof = """
    p30447
    n\(firstURL.path)
    n\(secondURL.path)
    """
  let runner = MockProcessRunner(results: [
    ProcessResult(exitCode: 0, standardOutput: panes, standardError: "", timedOut: false),
    ProcessResult(
      exitCode: 0, standardOutput: "30447 ttys027  codex\n", standardError: "", timedOut: false),
    ProcessResult(exitCode: 0, standardOutput: lsof, standardError: "", timedOut: false),
  ])

  let agents = try await WezTermController(runner: runner).listRunningAgents(
    configuration: WezTermConfiguration(executable: "/mock/wezterm")
  )

  #expect(agents.isEmpty)
}

@Test("Agent registration inbox persists and acknowledges a session")
func agentRegistrationInboxRoundTrip() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "focus-queue-agent-registration-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let inbox = AgentRegistrationInbox(directory: directory)
  let session = TaskAgentSession(
    ticketID: "ECC-035",
    provider: .codex,
    sessionID: "11111111-2222-3333-4444-555555555555",
    tabTitle: "ECC-035",
    workingDirectory: "/Users/test/worktree",
    paneID: 33
  )

  try await inbox.submit(session)
  #expect(try await inbox.pending() == [session])
  await inbox.acknowledge(try await inbox.pendingRecords())
  #expect(try await inbox.pending().isEmpty)
}

@Test("Agent registration inbox coalesces repeated identity publication")
func agentRegistrationInboxIsIdempotent() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "focus-queue-agent-registration-idempotent-\(UUID())", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let inbox = AgentRegistrationInbox(directory: directory)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let legacy = TaskAgentSession(
    ticketID: "ECC-035", provider: .codex,
    sessionID: "11111111-2222-3333-4444-555555555555",
    tabTitle: "Legacy", workingDirectory: "/Users/test/worktree", paneID: 32)
  try JSONEncoder().encode(legacy).write(
    to: directory.appendingPathComponent("\(legacy.id.uuidString).json"))
  for paneID in [33, 34] {
    try await inbox.submit(TaskAgentSession(
      ticketID: "ECC-035", provider: .codex,
      sessionID: "11111111-2222-3333-4444-555555555555",
      tabTitle: "Agent", workingDirectory: "/Users/test/worktree", paneID: paneID))
  }

  let pending = try await inbox.pending()
  #expect(pending.count == 1)
  #expect(pending.first?.paneID == 34)
}

@Test("Agent registration acknowledgement retains a newer stable-file generation")
func agentRegistrationInboxAcknowledgesExactGeneration() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "focus-queue-agent-registration-generation-\(UUID())", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let inbox = AgentRegistrationInbox(directory: directory)
  let sessionID = "11111111-2222-3333-4444-555555555555"
  try await inbox.submit(TaskAgentSession(
    ticketID: "ECC-035", provider: .codex, sessionID: sessionID,
    tabTitle: "First", workingDirectory: "/Users/test/worktree", paneID: 33))
  let firstGeneration = try await inbox.pendingRecords()

  try await inbox.submit(TaskAgentSession(
    ticketID: "ECC-035", provider: .codex, sessionID: sessionID,
    tabTitle: "Newer", workingDirectory: "/Users/test/worktree", paneID: 34))
  await inbox.acknowledge(firstGeneration)

  let retained = try await inbox.pending()
  #expect(retained.count == 1)
  #expect(retained.first?.tabTitle == "Newer")
  #expect(retained.first?.paneID == 34)
}

@Test("Agent registration inbox rejects redirected storage and uses private permissions")
func agentRegistrationInboxUsesPrivateStorage() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "focus-queue-agent-registration-private-\(UUID())", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let directory = root.appendingPathComponent("inbox", isDirectory: true)
  let session = TaskAgentSession(
    ticketID: "ECC-035", provider: .codex,
    sessionID: "11111111-2222-3333-4444-555555555555",
    tabTitle: "Private", workingDirectory: "/Users/test/worktree", paneID: 33)
  try await AgentRegistrationInbox(directory: directory).submit(session)
  let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
  let payload = try #require(try FileManager.default.contentsOfDirectory(
    at: directory, includingPropertiesForKeys: nil).first)
  let payloadMode = try FileManager.default.attributesOfItem(atPath: payload.path)[.posixPermissions] as? NSNumber
  #expect(directoryMode?.intValue == 0o700)
  #expect(payloadMode?.intValue == 0o600)

  let target = root.appendingPathComponent("target", isDirectory: true)
  let redirected = root.appendingPathComponent("redirected", isDirectory: true)
  try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
  try FileManager.default.createSymbolicLink(at: redirected, withDestinationURL: target)
  await #expect(throws: TaskContextError.self) {
    try await AgentRegistrationInbox(directory: redirected).submit(session)
  }
}

@Test("A registered route session publishes its canonical task row immediately")
func routedAgentRegistrationPublishesToInbox() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "focus-queue-routed-registration-\(UUID())", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = TaskContextStore(root: root)
  var context = try await store.ensureContext(ticket: DashboardTicket(
    id: "ECC-035", title: "Agent tracking", status: "open", summary: ""))
  let sessionID = UUID().uuidString.lowercased()
  var subtask = TaskSubtask(
    id: UUID().uuidString.lowercased(), title: "Register routed agents",
    assignmentDescription: "Publish the successor as soon as its identity is known.",
    provider: .codex, sessionID: sessionID)
  subtask.workspace = AgentWorkspace(path: "/Users/test/worktree", repositoryPath: "/Users/test")
  context = try await store.upsertSubtask(ticketID: context.ticketID, subtask: subtask)
  let inbox = AgentRegistrationInbox(
    directory: root.appendingPathComponent("agent-registrations", isDirectory: true))

  try await inbox.submitRegisteredSession(
    context: context, subtaskID: subtask.id, provider: .codex,
    sessionID: sessionID, supportDirectory: root)

  let published = try #require(try await inbox.pending().first)
  #expect(published.ticketID == "ECC-035")
  #expect(published.subtaskID == subtask.id)
  #expect(published.sessionID == sessionID)
  #expect(published.tabTitle == "Register routed agents")
}

@Test("A registered route replay republishes a missing pre-upgrade inbox record")
func registeredRouteReplayRepublishesCanonicalSession() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "focus-queue-routed-registration-replay-\(UUID())", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = TaskContextStore(root: root)
  var context = try await store.ensureContext(ticket: DashboardTicket(
    id: "ECC-035", title: "Agent tracking", status: "open", summary: ""))
  let sessionID = UUID().uuidString.lowercased()
  var subtask = TaskSubtask(
    id: UUID().uuidString.lowercased(), title: "Recover route publication",
    assignmentDescription: "Republish the canonical route registration.",
    provider: .codex, sessionID: sessionID)
  subtask.workspace = AgentWorkspace(path: "/Users/test/worktree", repositoryPath: "/Users/test")
  context = try await store.upsertSubtask(ticketID: context.ticketID, subtask: subtask)
  let receipt = AgentStartupReceipt(
    routeID: UUID().uuidString.lowercased(), status: .registered,
    taskID: context.ticketID, subtaskID: subtask.id,
    title: subtask.title, description: subtask.workDescription,
    provider: .codex, providerSessionID: sessionID,
    promptByteCount: 1, promptSHA256: AgentStartupReceipt.promptDigest("x"),
    workspace: try #require(subtask.workspace),
    context: .init(capsule: "/tmp/capsule", projectPlan: nil,
      taskPlan: context.planPath, taskContext: context.contextDirectory
        .appendingPathComponent("context.json").path,
      taskLog: context.contextDirectory.appendingPathComponent("agent-log.md").path),
    source: .init(cwd: "/Users/test/worktree"),
    orchestrationPreparedAt: Date(), handoffCompletedAt: Date())
  let inbox = AgentRegistrationInbox(
    directory: root.appendingPathComponent("agent-registrations", isDirectory: true))
  #expect(try await inbox.pending().isEmpty)

  try await inbox.republishRegisteredRoute(receipt, supportDirectory: root)

  let published = try #require(try await inbox.pending().first)
  #expect(published.ticketID == context.ticketID)
  #expect(published.subtaskID == subtask.id)
  #expect(published.sessionID == sessionID)
  #expect(published.tabTitle == subtask.title)
}

@Test("Agent terminal labels keep the task stable and distinguish the session")
func agentTerminalLabels() {
  let session = TaskAgentSession(
    ticketID: "ECC-015",
    provider: .codex,
    sessionID: "01a0696a-6348-79f0-8dbd-0c421c0bea7c",
    tabTitle: "App Defect",
    workingDirectory: "/Users/test/project"
  )

  #expect(session.terminalWindowTitle == "ECC-015")
  #expect(session.terminalTabTitle == "ECC-015 · Codex · 0bea7c")
  #expect(AgentTerminalLabels.tabTitle(ticketID: "ECC-015", paneID: 17) == "ECC-015 · Tab 17")
}

@Test("Agent terminal labels prefer a sanitized task name over the ticket ID")
func agentTerminalLabelsPreferTaskName() {
  let session = TaskAgentSession(
    ticketID: "ECC-015",
    provider: .codex,
    sessionID: "01a0696a-6348-79f0-8dbd-0c421c0bea7c",
    tabTitle: "App Defect",
    taskTitle: "Fix\tlogin   flow",
    workingDirectory: "/Users/test/project"
  )

  #expect(session.terminalWindowTitle == "Fix login flow")
  #expect(session.terminalTabTitle == "Fix login flow · Codex · 0bea7c")
  #expect(AgentTerminalLabels.managedTabTitle(ticketID: "ECC-015", taskTitle: "Fix login flow")
    == "Fix login flow · tmux")
  #expect(AgentTerminalLabels.windowTitle(ticketID: "ECC-015", taskTitle: "   ") == "ECC-015")
  #expect(AgentTerminalLabels.managedTabTitle(ticketID: "ecc-015", taskTitle: "") == "ECC-015 · tmux")
  let longTitle = String(repeating: "a", count: 200)
  #expect(AgentTerminalLabels.windowTitle(ticketID: "ECC-015", taskTitle: longTitle).count == 120)
}

@Test("One provider session can belong to only one ticket")
func agentSessionUpsertMovesAssociationAndCanonicalizesLabel() {
  let originalID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
  let original = TaskAgentSession(
    id: originalID,
    ticketID: "ECC-014",
    provider: .codex,
    sessionID: "01a0696a-6348-79f0-8dbd-0c421c0bea7c",
    tabTitle: "Old task",
    workingDirectory: "/Users/test/project",
    paneID: 33
  )
  let replacement = TaskAgentSession(
    ticketID: "ECC-015",
    provider: .codex,
    sessionID: original.sessionID,
    tabTitle: "App Defect",
    workingDirectory: "/Users/test/project",
    paneID: 33
  )
  var state = LocalState(agentSessions: [original])

  state.upsertAgentSession(replacement)

  #expect(state.agentSessions.count == 1)
  #expect(state.agentSessions.first?.id == originalID)
  #expect(state.agentSessions.first?.ticketID == "ECC-015")
  #expect(state.agentSessions.first?.tabTitle == "ECC-015 · Codex · 0bea7c")
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
  #expect(prompt.contains("read every configured project dashboard"))
  #expect(prompt.contains("Edit the selected dashboard only when"))
  #expect(prompt.contains("authorized to reorder tasks when the user requests it"))
  #expect(prompt.contains("focus-queue-session queue move"))
  #expect(prompt.contains("focus-queue-session projects list"))
  #expect(prompt.contains("focus-queue-session projects create"))
  #expect(prompt.contains("Projects are separate dashboards"))
  #expect(prompt.contains("Never substitute a category label or projectID field"))
  #expect(prompt.contains("Never hand-edit config.json or dashboards to create or move a project"))
  #expect(prompt.contains("Run `focus-queue-session projects list` afterward"))
  #expect(prompt.contains("Do not edit state.json"))
  #expect(prompt.contains("Current local deferred task IDs: ECC-009"))
  #expect(prompt.contains("Truth is a hard operational invariant"))
  #expect(prompt.contains("/Users/hira/.local/bin/focus-mail"))
  #expect(prompt.contains("Use the provider selected in ingestion settings"))
  #expect(prompt.lowercased().contains("do not use himalaya"))
  #expect(prompt.contains("MAIL_PROOF: <nonce>"))
  #expect(prompt.contains("/Users/hira/.local/bin/focus-discord"))
  #expect(prompt.contains("DISCORD_PROOF: <nonce>"))
  #expect(CodexQueueAgent.sessionName == "ecc-focus-queue-codex-v1")
  #expect(prompt.contains("<queue-user-message>"))
}

@Test("Whole-inbox Queue chat requests receive the bulk processing budget")
func codexQueueAgentBulkInboxTimeout() {
  #expect(CodexQueueAgent.runTimeoutSeconds(
    for: "Scan through my entire inbox so I can get caught up and add relevant tasks.",
    configuredTimeoutSeconds: 120
  ) == 600)
  #expect(CodexQueueAgent.runTimeoutSeconds(
    for: "Read my latest email.",
    configuredTimeoutSeconds: 120
  ) == 180)
  #expect(CodexQueueAgent.runTimeoutSeconds(
    for: "Why is ECC-002 second?",
    configuredTimeoutSeconds: 120
  ) == 120)
}

@Test("Daily report process errors preserve an actionable one-line cause")
func dailyReportProcessFailurePresentation() {
  let result = ProcessResult(
    exitCode: 1,
    standardOutput: "",
    standardError: "Focus Queue morning reconciliation failed:\nNo-tools classification rejected codex-cli 0.153.4\n",
    timedOut: false
  )

  let presentation = DailyReportAutomation.presentation(
    for: result,
    hasMatchingReport: false
  )

  #expect(presentation.isError)
  #expect(presentation.message.contains("classifier failed its safety or compatibility check"))
  #expect(!presentation.message.contains("codex-cli 0.153.4"))
  #expect(presentation.message.contains("retry automatically"))
  #expect(!presentation.message.contains("\n"))
}

@Test("Daily report UI does not expose multiline worker payloads")
func dailyReportProcessFailureRedactsRawPayload() {
  let presentation = DailyReportAutomation.presentation(
    for: ProcessResult(
      exitCode: 1,
      standardOutput: "",
      standardError: """
      Focus Queue morning reconciliation failed: {
        "error": "customer@example.com token=private-value"
      }
      """,
      timedOut: false
    ),
    hasMatchingReport: false
  )

  #expect(presentation.isError)
  #expect(presentation.message.contains("worker exited with code 1"))
  #expect(!presentation.message.contains("customer@example.com"))
  #expect(!presentation.message.contains("private-value"))
  #expect(!presentation.message.hasSuffix("}. It will retry automatically."))
}

@Test("Partial daily reports are warnings and remain eligible for retry")
func dailyReportPartialPresentation() {
  let result = ProcessResult(
    exitCode: 2,
    standardOutput: "REPORT_ID: 11111111-2222-3333-4444-555555555555",
    standardError: "",
    timedOut: false
  )

  let presentation = DailyReportAutomation.presentation(
    for: result,
    hasMatchingReport: true
  )

  #expect(presentation.isError)
  #expect(presentation.message.contains("partial platform coverage"))
  #expect(DailyReportStatus.partial.satisfiesDailySchedule == false)
  #expect(DailyReportStatus.success.satisfiesDailySchedule == true)
}

@Test("Daily report process presentation covers success, receipt, and timeout outcomes")
func dailyReportProcessOutcomePresentation() {
  let success = DailyReportAutomation.presentation(
    for: ProcessResult(
      exitCode: 0, standardOutput: "", standardError: "", timedOut: false),
    hasMatchingReport: true
  )
  let missingReceipt = DailyReportAutomation.presentation(
    for: ProcessResult(
      exitCode: 0, standardOutput: "", standardError: "", timedOut: false),
    hasMatchingReport: false
  )
  let timeout = DailyReportAutomation.presentation(
    for: ProcessResult(
      exitCode: -15, standardOutput: "", standardError: "", timedOut: true),
    hasMatchingReport: false
  )
  let emptyFailure = DailyReportAutomation.presentation(
    for: ProcessResult(
      exitCode: 7, standardOutput: "", standardError: "", timedOut: false),
    hasMatchingReport: false
  )

  #expect(success == .init(message: "Daily report completed.", isError: false))
  #expect(missingReceipt.message.contains("receipt validation failed"))
  #expect(missingReceipt.isError)
  #expect(timeout.message.contains("timed out after 15 minutes"))
  #expect(timeout.isError)
  #expect(emptyFailure.message.contains("worker exited with code 7"))
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
      "account":"reader@gmail.com",
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
  #expect(reply.message.contains("Verified mail evidence: reader@gmail.com"))
  #expect(reply.message.contains("<message@example.com>"))
}

@Test("Queue chat requires a search receipt for a generic inbox check")
func codexQueueAgentRejectsStatusProofForInboxCheck() async {
  let receipt = Data(
    """
    {
      "status":"ok",
      "verified":true,
      "operation":"status",
      "connector":"ecc-focus-mail-reader",
      "account":"haley@ecc.tools",
      "retrievedAt":"2026-09-03T00:50:43Z",
      "nonce":"proof-status"
    }
    """.utf8
  )
  let runner = MockProcessRunner(results: [
    ProcessResult(
      exitCode: 0,
      standardOutput: "Your inbox is clear.\nMAIL_PROOF: proof-status",
      standardError: "",
      timedOut: false
    )
  ])
  let agent = CodexQueueAgent(
    runner: runner,
    files: MockFileAccessor(data: receipt, modificationDate: .distantFuture)
  )

  do {
    _ = try await agent.send(
      message: "Check my inbox for anything new.",
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
    Issue.record("A status receipt incorrectly proved inbox search claims")
  } catch {
    #expect(error.localizedDescription.contains("performed status, not the required search"))
  }
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

@Test("Queue chat safely maps a blocked connector error when no mail proof exists")
func codexQueueAgentMapsBlockedMailError() async {
  let runner = MockProcessRunner(results: [
    ProcessResult(
      exitCode: 0,
      standardOutput: "Blocked. focus-mail failed: Operation not permitted.",
      standardError: "",
      timedOut: false
    )
  ])
  let agent = CodexQueueAgent(runner: runner)

  do {
    _ = try await agent.send(
      message: "Search my inbox.",
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
    Issue.record("Blocked mail connector error was not surfaced")
  } catch {
    #expect(error.localizedDescription.contains("denied access to a local process or file"))
    #expect(!error.localizedDescription.contains("Operation not permitted"))
    #expect(!error.localizedDescription.contains("did not provide current-turn"))
  }
}

@Test("Queue chat explains a timed-out Mail check with its actual budget")
func codexQueueAgentExplainsMailTimeout() async {
  let runner = MockProcessRunner(results: [
    ProcessResult(
      exitCode: -15,
      standardOutput: "",
      standardError: "",
      timedOut: true
    )
  ])
  let agent = CodexQueueAgent(runner: runner)

  do {
    _ = try await agent.send(
      message: "Check my recent email.",
      dashboardPath: "/tmp/dashboard.json",
      workspace: "/tmp",
      visibleOrder: [],
      deferredTicketIDs: [],
      configuration: VerifierConfiguration(
        enabled: true,
        executable: "/mock/focus-queue-codex",
        sessionName: "unused",
        timeoutSeconds: 120,
        maxTurns: 12
      )
    )
    Issue.record("Timed-out Mail check did not throw")
  } catch {
    #expect(error.localizedDescription.contains("Mail check timed out after 180 seconds"))
    #expect(error.localizedDescription.contains("retry"))
  }
}

@Test("Queue chat process failures expose only allowlisted diagnostics")
func codexQueueAgentRedactsRawProcessFailure() async {
  let runner = MockProcessRunner(results: [
    ProcessResult(
      exitCode: 7,
      standardOutput: "",
      standardError: "provider failed for customer@example.com token=private-value\n{\"secret\":true}",
      timedOut: false
    )
  ])
  let agent = CodexQueueAgent(runner: runner)

  do {
    _ = try await agent.send(
      message: "Why is ECC-002 second?",
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
    Issue.record("Failed Queue process did not throw")
  } catch {
    #expect(error.localizedDescription.contains("worker exited with code 7"))
    #expect(error.localizedDescription.contains("private Queue chat log"))
    #expect(!error.localizedDescription.contains("customer@example.com"))
    #expect(!error.localizedDescription.contains("private-value"))
    #expect(!error.localizedDescription.contains("secret"))
  }
}

@Test("Queue chat maps blocked Mail output without exposing raw content")
func codexQueueAgentRedactsBlockedMailOutput() async {
  let runner = MockProcessRunner(results: [
    ProcessResult(
      exitCode: 0,
      standardOutput: "Blocked. focus-mail failed: Operation not permitted. token=private-value",
      standardError: "",
      timedOut: false
    )
  ])
  let agent = CodexQueueAgent(runner: runner)

  do {
    _ = try await agent.send(
      message: "Search my inbox.",
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
    Issue.record("Blocked Mail output did not throw")
  } catch {
    #expect(error.localizedDescription.contains("denied access to a local process or file"))
    #expect(!error.localizedDescription.contains("private-value"))
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
  #expect(invocations.count == 5)
  #expect(invocations[1].arguments == [
    "cli", "set-tab-title", "--pane-id", "17", "ECC-035 · Tab 17",
  ])
  #expect(invocations[2].arguments == [
    "cli", "set-window-title", "--pane-id", "17", "ECC-035",
  ])
  #expect(invocations[3].arguments == ["cli", "activate-pane", "--pane-id", "17"])
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
    "cli", "set-tab-title", "--pane-id", "22", "ECC-035 · Tab 22",
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
    placement: .upperRight,
    topMargin: 4
  )
  let centered = DisplayGeometry.panelFrame(
    preferredWidth: 900,
    visibleFrame: CGRect(x: -1_920, y: 0, width: 1_920, height: 1_080),
    placement: .center
  )

  #expect(compactDisplay.contains(right))
  #expect(right == CGRect(x: 1_568, y: -8, width: 620, height: 484))
  #expect(right.minY == compactDisplay.minY + 12)
  #expect(right.maxY == compactDisplay.maxY - 4)
  #expect(centered.midX == -960)
  #expect(centered.width == 620)
}

@Test("Expanded report panels stay anchored to their queue edge")
func expandedDailyReportPanelAnchoring() {
  let display = CGRect(x: 0, y: 0, width: 1_440, height: 900)
  let left = DisplayGeometry.panelFrame(
    preferredWidth: 1_000,
    visibleFrame: display,
    placement: .upperLeft,
    maximumWidth: 1_200
  )
  let narrow = DisplayGeometry.panelFrame(
    preferredWidth: 600,
    visibleFrame: CGRect(x: 0, y: 0, width: 760, height: 900),
    placement: .upperRight,
    minimumWidth: 790,
    maximumWidth: 1_200
  )
  let right = DisplayGeometry.panelFrame(
    preferredWidth: 1_000,
    visibleFrame: display,
    placement: .upperRight,
    maximumWidth: 1_200
  )

  #expect(left.minX == 12)
  #expect(right.maxX == display.maxX - 12)
  #expect(left.width == 1_000)
  #expect(right.width == 1_000)
  #expect(narrow.width == 736)
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

@Test("Terminal browsing activates only the selected pane and preserves all labels")
func browseExactTerminal() async throws {
  let pane = WezTermPane(windowID: 7, tabID: 8, paneID: 9, cwd: "file:///tmp/work", ttyName: "/dev/ttys010")
  let json = String(decoding: try JSONEncoder().encode([pane]), as: UTF8.self)
  let runner = MockProcessRunner(results: [ProcessResult(exitCode: 0, standardOutput: json, standardError: "", timedOut: false)])
  try await WezTermController(runner: runner).focusPane(pane, configuration: WezTermConfiguration(executable: "/mock/wezterm"))
  let calls = await runner.specifications
  #expect(calls.count == 3)
  #expect(calls[1].arguments == ["cli", "activate-pane", "--pane-id", "9"])
  #expect(calls[2].executable == "/usr/bin/open")
  #expect(!calls.flatMap(\.arguments).contains("set-tab-title"))
  #expect(!calls.flatMap(\.arguments).contains("spawn"))
  #expect(!calls.flatMap(\.arguments).contains("kill-pane"))
}

@Test("Terminal browsing rejects a stale pane before any activation")
func browseRejectsStaleTerminal() async throws {
  let pane = WezTermPane(windowID: 7, tabID: 8, paneID: 9, cwd: "file:///tmp/work", ttyName: "/dev/ttys010")
  let changed = WezTermPane(windowID: 7, tabID: 8, paneID: 9, cwd: "file:///tmp/work", ttyName: "/dev/ttys011")
  let json = String(decoding: try JSONEncoder().encode([changed]), as: UTF8.self)
  let runner = MockProcessRunner(results: [ProcessResult(exitCode: 0, standardOutput: json, standardError: "", timedOut: false)])
  await #expect(throws: WezTermError.self) {
    try await WezTermController(runner: runner).focusPane(pane, configuration: WezTermConfiguration(executable: "/mock/wezterm"))
  }
  #expect(await runner.specifications.count == 1)
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
  func removeItem(at url: URL) throws {}
}
