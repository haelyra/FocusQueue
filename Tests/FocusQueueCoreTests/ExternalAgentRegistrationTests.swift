import CryptoKit
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

    @Test("Launch metadata resolves an exact pane inside a shared task session and keeps legacy names")
    func launchMetadataMatchesExactReference() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("launch-metadata-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("shell/launch-metadata")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let first = TmuxSessionReference(name: "fq-task-ecc-101", serverPID: 10,
            createdAt: 20, paneID: "%3", panePID: 30, tty: "/dev/ttys003",
            executable: "/mock/tmux")
        let second = TmuxSessionReference(name: first.name, serverPID: first.serverPID,
            createdAt: first.createdAt, paneID: "%4", panePID: 40,
            tty: "/dev/ttys004", executable: first.executable)
        func write(_ name: String, prompt: String, reference: TmuxSessionReference) throws {
            let payload: [String: Any] = [
                "initialPrompt": prompt,
                "reference": ["name": reference.name, "serverPID": reference.serverPID,
                    "createdAt": reference.createdAt, "paneID": reference.paneID,
                    "panePID": reference.panePID, "tty": reference.tty,
                    "executable": reference.executable],
            ]
            try JSONSerialization.data(withJSONObject: payload)
                .write(to: directory.appendingPathComponent(name + ".json"))
        }
        try write("fq-task-ecc-101-agent-one", prompt: "First pane", reference: first)
        try write("fq-task-ecc-101-agent-two", prompt: "Second pane", reference: second)

        #expect(try ExternalAgentLaunchMetadata.load(
            matching: second, supportDirectory: root)?.initialPrompt == "Second pane")

        try FileManager.default.removeItem(at: directory.appendingPathComponent("fq-task-ecc-101-agent-one.json"))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("fq-task-ecc-101-agent-two.json"))
        try write(first.name, prompt: "Legacy pane", reference: first)
        #expect(try ExternalAgentLaunchMetadata.load(
            matching: first, supportDirectory: root)?.initialPrompt == "Legacy pane")
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

    @Test("A provider session with multiple active task owners fails closed")
    func duplicateActiveOwnersFailClosed() async throws {
        let (root, store) = try await fixture(twoTasks: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID().uuidString.lowercased()
        for taskID in ["ECC-101", "ECC-102"] {
            var subtask = TaskSubtask(
                id: "agent-\(taskID.lowercased())", title: "Duplicate owner",
                provider: .codex, sessionID: sessionID, status: .working)
            subtask.workspace = AgentWorkspace(path: root.path, repositoryPath: root.path)
            _ = try await store.upsertSubtask(ticketID: taskID, subtask: subtask)
        }

        let record = try await ExternalAgentRegistry(root: root).register(
            .init(sessionID: sessionID, cwd: root.path, hookEventName: "ProcessDiscovery"),
            provider: .codex,
            explicitTaskID: "ECC-101",
            environment: ["FOCUS_QUEUE_TASK_ID": "ECC-101"])

        #expect(record.taskID == nil)
        #expect(record.subtaskID == nil)
        #expect(record.reason?.contains("Several active tasks claim") == true)
        #expect(try await store.load(ticketID: "ECC-101")?.subtasks.count == 1)
        #expect(try await store.load(ticketID: "ECC-102")?.subtasks.count == 1)
    }

    @Test("A Codex subagent start keeps its own UUID without adding an agent")
    func subagentIdentity() async throws {
        let (root, store) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ExternalAgentRegistry(root: root)
        let parentID = UUID().uuidString, childID = UUID().uuidString
        let parent = try await registry.register(.init(sessionID: parentID, cwd: root.path,
            hookEventName: "SessionStart"), provider: .codex, explicitTaskID: "ECC-101")
        let child = try await registry.register(.init(sessionID: parentID, cwd: root.path,
            hookEventName: "SubagentStart", agentID: childID), provider: .codex)
        #expect(child.sessionID == childID.lowercased())
        #expect(child.parentSessionID == parentID.lowercased())
        #expect(child.taskID == nil && child.subtaskID == nil)
        #expect(child.reason == ExternalAgentRegistry.codexSubagentReason)
        #expect(try await registry.registrations().map(\.id) == [parent.id])
        #expect(try await store.load(ticketID: "ECC-101")?.subtasks.count == 1)
        let opaque = try await registry.register(.init(sessionID: parentID, cwd: root.path,
            hookEventName: "SubagentStart", agentID: "opaque-child"), provider: .claude)
        #expect(opaque.sessionID == nil)
        #expect(opaque.taskID == nil)
    }

    @Test("Discovered Codex subagents stay under their parent's single agent")
    func discoveredSubagentsDoNotAddAgents() async throws {
        let (root, store) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ExternalAgentRegistry(root: root)
        let parentID = UUID().uuidString
        let siblings = [UUID().uuidString, UUID().uuidString]
        let parent = try await registry.register(.init(
            sessionID: parentID, cwd: root.path, hookEventName: "SessionStart"
        ), provider: .codex, explicitTaskID: "ECC-101")
        // A receipt saved by an older build is removed on the next discovery pass.
        let staleID = SHA256.hash(data: Data(("codex:" + siblings[0].lowercased()).utf8))
            .map { String(format: "%02x", $0) }.joined()
        let stale = ExternalAgentRegistration(id: staleID, provider: .codex,
            sessionID: siblings[0].lowercased(), parentSessionID: parentID.lowercased(),
            cwd: root.path, title: "Subagent", taskID: "ECC-101", subtaskID: "old",
            eventName: "ProcessDiscovery", updatedAt: Date())
        try JSONEncoder().encode(stale).write(to: root
            .appendingPathComponent("external-agent-sessions/\(staleID).json"))
        #expect(try await registry.registrations().count == 2)

        for sibling in siblings {
            for _ in 0..<2 {
                let child = try await registry.register(.init(
                    sessionID: sibling, cwd: root.path, hookEventName: "ProcessDiscovery",
                    parentSessionID: parentID, discoveredAsSubagent: true
                ), provider: .codex, environment: ["FOCUS_QUEUE_TASK_ID": "ECC-101",
                    "FOCUS_QUEUE_SUBTASK_ID": try #require(parent.subtaskID)])
                #expect(child.taskID == nil && child.subtaskID == nil)
                #expect(child.parentSessionID == parentID.lowercased())
            }
        }

        let context = try #require(try await store.load(ticketID: "ECC-101"))
        #expect(context.subtasks.map(\.sessionID) == [parentID.lowercased()])
        #expect(try await registry.registrations().map(\.id) == [parent.id])
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
        #expect(records.first?.workDescription == "Fix pane registration")
        let saved = try await store.load(ticketID: "ECC-101")
        #expect(saved?.subtasks.count == 1)
        #expect(saved?.subtasks.first?.workDescription == "Fix pane registration")
        try Data("damaged".utf8).write(to: root.appendingPathComponent("external-agent-sessions/bad.json"))
        #expect(try await registry.registrations().count == 1)
    }

    @Test("First prompt names a promptless app agent once",
          arguments: ["Agent 1", "Codex agent", "Codex agent 2", "Claude agent"])
    func firstPromptNamesDefaultAgent(defaultTitle: String) async throws {
        let (root, store) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID().uuidString
        var agent = TaskSubtask(
            id: "promptless", title: defaultTitle, assignmentDescription: "",
            provider: .codex, status: .queued, includeInitializationPrompt: false)
        agent.workspace = AgentWorkspace(path: root.path, repositoryPath: root.path)
        _ = try await store.upsertSubtask(ticketID: "ECC-101", subtask: agent)
        let environment = [
            "FOCUS_QUEUE_TASK_ID": "ECC-101", "FOCUS_QUEUE_SUBTASK_ID": agent.id,
        ]
        let registry = ExternalAgentRegistry(root: root)
        _ = try await registry.register(.init(
            sessionID: sessionID, cwd: root.path, hookEventName: "SessionStart"
        ), provider: .codex, environment: environment)
        _ = try await registry.register(.init(
            sessionID: sessionID, cwd: root.path, hookEventName: "UserPromptSubmit",
            prompt: "Fix blank agent startup. Keep the saved tmux session intact."
        ), provider: .codex, environment: environment)
        var saved = try #require(try await store.load(ticketID: "ECC-101")?.subtasks.first)
        #expect(saved.title == "Fix blank agent startup")
        #expect(saved.assignmentDescription == "Fix blank agent startup.")

        _ = try await registry.register(.init(
            sessionID: sessionID, cwd: root.path, hookEventName: "UserPromptSubmit",
            prompt: "Do not replace the established identity. This is a later prompt."
        ), provider: .codex, environment: environment)
        saved = try #require(try await store.load(ticketID: "ECC-101")?.subtasks.first)
        #expect(saved.title == "Fix blank agent startup")
        #expect(saved.assignmentDescription == "Fix blank agent startup.")
    }

    @Test("Discovery metadata cannot replace a routed title and description")
    func discoveryPreservesRoutedIdentity() async throws {
        let (root, store) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID().uuidString
        var agent = TaskSubtask(
            id: "routed-agent", title: "Repair agent tracking",
            assignmentDescription: "Keep routed agents visible and uniquely identified.",
            provider: .codex, status: .queued)
        agent.workspace = AgentWorkspace(path: root.path, repositoryPath: root.path)
        _ = try await store.upsertSubtask(ticketID: "ECC-101", subtask: agent)

        _ = try await ExternalAgentRegistry(root: root).register(.init(
            sessionID: sessionID, cwd: root.path, hookEventName: "ProcessDiscovery",
            prompt: "Stale launch metadata that must not become the display identity."
        ), provider: .codex, environment: [
            "FOCUS_QUEUE_TASK_ID": "ECC-101", "FOCUS_QUEUE_SUBTASK_ID": agent.id,
        ])

        let saved = try #require(try await store.load(ticketID: "ECC-101")?.subtasks.first)
        #expect(saved.title == "Repair agent tracking")
        #expect(saved.assignmentDescription == "Keep routed agents visible and uniquely identified.")
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

    @Test("registeredAt is set on first registration, preserved across updates, and legacy records decode")
    func registeredAtFirstSeenAndLegacyDecode() async throws {
        let (root, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ExternalAgentRegistry(root: root)
        let sessionID = UUID().uuidString
        let first = try await registry.register(.init(
            sessionID: sessionID, cwd: root.path, hookEventName: "SessionStart"), provider: .codex)
        #expect(first.registeredAt == first.updatedAt)
        try await Task.sleep(for: .milliseconds(20))
        let second = try await registry.register(.init(
            sessionID: sessionID, cwd: root.path, hookEventName: "ProcessDiscovery"), provider: .codex)
        #expect(abs(second.registeredAt.timeIntervalSince(first.registeredAt)) < 0.001)
        #expect(second.updatedAt > first.updatedAt)

        // Records saved before first-seen tracking fall back to their last update.
        let file = root.appendingPathComponent(
            "external-agent-sessions/\(first.id).json")
        var legacy = try #require(try JSONSerialization.jsonObject(
            with: Data(contentsOf: file)) as? [String: Any])
        legacy.removeValue(forKey: "registeredAt")
        try JSONSerialization.data(withJSONObject: legacy).write(to: file)
        let decoded = try #require(try await registry.registrations().first { $0.id == first.id })
        #expect(abs(decoded.registeredAt.timeIntervalSince(decoded.updatedAt)) < 0.001)
        #expect(decoded.taskID == "ECC-101")
    }

    @Test("A discovery prompt hint upgrades the provider-code fallback title without hooks")
    func promptHintUpgradesFallbackTitle() async throws {
        let (root, store) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ExternalAgentRegistry(root: root)
        let sessionID = UUID().uuidString
        let fallback = try await registry.register(.init(
            sessionID: sessionID, cwd: root.path, hookEventName: "SessionStart"), provider: .codex)
        #expect(fallback.title == "Codex · \(sessionID.suffix(6))")
        #expect(fallback.taskID == "ECC-101")

        let discovered = try await registry.register(.init(
            sessionID: sessionID, cwd: root.path, hookEventName: "ProcessDiscovery",
            prompt: "Review the queue registration flow"), provider: .codex)
        #expect(discovered.title == "Review the queue registration flow")
        #expect(discovered.subtaskID == fallback.subtaskID)
        let saved = try #require(try await store.load(ticketID: "ECC-101")?.subtasks.first)
        #expect(saved.title == "Review the queue registration flow")
        #expect(abs(discovered.registeredAt.timeIntervalSince(fallback.registeredAt)) < 0.001)

        // The real first prompt still adopts over a provisional fallback title.
        let hookedSession = UUID().uuidString
        _ = try await registry.register(.init(
            sessionID: hookedSession, cwd: root.path, hookEventName: "SessionStart"), provider: .codex)
        _ = try await registry.register(.init(
            sessionID: hookedSession, cwd: root.path, hookEventName: "UserPromptSubmit",
            prompt: "Fix the actual registration bug"), provider: .codex)
        let adopted = try #require(try await store.load(ticketID: "ECC-101")?.subtasks
            .first { $0.sessionID == hookedSession.lowercased() })
        #expect(adopted.title == "Fix the actual registration bug")
    }

    @Test("Discovery binds a routed launch through its environment and keeps the routed identity")
    func routedDiscoveryBindsThroughLaunchEnvironment() async throws {
        let (root, store) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var agent = TaskSubtask(
            id: "routed-launch", title: "Repair agent tracking",
            assignmentDescription: "Keep routed agents visible and uniquely identified.",
            provider: .codex, status: .queued)
        agent.workspace = AgentWorkspace(
            path: root.path, repositoryPath: root.path, branch: "fq/ecc-101/routed", managed: true)
        _ = try await store.upsertSubtask(ticketID: "ECC-101", subtask: agent)
        let tmux = TmuxSessionReference(name: "fq-task-ecc-101", serverPID: 10,
            createdAt: 20, paneID: "%3", panePID: 30, tty: "/dev/ttys003",
            executable: "/mock/tmux")
        let sessionID = UUID().uuidString
        // The hint supplies the fixed task, agent, and objective the launch knew.
        let record = try await ExternalAgentRegistry(root: root).register(.init(
            sessionID: sessionID, cwd: root.path, hookEventName: "ProcessDiscovery",
            prompt: "Repair agent tracking and keep agents visible"), provider: .codex,
            environment: ["FOCUS_QUEUE_TASK_ID": "ECC-101", "FOCUS_QUEUE_SUBTASK_ID": agent.id],
            tmux: tmux)
        #expect(record.taskID == "ECC-101")
        #expect(record.subtaskID == agent.id)
        #expect(record.sessionID == sessionID.lowercased())
        #expect(record.tmux == tmux)
        #expect(record.registeredAt <= Date())
        let saved = try #require(try await store.load(ticketID: "ECC-101")?.subtasks.first)
        #expect(saved.title == "Repair agent tracking")
        #expect(try await store.load(ticketID: "ECC-101")?.subtasks.count == 1)
        #expect(AgentRegistrationValidator.missingFields(record: record, subtask: saved) == [])
    }

    @Test("App-written launch metadata loads with its prompt for discovery naming")
    func launchMetadataSaveLoad() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("launch-metadata-save-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let reference = TmuxSessionReference(name: "fq-task-ecc-101", serverPID: 10,
            createdAt: 20, paneID: "%3", panePID: 30, tty: "/dev/ttys003",
            executable: "/mock/tmux")
        try ExternalAgentLaunchMetadata(
            initialPrompt: "Fix pane registration", reference: reference,
            provider: .codex, cwd: "/tmp"
        ).save(name: "fq-task-ecc-101-agent-1", supportDirectory: root)
        let loaded = try #require(try ExternalAgentLaunchMetadata.load(
            matching: reference, supportDirectory: root))
        #expect(loaded.initialPrompt == "Fix pane registration")
        #expect(loaded.provider == "codex")
        let file = root.appendingPathComponent(
            "shell/launch-metadata/fq-task-ecc-101-agent-1.json")
        #expect((try? FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]
            as? Int) == 0o600)
    }

    @Test("Completeness validation flags missing task, session, tmux, worktree, and branch data")
    func completenessValidation() throws {
        let tmux = TmuxSessionReference(name: "fq-task-ecc-101", serverPID: 10,
            createdAt: 20, paneID: "%3", panePID: 30, tty: "/dev/ttys003",
            executable: "/mock/tmux")
        func record(taskID: String? = "ECC-101",
                    sessionID: String? = UUID().uuidString,
                    tmux: TmuxSessionReference? = nil) -> ExternalAgentRegistration {
            ExternalAgentRegistration(
                id: UUID().uuidString, provider: .codex, sessionID: sessionID,
                cwd: "/tmp", title: "Agent", taskID: taskID,
                eventName: "ProcessDiscovery", updatedAt: Date(), tmux: tmux)
        }
        #expect(AgentRegistrationValidator.missingFields(
            record: record(taskID: nil), subtask: nil) == ["task"])
        #expect(AgentRegistrationValidator.missingFields(
            record: record(sessionID: nil), subtask: nil) == ["provider session"])
        #expect(AgentRegistrationValidator.missingFields(record: record(), subtask: nil) == [])

        // Managed tmux agents require their tmux reference.
        var managed = TaskSubtask(id: "managed", title: "Managed", provider: .codex,
            runtimeMode: .tmux)
        #expect(AgentRegistrationValidator.missingFields(
            record: record(), subtask: managed) == ["tmux session"])
        #expect(AgentRegistrationValidator.missingFields(
            record: record(tmux: tmux), subtask: managed) == [])
        managed.tmux = tmux
        #expect(AgentRegistrationValidator.missingFields(
            record: record(), subtask: managed) == [])

        // Isolated-workspace launches require the worktree and its branch.
        var isolated = TaskSubtask(id: "isolated", title: "Isolated", provider: .codex,
            runtimeMode: nil)
        isolated.workspace = AgentWorkspace(path: "/tmp/wt", repositoryPath: "/tmp", managed: true)
        #expect(AgentRegistrationValidator.missingFields(
            record: record(), subtask: isolated) == ["branch"])
        isolated.workspace = AgentWorkspace(
            path: "/tmp/wt", repositoryPath: "/tmp", branch: "fq/ecc-101/isolated", managed: true)
        #expect(AgentRegistrationValidator.missingFields(
            record: record(), subtask: isolated) == [])
        let issue = AgentRegistrationValidator.issue(
            record: record(taskID: nil, sessionID: nil), subtask: nil)
        #expect(issue?.missingFields == ["task", "provider session"])
        #expect(issue?.summary.contains("missing task, provider session") == true)
    }

    @Test("Attach, hook, and launcher launch paths each produce a complete registration")
    func launchPathsProduceCompleteRegistrations() async throws {
        let (root, store) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ExternalAgentRegistry(root: root)

        // focus-queue-session attach <TICKET-ID> from the agent's pane.
        let attached = try await registry.register(.init(
            sessionID: UUID().uuidString, cwd: root.path, hookEventName: "ExplicitAttach"),
            provider: .claude, explicitTaskID: "ECC-101")
        #expect(attached.taskID == "ECC-101")
        #expect(attached.subtaskID != nil)
        #expect(attached.sessionID != nil)
        #expect(attached.registeredAt <= Date())

        // Provider hook register-event with the first prompt.
        let hooked = try await registry.register(.init(
            sessionID: UUID().uuidString, cwd: root.path, hookEventName: "UserPromptSubmit",
            prompt: "Summarize the routing plan"), provider: .codex)
        #expect(hooked.taskID == "ECC-101")
        #expect(hooked.title == "Summarize the routing plan")
        #expect(hooked.registeredAt <= Date())

        // New-agent launcher: provisional agent plus inherited launch environment.
        var agent = TaskSubtask(id: "launcher-agent", title: "Agent 1", provider: .codex,
            status: .queued, includeInitializationPrompt: false, runtimeMode: .terminal)
        agent.workspace = AgentWorkspace(path: root.path, repositoryPath: root.path)
        _ = try await store.upsertSubtask(ticketID: "ECC-101", subtask: agent)
        let launched = try await registry.register(.init(
            sessionID: UUID().uuidString, cwd: root.path, hookEventName: "SessionStart"),
            provider: .codex,
            environment: ["FOCUS_QUEUE_TASK_ID": "ECC-101", "FOCUS_QUEUE_SUBTASK_ID": agent.id],
            paneID: 42, socketPath: "/tmp/wezterm.sock")
        #expect(launched.taskID == "ECC-101")
        #expect(launched.subtaskID == agent.id)
        #expect(launched.paneID == 42)
        #expect(launched.registeredAt <= Date())

        for record in [attached, hooked, launched] {
            let subtask = try await store.load(ticketID: "ECC-101")?.subtasks
                .first { $0.id == record.subtaskID }
            #expect(AgentRegistrationValidator.missingFields(record: record, subtask: subtask) == [])
        }
    }
}
