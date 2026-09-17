import Foundation
import Testing
@testable import FocusQueueCore

@Suite("Projects and filtered queue order")
struct ProjectTests {
    @Test func remoteIdentityAndCompatibility() throws {
        #expect(ProjectCatalog.normalizedRemote("git@github.com:Affaan-M/ECC.git") == "github.com/affaan-m/ecc")
        #expect(ProjectCatalog.normalizedRemote("ssh://git@github.com/affaan-m/ECC.git") == "github.com/affaan-m/ecc")
        #expect(ProjectCatalog.normalizedRemote("https://github.com/affaan-m/ECC/") == "github.com/affaan-m/ecc")
        #expect(ProjectCatalog.normalizedRemote("javascript:invalid") == nil)
        let project = ProjectDefinition(id: "ecc", name: "ECC", repositoryPath: "/tmp/ecc", remote: "https://github.com/affaan-m/ECC")
        try ProjectCatalog.validate([project])
        #expect(throws: (any Error).self) { try ProjectCatalog.validate([project, project]) }
        var other = project; other.id = "other"
        #expect(throws: (any Error).self) { try ProjectCatalog.validate([project, other]) }
        let ticket = try JSONDecoder().decode(DashboardTicket.self, from: Data("{\"id\":\"ECC-001\"}".utf8))
        #expect(ticket.projectID == nil)
        #expect(ProjectCatalog.includes(ticket, selection: ProjectCatalog.unassignedID, projects: [project]))
        #expect(ProjectCatalog.normalizedSelection("missing", projects: [project]) == nil)
    }

    @Test func filteredMovesKeepHiddenSlots() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = QueueOrderStore(root: root)
        let tickets = ["A", "B", "C", "D", "E"].map { DashboardTicket(id: $0, title: $0, status: "open", summary: "") }
        let order = ["A", "B", "C", "D", "E"]
        let visible = Set(["A", "C", "E"])
        let moved = try store.move("E", to: .top, tickets: tickets, fallbackIDs: order, visibleIDs: visible)
        #expect(moved == ["E", "B", "A", "D", "C"])
        #expect(try store.move("E", to: .before("E"), tickets: tickets, fallbackIDs: order, visibleIDs: visible) == moved)
        #expect(throws: (any Error).self) { try store.move("B", to: .top, tickets: tickets, fallbackIDs: order, visibleIDs: visible) }
        #expect(throws: (any Error).self) { try store.move("A", to: .before("B"), tickets: tickets, fallbackIDs: order, visibleIDs: visible) }
        let reset = try store.reset(tickets: tickets, visibleIDs: visible, fallbackIDs: order)
        #expect(reset[1] == "B" && reset[3] == "D")
        #expect(reset.filter { visible.contains($0) } == DashboardOrdering.openTickets(in: tickets).map(\.id).filter { visible.contains($0) })
    }

    @Test func assignmentPreservesUnknownFieldsAndCreatesUniqueTasks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("dashboard.json")
        let raw = #"{"meta":{"custom":true},"tickets":[{"id":"ECC-035","title":"Existing","summary":"Keep","status":"in-progress","worktree":"/existing","unknown":{"keep":[1,2]}}]}"#
        try Data(raw.utf8).write(to: path)
        let store = ProjectTaskStore(dashboardURL: path, supportDirectory: root)
        try store.assign(ticketID: "ECC-035", projectID: "focus")
        let document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        let tickets = try #require(document["tickets"] as? [[String: Any]])
        #expect(tickets[0]["worktree"] as? String == "/existing")
        #expect(tickets[0]["unknown"] != nil && document["meta"] != nil)
        #expect(tickets[0]["projectID"] as? String == "focus")
        #expect(try store.create(title: "New", summary: "", projectID: nil) == "ECC-036")
        try store.assign(ticketID: "ECC-035", projectID: nil)
        let decoded = try JSONDecoder().decode(DashboardDocument.self, from: Data(contentsOf: path))
        #expect(decoded.tickets.allSatisfy { $0.projectID == nil })
        #expect(decoded.tickets[1].summary == "New")
    }

    @Test func worktreeRepositoryIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo"), tree = root.appendingPathComponent("tree")
        let runner = FoundationProcessRunner()
        for args in [["init", repo.path], ["-C", repo.path, "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--allow-empty", "-m", "initial"], ["-C", repo.path, "worktree", "add", "-b", "test", tree.path]] {
            let result = try await runner.run(.init(executable: "/usr/bin/git", arguments: args))
            #expect(result.succeeded)
        }
        let project = ProjectDefinition(name: "Repo", repositoryPath: repo.path)
        #expect(try await ProjectRepositoryResolver().matches(path: tree.path, project: project))
        #expect(try await !ProjectRepositoryResolver().matches(path: root.path, project: project))
    }
}
