import Foundation
import Testing
@testable import FocusQueueCore

private func briefFixture() throws -> (root: URL, project: ProjectDefinition) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("dev-brief-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let project = ProjectDefinition(id: "demo", name: "Demo", taskPrefix: "DEM",
        repositoryPath: "/tmp/demo-repo")
    _ = try ProjectContextStore(root: root).ensurePlan(for: project)
    return (root, project)
}

private let briefTicket = DashboardTicket(
    id: "DEM-001", title: "Build login", status: "open",
    summary: "Implement the login module.", doneWhen: "Login succeeds against staging auth.")

@Test("Projects without development.json get no process lines")
func noProcessNoLines() async throws {
    let (root, project) = try briefFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let context = try await TaskContextStore(root: root).ensureContext(ticket: briefTicket, project: project)
    #expect(context.developmentProcessState() == nil)
    #expect(context.developmentProcessLines().isEmpty)
    let prompt = context.agentPrompt(subtask: TaskSubtask(title: "Build login"))
    #expect(!prompt.contains("Development process"))
}

@Test("Enabled projects inject phase, step, and pending module criteria into both briefs")
func enabledProcessInjects() async throws {
    let (root, project) = try briefFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DevelopmentProcessStore(root: root)
    var process = try store.setStepStatus(.inProgress, stepID: "modules", projectID: project.id,
        note: "Auth and sync are drafted")
    process = try store.addModule(name: "Auth", file: "modules/auth.md", projectID: project.id)
    process = try store.addModule(name: "Sync", file: "modules/sync.md", projectID: project.id)
    try store.save(process, projectID: project.id)

    let context = try await TaskContextStore(root: root).ensureContext(ticket: briefTicket, project: project)
    let lines = context.developmentProcessLines()
    #expect(lines.count == 3)
    #expect(lines[0].contains("development.json") && lines[0].contains("Planning phase"))
    #expect(lines[0].contains("planning artifacts"))
    #expect(lines[1].contains("Current step: Module design files"))
    #expect(lines[1].contains("Auth and sync are drafted"))
    #expect(lines[2].contains("Auth, Sync"))

    let agent = TaskSubtask(title: "Build login")
    let prompt = context.agentPrompt(subtask: agent)
    #expect(prompt.contains("Development process (development.json): Planning phase"))
    let bootstrap = context.agentBootstrap(subtask: agent)
    #expect(bootstrap.contains("Development process (development.json): Planning phase"))
}

@Test("A disabled process file stays out of briefs")
func disabledProcessSilent() async throws {
    let (root, project) = try briefFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try DevelopmentProcessStore(root: root).setEnabled(false, projectID: project.id)
    let context = try await TaskContextStore(root: root).ensureContext(ticket: briefTicket, project: project)
    #expect(context.developmentProcessState() == nil)
    #expect(!context.agentPrompt(subtask: TaskSubtask(title: "Build login")).contains("Development process"))
}

@Test("After criteria acceptance the module reminder disappears")
func acceptedModulesNotReminded() async throws {
    let (root, project) = try briefFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DevelopmentProcessStore(root: root)
    let process = try store.addModule(name: "Auth", file: nil, projectID: project.id)
    let auth = try #require(process.modules.first)
    _ = try store.acceptCriteria(moduleID: auth.id, projectID: project.id)

    let context = try await TaskContextStore(root: root).ensureContext(ticket: briefTicket, project: project)
    let lines = context.developmentProcessLines()
    #expect(lines.contains { $0.contains("Development process") })
    #expect(!lines.contains { $0.contains("awaiting sequential human acceptance") })
}
