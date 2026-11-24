import CryptoKit
import Foundation
import Testing
@testable import FocusQueueCore

// MARK: - Helpers shared with T3ConnectionStateMachineTests

/// Routes HTTP requests to per-host handlers so parallel tests do not collide.
final class T3ConnStubProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, Data) -> (status: Int, body: Data)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

    static func register(host: String, _ handler: @escaping Handler) { lock.withLock { handlers[host] = handler } }
    static func unregister(host: String) { _ = lock.withLock { handlers.removeValue(forKey: host) } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        guard let handler = Self.lock.withLock({ Self.handlers[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let (status, body) = handler(request, Self.body(of: request))
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["content-type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// A fake OAuth server on a unique host, recording each request.
final class T3ConnOAuthServer: @unchecked Sendable {
    let host = "t3-\(UUID().uuidString.lowercased()).test"
    var url: String { "https://\(host)" }
    private let lock = NSLock()
    private var _requests: [(path: String, request: URLRequest, body: Data)] = []
    private var _grantedScope = "orchestration:read orchestration:operate settings:write source-control:write"
    private var _tokenStatus = 200

    let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [T3ConnStubProtocol.self]
        return URLSession(configuration: configuration)
    }()

    init() {
        T3ConnStubProtocol.register(host: host) { [weak self] request, body in
            self?.handle(request, body) ?? (500, Data())
        }
    }
    deinit { T3ConnStubProtocol.unregister(host: host) }

    var grantedScope: String {
        get { lock.withLock { _grantedScope } }
        set { lock.withLock { _grantedScope = newValue } }
    }
    var requests: [(path: String, request: URLRequest, body: Data)] { lock.withLock { _requests } }
    func body(_ path: String) -> Data? { requests.last { $0.path == path }?.body }

    private func handle(_ request: URLRequest, _ body: Data) -> (Int, Data) {
        let path = request.url?.path ?? ""
        let scope = lock.withLock { () -> String in
            _requests.append((path, request, body))
            return _grantedScope
        }
        switch path {
        case "/oauth/mcp/register":
            return (201, Data(#"{"client_id":"CLIENT_1","token_endpoint_auth_method":"none"}"#.utf8))
        case "/oauth/mcp/token":
            let json: JSONValue = ["access_token": "TOKEN_1", "expires_in": 2_592_000, "scope": .string(scope),
                                   "token_type": "Bearer"]
            return (200, (try? json.data()) ?? Data())
        default:
            return (404, Data(#"{"error":"not_found"}"#.utf8))
        }
    }
}

/// A scripted MCP transport. It reads the token at call time, as the real transport does.
final class T3ConnFakeTransport: T3MCPTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private var tokenProvider: (@Sendable () async throws -> String)?
    private var _environmentId = "ENV_1"
    private var _eventsSupported = true
    private var _failure: T3Error?
    private var _sentTokens: [String] = []
    private var _methods: [String] = []
    private var _cancelAllCount = 0
    private var _baseURLs: [URL] = []
    private var streams: [AsyncThrowingStream<T3StreamMessage, any Error>.Continuation] = []
    private var _streamsEnded = 0

    func attach(_ url: URL, _ token: @escaping @Sendable () async throws -> String) -> T3ConnFakeTransport {
        lock.withLock { _baseURLs.append(url); tokenProvider = token }
        return self
    }

    var environmentId: String { get { lock.withLock { _environmentId } } set { lock.withLock { _environmentId = newValue } } }
    var eventsSupported: Bool { get { lock.withLock { _eventsSupported } } set { lock.withLock { _eventsSupported = newValue } } }
    var failure: T3Error? { get { lock.withLock { _failure } } set { lock.withLock { _failure = newValue } } }
    var sentTokens: [String] { lock.withLock { _sentTokens } }
    var methods: [String] { lock.withLock { _methods } }
    var cancelAllCount: Int { lock.withLock { _cancelAllCount } }
    var baseURLs: [URL] { lock.withLock { _baseURLs } }
    var streamsEnded: Int { lock.withLock { _streamsEnded } }
    func clearLog() { lock.withLock { _sentTokens.removeAll(); _methods.removeAll() } }

    static func discoverResult(events: Bool, version: String = "0.1.12-nightly.20261123.5124") -> JSONValue {
        var extensions: [String: JSONValue] = [:]
        if events { extensions["io.modelcontextprotocol/events"] = ["types": 12] }
        return ["capabilities": ["tools": [:], "extensions": .object(extensions)],
                "_meta": ["io.modelcontextprotocol/serverInfo": ["name": "t3-code", "version": .string(version)]]]
    }

    static func environmentResult(_ environmentId: String) -> JSONValue {
        let payload: JSONValue = ["environmentId": .string(environmentId), "label": "Test Mac",
                                  "serverVersion": "0.1.12-nightly.20261123.5124", "platform": "darwin",
                                  "preferences": ["defaultThreadEnvMode": "worktree"]]
        let text = String(decoding: (try? payload.data()) ?? Data(), as: UTF8.self)
        return ["content": [["type": "text", "text": .string(text)]], "structuredContent": payload, "isError": false]
    }

    func request(method: String, name: String?, params: [String: JSONValue]) async throws -> JSONValue {
        guard let provider = lock.withLock({ tokenProvider }) else { throw T3Error.unauthorized }
        let token = try await provider()
        let (failure, environmentId, events) = lock.withLock { () -> (T3Error?, String, Bool) in
            _sentTokens.append(token)
            _methods.append(name.map { "\(method):\($0)" } ?? method)
            return (_failure, _environmentId, _eventsSupported)
        }
        if let failure { throw failure }
        switch (method, name) {
        case ("server/discover", _): return Self.discoverResult(events: events)
        case ("tools/call", "t3_environment_read"): return Self.environmentResult(environmentId)
        default: throw T3Error.invalidResponse("unscripted \(method)")
        }
    }

    func stream(name: String, arguments: JSONValue, heartbeatMs: Int) async -> AsyncThrowingStream<T3StreamMessage, any Error> {
        let (stream, continuation) = AsyncThrowingStream<T3StreamMessage, any Error>.makeStream()
        continuation.onTermination = { [weak self] _ in self?.lock.withLock { self?._streamsEnded += 1 } }
        lock.withLock { streams.append(continuation) }
        continuation.yield(.active(cursor: "epoch.1", truncated: false, heartbeatMs: heartbeatMs))
        return stream
    }

    func cancelAll() async {
        let open = lock.withLock { () -> [AsyncThrowingStream<T3StreamMessage, any Error>.Continuation] in
            _cancelAllCount += 1
            defer { streams.removeAll() }
            return streams
        }
        for continuation in open { continuation.finish(throwing: CancellationError()) }
    }
}

/// Records the URL the connection asked to open.
final class T3ConnURLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _url: URL?
    var url: URL? { get { lock.withLock { _url } } set { lock.withLock { _url = newValue } } }
}

/// A connection wired to fakes, plus a temporary state file.
struct T3ConnHarness {
    let oauth = T3ConnOAuthServer()
    let transport = T3ConnFakeTransport()
    let credentials = InMemoryT3CredentialStore()
    let clock = ManualT3Clock()
    let stateStore: T3ConnectionStateStore
    let connection: T3Connection

    init(serverURL: String? = nil, stored: T3ConnectionState? = nil, credential: T3Credential? = nil,
         listener: (@Sendable () async throws -> any T3OAuthCallbackListening)? = nil) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("t3-conn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        stateStore = T3ConnectionStateStore(supportDirectory: directory)
        let server = serverURL ?? oauth.url
        if let stored { try stateStore.save(stored) }
        if let credential { try credentials.save(credential, server: server) }
        let transport = self.transport
        connection = T3Connection(serverURL: server, credentials: credentials, stateStore: stateStore,
                                  session: oauth.session, clock: clock,
                                  makeTransport: { url, token in transport.attach(url, token) },
                                  makeCallbackListener: listener ?? { try await T3LoopbackListener.start() })
    }

    var server: String { oauth.url }

    /// A stored Full access connection on `ENV_1` with a valid token.
    static func connectedState(server: String, environmentId: String = "ENV_1",
                               access: T3AccessLevel = .fullAccess) -> T3ConnectionState {
        T3ConnectionState(serverURL: server, environmentId: environmentId, clientId: "CLIENT_1",
                          redirectURI: "http://127.0.0.1:1/callback",
                          grantedScope: access == .fullAccess
                              ? "orchestration:read orchestration:operate settings:write source-control:write"
                              : "orchestration:read orchestration:operate",
                          accessLevel: access, tokenExpiresAt: Date(timeIntervalSince1970: 1_900_000_000))
    }

    static func stored(environmentId: String = "ENV_1", access: T3AccessLevel = .fullAccess) throws -> T3ConnHarness {
        let harness = try T3ConnHarness()
        try harness.stateStore.save(connectedState(server: harness.server, environmentId: environmentId, access: access))
        try harness.credentials.save(T3Credential(accessToken: "TOKEN_1", expiresAt: Date(timeIntervalSince1970: 1_900_000_000)),
                                     server: harness.server)
        return harness
    }

    /// An `openURL` that answers the loopback callback with a real local HTTP request.
    static func browser(box: T3ConnURLBox, code: String = "CODE_1", state override: String? = nil,
                        error: String? = nil) -> @Sendable (URL) async -> Void {
        { url in
            box.url = url
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard let redirect = items.first(where: { $0.name == "redirect_uri" })?.value,
                  var callback = URLComponents(string: redirect) else { return }
            let state = override ?? items.first { $0.name == "state" }?.value ?? ""
            callback.queryItems = error.map { [URLQueryItem(name: "error", value: $0), URLQueryItem(name: "state", value: state)] }
                ?? [URLQueryItem(name: "code", value: code), URLQueryItem(name: "state", value: state)]
            _ = try? await URLSession(configuration: .ephemeral).data(from: callback.url!)
        }
    }
}

func t3Query(_ url: URL?, _ name: String) -> String? {
    url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value }
}

func t3Form(_ data: Data?) -> [String: String] {
    var components = URLComponents()
    components.percentEncodedQuery = String(decoding: data ?? Data(), as: UTF8.self)
    return Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
}

/// A listener that never receives a callback.
final class T3ConnSilentListener: T3OAuthCallbackListening, @unchecked Sendable {
    let redirectURI = "http://127.0.0.1:9/callback"
    func waitForCallback() async throws -> T3OAuthCallback {
        try await Task.sleep(nanoseconds: 3_600 * 1_000_000_000)
        throw CancellationError()
    }
    func stop() {}
}

// MARK: - Task 5: OAuth sign-in, access level, discovery, identity

@Suite("T3 connection sign-in")
struct T3ConnectionTests {
    @Test("PKCE S256 matches the RFC 7636 example and verifiers are 64 URL-safe characters")
    func pkce() {
        #expect(T3PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
                == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let pkce = T3PKCE()
        #expect(pkce.verifier.count == 64)
        #expect(pkce.verifier.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        #expect(T3PKCE().verifier != pkce.verifier)
    }

    @Test("A stubbed sign-in registers, authorizes with S256, exchanges the code, and stores the token")
    func signInStoresToken() async throws {
        let harness = try T3ConnHarness()
        let box = T3ConnURLBox()
        let state = try await harness.connection.signIn(openURL: T3ConnHarness.browser(box: box))

        // Registration
        let register = try JSONValue.parse(#require(harness.oauth.body("/oauth/mcp/register")))
        #expect(register["client_name"] == "Focus Queue")
        #expect(register["grant_types"] == ["authorization_code"])
        #expect(register["response_types"] == ["code"])
        #expect(register["token_endpoint_auth_method"] == "none")
        let redirect = try #require(register["redirect_uris"]?.arrayValue?.first?.stringValue)
        #expect(redirect.hasPrefix("http://127.0.0.1:"))
        #expect(redirect.hasSuffix("/callback"))

        // Authorize URL
        let authorize = try #require(box.url)
        #expect(authorize.absoluteString.hasPrefix(harness.server + "/oauth/mcp/authorize?"))
        #expect(t3Query(authorize, "response_type") == "code")
        #expect(t3Query(authorize, "client_id") == "CLIENT_1")
        #expect(t3Query(authorize, "redirect_uri") == redirect)
        #expect(t3Query(authorize, "code_challenge_method") == "S256")
        #expect(t3Query(authorize, "scope") == "orchestration:read orchestration:operate settings:write")
        #expect(t3Query(authorize, "resource") == harness.server + "/mcp")
        #expect((t3Query(authorize, "state") ?? "").count >= 32)

        // Token exchange, and the challenge matches the verifier sent there
        let form = t3Form(harness.oauth.body("/oauth/mcp/token"))
        #expect(form["grant_type"] == "authorization_code")
        #expect(form["code"] == "CODE_1")
        #expect(form["redirect_uri"] == redirect)
        #expect(form["client_id"] == "CLIENT_1")
        #expect(form["resource"] == harness.server + "/mcp")
        let verifier = try #require(form["code_verifier"])
        #expect(verifier.count == 64)
        let digest = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        #expect(t3Query(authorize, "code_challenge") == digest)

        // Stored credential and state
        let expected = harness.clock.now().addingTimeInterval(2_592_000)
        #expect(try harness.credentials.load(server: harness.server) == T3Credential(accessToken: "TOKEN_1", expiresAt: expected))
        #expect(state.clientId == "CLIENT_1")
        #expect(state.redirectURI == redirect)
        #expect(state.accessLevel == .fullAccess)
        #expect(state.tokenExpiresAt == expected)
        #expect(state.environmentId == "ENV_1")
        #expect(state.environmentLabel == "Test Mac")
        #expect(state.serverVersion == "0.1.12-nightly.20261123.5124")
        #expect(try harness.stateStore.load() == state)
        #expect(await harness.connection.tokenExpiresAt == expected)
        #expect(await harness.connection.grantedScope == harness.oauth.grantedScope)

        // The transport now carries the new token.
        #expect(harness.transport.sentTokens.allSatisfy { $0 == "TOKEN_1" })
        #expect(harness.transport.methods == ["tools/call:t3_environment_read", "server/discover"])
    }

    @Test("Access level comes from the granted scope",
          arguments: [("orchestration:read orchestration:operate settings:write source-control:write", T3AccessLevel.fullAccess),
                      ("orchestration:read orchestration:operate", T3AccessLevel.belowFullAccess)])
    func accessLevel(scope: String, level: T3AccessLevel) async throws {
        let harness = try T3ConnHarness()
        harness.oauth.grantedScope = scope
        let state = try await harness.connection.signIn(openURL: T3ConnHarness.browser(box: T3ConnURLBox()))
        #expect(state.grantedScope == scope)
        #expect(state.accessLevel == level)
        #expect(await harness.connection.currentAccessLevel() == level)
    }

    @Test("A state mismatch throws and stores nothing")
    func stateMismatch() async throws {
        let harness = try T3ConnHarness()
        await #expect(throws: T3Error.invalidResponse("OAuth state mismatch")) {
            try await harness.connection.signIn(openURL: T3ConnHarness.browser(box: T3ConnURLBox(), state: "forged"))
        }
        #expect(harness.credentials.isEmpty)
        #expect(try harness.stateStore.load() == nil)
        #expect(harness.oauth.body("/oauth/mcp/token") == nil)
        #expect(await harness.connection.status == .disconnected)
    }

    @Test("An error callback is a cancelled sign-in and stores nothing")
    func errorCallback() async throws {
        let harness = try T3ConnHarness()
        await #expect(throws: T3Error.signInCancelled) {
            try await harness.connection.signIn(openURL: T3ConnHarness.browser(box: T3ConnURLBox(), error: "access_denied"))
        }
        #expect(harness.credentials.isEmpty)
        #expect(try harness.stateStore.load() == nil)
        #expect(await harness.connection.status == .disconnected)
    }

    @Test("No callback within 600 s times out and stores nothing")
    func timeout() async throws {
        let harness = try T3ConnHarness(listener: { T3ConnSilentListener() })
        let connection = harness.connection
        let task = Task { try await connection.signIn(openURL: { _ in }) }
        #expect(await eventually { harness.clock.pendingSleepers == 1 })
        #expect(harness.clock.sleepRequests == [600])
        await harness.clock.advance(by: 599)
        #expect(await connection.status == .signingIn)
        await harness.clock.advance(by: 1)
        await #expect(throws: T3Error.signInTimedOut) { try await task.value }
        #expect(harness.credentials.isEmpty)
        #expect(await connection.status == .disconnected)
    }

    @Test("Plain http is refused for hosts other than loopback")
    func insecureURL() async throws {
        #expect(T3Connection.isAllowed("http://127.0.0.1:3773"))
        #expect(T3Connection.isAllowed("http://localhost:3773"))
        #expect(T3Connection.isAllowed("https://t3.example.com"))
        #expect(!T3Connection.isAllowed("http://t3.example.com"))
        let harness = try T3ConnHarness(serverURL: "http://t3.example.com")
        await #expect(throws: T3Error.self) { try await harness.connection.signIn(openURL: { _ in }) }
        #expect(harness.oauth.requests.isEmpty)
    }

    @Test("discover() reads the events extension and the server version")
    func discover() async throws {
        let harness = try T3ConnHarness()
        try harness.credentials.save(T3Credential(accessToken: "TOKEN_1", expiresAt: nil), server: harness.server)
        _ = await harness.connection.connect()

        let info = try await harness.connection.discover()
        #expect(info == T3ServerInfo(version: "0.1.12-nightly.20261123.5124", eventsSupported: true))
        harness.transport.eventsSupported = false
        #expect(try await harness.connection.discover().eventsSupported == false)

        let stable: JSONValue = ["capabilities": ["tools": [:]], "serverInfo": ["name": "t3", "version": "0.1.11"]]
        #expect(T3Connection.serverInfo(from: stable) == T3ServerInfo(version: "0.1.11", eventsSupported: false))
    }

    @Test("identity() decodes t3_environment_read from structured or text content")
    func identity() async throws {
        let harness = try T3ConnHarness()
        try harness.credentials.save(T3Credential(accessToken: "TOKEN_1", expiresAt: nil), server: harness.server)
        _ = await harness.connection.connect()
        #expect(try await harness.connection.identity()
                == T3Environment(environmentId: "ENV_1", label: "Test Mac", serverVersion: "0.1.12-nightly.20261123.5124"))

        let textOnly: JSONValue = ["content": [["type": "text", "text": #"{"environmentId":"ENV_2","label":"Other"}"#]]]
        #expect(try T3Connection.environment(from: textOnly) == T3Environment(environmentId: "ENV_2", label: "Other"))

        let failure: JSONValue = ["isError": true, "structuredContent":
            ["_tag": "OrchestratorMcpFailure", "code": "forbidden", "message": "Nope"]]
        #expect(throws: T3Error.rejected(code: "forbidden", message: "Nope")) { try T3Connection.environment(from: failure) }
        #expect(throws: T3Error.self) { try T3Connection.environment(from: ["structuredContent": ["label": "x"]]) }
    }

    @Test("The loopback listener ignores other paths and answers /callback with a page")
    func loopbackListener() async throws {
        let listener = try await T3LoopbackListener.start()
        defer { listener.stop() }
        #expect(listener.port > 0)
        #expect(listener.redirectURI == "http://127.0.0.1:\(listener.port)/callback")
        let session = URLSession(configuration: .ephemeral)

        let (_, missing) = try await session.data(from: URL(string: "http://127.0.0.1:\(listener.port)/favicon.ico")!)
        #expect((missing as? HTTPURLResponse)?.statusCode == 404)

        let (body, found) = try await session.data(from: URL(string: listener.redirectURI + "?code=C%2B1&state=S")!)
        #expect((found as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: body, as: UTF8.self).contains("<html"))
        #expect(try await listener.waitForCallback() == T3OAuthCallback(code: "C+1", state: "S"))
    }

    @Test("Waiting for the callback stops when the task is cancelled")
    func listenerCancellation() async throws {
        let listener = try await T3LoopbackListener.start()
        defer { listener.stop() }
        let task = Task { try await listener.waitForCallback() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
