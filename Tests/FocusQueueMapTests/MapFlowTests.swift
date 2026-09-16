import Foundation
import Testing
import FocusQueueCore
@testable import FocusQueueMap

@Suite("Map context and output organization")
struct MapFlowTests {
    private func graph() -> MapSnapshot {
        let nodes = [
            MapNode(id: "queue", parentID: nil, kind: .queue, label: "Queue", evidence: "Task"),
            MapNode(id: "workspace", parentID: "queue", kind: .workspace, label: "Repo", path: "/repo", evidence: "Git"),
            MapNode(id: "source", parentID: "workspace", kind: .folder, label: "Sources", path: "/repo/Sources", evidence: "Git"),
            MapNode(id: "plan", parentID: "workspace", kind: .file, label: "plan.md", path: "/repo/plan.md", evidence: "Task"),
            MapNode(id: "output", parentID: "source", kind: .file, label: "Feature.swift", path: "/repo/Sources/Feature.swift", evidence: "Declaration"),
            MapNode(id: "quiet", parentID: "source", kind: .file, label: "Unrelated.swift", path: "/repo/Sources/Unrelated.swift", evidence: "Git"),
            MapNode(id: "agent", parentID: "workspace", kind: .agent, label: "Writer", evidence: "Registration"),
            MapNode(id: "other", parentID: "workspace", kind: .agent, label: "Reviewer", evidence: "Registration")]
        let edges = [MapRelation(from: "plan", to: "agent", kind: .input, evidence: "Provided", observedAt: nil),
                     MapRelation(from: "agent", to: "output", kind: .output, evidence: "Declared", observedAt: nil),
                     MapRelation(from: "plan", to: "other", kind: .input, evidence: "Provided", observedAt: nil)]
        return MapSnapshot(taskID: "TASK", generatedAt: Date(), nodes: nodes, relations: edges)
    }

    @Test("Relevant files are the default, and a directory toggle exposes other files")
    func relevance() {
        let snapshot = graph(), layout = MapFlowLayout(snapshot: graph())
        #expect(layout.items.contains { $0.node.id == "output" })
        #expect(!layout.items.contains { $0.node.id == "quiet" })
        let all = MapFlowLayout(snapshot: snapshot, showOtherFiles: true, expanded: Set(snapshot.nodes.map(\.id)))
        #expect(all.items.contains { $0.node.id == "quiet" })
        #expect(layout.items.filter { $0.node.id == "plan" }.count == 1)
    }

    @Test("Context is left of its agent, outputs are right, and parents consume no additional row")
    func compactLayout() throws {
        let snapshot = graph(), layout = MapFlowLayout(snapshot: graph())
        let input = try #require(layout.items.first { $0.node.id == "plan" })
        let agent = try #require(layout.items.first { $0.node.id == "agent" })
        let output = try #require(layout.items.first { $0.node.id == "output" })
        #expect(input.x < agent.x && agent.x < output.x)
        #expect(layout.height < Double(snapshot.nodes.count) * 92)
        #expect(layout.lines.contains { $0.kind == "input" && $0.to == agent.id })
        #expect(layout.lines.contains { $0.kind == "output" && $0.from == agent.id })
        for (i, first) in layout.items.enumerated() {
            for second in layout.items.dropFirst(i + 1) {
                let intersects = abs(first.x - second.x) < MapFlowLayout.nodeWidth && abs(first.y - second.y) < MapFlowLayout.nodeHeight
                #expect(!intersects, "Overlapping items: \(first.id), \(second.id)")
            }
        }
        #expect(MapFlowLayout(snapshot: snapshot, showOtherFiles: true, expanded: Set(snapshot.nodes.map(\.id)), limit: 6).items.count <= 6)
    }

    @Test("Agent selection highlights its input/output paths without including another agent")
    func highlight() {
        let highlighted = MapFlowLayout.highlightedNodes(agentID: "agent", snapshot: graph())
        #expect(highlighted.isSuperset(of: ["plan", "output", "source", "workspace", "agent"]))
        #expect(!highlighted.contains("other"))
        #expect(!highlighted.contains("quiet"))
    }

    @Test("A file can be both read and written without creating a layout cycle")
    func readWrite() throws {
        var snapshot = graph()
        snapshot.relations.append(.init(from: "output", to: "agent", kind: .input, evidence: "Declared", observedAt: nil))
        _ = try snapshot.validated()
        let layout = MapFlowLayout(snapshot: snapshot)
        let copies = layout.items.filter { $0.node.id == "output" }
        #expect(copies.count == 2)
        #expect(Set(copies.map(\.id)).count == 2)
    }

    @Test("Declarations are scoped to the exact session, and untracked context is included")
    func scopeCollection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scope-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let runner = FoundationProcessRunner()
        _ = try await runner.run(.init(executable: "/usr/bin/git", arguments: ["init", "-q"], workingDirectory: repo.path))
        try Data("# Scoped instructions".utf8).write(to: repo.appendingPathComponent("AGENTS.md"))
        let store = TaskContextStore(root: root.appendingPathComponent("support"))
        var context = try await store.ensureContext(ticket: .init(id: "MAP", title: "Map", status: "open", summary: "Map"))
        context.worktreePath = repo.path
        let subtask = TaskSubtask(id: "one", title: "Writer", sessionID: "first")
        context.subtasks = [subtask]
        try MapScope(context: context, subtask: subtask, inputs: ["AGENTS.md"], outputs: ["Sources/new file.swift"]).save(context: context)
        let snapshot = try await WorkspaceCollector().collect(context: context, sessions: [])
        #expect(snapshot.relations.contains { $0.kind == .output })
        #expect(snapshot.nodes.contains { $0.path?.hasSuffix("Sources/new file.swift") == true })
        #expect(snapshot.relations.filter { $0.kind == .input }.count >= 2)
        context.subtasks[0].sessionID = "replacement"
        let replacement = try await WorkspaceCollector().collect(context: context, sessions: [])
        #expect(!replacement.relations.contains { $0.kind == .output })
    }
}
