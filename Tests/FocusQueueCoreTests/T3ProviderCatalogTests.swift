import Foundation
import Testing
@testable import FocusQueueCore

/// Decodes `orchestrator_capabilities` fixture providers.
private func fixtureProviders() throws -> [T3ProviderInfo] {
    let root = try T3Fixtures.json("capabilities-sample.json")
    return try (root["providers"]?.arrayValue ?? []).map { item in
        guard let id = item["providerInstanceId"]?.stringValue, let driver = item["driverKind"]?.stringValue else {
            throw T3Error.invalidResponse("provider")
        }
        let models = try item["models"].map { try $0.decode([T3ModelInfo].self) } ?? []
        let constraints = (item["constraints"]?.arrayValue ?? []).compactMap(\.stringValue)
        return T3ProviderInfo(providerInstanceId: id, driverKind: driver,
                              displayName: item["displayName"]?.stringValue ?? id,
                              models: models, constraints: constraints)
    }
}

private func makeCatalog(clock: ManualT3Clock = ManualT3Clock()) async throws -> (T3ProviderCatalog, FakeT3Tools) {
    let providers = try fixtureProviders()
    let tools = FakeT3Tools()
    await tools.set { $0.onProviders = { providers } }
    return (T3ProviderCatalog(tools: tools, clock: clock), tools)
}

private func providerCalls(_ tools: FakeT3Tools) async -> Int {
    await tools.callCount { $0 == .providers }
}

@Suite("T3 provider catalog")
struct T3ProviderCatalogTests {
    @Test("Disabled providers are excluded")
    func excludesDisabled() async throws {
        let (catalog, _) = try await makeCatalog()
        let ids = try await catalog.available().map(\.providerInstanceId)
        #expect(ids == ["INSTANCE_CLAUDE", "INSTANCE_CODEX", "INSTANCE_CURSOR"])
    }

    @Test("Default selections follow the driver kind; Kimi has none")
    func defaults() async throws {
        let (catalog, _) = try await makeCatalog()
        let claude = try await catalog.defaultSelection(for: .claude)
        #expect(claude == T3ModelChoice(instanceId: "INSTANCE_CLAUDE", model: "claude-fable-5-2"))
        let codex = try await catalog.defaultSelection(for: .codex)
        #expect(codex == T3ModelChoice(instanceId: "INSTANCE_CODEX", model: "gpt-6.2"))
        #expect(try await catalog.defaultSelection(for: .kimi) == nil)
    }

    @Test("No available instance of the driver gives no default")
    func noInstance() async throws {
        let tools = FakeT3Tools()
        await tools.set { $0.onProviders = { [
            T3ProviderInfo(providerInstanceId: "c", driverKind: "claudeAgent", displayName: "C",
                           models: [T3ModelInfo(id: "m", label: "M")], constraints: ["Provider instance is disabled."]),
        ] } }
        let catalog = T3ProviderCatalog(tools: tools, clock: ManualT3Clock())
        #expect(try await catalog.defaultSelection(for: .claude) == nil)
        #expect(try await catalog.defaultSelection(for: .codex) == nil)
    }

    @Test("Model selection returns the exact object")
    func selectionWithOptions() async throws {
        let (catalog, _) = try await makeCatalog()
        let selection = try await catalog.modelSelection(instanceId: "INSTANCE_CLAUDE", model: "claude-haiku-5-5",
                                                         options: ["effort": "high"])
        #expect(selection == ["instanceId": "INSTANCE_CLAUDE", "model": "claude-haiku-5-5",
                              "options": ["effort": "high"]])
        let plain = try await catalog.modelSelection(instanceId: "INSTANCE_CODEX", model: "kimi-k3")
        #expect(plain == ["instanceId": "INSTANCE_CODEX", "model": "kimi-k3"])
    }

    @Test("An option with no listed values accepts any value")
    func freeOption() async throws {
        let (catalog, _) = try await makeCatalog()
        let selection = try await catalog.modelSelection(instanceId: "INSTANCE_CODEX", model: "gpt-6.2",
                                                         options: ["fastMode": true])
        #expect(selection["options"] == ["fastMode": true])
    }

    @Test("Unknown model, disabled or unknown instance, and bad options are rejected")
    func rejections() async throws {
        let (catalog, _) = try await makeCatalog()
        let cases: [(String, String, [String: JSONValue], String)] = [
            ("INSTANCE_CLAUDE", "claude-nope", [:], "claude-nope is not available in T3 Code"),
            ("INSTANCE_GROK", "grok-5", [:], "INSTANCE_GROK is not available in T3 Code"),
            ("INSTANCE_CLAUDE_DISABLED", "claude-haiku-5-5", [:], "INSTANCE_CLAUDE_DISABLED is not available in T3 Code"),
            ("MISSING", "claude-haiku-5-5", [:], "MISSING is not available in T3 Code"),
            ("INSTANCE_CLAUDE", "claude-haiku-5-5", ["effort": "max"],
             "Option effort=max for claude-haiku-5-5 is not available in T3 Code"),
            ("INSTANCE_CLAUDE", "claude-haiku-5-5", ["speed": "fast"],
             "Option speed for claude-haiku-5-5 is not available in T3 Code"),
        ]
        for (instance, model, options, message) in cases {
            await #expect(throws: T3Error.rejected(code: "model_unavailable", message: message)) {
                _ = try await catalog.modelSelection(instanceId: instance, model: model, options: options)
            }
        }
    }

    @Test("The catalog is cached for 10 minutes and refresh forces a reload")
    func caching() async throws {
        let clock = ManualT3Clock()
        let (catalog, tools) = try await makeCatalog(clock: clock)
        _ = try await catalog.available()
        _ = try await catalog.defaultSelection(for: .claude)
        await clock.advance(by: 599)
        _ = try await catalog.available()
        #expect(await providerCalls(tools) == 1)
        await clock.advance(by: 1)
        _ = try await catalog.available()
        #expect(await providerCalls(tools) == 2)
        try await catalog.refresh()
        #expect(await providerCalls(tools) == 3)
        _ = try await catalog.available()
        #expect(await providerCalls(tools) == 3)
    }

    @Test("A failed load is not cached")
    func failureNotCached() async throws {
        let tools = FakeT3Tools()
        await tools.set { $0.onProviders = { throw T3Error.notRunning } }
        let catalog = T3ProviderCatalog(tools: tools, clock: ManualT3Clock())
        await #expect(throws: T3Error.notRunning) { _ = try await catalog.available() }
        let providers = try fixtureProviders()
        await tools.set { $0.onProviders = { providers } }
        #expect(try await catalog.available().count == 3)
    }
}
