import Foundation

/// The optional weekly cleanup job: once a week the queue opens a fresh
/// cleanup task and launches a mid-sized agent that prunes stale or redundant
/// collected data and checks that finished work released its worktrees and
/// sessions. Settings toggle it; it is on by default.
public struct WeeklyCleanupSettings: Equatable, Sendable {
    public static let defaultWeekday = 1  // Sunday, Calendar weekday numbering.
    public static let defaultHour = 10
    public static let defaultProvider: AgentProvider = .claude
    public static let defaultModel = "claude-sonnet-5-5"
    public static let defaultEffort = "medium"

    public var enabled: Bool
    /// 1 (Sunday) through 7 (Saturday).
    public var weekday: Int
    public var hour: Int
    public var provider: AgentProvider
    public var model: String

    public init(enabled: Bool = true, weekday: Int = Self.defaultWeekday, hour: Int = Self.defaultHour,
                provider: AgentProvider = Self.defaultProvider, model: String = Self.defaultModel) {
        self.enabled = enabled
        self.weekday = min(max(weekday, 1), 7)
        self.hour = min(max(hour, 0), 23)
        self.provider = provider
        self.model = model
    }

    public var preset: AgentLaunchPreset {
        AgentLaunchPreset(provider: provider, model: model.isEmpty ? nil : model,
                          effort: provider == .claude ? Self.defaultEffort : nil,
                          workspacePolicy: .existingCheckout, useTmux: true, includePrompt: true)
    }
}

/// When the weekly job last ran, kept beside the other schedule files so a
/// settings save never races it.
public struct WeeklyCleanupState: Codable, Equatable, Sendable {
    public var lastRunAt: Date?
    public var lastTicketID: String?
    public init(lastRunAt: Date? = nil, lastTicketID: String? = nil) {
        self.lastRunAt = lastRunAt; self.lastTicketID = lastTicketID
    }
}

public struct WeeklyCleanupStateStore: Sendable {
    public let file: URL

    public init(supportDirectory: URL) {
        file = supportDirectory.appendingPathComponent("weekly-cleanup.json")
    }

    /// Nil when the file is missing or unreadable, which callers treat as "never ran".
    public func load() -> WeeklyCleanupState? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WeeklyCleanupState.self, from: data)
    }

    public func save(_ state: WeeklyCleanupState) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: file, options: .atomic)
    }
}

public enum WeeklyCleanupPolicy {
    /// The latest weekday/hour slot at or before `now`.
    public static func mostRecentSlot(before now: Date, weekday: Int, hour: Int,
                                      calendar: Calendar = .current) -> Date? {
        var components = DateComponents()
        components.weekday = weekday
        components.hour = hour
        components.minute = 0
        components.second = 0
        if let exact = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now),
           calendar.component(.weekday, from: now) == weekday, exact <= now {
            return exact
        }
        return calendar.nextDate(after: now, matching: components,
                                 matchingPolicy: .nextTime, direction: .backward)
    }

    /// The next slot strictly after `now`, for the settings caption.
    public static func nextSlot(after now: Date, weekday: Int, hour: Int,
                                calendar: Calendar = .current) -> Date? {
        var components = DateComponents()
        components.weekday = weekday
        components.hour = hour
        components.minute = 0
        components.second = 0
        return calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime)
    }

    /// Due once per slot. A slot missed while the Mac slept or the app was
    /// closed still runs on the next check within the same week. A missing
    /// last run is not due: the caller records a baseline first, so turning
    /// the job on, or installing it, never launches an agent immediately.
    public static func isDue(now: Date, lastRunAt: Date?, weekday: Int, hour: Int,
                             calendar: Calendar = .current) -> Bool {
        guard let lastRunAt,
              let slot = mostRecentSlot(before: now, weekday: weekday, hour: hour, calendar: calendar)
        else { return false }
        return lastRunAt < slot && now >= slot
    }
}

public enum WeeklyCleanupPrompt {
    public static let taskTitle = "Weekly data cleanup"

    public static func taskSummary(date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM-dd"
        return "What: the scheduled weekly cleanup for \(formatter.string(from: date)). "
            + "Why: collected data, finished tasks, worktrees, and sessions accumulate clutter that slows agents and readers. "
            + "How: a mid-sized agent prunes outdated or redundant entries with minimal edits and verifies cleanup through the queue CLI."
    }

    /// Project-agnostic instructions for the cleanup agent.
    public static func text(supportDirectory: URL) -> String {
        let support = supportDirectory.path
        return """
        You are the weekly Focus Queue cleanup agent. Make the smallest changes that keep stored data accurate and lean. When unsure, keep it.

        Scope (Focus Queue support directory: \(support)):
        1. Collected data files: `user/data.md`, `projects/*/data.md`, and `tasks/*/data.md`. Remove only entries that are exact or near duplicates, contradicted by a newer entry, or clearly outdated (a dated fact superseded by a later one, a deferred requirement already delivered). Merge duplicates into one line rather than rewriting. Never reword, reorder, or "improve" entries you keep. Never delete a standing instruction or user preference unless a newer entry replaces it.
        2. Tasks: run `focus-queue-session cleanup --completed --dry-run` and `focus-queue-session cleanup --orphans --dry-run` first. Apply the same commands without `--dry-run` only for items the dry run lists as safe. Each scan can take ten minutes or more across many tasks; let it finish instead of cancelling. Do not change any task's status, priority, or title, and never resolve or cancel another task.
        3. Worktrees and sessions: for tasks already resolved or cancelled, confirm their tmux sessions stopped and worktrees moved to `.worktrees/.trash`; use `focus-queue-session diagnose <TASK>` and `focus-queue-session reconcile <TASK>` to repair records. A live agent, unmerged work, or an uncommitted change always means retain.

        Rules:
        - Never hand-edit `state.json`, `config.json`, `dashboard.json`, or any other JSON file; use `focus-queue-session` commands only.
        - Never delete plans, agent logs, evidence, authored documents, git branches, or worktrees by hand. Never run `--purge`.
        - Touch nothing outside the support directory except through `focus-queue-session` commands.
        - Before each data file edit, note the removed lines and the reason in your report.

        Finish:
        1. Write a short report to this task's `evidence/weekly-cleanup-report.md`: each file changed with the removed lines and reason, each cleanup command run with its result, and anything retained that a human should look at.
        2. If something needs a human decision, propose one review with `focus-queue-session review propose`; otherwise propose nothing.
        3. Run `focus-queue-session complete` with a one-sentence summary, then mark this cleanup task resolved with `focus-queue-session task status "$FOCUS_QUEUE_TASK_ID" resolved`.
        """
    }
}
