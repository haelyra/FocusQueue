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

@Test("An unlinked task gets one phase line in both briefs, and no module or step detail")
func enabledProcessInjectsOneLine() async throws {
    let (root, project) = try briefFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DevelopmentProcessStore(root: root)
    _ = try store.setStepStatus(.inProgress, stepID: "modules", projectID: project.id,
        note: "Auth and sync are drafted")
    _ = try store.addModule(name: "Auth", file: "modules/auth.md", projectID: project.id)
    _ = try store.addModule(name: "Sync", file: "modules/sync.md", projectID: project.id)

    let context = try await TaskContextStore(root: root).ensureContext(ticket: briefTicket, project: project)
    let lines = context.developmentProcessLines()
    #expect(lines == ["Development process (Planning): "
        + DevelopmentProcessCatalog.brief(for: .planning)])

    let agent = TaskSubtask(title: "Build login")
    #expect(context.agentPrompt(subtask: agent).contains("Development process (Planning): "))
    #expect(context.agentBootstrap(subtask: agent).contains("Development process (Planning): "))
    #expect(!context.agentPrompt(subtask: agent).contains("Auth, Sync"))
}

@Test("A linked task names its own step and module in one line")
func linkedTaskNamesItsStep() async throws {
    let (root, project) = try briefFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DevelopmentProcessStore(root: root)
    _ = try store.addModule(name: "Auth", file: nil, projectID: project.id)
    _ = try store.link(taskID: "dem-001", step: "modules", module: "auth", projectID: project.id)

    let context = try await TaskContextStore(root: root).ensureContext(ticket: briefTicket, project: project)
    #expect(context.developmentProcessLines() == ["Development process (Planning, step Module design files (experimental, optional), "
        + "module Auth): " + DevelopmentProcessCatalog.brief(for: .planning)])
    // A task linked to a later phase's step follows that phase's rule.
    _ = try store.link(taskID: "DEM-001", step: "scaffolding", projectID: project.id)
    #expect(context.developmentProcessLines() == ["Development process (Phase 0, step Scaffolding & environment): "
        + DevelopmentProcessCatalog.brief(for: .phase0)])
}

@Test("A task marked outside the process gets no process line")
func outsideTaskGetsNothing() async throws {
    let (root, project) = try briefFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try DevelopmentProcessStore(root: root).link(taskID: "DEM-001", step: nil, projectID: project.id)
    let context = try await TaskContextStore(root: root).ensureContext(ticket: briefTicket, project: project)
    #expect(context.developmentProcessState() != nil)
    #expect(context.developmentProcessLines().isEmpty)
    #expect(!context.agentPrompt(subtask: TaskSubtask(title: "Build login")).contains("Development process"))
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

