import Foundation

/// Typed access to the T3 Code MCP tools. Every method is one or more `tools/call`
/// requests (`archive` and paged `listProjects` make several) on `T3MCPTransporting`.
///
/// Results come from `structuredContent`, or else from the first `text` content parsed as JSON.
/// Tool failures (`isError: true` with `{_tag: "OrchestratorMcpFailure", code, message}`) map to
/// `T3Error`. Decoding is tolerant: unknown fields are ignored and list results may be bare
/// arrays or wrapped in an object (`{threads: [...]}`, `{projects: [...]}`, …).
public actor T3ToolClient: T3ToolCalling {
    private let transport: any T3MCPTransporting
    /// Upper bound on `t3_project_list` pages, in case the server keeps returning cursors.
    private let maxProjectPages: Int

    public init(transport: any T3MCPTransporting, maxProjectPages: Int = 100) {
        self.transport = transport
        self.maxProjectPages = maxProjectPages
    }

    // MARK: Threads

    public func launch(_ request: T3LaunchRequest) async throws -> T3LaunchResult {
        var modelSelection: [String: JSONValue] = ["instanceId": .string(request.instanceId), "model": .string(request.model)]
        if let options = request.options { modelSelection["options"] = .object(options) }
        var arguments: [String: JSONValue] = [
            "title": .string(request.title),
            "projectId": .string(request.projectId),
            "message": .string(request.message),
            "modelSelection": .object(modelSelection),
            "workspaceStrategy": ["type": "existing_worktree", "worktreePath": .string(request.worktreePath)],
            "clientRequestId": .string(request.clientRequestId),
        ]
        if let runtimeMode = request.runtimeMode { arguments["runtimeMode"] = .string(runtimeMode) }
        let result = try await call(Tool.threadLaunch, arguments, context: .thread(nil))
        let object = try T3Decode.object(T3Decode.unwrap(result, "thread"), "t3_thread_launch")
        return T3LaunchResult(
            threadId: try T3Decode.string(object, ["threadId", "id"], "t3_thread_launch"),
            link: object["link"]?.stringValue ?? "",
            projectId: object["projectId"]?.stringValue ?? request.projectId)
    }

    public func send(threadId: String, message: String, mode: T3SendMode, clientRequestId: String?) async throws {
        var arguments: [String: JSONValue] = [
            "threadId": .string(threadId), "message": .string(message), "mode": .string(mode.rawValue),
        ]
        if let clientRequestId { arguments["clientRequestId"] = .string(clientRequestId) }
        _ = try await call(Tool.threadSend, arguments, context: .thread(threadId))
    }

    public func interrupt(threadId: String, stop: Bool, reason: String?) async throws -> T3InterruptResult {
        var arguments: [String: JSONValue] = ["threadId": .string(threadId), "stop": .bool(stop)]
        if let reason { arguments["reason"] = .string(reason) }
        let result: JSONValue
        do {
            result = try await call(Tool.threadInterrupt, arguments, context: .interrupt(threadId))
        } catch NoActiveRun.signal {
            return T3InterruptResult(runId: nil, status: T3InterruptResult.noActiveRun)
        }
        let object = try T3Decode.object(result, "t3_thread_interrupt")
        return T3InterruptResult(
            runId: object["runId"]?.stringValue,
            status: object["status"]?.stringValue ?? "interrupt_requested")
    }

    public func wait(threadId: String, runId: String, timeoutMs: Int) async throws -> T3WaitResult {
        let arguments: [String: JSONValue] = [
            "threadId": .string(threadId), "runId": .string(runId), "timeoutMs": .number(Double(timeoutMs)),
        ]
        let result = try await call(Tool.threadWait, arguments, context: .thread(threadId))
        let outer = try T3Decode.object(result, "t3_thread_wait")
        let run = outer["run"]?.objectValue ?? outer
        let status = try T3Decode.string(run, ["status", "outcome"], "t3_thread_wait")
        let timedOut = outer["timedOut"]?.boolValue ?? run["timedOut"]?.boolValue ?? false
        return T3WaitResult(runId: run["runId"]?.stringValue ?? runId, status: status, timedOut: timedOut)
    }

    public func snapshot(threadId: String) async throws -> T3ThreadSnapshot {
        let arguments: [String: JSONValue] = ["threadId": .string(threadId), "limit": 1, "runLimit": 5]
        let result = try await call(Tool.threadRead, arguments, context: .thread(threadId))
        let object = try T3Decode.object(result, "t3_thread_read")
        guard let thread = object["thread"]?.objectValue else {
            throw T3Error.invalidResponse("t3_thread_read: missing thread")
        }
        let state = T3ThreadState(
            status: try T3Decode.string(thread, ["status"], "t3_thread_read thread"),
            activeRunId: thread["activeRunId"]?.stringValue,
            pendingRequestCount: thread["pendingRequestCount"]?.intValue ?? 0,
            worktreePath: thread["worktreePath"]?.stringValue,
            branch: thread["branch"]?.stringValue,
            archived: thread["archived"]?.boolValue ?? false,
            settled: thread["settled"]?.boolValue ?? false)
        let runValues = object["recentRuns"]?.arrayValue ?? thread["recentRuns"]?.arrayValue ?? []
        var runs: [T3Run] = []
        for (index, value) in runValues.enumerated() {
            runs.append(try T3Decode.run(value, position: index))
        }
        let id = thread["threadId"]?.stringValue ?? thread["id"]?.stringValue ?? object["threadId"]?.stringValue ?? threadId
        return T3ThreadSnapshot(threadId: id, thread: state, recentRuns: runs)
    }

    public func list(projectId: String) async throws -> [T3ThreadRow] {
        let result = try await call(Tool.threadList, ["projectId": .string(projectId)], context: .general)
        let rows = try T3Decode.array(result, key: "threads", "t3_thread_list")
        return try rows.map(T3Decode.threadRow)
    }

    public func archive(threadId: String) async throws {
        for action in ["settle", "archive"] {
            let arguments: [String: JSONValue] = ["threadId": .string(threadId), "action": .string(action)]
            _ = try await call(Tool.threadOrganize, arguments, context: .thread(threadId))
        }
    }

    // MARK: Pending requests

    public func questionIds(threadId: String) async throws -> [String] {
        let arguments: [String: JSONValue] = ["action": "list", "threadId": .string(threadId)]
        let result = try await call(Tool.pendingRequest, arguments, context: .thread(threadId))
        let items = try T3Decode.array(result, key: "requestIds", "t3_pending_request list")
        return try items.map { item in
            if let id = item.stringValue ?? item["requestId"]?.stringValue ?? item["id"]?.stringValue { return id }
            throw T3Error.invalidResponse("t3_pending_request list: request id is not a string")
        }
    }

    public func question(threadId: String, requestId: String) async throws -> T3PendingRequest {
        let arguments: [String: JSONValue] = [
            "action": "read", "threadId": .string(threadId), "requestId": .string(requestId),
        ]
        let result = try await call(Tool.pendingRequest, arguments, context: .thread(threadId))
        let object = try T3Decode.object(T3Decode.unwrap(result, "request"), "t3_pending_request read")
        guard let questionValues = object["questions"]?.arrayValue else {
            throw T3Error.invalidResponse("t3_pending_request read: missing questions")
        }
        let questions: [T3Question]
        do { questions = try questionValues.map { try $0.decode(T3Question.self) } }
        catch { throw T3Error.invalidResponse("t3_pending_request read: \(error)") }
        return T3PendingRequest(requestId: object["requestId"]?.stringValue ?? requestId, questions: questions)
    }

    public func answer(threadId: String, requestId: String, answers: [String: String]) async throws {
        let arguments: [String: JSONValue] = [
            "action": "respond", "threadId": .string(threadId), "requestId": .string(requestId),
            "answers": .object(answers.mapValues { .string($0) }),
        ]
        _ = try await call(Tool.pendingRequest, arguments, context: .respond(requestId))
    }

    // MARK: Projects

    public func listProjects() async throws -> [T3Project] {
        var projects: [T3Project] = []
        var cursor: String?
        var seen: Set<String> = []
        for _ in 0..<maxProjectPages {
            var arguments: [String: JSONValue] = [:]
            if let cursor { arguments["cursor"] = .string(cursor) }
            let result = try await call(Tool.projectList, arguments, context: .general)
            let items = try T3Decode.array(result, key: "projects", "t3_project_list")
            projects += try items.map(T3Decode.project)
            let next = result["nextCursor"]?.stringValue ?? result["cursor"]?.stringValue
            guard let next, !next.isEmpty, seen.insert(next).inserted else { return projects }
            cursor = next
        }
        return projects
    }

    public func createProject(path: String, title: String) async throws -> T3Project {
        let arguments: [String: JSONValue] = ["title": .string(title), "workspaceRoot": .string(path)]
        let result = try await call(Tool.projectCreate, arguments, context: .projectCreate)
        return try T3Decode.project(T3Decode.unwrap(result, "project"))
    }

    // MARK: Server

    public func providers() async throws -> [T3ProviderInfo] {
        let result = try await call(Tool.capabilities, [:], context: .general)
        let items = try T3Decode.array(result, key: "providers", "orchestrator_capabilities")
        return try items.map(T3Decode.provider)
    }

    public func environment() async throws -> T3Environment {
        let result = try await call(Tool.environmentRead, [:], context: .general)
        let object = try T3Decode.object(T3Decode.unwrap(result, "environment"), "t3_environment_read")
        return T3Environment(
            environmentId: try T3Decode.string(object, ["environmentId"], "t3_environment_read"),
            label: object["label"]?.stringValue,
            serverVersion: object["serverVersion"]?.stringValue)
    }

    // MARK: Calling

    enum Tool {
        static let threadLaunch = "t3_thread_launch"
        static let threadSend = "t3_thread_send"
        static let threadInterrupt = "t3_thread_interrupt"
        static let threadWait = "t3_thread_wait"
        static let threadRead = "t3_thread_read"
        static let threadList = "t3_thread_list"
        static let threadOrganize = "t3_thread_organize"
        static let pendingRequest = "t3_pending_request"
        static let projectList = "t3_project_list"
        static let projectCreate = "t3_project_create"
        static let capabilities = "orchestrator_capabilities"
        static let environmentRead = "t3_environment_read"
    }

    /// Which special error mappings apply to a call.
    private enum ErrorContext {
        case general
        case thread(String?)
        case interrupt(String)
        case respond(String)
        case projectCreate
    }

    private enum NoActiveRun: Error { case signal }

    private func call(_ tool: String, _ arguments: [String: JSONValue], context: ErrorContext) async throws -> JSONValue {
        let params: [String: JSONValue] = ["name": .string(tool), "arguments": .object(arguments)]
        let result: JSONValue
        do {
            result = try await transport.request(method: "tools/call", name: tool, params: params)
        } catch let T3Error.rejected(code, message) {
            // A transport that surfaces failures as `.rejected` gets the same mapping as `isError`.
            throw Self.map(code: code, message: message, context: context)
        }
        if result["isError"]?.boolValue == true {
            let failure = Self.failure(in: result)
            throw Self.map(code: failure.code, message: failure.message, context: context)
        }
        return try Self.payload(of: result, tool: tool)
    }

    /// `structuredContent`, else the first `text` content item parsed as JSON.
    private static func payload(of result: JSONValue, tool: String) throws -> JSONValue {
        if let structured = result["structuredContent"], !structured.isNull { return structured }
        guard let text = firstText(in: result) else {
            throw T3Error.invalidResponse("\(tool): no structuredContent or text content")
        }
        do { return try JSONValue.parse(Data(text.utf8)) }
        catch { throw T3Error.invalidResponse("\(tool): text content is not JSON") }
    }

    private static func firstText(in result: JSONValue) -> String? {
        result["content"]?.arrayValue?.first { $0["type"]?.stringValue == "text" }?["text"]?.stringValue
    }

    /// The `OrchestratorMcpFailure` payload of an `isError` result. Plain-text errors keep their
    /// text as the message with code `unknown`, since the refusal itself is definite.
    private static func failure(in result: JSONValue) -> (code: String, message: String) {
        var payload = result["structuredContent"]
        let text = firstText(in: result)
        if payload == nil || payload?.isNull == true, let text {
            payload = try? JSONValue.parse(Data(text.utf8))
        }
        let error = payload?["error"]?.objectValue.map(JSONValue.object) ?? payload
        let code = error?["code"]?.stringValue ?? "unknown"
        let message = error?["message"]?.stringValue ?? text ?? "T3 Code reported an error"
        return (code, message)
    }

    private static func map(code: String, message: String, context: ErrorContext) -> any Error {
        switch context {
        case .respond(let requestId):
            return T3Error.requestNotOpen(requestId)
        case .interrupt(let threadId):
            if code == T3InterruptResult.noActiveRun { return NoActiveRun.signal }
            if code == "thread_not_found" { return T3Error.threadNotFound(threadId) }
        case .thread(let threadId?):
            if code == "thread_not_found" { return T3Error.threadNotFound(threadId) }
        case .projectCreate:
            if message.localizedCaseInsensitiveContains("already registered") { return T3Error.projectAlreadyRegistered }
        case .thread(nil), .general:
            break
        }
        return T3Error.rejected(code: code, message: message)
    }
}

/// Tolerant `JSONValue` readers for tool results. Missing required fields → `.invalidResponse`.
enum T3Decode {
    static func object(_ value: JSONValue, _ context: String) throws -> [String: JSONValue] {
        guard let object = value.objectValue else { throw T3Error.invalidResponse("\(context): expected an object") }
        return object
    }

    /// The value under `key` when the result is `{key: {...}}`, else the result itself.
    static func unwrap(_ value: JSONValue, _ key: String) -> JSONValue {
        if let inner = value[key], inner.objectValue != nil { return inner }
        return value
    }

    /// A bare array, or the array under `key` (or `items`/`data`) of an object.
    static func array(_ value: JSONValue, key: String, _ context: String) throws -> [JSONValue] {
        if let array = value.arrayValue { return array }
        for candidate in [key, "items", "data"] {
            if let array = value[candidate]?.arrayValue { return array }
        }
        throw T3Error.invalidResponse("\(context): missing \(key)")
    }

    static func string(_ object: [String: JSONValue], _ keys: [String], _ context: String) throws -> String {
        for key in keys {
            if let value = object[key]?.stringValue { return value }
        }
        throw T3Error.invalidResponse("\(context): missing \(keys[0])")
    }

    static func run(_ value: JSONValue, position: Int) throws -> T3Run {
        let object = try object(value, "t3_thread_read run")
        return T3Run(
            runId: try string(object, ["runId", "id"], "t3_thread_read run"),
            ordinal: object["ordinal"]?.intValue ?? position,
            status: try string(object, ["status"], "t3_thread_read run"),
            requestedAt: object["requestedAt"]?.stringValue,
            startedAt: object["startedAt"]?.stringValue,
            completedAt: object["completedAt"]?.stringValue)
    }

    static func threadRow(_ value: JSONValue) throws -> T3ThreadRow {
        let object = try object(value, "t3_thread_list row")
        let model = object["model"]?.stringValue ?? object["modelSelection"]?["model"]?.stringValue
        let instance = object["providerInstanceId"]?.stringValue ?? object["modelSelection"]?["instanceId"]?.stringValue
        return T3ThreadRow(
            threadId: try string(object, ["threadId", "id"], "t3_thread_list row"),
            title: object["title"]?.stringValue ?? "",
            status: try string(object, ["status"], "t3_thread_list row"),
            latestRunId: object["latestRunId"]?.stringValue,
            createdAt: object["createdAt"]?.stringValue.flatMap(date),
            updatedAt: object["updatedAt"]?.stringValue,
            link: object["link"]?.stringValue,
            providerInstanceId: instance,
            model: model,
            settled: object["settled"]?.boolValue,
            pendingBackgroundTasks: backgroundTasks(object["pendingBackgroundTasks"]),
            blockedOnThreadWait: object["blockedOnThreadWait"]?.boolValue ?? false)
    }

    /// An array as-is; a count `n` as `n` placeholder entries; anything else as none.
    static func backgroundTasks(_ value: JSONValue?) -> [JSONValue] {
        if let array = value?.arrayValue { return array }
        if let count = value?.intValue, count > 0 { return Array(repeating: .null, count: count) }
        return []
    }

    static func date(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }

    static func project(_ value: JSONValue) throws -> T3Project {
        let object = try object(value, "t3 project")
        return T3Project(
            id: try string(object, ["id", "projectId"], "t3 project"),
            title: object["title"]?.stringValue ?? "",
            workspaceRoot: try string(object, ["workspaceRoot"], "t3 project"))
    }

    static func provider(_ value: JSONValue) throws -> T3ProviderInfo {
        let object = try object(value, "orchestrator_capabilities provider")
        let id = try string(object, ["providerInstanceId", "instanceId"], "orchestrator_capabilities provider")
        let models: [T3ModelInfo]
        do { models = try (object["models"]?.arrayValue ?? []).map { try $0.decode(T3ModelInfo.self) } }
        catch { throw T3Error.invalidResponse("orchestrator_capabilities models: \(error)") }
        let constraints = (object["constraints"]?.arrayValue ?? []).map(constraintText)
        return T3ProviderInfo(
            providerInstanceId: id,
            driverKind: object["driverKind"]?.stringValue ?? "",
            displayName: object["displayName"]?.stringValue ?? id,
            models: models,
            constraints: constraints)
    }

    private static func constraintText(_ value: JSONValue) -> String {
        if let text = value.stringValue { return text }
        if let text = value["message"]?.stringValue ?? value["reason"]?.stringValue { return text }
        return (try? value.data()).flatMap { String(data: $0, encoding: .utf8) } ?? "constraint"
    }
}
