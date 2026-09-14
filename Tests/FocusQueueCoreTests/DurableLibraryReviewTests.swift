import Foundation
import Testing

@testable import FocusQueueCore

@Suite("Durable library assignment review")
struct DurableLibraryReviewTests {
  private func context(root: URL, ticketID: String, sessionID: String?) throws -> TaskContext {
    let folder = root.appendingPathComponent("tasks/\(ticketID)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let plan = folder.appendingPathComponent("plan.md")
    try Data("# \(ticketID) plan".utf8).write(to: plan)
    return TaskContext(ticketID: ticketID, title: ticketID, summary: "Review assignment history",
      successCriteria: "Preserve history while ending previous current bindings", planPath: plan.path,
      worktreePath: root.path,
      subtasks: [TaskSubtask(id: "implementation", title: "Implementation", sessionID: sessionID)],
      updatedAt: Date(timeIntervalSince1970: 100))
  }

  @Test("Context reassignment and detachment end only prior bindings for that task")
  func contextAssignmentLifecycle() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("library-review-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let firstNative = "11111111-1111-4111-8111-111111111111"
    let secondNative = "22222222-2222-4222-8222-222222222222"
    var first = try context(root: root, ticketID: "ECC-801", sessionID: firstNative)
    let unrelated = try context(root: root, ticketID: "ECC-802", sessionID: "33333333-3333-4333-8333-333333333333")
    let store = DurableLibraryStore(root: root)
    _ = try await store.reconcile(contexts: [first, unrelated])
    let original = try await store.snapshot()
    let taskID = try #require(original.tasks.first(where: { $0.ticketID == "ECC-801" })?.id)
    let firstID = try #require(original.sessions.first(where: { $0.nativeSessionID == firstNative })?.id)
    first.subtasks[0].sessionID = secondNative
    first.updatedAt = Date(timeIntervalSince1970: 200)
    _ = try await store.reconcile(contexts: [first])
    var library = try await store.snapshot()
    let assigned = library.assignments.filter { $0.taskID == taskID && $0.source == "task-context" }
    #expect(assigned.count == 2)
    #expect(assigned.first(where: { $0.sessionID == firstID })?.endedAt != nil)
    #expect(assigned.filter { $0.endedAt == nil }.count == 1)
    #expect(library.assignments.contains { $0.taskID != taskID && $0.source == "task-context" && $0.endedAt == nil })

    first.subtasks[0].sessionID = nil
    first.updatedAt = Date(timeIntervalSince1970: 300)
    let detached = try await store.reconcile(contexts: [first])
    let repeated = try await store.reconcile(contexts: [first])
    library = try await store.snapshot()
    #expect(detached == repeated)
    #expect(library.assignments.filter { $0.taskID == taskID && $0.source == "task-context" }.allSatisfy { $0.endedAt != nil })
    #expect(library.sessions.count == 3)
    #expect(library.assignments.contains { $0.taskID != taskID && $0.endedAt == nil })
  }

  @Test("Removing a subtask ends its current assignment while retaining its history")
  func removedSubtaskRetainsHistory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("library-review-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    var current = try context(root: root, ticketID: "ECC-803", sessionID: "44444444-4444-4444-8444-444444444444")
    let store = DurableLibraryStore(root: root)
    _ = try await store.reconcile(contexts: [current])
    let before = try await store.snapshot()
    current.subtasks = []
    current.updatedAt = Date(timeIntervalSince1970: 200)
    _ = try await store.reconcile(contexts: [current])
    let after = try await store.snapshot()
    #expect(after.assignments.count == 1)
    #expect(after.assignments[0].endedAt != nil)
    #expect(!after.assignments[0].isCurrent)
    #expect(after.assignments[0].id == before.assignments[0].id)
    #expect(after.sessions == before.sessions)
    #expect(after.tasks[0].subtasks[0].id == before.tasks[0].subtasks[0].id)
    #expect(!after.tasks[0].subtasks[0].isCurrent)
  }

  @Test("Reimport through filesystem aliases preserves messages outside the active cache")
  func conversationAliasMerge() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("library-review-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let current = try context(root: root, ticketID: "ECC-804", sessionID: nil)
    let taskFolder = root.appendingPathComponent("tasks/ECC-804")
    try JSONEncoder().encode(current).write(to: taskFolder.appendingPathComponent("context.json"))
    let full = [["id": "old-message", "text": "Retain me"], ["id": "recent-message", "text": "Recent"]]
    let store = DurableLibraryStore(root: root)
    try await store.captureConversation(data: JSONSerialization.data(withJSONObject: full), ticketID: "ECC-804")
    try JSONSerialization.data(withJSONObject: Array(full.suffix(1)))
      .write(to: taskFolder.appendingPathComponent("conversation.json"))
    // macOS enumeration commonly returns /private/var while the supplied
    // temporary root is /var. Both names must find the same retained document.
    _ = try await store.reconcile()
    let library = try await store.snapshot()
    let conversations = library.documents.filter { $0.kind == "conversation" }
    #expect(conversations.count == 1)
    let latest = try #require(conversations.first?.revisions.last)
    let retained = try #require(JSONSerialization.jsonObject(with:
      Data(contentsOf: store.directory.appendingPathComponent(latest.blobPath))) as? [[String: String]])
    #expect(retained.map { $0["id"] } == ["old-message", "recent-message"])
    let before = try await store.summary()
    #expect(try await store.reconcile() == before)
  }

  @Test("Restore rejects broken report and subtask relationships before creating a destination",
        arguments: ["report-document", "unknown-subtask", "other-task-subtask"])
  func invalidRestoreRelationships(relationship: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("library-review-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try context(root: root, ticketID: "ECC-805", sessionID: "55555555-5555-4555-8555-555555555555")
    let other = try context(root: root, ticketID: "ECC-806", sessionID: "66666666-6666-4666-8666-666666666666")
    let store = DurableLibraryStore(root: root)
    _ = try await store.reconcile(contexts: [first, other])
    let exported = root.appendingPathComponent("export")
    try await store.export(to: exported)
    var malformed = try await store.snapshot()
    if relationship == "report-document" {
      malformed.reportRuns.append(LibraryReportRun(id: UUID(), nativeRunID: "invalid-report",
        reportDate: nil, status: "success", documentID: UUID()))
    } else if relationship == "unknown-subtask" {
      malformed.assignments[0].subtaskID = UUID()
    } else {
      let otherTask = try #require(malformed.tasks.first(where: { $0.id != malformed.assignments[0].taskID }))
      malformed.assignments[0].subtaskID = try #require(otherTask.subtasks.first?.id)
    }
    try JSONEncoder().encode(malformed).write(to: exported.appendingPathComponent("manifest.json"))
    let destination = root.appendingPathComponent("restored")
    #expect(throws: DurableLibraryError.self) { try DurableLibraryStore.restore(from: exported, to: destination) }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
  }
}
