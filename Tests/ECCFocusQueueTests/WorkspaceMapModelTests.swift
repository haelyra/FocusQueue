import Foundation
import Testing
import FocusQueueCore
import FocusQueueMap
@testable import ECCFocusQueue

private actor UnavailableMapRunner: ProcessRunning {
    func run(_ spec: ProcessSpecification) async throws -> ProcessResult {
        ProcessResult(exitCode: 1, standardOutput: "", standardError: "unavailable", timedOut: false)
    }
}

@Suite("Workspace map presentation")
@MainActor
struct WorkspaceMapModelTests {
    @Test("A failed first refresh retains the saved snapshot and its original time")
    func savedSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("map-model-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskContextStore(root: root)
        var context = try await store.ensureContext(ticket: DashboardTicket(id: "ECC-901", title: "Map", status: "open", summary: "Map"))
        context.worktreePath = "/missing/map-test-workspace"
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = MapSnapshot(taskID: context.ticketID, generatedAt: date, nodes: [
            MapNode(id: "queue", parentID: nil, kind: .queue, label: "Queue", evidence: "Context"),
            MapNode(id: "workspace", parentID: "queue", kind: .workspace, label: "Saved workspace", path: context.worktreePath, evidence: "Previous Git observation", observedAt: date)])
        let cacheURL = context.contextDirectory.appendingPathComponent("workspace-map/snapshot.json")
        try await MapSnapshotCache().save(snapshot, to: cacheURL)
        let model = WorkspaceMapModel(collector: WorkspaceCollector(runner: UnavailableMapRunner()))
        await model.refresh(context: context, sessions: [])
        #expect(model.snapshot?.generatedAt == date)
        #expect(model.message?.contains("last successful map") == true)
        #expect(model.snapshot?.nodes.contains { $0.label == "Saved workspace" } == true)
        #expect(model.expanded.contains("workspace"))
        #expect(!model.isRefreshing)
    }

    @Test("A task change cannot display another task's cached map")
    func taskSwitch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("map-switch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskContextStore(root: root)
        let first = try await store.ensureContext(ticket: DashboardTicket(id: "ECC-901", title: "First", status: "open", summary: "First"))
        let second = try await store.ensureContext(ticket: DashboardTicket(id: "ECC-902", title: "Second", status: "open", summary: "Second"))
        let model = WorkspaceMapModel(collector: WorkspaceCollector(runner: UnavailableMapRunner()))
        await model.refresh(context: first, sessions: [])
        #expect(model.snapshot?.taskID == first.ticketID)
        await model.refresh(context: second, sessions: [])
        #expect(model.snapshot?.taskID == second.ticketID)
    }
}
