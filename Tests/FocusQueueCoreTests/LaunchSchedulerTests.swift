import Foundation
import Testing
@testable import FocusQueueCore

@Suite("Scheduled agent launches")
struct LaunchSchedulerTests {
    private let preset = AgentLaunchPreset(provider: .codex, model: "gpt-6.1-sol")

    private func launch(
        fireAt: Date, repeatInterval: TimeInterval? = nil, ticketID: String = "FOC-124"
    ) -> ScheduledLaunch {
        ScheduledLaunch(fireAt: fireAt, repeatIntervalSeconds: repeatInterval,
                        ticketID: ticketID, prompt: "Run the tests", title: "Tests", preset: preset)
    }

    @Test("Units convert to seconds and label amounts")
    func units() {
        #expect(LaunchScheduleUnit.minutes.seconds == 60)
        #expect(LaunchScheduleUnit.hours.seconds == 3_600)
        #expect(LaunchScheduleUnit.days.seconds == 86_400)
        #expect(LaunchScheduleUnit.hours.label(1) == "hour")
        #expect(LaunchScheduleUnit.hours.label(3) == "hours")
        #expect(LaunchScheduleUnit.days.label(1) == "day")
    }

    @Test("Fire dates and repeat intervals clamp amounts to at least one")
    func math() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        #expect(LaunchScheduleMath.fireDate(from: now, amount: 2, unit: .hours)
            == now.addingTimeInterval(7_200))
        #expect(LaunchScheduleMath.fireDate(from: now, amount: 0, unit: .minutes)
            == now.addingTimeInterval(60))
        #expect(LaunchScheduleMath.repeatInterval(amount: 3, unit: .days) == 259_200)
    }

    @Test("A repeating launch reschedules; a one-shot does not")
    func reschedule() {
        let now = Date(timeIntervalSinceReferenceDate: 5_000)
        let repeating = launch(fireAt: now, repeatInterval: 3_600)
        let next = repeating.rescheduled(after: now)
        #expect(next?.fireAt == now.addingTimeInterval(3_600))
        #expect(next?.id == repeating.id)
        #expect(launch(fireAt: now).rescheduled(after: now) == nil)
    }

    @Test("The store round-trips launches and reports due ones in fire order")
    func storeRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LaunchScheduleStore(supportDirectory: root)
        #expect(store.load().isEmpty)

        let now = Date()
        let past = launch(fireAt: now.addingTimeInterval(-120), ticketID: "FOC-1")
        let olderPast = launch(fireAt: now.addingTimeInterval(-600), ticketID: "FOC-2")
        let future = launch(fireAt: now.addingTimeInterval(3_600), repeatInterval: 3_600, ticketID: "FOC-3")
        try store.save([past, future, olderPast])

        let loaded = store.load()
        #expect(loaded.count == 3)
        #expect(loaded.first?.ticketID == "FOC-2")
        #expect(loaded.last?.isRepeating == true)
        #expect(loaded.last?.preset == preset)

        let due = store.dueLaunches(now: now)
        #expect(due.map(\.ticketID) == ["FOC-2", "FOC-1"])
    }

    @Test("Unknown fields in the file survive for forward compatibility")
    func unknownFieldsSurvive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // A file written by a newer build with one extra field still loads;
        // Codable drops the unknown key rather than failing the whole list.
        let json = """
        [{"id":"a","createdAt":"2026-01-01T00:00:00Z","fireAt":"2026-01-01T01:00:00Z",\
        "repeatIntervalSeconds":null,"ticketID":"FOC-9","prompt":"p","title":"t",\
        "preset":{"provider":"codex"},"futureField":true}]
        """
        try Data(json.utf8).write(to: root.appendingPathComponent("scheduled-launches.json"))
        let store = LaunchScheduleStore(supportDirectory: root)
        #expect(store.load().first?.ticketID == "FOC-9")
    }
}
