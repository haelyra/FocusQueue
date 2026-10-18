import Foundation
import Testing
@testable import FocusQueueCore

@Test func taskBriefKeepsSourceSentencesAndPreservesFullDescription() {
  let source = "First outcome. Second detail. Third detail. Fourth detail. Fifth detail."
  let ticket = DashboardTicket(id: "ECC-1", title: "Title", status: "open", summary: source)
  #expect(ticket.briefSummary == "First outcome. Second detail. Third detail.")
  #expect(ticket.summary == source)
  let empty = DashboardTicket(id: "ECC-2", title: "Fallback", status: "open", summary: " ")
  #expect(empty.briefSummary == "Fallback")
}

@Test func taskKindHandlesLegacyAndExplicitMetadata() {
  for (raw, expected) in [("recurring", QueueTaskKind.longRunning), ("subtask", .subtask),
                          ("customer-concern", .customerConcern), ("future-type", .task)] {
    let ticket = DashboardTicket(id: "ECC-1", title: "Title", status: "open", summary: "", taskType: raw)
    #expect(ticket.queueTaskKind == expected)
  }
}

@Test func embeddedDocumentsRejectExecutableNavigation() {
  for raw in ["javascript:alert(1)", "data:text/html,test", "shell:rm"] {
    #expect(!EmbeddedDocumentPolicy.allowsLink(URL(string: raw)!))
  }
  #expect(EmbeddedDocumentPolicy.allowsLink(URL(string: "https://example.com/plan")!))
  #expect(EmbeddedDocumentPolicy.allowsLink(URL(fileURLWithPath: "/tmp/plan.md")))
}

@Test func dashboardDatesDecodeCompatiblyAndHardDeadlineWins() throws {
  let legacy = try JSONDecoder().decode(DashboardTicket.self, from: Data(#"{"id":"ECC-1","title":"Legacy","status":"open","summary":""}"#.utf8))
  #expect(legacy.createdAt == nil)
  #expect(legacy.dueDate == nil)
  #expect(legacy.dueDateSource == nil)

  let ticket = DashboardTicket(
    id: "ECC-2", title: "Dated", status: "open", summary: "",
    updatedAt: "2026-10-18", createdAt: "2026-10-01",
    dueDate: "2026-10-20", dueDateSource: "User specified")
  let decoded = try JSONDecoder().decode(DashboardTicket.self, from: JSONEncoder().encode(ticket))
  #expect(decoded == ticket)
  #expect(TaskTriagePolicy.dateOnlyString(for: TaskTriagePolicy.hardDeadline(for: ticket)!) == "2026-10-20")
  #expect(TaskTriagePolicy.relativeDeadline(for: ticket) == nil)
}

@Test func relativeTriageUsesPriorityCadenceAndExclusions() {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(secondsFromGMT: 0)!
  for (priority, expected) in [("critical", "2026-10-19"), ("high", "2026-10-20"),
                               ("medium", "2026-10-22"), ("low", "2026-10-25")] {
    let ticket = DashboardTicket(
      id: "ECC-\(priority)", title: priority, priority: priority,
      status: "open", summary: "", updatedAt: "2026-10-18")
    let deadline = TaskTriagePolicy.relativeDeadline(for: ticket, calendar: calendar)
    #expect(deadline != nil)
    #expect(TaskTriagePolicy.dateOnlyString(for: deadline!) == expected)
  }

  let recurring = DashboardTicket(
    id: "ECC-recurring", title: "Recurring", status: "open", summary: "",
    updatedAt: "2026-10-18", taskType: "long-running")
  let completed = DashboardTicket(
    id: "ECC-complete", title: "Complete", status: "resolved", summary: "", updatedAt: "2026-10-18")
  #expect(TaskTriagePolicy.relativeDeadline(for: recurring) == nil)
  #expect(TaskTriagePolicy.relativeDeadline(for: completed) == nil)
}

@Test func deadlineOrderingSurfacesOlderWorkBeforeLaterPriorities() {
  let oldLow = DashboardTicket(
    id: "ECC-low", title: "Old low", priority: "low", status: "open", summary: "", updatedAt: "2026-10-01")
  let critical = DashboardTicket(
    id: "ECC-critical", title: "Critical", priority: "critical", status: "open", summary: "", updatedAt: "2026-10-18")
  let hard = DashboardTicket(
    id: "ECC-hard", title: "Hard", priority: "high", status: "open", summary: "", dueDate: "2026-10-20")
  let recurring = DashboardTicket(
    id: "ECC-recurring", title: "Recurring", priority: "critical", status: "open", summary: "",
    updatedAt: "2026-10-18", taskType: "long-running")
  let ordered = TaskTriagePolicy.deadlineOrdered([hard, recurring, critical, oldLow])
  #expect(ordered.map(\.id) == ["ECC-low", "ECC-critical", "ECC-hard", "ECC-recurring"])

  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(secondsFromGMT: 0)!
  let now = TaskTriagePolicy.date(from: "2026-10-18")!
  #expect(TaskTriagePolicy.hardDeadlineIsOverdue(for: hard, now: now, calendar: calendar) == false)
  let overdue = DashboardTicket(id: "ECC-overdue", title: "Overdue", status: "open", summary: "", dueDate: "2026-10-17")
  #expect(TaskTriagePolicy.hardDeadlineIsOverdue(for: overdue, now: now, calendar: calendar))
}

// MARK: - Agent view ordering

@Test func agentViewOrderingRanksAttentionThenUnreadThenWorkingThenProblems() {
  func rank(_ status: TaskSubtaskStatus, _ attention: AgentAttention? = nil,
            unread: Bool = false, error: String? = nil) -> Int {
    AgentViewOrdering.rank(status: status, attention: attention,
                           completionUnread: unread, sessionError: error)
  }
  // 0: needs user input
  #expect(rank(.idle, .question) == 0)
  #expect(rank(.working, .approval) == 0)
  // 1: result to review
  #expect(rank(.completed, unread: true) == 1)
  #expect(rank(.working, unread: true) == 1)
  // 2: working
  #expect(rank(.working) == 2)
  // 3: interrupted and other problems, including session errors
  #expect(rank(.idle, .interrupted) == 3)
  #expect(rank(.blocked, .incomplete) == 3)
  #expect(rank(.idle, .failed) == 3)
  #expect(rank(.idle, error: "session lost") == 3)
  // 4: idle or output viewed
  #expect(rank(.idle) == 4)
  #expect(rank(.completed) == 4)
  // 5: everything else
  #expect(rank(.queued) == 5)
  #expect(rank(.blocked) == 5)
}

@Test func agentViewOrderingSortsByRankThenMostRecentActivity() {
  struct Row { let name: String; let rank: Int; let activity: Date? }
  let now = Date()
  let rows = [
    Row(name: "idle-old", rank: 4, activity: now.addingTimeInterval(-3600)),
    Row(name: "question", rank: 0, activity: now.addingTimeInterval(-7200)),
    Row(name: "queued", rank: 5, activity: now),
    Row(name: "unread", rank: 1, activity: nil),
    Row(name: "idle-new", rank: 4, activity: now.addingTimeInterval(-60)),
    Row(name: "working", rank: 2, activity: now.addingTimeInterval(-10_000)),
    Row(name: "interrupted", rank: 3, activity: now),
  ]
  let ordered = AgentViewOrdering.ordered(rows, rank: \.rank, activity: \.activity)
  #expect(ordered.map(\.name) == [
    "question", "unread", "working", "interrupted", "idle-new", "idle-old", "queued",
  ])
}
