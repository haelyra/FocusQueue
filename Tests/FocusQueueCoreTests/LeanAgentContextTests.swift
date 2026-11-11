import Foundation
import Testing
@testable import FocusQueueCore

private func leanFixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("lean-context-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private let leanTicket = DashboardTicket(
    id: "ECC-950", title: "Fix chat markdown", status: "open",
    summary: "Render chat markdown and allow\nmulti-line selection.",
    doneWhen: "Markdown renders and several lines can be copied.",
    links: [.init(label: "Design notes", url: "https://example.com/notes")],
    steps: [.init(id: "render", label: "Render markdown", status: "done"),
            .init(id: "select", label: "Allow selection", status: "pending")])

@Test("New task plans are bare: What/Why/How, success criteria, progress, and context links")
func leanTaskPlanTemplate() async throws {
    let root = try leanFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let context = try await TaskContextStore(root: root).ensureContext(ticket: leanTicket)
    let plan = try String(contentsOfFile: context.planPath, encoding: .utf8)
    #expect(plan.hasPrefix("# ECC-950: Fix chat markdown\n"))
    #expect(plan.contains("- **What:** Render chat markdown and allow multi-line selection."))
    #expect(plan.contains("## Success criteria\n\n- Markdown renders and several lines can be copied."))
    #expect(plan.contains("## Progress\n\n- [x] Render markdown\n- [ ] Allow selection"))
    #expect(plan.contains("[Design notes](https://example.com/notes)"))
    for retired in ["BLUF", "Decision log", "Big-picture", "QA instructions", "Next steps", "advances the recorded project goal"] {
        #expect(!plan.contains(retired), "Retired template text: \(retired)")
    }
    #expect(plan.utf8.count < 500)
}

@Test("A task without real success criteria does not repeat the generic placeholder")
func leanGenericSuccessCriteria() async throws {
    let root = try leanFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let ticket = DashboardTicket(id: "ECC-951", title: "Untitled work", status: "open", summary: "Short summary.")
    let context = try await TaskContextStore(root: root).ensureContext(ticket: ticket)
    #expect(context.specificSuccessCriteria == nil)
    let plan = try String(contentsOfFile: context.planPath, encoding: .utf8)
    #expect(!plan.contains(TaskContext.genericSuccessCriteria))
    let prompt = context.agentPrompt(subtask: TaskSubtask(title: "Untitled work"))
    #expect(!prompt.contains("Success criteria:"))
}

@Test("The detailed brief inlines the project and task plans and keeps procedure short")
func leanDetailedBrief() async throws {
    let root = try leanFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let project = ProjectDefinition(id: "chat", name: "Chat App", taskPrefix: "CHA", repositoryPath: "/tmp/chat-repo")
    let context = try await TaskContextStore(root: root).ensureContext(ticket: leanTicket, project: project)
    var agent = TaskSubtask(id: "AGENT-1", title: "Fix chat markdown", provider: .claude)
    agent.initialPrompt = "Please make the chat render markdown."
    agent.assignmentDescription = agent.initialPrompt!
    agent.workspace = AgentWorkspace(path: "/tmp/chat-repo/.worktrees/a", repositoryPath: "/tmp/chat-repo", branch: "feature/a")
    let prompt = context.agentPrompt(subtask: agent)

    #expect(prompt.hasPrefix(agent.initialPrompt! + "\n\n[Focus Queue] ECC-950: Fix chat markdown · Project: Chat App\n"))
    #expect(prompt.components(separatedBy: agent.initialPrompt!).count == 2, "The request appears once")
    #expect(prompt.contains("Agent AGENT-1 (claude) · Workspace: /tmp/chat-repo/.worktrees/a · Branch: feature/a"))
    #expect(prompt.contains("Success criteria: Markdown renders and several lines can be copied."))
    #expect(prompt.contains("About the project: Tasks use `CHA-###` IDs. Repository: /tmp/chat-repo."))
    #expect(prompt.contains("Task plan (\(context.planPath)):\n- **What:**"))
    #expect(prompt.contains("- [ ] Allow selection"))
    #expect(!prompt.contains("# ECC-950"), "Plan titles are not repeated")
    #expect(!prompt.contains("- **Why:**"), "Empty plan fields are omitted")
    #expect(!prompt.contains("Subtask:"), "A subtask titled like its task is not repeated")
    for retired in ["Assignment details", "context.json", "FOCUS_QUEUE_SUPPORT_DIR", "review-push", "focus-queue-map", "Briefly state"] {
        #expect(!prompt.contains(retired), "Retired launch text: \(retired)")
    }
    // Procedure, excluding the request, inlined documents, and paths, stays within a fixed
    // budget. It grew past 1,000 bytes for the one rule that routes user-facing files to the
    // context folder, which every provider needs and no global contract carries for Kimi.
    let plan = TaskContext.inlineDocument(atPath: context.planPath, limit: 4_000)!
    let projectBody = TaskContext.inlineDocument(atPath: context.projectPlanPath, limit: 1_500)!
    let procedure = prompt.replacingOccurrences(of: agent.initialPrompt!, with: "")
        .replacingOccurrences(of: plan, with: "").replacingOccurrences(of: projectBody, with: "")
        .replacingOccurrences(of: context.planPath, with: "").replacingOccurrences(of: context.dataURL.path, with: "")
        .replacingOccurrences(of: context.contextDirectory.path, with: "")
        .replacingOccurrences(of: context.userDataURL.path, with: "")
        .replacingOccurrences(of: context.projectDataURL!.path, with: "")
    #expect(procedure.utf8.count < 1_150, "Procedure is \(procedure.utf8.count) bytes")
}

@Test("A plan What line that restates the request points back to it")
func leanWhatRestatingPrompt() async throws {
    let root = try leanFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let request = "The chat does not render markdown and I cannot select several lines. Please fix both and install."
    let ticket = DashboardTicket(id: "ECC-952", title: "Chat fixes", status: "open", summary: request)
    let context = try await TaskContextStore(root: root).ensureContext(ticket: ticket)
    var agent = TaskSubtask(title: "Chat fixes")
    agent.initialPrompt = request
    let prompt = context.agentPrompt(subtask: agent)
    #expect(prompt.components(separatedBy: request).count == 2)
    #expect(prompt.contains("- **What:** see the request above."))
}

@Test("Distinct assignment text and subtask titles are still shown")
func leanDistinctAssignment() {
    let context = TaskContext(ticketID: "ECC-1", title: "Parent task", summary: "", successCriteria: "",
        planPath: "/nonexistent/tasks/ECC-1/plan.md", worktreePath: "/tmp/w", updatedAt: Date())
    var agent = TaskSubtask(title: "Review the parser", assignmentDescription: "Only review; do not edit.")
    agent.initialPrompt = "Look at the parser."
    let prompt = context.agentPrompt(subtask: agent)
    #expect(prompt.contains("Subtask: Review the parser"))
    #expect(prompt.contains("Assignment details: Only review; do not edit."))
    #expect(prompt.contains("Task plan: /nonexistent/tasks/ECC-1/plan.md"))
    #expect(TaskContext.restates(String("Look at the parser.".prefix(10)), "Look at the parser."))
}

@Test("Agent rules carry the procedure removed from launch prompts")
func leanAgentRules() {
    let rules = TaskContext.agentRules(mapHelper: "/Apps/focus-queue-map")
    for required in ["attach", "progress queued|working|idle|blocked", "attention approval|question", "result \"summary\"",
                     "complete \"", "log \"entry\"", "Progress checklist", "immutable", "Push only when the user authorizes",
                     "'/Apps/focus-queue-map' scope <TASK-ID> <AGENT-ID>",
                     "/usr/bin/python3` is 3.9", "Never send a parser's stderr to /dev/null"] {
        #expect(rules.contains(required), "Missing rule: \(required)")
    }
    #expect(!TaskContext.agentRules(mapHelper: nil).contains("Map scope"))
}

@Test("New project plans are a one-line description")
func leanProjectPlan() throws {
    let root = try leanFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectContextStore(root: root).ensurePlan(
        for: ProjectDefinition(id: "chat", name: "Chat App", taskPrefix: "CHA", repositoryPath: "/tmp/chat-repo"))
    let plan = try String(contentsOf: url, encoding: .utf8)
    #expect(plan == "# Chat App\n\nTasks use `CHA-###` IDs. Repository: /tmp/chat-repo.\n")
}

@Test("Task data is pointed to while empty and inlined once an agent records facts")
func leanTaskDataInlining() async throws {
    let root = try leanFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let context = try await TaskContextStore(root: root).ensureContext(ticket: leanTicket)
    let agent = TaskSubtask(title: "Fix chat markdown")
    #expect(context.agentPrompt(subtask: agent).contains("Task data: \(context.dataURL.path)."))
    #expect(context.agentPrompt(subtask: agent).contains("one or two short sentences"))
    #expect(!context.agentPrompt(subtask: agent).contains(TaskContext.dataTemplateBody))
    try Data("# ECC-950 task data\n\n- Chat view lives in ChatMarkdownView.swift.\n".utf8).write(to: context.dataURL)
    let prompt = context.agentPrompt(subtask: agent)
    #expect(prompt.contains("Task data (\(context.dataURL.path)):\n- Chat view lives in ChatMarkdownView.swift."))
}
