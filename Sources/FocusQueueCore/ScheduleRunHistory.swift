import Foundation

/// How a scheduled job's fire turned out. The schedule timeline marks each
/// past run with one of these.
public enum ScheduleRunOutcome: String, Codable, CaseIterable, Sendable {
    /// The job ran as scheduled.
    case completed
    /// The run started but was cut short, for example by quitting the app.
    case interrupted
    /// The job ran and reported an error.
    case failed
    /// The fire time passed without a run.
    case skipped

    public var label: String {
        switch self {
        case .completed: "Completed"
        case .interrupted: "Interrupted"
        case .failed: "Failed"
        case .skipped: "Skipped"
        }
    }

    public var explanation: String {
        switch self {
        case .completed: "Ran as scheduled"
        case .interrupted: "Started but cut short"
        case .failed: "Ran into an error"
        case .skipped: "Did not run"
        }
    }

    /// The matching outcome for a daily report run phase; a report still
    /// running has no outcome yet.
    public init?(reportPhase: DailyReportRunPhase) {
        switch reportPhase {
        case .completed: self = .completed
        case .failed: self = .failed
        case .interrupted: self = .interrupted
        case .running: return nil
        }
    }
}

/// One past fire of a scheduled job, kept for the timeline's two-day history.
public struct ScheduleRunRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: ScheduleJobKind
    public var title: String
    /// What happened, shown in the timeline detail.
    public var detail: String
    /// The task the job acted on; nil for app-level jobs.
    public var ticketID: String?
    /// Owning project; nil means the job belongs to the whole app.
    public var projectID: String?
    /// When the job was due.
    public var scheduledAt: Date
    /// When the outcome was recorded.
    public var recordedAt: Date
    public var outcome: ScheduleRunOutcome

    public init(id: String = UUID().uuidString, kind: ScheduleJobKind, title: String, detail: String = "",
                ticketID: String? = nil, projectID: String? = nil,
                scheduledAt: Date, recordedAt: Date = Date(), outcome: ScheduleRunOutcome) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.ticketID = ticketID
        self.projectID = projectID
        self.scheduledAt = scheduledAt
        self.recordedAt = recordedAt
        self.outcome = outcome
    }

    /// The timeline lane this record draws in: its task, or the shared app lane.
    public var trackID: String { ticketID?.uppercased() ?? ScheduleJob.appTrackID }
}

/// JSON persistence for past scheduled runs, one file in the support directory.
/// Records older than `retention` are pruned on every load and save.
public struct ScheduleRunHistoryStore: Sendable {
    /// The timeline shows up to two days of past runs.
    public static let retention: TimeInterval = 2 * 86_400
    public static let maximumRecords = 300

    public let file: URL

    public init(supportDirectory: URL) {
        file = supportDirectory.appendingPathComponent("schedule-run-history.json")
    }

    public init(file: URL) {
        self.file = file
    }

    public func load(now: Date = Date()) -> [ScheduleRunRecord] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let records = (try? decoder.decode([ScheduleRunRecord].self, from: data)) ?? []
        return Self.pruned(records, now: now)
    }

    /// Appends one record, prunes, and saves. Loads first so records written
    /// by another app instance survive.
    public func record(_ record: ScheduleRunRecord, now: Date = Date()) throws {
        try save(load(now: now) + [record], now: now)
    }

    public func save(_ records: [ScheduleRunRecord], now: Date = Date()) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Self.pruned(records, now: now))
        try data.write(to: file, options: .atomic)
    }

    /// Drops records older than the retention window and caps the count,
    /// keeping the newest by scheduled time.
    public static func pruned(_ records: [ScheduleRunRecord], now: Date) -> [ScheduleRunRecord] {
        let cutoff = now.addingTimeInterval(-retention)
        let kept = records.filter { $0.recordedAt >= cutoff }
            .sorted { ($0.scheduledAt, $0.id) < ($1.scheduledAt, $1.id) }
        return Array(kept.suffix(maximumRecords))
    }
}
