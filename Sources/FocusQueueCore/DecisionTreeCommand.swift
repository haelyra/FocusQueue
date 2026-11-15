import Foundation

/// `focus-queue-session decision ...`: record, settle, and rewind an agent's
/// decisions. <TASK-ID> <AGENT-ID> may be omitted to use $FOCUS_QUEUE_TASK_ID
/// and $FOCUS_QUEUE_SUBTASK_ID.
public enum DecisionTreeCommand {
    public static let usage = """
        Usage: focus-queue-session decision add [<TASK-ID> <AGENT-ID>] "<divergence>" --option "<recommended>" [--option "<fallback>" ...] [--from user|master-plan|task-plan|other] [--detail "<why>"] [--chosen <OPTION|recommended>] [--no-push]
               focus-queue-session decision choose [<TASK-ID> <AGENT-ID>] [<NODE>] <OPTION|recommended|next> [--by user|agent|continue]
               focus-queue-session decision rewind [<TASK-ID> <AGENT-ID>] <NODE> [--option <OPTION>] [--reason "<why>"] [--by user|agent] [--no-restart]
               focus-queue-session decision show [<TASK-ID> <AGENT-ID>]
               focus-queue-session decision list [<TASK-ID>]
               focus-queue-session decision due [--apply]
               focus-queue-session decision push [<TASK-ID> <AGENT-ID>]
        Options are listed in recommendation order (A recommended, B fallback); "Label — detail" adds a detail line.
        """

    public static func run(arguments: [String], root: URL, environment: [String: String],
                           sessionExecutable: String? = nil) async throws {
        var args = Array(arguments.dropFirst())
        guard let verb = args.first else { throw DecisionUsageError() }
        args.removeFirst()
        let control = TmuxDecisionAgentControl(root: root, sessionExecutable: sessionExecutable)
        let service = DecisionTreeService(root: root, claudeRoot: DecisionConversations.claudeRoot(environment: environment),
                                          control: control)
        let selfAgentID = environment["FOCUS_QUEUE_SUBTASK_ID"].flatMap { $0.isEmpty ? nil : $0 }

        switch verb {
        case "add", "record":
            let options = try values("--option", in: &args)
            let from = try option("--from", in: &args) ?? "task-plan"
            let detail = try option("--detail", in: &args)
            let chosen = try option("--chosen", in: &args)
            let push = !flag("--no-push", in: &args)
            guard let divergence = DecisionDivergence(argument: from) else { throw DecisionUsageError() }
            let (taskID, agentID, rest) = try identity(args, environment: environment, positional: 1)
            guard rest.count == 1 else { throw DecisionUsageError() }
            let liveSession = selfAgentID?.caseInsensitiveCompare(agentID) == .orderedSame
                ? Self.liveSessionID(environment: environment) : nil
            let agent = try await service.agent(taskID: taskID, agentID: agentID, liveSessionID: liveSession,
                                                fallbackWorkspace: FileManager.default.currentDirectoryPath)
            let recorded = try await service.record(agent: agent, title: rest[0], divergence: divergence, detail: detail,
                                                    options: options, chosen: chosen, push: push)
            try emit(recordOutput(recorded, agent: agent))

        case "choose", "decide":
            let by = try option("--by", in: &args).map(actor) ?? (selfAgentID == nil ? .user : .agent)
            let (taskID, agentID, rest) = try identity(args, environment: environment, positional: nil)
            guard (1...2).contains(rest.count) else { throw DecisionUsageError() }
            let nodeID = rest.count == 2 ? rest[0] : nil
            // The agent is choosing for itself, so it is already running: no resume prompt.
            let resume = selfAgentID?.caseInsensitiveCompare(agentID) != .orderedSame
            let settled = try await service.choose(taskID: taskID, agentID: agentID, nodeID: nodeID,
                                                   optionID: rest.last!, by: by, resume: resume)
            var output: [String: String] = ["status": "decided", "task": settled.taskID, "agent": settled.agentID,
                                            "node": settled.nodeID, "option": settled.optionID, "by": by.rawValue]
            if let delivery = settled.delivery { output["agentResumed"] = delivery }
            if let error = settled.deliveryError { output["resumeError"] = error }
            output["next_step"] = resume ? "The agent was told to proceed." : "Proceed with option \(settled.optionID)."
            try emit(output)

        case "rewind":
            let optionID = try option("--option", in: &args)
            let reason = try option("--reason", in: &args)
            let explicitActor = try option("--by", in: &args).map(actor)
            let restart = !flag("--no-restart", in: &args)
            let (taskID, agentID, rest) = try identity(args, environment: environment, positional: 1)
            guard rest.count == 1 else { throw DecisionUsageError() }
            let callerIsAgent = selfAgentID?.caseInsensitiveCompare(agentID) == .orderedSame
            let by = explicitActor ?? (callerIsAgent ? .agent : .user)
            let rewound = try await service.rewind(taskID: taskID, agentID: agentID, nodeID: rest[0], optionID: optionID,
                                                   by: by, reason: reason, restart: restart, deferRestart: callerIsAgent)
            try emit(rewindOutput(rewound, callerIsAgent: callerIsAgent))

        case "restart":
            let delay = try option("--delay", in: &args).flatMap(Int.init) ?? 0
            guard args.count == 2 else { throw DecisionUsageError() }
            let outcome = try await service.performPendingRestart(taskID: args[0].uppercased(), agentID: args[1],
                                                                  delaySeconds: min(max(delay, 0), 60))
            try emit(["status": "restarted", "outcome": outcome])

        case "show":
            let (taskID, agentID, rest) = try identity(args, environment: environment, positional: 0)
            guard rest.isEmpty else { throw DecisionUsageError() }
            guard let tree = try service.store.load(taskID: taskID, agentID: agentID) else {
                throw DecisionTreeError.noTree(agentID)
            }
            try emit(tree)

        case "list":
            guard args.count <= 1 else { throw DecisionUsageError() }
            let taskIDs = args.first.map { [$0.uppercased()] }
                ?? environment["FOCUS_QUEUE_TASK_ID"].flatMap { $0.isEmpty ? nil : [$0.uppercased()] }
                ?? service.store.taskIDsWithTrees()
            let settings = service.settings()
            let rows = taskIDs.flatMap { service.store.trees(taskID: $0) }.map { tree in
                TreeListing(task: tree.taskID, agent: tree.agentID, title: tree.agentTitle ?? tree.agentID,
                            nodes: tree.nodes.count, pending: tree.pendingNodes.map(\.id),
                            head: tree.head.map { "\($0.nodeID)\($0.optionID.map { "/\($0)" } ?? "")" },
                            autoDecideAt: tree.pendingNodes.compactMap { settings.dueDate(for: $0) }.min()
                                .map { DecisionTreeStore.timestamp($0) },
                            file: (try? service.store.treeURL(taskID: tree.taskID, agentID: tree.agentID))?.path ?? "")
            }
            try emit(rows)

        case "due":
            let apply = flag("--apply", in: &args)
            guard args.isEmpty else { throw DecisionUsageError() }
            let settings = service.settings()
            if apply {
                let settled = await service.applyDue(settings: settings)
                try emit(DueOutput(autoDecide: settings.autoDecide, minutes: settings.autoDecideMinutes,
                                   settled: settled.map { "\($0.taskID) \($0.agentID) \($0.nodeID)=\($0.optionID)" + ($0.deliveryError.map { " (resume failed: \($0))" } ?? "") },
                                   due: []))
            } else {
                let now = Date()
                let due = service.store.taskIDsWithTrees().flatMap { service.store.trees(taskID: $0) }.flatMap { tree in
                    tree.pendingNodes.compactMap { node -> String? in
                        guard let date = settings.dueDate(for: node) else { return nil }
                        return "\(tree.taskID) \(tree.agentID) \(node.id) \(date <= now ? "overdue" : "due") \(DecisionTreeStore.timestamp(date))"
                    }
                }
                try emit(DueOutput(autoDecide: settings.autoDecide, minutes: settings.autoDecideMinutes, settled: [], due: due))
            }

        case "push":
            let (taskID, agentID, rest) = try identity(args, environment: environment, positional: 0)
            guard rest.isEmpty else { throw DecisionUsageError() }
            let tree = try await service.pushPending(taskID: taskID, agentID: agentID)
            try emit(tree.nodes.compactMap { node in
                node.checkpoint.map { ["node": node.id, "ref": $0.ref, "pushed": $0.pushed ? "yes" : "no",
                                       "error": $0.pushError ?? ""] }
            })

        default:
            throw DecisionUsageError()
        }
    }

    // MARK: Output

    struct TreeListing: Encodable {
        var task: String
        var agent: String
        var title: String
        var nodes: Int
        var pending: [String]
        var head: String?
        var autoDecideAt: String?
        var file: String
    }

    struct DueOutput: Encodable {
        var autoDecide: Bool
        var minutes: Int
        var settled: [String]
        var due: [String]
    }

    struct RecordOutput: Encodable {
        var status: String
        var task: String
        var agent: String
        var node: String
        var title: String
        var decision: String
        var recommended: String?
        var options: [DecisionOption]
        var checkpoint: DecisionCheckpoint?
        var checkpointError: String?
        var conversationSaved: Bool
        var conversationNote: String?
        var autoDecideAt: String?
        var autoRewind: Bool
        var treeFile: String
        var nextStep: String

        enum CodingKeys: String, CodingKey {
            case status, task, agent, node, title, decision, recommended, options, checkpoint, checkpointError
            case conversationSaved, conversationNote, autoDecideAt, autoRewind, treeFile
            case nextStep = "next_step"
        }
    }

    static func recordOutput(_ recorded: DecisionTreeService.Recorded, agent: DecisionTreeService.Agent) -> RecordOutput {
        let node = recorded.node
        let recommended = node.options.first
        var next: String
        if node.status == .decided {
            next = "Recorded. Proceed with option \(node.chosenOptionID ?? "?"); the user can rewind to \(node.id) from View decision tree."
        } else {
            next = "Stop and wait for the user: they choose in Focus Queue (View decision tree) or reply here. A reply of \"continue\" means option \(recommended?.id ?? "A"); record any reply with `focus-queue-session decision choose \(agent.taskID) \(agent.agentID) \(node.id) <OPTION> --by user` (or `--by continue`)."
            if let due = recorded.dueAt {
                next += " With no reply by \(DecisionTreeStore.timestamp(due)), Focus Queue chooses option \(recommended?.id ?? "A") and resumes you."
            } else {
                next += " Auto-decide is off, so wait for the user."
            }
        }
        if let checkpoint = node.checkpoint, !checkpoint.pushed {
            next += " The checkpoint did not reach the remote (\(checkpoint.pushError ?? "unknown")); retry with `focus-queue-session decision push \(agent.taskID) \(agent.agentID)` or report it."
        }
        return RecordOutput(
            status: "recorded", task: agent.taskID, agent: agent.agentID, node: node.id, title: node.title,
            decision: node.status.rawValue, recommended: recommended?.id, options: node.options,
            checkpoint: node.checkpoint, checkpointError: node.checkpointError,
            conversationSaved: node.conversation?.forkable ?? false, conversationNote: node.conversation?.note,
            autoDecideAt: recorded.dueAt.map { DecisionTreeStore.timestamp($0) }, autoRewind: recorded.settings.autoRewind,
            treeFile: recorded.treeURL.path, nextStep: next)
    }

    struct RewindOutput: Encodable {
        var status: String
        var node: String
        var option: DecisionOption
        var restoredCommit: String?
        var movedBranch: Bool
        var branchNote: String?
        var abandonedRef: String
        var abandonedCommit: String
        var abandonedPushed: Bool
        var sessionID: String?
        var conversationForked: Bool
        var restart: String?
        var restartError: String?
        var nextStep: String

        enum CodingKeys: String, CodingKey {
            case status, node, option, restoredCommit, movedBranch, branchNote, abandonedRef, abandonedCommit
            case abandonedPushed, sessionID, conversationForked, restart, restartError
            case nextStep = "next_step"
        }
    }

    static func rewindOutput(_ rewound: DecisionTreeService.Rewound, callerIsAgent: Bool) -> RewindOutput {
        let next: String
        if rewound.restartError != nil {
            next = "The code is restored, but the agent did not restart. Open it and send: \(rewound.prompt)"
        } else if callerIsAgent && rewound.conversationForked {
            next = "Stop now. Focus Queue restarts you in \(TmuxDecisionAgentControl.deferredDelay) seconds in the conversation saved at \(rewound.node.id), on option \(rewound.option.id)."
        } else if callerIsAgent {
            next = "Continue in this conversation on option \(rewound.option.id): \(rewound.option.label). Re-read files before editing; the worktree changed."
        } else {
            next = "The agent was restarted on option \(rewound.option.id)."
        }
        return RewindOutput(
            status: "rewound", node: rewound.node.id, option: rewound.option,
            restoredCommit: rewound.node.checkpoint?.commit, movedBranch: rewound.restore.movedBranch,
            branchNote: rewound.restore.branchNote, abandonedRef: rewound.restore.saved.ref,
            abandonedCommit: rewound.restore.saved.commit, abandonedPushed: rewound.restore.saved.pushed,
            sessionID: rewound.sessionID, conversationForked: rewound.conversationForked,
            restart: rewound.restart, restartError: rewound.restartError, nextStep: next)
    }

    // MARK: Parsing

    /// Splits an optional leading <TASK-ID> <AGENT-ID> pair from the positional
    /// arguments. With `positional` set, the pair is present exactly when the
    /// arguments hold that many values plus two; otherwise (`choose`, whose
    /// node is optional) when there are at least three.
    static func identity(_ args: [String], environment: [String: String],
                         positional: Int?) throws -> (String, String, [String]) {
        let explicit = positional.map { args.count == $0 + 2 } ?? (args.count >= 3)
        if explicit, looksLikeTaskID(args[0]) {
            return (try DecisionTreeStore.validated(args[0]).uppercased(), try DecisionTreeStore.validated(args[1]),
                    Array(args.dropFirst(2)))
        }
        guard let taskID = environment["FOCUS_QUEUE_TASK_ID"], !taskID.isEmpty,
              let agentID = environment["FOCUS_QUEUE_SUBTASK_ID"], !agentID.isEmpty else {
            throw DecisionTreeError.notAllowed("Name the task and agent (<TASK-ID> <AGENT-ID>) or run this from the agent's pane, where $FOCUS_QUEUE_TASK_ID and $FOCUS_QUEUE_SUBTASK_ID are set.")
        }
        return (try DecisionTreeStore.validated(taskID).uppercased(), try DecisionTreeStore.validated(agentID), args)
    }

    static func looksLikeTaskID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z][A-Za-z0-9]*-[0-9]+$", options: .regularExpression) != nil
    }

    static func looksLikeNodeID(_ value: String) -> Bool {
        value.range(of: "^[Dd][0-9]+$", options: .regularExpression) != nil
    }

    static func actor(_ value: String) throws -> DecisionActor {
        guard let actor = DecisionActor(rawValue: value.lowercased()) else { throw DecisionUsageError() }
        return actor
    }

    /// The caller's own provider session, when it exports one.
    static func liveSessionID(environment: [String: String]) -> String? {
        TaskSessionBinding.providerSession(environment: environment)?.1
    }

    static func option(_ name: String, in args: inout [String]) throws -> String? {
        guard let index = args.firstIndex(of: name) else { return nil }
        guard index + 1 < args.count else { throw DecisionUsageError() }
        let value = args[index + 1]
        args.removeSubrange(index...(index + 1))
        return value
    }

    static func values(_ name: String, in args: inout [String]) throws -> [String] {
        var values: [String] = []
        while let value = try option(name, in: &args) { values.append(value) }
        return values
    }

    static func flag(_ name: String, in args: inout [String]) -> Bool {
        guard let index = args.firstIndex(of: name) else { return false }
        args.remove(at: index)
        return true
    }

    static func emit<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        FileHandle.standardOutput.write(try encoder.encode(value))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

public struct DecisionUsageError: Error, LocalizedError {
    public init() {}
    public var errorDescription: String? { DecisionTreeCommand.usage }
}
