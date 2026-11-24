import Foundation

/// Finds the Focus Queue agent that a process inside a T3 Code thread belongs to.
///
/// T3 Code does not pass Focus Queue's `FOCUS_QUEUE_TASK_ID`/`FOCUS_QUEUE_SUBTASK_ID` to its
/// agents, but it exports the thread's id as `T3CODE_THREAD_ID`. `focus-queue-session` uses this
/// to fill in the task and agent IDs, and to keep `attach` from registering a second agent.
public enum T3AgentIdentity {
    public static let threadEnvironmentKey = "T3CODE_THREAD_ID"

    /// The agent bound to this T3 thread. Before the launch is adopted the thread id is not saved
    /// yet, so an unfinished launch whose checkout contains `cwd` matches too, when it is the only one.
    /// Nothing matches outside a T3 thread.
    public static func resolve(environment: [String: String], cwd: String,
                               records: [T3SubtaskRecord]) -> T3SubtaskLocation? {
        guard let threadId = environment[threadEnvironmentKey]?.trimmingCharacters(in: .whitespaces),
              !threadId.isEmpty else { return nil }
        let live = records.filter { $0.subtask.agentRemovedAt == nil }
        if let bound = live.first(where: { $0.subtask.t3?.threadId.caseInsensitiveCompare(threadId) == .orderedSame }) {
            return bound.location
        }
        let directory = standardized(cwd)
        let launching = live.filter { record in
            guard record.subtask.t3 == nil, let intent = record.subtask.t3Launch else { return false }
            let checkout = standardized(intent.worktreePath)
            return directory == checkout || directory.hasPrefix(checkout + "/")
        }
        return launching.count == 1 ? launching[0].location : nil
    }

    /// `environment` plus the task and agent IDs of the T3 agent it belongs to. Unchanged when
    /// Focus Queue already exported a task, or when the process is not a Focus Queue T3 agent.
    public static func environment(_ environment: [String: String], cwd: String,
                                   records: [T3SubtaskRecord]) -> [String: String] {
        guard environment["FOCUS_QUEUE_TASK_ID"]?.isEmpty != false,
              let location = resolve(environment: environment, cwd: cwd, records: records) else { return environment }
        var result = environment
        result["FOCUS_QUEUE_TASK_ID"] = location.ticketID
        result["FOCUS_QUEUE_SUBTASK_ID"] = location.subtaskID
        result["FOCUS_QUEUE_RUNTIME"] = AgentRuntimeMode.t3.rawValue
        return result
    }

    private static func standardized(_ path: String) -> String {
        let value = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        return value.count > 1 && value.hasSuffix("/") ? String(value.dropLast()) : value
    }
}
