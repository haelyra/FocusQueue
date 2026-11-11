import Foundation

/// Units the task creator offers for delayed and repeating launches.
public enum LaunchScheduleUnit: String, Codable, CaseIterable, Sendable {
    case minutes, hours, days

    public var seconds: TimeInterval {
        switch self {
        case .minutes: 60
        case .hours: 3_600
        case .days: 86_400
        }
    }

    public func label(_ amount: Int) -> String {
        switch self {
        case .minutes: amount == 1 ? "minute" : "minutes"
        case .hours: amount == 1 ? "hour" : "hours"
        case .days: amount == 1 ? "day" : "days"
        }
    }
}

/// One agent launch the queue owes a task at a future time. Created from the
/// task creator's schedule fields; fired by the queue's refresh loop while the
/// app runs. A repeating entry reschedules itself after each fire.
public struct ScheduledLaunch: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var createdAt: Date
    public var fireAt: Date
    /// Repeating launches carry their interval; one-shot launches carry nil.
    public var repeatIntervalSeconds: TimeInterval?
    public var ticketID: String
    public var prompt: String
    public var title: String
    public var preset: AgentLaunchPreset

    public init(id: String = UUID().uuidString, createdAt: Date = Date(), fireAt: Date,
                repeatIntervalSeconds: TimeInterval? = nil, ticketID: String,
                prompt: String, title: String, preset: AgentLaunchPreset) {
        self.id = id
        self.createdAt = createdAt
        self.fireAt = fireAt
        self.repeatIntervalSeconds = repeatIntervalSeconds
        self.ticketID = ticketID
        self.prompt = prompt
        self.title = title
        self.preset = preset
    }

    public var isRepeating: Bool { repeatIntervalSeconds != nil }

    /// The next fire date after a repeating launch fired at `now`.
    public func rescheduled(after now: Date) -> ScheduledLaunch? {
        guard let interval = repeatIntervalSeconds, interval > 0 else { return nil }
        var copy = self
        copy.fireAt = now.addingTimeInterval(interval)
        return copy
    }
}

/// How far ahead a schedule lands, shared by the picker and the fired launch.
public enum LaunchScheduleMath {
    public static func fireDate(from now: Date, amount: Int, unit: LaunchScheduleUnit) -> Date {
        now.addingTimeInterval(TimeInterval(max(1, amount)) * unit.seconds)
    }

    /// The repeating interval for "every N units"; nil for a one-shot launch.
    public static func repeatInterval(amount: Int, unit: LaunchScheduleUnit) -> TimeInterval {
        TimeInterval(max(1, amount)) * unit.seconds
    }
}

/// JSON persistence for scheduled launches, one file in the support directory.
/// Unknown fields survive a round trip through the app's Codable model.
public struct LaunchScheduleStore: Sendable {
    public let file: URL

    public init(supportDirectory: URL) {
        file = supportDirectory.appendingPathComponent("scheduled-launches.json")
    }

    public init(file: URL) {
        self.file = file
    }

    public func load() -> [ScheduledLaunch] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ScheduledLaunch].self, from: data)) ?? []
    }

    public func dueLaunches(now: Date = Date()) -> [ScheduledLaunch] {
        load().filter { $0.fireAt <= now }.sorted { $0.fireAt < $1.fireAt }
    }

    public func save(_ launches: [ScheduledLaunch]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(launches.sorted { $0.fireAt < $1.fireAt })
        try data.write(to: file, options: .atomic)
    }
}
