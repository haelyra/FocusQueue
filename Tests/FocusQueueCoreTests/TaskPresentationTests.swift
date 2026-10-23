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

@Test func agentViewActivityCountsOutputAndOpenAttentionRequests() {
  let output = Date(timeIntervalSince1970: 1_000)
  let later = Date(timeIntervalSince1970: 2_000)
  // Output wins when nothing is waiting on the user.
  #expect(AgentViewOrdering.activityDate(
    lastOutputAt: output, resultAt: nil, attention: nil, lastHeartbeatAt: later) == output)
  // A result stands in for missing output.
  #expect(AgentViewOrdering.activityDate(
    lastOutputAt: nil, resultAt: output, attention: nil, lastHeartbeatAt: later) == output)
  // An open question stamps only the heartbeat, which then counts.
  #expect(AgentViewOrdering.activityDate(
    lastOutputAt: output, resultAt: nil, attention: .question, lastHeartbeatAt: later) == later)
  #expect(AgentViewOrdering.activityDate(
    lastOutputAt: nil, resultAt: nil, attention: .approval, lastHeartbeatAt: later) == later)
  #expect(AgentViewOrdering.activityDate(
    lastOutputAt: nil, resultAt: nil, attention: nil, lastHeartbeatAt: later) == nil)
}

@Test func agentViewGroupsTasksAndAgentsByMostRecentActivity() {
  struct Agent { let name: String; let activity: Date? }
  let now = Date()
  let groups: [(group: String, items: [Agent])] = [
    ("stale", [Agent(name: "s1", activity: now.addingTimeInterval(-3600))]),
    ("empty", []),
    ("busy", [
      Agent(name: "b-old", activity: now.addingTimeInterval(-600)),
      Agent(name: "b-none", activity: nil),
      Agent(name: "b-new", activity: now),
    ]),
    ("silent", [Agent(name: "q1", activity: nil), Agent(name: "q2", activity: nil)]),
    ("middle", [Agent(name: "m1", activity: now.addingTimeInterval(-60))]),
  ]
  let ordered = AgentViewOrdering.grouped(groups, activity: \.activity)
  #expect(ordered.map(\.group) == ["busy", "middle", "stale", "silent"])
  #expect(ordered[0].items.map(\.name) == ["b-new", "b-old", "b-none"])
  // Ties keep the input order.
  #expect(ordered[3].items.map(\.name) == ["q1", "q2"])
}

@Test func statusMenuOffersOpenWorkflowStatusesAndKeepsACustomCurrentValue() {
  #expect(TaskFieldChoices.statusOptions(current: "In-Progress") == TaskFieldChoices.openStatuses)
  #expect(TaskFieldChoices.statusOptions(current: "draft-pr").last == "draft-pr")
  #expect(!TaskFieldChoices.statusOptions(current: "resolved").contains("resolved"))
  #expect(TaskFieldChoices.openStatuses.allSatisfy {
    DashboardTicket(id: "ECC-1", title: "T", status: $0, summary: "").isOpen
  })
  #expect(TaskFieldChoices.statusLabel("in-progress") == "In progress")
  #expect(TaskFieldChoices.statusLabel("qa") == "QA")
}
