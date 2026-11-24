import Foundation

/// Provider, model, and option selection for a T3 launch, offered from what T3
/// Code reports as enabled. The agent's Focus Queue provider only preselects
/// the matching T3 provider kind; Kimi has no T3 driver, so it starts empty.
public struct T3LaunchPickerModel: Equatable, Sendable {
    public private(set) var providers: [T3ProviderInfo]
    public private(set) var instanceId: String?
    public private(set) var model: String?
    public private(set) var options: [String: JSONValue]

    public init(providers: [T3ProviderInfo], agentProvider: AgentProvider, preferredModel: String? = nil) {
        self.providers = providers.filter(\.available)
        instanceId = nil; model = nil; options = [:]
        if let kind = T3ProviderCatalog.driverKind(for: agentProvider),
           let instance = self.providers.first(where: { $0.driverKind == kind }) {
            selectProvider(instance.providerInstanceId)
            if let preferredModel, instance.models.contains(where: { $0.id == preferredModel }) {
                selectModel(preferredModel)
            }
        }
    }

    public var selectedProvider: T3ProviderInfo? { providers.first { $0.providerInstanceId == instanceId } }
    public var models: [T3ModelInfo] { selectedProvider?.models ?? [] }
    public var selectedModel: T3ModelInfo? { models.first { $0.id == model } }

    /// Launch stays disabled until a provider and model are chosen.
    public var isValid: Bool { selectedModel != nil }

    public var choice: T3LaunchChoice? {
        guard let instanceId, let model, isValid else { return nil }
        return T3LaunchChoice(instanceId: instanceId, model: model, options: options)
    }

    /// Picks a provider and its first model.
    public mutating func selectProvider(_ id: String) {
        guard let provider = providers.first(where: { $0.providerInstanceId == id }) else { return }
        instanceId = id
        if let first = provider.models.first { selectModel(first.id) } else { model = nil; options = [:] }
    }

    /// Picks a model and resets its options to their defaults.
    public mutating func selectModel(_ id: String) {
        guard let info = models.first(where: { $0.id == id }) else { return }
        model = id
        options = Dictionary(uniqueKeysWithValues: info.options.compactMap { option in
            option.default.map { (option.id, $0) }
        })
    }

    public mutating func setOption(_ id: String, _ value: JSONValue) {
        guard let option = selectedModel?.options.first(where: { $0.id == id }),
              option.values.isEmpty || option.values.contains(value) else { return }
        options[id] = value
    }
}
