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

private actor PartiallyAvailableMapRunner: ProcessRunning {
    let availableRoot: String
    private var failAvailableRoot = false

    init(availableRoot: String) {
        self.availableRoot = availableRoot
    }

    func setFailure(_ value: Bool) {
        failAvailableRoot = value
    }

    func run(_ spec: ProcessSpecification) async throws -> ProcessResult {
        guard spec.workingDirectory == availableRoot, !failAvailableRoot else {
            throw ProcessRunnerError.invalidWorkingDirectory(spec.workingDirectory ?? "")
        }
        let output: String
        switch spec.arguments.first {
        case "rev-parse":
            output = spec.arguments.last == "--show-toplevel" ? availableRoot + "\n" : availableRoot + "/.git\n"
        case "worktree":
            output = "worktree \(availableRoot)\0HEAD abc\0branch refs/heads/feature/map\0\0"
        case "status":
            output = ""
        case "ls-files":
            output = "Sources/Live.swift\0"
        default:
            throw MapError.unavailable("Unexpected Git command")
        }
        return ProcessResult(exitCode: 0, standardOutput: output, standardError: "", timedOut: false)
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
        #expect(model.expanded.isEmpty) // Expansion defaults belong to the bounded layout, not the snapshot cache.
        #expect(!model.isRefreshing)
    }

    @Test("A usable partial refresh replaces the saved snapshot and reports its warnings")
    func partialRefresh() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("map-partial-\(UUID().uuidString)")
        let live = root.appendingPathComponent("live-workspace")
        let missing = root.appendingPathComponent("missing-workspace")
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = TaskContextStore(root: root.appendingPathComponent("support"))
        var context = try await store.ensureContext(ticket: DashboardTicket(
            id: "ECC-901", title: "Map", status: "open", summary: "Map"))
        context.worktreePath = live.path
        context.repositoryPath = live.path
        let savedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let saved = MapSnapshot(taskID: context.ticketID, generatedAt: savedAt, nodes: [
            MapNode(id: "queue", parentID: nil, kind: .queue, label: "Queue", evidence: "Context"),
            MapNode(id: "saved", parentID: "queue", kind: .workspace, label: "Saved workspace",
                    path: "/previous/workspace", evidence: "Previous Git observation", observedAt: savedAt)
        ])
        let cacheURL = context.contextDirectory.appendingPathComponent("workspace-map/snapshot.json")
        try await MapSnapshotCache().save(saved, to: cacheURL)
        let sessions = [TaskAgentSession(ticketID: context.ticketID, provider: .codex,
            sessionID: "missing-session", tabTitle: "Missing", workingDirectory: missing.path)]
        let model = WorkspaceMapModel(collector: WorkspaceCollector(
            runner: PartiallyAvailableMapRunner(availableRoot: live.path)))

        await model.refresh(context: context, sessions: sessions)

        let snapshot = try #require(model.snapshot)
        #expect(snapshot.generatedAt != savedAt)
        #expect(snapshot.warnings.contains { $0.contains("Working directory does not exist") })
        #expect(snapshot.nodes.contains { $0.kind == .workspace && $0.path == live.path && $0.observedAt != nil })
        #expect(snapshot.nodes.contains { $0.kind == .file && $0.label == "Live.swift" })
        #expect(!snapshot.nodes.contains { $0.label == "Saved workspace" })
        #expect(model.message?.contains("Working directory does not exist") == true)
        #expect(model.message?.contains("last successful map") == false)
    }

    @Test("A total failure after a partial refresh returns to the clean saved snapshot")
    func partialThenUnavailableFallsBack() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("map-partial-fallback-\(UUID().uuidString)")
        let live = root.appendingPathComponent("live-workspace")
        let missing = root.appendingPathComponent("missing-workspace")
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = TaskContextStore(root: root.appendingPathComponent("support"))
        var context = try await store.ensureContext(ticket: DashboardTicket(
            id: "ECC-901", title: "Map", status: "open", summary: "Map"))
        context.worktreePath = live.path
        context.repositoryPath = live.path
        let savedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let saved = MapSnapshot(taskID: context.ticketID, generatedAt: savedAt, nodes: [
            MapNode(id: "queue", parentID: nil, kind: .queue, label: "Queue", evidence: "Context"),
            MapNode(id: "saved", parentID: "queue", kind: .workspace, label: "Saved workspace",
                    path: "/previous/workspace", evidence: "Previous Git observation", observedAt: savedAt)
        ])
        let cacheURL = context.contextDirectory.appendingPathComponent("workspace-map/snapshot.json")
        try await MapSnapshotCache().save(saved, to: cacheURL)
        let sessions = [TaskAgentSession(ticketID: context.ticketID, provider: .codex,
            sessionID: "missing-session", tabTitle: "Missing", workingDirectory: missing.path)]
        let runner = PartiallyAvailableMapRunner(availableRoot: live.path)
        let model = WorkspaceMapModel(collector: WorkspaceCollector(runner: runner))

        await model.refresh(context: context, sessions: sessions)
        #expect(model.snapshot?.generatedAt != savedAt)
        #expect(model.snapshot?.warnings.isEmpty == false)

        await runner.setFailure(true)
        try await Task.sleep(for: .milliseconds(5))
        await model.refresh(context: context, sessions: sessions)

        #expect(model.snapshot?.generatedAt == savedAt)
        #expect(model.snapshot?.warnings.isEmpty == true)
        #expect(model.snapshot?.nodes.contains { $0.label == "Saved workspace" } == true)
        #expect(model.message?.contains("last successful map") == true)
    }

    @Test("A warning-bearing saved snapshot is never promoted as the clean fallback")
    func warningCacheIsNotFallback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("map-warning-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskContextStore(root: root.appendingPathComponent("support"))
        var context = try await store.ensureContext(ticket: DashboardTicket(
            id: "ECC-901", title: "Map", status: "open", summary: "Map"))
        context.worktreePath = "/missing/map-warning-cache-workspace"
        let savedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let warned = MapSnapshot(taskID: context.ticketID, generatedAt: savedAt, nodes: [
            MapNode(id: "queue", parentID: nil, kind: .queue, label: "Queue", evidence: "Context"),
            MapNode(id: "warned", parentID: "queue", kind: .workspace, label: "Warned workspace",
                    path: "/previous/workspace", evidence: "Partial Git observation", observedAt: savedAt)
        ], warnings: ["Previous partial scan"])
        let cacheURL = context.contextDirectory.appendingPathComponent("workspace-map/snapshot.json")
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try warned.encoded().write(to: cacheURL)
        let model = WorkspaceMapModel(collector: WorkspaceCollector(runner: UnavailableMapRunner()))

        await model.refresh(context: context, sessions: [])

        #expect(model.snapshot?.generatedAt != savedAt)
        #expect(model.snapshot?.nodes.contains { $0.label == "Warned workspace" } == false)
        #expect(model.message?.contains("last successful map") == false)
    }

    @Test("A retained older observation does not count as a live workspace")
    func staleObservationFallsBack() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("map-stale-\(UUID().uuidString)")
        let live = root.appendingPathComponent("live-workspace")
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = TaskContextStore(root: root.appendingPathComponent("support"))
        var context = try await store.ensureContext(ticket: DashboardTicket(
            id: "ECC-901", title: "Map", status: "open", summary: "Map"))
        context.worktreePath = live.path
        context.repositoryPath = live.path
        let runner = PartiallyAvailableMapRunner(availableRoot: live.path)
        let model = WorkspaceMapModel(collector: WorkspaceCollector(runner: runner))

        await model.refresh(context: context, sessions: [])
        let successful = try #require(model.snapshot)
        #expect(successful.warnings.isEmpty)
        #expect(successful.nodes.contains {
            $0.kind == .workspace && $0.observedAt == successful.generatedAt
        })

        await runner.setFailure(true)
        try await Task.sleep(for: .milliseconds(5))
        await model.refresh(context: context, sessions: [])

        #expect(model.snapshot?.generatedAt == successful.generatedAt)
        #expect(model.snapshot?.warnings.isEmpty == true)
        #expect(model.message?.contains("last successful map") == true)
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

@Suite("Map navigation and collapse controls")
@MainActor
struct MapNavigationTests {
    @Test("Background action exits agent and branch focus without changing the snapshot")
    func backgroundExit() {
        let model = WorkspaceMapModel()
        model.mode = .agent; model.focusedAgentID = "agent"; model.focusedBranchID = "branch"; model.retrospective = true
        model.normalView()
        #expect(model.mode == .typical && model.focusedAgentID == nil && model.focusedBranchID == nil && !model.retrospective)
    }
    @Test("Parent controls collapse visible children and drill into budget-limited groups")
    func collapse() {
        let model = WorkspaceMapModel()
        var diagram = MapDiagram()
        let node = MapNode(id: "parent", parentID: nil, kind: .folder, label: "Folder", evidence: "Group")
        diagram.add(node, x: 0, y: 0, role: "Output", expansion: "parent")
        var item = diagram.items[0]; item.isExpanded = true
        model.toggle(item)
        #expect(model.collapsed.contains("parent"))
        item.isExpanded = false; item.focusOnExpand = true
        model.toggle(item)
        #expect(!model.collapsed.contains("parent") && model.focusedBranchID == "parent")
    }
}
