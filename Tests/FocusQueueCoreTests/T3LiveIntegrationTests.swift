import Foundation
import Testing
@testable import FocusQueueCore

// Opt-in live suite (Task 22). Runs only with ECC_FOCUS_QUEUE_LIVE_T3_TESTS=1
// against T3 Code 0.1.12+ at http://127.0.0.1:3773 (or ECC_FOCUS_QUEUE_T3_SERVER).
// The Full access token comes from ECC_FOCUS_QUEUE_T3_TOKEN_FILE, the JSON
// `Scripts/t3_contract_probe.py --login --token-file <path>` writes.
// Each test builds a scratch repo and T3 project and deletes both afterwards.

private let liveEnabled = ProcessInfo.processInfo.environment["ECC_FOCUS_QUEUE_LIVE_T3_TESTS"] == "1"
private let liveServer = ProcessInfo.processInfo.environment["ECC_FOCUS_QUEUE_T3_SERVER"] ?? T3Defaults.serverURL
private let projectPrefix = "fq-live-t3"

private func liveToken() throws -> String {
    guard let path = ProcessInfo.processInfo.environment["ECC_FOCUS_QUEUE_T3_TOKEN_FILE"] else {
        throw T3Error.unauthorized
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
    if let object = try? JSONValue.parse(data), let token = object["access_token"]?.stringValue { return token }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Drops the first launch reply after the request reached the server, to simulate a lost reply.
private actor DroppingTransport: T3MCPTransporting {
    let inner: any T3MCPTransporting
    var dropNextLaunch = false
    init(_ inner: any T3MCPTransporting) { self.inner = inner }
    func setDrop(_ drop: Bool) { dropNextLaunch = drop }
    func request(method: String, name: String?, params: [String: JSONValue]) async throws -> JSONValue {
        let result = try await inner.request(method: method, name: name, params: params)
        if dropNextLaunch, name == "t3_thread_launch" {
            dropNextLaunch = false
            throw T3Error.outcomeUnknown("reply dropped by test")
        }
        return result
    }
    func stream(name: String, arguments: JSONValue, heartbeatMs: Int) async -> AsyncThrowingStream<T3StreamMessage, any Error> {
        await inner.stream(name: name, arguments: arguments, heartbeatMs: heartbeatMs)
    }
    func cancelAll() async { await inner.cancelAll() }
}

/// A connection fixed at `connected` for the live server's environment.
private actor LiveConnection: T3ConnectionProviding {
    let environmentId: String
    init(environmentId: String) { self.environmentId = environmentId }
    func currentStatus() async -> T3ConnectionStatus { .connected(environmentId: environmentId, version: "live") }
    func currentAccessLevel() async -> T3AccessLevel? { .fullAccess }
    func report(_ error: T3Error) async {}
}

private struct LiveHarness {
    let root: URL
    let repository: URL
    let support: URL
    let store: TaskContextStore
    let transport: DroppingTransport
    let tools: T3ToolClient
    let refresher: T3Refresher
    let watcher: T3Watcher
    let runtime: T3Runtime
    let catalog: T3ProviderCatalog
    let project: ProjectConfiguration
    let projectId: String
    let environmentId: String
    let ticketID = "FOC-LIVE"

    static func make() async throws -> LiveHarness {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("\(projectPrefix)-\(UUID().uuidString.prefix(8))")
            .resolvingSymlinksInPath()
        let repository = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        for args in [["init", "-b", "main"], ["config", "user.email", "t@example.com"], ["config", "user.name", "FQ Live"]] {
            try await git(args, in: repository)
        }
        try Data("live\n".utf8).write(to: repository.appendingPathComponent("README.md"))
        try await git(["add", "."], in: repository)
        try await git(["commit", "-m", "Initial"], in: repository)
        let support = root.appendingPathComponent("support")
        let store = TaskContextStore(root: support)
        _ = try await store.ensureContext(ticket: DashboardTicket(id: "FOC-LIVE", title: "Live T3", status: "open", summary: ""))
        let token = try liveToken()
        let base = try #require(URL(string: liveServer))
        let transport = DroppingTransport(T3McpTransport(baseURL: base, token: { token }))
        let tools = T3ToolClient(transport: transport)
        let environment = try await tools.environment()
        let connection = LiveConnection(environmentId: environment.environmentId)
        let stateStore = T3ConnectionStateStore(supportDirectory: support)
        let resolver = T3ProjectResolver(tools: tools, stateStore: stateStore, serverURL: liveServer)
        let project = ProjectConfiguration(id: "live", name: root.lastPathComponent, dashboardPath: "/dev/null",
                                           workspacePath: repository.path, repositoryPath: repository.path)
        let projectId = try await resolver.projectId(for: project, environmentId: environment.environmentId)
        let refresher = T3Refresher(tools: tools, store: store, connection: connection)
        let watcher = T3Watcher(transport: transport, tools: tools, target: refresher, store: store, connection: connection)
        let catalog = T3ProviderCatalog(tools: tools)
        let runtime = T3Runtime(connection: connection, tools: tools, models: catalog, projects: resolver,
                                worktrees: TaskWorktreeT3Adapter(manager: TaskWorktreeManager(), store: store),
                                store: store, dirty: refresher)
        return LiveHarness(root: root, repository: repository, support: support, store: store, transport: transport,
                           tools: tools, refresher: refresher, watcher: watcher, runtime: runtime, catalog: catalog,
                           project: project, projectId: projectId, environmentId: environment.environmentId)
    }

    @discardableResult
    static func git(_ arguments: [String], in directory: URL) async throws -> String {
        let result = try await FoundationProcessRunner().run(.init(executable: "/usr/bin/git", arguments: arguments,
                                                                   workingDirectory: directory.path))
        guard result.succeeded else { throw TaskContextError.commandFailed(result.standardError) }
        return result.standardOutput
    }

    func choice() async throws -> T3LaunchChoice {
        let providers = try await catalog.available()
        let claude = try #require(providers.first { $0.driverKind == "claudeAgent" })
        return T3LaunchChoice(instanceId: claude.providerInstanceId, model: "claude-haiku-5-5")
    }

    func launch(_ prompt: String, id: String = UUID().uuidString.lowercased()) async throws -> (T3SubtaskLocation, TaskSubtask) {
        let subtask = TaskSubtask(id: id, title: "Live \(id.prefix(6))", provider: .claude, runtimeMode: .t3)
        let saved = try await runtime.launch(T3LaunchInput(ticketID: ticketID, subtask: subtask, prompt: prompt,
            project: project, repositoryPath: repository.path, choice: try await choice()))
        return (T3SubtaskLocation(ticketID: ticketID, subtaskID: id), saved)
    }

    func waitFor(_ location: T3SubtaskLocation, timeout: Double,
                 _ condition: @escaping @Sendable (TaskSubtask) -> Bool) async -> TaskSubtask? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let reference = try? await store.subtask(location)?.t3 { await refresher.refreshNow(reference.threadId) }
            if let subtask = try? await store.subtask(location), condition(subtask) { return subtask }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return nil
    }

    func teardown() async {
        await watcher.stop()
        _ = try? await transport.request(method: "tools/call", name: "t3_project_delete",
                                         params: ["name": "t3_project_delete",
                                                  "arguments": ["projectId": .string(projectId), "force": true]])
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("T3 live integration", .serialized, .enabled(if: liveEnabled))
struct T3LiveIntegrationTests {
    @Test("Launch runs in Focus Queue's checkout and commits on its branch")
    func launch() async throws {
        let h = try await LiveHarness.make()
        defer { Task { await h.teardown() } }
        let (location, saved) = try await h.launch(
            "Create a file SPIKE.md containing 'spike', then run: git add SPIKE.md && git commit -m 'spike commit'. Reply DONE.")
        let workspace = try #require(saved.workspace?.path)
        _ = await h.waitFor(location, timeout: 180) { $0.status == .idle }
        let log = try await LiveHarness.git(["log", "--oneline"], in: URL(fileURLWithPath: workspace))
        #expect(log.contains("spike commit"))
        await h.teardown()
    }

    @Test("A question reaches the row through the watcher and an answer resumes the agent")
    func question() async throws {
        let h = try await LiveHarness.make()
        let (location, saved) = try await h.launch(
            "Use your ask-the-user question tool to ask me to choose between 'Option A' and 'Option B'. After I answer, reply with only my choice.")
        await h.watcher.start(environmentId: h.environmentId, projectIds: [h.projectId])
        let blocked = await h.waitFor(location, timeout: 90) { $0.attention == .question }
        let threadId = try #require(saved.t3?.threadId)
        let requestId = try #require(blocked?.t3?.openQuestionIds.first)
        let request = try await h.tools.question(threadId: threadId, requestId: requestId)
        let answers = T3AnswerBuilder.answers(for: request,
            selections: Dictionary(uniqueKeysWithValues: request.questions.map { ($0.id, "Option B") }), freeText: [:])
        try await h.tools.answer(threadId: threadId, requestId: requestId, answers: answers)
        let done = await h.waitFor(location, timeout: 120) { $0.status == .idle && $0.attention == nil }
        #expect(done?.completionUnread == true)
        await h.teardown()
    }

    @Test("Approvals are visible but not answerable")
    func approval() async throws {
        let h = try await LiveHarness.make()
        let choice = try await h.choice()
        let launched = try await h.tools.launch(T3LaunchRequest(
            title: "approval", projectId: h.projectId, message: "Run the shell command: touch APPROVAL_PROBE",
            instanceId: choice.instanceId, model: choice.model, worktreePath: h.repository.path,
            clientRequestId: UUID().uuidString, runtimeMode: "approval-required"))
        var approvals = 0
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline, approvals == 0 {
            let snapshot = try await h.tools.snapshot(threadId: launched.threadId)
            let questions = try await h.tools.questionIds(threadId: launched.threadId)
            approvals = T3StateDeriver.derive(snapshot: snapshot, questionIds: questions,
                previous: T3ThreadReference(environmentId: h.environmentId, threadId: launched.threadId,
                    projectId: h.projectId, link: "", providerInstanceId: "", model: ""), pausedAt: nil).reference.pendingApprovalCount
            if approvals == 0 { try await Task.sleep(nanoseconds: 2_000_000_000) }
        }
        #expect(approvals == 1)
        #expect(try await h.tools.questionIds(threadId: launched.threadId).isEmpty)
        await h.teardown()
    }

    @Test("A turn started outside Focus Queue shows working within 10 seconds")
    func externalTurn() async throws {
        let h = try await LiveHarness.make()
        let (location, saved) = try await h.launch("Reply with only OK.")
        _ = await h.waitFor(location, timeout: 120) { $0.status == .idle }
        await h.watcher.start(environmentId: h.environmentId, projectIds: [h.projectId])
        let threadId = try #require(saved.t3?.threadId)
        // Another client starts the turn; Focus Queue only watches.
        try await h.tools.send(threadId: threadId, message: "Run: sleep 20, then reply OK.", mode: .auto, clientRequestId: nil)
        let started = Date()
        var working = false
        while Date().timeIntervalSince(started) < 10, !working {
            working = (try? await h.store.subtask(location))??.status == .working
            if !working { try await Task.sleep(nanoseconds: 250_000_000) }
        }
        #expect(working)
        await h.teardown()
    }

    @Test("Stop holds a queued prompt and confirms quiescence")
    func stopAndQuiescence() async throws {
        let h = try await LiveHarness.make()
        let (location, saved) = try await h.launch(
            "Run this exact shell command and wait for it: for i in $(seq 1 60); do echo $i >> loop.txt; sleep 1; done")
        let threadId = try #require(saved.t3?.threadId)
        let workspace = try #require(saved.workspace?.path)
        try await Task.sleep(nanoseconds: 8_000_000_000)
        try await h.tools.send(threadId: threadId, message: "Reply with only QUEUED.", mode: .queue, clientRequestId: nil)
        let confirmation = await h.runtime.confirmStopped(location)
        #expect(confirmation.confirmed, "\(confirmation.reason)")
        let file = URL(fileURLWithPath: workspace).appendingPathComponent("loop.txt")
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        try await Task.sleep(nanoseconds: 15_000_000_000)
        let later = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        #expect(later == size)
        let rows = try await h.tools.list(projectId: h.projectId)
        #expect(rows.first { $0.threadId == threadId }?.status != "running")
        await h.teardown()
    }

    @Test("Finish retains an unmerged checkout and archives the thread")
    func finish() async throws {
        let h = try await LiveHarness.make()
        let (location, saved) = try await h.launch(
            "Create a file NOTE.md containing 'note', then run: git add NOTE.md && git commit -m 'note'. Reply DONE.")
        _ = await h.waitFor(location, timeout: 180) { $0.status == .idle }
        let state = await h.runtime.finish(location)
        if case .retained = state {} else { Issue.record("expected retained, got \(String(describing: state))") }
        let snapshot = try await h.tools.snapshot(threadId: try #require(saved.t3?.threadId))
        #expect(snapshot.thread.archived)
        await h.teardown()
    }

    @Test("A lost launch reply reconciles to exactly one thread")
    func lostReply() async throws {
        let h = try await LiveHarness.make()
        await h.transport.setDrop(true)
        let id = UUID().uuidString.lowercased()
        await #expect(throws: T3Error.self) { try await h.launch("Reply with only OK.", id: id) }
        let location = T3SubtaskLocation(ticketID: h.ticketID, subtaskID: id)
        #expect(try await h.store.subtask(location)?.t3Launch?.phase == .unknown)
        await h.runtime.reconcileLaunches()
        let linked = try await h.store.subtask(location)
        #expect(linked?.t3 != nil)
        let path = try #require(linked?.workspace?.path)
        var bound = 0
        for row in try await h.tools.list(projectId: h.projectId) {
            if let worktree = try? await h.tools.snapshot(threadId: row.threadId).thread.worktreePath,
               T3Runtime.standardized(worktree) == T3Runtime.standardized(path) { bound += 1 }
        }
        #expect(bound == 1)
        await h.teardown()
    }
}
