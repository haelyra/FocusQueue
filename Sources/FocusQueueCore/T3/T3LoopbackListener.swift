import Foundation
import Network

/// The query of an OAuth redirect to `/callback`.
public struct T3OAuthCallback: Equatable, Sendable {
    public var code: String?
    public var state: String?
    public var error: String?
    public var errorDescription: String?

    public init(code: String? = nil, state: String? = nil, error: String? = nil, errorDescription: String? = nil) {
        self.code = code; self.state = state; self.error = error; self.errorDescription = errorDescription
    }

    public init(queryItems: [URLQueryItem]) {
        func value(_ name: String) -> String? { queryItems.first { $0.name == name }?.value }
        self.init(code: value("code"), state: value("state"), error: value("error"),
                  errorDescription: value("error_description"))
    }
}

/// Receives the OAuth redirect. `T3LoopbackListener` is the live one.
public protocol T3OAuthCallbackListening: Sendable {
    var redirectURI: String { get }
    /// Waits for the first `/callback` request. Throws `CancellationError` when the task is cancelled.
    func waitForCallback() async throws -> T3OAuthCallback
    func stop()
}

/// A one-shot HTTP listener on `127.0.0.1`, ephemeral port. Answers `/callback` with a small page
/// and every other path with 404.
public final class T3LoopbackListener: T3OAuthCallbackListening, @unchecked Sendable {
    /// Set once by `start()` before the listener is returned.
    public private(set) var port: UInt16 = 0
    public var redirectURI: String { "http://127.0.0.1:\(port)/callback" }

    private let listener: NWListener
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var result: T3OAuthCallback?
    private var waiter: CheckedContinuation<T3OAuthCallback, any Error>?

    private init(listener: NWListener, queue: DispatchQueue) {
        self.listener = listener; self.queue = queue
    }

    deinit { listener.cancel() }

    public static func start() async throws -> T3LoopbackListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "com.focusqueue.t3.loopback")
        let instance = T3LoopbackListener(listener: listener, queue: queue)
        listener.newConnectionHandler = { [weak instance] connection in
            guard let instance else { connection.cancel(); return }
            instance.handle(connection)
        }
        instance.port = try await ready(listener, queue: queue)
        return instance
    }

    private static func ready(_ listener: NWListener, queue: DispatchQueue) async throws -> UInt16 {
        let once = OnceFlag()
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard once.claim() else { return }
                    if let port = listener.port?.rawValue { continuation.resume(returning: port) }
                    else { continuation.resume(throwing: T3Error.invalidResponse("loopback listener has no port")) }
                case .failed(let error):
                    guard once.claim() else { return }
                    continuation.resume(throwing: error)
                case .cancelled:
                    guard once.claim() else { return }
                    continuation.resume(throwing: CancellationError())
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func waitForCallback() async throws -> T3OAuthCallback {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T3OAuthCallback, any Error>) in
                let ready: T3OAuthCallback?? = lock.withLock {
                    if let result { return .some(result) }
                    if Task.isCancelled { return .some(nil) }
                    waiter = continuation
                    return nil
                }
                switch ready {
                case .some(.some(let callback)): continuation.resume(returning: callback)
                case .some(.none): continuation.resume(throwing: CancellationError())
                case .none: break
                }
            }
        } onCancel: {
            let pending = lock.withLock { () -> CheckedContinuation<T3OAuthCallback, any Error>? in
                defer { waiter = nil }
                return waiter
            }
            pending?.resume(throwing: CancellationError())
        }
    }

    public func stop() { listener.cancel() }

    private func deliver(_ callback: T3OAuthCallback) {
        let pending = lock.withLock { () -> CheckedContinuation<T3OAuthCallback, any Error>? in
            guard result == nil else { return nil }
            result = callback
            defer { waiter = nil }
            return waiter
        }
        pending?.resume(returning: callback)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8))
            if headerEnd == nil, !isComplete, error == nil, buffer.count < 65_536 {
                self.receive(connection, buffer: buffer)
                return
            }
            self.respond(connection, request: buffer)
        }
    }

    private func respond(_ connection: NWConnection, request: Data) {
        let line = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
        let parts = line.split(separator: " ")
        var status = "404 Not Found"
        var body = Self.page(title: "Not found", message: "Focus Queue is waiting for the T3 Code sign-in.")
        if parts.count >= 2, parts[0] == "GET",
           let components = URLComponents(string: "http://127.0.0.1" + parts[1]), components.path == "/callback" {
            let callback = T3OAuthCallback(queryItems: components.queryItems ?? [])
            status = "200 OK"
            body = callback.error == nil
                ? Self.page(title: "Connected", message: "Focus Queue received the T3 Code sign-in. You can close this tab.")
                : Self.page(title: "Not connected", message: "The T3 Code sign-in was not completed. You can close this tab.")
            deliver(callback)
        }
        let bodyData = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(bodyData.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + bodyData, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func page(title: String, message: String) -> String {
        "<!doctype html><html><head><meta charset=\"utf-8\"><title>Focus Queue: \(title)</title>"
            + "<style>body{font:15px -apple-system,sans-serif;margin:3em;color:#222}"
            + "@media(prefers-color-scheme:dark){body{background:#1e1e1e;color:#ddd}}</style></head>"
            + "<body><h1>\(title)</h1><p>\(message)</p></body></html>"
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool { lock.withLock { defer { claimed = true }; return !claimed } }
}
