import Foundation
import Testing
@testable import FocusQueueCore

@Suite("Weekly cleanup job")
struct WeeklyCleanupTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    // 2026-11-22 is a Sunday (weekday 1).
    @Test("The most recent slot is this week's weekday and hour, or last week's")
    func slots() {
        #expect(WeeklyCleanupPolicy.mostRecentSlot(before: date("2026-11-24 09:00"), weekday: 1, hour: 10,
                                                   calendar: calendar) == date("2026-11-22 10:00"))
        #expect(WeeklyCleanupPolicy.mostRecentSlot(before: date("2026-11-22 10:00"), weekday: 1, hour: 10,
                                                   calendar: calendar) == date("2026-11-22 10:00"))
        #expect(WeeklyCleanupPolicy.mostRecentSlot(before: date("2026-11-22 09:59"), weekday: 1, hour: 10,
                                                   calendar: calendar) == date("2026-11-15 10:00"))
        #expect(WeeklyCleanupPolicy.nextSlot(after: date("2026-11-24 09:00"), weekday: 1, hour: 10,
                                             calendar: calendar) == date("2026-11-29 10:00"))
    }

    @Test("Due once per slot, catches up a missed slot, never without a baseline")
    func due() {
        let now = date("2026-11-24 09:00")
        #expect(!WeeklyCleanupPolicy.isDue(now: now, lastRunAt: nil, weekday: 1, hour: 10, calendar: calendar))
        #expect(WeeklyCleanupPolicy.isDue(now: now, lastRunAt: date("2026-11-20 12:00"),
                                          weekday: 1, hour: 10, calendar: calendar))
        #expect(!WeeklyCleanupPolicy.isDue(now: now, lastRunAt: date("2026-11-22 10:05"),
                                           weekday: 1, hour: 10, calendar: calendar))
        #expect(!WeeklyCleanupPolicy.isDue(now: date("2026-11-22 09:30"), lastRunAt: date("2026-11-20 12:00"),
                                           weekday: 1, hour: 10, calendar: calendar))
    }

    @Test("Config defaults to on, Sunday 10:00, mid-sized Claude; old configs decode")
    func configDefaults() throws {
        let config = AppConfiguration.eccDefault()
        let settings = config.weeklyCleanup
        #expect(settings.enabled)
        #expect(settings.weekday == 1 && settings.hour == 10)
        #expect(settings.provider == .claude && settings.model == "claude-sonnet-5-5")
        #expect(AgentModelTier(model: settings.model) == .mid)
        #expect(settings.preset.workspacePolicy == .existingCheckout)
        #expect(settings.preset.useTmux == true)
        var noTmux = config
        noTmux.persistentTerminals = false
        #expect(noTmux.weeklyCleanup.preset.useTmux == false)

        var changed = config
        changed.weeklyCleanupEnabled = false
        changed.weeklyCleanupWeekday = 4
        changed.weeklyCleanupHour = 15
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(changed))
        #expect(decoded.weeklyCleanup.enabled == false)
        #expect(decoded.weeklyCleanup.weekday == 4 && decoded.weeklyCleanup.hour == 15)

        let legacy = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(config))
        #expect(legacy.weeklyCleanupEnabled == nil && legacy.weeklyCleanup.enabled)
    }

    @Test("Another provider gets a mid-tier model from the catalog")
    func otherProvider() {
        var config = AppConfiguration.eccDefault()
        config.weeklyCleanupProvider = .codex
        let settings = config.weeklyCleanup
        #expect(settings.provider == .codex)
        #expect(!settings.model.isEmpty)
        #expect(AgentModelTier(model: settings.model) == .mid)
    }

    @Test("State round-trips through its file")
    func stateStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WeeklyCleanupStateStore(supportDirectory: dir)
        #expect(store.load() == nil)
        let state = WeeklyCleanupState(lastRunAt: Date(timeIntervalSince1970: 1_800_000_000), lastTicketID: "OTH-9")
        try store.save(state)
        #expect(store.load() == state)
    }

    @Test("Prompt keeps edits minimal and routes cleanup through the CLI")
    func prompt() {
        let text = WeeklyCleanupPrompt.text(supportDirectory: URL(fileURLWithPath: "/tmp/support"))
        #expect(text.contains("/tmp/support"))
        #expect(text.contains("smallest changes"))
        #expect(text.contains("cleanup --completed --dry-run"))
        #expect(text.contains("Never run `--purge`"))
        #expect(text.contains("Never hand-edit"))
        #expect(text.contains("weekly-cleanup-report.md"))
        #expect(WeeklyCleanupPrompt.taskSummary(date: Date()).hasPrefix("What:"))
    }

    @Test("The schedule timeline shows the next weekly slot only when enabled")
    func timeline() {
        let now = date("2026-11-24 09:00")
        let on = ScheduleTimeline.jobs(
            launches: [], dailyReport: nil, weeklyCleanup: WeeklyCleanupSettings(),
            decisions: [], automation: AppConfiguration.eccDefault().decisionAutomation,
            tickets: [:], now: now, calendar: calendar)
        let job = on.first { $0.source == .weeklyCleanup }
        #expect(job?.anchor == date("2026-11-29 10:00"))
        #expect(job?.repeatInterval == TimeInterval(604_800))
        let off = ScheduleTimeline.jobs(
            launches: [], dailyReport: nil, weeklyCleanup: WeeklyCleanupSettings(enabled: false),
            decisions: [], automation: AppConfiguration.eccDefault().decisionAutomation,
            tickets: [:], now: now, calendar: calendar)
        #expect(!off.contains { $0.source == .weeklyCleanup })
    }
}
