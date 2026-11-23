import Foundation
import Testing
@testable import FocusQueueCore

@Suite("Core agent settings: QChat provider, auto-clear, data placement")
struct CoreAgentSettingsTests {
    private func starter() -> AppConfiguration {
        SetupEnvironment.starter(
            supportDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    @Test("QChat provider, auto-clear, and extractor choices survive a round-trip")
    func roundTrip() throws {
        var configuration = starter()
        #expect(configuration.chatProvider == nil)
        #expect(configuration.chatAutoClearMinutes == nil)
        #expect(configuration.extractorProvider == nil)
        configuration.chatProvider = .kimi
        configuration.chatAutoClearMinutes = 180
        configuration.extractorProvider = .codex
        configuration.extractorModels = [.codex: "gpt-6-sol"]
        configuration.extractorEfforts = [.codex: "medium"]

        let data = try JSONEncoder().encode(configuration)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        // The Python extractor reads these exact keys.
        #expect(object["extractorProvider"] as? String == "codex")
        #expect((object["extractorModels"] as? [String: String])?["codex"] == "gpt-6-sol")
        #expect((object["extractorEfforts"] as? [String: String])?["codex"] == "medium")

        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: data)
        #expect(decoded.chatProvider == .kimi)
        #expect(decoded.chatAutoClearMinutes == 180)
        #expect(decoded.extractorProvider == .codex)
        #expect(decoded.extractorModel(for: .codex) == "gpt-6-sol")
        #expect(decoded.extractorEffort(for: .codex) == "medium")
    }

    @Test("Extraction falls back to the placement model and effort, like the extractor script")
    func extractorFallsBackToPlacement() {
        var configuration = starter()
        #expect(configuration.extractorModel(for: .claude) == AppConfiguration.defaultPlacementModels[.claude])
        configuration.placementModels[.claude] = "sonnet"
        configuration.placementEfforts[.claude] = "high"
        #expect(configuration.extractorModel(for: .claude) == "sonnet")
        #expect(configuration.extractorEffort(for: .claude) == "high")
        #expect(configuration.extractorEffort(for: .kimi) == nil)
    }

    @Test("Resetting a follow-another-setting choice to nil removes it from config.json")
    func resetToFollowRemovesSavedValue() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        let repository = JSONConfigurationRepository(url: url)
        var configuration = starter()
        configuration.chatProvider = .claude
        configuration.chatAutoClearMinutes = 60
        configuration.extractorProvider = .kimi
        configuration.placementProvider = .codex
        try await repository.save(configuration)

        configuration.chatProvider = nil
        configuration.chatAutoClearMinutes = nil
        configuration.extractorProvider = nil
        configuration.placementProvider = nil
        try await repository.save(configuration)

        let object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        for key in ["chatProvider", "chatAutoClearMinutes", "extractorProvider", "placementProvider"] {
            #expect(object[key] == nil, "\(key) should be removed")
        }
        let reloaded = try await repository.loadOrCreate(default: starter())
        #expect(reloaded.chatProvider == nil)
        #expect(reloaded.chatAutoClearMinutes == nil)
    }

    @Test("A zero or negative auto-clear value loads as never")
    func nonPositiveAutoClearIsNever() throws {
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(starter())) as? [String: Any])
        object["chatAutoClearMinutes"] = 0
        let decoded = try JSONDecoder().decode(
            AppConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.chatAutoClearMinutes == nil)
    }

    @Test("Auto-clear reads stored minutes back in the unit that wrote them")
    func autoClearUnits() {
        #expect(QueueChatAutoClear(minutes: nil).unit == .never)
        #expect(QueueChatAutoClear(minutes: 0).minutes == nil)
        #expect(QueueChatAutoClear(minutes: 45) == QueueChatAutoClear(unit: .minutes, amount: 45))
        #expect(QueueChatAutoClear(minutes: 120) == QueueChatAutoClear(unit: .hours, amount: 2))
        #expect(QueueChatAutoClear(minutes: 4_320) == QueueChatAutoClear(unit: .days, amount: 3))
        for unit in QueueChatAutoClear.Unit.allCases where unit != .never {
            for amount in unit.amountRange {
                let value = QueueChatAutoClear(unit: unit, amount: amount)
                #expect(QueueChatAutoClear(minutes: value.minutes) == value)
            }
        }
        #expect(QueueChatAutoClear(unit: .hours, amount: 99).amount == 23)
        #expect(QueueChatAutoClear(minutes: 60).summary == "1 hour")
        #expect(QueueChatAutoClear(minutes: 2_880).summary == "2 days")
    }

    @Test("Switching units keeps an amount that fits and starts fresh from never")
    func autoClearSwitching() {
        let twoHours = QueueChatAutoClear(unit: .hours, amount: 2)
        #expect(twoHours.switching(to: .days) == QueueChatAutoClear(unit: .days, amount: 2))
        #expect(twoHours.switching(to: .never).minutes == nil)
        #expect(QueueChatAutoClear(minutes: nil).switching(to: .minutes)
            == QueueChatAutoClear(unit: .minutes, amount: 30))
        #expect(QueueChatAutoClear(unit: .days, amount: 30).switching(to: .hours)
            == QueueChatAutoClear(unit: .hours, amount: 1))
    }

    @Test("A conversation is due once it has been idle for the configured time")
    func autoClearDue() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(!QueueChatAutoClear.isDue(lastActivity: now.addingTimeInterval(-3_599), now: now, minutes: 60))
        #expect(QueueChatAutoClear.isDue(lastActivity: now.addingTimeInterval(-3_600), now: now, minutes: 60))
        #expect(!QueueChatAutoClear.isDue(lastActivity: .distantPast, now: now, minutes: nil))
    }
}
