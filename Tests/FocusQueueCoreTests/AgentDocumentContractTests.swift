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

    @Test("Task data is created at initialization, linked from the plan, and preserved once authored")
    func taskData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("task-data-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskContextStore(root: root)
        let ticket = DashboardTicket(id: "DOC-2", title: "Cached facts", status: "open", summary: "Remember facts",
                                     links: [DashboardLink(label: "Spec", url: "https://example.com/spec")])
        let context = try await store.ensureContext(ticket: ticket)
        #expect(context.dataURL.lastPathComponent == "data.md")
        #expect(try Data(contentsOf: context.dataURL).isEmpty)
        #expect(try await store.readPlan(ticketID: ticket.id).contains("[Task data](data.md)"))
        let prompt = context.agentPrompt(subtask: .init(id: "agent", title: "Facts"))
        let bootstrap = context.agentBootstrap(subtask: .init(id: "agent", title: "Facts"))
        #expect(prompt.contains(context.dataURL.path))
        #expect(bootstrap.contains(context.dataURL.path))
        for launchText in [prompt, bootstrap] {
            #expect(launchText.contains("one or two short sentences"))
            #expect(launchText.contains("test results, and evidence in the agent log"))
        }

        try Data("# Facts\nPort 8080.\n".utf8).write(to: context.dataURL)
        _ = try await store.ensureContext(ticket: ticket)
        #expect(try String(contentsOf: context.dataURL, encoding: .utf8) == "# Facts\nPort 8080.\n")
        try FileManager.default.removeItem(at: context.dataURL)
        _ = try await store.ensureContext(ticket: ticket)
        #expect(FileManager.default.fileExists(atPath: context.dataURL.path))

        try Data("# DOC-2 task data\n\nCached facts, inputs, and test data for this task. Agents read this before acting and add durable task facts here.\n".utf8)
            .write(to: context.dataURL)
        _ = try await store.ensureContext(ticket: ticket)
        #expect(try Data(contentsOf: context.dataURL).isEmpty)

        let links = context.evidenceLinks(ticket.links + [DashboardLink(label: "Data", url: context.dataURL.path)])
        #expect(links.map(\.url) == [context.dataURL.path, "https://example.com/spec"])
        #expect(context.evidenceLinks([]).map(\.label) == ["Task data (data.md)"])
    }

    @Test("Scoped saved facts appear in detailed and compact launch prompts")
    func scopedData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scoped-data-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = ProjectDefinition(id: "demo", name: "Demo", taskPrefix: "DOC", repositoryPath: root.path)
        let ticket = DashboardTicket(id: "DOC-3", title: "Page", projectID: project.id,
                                     status: "open", summary: "Build a page")
        let context = try await TaskContextStore(root: root).ensureContext(ticket: ticket, project: project)
        let projectData = try #require(context.projectDataURL)
        try FileManager.default.createDirectory(at: projectData.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("- Use the gray theme.\n".utf8).write(to: projectData)
        try FileManager.default.createDirectory(at: context.userDataURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("- Keep answers concise.\n".utf8).write(to: context.userDataURL)
        try Data("- Keep the demo under ten seconds.\n".utf8).write(to: context.dataURL)
        let prompt = context.agentPrompt(subtask: .init(id: "agent", title: "Facts"))
        #expect(prompt.contains("Use the gray theme."))
        #expect(prompt.contains("Keep answers concise."))
        #expect(prompt.contains("Keep the demo under ten seconds."))
        let bootstrap = context.agentBootstrap(subtask: .init(id: "agent", title: "Facts"))
        #expect(bootstrap.contains(projectData.path))
        #expect(bootstrap.contains(context.userDataURL.path))
        #expect(bootstrap.contains("Use the gray theme."))
        #expect(bootstrap.contains("Keep answers concise."))
        #expect(bootstrap.contains("Keep the demo under ten seconds."))
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
