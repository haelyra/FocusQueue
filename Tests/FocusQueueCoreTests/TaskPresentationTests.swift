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
