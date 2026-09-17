import Foundation
import Testing
@testable import FocusQueueCore

@Suite("External agent registration")
struct ExternalAgentRegistrationTests {
    private func fixture(twoTasks: Bool = false) async throws -> (URL, TaskContextStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("registration-test-" + UUID().uuidString)
        let store = TaskContextStore(root: root)
        for id in twoTasks ? ["ECC-101", "ECC-102"] : ["ECC-101"] {
            _ = try await store.ensureContext(ticket: DashboardTicket(id: id, title: id, status: "open", summary: ""))
            _ = try await store.setWorktree(ticketID: id, path: root.path, branch: nil,
                baseBranch: nil, managed: false, repositoryPath: root.path)
        }
        return (root, store)
    }

    @Test("Explicit attachment replaces a deleted association without reviving its old work")
    func clearedAssociation() async throws {
        let (root, store) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ExternalAgentRegistry(root: root)
        let id = UUID().uuidString
        let event = ExternalAgentEvent(sessionID: id, cwd: root.path, hookEventName: "SessionStart")
        let first = try await registry.register(event, provider: .codex, explicitTaskID: "ECC-101",
            environment: ["FOCUS_QUEUE_TASK_ID": "ECC-101", "FOCUS_QUEUE_SUBTASK_ID": "deleted-subtask"])
        #expect(first.status == "registered")
        #expect(first.subtaskID != "deleted-subtask")
        let again = try await registry.register(event, provider: .codex)
        #expect(again.subtaskID == first.subtaskID)
        #expect(try await store.load(ticketID: "ECC-101")?.subtasks.count == 1)
        _ = try await store.clearSubtasks(ticketID: "ECC-101")
        let automatic = try await registry.register(event, provider: .codex)
        #expect(automatic.status == "unassigned")
        #expect(try await store.load(ticketID: "ECC-101")?.subtasks.isEmpty == true)
        let explicit = try await registry.register(event, provider: .codex, explicitTaskID: "ECC-101")
        #expect(explicit.subtaskID != first.subtaskID)
        #expect(explicit.status == "registered")
        let subsequent = try await registry.register(event, provider: .codex,
            environment: ["FOCUS_QUEUE_TASK_ID": "ECC-101", "FOCUS_QUEUE_SUBTASK_ID": "deleted-subtask"])
        #expect(subsequent.subtaskID == explicit.subtaskID)
    }

    @Test("Ambiguous workspaces remain unassigned and inherited session IDs cannot replace hook identity")
    func ambiguousWorkspace() async throws {
        let (root, store) = try await fixture(twoTasks: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ExternalAgentRegistry(root: root)
        let exact = UUID().uuidString
        let event = ExternalAgentEvent(sessionID: exact, cwd: root.path, hookEventName: "UserPromptSubmit",
            prompt: "Work on ECC-101; this text is not assignment authority")
        let record = try await registry.register(event, provider: .codex,
            environment: ["CODEX_SESSION_ID": UUID().uuidString])
        #expect(record.sessionID == exact.lowercased())
        #expect(record.taskID == nil)
        #expect(record.reason?.contains("Several tasks") == true)
        #expect(try await store.load(ticketID: "ECC-101")?.subtasks.isEmpty == true)
        let explicit = try await registry.register(event, provider: .codex, explicitTaskID: "ECC-102")
        #expect(explicit.taskID == "ECC-102")
        let moved = try await registry.register(event, provider: .codex, explicitTaskID: "ECC-101")
        #expect(moved.taskID == "ECC-101")
        #expect(try await store.load(ticketID: "ECC-102")?.subtasks.first?.agentRemovedAt != nil)
        #expect(try await registry.register(event, provider: .codex).taskID == "ECC-101")
    }

    @Test("Subagent start uses its own UUID and discovery shares the same receipt")
    func subagentIdentity() async throws {
        let (root, store) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ExternalAgentRegistry(root: root)
        let parentID = UUID().uuidString, childID = UUID().uuidString
        let parent = try await registry.register(.init(sessionID: parentID, cwd: root.path,
            hookEventName: "SessionStart"), provider: .codex, explicitTaskID: "ECC-101")
        let child = try await registry.register(.init(sessionID: parentID, cwd: root.path,
            hookEventName: "SubagentStart", agentID: childID), provider: .codex)
        let discovery = try await registry.register(.init(sessionID: childID, cwd: root.path,
            hookEventName: "ProcessDiscovery"), provider: .codex, paneID: 45)
        #expect(child.sessionID == childID.lowercased())
        #expect(child.parentSessionID == parentID.lowercased())
        #expect(child.subtaskID != parent.subtaskID)
        #expect(discovery.id == child.id)
        #expect(discovery.parentSessionID == parentID.lowercased())
        #expect(discovery.paneID == nil, "A child sharing the parent process cannot relabel the parent's pane")
        #expect(try await registry.registrations().count == 2)
        #expect(try await store.load(ticketID: "ECC-101")?.subtasks.count == 2)
        let opaque = try await registry.register(.init(sessionID: parentID, cwd: root.path,
            hookEventName: "SubagentStart", agentID: "opaque-child"), provider: .claude)
        #expect(opaque.sessionID == nil)
        #expect(opaque.taskID == nil)
    }

    @Test("Concurrent event writers retain one association and a useful prompt title")
    func concurrentEvents() async throws {
        let (root, store) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID().uuidString
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask {
                    _ = try await ExternalAgentRegistry(root: root).register(.init(sessionID: sessionID,
                        cwd: root.path, hookEventName: index == 0 ? "UserPromptSubmit" : "ProcessDiscovery",
                        prompt: index == 0 ? "Fix pane registration" : nil), provider: .codex)
                }
            }
            try await group.waitForAll()
        }
        let registry = ExternalAgentRegistry(root: root)
        let records = try await registry.registrations()
        #expect(records.count == 1)
        #expect(records.first?.title == "Fix pane registration")
        #expect(try await store.load(ticketID: "ECC-101")?.subtasks.count == 1)
        try Data("damaged".utf8).write(to: root.appendingPathComponent("external-agent-sessions/bad.json"))
        #expect(try await registry.registrations().count == 1)
    }

    @Test("Discovery never changes completed work or counts presence as activity")
    func completedAndIdle() async throws {
        let (root, store) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ExternalAgentRegistry(root: root)
        let sessionID = UUID().uuidString
        let first = try await registry.register(.init(sessionID: sessionID, cwd: root.path,
            hookEventName: "UserPromptSubmit", prompt: "Check panes"), provider: .codex)
        let before = try #require(try await store.load(ticketID: "ECC-101")?.subtasks.first)
        _ = try await registry.register(.init(sessionID: sessionID, cwd: root.path,
            hookEventName: "ProcessDiscovery"), provider: .codex)
        #expect(try await store.load(ticketID: "ECC-101")?.subtasks.first?.lastHeartbeatAt == before.lastHeartbeatAt)
        _ = try await store.overrideCompletion(ticketID: "ECC-101", subtaskID: try #require(first.subtaskID))
        let after = try await registry.register(.init(sessionID: sessionID, cwd: root.path,
            hookEventName: "SessionStart"), provider: .codex)
        #expect(after.taskID == nil)
        #expect(try await store.load(ticketID: "ECC-101")?.subtasks.first?.status == .completed)
    }
}
