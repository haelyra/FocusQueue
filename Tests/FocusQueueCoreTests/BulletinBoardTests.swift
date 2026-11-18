import Foundation
import Testing
@testable import FocusQueueCore

@Suite("Bulletin board pins")
struct BulletinBoardTests {
  private func lookup(existing: Set<String> = []) -> BulletinPinLookup {
    var archived = TaskSubtask(id: "A-ARCHIVED", title: "Archived")
    archived.agentRemovedAt = Date()
    var merged = TaskSubtask(id: "A-MERGED", title: "Merged")
    merged.mergedIntoSubtaskID = "A-LIVE"
    var context = TaskContext(ticketID: "FOC-1", title: "Open", summary: "", successCriteria: "",
      planPath: "/tmp/plan.md", updatedAt: Date())
    context.subtasks = [TaskSubtask(id: "A-LIVE", title: "Live"), archived, merged]
    return BulletinPinLookup(
      tickets: [
        "FOC-1": DashboardTicket(id: "FOC-1", title: "Open", projectID: "p1", status: "in-progress", summary: ""),
        "FOC-2": DashboardTicket(id: "FOC-2", title: "Done", projectID: "p1", status: "resolved", summary: ""),
        "FOC-3": DashboardTicket(id: "FOC-3", title: "Dropped", projectID: "p2", status: "cancelled", summary: ""),
        "FOC-4": DashboardTicket(id: "FOC-4", title: "Unloaded", projectID: "p2", status: "backlog", summary: ""),
      ],
      contexts: ["FOC-1": context],
      fileExists: { existing.contains($0) })
  }

  private func task(_ id: String, project: String = "p1") -> BulletinPin {
    BulletinPin(kind: .task, projectID: project, taskID: id, title: id)
  }

  private func agent(_ taskID: String, _ subtaskID: String) -> BulletinPin {
    BulletinPin(kind: .agent, projectID: "p1", taskID: taskID, subtaskID: subtaskID, title: subtaskID)
  }

  @Test("Resolved, cancelled, and deleted tasks are cleaned up; open tasks stay")
  func taskRule() {
    let facts = lookup()
    #expect(!BulletinBoardRules.isCleanedUp(task("FOC-1"), lookup: facts))
    #expect(BulletinBoardRules.isCleanedUp(task("FOC-2"), lookup: facts))
    #expect(BulletinBoardRules.isCleanedUp(task("FOC-3"), lookup: facts))
    #expect(BulletinBoardRules.isCleanedUp(task("FOC-99"), lookup: facts))
  }

  @Test("Archived, merged, deleted, and orphaned agents are cleaned up; unloaded contexts stay")
  func agentRule() {
    let facts = lookup()
    #expect(!BulletinBoardRules.isCleanedUp(agent("FOC-1", "A-LIVE"), lookup: facts))
    #expect(BulletinBoardRules.isCleanedUp(agent("FOC-1", "A-ARCHIVED"), lookup: facts))
    #expect(BulletinBoardRules.isCleanedUp(agent("FOC-1", "A-MERGED"), lookup: facts))
    #expect(BulletinBoardRules.isCleanedUp(agent("FOC-1", "A-GONE"), lookup: facts))
    #expect(BulletinBoardRules.isCleanedUp(agent("FOC-2", "A-LIVE"), lookup: facts))
    // A task whose context has not loaded must not lose its agent pins.
    #expect(!BulletinBoardRules.isCleanedUp(agent("FOC-4", "A-ANY"), lookup: facts))
  }

  @Test("Files and folders are cleaned up once they leave the disk")
  func fileRule() {
    let facts = lookup(existing: ["/repo/kept.md"])
    #expect(!BulletinBoardRules.isCleanedUp(
      BulletinPin(kind: .file, projectID: "p1", path: "/repo/kept.md", title: "kept.md"), lookup: facts))
    #expect(BulletinBoardRules.isCleanedUp(
      BulletinPin(kind: .folder, projectID: "p1", path: "/repo/.worktrees/gone", title: "gone"), lookup: facts))
  }

  @Test("A project shows its own and unscoped pins; All shows every pin; cleaned-up pins hide unless asked")
  func visibility() {
    let facts = lookup()
    let unscoped = BulletinPin(kind: .task, projectID: nil, taskID: "FOC-1", title: "x")
    let pins = [task("FOC-1"), task("FOC-4", project: "p2"), task("FOC-2"), unscoped]
    let p1 = BulletinBoardRules.visiblePins(pins, projectID: "p1", showsCleanedUp: false, lookup: facts)
    #expect(p1.map(\.taskID) == ["FOC-1", "FOC-1"])
    let p1All = BulletinBoardRules.visiblePins(pins, projectID: "p1", showsCleanedUp: true, lookup: facts)
    #expect(p1All.map(\.taskID) == ["FOC-1", "FOC-2", "FOC-1"])
    let all = BulletinBoardRules.visiblePins(pins, projectID: nil, showsCleanedUp: false, lookup: facts)
    #expect(all.count == 3)
  }

  @Test("Pinning the same item twice moves its card instead of duplicating it")
  func dedupe() {
    var pins = BulletinBoardRules.adding(task("FOC-1"), to: [])
    pins = BulletinBoardRules.adding(task("FOC-4"), to: pins)
    var again = task("FOC-1")
    again.x = 120; again.y = 40
    pins = BulletinBoardRules.adding(again, to: pins)
    #expect(pins.count == 2)
    #expect(pins.last?.taskID == "FOC-1" && pins.last?.x == 120 && pins.last?.y == 40)
    let file = BulletinPin(kind: .file, projectID: "p1", path: "/repo/./a.md", title: "a.md")
    let same = BulletinPin(kind: .file, projectID: "p1", path: "/repo/a.md", title: "a.md")
    #expect(file.targets(sameItemAs: same))
  }

  @Test("Agent drag tokens round-trip and file strings parse as URLs or paths")
  func dragTokens() {
    let token = BulletinDragToken.agent(taskID: "FOC-1", subtaskID: "ABC-123")
    #expect(BulletinDragToken.parseAgent(token)?.taskID == "FOC-1")
    #expect(BulletinDragToken.parseAgent(token)?.subtaskID == "ABC-123")
    #expect(BulletinDragToken.parseAgent("FOC-1") == nil)
    #expect(BulletinDragToken.parseAgent("focusqueue-agent:FOC-1/") == nil)
    #expect(BulletinDragToken.fileURL("file:///tmp/a%20b.md")?.path == "/tmp/a b.md")
    #expect(BulletinDragToken.fileURL("/tmp/x")?.path == "/tmp/x")
    #expect(BulletinDragToken.fileURL("FOC-1") == nil)
    #expect(BulletinDragToken.linkURL("https://github.com/org/repo/pull/7")?.host == "github.com")
    #expect(BulletinDragToken.linkURL("focusqueue://ref/FOC-1/B3") != nil)
    #expect(BulletinDragToken.linkURL("file:///tmp/a.md") == nil)
    #expect(BulletinDragToken.linkURL("FOC-1") == nil)
    #expect(BulletinDragToken.linkURL("note: not a link") == nil)
  }

  @Test("Links are never cleaned up and dedupe by URL")
  func links() {
    let pin = BulletinPin(kind: .link, projectID: "p1", url: "https://example.com/a", title: "A")
    #expect(!BulletinBoardRules.isCleanedUp(pin, lookup: lookup()))
    let pins = BulletinBoardRules.adding(pin, to: BulletinBoardRules.adding(
      BulletinPin(kind: .link, projectID: "p1", url: "https://example.com/a", title: "A", x: 50), to: []))
    #expect(pins.count == 1)
    let other = BulletinPin(kind: .link, projectID: "p1", url: "https://example.com/b", title: "B")
    #expect(!pin.targets(sameItemAs: other))
  }

  @Test("New pins without a drop spot fill free grid slots")
  func nextSlot() {
    let first = BulletinBoardRules.nextSlot(for: [], boardWidth: 400, cardWidth: 150, cardHeight: 70, spacing: 12)
    var pin = task("FOC-1")
    pin.x = first.x; pin.y = first.y
    let second = BulletinBoardRules.nextSlot(for: [pin], boardWidth: 400, cardWidth: 150, cardHeight: 70, spacing: 12)
    #expect(second.x > first.x && second.y == first.y)
  }

  @Test("The store round-trips pins and reads a missing file as empty")
  func store() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bulletin-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = BulletinBoardStore(root: root)
    #expect(try store.load().pins.isEmpty)
    let document = BulletinBoardDocument(pins: [task("FOC-1"), agent("FOC-1", "A-LIVE")])
    try store.save(document)
    let loaded = try store.load()
    #expect(loaded.pins.map(\.id) == document.pins.map(\.id))
    #expect(loaded.pins[1].subtaskID == "A-LIVE")
  }
}
