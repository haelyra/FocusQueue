import Foundation
import Testing
import FocusQueueCore
@testable import FocusQueueMap

@Suite("Map agent activity and subagents")
struct MapActivityTests {
    func report(task: String = "TEST", session: String = "child", parent: String? = "parent", files: [(String, String, Date, Int)] = []) throws -> MapAgentActivity {
        var value: [String: Any] = ["version": 1, "taskID": task, "provider": "codex", "sessionID": session,
            "label": session, "workingDirectory": "/repo", "state": "working", "updatedAt": ISO8601DateFormatter().string(from: Date()),
            "entries": files.map { ["path": $0.0, "operation": $0.1, "at": ISO8601DateFormatter().string(from: $0.2), "importance": $0.3] }]
        if let parent { value["parentSessionID"] = parent }
        return try MapAgentActivity.decode(JSONSerialization.data(withJSONObject: value), taskID: task)
    }
    @Test("Activity keeps earlier writes across reports and rejects cyclic subagent ancestry")
    func persistence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("map-activity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try await TaskContextStore(root: root).ensureContext(ticket: .init(id: "TEST", title: "Map", status: "open", summary: "Map"))
        try report(files: [("/repo/old.swift", "write", Date().addingTimeInterval(-3600), 90)]).save(context: context)
        try report(files: [("/repo/new.swift", "read", Date(), 30)]).save(context: context)
        let saved = try #require(MapAgentActivity.load(context: context).first)
        #expect(saved.entries.count == 2)
        #expect(saved.parentSessionID == "parent")
        #expect(throws: (any Error).self) { try report(session: "parent", parent: "child").save(context: context) }
        #expect(try MapAgentActivity.load(context: context).count == 1)
        try report(session: "replacement", parent: nil).save(context: context)
        #expect(try MapAgentActivity.load(context: context).first { $0.sessionID == "replacement" }?.entries.isEmpty == true)
    }
    @Test("Current files come first, historical importance fills remaining slots, and retrospective excludes guesses")
    func focus() {
        let now = Date(); var graph = MapTemplateTests().snapshot(fileCount: 8)
        let agentIndex = graph.nodes.firstIndex { $0.id == "a" }!
        graph.nodes[agentIndex].reportedState = "working"; graph.nodes[agentIndex].observedAt = now
        for i in graph.relations.indices where graph.relations[i].kind == .output {
            graph.relations[i].evidence = "Reported write"; graph.relations[i].observedAt = now.addingTimeInterval(-3600)
            graph.relations[i].importance = graph.relations[i].to == "file7" ? 100 : 1
        }
        let currentIndex = graph.relations.firstIndex { $0.to == "file0" && $0.kind == .output }!
        graph.relations[currentIndex].observedAt = now
        var options = WorkspaceMapOptions()
        let focus = MapAgentFocus.relations(agent: graph.nodes[agentIndex], snapshot: graph, options: options, now: now)
        #expect(focus.filter { $0.kind == .output }.count == 4)
        #expect(focus.contains { $0.to == "file0" } && focus.contains { $0.to == "file7" })
        options.retrospective = true
        #expect(MapAgentFocus.relations(agent: graph.nodes[agentIndex], snapshot: graph, options: options, now: now).count == 8)
        graph.relations[currentIndex].evidence = "Declared output"
        #expect(MapAgentFocus.relations(agent: graph.nodes[agentIndex], snapshot: graph, options: options, now: now).count == 7)
    }
    @Test("Subagent instances carry independent inputs and outputs while tmux remains an agent attribute")
    func collection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("subagent-map-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try await FoundationProcessRunner().run(.init(executable: "/usr/bin/git", arguments: ["init", "-q"], workingDirectory: root.path))
        var context = try await TaskContextStore(root: root.appendingPathComponent("support")).ensureContext(ticket: .init(id: "TEST", title: "Map", status: "open", summary: "Map"))
        context.worktreePath = root.path
        var subtask = TaskSubtask(id: "parent", title: "Parent", sessionID: "parent")
        let tmux = #"{"name":"recorded-only","serverPID":123,"createdAt":1700000000,"paneID":"%1","panePID":456,"tty":"/dev/fixture","executable":"/usr/bin/false"}"#
        subtask.tmux = try JSONDecoder().decode(TmuxSessionReference.self, from: Data(tmux.utf8))
        context.subtasks = [subtask]
        var activity = try report(files: [(root.appendingPathComponent("context.txt").path, "read", Date(), 10), (root.appendingPathComponent("output.swift").path, "write", Date(), 90)])
        activity.workingDirectory = root.path
        try activity.save(context: context)
        let snapshot = try await WorkspaceCollector().collect(context: context, sessions: [])
        let parent = try #require(snapshot.nodes.first { $0.sessionID == "parent" })
        let child = try #require(snapshot.nodes.first { $0.sessionID == "child" })
        #expect(child.parentAgentID == parent.id)
        #expect(parent.runtime == "tmux · recorded-only")
        #expect(!snapshot.nodes.contains { $0.kind == .resource && $0.label.contains("tmux") })
        #expect(snapshot.relations.contains { $0.from == child.id && $0.evidence == "Reported write" })
        #expect(snapshot.relations.contains { $0.to == child.id && $0.evidence == "Reported read" })
        var options = WorkspaceMapOptions(); options.mode = .agent; options.agentID = child.id
        let diagram = WorkspaceMapProjection.diagram(snapshot: snapshot, options: options)
        #expect(diagram.items.contains { $0.node.id == child.id && $0.role == "Subagent instance" })
        MapTemplateTests().assertPacked(diagram)
        var parentActivity = try report(session: "parent", parent: nil)
        parentActivity.workingDirectory = root.path
        try parentActivity.save(context: context)
        context.subtasks[0].status = .completed
        let completed = try await WorkspaceCollector().collect(context: context, sessions: [])
        #expect(completed.nodes.first { $0.sessionID == "parent" }?.reportedState == "completed")
    }
}
