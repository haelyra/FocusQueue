import CryptoKit
import Foundation

/// Builds the MCP transport for a base URL and a token provider. The app passes
/// `{ T3McpTransport(baseURL: $0, token: $1, session: session, ...) }`; tests pass fakes.
public typealias T3TransportFactory = @Sendable (URL, @escaping @Sendable () async throws -> String) -> any T3MCPTransporting

/// OAuth sign-in, Keychain credential, discovery, identity, and the connection state machine
/// in `.spec/plan.md` ("Connection state machine").
public actor T3Connection: T3ConnectionProviding {
    public static let requestedScope = "orchestration:read orchestration:operate settings:write"
    public static let signInTimeout: Double = 600
    /// Probe delays after the connection drops; the last one repeats.
    public static let backoff: [Double] = [1, 2, 4, 8, 16, 30]

    public private(set) var serverURL: String
    public private(set) var status: T3ConnectionStatus = .disconnected

    private let credentials: any T3CredentialStoring
    private let stateStore: T3ConnectionStateStore
    private let session: URLSession
    private let clock: any T3Clock
    private let makeTransport: T3TransportFactory
    private let makeCallbackListener: @Sendable () async throws -> any T3OAuthCallbackListening
    private let token = T3TokenBox()
    private let transport: T3ConnectionTransport
    private var subscribers: [UUID: AsyncStream<T3ConnectionStatus>.Continuation] = [:]
    private var probeTask: Task<Void, Never>?
    /// Bumped by sign-out, server change, unauthorized, and a new sign-in, so stale async work drops its result.
    private var epoch = 0

    public init(serverURL: String, credentials: any T3CredentialStoring, stateStore: T3ConnectionStateStore,
                session: URLSession = .shared, clock: any T3Clock = SystemT3Clock(),
                makeTransport: @escaping T3TransportFactory,
                makeCallbackListener: @escaping @Sendable () async throws -> any T3OAuthCallbackListening = {
                    try await T3LoopbackListener.start()
                }) {
        let normalized = T3CredentialAccount.normalized(serverURL)
        self.serverURL = normalized
        self.credentials = credentials; self.stateStore = stateStore; self.session = session
        self.clock = clock; self.makeTransport = makeTransport; self.makeCallbackListener = makeCallbackListener
        let box = token
        let provider: @Sendable () async throws -> String = { try box.require() }
        self.transport = T3ConnectionTransport(makeTransport(Self.baseURL(normalized), provider))
    }

    deinit { probeTask?.cancel() }

    // MARK: Observation

    public func currentStatus() async -> T3ConnectionStatus { status }

    /// The current status first, then every change. Each call is an independent subscriber.
    public func transitions() -> AsyncStream<T3ConnectionStatus> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<T3ConnectionStatus>.makeStream(bufferingPolicy: .unbounded)
        continuation.yield(status)
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    private func removeSubscriber(_ id: UUID) { subscribers[id] = nil }

    /// The transport every T3 call should use. It stays the same object across server changes,
    /// and fails with `.unauthorized` whenever no token is held.
    public nonisolated func currentTransport() -> any T3MCPTransporting { transport }

    public func currentState() -> T3ConnectionState? { try? stateStore.load() }
    public var grantedScope: String? { currentState()?.grantedScope }
    public var tokenExpiresAt: Date? { currentState()?.tokenExpiresAt }

    public func readableEnvironmentId() async -> String? {
        switch status {
        case .connected(let environmentId, _): return environmentId
        case .accessTooLow: return currentState()?.environmentId.flatMap { $0.isEmpty ? nil : $0 }
        default: return nil
        }
    }

    public func currentAccessLevel() async -> T3AccessLevel? {
        guard let state = currentState(), !state.clientId.isEmpty else { return nil }
        return state.accessLevel
    }

    // MARK: Sign-in (Task 5)

    /// OAuth 2.1 authorization code + PKCE S256 with a loopback redirect. Throws before anything is
    /// stored on cancel, denial, state mismatch, or timeout. After the token is saved it returns the
    /// state, and `status` tells whether the connection is usable.
    @discardableResult
    public func signIn(openURL: @escaping @Sendable (URL) async -> Void) async throws -> T3ConnectionState {
        if status == .signingIn { throw T3Error.rejected(code: "sign_in_in_progress", message: "A T3 Code sign-in is already open") }
        try Self.checkAllowed(serverURL)
        epoch += 1
        let myEpoch = epoch
        stopProbing()
        setStatus(.signingIn)
        do {
            let state = try await performSignIn(openURL: openURL, epoch: myEpoch)
            return state
        } catch {
            if epoch == myEpoch, status == .signingIn { setStatus(.disconnected) }
            throw error
        }
    }

    private func performSignIn(openURL: @escaping @Sendable (URL) async -> Void, epoch myEpoch: Int) async throws -> T3ConnectionState {
        let server = serverURL
        let listener = try await makeCallbackListener()
        defer { listener.stop() }
        let redirectURI = listener.redirectURI
        let clientId = try await register(server: server, redirectURI: redirectURI)
        let pkce = T3PKCE()
        let state = T3PKCE.randomURLSafe(bytes: 32)
        let authorize = try Self.authorizeURL(server: server, clientId: clientId, redirectURI: redirectURI,
                                              challenge: pkce.challenge, state: state)
        await openURL(authorize)
        let callback = try await waitForCallback(listener)
        try checkEpoch(myEpoch)
        if callback.error != nil { throw T3Error.signInCancelled }
        guard callback.state == state else { throw T3Error.invalidResponse("OAuth state mismatch") }
        guard let code = callback.code, !code.isEmpty else { throw T3Error.invalidResponse("OAuth callback has no code") }
        let grant = try await exchange(server: server, code: code, redirectURI: redirectURI,
                                       clientId: clientId, verifier: pkce.verifier)
        try checkEpoch(myEpoch)

        let expiresAt = grant.expiresIn.map { clock.now().addingTimeInterval($0) }
        try credentials.save(T3Credential(accessToken: grant.accessToken, expiresAt: expiresAt), server: server)
        token.set(grant.accessToken)
        let saved = try stateStore.update(serverURL: server) { value in
            value.serverURL = server
            value.clientId = clientId
            value.redirectURI = redirectURI
            value.grantedScope = grant.scope
            value.accessLevel = T3AccessLevel.from(grantedScope: grant.scope)
            value.tokenExpiresAt = expiresAt
        }
        let next = await evaluate(epoch: myEpoch)
        guard epoch == myEpoch else { return currentState() ?? saved }
        apply(next)
        return currentState() ?? saved
    }

    private func waitForCallback(_ listener: any T3OAuthCallbackListening) async throws -> T3OAuthCallback {
        let clock = self.clock
        return try await withThrowingTaskGroup(of: T3OAuthCallback.self) { group in
            group.addTask { try await listener.waitForCallback() }
            group.addTask {
                try await clock.sleep(seconds: T3Connection.signInTimeout)
                throw T3Error.signInTimedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw T3Error.signInCancelled }
            return first
        }
    }

    private func checkEpoch(_ expected: Int) throws {
        if epoch != expected { throw T3Error.signInCancelled }
    }

    private func register(server: String, redirectURI: String) async throws -> String {
        let body: JSONValue = [
            "client_name": "Focus Queue",
            "redirect_uris": [.string(redirectURI)],
            "grant_types": ["authorization_code"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        ]
        var request = URLRequest(url: try Self.url(server, "/oauth/mcp/register"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.httpBody = try body.data()
        let response = try await send(request)
        guard let clientId = response["client_id"]?.stringValue, !clientId.isEmpty else {
            throw T3Error.invalidResponse("client registration returned no client_id")
        }
        return clientId
    }

    private struct Grant { var accessToken: String; var expiresIn: Double?; var scope: String }

    private func exchange(server: String, code: String, redirectURI: String, clientId: String,
                          verifier: String) async throws -> Grant {
        let fields = [("grant_type", "authorization_code"), ("code", code), ("redirect_uri", redirectURI),
                      ("client_id", clientId), ("code_verifier", verifier), ("resource", server + "/mcp")]
        var request = URLRequest(url: try Self.url(server, "/oauth/mcp/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.httpBody = Data(fields.map { "\(Self.formEncode($0.0))=\(Self.formEncode($0.1))" }
            .joined(separator: "&").utf8)
        let response = try await send(request)
        guard let accessToken = response["access_token"]?.stringValue, !accessToken.isEmpty else {
            throw T3Error.invalidResponse("token response has no access_token")
        }
        return Grant(accessToken: accessToken, expiresIn: response["expires_in"]?.doubleValue,
                     scope: response["scope"]?.stringValue ?? "")
    }

    private func send(_ request: URLRequest) async throws -> JSONValue {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet:
                throw T3Error.notRunning
            case .cancelled: throw CancellationError()
            default: throw T3Error.outcomeUnknown(error.localizedDescription)
            }
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONValue.parse(data)
        guard (200..<300).contains(code) else {
            let error = json?["error"]?.stringValue ?? "http_\(code)"
            let message = json?["error_description"]?.stringValue ?? "T3 Code sign-in failed (HTTP \(code))"
            throw T3Error.rejected(code: error, message: message)
        }
        guard let json else { throw T3Error.invalidResponse("sign-in response is not JSON") }
        return json
    }

    // MARK: Discovery and identity

    /// `server/discover`: the events extension and the server version.
    public func discover() async throws -> T3ServerInfo {
        let result = try await transport.request(method: "server/discover", name: nil, params: [:])
        return Self.serverInfo(from: result)
    }

    /// `t3_environment_read {}`.
    public func identity() async throws -> T3Environment {
        let result = try await transport.request(method: "tools/call", name: "t3_environment_read",
                                                 params: ["name": "t3_environment_read", "arguments": [:]])
        return try Self.environment(from: result)
    }

    static func serverInfo(from result: JSONValue) -> T3ServerInfo {
        let events = result["capabilities"]?["extensions"]?["io.modelcontextprotocol/events"]
        let version = result["_meta"]?["io.modelcontextprotocol/serverInfo"]?["version"]?.stringValue
            ?? result["serverInfo"]?["version"]?.stringValue
        return T3ServerInfo(version: version, eventsSupported: events != nil && events?.isNull == false)
    }

    static func environment(from result: JSONValue) throws -> T3Environment {
        let payload = try toolPayload(result)
        guard let environmentId = payload["environmentId"]?.stringValue, !environmentId.isEmpty else {
            throw T3Error.invalidResponse("t3_environment_read returned no environmentId")
        }
        return T3Environment(environmentId: environmentId, label: payload["label"]?.stringValue,
                             serverVersion: payload["serverVersion"]?.stringValue)
    }

    /// A `tools/call` result's payload: `structuredContent`, else the first text content as JSON.
    static func toolPayload(_ result: JSONValue) throws -> JSONValue {
        let text = result["content"]?.arrayValue?.first { $0["type"]?.stringValue == "text" }?["text"]?.stringValue
        let payload = result["structuredContent"].flatMap { $0.isNull ? nil : $0 }
            ?? text.flatMap { try? JSONValue.parse(Data($0.utf8)) }
        if result["isError"]?.boolValue == true {
            let code = payload?["code"]?.stringValue ?? "tool_error"
            throw T3Error.rejected(code: code, message: payload?["message"]?.stringValue ?? text ?? code)
        }
        guard let payload else { throw T3Error.invalidResponse("tool result has no content") }
        return payload
    }

    // MARK: State machine (Task 6)

    /// Resumes from a stored credential at app start. Without one the status stays `disconnected`.
    @discardableResult
    public func connect() async -> T3ConnectionStatus {
        switch status {
        case .connected, .signingIn: return status
        default: break
        }
        guard Self.isAllowed(serverURL),
              let credential = try? credentials.load(server: serverURL) else {
            setStatus(.disconnected)
            return status
        }
        epoch += 1
        let myEpoch = epoch
        stopProbing()
        if credential.isExpired(at: clock.now()) {
            token.set(nil)
            setStatus(.unauthorized)
            return status
        }
        token.set(credential.accessToken)
        let next = await evaluate(epoch: myEpoch)
        if epoch == myEpoch { apply(next) }
        return status
    }

    public func report(_ error: T3Error) async {
        switch error {
        case .notRunning, .outcomeUnknown:
            guard case .connected = status else { return }
            setStatus(.unreachable)
            startProbing()
        case .unauthorized:
            switch status {
            case .disconnected, .signingIn, .unauthorized: return
            default: await enterUnauthorized()
            }
        case .serverTooOld(let version):
            guard case .connected = status else { return }
            setStatus(.serverTooOld(version))
        default:
            return
        }
    }

    /// Makes the server now answering at `serverURL` Focus Queue's T3 Code server, after
    /// `otherServer`. Agents started on the previous server stay listed as on another server.
    @discardableResult
    public func useCurrentServer() async throws -> T3ConnectionStatus {
        guard case .otherServer(_, let actual) = status else { return status }
        epoch += 1
        let myEpoch = epoch
        stopProbing()
        let server = serverURL
        try stateStore.update(serverURL: server) { $0.environmentId = actual }
        let next = await evaluate(epoch: myEpoch)
        if epoch == myEpoch { apply(next) }
        return status
    }

    /// Cancels every request and stream, deletes the credential, and clears the token.
    public func signOut() async throws {
        try await disconnect(server: serverURL)
    }

    /// As sign-out for the old server; a later `connect()` or `signIn` checks the `environmentId`.
    public func setServerURL(_ newURL: String) async throws {
        let normalized = T3CredentialAccount.normalized(newURL)
        guard normalized != serverURL else { return }
        var failure: (any Error)?
        do { try await disconnect(server: serverURL) } catch { failure = error }
        serverURL = normalized
        transport.replace(makeTransport(Self.baseURL(normalized), { [token] in try token.require() }))
        if currentState() != nil {
            try stateStore.update(serverURL: normalized) { $0.serverURL = normalized }
        }
        if let failure { throw failure }
    }

    private func disconnect(server: String) async throws {
        epoch += 1
        stopProbing()
        token.set(nil)
        setStatus(.disconnected)
        await transport.cancelAll()
        try credentials.delete(server: server)
        if currentState() != nil {
            try stateStore.update(serverURL: server) { value in
                value.clientId = ""
                value.tokenExpiresAt = nil
            }
        }
    }

    private func enterUnauthorized() async {
        epoch += 1
        stopProbing()
        token.set(nil)
        setStatus(.unauthorized)
        await transport.cancelAll()
    }

    /// Reads identity and discovery and decides the status. Saves the environment facts when the
    /// server is the expected one (or the first one).
    private func evaluate(epoch myEpoch: Int) async -> T3ConnectionStatus {
        do {
            let environment = try await identity()
            let info = try await discover()
            guard epoch == myEpoch else { return status }
            let stored = currentState()
            if let expected = stored?.environmentId, !expected.isEmpty, expected != environment.environmentId {
                return .otherServer(expected: expected, actual: environment.environmentId)
            }
            let version = info.version ?? environment.serverVersion
            let now = clock.now()
            let server = serverURL
            try stateStore.update(serverURL: server) { value in
                value.serverURL = server
                value.environmentId = environment.environmentId
                value.environmentLabel = environment.label
                value.serverVersion = version
                value.lastConnectedAt = now
            }
            if stored?.accessLevel != .fullAccess { return .accessTooLow }
            if !info.eventsSupported { return .serverTooOld(version) }
            return .connected(environmentId: environment.environmentId, version: version ?? "unknown")
        } catch T3Error.unauthorized {
            if epoch == myEpoch { await enterUnauthorized() }
            return .unauthorized
        } catch T3Error.serverTooOld(let version) {
            return .serverTooOld(version)
        } catch {
            return .unreachable
        }
    }

    private func apply(_ next: T3ConnectionStatus) {
        setStatus(next)
        if next == .unreachable { startProbing() }
    }

    private func setStatus(_ next: T3ConnectionStatus) {
        guard next != status else { return }
        status = next
        for continuation in subscribers.values { continuation.yield(next) }
    }

    private func startProbing() {
        probeTask?.cancel()
        let myEpoch = epoch
        probeTask = Task { [weak self] in await self?.probe(epoch: myEpoch) }
    }

    private func stopProbing() {
        probeTask?.cancel()
        probeTask = nil
    }

    private func probe(epoch myEpoch: Int) async {
        var attempt = 0
        while !Task.isCancelled {
            let delay = Self.backoff[min(attempt, Self.backoff.count - 1)]
            attempt += 1
            do { try await clock.sleep(seconds: delay) } catch { return }
            guard epoch == myEpoch, !Task.isCancelled else { return }
            let next = await evaluate(epoch: myEpoch)
            guard epoch == myEpoch, !Task.isCancelled else { return }
            if next == .unreachable { continue }
            probeTask = nil
            setStatus(next)
            return
        }
    }

    // MARK: URLs

    static func baseURL(_ server: String) -> URL {
        URL(string: server) ?? URL(string: T3Defaults.serverURL)!
    }

    private static func url(_ server: String, _ path: String) throws -> URL {
        guard let url = URL(string: server + path) else { throw T3Error.invalidResponse("bad server URL \(server)") }
        return url
    }

    static func authorizeURL(server: String, clientId: String, redirectURI: String, challenge: String,
                             state: String) throws -> URL {
        guard var components = URLComponents(string: server + "/oauth/mcp/authorize") else {
            throw T3Error.invalidResponse("bad server URL \(server)")
        }
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "scope", value: requestedScope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "resource", value: server + "/mcp"),
        ]
        // URLComponents leaves `+` alone, which form decoders read as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw T3Error.invalidResponse("bad authorize URL") }
        return url
    }

    /// Plain `http` only to `127.0.0.1`/`localhost`; everything else must be `https`.
    public static func isAllowed(_ server: String) -> Bool {
        guard let components = URLComponents(string: server), let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty else { return false }
        if scheme == "https" { return true }
        return scheme == "http" && ["127.0.0.1", "localhost", "[::1]", "::1"].contains(host)
    }

    private static func checkAllowed(_ server: String) throws {
        guard isAllowed(server) else {
            throw T3Error.rejected(code: "insecure_server_url",
                                   message: "T3 Code server URLs must use https unless they are 127.0.0.1 or localhost")
        }
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

/// PKCE S256: a 64-character verifier from 48 random bytes, challenge = base64url(SHA-256(verifier)).
public struct T3PKCE: Sendable {
    public let verifier: String
    public var challenge: String { Self.challenge(for: verifier) }

    public init(verifier: String = T3PKCE.randomURLSafe(bytes: 48)) { self.verifier = verifier }

    public static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    public static func randomURLSafe(bytes count: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URL(Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// The in-memory bearer token, read by the transport at request time.
final class T3TokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func set(_ token: String?) { lock.withLock { value = token } }
    func require() throws -> String {
        guard let token = lock.withLock({ value }) else { throw T3Error.unauthorized }
        return token
    }
}

/// A stable transport whose underlying `T3MCPTransporting` is replaced when the server URL changes.
final class T3ConnectionTransport: T3MCPTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private var inner: any T3MCPTransporting

    init(_ inner: any T3MCPTransporting) { self.inner = inner }

    func replace(_ next: any T3MCPTransporting) { lock.withLock { inner = next } }
    private var current: any T3MCPTransporting { lock.withLock { inner } }

    func request(method: String, name: String?, params: [String: JSONValue]) async throws -> JSONValue {
        try await current.request(method: method, name: name, params: params)
    }

    func stream(name: String, arguments: JSONValue, heartbeatMs: Int) async -> AsyncThrowingStream<T3StreamMessage, any Error> {
        await current.stream(name: name, arguments: arguments, heartbeatMs: heartbeatMs)
    }

    func cancelAll() async { await current.cancelAll() }
}
