import Foundation

/// A provider instance and model picked for a T3 launch.
public struct T3ModelChoice: Equatable, Sendable {
    public var instanceId: String
    public var model: String
    public var options: [String: JSONValue]
    public init(instanceId: String, model: String, options: [String: JSONValue] = [:]) {
        self.instanceId = instanceId; self.model = model; self.options = options
    }
}

/// The providers T3 Code offers (`orchestrator_capabilities`), cached for a short time.
public actor T3ProviderCatalog {
    private let tools: any T3ToolCalling
    private let clock: any T3Clock
    private let ttlSeconds: Double
    private var cached: (providers: [T3ProviderInfo], fetchedAt: Date)?
    private var inFlight: Task<[T3ProviderInfo], any Error>?

    public init(tools: any T3ToolCalling, clock: any T3Clock = SystemT3Clock(), ttlSeconds: Double = 600) {
        self.tools = tools
        self.clock = clock
        self.ttlSeconds = ttlSeconds
    }

    /// Provider instances without constraints. Cached for `ttlSeconds`.
    public func available() async throws -> [T3ProviderInfo] {
        if let cached, clock.now().timeIntervalSince(cached.fetchedAt) < ttlSeconds {
            return cached.providers
        }
        return try await load()
    }

    /// Reloads the catalog, ignoring the cache.
    @discardableResult
    public func refresh() async throws -> [T3ProviderInfo] {
        cached = nil
        return try await load()
    }

    /// The first available instance of the T3 driver for `provider`, with its first model.
    /// `nil` for Kimi (T3 Code has no Kimi driver) or when no matching instance is available.
    public func defaultSelection(for provider: AgentProvider) async throws -> T3ModelChoice? {
        guard let driverKind = Self.driverKind(for: provider) else { return nil }
        for instance in try await available() where instance.driverKind == driverKind {
            if let model = instance.models.first {
                return T3ModelChoice(instanceId: instance.providerInstanceId, model: model.id)
            }
        }
        return nil
    }

    /// Validates the choice and returns the `modelSelection` object for `t3_thread_launch`.
    public func modelSelection(instanceId: String, model: String,
                               options: [String: JSONValue] = [:]) async throws -> [String: JSONValue] {
        let providers = try await available()
        guard let instance = providers.first(where: { $0.providerInstanceId == instanceId }) else {
            throw Self.unavailable(instanceId)
        }
        guard let info = instance.models.first(where: { $0.id == model }) else {
            throw Self.unavailable(model)
        }
        for (key, value) in options {
            guard let option = info.options.first(where: { $0.id == key }) else {
                throw Self.unavailable("Option \(key) for \(model)")
            }
            if !option.values.isEmpty, !option.values.contains(value) {
                throw Self.unavailable("Option \(key)=\(Self.describe(value)) for \(model)")
            }
        }
        var selection: [String: JSONValue] = ["instanceId": .string(instanceId), "model": .string(model)]
        if !options.isEmpty { selection["options"] = .object(options) }
        return selection
    }

    /// The T3 `driverKind` that runs `provider`, or nil when T3 Code has none.
    public static func driverKind(for provider: AgentProvider) -> String? {
        switch provider {
        case .claude: "claudeAgent"
        case .codex: "codex"
        case .kimi: nil
        }
    }

    private func load() async throws -> [T3ProviderInfo] {
        if let inFlight { return try await inFlight.value }
        let tools = self.tools
        let task = Task { try await tools.providers().filter(\.available) }
        inFlight = task
        defer { inFlight = nil }
        let providers = try await task.value
        cached = (providers, clock.now())
        return providers
    }

    private static func unavailable(_ subject: String) -> T3Error {
        .rejected(code: "model_unavailable", message: "\(subject) is not available in T3 Code")
    }

    private static func describe(_ value: JSONValue) -> String {
        if let string = value.stringValue { return string }
        return (try? value.data()).flatMap { String(data: $0, encoding: .utf8) } ?? "value"
    }
}
