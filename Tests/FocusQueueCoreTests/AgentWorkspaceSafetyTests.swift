import Foundation
import Testing
@testable import FocusQueueCore

@Suite("Agent workspace launch safety")
struct AgentWorkspaceSafetyTests {
    @Test("Detached checkouts can launch and create worktrees without changing their source")
    func detachedCheckout() async throws {
        let fixture = try await WorkspaceSafetyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.git(["checkout", "--detach", "HEAD"])
        let manager = TaskWorktreeManager()
        let detached = try await manager.workspace(at: fixture.repository.path)
        #expect(detached.branch == nil)
        try await manager.validate(detached)
        let created = try await manager.provisionAgent(ticketID: "ECC-035", subtaskID: UUID().uuidString,
            path: fixture.repository.path, createWorktree: true, store: TaskContextStore(root: fixture.support))
        #expect(created.baseCommit == detached.baseCommit)
        #expect(created.managed)
        #expect(try await manager.workspace(at: fixture.repository.path).branch == nil)
        _ = try await fixture.git(["checkout", "-b", "changed"])
        await #expect(throws: TaskContextError.self) { try await manager.validate(detached) }
    }

    @Test("Saved workspaces reject repository replacement even when the branch and path match")
    func replacedRepository() async throws {
        let fixture = try await WorkspaceSafetyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = TaskWorktreeManager()
        let saved = try await manager.workspace(at: fixture.repository.path)
        let roundTrip = try JSONDecoder().decode(AgentWorkspace.self, from: JSONEncoder().encode(saved))
        #expect(roundTrip == saved)
        try FileManager.default.moveItem(at: fixture.repository, to: fixture.root.appendingPathComponent("original"))
        try FileManager.default.createDirectory(at: fixture.repository, withIntermediateDirectories: true)
        try await fixture.initializeRepository()
        #expect(try await manager.workspace(at: fixture.repository.path).branch == saved.branch)
        await #expect(throws: TaskContextError.self) { try await manager.validate(roundTrip) }
    }

    @Test("A redirected worktree cannot launch in the main checkout")
    func redirectedWorktree() async throws {
        let fixture = try await WorkspaceSafetyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = TaskWorktreeManager()
        let saved = try await manager.provisionAgent(ticketID: "ECC-035", subtaskID: UUID().uuidString,
            path: fixture.repository.path, createWorktree: true, store: TaskContextStore(root: fixture.support))
        try FileManager.default.moveItem(at: URL(fileURLWithPath: saved.path),
            to: fixture.root.appendingPathComponent("retained-worktree"))
        try FileManager.default.createSymbolicLink(atPath: saved.path, withDestinationPath: fixture.repository.path)
        var matchingBranch = saved
        matchingBranch.branch = "main"
        await #expect(throws: TaskContextError.self) { try await manager.validate(matchingBranch) }
        // Existing records without the new identity fields still require a linked worktree.
        matchingBranch.gitDirectory = nil
        matchingBranch.repositoryIdentity = nil
        await #expect(throws: TaskContextError.self) { try await manager.validate(matchingBranch) }
    }

    @Test("Application bundles are rejected even when nested in a source repository")
    func applicationBundle() async throws {
        let fixture = try await WorkspaceSafetyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let app = fixture.repository.appendingPathComponent("Build/Focus Queue.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        await #expect(throws: TaskContextError.self) { try await TaskWorktreeManager().workspace(at: app.path) }
        let alias = fixture.root.appendingPathComponent("app-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: app)
        await #expect(throws: TaskContextError.self) { try await TaskWorktreeManager().workspace(at: alias.path) }
    }

    @Test("Legacy workspace records remain readable and explicit dirty checkout choices stay usable")
    func legacyAndDeliberateWorkspace() async throws {
        let fixture = try await WorkspaceSafetyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let data = try JSONSerialization.data(withJSONObject: ["path": fixture.repository.path,
            "repositoryPath": fixture.repository.path, "branch": "main", "managed": false])
        let legacy = try JSONDecoder().decode(AgentWorkspace.self, from: data)
        #expect(legacy.repositoryIdentity == nil)
        #expect(legacy.gitDirectory == nil)
        try Data("keep my local work".utf8).write(to: fixture.repository.appendingPathComponent("local.txt"))
        let manager = TaskWorktreeManager()
        try await manager.validate(legacy)
        let explicit = try await manager.provisionAgent(ticketID: "ECC-035", subtaskID: UUID().uuidString,
            path: fixture.repository.path, createWorktree: false, store: TaskContextStore(root: fixture.support))
        #expect(explicit.path == fixture.repository.path)
        #expect(!explicit.managed)
    }
}

private struct WorkspaceSafetyFixture {
    let root: URL
    var repository: URL { root.appendingPathComponent("repo") }
    var support: URL { root.appendingPathComponent("support") }

    init() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-safety-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try await initializeRepository()
    }

    func initializeRepository() async throws {
        _ = try await git(["init", "-q", "-b", "main"])
        _ = try await git(["-c", "user.name=Test", "-c", "user.email=test@example.invalid",
            "-c", "core.hooksPath=/dev/null", "commit", "-qm", "Fixture", "--allow-empty"])
    }

    func git(_ arguments: [String]) async throws -> String {
        let result = try await FoundationProcessRunner().run(.init(executable: "/usr/bin/git",
            arguments: arguments, workingDirectory: repository.path))
        try #require(result.succeeded, "\(result.standardError)")
        return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
