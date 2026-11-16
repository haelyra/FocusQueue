import Foundation
import Testing
@testable import FocusQueueCore

private func reviewFixture(tasks: [String] = ["FOC-1", "FOC-2"]) throws -> (URL, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("priority-reviews-\(UUID().uuidString)")
    for task in tasks {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("tasks/\(task)"), withIntermediateDirectories: true)
    }
    let document = root.appendingPathComponent("tasks/FOC-1/evidence/design.md")
    try FileManager.default.createDirectory(at: document.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("# Design\n".utf8).write(to: document)
    return (root, document)
}

@Test("A proposal waits for approval, then shows in the queue until it is done")
func priorityReviewLifecycle() throws {
    let (root, document) = try reviewFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = PriorityReviewStore(root: root)

    let proposed = try store.propose(taskID: "foc-1", agentID: "A1", document: document, title: nil,
                                     reason: "Pick the storage engine", priority: .high)
    #expect(proposed.status == .proposed && proposed.taskID == "FOC-1" && proposed.title == "design")
    var split = PriorityReviewStore.partition(store.allReviews(), openTaskIDs: ["FOC-1"])
    #expect(split.visible.isEmpty && split.proposed.map(\.id) == [proposed.id])

    // A repeat proposal of the same document refreshes it instead of duplicating it.
    let again = try store.propose(taskID: "FOC-1", agentID: "A1", document: document, title: "Storage choice",
                                  reason: "Pick the storage engine today", priority: .critical)
    #expect(again.id == proposed.id && store.reviews(taskID: "FOC-1").count == 1 && again.priority == .critical)

    let approved = try store.approve(taskID: "FOC-1", reviewID: proposed.id.lowercased(), by: "agent:ORCH")
    #expect(approved.status == .approved && approved.approvedBy == "agent:ORCH" && approved.approvedAt != nil)
    split = PriorityReviewStore.partition(store.allReviews(), openTaskIDs: ["FOC-1"])
    #expect(split.visible.map(\.id) == [proposed.id] && split.proposed.isEmpty)
    // A closed task's reviews leave the queue.
    #expect(PriorityReviewStore.partition(store.allReviews(), openTaskIDs: []).visible.isEmpty)

    let done = try store.resolve(taskID: "FOC-1", reviewID: proposed.id, as: .done)
    #expect(done.status == .done && done.resolvedAt != nil)
    #expect(PriorityReviewStore.partition(store.allReviews(), openTaskIDs: ["FOC-1"]).visible.isEmpty)
    #expect(throws: PriorityReviewError.self) {
        try store.approve(taskID: "FOC-1", reviewID: proposed.id, by: "human")
    }
}

@Test("The queue shows at most five approved reviews, highest priority first")
func priorityReviewLimitAndOrder() throws {
    let (root, _) = try reviewFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = PriorityReviewStore(root: root)
    let levels: [PriorityReviewLevel] = [.low, .medium, .high, .critical, .medium, .high, .low]
    let start = Date(timeIntervalSince1970: 1_000)
    for (index, level) in levels.enumerated() {
        let task = index.isMultiple(of: 2) ? "FOC-1" : "FOC-2"
        let file = root.appendingPathComponent("tasks/\(task)/doc-\(index).md")
        try Data("x".utf8).write(to: file)
        try store.propose(taskID: task, agentID: "A", document: file, title: "doc-\(index)", reason: "why",
                          priority: level, approved: true, approvedBy: "agent:O",
                          now: start.addingTimeInterval(Double(index)))
    }
    let split = PriorityReviewStore.partition(store.allReviews(), openTaskIDs: ["FOC-1", "FOC-2"])
    #expect(split.visible.count == PriorityReviewStore.visibleLimit)
    #expect(split.visible.map(\.title) == ["doc-3", "doc-2", "doc-5", "doc-1", "doc-4"])
    #expect(split.waiting.map(\.title) == ["doc-0", "doc-6"])
}

@Test("Proposals need an existing document, a reason, and an existing task")
func priorityReviewValidation() throws {
    let (root, document) = try reviewFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = PriorityReviewStore(root: root)
    #expect(throws: PriorityReviewError.self) {
        try store.propose(taskID: "FOC-1", agentID: "A", document: root.appendingPathComponent("missing.md"),
                          title: nil, reason: "why", priority: .high)
    }
    #expect(throws: PriorityReviewError.self) {
        try store.propose(taskID: "FOC-1", agentID: "A", document: document, title: nil, reason: "  ", priority: .high)
    }
    #expect(throws: PriorityReviewError.self) {
        try store.propose(taskID: "FOC-9", agentID: "A", document: document, title: nil, reason: "why", priority: .high)
    }
    #expect(throws: PriorityReviewError.self) {
        try store.propose(taskID: "../x", agentID: "A", document: document, title: nil, reason: "why", priority: .high)
    }
}

@Test("A bare review ID resolves to the one task that has it")
func priorityReviewTarget() throws {
    let (root, document) = try reviewFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = PriorityReviewStore(root: root)
    let review = try store.propose(taskID: "FOC-1", agentID: "A", document: document, title: nil,
                                   reason: "why", priority: .medium)
    let target = try PriorityReviewCommand.target([review.id], store: store, envTask: "FOC-2")
    #expect(target.0 == "FOC-1" && target.1 == review.id)
    #expect(throws: PriorityReviewError.self) {
        _ = try PriorityReviewCommand.target(["RZZZZ"], store: store, envTask: nil)
    }
}
