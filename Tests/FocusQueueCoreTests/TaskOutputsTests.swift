import Foundation
import Testing
@testable import FocusQueueCore

private func outputsFixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("focus-outputs-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func write(_ relativePath: String, in directory: URL, modified: Date = Date()) throws {
    let url = directory.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("content".utf8).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
}

@Test("Agent files anywhere in the context folder are outputs; Focus Queue records are not")
func taskOutputsScanSkipsRecords() throws {
    let folder = try outputsFixture(); defer { try? FileManager.default.removeItem(at: folder) }
    for record in ["plan.md", "data.md", "agent-log.md", "initial-prompt.md", "context.json", "maintenance.json",
                   "cleanup.json", "conversation.json", "plan-draft.json", ".lock", "context.json.pre-repair",
                   "completion-review-1.json", "archive/plan-1.md", "maintenance-history/a.json",
                   "push-reviews/r.json", "workspace-map/snapshot.json", "architecture/index.generated.md",
                   ".hidden/notes.md"] {
        try write(record, in: folder)
    }
    let now = Date()
    try write("roadmap.md", in: folder, modified: now.addingTimeInterval(-60))
    try write("evidence/report.pdf", in: folder, modified: now)
    try write("qa/screens/render-dark.png", in: folder, modified: now.addingTimeInterval(-120))

    let outputs = TaskOutputs.scan(folder)
    #expect(outputs.map(\.relativePath) == ["evidence/report.pdf", "roadmap.md", "qa/screens/render-dark.png"])
    #expect(outputs.first?.url.path == folder.appendingPathComponent("evidence/report.pdf").standardizedFileURL.path)
    #expect(TaskOutputs.scan(folder, limit: 1).count == 1)
}

@Test("An output is new until reviewed, again after an edit, and never once it is stale")
func taskOutputsNewness() {
    let now = Date()
    let output = TaskOutputFile(relativePath: "evidence/report.pdf",
        url: URL(fileURLWithPath: "/tmp/evidence/report.pdf"), modifiedAt: now.addingTimeInterval(-600))
    #expect(TaskOutputs.isNew(output, reviewed: nil, now: now))
    #expect(!TaskOutputs.isNew(output, reviewed: [output.relativePath: output.modifiedAt], now: now))
    // A JSON round trip may shave sub-second precision; that is not an edit.
    #expect(!TaskOutputs.isNew(output, reviewed: [output.relativePath: output.modifiedAt.addingTimeInterval(-0.0001)], now: now))
    #expect(TaskOutputs.isNew(output, reviewed: [output.relativePath: output.modifiedAt.addingTimeInterval(-300)], now: now))
    let stale = TaskOutputFile(relativePath: "old.md", url: URL(fileURLWithPath: "/tmp/old.md"),
        modifiedAt: now.addingTimeInterval(-TaskOutputs.freshness - 1))
    #expect(!TaskOutputs.isNew(stale, reviewed: nil, now: now))
}

@Test("Reviewing outputs persists in context.json and forgets deleted files")
func taskOutputsReviewPersists() async throws {
    let root = try outputsFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let store = TaskContextStore(root: root)
    let ticket = DashboardTicket(id: "ECC-950", title: "Show agent outputs", status: "in-progress", summary: "Surface files.")
    let context = try await store.ensureContext(ticket: ticket)
    try write("evidence/report.pdf", in: context.contextDirectory)
    try write("notes.md", in: context.contextDirectory)
    let outputs = TaskOutputs.scan(context.contextDirectory)
    #expect(context.newOutputs(outputs).count == 2)

    let report = try #require(outputs.first { $0.relativePath == "evidence/report.pdf" })
    let reviewed = try await store.markOutputsReviewed(ticketID: ticket.id, outputs: [report])
    #expect(reviewed.newOutputs(outputs).map(\.relativePath) == ["notes.md"])
    let reloaded = try #require(try await store.load(ticketID: ticket.id))
    #expect(reloaded.newOutputs(outputs).map(\.relativePath) == ["notes.md"])

    try FileManager.default.removeItem(at: report.url)
    let notes = try #require(outputs.first { $0.relativePath == "notes.md" })
    let pruned = try await store.markOutputsReviewed(ticketID: ticket.id, outputs: [notes])
    #expect(pruned.reviewedOutputs?.keys.sorted() == ["notes.md"])
}
