import Foundation
import Testing
@testable import FocusQueueCore

/// Collects every status a `transitions()` subscriber sees.
final class T3ConnStatusLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [T3ConnectionStatus] = []
    private var task: Task<Void, Never>?
    var values: [T3ConnectionStatus] { lock.withLock { _values } }

    static func watch(_ connection: T3Connection) async -> T3ConnStatusLog {
        let log = T3ConnStatusLog()
        let stream = await connection.transitions()
        log.task = Task { for await value in stream { log.lock.withLock { log._values.append(value) } } }
        _ = await eventually { !log.values.isEmpty }
        return log
    }

    deinit { task?.cancel() }
}

private let version = "0.1.12-nightly.20261123.5124"
private let connectedEnv1 = T3ConnectionStatus.connected(environmentId: "ENV_1", version: version)

/// Connects a harness that has a stored Full access state and token.
private func connectedHarness() async throws -> T3ConnHarness {
    let harness = try T3ConnHarness.stored()
    #expect(await harness.connection.connect() == connectedEnv1)
    harness.transport.clearLog()
    return harness
}

/// Steps the probe loop through the given delays, checking each requested sleep.
private func expectBackoff(_ harness: T3ConnHarness, _ delays: [Double], from start: Int = 0) async {
    for (offset, delay) in delays.enumerated() {
        let count = start + offset + 1
        #expect(await eventually { harness.clock.sleepRequests.count == count && harness.clock.pendingSleepers == 1 })
        #expect(harness.clock.sleepRequests.last == delay)
        await harness.clock.advance(by: delay)
    }
}

@Suite("T3 connection state machine")
struct T3ConnectionStateMachineTests {
    // MARK: signingIn

    @Test("signingIn + Full access + events → connected")
    func signInConnected() async throws {
        let harness = try T3ConnHarness()
        let log = await T3ConnStatusLog.watch(harness.connection)
        try await harness.connection.signIn(openURL: T3ConnHarness.browser(box: T3ConnURLBox()))
        #expect(await harness.connection.status == connectedEnv1)
        #expect(await eventually { log.values == [.disconnected, .signingIn, connectedEnv1] })
    }

    @Test("signingIn + below Full access → accessTooLow")
    func signInAccessTooLow() async throws {
        let harness = try T3ConnHarness()
        harness.oauth.grantedScope = "orchestration:read orchestration:operate"
        try await harness.connection.signIn(openURL: T3ConnHarness.browser(box: T3ConnURLBox()))
        #expect(await harness.connection.status == .accessTooLow)
    }

    @Test("signingIn + denial → disconnected")
    func signInDenied() async throws {
        let harness = try T3ConnHarness()
        let log = await T3ConnStatusLog.watch(harness.connection)
        _ = try? await harness.connection.signIn(openURL: T3ConnHarness.browser(box: T3ConnURLBox(), error: "access_denied"))
        #expect(await eventually { log.values == [.disconnected, .signingIn, .disconnected] })
        #expect(harness.credentials.isEmpty)
    }

    @Test("signingIn + no events extension → serverTooOld")
    func signInServerTooOld() async throws {
        let harness = try T3ConnHarness()
        harness.transport.eventsSupported = false
        try await harness.connection.signIn(openURL: T3ConnHarness.browser(box: T3ConnURLBox()))
        #expect(await harness.connection.status == .serverTooOld(version))
    }

    @Test("signingIn against a server whose environmentId differs from the stored one → otherServer")
    func signInOtherServer() async throws {
        let harness = try T3ConnHarness()
        try harness.stateStore.save(T3ConnectionState(serverURL: harness.server, environmentId: "ENV_OLD"))
        try await harness.connection.signIn(openURL: T3ConnHarness.browser(box: T3ConnURLBox()))
        #expect(await harness.connection.status == .otherServer(expected: "ENV_OLD", actual: "ENV_1"))
        #expect(try harness.stateStore.load()?.environmentId == "ENV_OLD")
    }

    // MARK: connect() at app start

    @Test("connect() without a stored credential stays disconnected and sends nothing")
    func connectWithoutCredential() async throws {
        let harness = try T3ConnHarness()
        #expect(await harness.connection.connect() == .disconnected)
        #expect(harness.transport.methods.isEmpty)
    }

    @Test("connect() resumes from the stored credential")
    func connectResumes() async throws {
        let harness = try T3ConnHarness.stored()
        #expect(await harness.connection.connect() == connectedEnv1)
        #expect(harness.transport.sentTokens == ["TOKEN_1", "TOKEN_1"])
        #expect(try harness.stateStore.load()?.lastConnectedAt == harness.clock.now())
    }

    @Test("connect() with an expired token → unauthorized without a request")
    func connectExpired() async throws {
        let harness = try T3ConnHarness.stored()
        try harness.credentials.save(T3Credential(accessToken: "OLD", expiresAt: harness.clock.now()), server: harness.server)
        #expect(await harness.connection.connect() == .unauthorized)
        #expect(harness.transport.methods.isEmpty)
    }

    @Test("connect() with a stored below-Full-access state → accessTooLow")
    func connectAccessTooLow() async throws {
        let harness = try T3ConnHarness.stored(access: .belowFullAccess)
        #expect(await harness.connection.connect() == .accessTooLow)
    }

    @Test("connect() without the events extension → serverTooOld")
    func connectServerTooOld() async throws {
        let harness = try T3ConnHarness.stored()
        harness.transport.eventsSupported = false
        #expect(await harness.connection.connect() == .serverTooOld(version))
    }

    @Test("connect() to another environmentId → otherServer, and the stored id is kept")
    func connectOtherServer() async throws {
        let harness = try T3ConnHarness.stored()
        harness.transport.environmentId = "ENV_2"
        #expect(await harness.connection.connect() == .otherServer(expected: "ENV_1", actual: "ENV_2"))
        #expect(try harness.stateStore.load()?.environmentId == "ENV_1")
    }

    @Test("connect() to a stopped server → unreachable, then probes")
    func connectUnreachable() async throws {
        let harness = try T3ConnHarness.stored()
        harness.transport.failure = .notRunning
        #expect(await harness.connection.connect() == .unreachable)
        await expectBackoff(harness, [1, 2])
        harness.transport.failure = nil
        await expectBackoff(harness, [4], from: 2)
        #expect(await eventually { await harness.connection.status == connectedEnv1 })
    }

    // MARK: connected → unreachable → probe

    @Test("connected + notRunning → unreachable, probing at 1, 2, 4, 8, 16, 30, 30 s until the same server returns")
    func backoff() async throws {
        let harness = try await connectedHarness()
        let log = await T3ConnStatusLog.watch(harness.connection)
        harness.transport.failure = .notRunning
        await harness.connection.report(.notRunning)
        #expect(await harness.connection.status == .unreachable)

        await expectBackoff(harness, [1, 2, 4, 8, 16, 30, 30])
        #expect(await harness.connection.status == .unreachable)
        #expect(Array(harness.clock.sleepRequests.prefix(7)) == [1, 2, 4, 8, 16, 30, 30])

        harness.transport.failure = nil
        await expectBackoff(harness, [30], from: 7)
        #expect(await eventually { await harness.connection.status == connectedEnv1 })
        #expect(await eventually { log.values == [connectedEnv1, .unreachable, connectedEnv1] })
        await harness.clock.settle()
        #expect(harness.clock.pendingSleepers == 0)
    }

    @Test("connected + outcomeUnknown → unreachable")
    func outcomeUnknown() async throws {
        let harness = try await connectedHarness()
        harness.transport.failure = .notRunning
        await harness.connection.report(.outcomeUnknown("timeout"))
        #expect(await harness.connection.status == .unreachable)
        #expect(await eventually { harness.clock.sleepRequests == [1] })
    }

    @Test("A connectivity report while not connected changes nothing")
    func reportWhileDisconnected() async throws {
        let harness = try T3ConnHarness()
        await harness.connection.report(.notRunning)
        #expect(await harness.connection.status == .disconnected)
        #expect(harness.clock.sleepRequests.isEmpty)
    }

    @Test("A probe that finds another environmentId → otherServer, never connected")
    func probeOtherServer() async throws {
        let harness = try await connectedHarness()
        let log = await T3ConnStatusLog.watch(harness.connection)
        harness.transport.failure = .notRunning
        await harness.connection.report(.notRunning)
        await expectBackoff(harness, [1])
        harness.transport.failure = nil
        harness.transport.environmentId = "ENV_2"
        await expectBackoff(harness, [2], from: 1)
        let other = T3ConnectionStatus.otherServer(expected: "ENV_1", actual: "ENV_2")
        #expect(await eventually { await harness.connection.status == other })
        #expect(await eventually { log.values == [connectedEnv1, .unreachable, other] })
        await harness.clock.settle()
        #expect(harness.clock.pendingSleepers == 0)
    }

    @Test("connected + serverTooOld report → serverTooOld")
    func reportServerTooOld() async throws {
        let harness = try await connectedHarness()
        await harness.connection.report(.serverTooOld("0.1.11"))
        #expect(await harness.connection.status == .serverTooOld("0.1.11"))
    }

    // MARK: unauthorized

    @Test("connected + unauthorized → unauthorized: cancelAll, token dropped, no retries")
    func unauthorized() async throws {
        let harness = try await connectedHarness()
        await harness.connection.report(.unauthorized)
        #expect(await harness.connection.status == .unauthorized)
        #expect(harness.transport.cancelAllCount == 1)
        await #expect(throws: T3Error.unauthorized) {
            _ = try await harness.connection.currentTransport().request(method: "server/discover", name: nil, params: [:])
        }
        #expect(harness.transport.sentTokens.isEmpty)
        await harness.clock.advance(by: 120)
        #expect(harness.clock.sleepRequests.isEmpty)
    }

    @Test("unauthorized while probing stops the probe")
    func unauthorizedWhileUnreachable() async throws {
        let harness = try await connectedHarness()
        harness.transport.failure = .notRunning
        await harness.connection.report(.notRunning)
        #expect(await eventually { harness.clock.pendingSleepers == 1 })
        await harness.connection.report(.unauthorized)
        #expect(await harness.connection.status == .unauthorized)
        harness.transport.failure = nil
        await harness.clock.advance(by: 120)
        #expect(harness.clock.sleepRequests == [1])
        #expect(harness.transport.sentTokens.isEmpty)
        #expect(await harness.connection.status == .unauthorized)
    }

    @Test("A probe answered with 401 → unauthorized")
    func probeUnauthorized() async throws {
        let harness = try await connectedHarness()
        harness.transport.failure = .notRunning
        await harness.connection.report(.notRunning)
        harness.transport.failure = .unauthorized
        await expectBackoff(harness, [1])
        #expect(await eventually { await harness.connection.status == .unauthorized })
        await harness.clock.advance(by: 120)
        #expect(harness.clock.sleepRequests == [1])
    }

    // MARK: sign-out and server change

    @Test("signOut() cancels an open stream, deletes the credential, and no later request carries the old token")
    func signOut() async throws {
        let harness = try await connectedHarness()
        let transport = harness.connection.currentTransport()
        let stream = await transport.stream(name: T3EventName.runSettled, arguments: [:], heartbeatMs: 15_000)
        let consumer = Task { () -> (Int, Bool) in
            var count = 0
            do { for try await _ in stream { count += 1 } } catch is CancellationError { return (count, true) } catch {}
            return (count, false)
        }

        try await harness.connection.signOut()

        #expect(await harness.connection.status == .disconnected)
        let (received, cancelled) = await consumer.value
        #expect(received == 1)
        #expect(cancelled)
        #expect(harness.transport.cancelAllCount == 1)
        #expect(try harness.credentials.load(server: harness.server) == nil)
        let state = try #require(try harness.stateStore.load())
        #expect(state.clientId.isEmpty)
        #expect(state.tokenExpiresAt == nil)
        #expect(state.environmentId == "ENV_1")
        #expect(await harness.connection.currentAccessLevel() == nil)

        await #expect(throws: T3Error.unauthorized) {
            _ = try await transport.request(method: "tools/call", name: "t3_environment_read", params: [:])
        }
        #expect(harness.transport.sentTokens.isEmpty)
    }

    @Test("signOut() while unreachable stops probing")
    func signOutWhileProbing() async throws {
        let harness = try await connectedHarness()
        harness.transport.failure = .notRunning
        await harness.connection.report(.notRunning)
        #expect(await eventually { harness.clock.pendingSleepers == 1 })
        try await harness.connection.signOut()
        await harness.clock.advance(by: 120)
        #expect(harness.clock.sleepRequests == [1])
        #expect(await harness.connection.status == .disconnected)
    }

    @Test("Changing the server URL → disconnected, as sign-out, on a transport for the new URL")
    func serverURLChange() async throws {
        let harness = try await connectedHarness()
        try await harness.connection.setServerURL(harness.server + "/")
        #expect(await harness.connection.status == connectedEnv1)

        try await harness.connection.setServerURL("http://LOCALHOST:4000/")
        #expect(await harness.connection.status == .disconnected)
        #expect(await harness.connection.serverURL == "http://localhost:4000")
        #expect(harness.transport.cancelAllCount == 1)
        #expect(try harness.credentials.load(server: harness.server) == nil)
        #expect(harness.transport.baseURLs.last == URL(string: "http://localhost:4000"))
        let state = try #require(try harness.stateStore.load())
        #expect(state.serverURL == "http://localhost:4000")
        #expect(state.clientId.isEmpty)
        #expect(state.environmentId == "ENV_1")
        await #expect(throws: T3Error.unauthorized) {
            _ = try await harness.connection.currentTransport().request(method: "server/discover", name: nil, params: [:])
        }
    }

    // MARK: observation

    @Test("Every transitions() subscriber gets the current status first, then each change")
    func multipleSubscribers() async throws {
        let harness = try T3ConnHarness.stored()
        let first = await T3ConnStatusLog.watch(harness.connection)
        _ = await harness.connection.connect()
        let second = await T3ConnStatusLog.watch(harness.connection)
        await harness.connection.report(.unauthorized)
        #expect(await eventually { first.values == [.disconnected, connectedEnv1, .unauthorized] })
        #expect(await eventually { second.values == [connectedEnv1, .unauthorized] })
    }
}
