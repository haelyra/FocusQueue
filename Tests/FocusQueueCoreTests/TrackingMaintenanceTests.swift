import Foundation
import Testing
@testable import FocusQueueCore

@Suite("Lightweight tracking and maintenance")
struct TrackingMaintenanceTests {
    @Test("Real Git maintenance retains dirty and unmerged work, then removes only a clean merged inactive workspace")
    func realGitLifecycle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("maintenance-git-\(UUID())").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo"), support = root.appendingPathComponent("support")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        func git(_ args: [String], at directory: String) async throws {
            let result = try await FoundationProcessRunner().run(.init(executable: "/usr/bin/git", arguments: args, workingDirectory: directory))
            try #require(result.succeeded, "\(result.standardError)")
        }
        try await git(["init", "-q", "-b", "main"], at: repo.path)
        let commit = ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "core.hooksPath=/dev/null", "commit", "--allow-empty", "-qm", "Fixture"]
        try await git(commit, at: repo.path)
        let store = TaskContextStore(root: support)
        let ticket = DashboardTicket(id: "ECC-1", title: "Git lifecycle", status: "open", summary: "")
        _ = try await store.ensureContext(ticket: ticket)
        var agent = TaskSubtask(id: UUID().uuidString, title: "Done", sessionID: UUID().uuidString, status: .completed)
        let workspace = try await TaskWorktreeManager().provisionAgent(ticketID: ticket.id, subtaskID: agent.id,
            path: repo.path, policy: .isolatedCommittedSnapshot, store: store)
        agent.workspace = workspace
        _ = try await store.upsertSubtask(ticketID: ticket.id, subtask: agent)
        let maintenance = TaskMaintenance(root: support, inspect: { _ in false })
        try Data("retain me".utf8).write(to: URL(fileURLWithPath: workspace.path).appendingPathComponent("local.txt"))
        #expect(try await maintenance.run(ticket: ticket).agentStates[agent.id]?.contains("uncommitted") == true)
        try await git(["add", "local.txt"], at: workspace.path)
        try await git(commit, at: workspace.path)
        #expect(try await maintenance.run(ticket: ticket).agentStates[agent.id]?.contains("not been merged") == true)
        try await git(["merge", "--ff-only", try #require(workspace.branch)], at: repo.path)
        #expect(try await maintenance.run(ticket: ticket).agentStates[agent.id]?.contains("Cleaned") == true)
        #expect(!FileManager.default.fileExists(atPath: workspace.path))
        try await git(["show-ref", "--verify", "refs/heads/" + (try #require(workspace.branch))], at: repo.path)
        #expect(try await store.load(ticketID: ticket.id)?.subtasks.first?.sessionID == agent.sessionID)
    }

    @Test("Partial task fields recover without rewriting source and corrupt neighbors do not stop registration")
    func incompleteContext() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tracking-partial-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("tasks/ECC-1")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let raw = Data(#"{"subtasks":[{}, {"provider":"", "title":"", "status":""}],"planPath":"","title":null}"#.utf8)
        let path = folder.appendingPathComponent("context.json")
        try raw.write(to: path)
        let store = TaskContextStore(root: root)
        let context = try #require(try await store.load(ticketID: "ECC-1"))
        #expect(context.title == "ECC-1" && context.successCriteria.isEmpty)
        #expect(context.subtasks[0].status == .queued)
        #expect(context.subtasks[0].sessionID == nil)
        #expect(context.subtasks[1].title == "Agent awaiting details" && context.subtasks[1].status == .queued)
        #expect(try Data(contentsOf: path) == raw)
        #expect(try await store.load(ticketID: "ECC-1")?.subtasks[0].id == context.subtasks[0].id)
        let bad = root.appendingPathComponent("tasks/ECC-2")
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("broken JSON".utf8).write(to: bad.appendingPathComponent("context.json"))
        let record = try await ExternalAgentRegistry(root: root).register(.init(sessionID: UUID().uuidString,
            cwd: root.path, hookEventName: "SessionStart"), provider: .codex, explicitTaskID: "ECC-MISSING")
        #expect(record.status == "unassigned")
        #expect(record.reason?.contains("missing or incomplete") == true)
        #expect(try await ExternalAgentRegistry(root: root).registrations().count == 1)
        await #expect(throws: (any Error).self) { try await store.loadAll() }
    }

    @Test("Provisional receipts tolerate missing data and prevent PID-reuse or cwd-only matching")
    func intakeIdentity() throws {
        let launch = UUID().uuidString, session = UUID().uuidString
        func receipt(_ extra: [String: Any]) throws -> AgentIntakeReceipt {
            try JSONDecoder().decode(AgentIntakeReceipt.self, from: JSONSerialization.data(withJSONObject:
                ["launchID": launch].merging(extra) { _, new in new }))
        }
        let partial = try receipt(["reference": ["name":"partial"]])
        #expect(partial.pendingRegistration.sessionID == nil)
        #expect(partial.pendingRegistration.title == "Codex agent")
        let ready = try receipt(["cwd":"/tmp/repo", "processID":100, "processStartedAt":"start A", "phase":"ready"])
        let process = KnownProviderProcess(provider: .codex, sessionID: session, processID: 101, tty: nil, cwd: "/tmp/repo")
        var parents: [Int32: AgentIntakeStore.ProcessIdentity] = [100: .init(parent: 1, startedAt: "start A"), 101: .init(parent: 100, startedAt: "start B")]
        #expect(AgentIntakeStore.match(process, tmux: nil, receipts: [ready], parents: parents) == nil)
        let reference = TmuxSessionReference(name: "fq-codex-" + launch, serverPID: 10,
            createdAt: 20, paneID: "%3", panePID: 30, tty: "/dev/ttys099", executable: "/mock/tmux")
        let referenced = try receipt(["cwd":"/tmp/repo", "processID":100,
            "processStartedAt":"start A", "phase":"ready",
            "reference": ["name": reference.name, "serverPID": reference.serverPID,
                "createdAt": reference.createdAt, "paneID": reference.paneID,
                "panePID": reference.panePID, "tty": reference.tty,
                "executable": reference.executable]])
        #expect(AgentIntakeStore.match(process, tmux: reference, receipts: [referenced], parents: parents)?.launchID == launch)
        #expect(AgentIntakeStore.match(process, tmux: nil, receipts: [ready], parents: parents,
            candidateSessionsForProcess: [session, UUID().uuidString]) == nil)
        parents[100] = .init(parent: 1, startedAt: "reused PID")
        #expect(AgentIntakeStore.match(process, tmux: reference, receipts: [referenced], parents: parents)?.launchID == launch)
        #expect(AgentIntakeStore.match(process, tmux: nil, receipts: [ready], parents: [:]) == nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("intake-resolution-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try AgentIntakeStore.resolve(ready, sessionID: session, root: root)
        try AgentIntakeStore.resolve(ready, sessionID: session, root: root)
        #expect(throws: (any Error).self) { try AgentIntakeStore.resolve(ready, sessionID: UUID().uuidString, root: root) }
    }

    @Test("Blocked and expired launch receipts remain visible until acknowledged")
    func terminalIntakeReceipts() throws {
        func receipt(_ value: [String: Any]) throws -> AgentIntakeReceipt {
            try JSONDecoder().decode(AgentIntakeReceipt.self,
                from: JSONSerialization.data(withJSONObject: value))
        }
        let blocked = try receipt(["launchID": UUID().uuidString, "phase": "blocked"])
        #expect(!blocked.isTerminal)
        #expect(!blocked.isReadyForDiscovery)
        let old = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-600))
        let crashed = try receipt(["launchID": UUID().uuidString, "phase": "preparing",
            "createdAt": old])
        #expect(!crashed.isTerminal)
        let incomplete = try receipt(["launchID": UUID().uuidString, "phase": "preparing"])
        #expect(!incomplete.isTerminal)
        #expect(!incomplete.isReadyForDiscovery)
    }

    @Test("A launch-keyed placeholder retires into the agent row its placement names")
    func mergeTrackedLaunchRetiresPlaceholder() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("merge-tracked-launch-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskContextStore(root: root)
        _ = try await store.ensureContext(ticket: DashboardTicket(
            id: "ECC-35", title: "Merge placeholder", status: "open", summary: ""))
        let agentID = "63B453D1-F943-4ADE-A8BE-998AE089D2F2"
        let launchID = UUID().uuidString.lowercased()
        var real = TaskSubtask(id: agentID, title: "Integrate and install arrow fix",
            assignmentDescription: "Real work", provider: .codex, status: .working)
        real.tracksCompletion = true
        real.lastHeartbeatAt = Date()
        _ = try await store.upsertSubtask(ticketID: "ECC-35", subtask: real)
        var placeholder = TaskSubtask(id: launchID, title: "Codex agent",
            assignmentDescription: "Tracked launch", provider: .codex, status: .working)
        placeholder.tracksCompletion = false
        placeholder.lastHeartbeatAt = Date()
        _ = try await store.upsertSubtask(ticketID: "ECC-35", subtask: placeholder)

        let context = try await store.mergeTrackedLaunch(
            ticketID: "ECC-35", launchID: launchID, into: agentID.lowercased())

        let merged = try #require(context.subtasks.first { $0.id == launchID })
        #expect(merged.mergedIntoSubtaskID == agentID)
        #expect(merged.agentRemovedAt != nil)
        #expect(!merged.completionUnread)
        #expect(context.hasDismissedLaunch(launchID))
        #expect(context.canonicalSubtaskID(launchID) == agentID)
        let retained = try #require(context.subtasks.first { $0.id == agentID })
        #expect(retained.agentRemovedAt == nil)
        #expect(retained.status == .working)
        // A completed target still retires the placeholder; the merge is idempotent.
        let repeated = try await store.mergeTrackedLaunch(
            ticketID: "ECC-35", launchID: launchID, into: agentID)
        #expect(repeated.subtasks.first { $0.id == launchID }?.mergedIntoSubtaskID == agentID)
    }

    @Test("Provider discovery enriches the provisional queue row with the exact Codex session ID")
    func intakeSessionIdentityEnrichment() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("intake-enrichment-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("repo-worktrees/ecc-35/agents/launch")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let store = TaskContextStore(root: root)
        _ = try await store.ensureContext(ticket: DashboardTicket(
            id: "ECC-35", title: "Session identity", status: "open", summary: ""))
        let launchID = UUID().uuidString.lowercased()
        let data = try JSONSerialization.data(withJSONObject: [
            "launchID": launchID, "agentID": "inherited-agent", "taskID": "ECC-35",
            "cwd": workspace.path, "repositoryPath": root.path,
            "workspacePolicy": "isolated", "phase": "ready", "title": "Track session",
        ])
        let receipt = try JSONDecoder().decode(AgentIntakeReceipt.self, from: data)
        _ = try await store.upsertSubtask(ticketID: "ECC-35", subtask: receipt.provisionalSubtask())
        let sessionID = UUID().uuidString.lowercased()

        let registration = try await ExternalAgentRegistry(root: root).register(
            .init(sessionID: sessionID, cwd: workspace.path,
                hookEventName: "ProcessDiscovery", prompt: receipt.title),
            provider: .codex, explicitTaskID: "ECC-35",
            environment: ["FOCUS_QUEUE_TASK_ID": "ECC-35",
                "FOCUS_QUEUE_SUBTASK_ID": launchID])

        #expect(registration.taskID == "ECC-35")
        #expect(registration.subtaskID == launchID)
        let context = try #require(try await store.load(ticketID: "ECC-35"))
        #expect(context.subtasks.count == 1)
        #expect(context.subtasks[0].id == launchID)
        #expect(context.subtasks[0].sessionID == sessionID)
    }

    @Test("Unchanged maintenance is idempotent and missing UUID never authorizes cleanup")
    func maintenanceIsConservative() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("maintenance-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskContextStore(root: root)
        let ticket = DashboardTicket(id: "ECC-1", title: "Maintenance", status: "open", summary: "", doneWhen: "")
        let context = try await store.ensureContext(ticket: ticket)
        var agent = TaskSubtask(id: UUID().uuidString, title: "Unknown", status: .completed)
        agent.workspace = .init(path: root.path, repositoryPath: root.path, managed: true)
        _ = try await store.upsertSubtask(ticketID: ticket.id, subtask: agent)
        let maintenance = TaskMaintenance(root: root, inspect: { _ in
            Issue.record("Incomplete identity must retain without inspecting runtime"); return false
        }, cleanup: { _, _ in Issue.record("Unknown identity must never clean up"); return .init(removed: false, message: "") })
        let first = try await maintenance.run(ticket: ticket)
        #expect(first.agentStates[agent.id]?.contains("identity pending") == true)
        #expect(!first.notes.isEmpty)
        let receipt = context.contextDirectory.appendingPathComponent("maintenance.json")
        let before = try receipt.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        #expect(try await maintenance.run(ticket: ticket) == first)
        #expect(try receipt.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == before)
        #expect(try FileManager.default.contentsOfDirectory(at: context.contextDirectory.appendingPathComponent("maintenance-history"), includingPropertiesForKeys: nil).count == 1)
    }

    @Test("Verified active agents retain workspaces; only verified stopped agents reach guarded cleanup")
    func completedLifecycle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("maintenance-complete-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskContextStore(root: root)
        let ticket = DashboardTicket(id: "ECC-1", title: "Maintenance", status: "open", summary: "")
        _ = try await store.ensureContext(ticket: ticket)
        var agent = TaskSubtask(id: UUID().uuidString, title: "Completed", sessionID: UUID().uuidString, status: .completed)
        agent.workspace = .init(path: root.path, repositoryPath: root.path, managed: true)
        _ = try await store.upsertSubtask(ticketID: ticket.id, subtask: agent)
        let active = TaskMaintenance(root: root, inspect: { _ in true }, cleanup: { _, _ in
            Issue.record("Live agent cannot be removed"); return .init(removed: true, message: "")
        })
        #expect(try await active.run(ticket: ticket).agentStates[agent.id]?.contains("live agent") == true)
        await #expect(throws: TaskContextError.self) { try await active.requireInactive(agent) }
        let stopped = TaskMaintenance(root: root, inspect: { _ in false }, cleanup: { _, _ in
            .init(removed: false, message: "Unmerged commits retained")
        })
        #expect(try await stopped.run(ticket: ticket).agentStates[agent.id] == "Unmerged commits retained")
        #expect(try await store.load(ticketID: ticket.id)?.subtasks[0].status == .completed)
    }

    @Test("A shared process snapshot answers ownership without per-agent process scans")
    func maintenanceUsesSharedProcessSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("maintenance-snapshot-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskContextStore(root: root)
        let ticket = DashboardTicket(id: "ECC-1", title: "Maintenance", status: "open", summary: "", doneWhen: "")
        _ = try await store.ensureContext(ticket: ticket)
        var agent = TaskSubtask(id: UUID().uuidString, title: "Completed", provider: .codex,
            sessionID: UUID().uuidString, status: .completed)
        agent.workspace = .init(path: root.path, repositoryPath: root.path, managed: true)
        _ = try await store.upsertSubtask(ticketID: ticket.id, subtask: agent)
        let live = TaskMaintenance(root: root, processes: [
            KnownProviderProcess(provider: .codex, sessionID: try #require(agent.sessionID),
                processID: 4242, tty: nil, cwd: "/elsewhere")
        ])
        #expect(try await live.run(ticket: ticket).agentStates[agent.id]?.contains("live agent") == true)
        let stopped = TaskMaintenance(root: root, processes: [], cleanup: { _, _ in
            .init(removed: false, message: "Unmerged commits retained")
        })
        #expect(try await stopped.run(ticket: ticket).agentStates[agent.id] == "Unmerged commits retained")
    }
}
