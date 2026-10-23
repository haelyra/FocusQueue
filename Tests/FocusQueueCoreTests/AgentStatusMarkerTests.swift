import Foundation
import Testing
@testable import FocusQueueCore

/// Status markers must follow what the agent is doing: Working mid-turn,
/// New result only between a finished turn and the person's next prompt.
@Suite("Agent status markers")
struct AgentStatusMarkerTests {
    private func makeStore(_ agent: TaskSubtask) async throws -> (TaskContextStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = TaskContextStore(root: root)
        _ = try await store.ensureContext(ticket: DashboardTicket(id: "ECC-900", title: "Task", status: "open", summary: ""))
        _ = try await store.upsertSubtask(ticketID: "ECC-900", subtask: agent)
        return (store, root)
    }

    private func observe(_ store: TaskContextStore, _ id: String, _ kind: AgentActivityEvent.Kind,
                         at date: Date, eventID: String = UUID().uuidString) async throws -> TaskSubtask {
        let context = try await store.observeActivity(ticketID: "ECC-900", subtaskID: id,
            event: .init(id: eventID, date: date, kind: kind, summary: ""))
        return try #require(context.subtasks.first { $0.id == id })
    }

    private func reference() -> TmuxSessionReference {
        TmuxSessionReference(name: "fq-task-ecc-900", serverPID: 1, createdAt: 1, paneID: "%1",
            panePID: 2, tty: "/dev/ttys001", executable: "/usr/bin/true")
    }

    @Test("A prompt after a result clears the unread marker; unprompted work keeps it")
    func promptAcknowledgesResult() async throws {
        let (store, root) = try await makeStore(TaskSubtask(id: "a", title: "A", sessionID: UUID().uuidString, status: .working))
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date()
        let result = try await observe(store, "a", .result, at: start)
        #expect(result.completionUnread)
        let resumed = try await observe(store, "a", .working, at: start.addingTimeInterval(30))
        #expect(resumed.status == .working)
        #expect(resumed.completionUnread)
        let prompted = try await observe(store, "a", .prompt, at: start.addingTimeInterval(60))
        #expect(prompted.status == .working)
        #expect(!prompted.completionUnread)
    }

    @Test("A prompt re-tasks a completed agent, even over a user override")
    func promptReopensCompletedAgent() async throws {
        let (store, root) = try await makeStore(TaskSubtask(id: "c", title: "C", sessionID: UUID().uuidString, status: .working))
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await store.overrideCompletion(ticketID: "ECC-900", subtaskID: "c")
        let completedAt = Date()
        let ownOutput = try await observe(store, "c", .working, at: completedAt.addingTimeInterval(5))
        #expect(ownOutput.status == .completed)
        let stalePrompt = try await observe(store, "c", .prompt, at: completedAt.addingTimeInterval(-60))
        #expect(stalePrompt.status == .completed)
        let reopened = try await observe(store, "c", .prompt, at: completedAt.addingTimeInterval(60))
        #expect(reopened.status == .working)
        #expect(reopened.completionOverrideAt == nil)
        #expect(!reopened.completionUnread)
    }

    @Test("A prompt revives an auto-archived agent whose terminal was kept, not a manually archived one")
    func promptRevivesRetainedTerminalOnly() async throws {
        let (store, root) = try await makeStore(TaskSubtask(id: "r", title: "R", sessionID: UUID().uuidString, status: .working))
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await store.upsertSubtask(ticketID: "ECC-900", subtask: TaskSubtask(id: "m", title: "M", sessionID: UUID().uuidString, status: .working))
        for id in ["r", "m"] {
            _ = try await store.updateProgress(ticketID: "ECC-900", subtaskID: id, status: .completed, summary: "done")
        }
        _ = try await store.archiveAgent(ticketID: "ECC-900", subtaskID: "r", automatically: true)
        _ = try await store.archiveAgent(ticketID: "ECC-900", subtaskID: "m")
        let later = Date().addingTimeInterval(60)
        let revived = try await observe(store, "r", .prompt, at: later)
        #expect(revived.status == .working)
        #expect(revived.agentRemovedAt == nil)
        #expect(revived.isAgentVisible)
        let manual = try await observe(store, "m", .prompt, at: later)
        #expect(manual.status == .completed)
        #expect(manual.agentRemovedAt != nil)
    }

    @Test("Resuming waits for input, a prompted launch works, and a re-found pane keeps its status")
    func runtimeStartStatus() async throws {
        let (store, root) = try await makeStore(TaskSubtask(id: "i", title: "I", sessionID: UUID().uuidString, status: .idle))
        defer { try? FileManager.default.removeItem(at: root) }
        let resumed = try await store.setManagedRuntime(ticketID: "ECC-900", subtaskID: "i", tmux: reference(), status: .idle)
        #expect(resumed.subtasks.first?.status == .idle)
        _ = try await store.updateProgress(ticketID: "ECC-900", subtaskID: "i", status: .working, summary: "busy")
        let refound = try await store.setManagedRuntime(ticketID: "ECC-900", subtaskID: "i", tmux: reference())
        #expect(refound.subtasks.first?.status == .working)
        #expect(refound.subtasks.first?.progressSummary == "busy")
        let launched = try await store.setDirectRuntime(ticketID: "ECC-900", subtaskID: "i", paneID: 4, socketPath: nil, status: .working)
        #expect(launched.subtasks.first?.status == .working)
    }

    @Test("A live pane keeps Working through a silent tool call for up to an hour")
    func liveRuntimeLifetime() {
        let now = Date()
        var agent = TaskSubtask(id: "w", title: "W", status: .working)
        agent.lastHeartbeatAt = now.addingTimeInterval(-600)
        #expect(agent.effectiveStatus(now: now) == .idle)
        #expect(agent.effectiveStatus(now: now, heartbeatLifetime: TaskSubtask.liveRuntimeHeartbeatLifetime) == .working)
        agent.lastHeartbeatAt = now.addingTimeInterval(-3_700)
        #expect(agent.effectiveStatus(now: now, heartbeatLifetime: TaskSubtask.liveRuntimeHeartbeatLifetime) == .idle)
    }

    @Test("Claude assistant records and Codex reasoning are heartbeats; a thinking-only turn end is not")
    func midTurnRecordsAreHeartbeats() {
        let session = UUID().uuidString
        let claude = [
            #"{"timestamp":"2026-10-19T17:06:00Z","type":"assistant","sessionId":"\#(session)","uuid":"t","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"text","text":"Running the build"},{"type":"tool_use","name":"Bash","id":"x","input":{}}]}}"#,
            #"{"timestamp":"2026-10-19T17:07:00Z","type":"assistant","sessionId":"\#(session)","uuid":"e","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"thinking","thinking":"done"}]}}"#,
        ].joined(separator: "\n")
        let claudeEvents = AgentActivityEvent.events(in: Data(claude.utf8), provider: .claude, sessionID: session)
        #expect(claudeEvents.map(\.kind) == [.working])
        #expect(claudeEvents.first?.summary == "")
        let codex = [
            #"{"timestamp":"2026-10-19T17:06:00Z","type":"response_item","payload":{"type":"reasoning"}}"#,
            #"{"timestamp":"2026-10-19T17:06:01Z","type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch"}}"#,
            #"{"timestamp":"2026-10-19T17:06:02Z","type":"response_item","payload":{"type":"message","role":"assistant","phase":"commentary","content":[]}}"#,
            #"{"timestamp":"2026-10-19T17:06:03Z","type":"event_msg","payload":{"type":"token_count"}}"#,
        ].joined(separator: "\n")
        let codexEvents = AgentActivityEvent.events(in: Data(codex.utf8), provider: .codex, sessionID: session)
        #expect(codexEvents.map(\.kind) == [.working, .working, .working])
    }

    @Test("Kimi's main wire transcript is located and parsed into prompts, work, and results")
    func kimiTranscript() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = UUID().uuidString.lowercased()
        let directory = root.appendingPathComponent("sessions/wd_x/session_\(session)/agents")
        for agent in ["main", "agent-0"] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(agent), withIntermediateDirectories: true)
        }
        let lines = [
            #"{"type":"metadata","protocol_version":"1.5","created_at":1792780953051}"#,
            #"{"type":"turn.prompt","agentId":"main","origin":{"kind":"user"},"input":[{"type":"text","text":"Fix it"}],"time":1792780953000}"#,
            #"{"type":"context.append_loop_event","agentId":"main","event":{"type":"tool.call","uuid":"c1"},"time":1792780954000}"#,
            #"{"type":"agent.message.appended","message":{"message":{"role":"assistant","content":[{"type":"text","text":"Fixed."}]}},"time":1792780955000}"#,
            #"{"type":"turn.ended","agentId":"main","turnId":0,"reason":"completed","time":1792780956000}"#,
            #"{"type":"turn.prompt","agentId":"main","origin":{"kind":"system"},"input":[],"time":1792780957000}"#,
            #"{"type":"turn.ended","agentId":"main","turnId":1,"reason":"cancelled","time":1792780958000}"#,
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: directory.appendingPathComponent("main/wire.jsonl"))
        try Data(#"{"type":"turn.ended","reason":"completed","time":1792780999000}"#.utf8 + [10])
            .write(to: directory.appendingPathComponent("agent-0/wire.jsonl"))

        let all = AgentActivityEvent.events(in: Data(lines.joined(separator: "\n").utf8), provider: .kimi, sessionID: session)
        #expect(all.map(\.kind) == [.prompt, .working, .working, .result, .working, .attention(.interrupted)])
        #expect(all[3].summary == "Fixed.")
        #expect(all[0].date == Date(timeIntervalSince1970: 1_792_780_953))

        let observer = AgentActivityObserver(codexRoot: root.appendingPathComponent("codex"),
            claudeRoot: root.appendingPathComponent("claude"), kimiRoot: root)
        for id in [session, "session_" + session] {
            let events = try await observer.events(for: TaskSubtask(id: id, title: "K", provider: .kimi, sessionID: id))
            #expect(events.last?.kind == .attention(.interrupted), "lookup by \(id)")
            #expect(events.contains { $0.kind == .result })
        }
    }
}
