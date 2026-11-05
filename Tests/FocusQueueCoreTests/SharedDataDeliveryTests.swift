import Foundation
import Testing
@testable import FocusQueueCore

@Suite("Shared data reaches every agent in a project")
struct SharedDataDeliveryTests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func project(_ root: URL) -> ProjectDefinition {
        ProjectDefinition(id: "acme", name: "Acme", dashboardPath: root.appendingPathComponent("d.json").path,
                          workspacePath: root.path)
    }

    private func prompt(_ text: String = "Fix it", session: String = "s-1") -> [String: Any] {
        ["hook_event_name": "UserPromptSubmit", "session_id": session, "prompt": text]
    }

    private func save(_ facts: String, root: URL) throws {
        try Data(facts.utf8).write(to: root.appendingPathComponent("projects/acme/data.md"))
    }

    @Test("Preparing a project plan creates blank project and user data and keeps saved facts")
    func creation() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectContextStore(root: root)
        try store.ensurePlan(for: project(root))
        let data = root.appendingPathComponent("projects/acme/data.md")
        let user = root.appendingPathComponent("user/data.md")
        #expect(try Data(contentsOf: data).isEmpty)
        #expect(try Data(contentsOf: user).isEmpty)
        let mode = try FileManager.default.attributesOfItem(atPath: data.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        try save("- Use gray.\n", root: root)
        try store.ensurePlan(for: project(root))
        #expect(try String(contentsOf: data, encoding: .utf8) == "- Use gray.\n")
    }

    @Test("A redirected data file is refused and its target is left alone")
    func redirected() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside.md")
        let directory = root.appendingPathComponent("projects/acme")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("data.md"),
                                                   withDestinationURL: outside)
        #expect(throws: (any Error).self) { try ProjectContextStore(root: root).ensureData(projectID: "acme") }
        #expect(!FileManager.default.fileExists(atPath: outside.path))
    }

    @Test("Briefs name data files with no facts and inline saved ones")
    func brief() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try ProjectContextStore(root: root).ensurePlan(for: project(root))
        var context = try await TaskContextStore(root: root).ensureContext(
            ticket: DashboardTicket(id: "ACM-001", title: "Task", status: "open", summary: "Do it"))
        context.projectPlanPath = plan.path
        let data = root.appendingPathComponent("projects/acme/data.md").path
        for detailed in [true, false] {
            var agent = TaskSubtask(title: "Agent", assignmentDescription: "Do it", provider: .claude)
            agent.includeInitializationPrompt = detailed
            let brief = { detailed ? context.agentPrompt(subtask: agent) : context.agentBootstrap(subtask: agent) }
            #expect(brief().contains("Project data: \(data)\n"))
            #expect(brief().contains("User data: \(root.appendingPathComponent("user/data.md").path)\n"))
            try save("- Use gray.\n", root: root)
            #expect(brief().contains("Project data (\(data)):\n- Use gray."))
            // The block a hook compares against is what the brief carries.
            let facts = try #require(TaskContext.sharedDataBlock(root: root, projectID: "acme"))
            #expect(brief().contains(facts))
            try save("", root: root)
        }
    }

    @Test("A session gets the facts once, and again only when they change")
    func onceUntilChanged() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try ProjectContextStore(root: root).ensurePlan(for: project(root))
        func deliver(_ payload: [String: Any]) -> String? {
            SharedDataDelivery.context(payload: payload, provider: "claude", projectID: "acme", root: root)
        }
        #expect(deliver(prompt()) == nil)
        try save("- Use gray.\n", root: root)
        #expect(deliver(prompt())?.contains("- Use gray.") == true)
        #expect(deliver(prompt()) == nil)
        #expect(deliver(prompt(session: "s-2"))?.contains("- Use gray.") == true)
        try save("- Use gray.\n- Use serif.\n", root: root)
        #expect(deliver(prompt())?.contains("- Use serif.") == true)
    }

    @Test("A launch brief counts as delivered, and a cleared conversation gets the facts again")
    func briefAndClear() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try ProjectContextStore(root: root).ensurePlan(for: project(root))
        try save("- Use gray.\n", root: root)
        let facts = try #require(TaskContext.sharedDataBlock(root: root, projectID: "acme"))
        func deliver(_ payload: [String: Any]) -> String? {
            SharedDataDelivery.context(payload: payload, provider: "claude", projectID: "acme", root: root)
        }
        #expect(deliver(prompt("Fix it\n\n[Focus Queue] ACM-001: Task\n" + facts + "\nMore")) == nil)
        #expect(deliver(prompt()) == nil)
        let cleared: [String: Any] = ["hook_event_name": "SessionStart", "session_id": "s-1", "source": "clear"]
        #expect(deliver(cleared)?.contains("- Use gray.") == true)
        #expect(deliver(prompt()) == nil)
    }

    @Test("Subagents, unplaced sessions, and other events receive nothing")
    func exclusions() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try ProjectContextStore(root: root).ensurePlan(for: project(root))
        try save("- Use gray.\n", root: root)
        var subagent = prompt()
        subagent["agent_id"] = "worker"
        #expect(SharedDataDelivery.context(payload: subagent, provider: "claude", projectID: "acme", root: root) == nil)
        #expect(SharedDataDelivery.context(payload: prompt(), provider: "claude", projectID: nil, root: root) == nil)
        #expect(SharedDataDelivery.context(payload: ["hook_event_name": "Stop", "session_id": "s-1"],
                                           provider: "claude", projectID: "acme", root: root) == nil)
    }

    @Test("Hook output uses Claude's additional context shape")
    func hookOutput() throws {
        let data = try #require(SharedDataDelivery.claudeHookOutput(event: "UserPromptSubmit", context: "Use gray."))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: [String: String]])
        #expect(object == ["hookSpecificOutput": ["hookEventName": "UserPromptSubmit", "additionalContext": "Use gray."]])
    }

    @Test("Extraction reads the user's words, not the launch brief after them")
    func userText() {
        let brief = "Always use serif.\n\n[Focus Queue] ACM-001: Task · Project: Acme\n" + String(repeating: "x", count: 5_000)
        #expect(PromptExtraction.userText(of: brief) == "Always use serif.")
        #expect(PromptExtraction.userText(of: "Plain prompt") == "Plain prompt")
    }
}
