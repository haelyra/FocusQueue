// T3ToolClient tests.
//
// Live-probe fixture convention (optional; the fixture test skips when none exist):
//   Tests/Fixtures/T3/tool-<toolname>.json            e.g. tool-t3_thread_read.json
//   Tests/Fixtures/T3/tool-<toolname>-<variant>.json  e.g. tool-t3_pending_request-list.json
// Each file holds one `tools/call` `result` exactly as captured: an object with
// `structuredContent` and/or `content: [{type: "text", text}]`. A file holding only the bare
// structured payload is also accepted. For `t3_pending_request` the variant names the action
// (`list` or `read`); other tools ignore the variant. Error results (`isError: true`) must be
// listed in `expectedFixtureErrors` with the error they map to.

import Foundation
import Testing
@testable import FocusQueueCore

/// Records every request and answers with scripted results, in order per tool name.
actor RecordingT3Transport: T3MCPTransporting {
    struct Request: Equatable, Sendable {
        var method: String
        var name: String?
        var params: [String: JSONValue]
        var arguments: JSONValue? { params["arguments"] }
    }

    enum Reply: Sendable {
        case result(JSONValue)
        case failure(T3Error)
    }

    private(set) var requests: [Request] = []
    private var replies: [String: [Reply]] = [:]

    /// Queues replies for `tool`. The last reply repeats once the queue runs out.
    func script(_ tool: String, _ next: Reply...) { replies[tool, default: []] += next }

    func request(method: String, name: String?, params: [String: JSONValue]) async throws -> JSONValue {
        requests.append(Request(method: method, name: name, params: params))
        let key = name ?? method
        guard var queue = replies[key], let reply = queue.first else {
            throw T3Error.invalidResponse("unscripted \(key)")
        }
        if queue.count > 1 { queue.removeFirst(); replies[key] = queue }
        switch reply {
        case .result(let value): return value
        case .failure(let error): throw error
        }
    }

    func stream(name: String, arguments: JSONValue, heartbeatMs: Int) async -> AsyncThrowingStream<T3StreamMessage, any Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func cancelAll() async {}
}

private func structured(_ value: JSONValue) -> RecordingT3Transport.Reply {
    .result(["structuredContent": value, "content": [["type": "text", "text": "ignored"]]])
}

private func textResult(_ json: String) -> RecordingT3Transport.Reply {
    .result(["content": [["type": "image", "data": "x"], ["type": "text", "text": .string(json)]]])
}

private func toolError(_ code: String, _ message: String) -> RecordingT3Transport.Reply {
    let payload: JSONValue = ["_tag": "OrchestratorMcpFailure", "code": .string(code), "message": .string(message)]
    let text = String(data: (try? payload.data()) ?? Data(), encoding: .utf8) ?? ""
    return .result(["isError": true, "content": [["type": "text", "text": .string(text)]]])
}

private func makeClient() -> (T3ToolClient, RecordingT3Transport) {
    let transport = RecordingT3Transport()
    return (T3ToolClient(transport: transport), transport)
}

private func expectCall(_ request: RecordingT3Transport.Request?, _ tool: String, _ arguments: JSONValue,
                        sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(request?.method == "tools/call", sourceLocation: sourceLocation)
    #expect(request?.name == tool, sourceLocation: sourceLocation)
    #expect(request?.params["name"] == .string(tool), sourceLocation: sourceLocation)
    #expect(request?.arguments == arguments, sourceLocation: sourceLocation)
}

private func thrownError(_ body: () async throws -> Void) async -> (any Error)? {
    do { try await body(); return nil } catch { return error }
}

@Suite("T3 tool client")
struct T3ToolClientTests {
    // MARK: Requests

    @Test("launch sends the documented arguments and decodes the result")
    func launch() async throws {
        let (client, transport) = makeClient()
        await transport.script("t3_thread_launch", structured(["threadId": "mcp:launch:abc", "link": "t3://thread/abc", "projectId": "p1"]))
        let request = T3LaunchRequest(
            title: "Fix bug", projectId: "p1", message: "Do it", instanceId: "codex-1", model: "gpt-6.2",
            options: ["reasoningEffort": "high"], worktreePath: "/tmp/wt", clientRequestId: "req-1",
            runtimeMode: "full-access")
        let result = try await client.launch(request)
        #expect(result == T3LaunchResult(threadId: "mcp:launch:abc", link: "t3://thread/abc", projectId: "p1"))
        let expected: JSONValue = [
            "title": "Fix bug", "projectId": "p1", "message": "Do it",
            "modelSelection": ["instanceId": "codex-1", "model": "gpt-6.2", "options": ["reasoningEffort": "high"]],
            "workspaceStrategy": ["type": "existing_worktree", "worktreePath": "/tmp/wt"],
            "clientRequestId": "req-1", "runtimeMode": "full-access",
        ]
        expectCall(await transport.requests.first, "t3_thread_launch", expected)
    }

    @Test("launch omits options and runtimeMode when nil")
    func launchMinimal() async throws {
        let (client, transport) = makeClient()
        await transport.script("t3_thread_launch", structured(["threadId": "t1", "link": "l", "projectId": "p1"]))
        _ = try await client.launch(T3LaunchRequest(
            title: "T", projectId: "p1", message: "M", instanceId: "i", model: "m", worktreePath: "/w", clientRequestId: "c"))
        let expected: JSONValue = [
            "title": "T", "projectId": "p1", "message": "M",
            "modelSelection": ["instanceId": "i", "model": "m"],
            "workspaceStrategy": ["type": "existing_worktree", "worktreePath": "/w"],
            "clientRequestId": "c",
        ]
        expectCall(await transport.requests.first, "t3_thread_launch", expected)
    }

    @Test("send, interrupt, and wait send their arguments")
    func sendInterruptWait() async throws {
        let (client, transport) = makeClient()
        await transport.script("t3_thread_send", structured(["accepted": true]))
        await transport.script("t3_thread_interrupt", structured(["runId": "r1", "status": "interrupt_requested"]))
        await transport.script("t3_thread_wait", textResult(#"{"runId":"r1","status":"interrupted","timedOut":false}"#))

        try await client.send(threadId: "t1", message: "hi", mode: .steer, clientRequestId: "c1")
        try await client.send(threadId: "t1", message: "again", mode: .queue, clientRequestId: nil)
        let interrupt = try await client.interrupt(threadId: "t1", stop: true, reason: "paused")
        let wait = try await client.wait(threadId: "t1", runId: "r1", timeoutMs: 30_000)

        #expect(interrupt == T3InterruptResult(runId: "r1", status: "interrupt_requested"))
        #expect(wait == T3WaitResult(runId: "r1", status: "interrupted", timedOut: false))
        let requests = await transport.requests
        #expect(requests.count == 4)
        expectCall(requests[0], "t3_thread_send", ["threadId": "t1", "message": "hi", "mode": "steer", "clientRequestId": "c1"])
        expectCall(requests[1], "t3_thread_send", ["threadId": "t1", "message": "again", "mode": "queue"])
        expectCall(requests[2], "t3_thread_interrupt", ["threadId": "t1", "stop": true, "reason": "paused"])
        expectCall(requests[3], "t3_thread_wait", ["threadId": "t1", "runId": "r1", "timeoutMs": 30_000])
    }

    @Test("interrupt without a reason sends only threadId and stop")
    func interruptNoReason() async throws {
        let (client, transport) = makeClient()
        await transport.script("t3_thread_interrupt", structured(["runId": "r1", "status": "interrupt_requested"]))
        _ = try await client.interrupt(threadId: "t1", stop: false, reason: nil)
        expectCall(await transport.requests.first, "t3_thread_interrupt", ["threadId": "t1", "stop": false])
    }

    @Test("wait with timedOut true")
    func waitTimedOut() async throws {
        let (client, transport) = makeClient()
        await transport.script("t3_thread_wait", structured(["runId": "r2", "status": "running", "timedOut": true]))
        let result = try await client.wait(threadId: "t1", runId: "r2", timeoutMs: 10)
        #expect(result == T3WaitResult(runId: "r2", status: "running", timedOut: true))
    }

    @Test("archive settles then archives")
    func archiveTwoSteps() async throws {
        let (client, transport) = makeClient()
        await transport.script("t3_thread_organize", structured(["ok": true]))
        try await client.archive(threadId: "t1")
        let requests = await transport.requests
        #expect(requests.count == 2)
        expectCall(requests[0], "t3_thread_organize", ["threadId": "t1", "action": "settle"])
        expectCall(requests[1], "t3_thread_organize", ["threadId": "t1", "action": "archive"])
    }

    @Test("archive stops when settle fails")
    func archiveSettleFails() async throws {
        let (client, transport) = makeClient()
        await transport.script("t3_thread_organize", toolError("thread_not_found", "Thread not found"))
        let error = await thrownError { try await client.archive(threadId: "t9") }
        #expect(error as? T3Error == .threadNotFound("t9"))
        #expect(await transport.requests.count == 1)
    }

    @Test("pending request list, read, and respond use the action argument")
    func pendingRequests() async throws {
        let (client, transport) = makeClient()
        let read: JSONValue = [
            "requestId": "q1",
            "questions": [[
                "id": "pick", "header": "Choice", "question": "Which one?",
                "options": [["label": "A", "description": "first"], ["label": "B"]], "multiSelect": false,
            ]],
        ]
        await transport.script("t3_pending_request",
                               structured(["requestIds": ["q1", "q2"]]), structured(read), structured(["ok": true]))

        let ids = try await client.questionIds(threadId: "t1")
        let question = try await client.question(threadId: "t1", requestId: "q1")
        try await client.answer(threadId: "t1", requestId: "q1", answers: ["pick": "A"])

        #expect(ids == ["q1", "q2"])
        #expect(question == T3PendingRequest(requestId: "q1", questions: [
            T3Question(id: "pick", header: "Choice", question: "Which one?",
                       options: [T3QuestionOption(label: "A", description: "first"), T3QuestionOption(label: "B")]),
        ]))
        let requests = await transport.requests
        expectCall(requests[0], "t3_pending_request", ["action": "list", "threadId": "t1"])
        expectCall(requests[1], "t3_pending_request", ["action": "read", "threadId": "t1", "requestId": "q1"])
        expectCall(requests[2], "t3_pending_request",
                   ["action": "respond", "threadId": "t1", "requestId": "q1", "answers": ["pick": "A"]])
    }

    @Test("question ids accept a bare array")
    func questionIdsBare() async throws {
        let (client, transport) = makeClient()
        await transport.script("t3_pending_request", structured(["q9"]))
        #expect(try await client.questionIds(threadId: "t1") == ["q9"])
    }

    @Test("project list pages by cursor")
    func projectPaging() async throws {
        let (client, transport) = makeClient()
        await transport.script(
            "t3_project_list",
            structured(["projects": [["id": "p1", "title": "One", "workspaceRoot": "/a"]], "nextCursor": "c2"]),
            structured(["projects": [["id": "p2", "title": "Two", "workspaceRoot": "/b"]], "cursor": "c3"]),
            structured(["projects": [["id": "p3", "title": "Three", "workspaceRoot": "/c"]], "nextCursor": nil]))
        let projects = try await client.listProjects()
        #expect(projects.map(\.id) == ["p1", "p2", "p3"])
        let requests = await transport.requests
        #expect(requests.count == 3)
        expectCall(requests[0], "t3_project_list", [:])
        expectCall(requests[1], "t3_project_list", ["cursor": "c2"])
        expectCall(requests[2], "t3_project_list", ["cursor": "c3"])
    }

    @Test("project list stops on a repeated cursor")
    func projectPagingRepeat() async throws {
        let (client, transport) = makeClient()
        await transport.script("t3_project_list", structured(["projects": [], "nextCursor": "same"]))
        _ = try await client.listProjects()
        #expect(await transport.requests.count == 2)
    }

    @Test("create project sends title and workspaceRoot")
    func createProject() async throws {
        let (client, transport) = makeClient()
        await transport.script("t3_project_create",
                               structured(["id": "p1", "title": "Repo", "workspaceRoot": "/r", "createdAt": "x"]))
        let project = try await client.createProject(path: "/r", title: "Repo")
        #expect(project == T3Project(id: "p1", title: "Repo", workspaceRoot: "/r"))
        expectCall(await transport.requests.first, "t3_project_create", ["title": "Repo", "workspaceRoot": "/r"])
    }

    @Test("providers and environment send empty arguments")
    func emptyArguments() async throws {
        let (client, transport) = makeClient()
        await transport.script("orchestrator_capabilities", structured(["providers": []]))
        await transport.script("t3_environment_read", structured(["environmentId": "env-1"]))
        #expect(try await client.providers().isEmpty)
        #expect(try await client.environment() == T3Environment(environmentId: "env-1"))
        let requests = await transport.requests
        expectCall(requests[0], "orchestrator_capabilities", [:])
        expectCall(requests[1], "t3_environment_read", [:])
    }

    // MARK: Errors

    @Test("thread_not_found maps to threadNotFound")
    func threadNotFound() async throws {
        let (client, transport) = makeClient()
        await transport.script("t3_thread_read", toolError("thread_not_found", "No such thread"))
        let error = await thrownError { _ = try await client.snapshot(threadId: "gone") }
        #expect(error as? T3Error == .threadNotFound("gone"))
    }

    @Test("thread_not_found in structuredContent also maps")
    func threadNotFoundStructured() async throws {
        let (client, transport) = makeClient()
        await transport.script("t3_thread_send", .result([
            "isError": true,
            "structuredContent": ["_tag": "OrchestratorMcpFailure", "code": "thread_not_found", "message": "gone"],
        ]))
        let error = await thrownError { try await client.send(threadId: "t5", message: "x", mode: .auto, clientRequestId: nil) }
        #expect(error as? T3Error == .threadNotFound("t5"))
    }

    @Test("no_active_run on interrupt returns a result")
    func noActiveRun() async throws {
        let (client, transport) = makeClient()
        await transport.script("t3_thread_interrupt", toolError("no_active_run", "Thread has no active run"))
        let result = try await client.interrupt(threadId: "t1", stop: false, reason: nil)
        #expect(result == T3InterruptResult(runId: nil, status: "no_active_run"))
    }

    @Test("no_active_run elsewhere is a rejection")
    func noActiveRunElsewhere() async throws {
        let (client, transport) = makeClient()
        await transport.script("t3_thread_send", toolError("no_active_run", "nothing"))
        let error = await thrownError { try await client.send(threadId: "t1", message: "x", mode: .steer, clientRequestId: nil) }
        #expect(error as? T3Error == .rejected(code: "no_active_run", message: "nothing"))
    }

    @Test("any respond failure maps to requestNotOpen")
    func respondFailure() async throws {
        let (client, transport) = makeClient()
        await transport.script("t3_pending_request", toolError("invalid_request", "Request is not pending"))
        let error = await thrownError { try await client.answer(threadId: "t1", requestId: "q1", answers: ["a": "b"]) }
        #expect(error as? T3Error == .requestNotOpen("q1"))
    }

    @Test("duplicate project maps to projectAlreadyRegistered")
    func duplicateProject() async throws {
        let (client, transport) = makeClient()
        await transport.script("t3_project_create",
                               toolError("invalid_request", "The workspace is already registered to a project."))
        let error = await thrownError { _ = try await client.createProject(path: "/r", title: "R") }
        #expect(error as? T3Error == .projectAlreadyRegistered)
    }

    @Test("other failures map to rejected")
    func otherRejection() async throws {
        let (client, transport) = makeClient()
        await transport.script("t3_thread_launch",
                               toolError("invalid_request", "worktreePath must be one of the project's git worktrees."))
        let error = await thrownError {
            _ = try await client.launch(T3LaunchRequest(
                title: "T", projectId: "p", message: "m", instanceId: "i", model: "m", worktreePath: "/x", clientRequestId: "c"))
        }
        #expect(error as? T3Error == .rejected(code: "invalid_request",
                                               message: "worktreePath must be one of the project's git worktrees."))
    }

    @Test("transport rejections get the same mapping; connectivity errors pass through")
    func transportErrors() async throws {
        let (client, transport) = makeClient()
        await transport.script("t3_thread_read", .failure(.rejected(code: "thread_not_found", message: "x")))
        await transport.script("t3_thread_list", .failure(.notRunning))
        await transport.script("t3_pending_request", .failure(.outcomeUnknown("timeout")))
        #expect(await thrownError { _ = try await client.snapshot(threadId: "t1") } as? T3Error == .threadNotFound("t1"))
        #expect(await thrownError { _ = try await client.list(projectId: "p") } as? T3Error == .notRunning)
        #expect(await thrownError { try await client.answer(threadId: "t", requestId: "q", answers: [:]) } as? T3Error
            == .outcomeUnknown("timeout"))
    }

    @Test("missing or undecodable results are invalidResponse")
    func invalidResponses() async throws {
        let (client, transport) = makeClient()
        await transport.script("t3_thread_read", structured(["notThread": true]))
        await transport.script("t3_environment_read", textResult("not json"))
        await transport.script("t3_thread_list", .result(["content": []]))
        await transport.script("t3_thread_launch", structured(["link": "l"]))
        func isInvalid(_ error: (any Error)?) -> Bool {
            if case .invalidResponse = error as? T3Error { return true }
            return false
        }
        #expect(isInvalid(await thrownError { _ = try await client.snapshot(threadId: "t1") }))
        #expect(isInvalid(await thrownError { _ = try await client.environment() }))
        #expect(isInvalid(await thrownError { _ = try await client.list(projectId: "p") }))
        #expect(isInvalid(await thrownError {
            _ = try await client.launch(T3LaunchRequest(
                title: "T", projectId: "p", message: "m", instanceId: "i", model: "m", worktreePath: "/x", clientRequestId: "c"))
        }))
    }

    // MARK: Decoding

    @Test("snapshot decodes thread and recent runs, using position for a missing ordinal")
    func snapshotDecoding() async throws {
        let (client, transport) = makeClient()
        let payload: JSONValue = [
            "thread": [
                "threadId": "t1", "status": "idle", "activeRunId": nil, "pendingRequestCount": 2,
                "worktreePath": "/w", "branch": nil, "archived": false, "settled": true,
            ],
            "recentRuns": [
                ["runId": "r0", "status": "completed", "requestedAt": "2026-11-22T10:00:00Z"],
                ["runId": "r1", "ordinal": 7, "status": "failed", "completedAt": "2026-11-22T11:00:00Z"],
            ],
            "items": [],
        ]
        await transport.script("t3_thread_read", structured(payload))
        let snapshot = try await client.snapshot(threadId: "t1")
        #expect(snapshot == T3ThreadSnapshot(
            threadId: "t1",
            thread: T3ThreadState(status: "idle", pendingRequestCount: 2, worktreePath: "/w", settled: true),
            recentRuns: [
                T3Run(runId: "r0", ordinal: 0, status: "completed", requestedAt: "2026-11-22T10:00:00Z"),
                T3Run(runId: "r1", ordinal: 7, status: "failed", completedAt: "2026-11-22T11:00:00Z"),
            ]))
        expectCall(await transport.requests.first, "t3_thread_read", ["threadId": "t1", "limit": 1, "runLimit": 5])
    }

    @Test("thread list decodes rows, dates, and background tasks")
    func threadListDecoding() async throws {
        let (client, transport) = makeClient()
        let rows: JSONValue = ["threads": [
            [
                "threadId": "t1", "title": "One", "status": "running", "latestRunId": "r1",
                "createdAt": "2026-11-22T10:00:00.123Z", "updatedAt": "2026-11-22T10:05:00Z",
                "link": "t3://t1", "providerInstanceId": "codex-1", "model": "gpt-6.2", "runtimeMode": "full-access",
                "settled": false, "pendingBackgroundTasks": [["id": "bg1"]], "blockedOnThreadWait": true,
                "parentThreadId": nil,
            ],
            ["threadId": "t2", "title": "Two", "status": "idle", "createdAt": "2026-11-22T10:00:00Z", "pendingBackgroundTasks": 2],
            ["threadId": "t3", "title": "Three", "status": "completed"],
        ]]
        await transport.script("t3_thread_list", structured(rows))
        let result = try await client.list(projectId: "p1")
        expectCall(await transport.requests.first, "t3_thread_list", ["projectId": "p1"])
        #expect(result.count == 3)
        let base = Date(timeIntervalSince1970: 1_795_341_600) // 2026-11-22T10:00:00Z
        var first = result[0]
        first.createdAt = nil // Compared with a tolerance below.
        #expect(first == T3ThreadRow(
            threadId: "t1", title: "One", status: "running", latestRunId: "r1",
            createdAt: nil, updatedAt: "2026-11-22T10:05:00Z", link: "t3://t1",
            providerInstanceId: "codex-1", model: "gpt-6.2", settled: false,
            pendingBackgroundTasks: [["id": "bg1"]], blockedOnThreadWait: true))
        #expect(abs((result[0].createdAt?.timeIntervalSince(base) ?? 0) - 0.123) < 0.001)
        #expect(result[1].createdAt == base)
        #expect(result[1].pendingBackgroundTasks.count == 2)
        #expect(result[2].createdAt == nil)
        #expect(result[2].pendingBackgroundTasks.isEmpty)
        #expect(result[2].blockedOnThreadWait == false)
    }

    @Test("thread list accepts a bare array from text content")
    func threadListBare() async throws {
        let (client, transport) = makeClient()
        await transport.script("t3_thread_list", textResult(#"[{"threadId":"t1","title":"x","status":"idle"}]"#))
        #expect(try await client.list(projectId: "p").map(\.threadId) == ["t1"])
    }

    @Test("providers decode models, options, and constraints")
    func providersDecoding() async throws {
        let (client, transport) = makeClient()
        let payload: JSONValue = ["providers": [
            [
                "providerInstanceId": "codex-1", "driverKind": "codex", "displayName": "Codex",
                "models": [[
                    "id": "gpt-6.2", "label": "GPT-6.2",
                    "options": [["id": "reasoningEffort", "values": ["low", "high"], "default": "high"]],
                ]],
                "runtimeModes": ["full-access"], "constraints": [],
            ],
            [
                "providerInstanceId": "claude-1", "driverKind": "claudeAgent", "displayName": "Claude",
                "models": [["id": "fable-5.2"]], "constraints": ["Provider instance is disabled."],
            ],
            ["providerInstanceId": "cursor-1", "driverKind": "cursor", "displayName": "Cursor", "models": []],
        ]]
        await transport.script("orchestrator_capabilities", structured(payload))
        let providers = try await client.providers()
        #expect(providers == [
            T3ProviderInfo(providerInstanceId: "codex-1", driverKind: "codex", displayName: "Codex", models: [
                T3ModelInfo(id: "gpt-6.2", label: "GPT-6.2",
                            options: [T3ModelOption(id: "reasoningEffort", values: ["low", "high"], default: "high")]),
            ]),
            T3ProviderInfo(providerInstanceId: "claude-1", driverKind: "claudeAgent", displayName: "Claude",
                           models: [T3ModelInfo(id: "fable-5.2", label: "fable-5.2")],
                           constraints: ["Provider instance is disabled."]),
            T3ProviderInfo(providerInstanceId: "cursor-1", driverKind: "cursor", displayName: "Cursor", models: []),
        ])
        #expect(providers.map(\.available) == [true, false, true])
    }

    @Test("environment decodes identity fields")
    func environmentDecoding() async throws {
        let (client, transport) = makeClient()
        await transport.script("t3_environment_read", structured([
            "environmentId": "f95d287c", "label": "Mac Studio", "serverVersion": "0.1.12-nightly",
            "platform": "darwin", "preferences": ["defaultThreadEnvMode": "worktree"],
        ]))
        #expect(try await client.environment()
            == T3Environment(environmentId: "f95d287c", label: "Mac Studio", serverVersion: "0.1.12-nightly"))
    }

    @Test("wrapped project results decode")
    func wrappedProject() async throws {
        let (client, transport) = makeClient()
        await transport.script("t3_project_create", structured(["project": ["id": "p1", "title": "R", "workspaceRoot": "/r"]]))
        await transport.script("t3_project_list", structured([["id": "p1", "title": "R", "workspaceRoot": "/r"]]))
        #expect(try await client.createProject(path: "/r", title: "R").id == "p1")
        #expect(try await client.listProjects().map(\.id) == ["p1"])
    }

    // MARK: Live-probe fixtures

    @Test("Captured tool fixtures decode (skipped when none exist)")
    func capturedFixtures() async throws {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: T3Fixtures.directory.path)) ?? []
        let fixtures = files.filter { $0.hasPrefix("tool-") && $0.hasSuffix(".json") }.sorted()
        for file in fixtures {
            var result = try T3Fixtures.json(file)
            if result["structuredContent"] == nil, result["content"] == nil {
                result = ["structuredContent": result]
            }
            let stem = String(file.dropFirst("tool-".count).dropLast(".json".count))
            let tool = stem.split(separator: "-", maxSplits: 1).first.map(String.init) ?? stem
            let variant = stem.split(separator: "-", maxSplits: 1).dropFirst().first.map(String.init)
            let (client, transport) = makeClient()
            await transport.script(tool, .result(result))
            if let expected = Self.expectedFixtureErrors[file] {
                do {
                    try await decodeFixture(client: client, tool: tool, variant: variant)
                    Issue.record("\(file) is an error result but decoded")
                } catch let error as T3Error {
                    #expect(error == expected, "\(file)")
                }
                continue
            }
            #expect(result["isError"]?.boolValue != true, "\(file) is an error result without an expected error")
            do {
                try await decodeFixture(client: client, tool: tool, variant: variant)
            } catch {
                Issue.record("\(file) failed to decode: \(error)")
            }
        }
    }

    /// Error results captured from T3 Code and the error each must map to.
    private static let expectedFixtureErrors: [String: T3Error] = [
        "tool-t3_project_create-duplicate.json": .projectAlreadyRegistered,
        "tool-t3_project_create-error.json": .rejected(
            code: "capability_denied",
            message: "Changing projects or environment settings needs a live full-access/default calling thread or a full-access client."),
        "tool-t3_thread_launch-rejected.json": .rejected(
            code: "invalid_request",
            message: "worktreePath must be one of the project's git worktrees. t3_worktree_list shows them."),
    ]

    private func decodeFixture(client: T3ToolClient, tool: String, variant: String?) async throws {
        let launch = T3LaunchRequest(title: "t", projectId: "p", message: "m", instanceId: "i", model: "m",
                                     worktreePath: "/w", clientRequestId: "c")
        switch tool {
        case "t3_thread_launch": _ = try await client.launch(launch)
        case "t3_thread_send": try await client.send(threadId: "t", message: "m", mode: .auto, clientRequestId: nil)
        case "t3_thread_interrupt": _ = try await client.interrupt(threadId: "t", stop: false, reason: nil)
        case "t3_thread_wait": _ = try await client.wait(threadId: "t", runId: "r", timeoutMs: 1)
        case "t3_thread_read": _ = try await client.snapshot(threadId: "t")
        case "t3_thread_list": _ = try await client.list(projectId: "p")
        case "t3_thread_organize": try await client.archive(threadId: "t")
        case "t3_pending_request":
            switch variant {
            case "read": _ = try await client.question(threadId: "t", requestId: "q")
            case "respond": try await client.answer(threadId: "t", requestId: "q", answers: [:])
            default: _ = try await client.questionIds(threadId: "t")
            }
        case "t3_project_list": _ = try await client.listProjects()
        case "t3_project_create": _ = try await client.createProject(path: "/w", title: "t")
        case "orchestrator_capabilities": _ = try await client.providers()
        case "t3_environment_read": _ = try await client.environment()
        default: break // A tool this client does not call.
        }
    }
}
