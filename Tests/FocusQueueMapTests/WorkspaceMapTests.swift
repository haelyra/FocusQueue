import Foundation
import Testing
import FocusQueueCore
@testable import FocusQueueMap

private let mapNow = Date(timeIntervalSince1970: 1_800_000_000)

private func fixture() async throws -> (URL, TaskContext) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("map fixture \(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = TaskContextStore(root: root.appendingPathComponent("support"))
    var context = try await store.ensureContext(ticket: DashboardTicket(id: "ECC-901", title: "Workspace map", status: "in-progress", summary: "Inspect agent work"))
    context.worktreePath = root.path; context.repositoryPath = root.path
    return (root, context)
}

private actor MapRunner: ProcessRunning {
    let root: String
    var fail = false
    var status = " M Sources/Hello world.swift\0?? Docs/new.md\0"
    var tracked = "Sources/Hello world.swift\0Sources/Quiet.swift\0README.md\0"
    var calls: [ProcessSpecification] = []
    init(root: String) { self.root = root }
    func setFailure(_ value: Bool) { fail = value }
    func run(_ spec: ProcessSpecification) async throws -> ProcessResult {
        calls.append(spec)
        let output: String
        switch spec.arguments.first {
        case "rev-parse": output = spec.arguments.last == "--show-toplevel" ? root + "\n" : root + "/.git\n"
        case "worktree": output = "worktree \(root)\0HEAD abc\0branch refs/heads/feature/map\0\0"
        case "status": output = status
        case "ls-files": output = tracked
        default: throw MapError.unavailable("Unexpected Git command")
        }
        return ProcessResult(exitCode: fail ? 1 : 0, standardOutput: output, standardError: "", timedOut: false)
    }
}

@Suite("Workspace map")
struct WorkspaceMapTests {
    @Test("NUL records preserve spaces, Unicode, renames, and deletions")
    func porcelain() throws {
        let records = try GitMapParser.changes("R  Sources/new name.swift\0Sources/旧.swift\0 D deleted.txt\0?? line\nname.txt\0")
        #expect(records.map(\.path) == ["Sources/new name.swift", "deleted.txt", "line\nname.txt"])
        #expect(records[0].originalPath == "Sources/旧.swift")
        #expect(records[1].status == " D")
        #expect(throws: MapError.self) { try GitMapParser.changes("R  no-source\0") }
        #expect(throws: MapError.self) { try GitMapParser.changes("invalid record\0") }
        #expect(GitMapParser.worktrees("worktree /a b\0branch refs/heads/main\0\0worktree /a\nb\0detached\0\0") == ["/a b": "main", "/a\nb": "Detached HEAD"])
    }

    @Test("Freshness distinguishes stale evidence, absent heartbeats, completion, and clock skew")
    func freshness() {
        var node = MapNode(id: "agent", parentID: "queue", kind: .agent, label: "Agent", evidence: "Report",
                           observedAt: mapNow, reportedState: "working")
        #expect(node.state(at: mapNow.addingTimeInterval(300)) == "working")
        #expect(node.state(at: mapNow.addingTimeInterval(301)) == "stale")
        #expect(node.state(at: mapNow.addingTimeInterval(-61)) == "stale")
        node.observedAt = nil
        #expect(node.state(at: mapNow) == "stale")
        node.reportedState = "completed"
        #expect(node.state(at: mapNow) == "completed")
    }

    @Test("Collector keeps workspace attribution separate from file authors and filters unrelated sessions")
    func collection() async throws {
        let (root, initial) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var context = initial
        context.subtasks = [TaskSubtask(id: "one", title: "Map writer", sessionID: "session-a", status: .working,
                                       progressSummary: "Building the map", lastHeartbeatAt: mapNow)]
        let sessions = [TaskAgentSession(ticketID: context.ticketID, provider: .codex, sessionID: "session-a", tabTitle: "Agent", workingDirectory: root.path, subtaskID: "one"),
                        TaskAgentSession(ticketID: "OTHER", provider: .claude, sessionID: "other", tabTitle: "Other", workingDirectory: "/other")]
        let runner = MapRunner(root: root.path), collector = WorkspaceCollector(runner: runner)
        let first = try await collector.collect(context: context, sessions: sessions, now: mapNow)
        #expect(first.warnings.isEmpty)
        #expect(first.nodes.filter { $0.kind == .agent }.count == 1)
        let file = try #require(first.nodes.first { $0.label == "Hello world.swift" })
        #expect(file.sessionID == nil && file.summary.contains("owner unknown"))
        #expect(first.nodes.first { $0.kind == .document }?.parentID == "queue")
        #expect(first.nodes.first { $0.kind == .workspace }?.summary.contains("feature/map") == true)
        let second = try await collector.collect(context: context, sessions: sessions, now: mapNow.addingTimeInterval(5))
        #expect(first.nodes.map(\.id) == second.nodes.map(\.id))
        let calls = await runner.calls
        #expect(calls.filter { $0.arguments.first == "ls-files" }.count == 1)
        #expect(calls.allSatisfy { $0.environment?["GIT_OPTIONAL_LOCKS"] == "0" })
        #expect(calls.allSatisfy { $0.workingDirectory == root.path })
        #expect(try MapSnapshot.decode(first.encoded()).taskID == context.ticketID)
    }

    @Test("Failed scans retain the original observation time and last good paths")
    func failedRefresh() async throws {
        let (root, context) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let runner = MapRunner(root: root.path), collector = WorkspaceCollector(runner: runner)
        let first = try await collector.collect(context: context, sessions: [], now: mapNow)
        await runner.setFailure(true)
        let second = try await collector.collect(context: context, sessions: [], now: mapNow.addingTimeInterval(400))
        #expect(!second.warnings.isEmpty)
        #expect(second.nodes == first.nodes)
        #expect(second.nodes.first { $0.kind == .workspace }?.observedAt == mapNow)
        let cache = MapSnapshotCache(), url = root.appendingPathComponent("map/snapshot.json")
        try await cache.save(first, to: url)
        try await cache.save(second, to: url)
        #expect(try await cache.load(from: url, taskID: context.ticketID)?.generatedAt == mapNow)
        await #expect(throws: MapError.self) { try await cache.load(from: url, taskID: "OTHER") }
    }

    @Test("No workspace or heartbeat yields useful context without invented activity")
    func emptyAndUnregistered() async throws {
        let (root, initial) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var context = initial; context.worktreePath = nil; context.repositoryPath = nil
        context.subtasks = [TaskSubtask(id: "queued", title: "Pending", status: .queued)]
        let snapshot = try await WorkspaceCollector().collect(context: context, sessions: [], now: mapNow)
        #expect(!snapshot.warnings.isEmpty)
        #expect(snapshot.nodes.filter { $0.kind == .agent }.first?.state(at: mapNow) == "queued")
        #expect(snapshot.nodes.contains { $0.kind == .queue })
    }

    @Test("Schema rejects missing parents, duplicate IDs, cycles, and incompatible versions")
    func validation() throws {
        let root = MapNode(id: "queue", parentID: nil, kind: .queue, label: "Queue", evidence: "context")
        let child = MapNode(id: "child", parentID: "queue", kind: .folder, label: "Sources", evidence: "Git")
        var snapshot = MapSnapshot(taskID: "TEST", generatedAt: mapNow, nodes: [root, child])
        _ = try snapshot.validated()
        snapshot.nodes.append(child)
        #expect(throws: MapError.self) { try snapshot.validated() }
        snapshot.nodes = [root, child]; snapshot.nodes[1].parentID = "missing"
        #expect(throws: MapError.self) { try snapshot.validated() }
        snapshot.nodes[1].parentID = "child"
        #expect(throws: MapError.self) { try snapshot.validated() }
        snapshot.nodes = [root]; snapshot.schemaVersion = 99
        #expect(throws: MapError.self) { try snapshot.validated() }
    }

    @Test("Layout retains ancestors during filtering and is stable across timestamp-only refreshes")
    func layout() async throws {
        let (root, initial) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var context = initial
        context.subtasks = [TaskSubtask(id: "one", title: "Blocked agent", status: .blocked)]
        let snapshot = try await WorkspaceCollector(runner: MapRunner(root: root.path)).collect(context: context, sessions: [], now: mapNow)
        let expanded = Set(snapshot.nodes.map(\.id))
        let first = MapLayout(snapshot: snapshot, expanded: expanded)
        var newer = snapshot; newer.generatedAt = mapNow.addingTimeInterval(5)
        let second = MapLayout(snapshot: newer, expanded: expanded)
        #expect(first.items.map(\.id) == second.items.map(\.id))
        let attention = MapLayout(snapshot: snapshot, expanded: [], attentionOnly: true)
        #expect(attention.items.map { $0.node.kind } == [.queue, .workspace, .agent])
        let search = MapLayout(snapshot: snapshot, expanded: [], search: "Hello world.swift")
        #expect(search.items.map { $0.node.kind } == [.queue, .workspace, .folder, .file])
        let changes = MapLayout(snapshot: snapshot, expanded: [], changesOnly: true)
        #expect(changes.items.contains { $0.node.label == "Hello world.swift" })
        #expect(!changes.items.contains { $0.node.label == "Quiet.swift" })
        #expect(MapLayout(snapshot: snapshot, expanded: expanded, limit: 3).items.count == 3)
    }

    @Test("Old registrations cannot steal a reassigned subtask's progress")
    func reassignedSession() async throws {
        let (root, initial) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var context = initial
        context.subtasks = [TaskSubtask(id: "subtask", title: "Current assignment", sessionID: "new-session", status: .blocked)]
        let sessions = [TaskAgentSession(ticketID: context.ticketID, provider: .codex, sessionID: "old-session", tabTitle: "Old", workingDirectory: root.path, subtaskID: "subtask"),
                        TaskAgentSession(ticketID: context.ticketID, provider: .codex, sessionID: "new-session", tabTitle: "New", workingDirectory: root.path, subtaskID: "subtask")]
        let snapshot = try await WorkspaceCollector(runner: MapRunner(root: root.path)).collect(context: context, sessions: sessions)
        #expect(snapshot.nodes.first { $0.sessionID == "new-session" }?.reportedState == "blocked")
        #expect(snapshot.nodes.first { $0.sessionID == "old-session" }?.reportedState == "unknown")
    }

    @Test("A linked worktree retains identity when its directory moves")
    func movedWorktree() async throws {
        let (root, initial) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo"), linked = root.appendingPathComponent("linked"), moved = root.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let runner = FoundationProcessRunner()
        for args in [["init", "-q"], ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "core.hooksPath=/dev/null", "commit", "-qm", "Fixture", "--allow-empty"],
                     ["worktree", "add", "-b", "map", linked.path]] {
            #expect(try await runner.run(.init(executable: "/usr/bin/git", arguments: args, workingDirectory: repo.path)).succeeded)
        }
        var context = initial; context.worktreePath = linked.path; context.repositoryPath = repo.path
        let collector = WorkspaceCollector()
        let before = try await collector.collect(context: context, sessions: [])
        #expect(try await runner.run(.init(executable: "/usr/bin/git", arguments: ["worktree", "move", linked.path, moved.path], workingDirectory: repo.path)).succeeded)
        context.worktreePath = moved.path
        let after = try await collector.collect(context: context, sessions: [])
        #expect(before.nodes.first { $0.kind == .workspace }?.id == after.nodes.first { $0.kind == .workspace }?.id)
        let actual = try #require(after.nodes.first { $0.kind == .workspace }?.path)
        #expect(URL(fileURLWithPath: actual).resolvingSymlinksInPath() == moved.resolvingSymlinksInPath())
    }

    @Test("File actions handle spaces, traversal, symlink escapes, deleted paths, and readonly argv")
    func openActions() async throws {
        let (root, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside.md")
        try Data("context".utf8).write(to: outside)
        let workspace = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let file = workspace.appendingPathComponent("a $(touch nope) 'quoted'.swift")
        try Data("source".utf8).write(to: file)
        let queue = MapNode(id: "queue", parentID: nil, kind: .queue, label: "Queue", evidence: "context")
        var node = MapNode(id: "file", parentID: "queue", kind: .file, label: "Code", path: file.path,
                           allowedRoot: workspace.path, evidence: "Git")
        func snapshot(_ node: MapNode) -> MapSnapshot { MapSnapshot(taskID: "TEST", generatedAt: mapNow, nodes: [queue, node]) }
        #expect(try MapOpenAction.resolve(nodeID: "file", snapshot: snapshot(node)) == .code(file))
        #expect(MapOpenAction.neovimArguments(path: file.path) == ["-R", "-M", "--", file.path])
        let link = workspace.appendingPathComponent("linked.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        node.path = link.path
        #expect(throws: MapError.self) { try MapOpenAction.resolve(nodeID: "file", snapshot: snapshot(node)) }
        node.path = workspace.appendingPathComponent("../outside.md").path
        #expect(throws: MapError.self) { try MapOpenAction.resolve(nodeID: "file", snapshot: snapshot(node)) }
        node.path = file.path; try FileManager.default.removeItem(at: file)
        #expect(throws: MapError.self) { try MapOpenAction.resolve(nodeID: "file", snapshot: snapshot(node)) }
        node.path = outside.path; node.allowedRoot = outside.path
        #expect(try MapOpenAction.resolve(nodeID: "file", snapshot: snapshot(node)) == .markdown(outside))
    }

    @Test("Actual Git worktree collection observes renamed and untracked files")
    func gitIntegration() async throws {
        let (root, initial) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("actual repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let runner = FoundationProcessRunner()
        func git(_ args: [String]) async throws {
            let result = try await runner.run(.init(executable: "/usr/bin/git", arguments: args, workingDirectory: repo.path))
            #expect(result.succeeded, "\(result.standardError)")
        }
        try await git(["init", "-q"])
        try Data("original".utf8).write(to: repo.appendingPathComponent("old name.swift"))
        try await git(["add", "."])
        try await git(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "core.hooksPath=/dev/null", "commit", "-qm", "Fixture"])
        try await git(["mv", "old name.swift", "new name.swift"])
        try Data("new".utf8).write(to: repo.appendingPathComponent("新しい.md"))
        var context = initial; context.worktreePath = repo.path; context.repositoryPath = repo.path
        let snapshot = try await WorkspaceCollector().collect(context: context, sessions: [])
        #expect(snapshot.warnings.isEmpty)
        #expect(snapshot.nodes.first { $0.label == "new name.swift" }?.summary.contains("old name.swift") == true)
        #expect(snapshot.nodes.first { $0.label == "新しい.md" }?.gitStatus == "??")
    }
}
