import Foundation
import Testing
@testable import FocusQueueCore

@Suite("Agent document contract")
struct AgentDocumentContractTests {
    @Test("Missing documents are repaired and authored plan/log text is preserved")
    func repairAndPreservation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-docs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskContextStore(root: root)
        let ticket = DashboardTicket(id: "DOC-1", title: "Shared guideline", status: "open", summary: "Keep context small")
        let context = try await store.ensureContext(ticket: ticket)
        let plan = try await store.readPlan(ticketID: ticket.id)
        #expect(!plan.contains("## Decisions"))
        #expect(plan.contains("[Agent log](agent-log.md)"))
        #expect(FileManager.default.fileExists(atPath: context.agentLogURL.path))
        try await store.savePlan(ticketID: ticket.id, markdown: "# Authored plan\n", expectedMarkdown: plan)
        try Data("# Existing log\nKeep my decision.\n".utf8).write(to: context.agentLogURL)
        _ = try await store.ensureContext(ticket: ticket)
        #expect(try await store.readPlan(ticketID: ticket.id) == "# Authored plan\n")
        #expect(try String(contentsOf: context.agentLogURL, encoding: .utf8) == "# Existing log\nKeep my decision.\n")
        try FileManager.default.removeItem(atPath: context.planPath)
        _ = try await store.ensureContext(ticket: ticket)
        #expect(try await store.readPlan(ticketID: ticket.id) == plan)
        #expect(try String(contentsOf: context.agentLogURL, encoding: .utf8).contains("Keep my decision."))
    }

    @Test("Independent stores append without lost entries or changes to plan and task state")
    func concurrentLogs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskContextStore(root: root)
        let context = try await store.ensureContext(ticket: DashboardTicket(id: "DOC-1", title: "Append", status: "open", summary: ""))
        _ = try await store.upsertSubtask(ticketID: "DOC-1", subtask: .init(id: "agent", title: "Evidence"))
        let beforePlan = try Data(contentsOf: URL(fileURLWithPath: context.planPath))
        let beforeContext = try Data(contentsOf: context.contextDirectory.appendingPathComponent("context.json"))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for number in 0..<24 {
                group.addTask {
                    try await TaskContextStore(root: root).appendAgentLog(ticketID: "DOC-1", subtaskID: "agent", entry: "Evidence entry \(number).")
                }
            }
            try await group.waitForAll()
        }
        let log = try String(contentsOf: context.agentLogURL, encoding: .utf8)
        for number in 0..<24 { #expect(log.components(separatedBy: "Evidence entry \(number).").count == 2) }
        #expect(try Data(contentsOf: URL(fileURLWithPath: context.planPath)) == beforePlan)
        #expect(try Data(contentsOf: context.contextDirectory.appendingPathComponent("context.json")) == beforeContext)
        await #expect(throws: TaskContextError.self) {
            try await store.appendAgentLog(ticketID: "DOC-1", subtaskID: "missing", entry: "Reject me")
        }
        await #expect(throws: TaskContextError.self) {
            try await store.appendAgentLog(ticketID: "DOC-1", subtaskID: "agent", entry: " \n ")
        }
        #expect(try String(contentsOf: context.agentLogURL, encoding: .utf8) == log)
    }

    @Test("Log appends reject symlink destinations")
    func symlinkLog() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-log-link-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskContextStore(root: root)
        let context = try await store.ensureContext(ticket: DashboardTicket(id: "DOC-1", title: "Safe log", status: "open", summary: ""))
        _ = try await store.upsertSubtask(ticketID: "DOC-1", subtask: .init(id: "agent", title: "Log"))
        let other = root.appendingPathComponent("user-notes.md")
        try Data("Keep me".utf8).write(to: other)
        try FileManager.default.removeItem(at: context.agentLogURL)
        try FileManager.default.createSymbolicLink(at: context.agentLogURL, withDestinationURL: other)
        await #expect(throws: TaskContextError.self) {
            try await store.appendAgentLog(ticketID: "DOC-1", subtaskID: "agent", entry: "Do not redirect")
        }
        #expect(try String(contentsOf: other, encoding: .utf8) == "Keep me")
    }
}
