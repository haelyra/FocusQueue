import Foundation
import Testing
@testable import FocusQueueCore

@Suite("Agent placement")
struct AgentPlacementTests {
    @Test func resolvesRepositoryCreatesPrefixedTasksAndFallsBackToOther() async throws {
        let fixture = try await PlacementFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let resolver = AgentPlacementResolver(root: fixture.support)

        let agentID = UUID().uuidString.lowercased()
        let placed = try await resolver.resolve(.init(
            launchID: UUID().uuidString, cwd: fixture.focus.path,
            prompt: "Implement automatic project placement", assignmentID: agentID),
            configuration: fixture.configuration)
        #expect(placed.status == .placed)
        #expect(placed.projectID == "focus")
        #expect(placed.taskID == "FOC-001")
        #expect(FileManager.default.fileExists(atPath: placed.projectPlanPath))
        #expect(placed.taskPlanPath.map(FileManager.default.fileExists(atPath:)) == true)
        let context = try #require(try await TaskContextStore(root: fixture.support).load(ticketID: "FOC-001"))
        #expect(context.subtasks.first?.id == agentID)
        #expect(context.subtasks.first?.title == "Implement automatic project placement")
        #expect(try AgentPlacementCapsuleStore(root: fixture.support).load(launchID: placed.launchID) == placed)
        #expect((try FileManager.default.attributesOfItem(atPath: placed.capsulePath)[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        let miscellaneous = fixture.root.appendingPathComponent("miscellaneous")
        try FileManager.default.createDirectory(at: miscellaneous, withIntermediateDirectories: true)
        let other = try await resolver.resolve(.init(
            launchID: UUID().uuidString, cwd: miscellaneous.path,
            prompt: "Summarize a standalone note"), configuration: fixture.configuration)
        #expect(other.status == .placed)
        #expect(other.projectID == ProjectCatalog.otherID)
        #expect(other.taskID == "OTH-001")

        let focusProject = try #require(fixture.configuration.projects.first { $0.id == "focus" })
        let otherProject = try #require(fixture.configuration.projects.first { $0.id == ProjectCatalog.otherID })
        let focusDashboard = try JSONDecoder().decode(DashboardDocument.self,
            from: Data(contentsOf: URL(fileURLWithPath: focusProject.dashboardPath)))
        let otherDashboard = try JSONDecoder().decode(DashboardDocument.self,
            from: Data(contentsOf: URL(fileURLWithPath: otherProject.dashboardPath)))
        #expect(focusDashboard.tickets.map(\.id) == ["FOC-001"])
        #expect(otherDashboard.tickets.map(\.id) == ["OTH-001"])
        #expect(focusDashboard.tickets.map(\.projectID) == ["focus"])
        #expect(otherDashboard.tickets.map(\.projectID) == [ProjectCatalog.otherID])
    }

    @Test func missingObjectiveWaitsInProjectInboxAndConflictingPathBlocksWriting() async throws {
        let fixture = try await PlacementFixture(includeSecondRepository: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let resolver = AgentPlacementResolver(root: fixture.support)

        let inbox = try await resolver.resolve(.init(
            launchID: UUID().uuidString, cwd: fixture.focus.path,
            createTaskIfNeeded: true), configuration: fixture.configuration)
        #expect(inbox.status == .projectInbox)
        #expect(inbox.projectID == "focus")
        #expect(inbox.taskID == nil)

        let focus = try #require(fixture.configuration.projects.first { $0.id == "focus" })
        let taskID = try ProjectTaskStore(
            dashboardURL: URL(fileURLWithPath: fixture.configuration.dashboardPath),
            supportDirectory: fixture.support).create(title: "Existing focus task", summary: "Fixture", project: focus)
        let second = try #require(fixture.second)
        let conflict = try await resolver.resolve(.init(
            launchID: UUID().uuidString, cwd: second.path, prompt: "Continue the task",
            explicitTaskID: taskID), configuration: fixture.configuration)
        #expect(conflict.status == .blockedConflict)
        #expect(conflict.projectID == "focus")
        #expect(conflict.taskID == taskID)
        #expect(conflict.reason?.contains("different projects") == true)

        let unrelated = fixture.root.appendingPathComponent("unrelated")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let unknownPath = try await resolver.resolve(.init(
            launchID: UUID().uuidString, cwd: unrelated.path,
            explicitTaskID: taskID), configuration: fixture.configuration)
        #expect(unknownPath.status == .blockedConflict)
        #expect(unknownPath.taskID == taskID)
    }
}

private struct PlacementFixture {
    let root: URL
    let support: URL
    let focus: URL
    let second: URL?
    let configuration: AppConfiguration

    init(includeSecondRepository: Bool = false) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("placement-\(UUID())")
        support = root.appendingPathComponent("support")
        focus = root.appendingPathComponent("focus")
        second = includeSecondRepository ? root.appendingPathComponent("second") : nil
        try SetupEnvironment.createStarterWorkspace(supportDirectory: support)
        try await Self.initializeRepository(focus)
        if let second { try await Self.initializeRepository(second) }
        var config = SetupEnvironment.starter(supportDirectory: support)
        let secondDashboard = support.appendingPathComponent("second/dashboard.json")
        if second != nil {
            try FileManager.default.createDirectory(
                at: secondDashboard.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{\"tickets\":[]}\n".utf8).write(to: secondDashboard)
        }
        config.projects = ProjectCatalog.ensuringOther(in: [
            ProjectDefinition(id: "focus", name: "Focus Queue",
                dashboardPath: config.dashboardPath, workspacePath: focus.path,
                taskPrefix: "FOC", repositoryPath: focus.path),
            second.map { ProjectDefinition(id: "second", name: "Second",
                dashboardPath: secondDashboard.path, workspacePath: $0.path,
                taskPrefix: "SEC", repositoryPath: $0.path) },
        ].compactMap { $0 }, supportDirectory: support)
        config.selectedProjectID = "focus"
        if let other = config.projects.first(where: { $0.id == ProjectCatalog.otherID }) {
            try ProjectCatalog.prepareFallbackStorage(for: other)
        }
        config.setupCompleted = true
        configuration = try config.validated()
    }

    private static func initializeRepository(_ url: URL) async throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let runner = FoundationProcessRunner()
        for arguments in [
            ["init", "-q", "-b", "main"],
            ["-c", "user.name=Test", "-c", "user.email=test@example.invalid",
             "-c", "core.hooksPath=/dev/null", "commit", "-qm", "Fixture", "--allow-empty"],
        ] {
            let result = try await runner.run(.init(executable: "/usr/bin/git", arguments: arguments,
                workingDirectory: url.path))
            guard result.succeeded else {
                throw TaskContextError.commandFailed(result.standardError)
            }
        }
    }
}
