import Foundation
import Testing
@testable import FocusQueueCore

private struct ResolverFixture {
    let root: URL
    let repo: URL
    let store: T3ConnectionStateStore
    let tools = FakeT3Tools()
    let project: ProjectConfiguration

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("t3-resolver-\(UUID().uuidString)")
        repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        store = T3ConnectionStateStore(supportDirectory: root)
        project = ProjectConfiguration(id: "focus", name: "Focus", dashboardPath: repo.path,
                                       workspacePath: repo.path, repositoryPath: repo.path)
    }

    func resolver() -> T3ProjectResolver {
        T3ProjectResolver(tools: tools, stateStore: store, serverURL: "http://127.0.0.1:3773")
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Suite("T3 project resolver")
struct T3ProjectResolverTests {
    @Test("A saved mapping is used without calling T3")
    func usesCache() async throws {
        let fixture = try ResolverFixture(); defer { fixture.cleanup() }
        try fixture.store.save(T3ConnectionState(serverURL: "http://127.0.0.1:3773",
                                                 projectMaps: ["ENV_1": ["focus": "P_SAVED"]]))
        let id = try await fixture.resolver().projectId(for: fixture.project, environmentId: "ENV_1")
        #expect(id == "P_SAVED")
        #expect(await fixture.tools.calls.isEmpty)
    }

    @Test("An existing project is matched by its symlink-resolved path and saved")
    func matchesByPath() async throws {
        let fixture = try ResolverFixture(); defer { fixture.cleanup() }
        let link = fixture.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.repo)
        let other = fixture.root.appendingPathComponent("repo-other").path
        await fixture.tools.set { $0.onListProjects = { [
            T3Project(id: "P_OTHER", title: "Other", workspaceRoot: other),
            T3Project(id: "P_LINK", title: "Focus", workspaceRoot: link.path + "/"),
        ] } }
        // The configuration path goes through `..` and /tmp-style symlinks; both sides normalize.
        var project = fixture.project
        project.repositoryPath = fixture.root.appendingPathComponent("repo/../repo").path
        let resolver = fixture.resolver()
        #expect(try await resolver.projectId(for: project, environmentId: "ENV_1") == "P_LINK")
        #expect(try fixture.store.load()?.projectMaps == ["ENV_1": ["focus": "P_LINK"]])
        // Second call uses the saved mapping.
        await fixture.tools.clearCalls()
        #expect(try await resolver.projectId(for: project, environmentId: "ENV_1") == "P_LINK")
        #expect(await fixture.tools.calls.isEmpty)
    }

    @Test("A missing project is created")
    func createsWhenMissing() async throws {
        let fixture = try ResolverFixture(); defer { fixture.cleanup() }
        await fixture.tools.set {
            $0.onListProjects = { [] }
            $0.onCreateProject = { path, title in T3Project(id: "P_NEW", title: title, workspaceRoot: path) }
        }
        let id = try await fixture.resolver().projectId(for: fixture.project, environmentId: "ENV_1")
        #expect(id == "P_NEW")
        #expect(await fixture.tools.calls == [.listProjects, .createProject(fixture.repo.path, "Focus")])
        #expect(try fixture.store.load()?.projectMaps["ENV_1"]?["focus"] == "P_NEW")
    }

    @Test("Already registered recovers by listing again")
    func recoversFromAlreadyRegistered() async throws {
        let fixture = try ResolverFixture(); defer { fixture.cleanup() }
        let listing = Counter()
        let repoPath = fixture.repo.path
        await fixture.tools.set {
            $0.onListProjects = {
                // First listing misses it (created concurrently elsewhere); second finds it.
                await listing.next() == 1 ? [] : [T3Project(id: "P_RACE", title: "Focus", workspaceRoot: repoPath)]
            }
            $0.onCreateProject = { _, _ in throw T3Error.projectAlreadyRegistered }
        }
        let id = try await fixture.resolver().projectId(for: fixture.project, environmentId: "ENV_1")
        #expect(id == "P_RACE")
        #expect(await fixture.tools.calls == [.listProjects, .createProject(repoPath, "Focus"), .listProjects])
        #expect(try fixture.store.load()?.projectMaps["ENV_1"]?["focus"] == "P_RACE")
    }

    @Test("Already registered with no match rethrows and saves nothing")
    func alreadyRegisteredNoMatch() async throws {
        let fixture = try ResolverFixture(); defer { fixture.cleanup() }
        await fixture.tools.set {
            $0.onListProjects = { [] }
            $0.onCreateProject = { _, _ in throw T3Error.projectAlreadyRegistered }
        }
        await #expect(throws: T3Error.projectAlreadyRegistered) {
            _ = try await fixture.resolver().projectId(for: fixture.project, environmentId: "ENV_1")
        }
        #expect(try fixture.store.load() == nil)
    }

    @Test("Mappings are kept separate per environment")
    func perEnvironment() async throws {
        let fixture = try ResolverFixture(); defer { fixture.cleanup() }
        try fixture.store.save(T3ConnectionState(serverURL: "http://127.0.0.1:3773", clientId: "CLIENT",
                                                 projectMaps: ["ENV_1": ["focus": "P_ENV1"]]))
        await fixture.tools.set {
            $0.onListProjects = { [] }
            $0.onCreateProject = { path, title in T3Project(id: "P_ENV2", title: title, workspaceRoot: path) }
        }
        let resolver = fixture.resolver()
        #expect(try await resolver.projectId(for: fixture.project, environmentId: "ENV_2") == "P_ENV2")
        #expect(try await resolver.projectId(for: fixture.project, environmentId: "ENV_1") == "P_ENV1")
        let state = try #require(try fixture.store.load())
        #expect(state.projectMaps == ["ENV_1": ["focus": "P_ENV1"], "ENV_2": ["focus": "P_ENV2"]])
        #expect(state.clientId == "CLIENT")
    }
}

private actor Counter {
    private var value = 0
    func next() -> Int { value += 1; return value }
}
