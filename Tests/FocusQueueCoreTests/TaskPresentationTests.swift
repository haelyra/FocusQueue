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
