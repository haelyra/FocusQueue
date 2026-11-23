import Foundation
import Testing
@testable import FocusQueueCore

/// A transport whose streams the test drives. Each `stream` call opens a new connection.
private actor ScriptedTransport: T3MCPTransporting {
    private(set) var opened: [String] = []
    private var continuations: [String: [AsyncThrowingStream<T3StreamMessage, any Error>.Continuation]] = [:]

    func request(method: String, name: String?, params: [String: JSONValue]) async throws -> JSONValue { .null }
    func stream(name: String, arguments: JSONValue, heartbeatMs: Int) async -> AsyncThrowingStream<T3StreamMessage, any Error> {
        opened.append(name)
        let (stream, continuation) = AsyncThrowingStream<T3StreamMessage, any Error>.makeStream()
        continuations[name, default: []].append(continuation)
        return stream
    }
    func cancelAll() async {}

    func openCount(_ name: String) -> Int { opened.filter { $0 == name }.count }
    func send(_ name: String, _ message: T3StreamMessage) { continuations[name]?.last?.yield(message) }
    func fail(_ name: String, _ error: any Error) { continuations[name]?.last?.finish(throwing: error) }
    func activateAll(epoch: String = "EPOCH") {
        for name in T3EventName.watched { send(name, .active(cursor: "\(epoch).0", truncated: false, heartbeatMs: 15_000)) }
    }
}

private actor TargetLog: T3RefreshTarget {
    private(set) var dirty: [String] = []
    private(set) var resyncs = 0
    func markDirty(_ threadId: String) async { dirty.append(threadId) }
    func resyncAll() async { resyncs += 1 }
}

private struct WatcherHarness {
    let transport = ScriptedTransport()
    let tools = FakeT3Tools()
    let target = TargetLog()
    let store = FakeT3Store([T3SubtaskRecord(location: T3SubtaskLocation(ticketID: "FOC-1", subtaskID: "SUB_1"),
                                             subtask: T3Samples.t3Subtask())])
    let connection = FakeT3Connection()
    let clock = ManualT3Clock()
    let watcher: T3Watcher
    init() {
        watcher = T3Watcher(transport: transport, tools: tools, target: target, store: store,
                            connection: connection, clock: clock)
    }

    func event(_ thread: String, cursor: String = "EPOCH.1") -> T3StreamMessage {
        .event(T3EventOccurrence(eventId: UUID().uuidString, name: T3EventName.needsInput, timestamp: nil,
                                 cursor: cursor, data: ["threadId": .string(thread)]))
    }

    func started() async {
        await tools.set { $0.onList = { _ in [] } }
        await watcher.start(environmentId: T3Samples.env, projectIds: ["PROJECT_1"])
        _ = await eventually { await transport.opened.count == 3 }
    }
}

@Suite("T3 watcher")
struct T3WatcherTests {
    @Test("Resync waits for all three streams, and an early event is not lost")
    func resyncAfterActive() async {
        let h = WatcherHarness()
        await h.started()
        await h.transport.send(T3EventName.runSettled, .active(cursor: "EPOCH.0", truncated: false, heartbeatMs: 15_000))
        await h.transport.send(T3EventName.runSettled, h.event("THREAD_1"))
        await h.transport.send(T3EventName.needsInput, .active(cursor: "EPOCH.0", truncated: false, heartbeatMs: 15_000))
        #expect(await eventually { await h.target.dirty == ["THREAD_1"] })
        #expect(await h.target.resyncs == 0)
        await h.transport.send(T3EventName.inputResolved, .active(cursor: "EPOCH.0", truncated: false, heartbeatMs: 15_000))
        #expect(await eventually { await h.target.resyncs == 1 })
        await h.watcher.stop()
    }

    @Test("A list-poll change with no event marks the thread dirty within one interval")
    func listPoll() async {
        let h = WatcherHarness()
        let rows = RowBox([T3ThreadRow(threadId: "THREAD_1", title: "t", status: "idle", latestRunId: "RUN_1"),
                           T3ThreadRow(threadId: "THREAD_OTHER", title: "t", status: "idle", latestRunId: "RUN_1")])
        await h.tools.set { $0.onList = { _ in await rows.value } }
        await h.watcher.start(environmentId: T3Samples.env, projectIds: ["PROJECT_1"])
        #expect(await eventually { await h.tools.callCount { $0 == .list("PROJECT_1") } == 1 })
        await rows.set([T3ThreadRow(threadId: "THREAD_1", title: "t", status: "running", latestRunId: "RUN_2"),
                        T3ThreadRow(threadId: "THREAD_OTHER", title: "t", status: "running", latestRunId: "RUN_2")])
        #expect(await eventually { h.clock.pendingSleepers >= 2 })
        await h.clock.advance(by: 5)
        #expect(await eventually { await h.target.dirty == ["THREAD_1"] })
        await h.watcher.stop()
    }

    @Test("Silence, a truncated buffer, and a new epoch each reconnect and resync")
    func reconnects() async {
        let h = WatcherHarness()
        await h.started()
        await h.transport.activateAll()
        #expect(await eventually { await h.target.resyncs == 1 })

        // 30 s of silence on one stream.
        for _ in 0..<4 {
            await h.transport.send(T3EventName.runSettled, .heartbeat(cursor: "EPOCH.0"))
            await h.transport.send(T3EventName.needsInput, .heartbeat(cursor: "EPOCH.0"))
            await h.clock.advance(by: 10)
        }
        // Poll, watchdog, and the reconnect backoff are all asleep.
        #expect(await eventually { await h.transport.openCount(T3EventName.inputResolved) == 1 && h.clock.pendingSleepers >= 3 })
        await h.clock.advance(by: 1) // backoff
        #expect(await eventually { await h.transport.openCount(T3EventName.inputResolved) == 2 })
        await h.transport.send(T3EventName.inputResolved, .active(cursor: "EPOCH.5", truncated: true, heartbeatMs: 15_000))
        #expect(await eventually { await h.target.resyncs == 2 })

        // An event from a new epoch.
        await h.transport.send(T3EventName.runSettled, h.event("THREAD_1", cursor: "NEWEPOCH.1"))
        #expect(await eventually { h.clock.pendingSleepers >= 3 })
        await h.clock.advance(by: 1)
        #expect(await eventually { await h.transport.openCount(T3EventName.runSettled) == 2 })
        await h.transport.send(T3EventName.runSettled, .active(cursor: "NEWEPOCH.1", truncated: false, heartbeatMs: 15_000))
        #expect(await eventually { await h.target.resyncs == 3 })
        #expect(await h.target.dirty.isEmpty)
        await h.watcher.stop()
    }

    @Test("Unauthorized stops streams and polling, with no further calls")
    func unauthorized() async {
        let h = WatcherHarness()
        await h.started()
        await h.transport.fail(T3EventName.needsInput, T3Error.unauthorized)
        #expect(await eventually { await h.connection.reported == [.unauthorized] })
        #expect(await h.watcher.isRunning == false)
        let lists = await h.tools.callCount { if case .list = $0 { true } else { false } }
        await h.clock.advance(by: 60)
        #expect(await h.tools.callCount { if case .list = $0 { true } else { false } } == lists)
        #expect(await h.transport.opened.count == 3)
    }
}

private actor RowBox {
    var value: [T3ThreadRow]
    init(_ value: [T3ThreadRow]) { self.value = value }
    func set(_ value: [T3ThreadRow]) { self.value = value }
}
