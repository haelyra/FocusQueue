import Foundation

/// A managed agent launch whose registration is missing required data after
/// its post-launch registration window. Surfaced as a visible subtask error
/// and a hard alert so the launch never silently degrades.
public struct AgentRegistrationIssue: Equatable, Sendable {
    public var registrationID: String
    public var title: String
    public var taskID: String?
    public var subtaskID: String?
    public var missingFields: [String]

    public init(registrationID: String, title: String, taskID: String? = nil,
                subtaskID: String? = nil, missingFields: [String]) {
        self.registrationID = registrationID
        self.title = title
        self.taskID = taskID
        self.subtaskID = subtaskID
        self.missingFields = missingFields
    }

    public var summary: String {
        let name = taskID.map { "\(title) (\($0))" } ?? title
        return "\(name) is missing \(missingFields.joined(separator: ", "))"
    }
}

/// Required registration data per launch path: a task always, the provider
/// session, the tmux reference for managed sessions, and the worktree plus
/// branch for isolated-workspace launches.
public enum AgentRegistrationValidator {
    public static func missingFields(
        record: ExternalAgentRegistration, subtask: TaskSubtask?
    ) -> [String] {
        var missing: [String] = []
        if record.taskID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            missing.append("task")
        }
        if record.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            missing.append("provider session")
        }
        if subtask?.runtimeMode == .tmux, record.tmux == nil, subtask?.tmux == nil {
            missing.append("tmux session")
        }
        if let workspace = subtask?.workspace, workspace.managed {
            if workspace.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                missing.append("worktree")
            }
            if workspace.branch?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                missing.append("branch")
            }
        }
        return missing
    }

    public static func missingFields(
        session: TaskAgentSession, subtask: TaskSubtask?
    ) -> [String] {
        var missing: [String] = []
        if session.ticketID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append("task")
        }
        if UUID(uuidString: session.sessionID) == nil {
            missing.append("provider session")
        }
        if subtask?.runtimeMode == .tmux, session.tmux == nil, subtask?.tmux == nil {
            missing.append("tmux session")
        }
        if let workspace = subtask?.workspace, workspace.managed {
            if workspace.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                missing.append("worktree")
            }
            if workspace.branch?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                missing.append("branch")
            }
        }
        return missing
    }

    public static func issue(
        record: ExternalAgentRegistration, subtask: TaskSubtask?
    ) -> AgentRegistrationIssue? {
        let missing = missingFields(record: record, subtask: subtask)
        guard !missing.isEmpty else { return nil }
        return AgentRegistrationIssue(
            registrationID: record.id, title: record.title, taskID: record.taskID,
            subtaskID: record.subtaskID, missingFields: missing)
    }
}

/// The launch data an app or fq launch knew before the provider session
/// existed: its fixed task and agent, the objective, and its expected tmux pane.
/// Process discovery uses it to bind and name the agent at first appearance.
public struct LaunchHint: Equatable, Sendable {
    public var taskID: String
    public var subtaskID: String
    public var provider: AgentProvider
    public var promptHint: String?
    public var providerSessionID: String?
    public var tmuxName: String?
    public var tmuxPaneID: String?

    public init(taskID: String, subtaskID: String, provider: AgentProvider,
                promptHint: String? = nil, providerSessionID: String? = nil,
                tmuxName: String? = nil, tmuxPaneID: String? = nil) {
        self.taskID = taskID
        self.subtaskID = subtaskID
        self.provider = provider
        self.promptHint = promptHint
        self.providerSessionID = providerSessionID
        self.tmuxName = tmuxName
        self.tmuxPaneID = tmuxPaneID
    }
}

public enum LaunchHintStore {
    /// Hints from placement capsules. Taskless capsules carry no binding authority.
    public static func hints(root: URL) -> [LaunchHint] {
        var hints: [LaunchHint] = []
        let capsuleStore = AgentPlacementCapsuleStore(root: root)
        let placements = root.appendingPathComponent("tracking/placements", isDirectory: true)
        let capsuleFiles = (try? FileManager.default.contentsOfDirectory(
            at: placements, includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [.skipsHiddenFiles])) ?? []
        for file in capsuleFiles where file.pathExtension == "json" {
            guard (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                  let capsule = try? capsuleStore.load(
                    launchID: file.deletingPathExtension().lastPathComponent),
                  let taskID = capsule.taskID, let subtaskID = capsule.assignmentID
            else { continue }
            hints.append(LaunchHint(
                taskID: taskID, subtaskID: subtaskID, provider: capsule.provider,
                promptHint: capsule.promptHint, providerSessionID: capsule.sessionID,
                tmuxName: capsule.tmuxName, tmuxPaneID: capsule.tmuxPaneID))
        }
        return hints
    }

    /// Exact identity only: the provider session UUID, or the immutable tmux
    /// pane reference. Ambiguous matches bind nothing.
    public static func match(
        sessionID: String, provider: AgentProvider,
        tmux: TmuxSessionReference?, hints: [LaunchHint]
    ) -> LaunchHint? {
        let sessionMatches = hints.filter {
            $0.provider == provider
                && $0.providerSessionID?.caseInsensitiveCompare(sessionID) == .orderedSame
        }
        if let unique = unique(sessionMatches) { return unique }
        guard let tmux else { return nil }
        let tmuxMatches = hints.filter { hint in
            guard hint.provider == provider else { return false }
            return hint.tmuxName == tmux.name && hint.tmuxPaneID == tmux.paneID
                && hint.tmuxName != nil
        }
        return unique(tmuxMatches)
    }

    private static func unique(_ matches: [LaunchHint]) -> LaunchHint? {
        let identities = Set(matches.map { $0.taskID.uppercased() + ":" + $0.subtaskID })
        guard identities.count == 1 else { return nil }
        return matches.max { ($0.providerSessionID == nil ? 0 : 1) < ($1.providerSessionID == nil ? 0 : 1) }
    }
}
