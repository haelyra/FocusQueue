import Foundation
import Testing
@testable import FocusQueueCore

enum T3Fixtures {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/T3")
    static func data(_ name: String) throws -> Data { try Data(contentsOf: directory.appendingPathComponent(name)) }
    static func json(_ name: String) throws -> JSONValue { try JSONValue.parse(data(name)) }
}

private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(T.self, from: encoder.encode(value))
}

@Suite("T3 models")
struct T3ModelsTests {
    @Test("Pre-change task context decodes with no T3 fields")
    func preChangeTaskContext() throws {
        let context = try JSONDecoder().decode(TaskContext.self, from: T3Fixtures.data("pre-t3-task-context.json"))
        #expect(context.subtasks.count == 1)
        #expect(context.subtasks[0].t3 == nil)
        #expect(context.subtasks[0].t3Launch == nil)
        #expect(context.subtasks[0].runtimeMode == .tmux)
    }

    @Test("Pre-change app configuration decodes with no runtime choice")
    func preChangeConfiguration() throws {
        let config = try JSONDecoder().decode(AppConfiguration.self, from: T3Fixtures.data("pre-t3-app-configuration.json"))
        #expect(config.agentRuntime == nil)
        #expect(config.t3ServerURL == nil)
    }

    @Test("Every T3 cleanup state round-trips")
    func cleanupStates() throws {
        for state in [T3CleanupState.pending(reason: "T3 Code unreachable"), .retained(message: "dirty"), .removed] {
            #expect(try roundTrip(state) == state)
        }
    }

    @Test("Thread references, intents, and connection state round-trip")
    func roundTrips() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let reference = T3ThreadReference(
            environmentId: "ENV_1", threadId: "THREAD_1", projectId: "PROJECT_1", link: "t3://thread/1",
            providerInstanceId: "claude", model: "claude-haiku-5-5", observedStatus: "running",
            activeRunId: "RUN_2", latestTerminalRunId: "RUN_1", latestTerminalOutcome: "completed",
            acknowledgedTerminalRunId: "RUN_1", openQuestionIds: ["Q1"], pendingApprovalCount: 1,
            reachability: .threadMissing, cleanup: .pending(reason: "x"), archivedAt: date, lastSnapshotAt: date)
        #expect(try roundTrip(reference) == reference)
        let intent = T3LaunchIntent(requestId: "REQ", environmentId: "ENV_1", projectId: "PROJECT_1",
            worktreePath: "/REPO/.worktrees/a", title: "Agent", createdAt: date, phase: .unknown, lastError: "timeout",
            message: "Do it", providerInstanceId: "claude", model: "m", modelOptions: ["effort": "high"])
        #expect(try roundTrip(intent) == intent)
        let state = T3ConnectionState(serverURL: T3Defaults.serverURL, environmentId: "ENV_1", environmentLabel: "Mac",
            serverVersion: "0.1.12", clientId: "C", redirectURI: "http://127.0.0.1:1/callback",
            grantedScope: "orchestration:read", accessLevel: .fullAccess, tokenExpiresAt: date,
            projectMaps: ["ENV_1": ["fq": "t3"]], lastConnectedAt: date)
        #expect(try roundTrip(state) == state)
        var subtask = TaskSubtask(title: "A", runtimeMode: .t3)
        subtask.t3 = reference; subtask.t3Launch = intent
        #expect(try roundTrip(subtask) == subtask)
        #expect(subtask.hasAgent)
        for choice in AgentRuntimeChoice.allCases { #expect(try roundTrip(choice) == choice) }
        var config = AppConfiguration.eccDefault()
        config.agentRuntime = .t3; config.t3ServerURL = "http://localhost:3773"
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(config))
        #expect(decoded.agentRuntime == .t3 && decoded.t3ServerURL == "http://localhost:3773")
    }

    @Test("Access level follows settings:write in the granted scope")
    func accessLevel() {
        #expect(T3AccessLevel.from(grantedScope: "orchestration:read orchestration:operate settings:write source-control:write") == .fullAccess)
        #expect(T3AccessLevel.from(grantedScope: "orchestration:read orchestration:operate") == .belowFullAccess)
    }

    @Test("Connection state store saves, loads, and reports a missing file")
    func stateStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("t3-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = T3ConnectionStateStore(supportDirectory: dir)
        #expect(try store.load() == nil)
        let state = T3ConnectionState(serverURL: T3Defaults.serverURL, environmentId: "E", clientId: "C",
            grantedScope: "s", accessLevel: .fullAccess, tokenExpiresAt: Date(timeIntervalSince1970: 1_800_000_000))
        try store.save(state)
        #expect(try store.load() == state)
        let updated = try store.update(serverURL: T3Defaults.serverURL) { $0.projectMaps["E"] = ["p": "q"] }
        #expect(try store.load() == updated)
    }

    @Test("JSON values keep numbers, booleans, and nesting")
    func jsonValue() throws {
        let value = try JSONValue.parse(Data(#"{"a":1,"b":true,"c":[null,"x",2.5],"d":{"e":0}}"#.utf8))
        #expect(value["a"] == .number(1))
        #expect(value["b"] == .bool(true))
        #expect(value["c"] == [nil, "x", 2.5])
        #expect(value["d"]?["e"]?.intValue == 0)
        #expect(try JSONValue.parse(value.data()) == value)
    }
}
