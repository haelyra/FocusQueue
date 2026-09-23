import Foundation
import Testing
@testable import FocusQueueCore

@Suite("Agent workspace launch safety")
struct AgentWorkspaceSafetyTests {
    @Test("Managed worktrees live under the canonical repository, never in app support")
    func repositoryOwnedLayout() async throws {
        let fixture = try await WorkspaceSafetyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let support = fixture.root.appendingPathComponent("Library/Application Support/ECC Focus Queue")
        let store = TaskContextStore(root: support)
        let manager = TaskWorktreeManager()
        let task = DashboardTicket(id: "ECC-035", title: "Location", status: "open", summary: "")
        let context = try await manager.provision(ticket: task,
            repositoryPath: fixture.repository.path, store: store)
        let taskPath = try #require(context.worktreePath)
        let expectedRoot = fixture.repository.appendingPathComponent(".worktrees")
        #expect(taskPath == expectedRoot.appendingPathComponent("ecc-035/task").path)
        #expect(!taskPath.contains("Application Support"))
        let markerURL = expectedRoot.appendingPathComponent(".focus-queue-worktrees.json")
        let marker = try #require(try JSONSerialization.jsonObject(
            with: Data(contentsOf: markerURL)) as? [String: Any])
        #expect(marker["schemaVersion"] as? Int == 1)
        #expect(marker["repositoryPath"] as? String == fixture.repository.path)
        #expect((marker["repositoryIdentity"] as? String)?.contains("/.git:") == true)
        #expect((try markerURL.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true)
        #expect((try markerURL.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true)

        let agentID = UUID().uuidString
        let agent = try await manager.provisionAgent(ticketID: task.id, subtaskID: agentID,
            path: fixture.repository.path, policy: .isolatedCommittedSnapshot, store: store)
        #expect(agent.path == expectedRoot.appendingPathComponent("ecc-035/agents/\(agentID.lowercased())").path)
        #expect(try await !manager.hasUncommittedChanges(at: fixture.repository.path))
        #expect(!FileManager.default.fileExists(atPath: support.appendingPathComponent("worktrees").path))
    }

    @Test("Recorded legacy sibling worktrees remain valid after nested storage becomes the default")
    func legacySiblingResume() async throws {
        let fixture = try await WorkspaceSafetyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = TaskWorktreeManager()
        let store = TaskContextStore(root: fixture.support)
        _ = try await manager.provisionAgent(ticketID: "SEED", subtaskID: UUID().uuidString,
            path: fixture.repository.path, policy: .isolatedCommittedSnapshot, store: store)

        let nestedRoot = TaskWorktreeManager.managedRoot(repositoryPath: fixture.repository.path)
        let legacyRoot = fixture.repository.deletingLastPathComponent()
            .appendingPathComponent(fixture.repository.lastPathComponent + "-worktrees")
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: false)
        try FileManager.default.copyItem(
            at: nestedRoot.appendingPathComponent(".focus-queue-worktrees.json"),
            to: legacyRoot.appendingPathComponent(".focus-queue-worktrees.json"))

        let agentID = UUID().uuidString
        let branch = "focus-queue/ecc-legacy-\(agentID.lowercased())"
        let legacyPath = legacyRoot.appendingPathComponent(
            "ecc-legacy/agents/\(agentID.lowercased())")
        try FileManager.default.createDirectory(
            at: legacyPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try await fixture.git(["worktree", "add", "-qb", branch, legacyPath.path])
        var saved = try await manager.workspace(at: legacyPath.path)
        saved.repositoryPath = fixture.repository.path
        saved.managed = true

        try await manager.validate(saved)
        try await manager.restoreIfNeeded(saved, ticketID: "ECC-LEGACY",
            subtaskID: agentID, store: store)
        #expect(FileManager.default.fileExists(atPath: saved.path))
    }

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

    @Test("An intermediate symlink cannot redirect managed worktree creation")
    func redirectedManagedAncestor() async throws {
        let fixture = try await WorkspaceSafetyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = TaskWorktreeManager()
        let store = TaskContextStore(root: fixture.support)
        _ = try await manager.provisionAgent(ticketID: "ECC-035", subtaskID: UUID().uuidString,
            path: fixture.repository.path, policy: .isolatedCommittedSnapshot, store: store)
        let root = TaskWorktreeManager.managedRoot(repositoryPath: fixture.repository.path)
        let redirected = fixture.root.appendingPathComponent("redirected")
        try FileManager.default.createDirectory(at: redirected, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("ecc-036"), withDestinationURL: redirected)

        await #expect(throws: TaskContextError.self) {
            try await manager.provisionAgent(ticketID: "ECC-036", subtaskID: UUID().uuidString,
                path: fixture.repository.path, policy: .isolatedCommittedSnapshot, store: store)
        }
        #expect(!FileManager.default.fileExists(atPath: redirected.appendingPathComponent("agents").path))
    }

    @Test("A nonempty unmarked managed directory is never adopted as storage")
    func unownedManagedRoot() async throws {
        let fixture = try await WorkspaceSafetyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let root = TaskWorktreeManager.managedRoot(repositoryPath: fixture.repository.path)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("someone else's files".utf8).write(to: root.appendingPathComponent("keep.txt"))

        await #expect(throws: TaskContextError.self) {
            try await TaskWorktreeManager().provisionAgent(
                ticketID: "ECC-035", subtaskID: UUID().uuidString,
                path: fixture.repository.path, policy: .isolatedCommittedSnapshot,
                store: TaskContextStore(root: fixture.support))
        }
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".focus-queue-worktrees.json").path))
    }

    @Test("Writable managed roots are rejected even when their marker is valid")
    func writableManagedRoot() async throws {
        let fixture = try await WorkspaceSafetyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = TaskWorktreeManager()
        let store = TaskContextStore(root: fixture.support)
        _ = try await manager.provisionAgent(ticketID: "ECC-035", subtaskID: UUID().uuidString,
            path: fixture.repository.path, policy: .isolatedCommittedSnapshot, store: store)
        let root = TaskWorktreeManager.managedRoot(repositoryPath: fixture.repository.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: root.path)

        await #expect(throws: TaskContextError.self) {
            try await manager.provisionAgent(ticketID: "ECC-036", subtaskID: UUID().uuidString,
                path: fixture.repository.path, policy: .isolatedCommittedSnapshot, store: store)
        }
    }

    @Test("Coding repositories inside Focus Queue application support are rejected")
    func applicationSupportSource() async throws {
        let fixture = try await WorkspaceSafetyFixture(
            repositoryRelativePath: "Library/Application Support/ECC Focus Queue/repo",
            supportRelativePath: "Library/Application Support/ECC Focus Queue")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        do {
            _ = try await TaskWorktreeManager().provisionAgent(
                ticketID: "ECC-035", subtaskID: UUID().uuidString,
                path: fixture.repository.path, policy: .isolatedCommittedSnapshot,
                store: TaskContextStore(root: fixture.support))
            Issue.record("Application Support repository was accepted")
        } catch {
            #expect(error.localizedDescription.contains("Application Support"))
        }
    }

    @Test("A saved resume cannot return to a workspace inside application support")
    func applicationSupportResume() async throws {
        let fixture = try await WorkspaceSafetyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let savedPath = fixture.support.appendingPathComponent("saved-agent")
        try FileManager.default.createDirectory(at: savedPath, withIntermediateDirectories: true)
        let saved = AgentWorkspace(path: savedPath.path,
            repositoryPath: fixture.repository.path, branch: "focus-queue/ecc-035-agent",
            managed: true)

        do {
            try await TaskWorktreeManager().restoreIfNeeded(saved,
                ticketID: "ECC-035", subtaskID: UUID().uuidString,
                store: TaskContextStore(root: fixture.support))
            Issue.record("Application Support workspace was accepted")
        } catch {
            #expect(error.localizedDescription.contains("Application Support"))
        }
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
    let repository: URL
    let support: URL

    init(repositoryRelativePath: String = "repo", supportRelativePath: String = "support") async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-safety-\(UUID().uuidString)")
        repository = root.appendingPathComponent(repositoryRelativePath)
        support = root.appendingPathComponent(supportRelativePath)
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
