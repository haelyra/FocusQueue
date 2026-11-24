import Foundation

/// What kind of trigger a scheduled job uses. The schedule viewer colors and
/// labels each clip by kind.
public enum ScheduleJobKind: String, CaseIterable, Codable, Sendable {
    /// Fires once at a set time.
    case timer
    /// Fires every N seconds from its next fire time.
    case interval
    /// Fires every day at a set time of day.
    case cron
    /// A pending decision that settles itself when the auto-decide window ends.
    case autoDecide

    public var label: String {
        switch self {
        case .timer: "Timer"
        case .interval: "Repeat"
        case .cron: "Cron"
        case .autoDecide: "Auto-decide"
        }
    }

    public var explanation: String {
        switch self {
        case .timer: "Runs once"
        case .interval: "Repeats every interval"
        case .cron: "Runs daily at a set time"
        case .autoDecide: "Settles an unanswered decision"
        }
    }
}

/// Which record owns a job, so a drag writes back to the right place.
public enum ScheduleJobSource: Hashable, Sendable {
    case scheduledLaunch(id: String)
    case scheduledResume(id: String)
    case dailyReport
    case decision(taskID: String, agentID: String, nodeID: String)
    /// A past run drawn from the two-day history; read-only.
    case runRecord(id: String)
}

/// The window lengths the viewer offers, in hours ahead of now.
public enum ScheduleRange: Int, CaseIterable, Identifiable, Sendable {
    case twoHours = 2, day = 24, threeDays = 72, week = 168, twoWeeks = 336

    public var id: Int { rawValue }
    public var hours: Int { rawValue }
    public var span: TimeInterval { TimeInterval(rawValue) * 3_600 }
    public var label: String {
        switch self {
        case .twoHours: "2 hours"
        case .day: "1 day"
        default: "\(rawValue / 24) days"
        }
    }

    /// The range for a value saved by builds that stored whole days.
    public static func migrating(legacyDays: Int) -> ScheduleRange? { ScheduleRange(rawValue: legacyDays * 24) }
}

/// One scheduled job, independent of how many times it fires in a window.
public struct ScheduleJob: Identifiable, Equatable, Sendable {
    public static let appTrackID = "focus-queue-app"
    /// Run-length estimates the timeline draws. Nothing records real run
    /// times yet, so these are typical values, labeled as estimates in the UI.
    public static let estimatedAgentRun: TimeInterval = 30 * 60
    public static let estimatedDailyReportRun: TimeInterval = 10 * 60

    public var source: ScheduleJobSource
    public var kind: ScheduleJobKind
    public var title: String
    public var detail: String
    /// What the schedule does, when the trigger alone is not specific enough.
    public var actionLabel: String?
    /// Existing pinned target shown in the detail popover.
    public var targetLabel: String?
    /// The task the job launches or decides on; nil for app-level jobs.
    public var ticketID: String?
    /// Owning project; nil means the job belongs to the whole app.
    public var projectID: String?
    /// Next fire time. For `.cron`, any date carrying the time of day.
    public var anchor: Date
    public var repeatInterval: TimeInterval?
    /// How long one run is expected to take; zero for an instant event.
    public var expectedDuration: TimeInterval
    public var isMovable: Bool

    public init(source: ScheduleJobSource, kind: ScheduleJobKind, title: String, detail: String = "",
                actionLabel: String? = nil, targetLabel: String? = nil,
                ticketID: String?, projectID: String?, anchor: Date,
                repeatInterval: TimeInterval? = nil, expectedDuration: TimeInterval = 0, isMovable: Bool) {
        self.source = source
        self.kind = kind
        self.title = title
        self.detail = detail
        self.actionLabel = actionLabel
        self.targetLabel = targetLabel
        self.ticketID = ticketID
        self.projectID = projectID
        self.anchor = anchor
        self.repeatInterval = repeatInterval
        self.expectedDuration = max(0, expectedDuration)
        self.isMovable = isMovable
    }

    public var id: String {
        switch source {
        case .scheduledLaunch(let id): "launch:\(id)"
        case .scheduledResume(let id): "resume:\(id)"
        case .dailyReport: "daily-report"
        case .decision(let task, let agent, let node): "decision:\(task)/\(agent)/\(node)"
        case .runRecord(let id): "run:\(id)"
        }
    }

    /// The lane this job draws in: its task, or the shared app lane.
    public var trackID: String { ticketID?.uppercased() ?? Self.appTrackID }
}

/// One row of the arrangement: every job that acts on the same task.
public struct ScheduleTrack: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var projectID: String?
    public var jobs: [ScheduleJob]
}

/// A run of tracks under one project heading.
public struct ScheduleTrackGroup: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var tracks: [ScheduleTrack]
}

/// One drawn fire of a job. The bar spans `start..<runEnd` (the expected run);
/// its label may use the free space up to `end`, the lane's next fire.
public struct ScheduleClip: Identifiable, Equatable, Sendable {
    public var job: ScheduleJob
    public var index: Int
    public var start: Date
    public var end: Date
    /// Sub-row inside the lane; non-zero only when fires collide.
    public var row: Int = 0
    /// Set for clips drawn from the run history; nil for scheduled fires.
    public var outcome: ScheduleRunOutcome? = nil
    public var id: String { "\(job.id)#\(index)" }
    public var runEnd: Date { min(start.addingTimeInterval(job.expectedDuration), max(start, end)) }
}

/// What the viewer knows about a task without loading its dashboard.
public struct ScheduleTicketInfo: Equatable, Sendable {
    public var title: String
    public var projectID: String?
    public init(title: String, projectID: String?) {
        self.title = title
        self.projectID = projectID
    }
}

public enum ScheduleTimeline {
    // MARK: Collect

    /// Gathers every job the app owns. `tickets` names tasks; `projectForTicket`
    /// resolves tasks the dashboard does not list (for example by ID prefix).
    public static func jobs(
        launches: [ScheduledLaunch],
        resumes: [ScheduledAgentResume] = [],
        dailyReport: DailyReportConfiguration?,
        decisions: [DecisionTree],
        automation: DecisionAutomationSettings,
        tickets: [String: ScheduleTicketInfo],
        projectForTicket: (String) -> String? = { _ in nil },
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [ScheduleJob] {
        func info(_ id: String) -> ScheduleTicketInfo? { tickets[id.uppercased()] }
        func project(_ id: String) -> String? { info(id)?.projectID ?? projectForTicket(id) }
        var jobs: [ScheduleJob] = []
        for launch in launches {
            let interval = launch.repeatIntervalSeconds.flatMap { $0 > 0 ? $0 : nil }
            jobs.append(ScheduleJob(
                source: .scheduledLaunch(id: launch.id),
                kind: interval == nil ? .timer : .interval,
                title: launch.title.isEmpty ? "Agent launch" : launch.title,
                detail: launch.prompt,
                ticketID: launch.ticketID,
                projectID: project(launch.ticketID),
                anchor: launch.fireAt,
                repeatInterval: interval,
                expectedDuration: ScheduleJob.estimatedAgentRun,
                isMovable: true))
        }
        for resume in resumes where resume.state == .pending {
            let target = resume.target
            jobs.append(ScheduleJob(
                source: .scheduledResume(id: resume.id), kind: .timer,
                title: resume.title.isEmpty ? "Existing-agent resume" : resume.title,
                detail: resume.prompt,
                actionLabel: "Resume existing agent",
                targetLabel: "\(target.agentID) · \(target.provider.displayName) · session \(target.sessionID)",
                ticketID: target.taskID, projectID: project(target.taskID),
                anchor: resume.fireAt, expectedDuration: ScheduleJob.estimatedAgentRun,
                isMovable: true))
        }
        if let report = dailyReport, report.enabled,
           let anchor = calendar.date(bySettingHour: report.scheduleHour, minute: report.scheduleMinute,
                                      second: 0, of: now) {
            jobs.append(ScheduleJob(
                source: .dailyReport, kind: .cron, title: "Daily report",
                detail: "Morning sweep of connected inboxes and agent results.",
                ticketID: nil, projectID: nil, anchor: anchor,
                repeatInterval: 86_400, expectedDuration: ScheduleJob.estimatedDailyReportRun,
                isMovable: true))
        }
        for tree in decisions {
            for node in tree.pendingNodes {
                guard let due = automation.dueDate(for: node) else { continue }
                jobs.append(ScheduleJob(
                    source: .decision(taskID: tree.taskID, agentID: tree.agentID, nodeID: node.id),
                    kind: .autoDecide,
                    title: "Decision \(node.id): \(node.title)",
                    detail: "Applies the recommended option if nobody answers first.",
                    ticketID: tree.taskID, projectID: project(tree.taskID),
                    anchor: due, isMovable: false))
            }
        }
        return jobs
    }

    // MARK: Arrange

    /// Tracks for the chosen scope, grouped by project. A nil `projectID`
    /// means all projects. App-level jobs show in every scope. `history`
    /// records whose task has no scheduled job get their own track, so a
    /// finished one-shot launch still appears in the past.
    public static func groups(
        jobs: [ScheduleJob],
        history: [ScheduleRunRecord] = [],
        projectID: String?,
        projectNames: [String: String],
        tickets: [String: ScheduleTicketInfo]
    ) -> [ScheduleTrackGroup] {
        let visible = jobs.filter { job in
            guard let projectID else { return true }
            return (job.projectID == nil && job.ticketID == nil) || job.projectID == projectID
        }
        let visibleHistory = history.filter { record in
            guard let projectID else { return true }
            return (record.projectID == nil && record.ticketID == nil) || record.projectID == projectID
        }
        var tracks: [String: ScheduleTrack] = [:]
        for job in visible {
            if tracks[job.trackID] == nil {
                let isApp = job.ticketID == nil
                tracks[job.trackID] = ScheduleTrack(
                    id: job.trackID,
                    title: isApp ? "Focus Queue" : job.trackID,
                    subtitle: isApp ? "App jobs" : tickets[job.trackID]?.title ?? job.title,
                    projectID: job.projectID, jobs: [])
            }
            tracks[job.trackID]?.jobs.append(job)
        }
        for record in visibleHistory where tracks[record.trackID] == nil {
            let isApp = record.ticketID == nil
            tracks[record.trackID] = ScheduleTrack(
                id: record.trackID,
                title: isApp ? "Focus Queue" : record.trackID,
                subtitle: isApp ? "App jobs" : tickets[record.trackID]?.title ?? record.title,
                projectID: record.projectID, jobs: [])
        }
        let groupKey: (ScheduleTrack) -> String = { track in
            track.id == ScheduleJob.appTrackID ? "~app" : track.projectID ?? "~other"
        }
        let byGroup = Dictionary(grouping: tracks.values, by: groupKey)
        return byGroup.keys.sorted { lhs, rhs in
            // App jobs first, unassigned tasks last, projects by name between.
            func rank(_ key: String) -> (Int, String) {
                if key == "~app" { return (0, "") }
                if key == "~other" { return (2, "") }
                return (1, projectNames[key] ?? key)
            }
            return rank(lhs) < rank(rhs)
        }.map { key in
            let title: String = switch key {
            case "~app": "App"
            case "~other": "Other"
            default: projectNames[key] ?? key
            }
            let ordered = (byGroup[key] ?? []).map { track -> ScheduleTrack in
                var track = track
                track.jobs.sort { $0.anchor < $1.anchor }
                return track
            }.sorted { ($0.jobs.first?.anchor ?? .distantFuture, $0.id) < ($1.jobs.first?.anchor ?? .distantFuture, $1.id) }
            return ScheduleTrackGroup(id: key, title: title, tracks: ordered)
        }
    }

    // MARK: Expand

    /// Every fire time of `job` inside `window`, capped so a dense repeat
    /// cannot flood the view.
    public static func occurrences(of job: ScheduleJob, in window: DateInterval, limit: Int = 500,
                                   calendar: Calendar = .current) -> [Date] {
        guard let interval = job.repeatInterval, interval > 0 else {
            return window.contains(job.anchor) ? [job.anchor] : []
        }
        if job.kind == .cron {
            // Daily jobs follow the wall clock, so walk calendar days: a fixed
            // 24-hour step would drift an hour across a daylight-saving change.
            let time = calendar.dateComponents([.hour, .minute], from: job.anchor)
            var day = calendar.startOfDay(for: window.start)
            var dates: [Date] = []
            while day <= window.end, dates.count < limit {
                if let date = calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0, of: day),
                   window.contains(date) {
                    dates.append(date)
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
            return dates
        }
        var first = job.anchor
        if first < window.start {
            let skip = ceil(window.start.timeIntervalSince(first) / interval)
            first = first.addingTimeInterval(skip * interval)
        }
        var dates: [Date] = []
        var date = first
        while date <= window.end, dates.count < limit {
            dates.append(date)
            date = date.addingTimeInterval(interval)
        }
        return dates
    }

    /// A read-only job standing in for one past run, so history draws in the
    /// same lane and shape as scheduled fires.
    public static func historyJob(for record: ScheduleRunRecord) -> ScheduleJob {
        ScheduleJob(source: .runRecord(id: record.id), kind: record.kind, title: record.title,
                    detail: record.detail, ticketID: record.ticketID, projectID: record.projectID,
                    anchor: record.scheduledAt, isMovable: false)
    }

    /// Clips for one lane. Fires closer than `minimumGap` to the previous
    /// fire in a row move to the next row, so labels never sit on top of each
    /// other. Each clip's slot ends at its row's next fire (or the window's
    /// end); the viewer truncates labels to fit. `history` records land as
    /// read-only clips marked with their outcome; when `pastCutoff` is set,
    /// scheduled fires before it are dropped so the recorded past is not
    /// double-drawn by jobs whose definition changed since.
    public static func clips(for track: ScheduleTrack, in window: DateInterval, minimumGap: TimeInterval = 0,
                             history: [ScheduleRunRecord] = [], pastCutoff: Date? = nil,
                             calendar: Calendar = .current) -> [ScheduleClip] {
        var starts: [(job: ScheduleJob, index: Int, start: Date, outcome: ScheduleRunOutcome?)] =
            track.jobs.flatMap { job in
                occurrences(of: job, in: window, calendar: calendar).enumerated().compactMap { index, date in
                    if let pastCutoff, date < pastCutoff { return nil }
                    return (job, index, date, nil)
                }
            }
        starts += history.filter { window.contains($0.scheduledAt) }.enumerated().map { index, record in
            (historyJob(for: record), index, record.scheduledAt, record.outcome)
        }
        starts.sort { ($0.start, $0.job.id) < ($1.start, $1.job.id) }
        var rowLast: [Date] = []
        var placed: [ScheduleClip] = []
        for entry in starts {
            let row = rowLast.firstIndex { entry.start.timeIntervalSince($0) >= max(minimumGap, 1) } ?? rowLast.count
            if row == rowLast.count { rowLast.append(entry.start) } else { rowLast[row] = entry.start }
            placed.append(ScheduleClip(job: entry.job, index: entry.index, start: entry.start,
                                       end: window.end, row: row, outcome: entry.outcome))
        }
        for i in placed.indices {
            if let next = placed[(i + 1)...].first(where: { $0.row == placed[i].row }) {
                placed[i].end = max(placed[i].start, next.start)
            }
        }
        return placed
    }

    // MARK: Window

    /// The drawable span: from the start of the day `pastSpan` before `now`,
    /// so past runs stay reachable by scrolling back, to `span` after `now`.
    /// The view opens on `now`, so the past is off screen by default.
    public static func window(now: Date, span: TimeInterval, pastSpan: TimeInterval,
                              calendar: Calendar = .current) -> DateInterval {
        let start = calendar.startOfDay(for: now.addingTimeInterval(-max(0, pastSpan)))
        return DateInterval(start: start, end: now.addingTimeInterval(max(60, span)))
    }

    /// Points per second so `span` fills `width` at `zoom` 1x, after
    /// `leadIn` points of the past kept left of the playhead so the "now"
    /// marker stays readable at the leading edge.
    public static func scale(width: Double, span: TimeInterval, zoom: Double, leadIn: Double = 0) -> Double {
        max(1, width - leadIn) * max(1, zoom) / max(60, span)
    }

    // MARK: Zoom

    /// Drag resolution for a zoom level: finer as an hour gets wider.
    public static func snapMinutes(pointsPerHour: Double) -> Int {
        switch pointsPerHour {
        case 120...: 5
        case 40...: 15
        case 15...: 30
        default: 60
        }
    }

    /// Minutes between labeled ruler ticks so labels stay at least
    /// `minimumSpacing` apart. Each step divides a day evenly.
    public static func tickMinutes(pointsPerHour: Double, minimumSpacing: Double = 64) -> Int {
        [5, 10, 15, 30, 60, 120, 180, 360, 720].first { Double($0) / 60 * pointsPerHour >= minimumSpacing } ?? 1_440
    }

    /// The zoom factor for a slider position in 0...1: exponential from 1x
    /// (the range fits the view) up to `maximum`.
    public static func zoomFactor(slider: Double, maximum: Double) -> Double {
        let top = max(1, maximum)
        return pow(top, min(max(slider, 0), 1))
    }

    // MARK: Drag

    /// Rounds `date` to the nearest `minutes` boundary in local time.
    public static func snap(_ date: Date, minutes: Int, calendar: Calendar = .current) -> Date {
        let step = TimeInterval(max(1, minutes) * 60)
        let offset = TimeInterval(calendar.timeZone.secondsFromGMT(for: date))
        let local = date.timeIntervalSinceReferenceDate + offset
        return Date(timeIntervalSinceReferenceDate: (local / step).rounded() * step - offset)
    }

    /// Where a movable job's next fire lands after dragging one of its
    /// occurrences from `from` to `to`. Repeats shift the whole series; a past
    /// result rolls forward by whole intervals, or clamps to `now` for a timer.
    public static func movedFireDate(of job: ScheduleJob, from: Date, to: Date, snapMinutes: Int,
                                     now: Date = Date(), calendar: Calendar = .current) -> Date {
        let target = snap(to, minutes: snapMinutes, calendar: calendar)
        let delta = target.timeIntervalSince(from)
        var next = job.anchor.addingTimeInterval(delta)
        if let interval = job.repeatInterval, interval > 0 {
            if next < now {
                next = next.addingTimeInterval(ceil(now.timeIntervalSince(next) / interval) * interval)
            }
            return next
        }
        return max(next, now)
    }

    /// The daily time a `.cron` job runs after a drag to `to`.
    public static func timeOfDay(_ date: Date, snapMinutes: Int, calendar: Calendar = .current) -> (hour: Int, minute: Int) {
        let snapped = snap(date, minutes: snapMinutes, calendar: calendar)
        let parts = calendar.dateComponents([.hour, .minute], from: snapped)
        return (parts.hour ?? 0, parts.minute ?? 0)
    }

    /// "every 6 hours", "every 90 minutes", "every 2 days".
    public static func intervalDescription(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes % 1_440 == 0 { let d = minutes / 1_440; return d == 1 ? "every day" : "every \(d) days" }
        if minutes % 60 == 0 { let h = minutes / 60; return h == 1 ? "every hour" : "every \(h) hours" }
        return minutes == 1 ? "every minute" : "every \(minutes) minutes"
    }
}
