import Foundation

/// Reaches a live agent: sends it text, or restarts its pane in another conversation.
public protocol DecisionAgentControlling: Sendable {
    /// Delivers `text` as the agent's next prompt, resuming it if it is idle.
    func deliver(_ text: String, taskID: String, agentID: String) async throws -> String
    /// Restarts the agent's pane. Claude resumes `sessionID` (a materialized
    /// fork); Codex forks `sessionID` natively when `forkNatively` is set.
    /// `deferred` waits a moment first, so an agent can call it on itself.
    func restart(taskID: String, agentID: String, provider: AgentProvider, sessionID: String?,
                 forkNatively: Bool, prompt: String, deferred: Bool) async throws -> String
}

/// The decision workflow shared by `focus-queue-session decision` and the app.
public struct DecisionTreeService: Sendable {
    public let root: URL
    let checkpointing: DecisionCheckpointing
    let claudeRoot: URL
    let control: (any DecisionAgentControlling)?

    public init(root: URL, checkpointing: DecisionCheckpointing = DecisionCheckpointing(),
                claudeRoot: URL = DecisionConversations.claudeRoot(),
                control: (any DecisionAgentControlling)? = nil) {
        self.root = root; self.checkpointing = checkpointing; self.claudeRoot = claudeRoot; self.control = control
    }

    public var store: DecisionTreeStore { DecisionTreeStore(root: root) }

    public struct Agent: Sendable {
        public var taskID: String
        public var agentID: String
        public var title: String
        public var provider: AgentProvider
        public var sessionID: String?
        public var workspace: String?
    }

    public struct Recorded: Sendable {
        public var tree: DecisionTree
        public var node: DecisionNode
        public var treeURL: URL
        public var dueAt: Date?
        public var settings: DecisionAutomationSettings
    }

    public struct Rewound: Sendable {
        public var tree: DecisionTree
        public var node: DecisionNode
        public var option: DecisionOption
        public var restore: DecisionCheckpointing.RestoreResult
        public var sessionID: String?
        public var conversationForked: Bool
        public var restart: String?
        public var restartError: String?
        public var prompt: String
    }

    public struct Settled: Sendable, Equatable {
        public var taskID: String
        public var agentID: String
        public var nodeID: String
        public var optionID: String
        public var delivery: String?
        public var deliveryError: String?
    }

    // MARK: Agents

    /// The agent's record. `liveSessionID` (the caller's own session) wins over
    /// the saved one, since an agent may have resumed into a newer session.
    public func agent(taskID: String, agentID: String, liveSessionID: String? = nil,
                      fallbackWorkspace: String? = nil) async throws -> Agent {
        let taskID = try DecisionTreeStore.validated(taskID).uppercased()
        guard let context = try await TaskContextStore(root: root).load(ticketID: taskID) else {
            throw TaskContextError.missingContext(taskID)
        }
        guard let subtask = context.subtasks.first(where: { $0.id.caseInsensitiveCompare(agentID) == .orderedSame }) else {
            throw TaskContextError.missingSubtask(agentID)
        }
        let live = liveSessionID.flatMap { $0.isEmpty ? nil : $0 }
        return Agent(taskID: taskID, agentID: subtask.id, title: subtask.title, provider: subtask.provider,
                     sessionID: live ?? subtask.sessionID,
                     workspace: subtask.workspace?.path ?? context.worktreePath ?? fallbackWorkspace)
    }

    public func settings() -> DecisionAutomationSettings {
        DecisionAutomationSettings.load(supportDirectory: root)
    }

    // MARK: Record

    /// Records a node: reserves it, checkpoints the worktree (commit, ref, push),
    /// saves the conversation, then asks the user unless the agent already chose.
    public func record(agent: Agent, title: String, divergence: DecisionDivergence, detail: String?,
                       options labels: [String], chosen: String?, push: Bool = true) async throws -> Recorded {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw DecisionTreeError.notAllowed("Describe the divergence in a short title.") }
        let options = Self.options(from: labels)
        guard !options.isEmpty else { throw DecisionTreeError.noOptions }
        if let chosen, !options.contains(where: { $0.id.caseInsensitiveCompare(chosen) == .orderedSame }),
           chosen.lowercased() != "recommended" {
            throw DecisionTreeError.unknownOption(chosen, "the new decision")
        }
        let store = self.store
        let now = DecisionTreeStore.timestamp()
        let node = try store.update(taskID: agent.taskID, agentID: agent.agentID) { tree -> DecisionNode in
            var current = tree ?? DecisionTree(taskID: agent.taskID, agentID: agent.agentID, agentTitle: agent.title,
                                               provider: agent.provider.rawValue, now: now)
            current.agentTitle = agent.title
            let node = current.addNode(title: title, divergence: divergence, detail: detail, options: options, now: now)
            tree = current
            return node
        }
        var checkpoint: DecisionCheckpoint?
        var checkpointError: String?
        if let workspace = agent.workspace {
            do {
                checkpoint = try await checkpointing.checkpoint(
                    workspace: workspace, ref: DecisionTreeStore.ref(taskID: agent.taskID, agentID: agent.agentID, name: node.id),
                    message: "Focus Queue decision \(node.id) for \(agent.taskID): \(title)\n\nAgent: \(agent.agentID)\nOptions: \(options.map { "\($0.id) \($0.label)" }.joined(separator: "; "))",
                    push: push)
            } catch {
                checkpointError = error.localizedDescription
            }
        } else {
            checkpointError = "The agent has no recorded workspace."
        }
        let snapshot = try store.snapshotDirectory(taskID: agent.taskID, agentID: agent.agentID)
            .appendingPathComponent("\(node.id).jsonl")
        let conversation = DecisionConversations.capture(
            provider: agent.provider, sessionID: agent.sessionID, workspace: agent.workspace,
            destination: snapshot, claudeRoot: claudeRoot)
        let chosenID = chosen.map { $0.lowercased() == "recommended" ? options[0].id : $0.uppercased() }
        let saved = try store.update(taskID: agent.taskID, agentID: agent.agentID) { tree -> DecisionTree in
            guard var current = tree, let index = current.index(of: node.id) else { throw DecisionTreeError.unknownNode(node.id) }
            current.nodes[index].checkpoint = checkpoint
            current.nodes[index].checkpointError = checkpointError
            current.nodes[index].conversation = conversation
            if let chosenID { try current.choose(nodeID: node.id, optionID: chosenID, by: .agent, now: now) }
            current.updatedAt = DecisionTreeStore.timestamp()
            tree = current
            return current
        }
        let settings = self.settings()
        let final = saved.node(node.id) ?? node
        let due = settings.dueDate(for: final)
        let contexts = TaskContextStore(root: root)
        if final.status == .pending {
            let deadline = due.map { " Auto-decides \(Self.clock($0))." } ?? ""
            _ = try? await contexts.reportAttention(
                ticketID: agent.taskID, subtaskID: agent.agentID, attention: .question,
                summary: "Decision \(final.id): \(title). Recommended \(options[0].id): \(options[0].label). Choose in View decision tree, or reply \"continue\".\(deadline)")
        }
        try? await contexts.appendAgentLog(
            ticketID: agent.taskID, subtaskID: agent.agentID,
            entry: "Decision \(final.id) (\(divergence.label) divergence): \(title). Options: \(options.map { "\($0.id) \($0.label)" }.joined(separator: "; ")). "
                + (final.status == .decided ? "Agent chose \(final.chosenOptionID ?? "?"). " : "Awaiting the user. ")
                + (checkpoint.map { "Checkpoint \($0.shortCommit) at \($0.ref)" + ($0.pushed ? ", pushed to \($0.remote ?? "remote")." : "; push failed: \($0.pushError ?? "unknown").") }
                    ?? "No checkpoint: \(checkpointError ?? "unknown").")
                + (conversation.forkable ? " Conversation saved at \(snapshot.path)." : " \(conversation.note ?? "")"))
        store.notify(taskID: agent.taskID, agentID: agent.agentID, event: "record")
        Self.notifyContextChanged()
        return Recorded(tree: saved, node: final, treeURL: try store.treeURL(taskID: agent.taskID, agentID: agent.agentID),
                        dueAt: due, settings: settings)
    }

    static func options(from labels: [String]) -> [DecisionOption] {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return labels.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            .prefix(letters.count).enumerated().map { index, text in
                // "Label — detail" or "Label: detail" keeps the card short.
                let parts = text.components(separatedBy: " — ")
                let label = parts[0].trimmingCharacters(in: .whitespaces)
                let detail = parts.count > 1 ? parts.dropFirst().joined(separator: " — ").trimmingCharacters(in: .whitespaces) : nil
                return DecisionOption(id: String(letters[index]), label: String(label.prefix(240)),
                                      detail: detail.map { String($0.prefix(2_000)) })
            }
    }

    // MARK: Choose

    /// Settles a pending node and, when `resume` is set, tells the agent to proceed.
    @discardableResult
    public func choose(taskID: String, agentID: String, nodeID: String?, optionID: String, by actor: DecisionActor,
                       resume: Bool) async throws -> Settled {
        let store = self.store
        let now = DecisionTreeStore.timestamp()
        let (node, changed) = try store.update(taskID: taskID, agentID: agentID) { tree -> (DecisionNode, Bool) in
            guard var current = tree else { throw DecisionTreeError.noTree(agentID) }
            let named = nodeID.flatMap { $0.lowercased() == "latest" ? nil : $0 }
            let found = named.map { current.node($0) } ?? current.latestPending
            guard let node = found else {
                throw named.map { DecisionTreeError.unknownNode($0) } ?? DecisionTreeError.noPending
            }
            let resolved = Self.resolve(optionID, in: node)
            guard let option = resolved else { throw DecisionTreeError.unknownOption(optionID, node.id) }
            let wasPending = node.status == .pending
            try current.choose(nodeID: node.id, optionID: option, by: actor, now: now)
            tree = current
            return (current.node(node.id) ?? node, wasPending)
        }
        var settled = Settled(taskID: taskID.uppercased(), agentID: agentID, nodeID: node.id,
                              optionID: node.chosenOptionID ?? optionID)
        guard changed else { return settled }
        let option = node.option(node.chosenOptionID)
        let contexts = TaskContextStore(root: root)
        let summary = "Decision \(node.id) settled by \(actor.logLabel): option \(option?.id ?? "?") (\(option?.label ?? "")). Resuming."
        _ = try? await contexts.reportAttention(ticketID: taskID, subtaskID: agentID, attention: nil, summary: summary)
        try? await contexts.appendAgentLog(ticketID: taskID, subtaskID: agentID, entry: summary)
        store.notify(taskID: taskID, agentID: agentID, event: "choose")
        Self.notifyContextChanged()
        if resume, let control, let option {
            do {
                settled.delivery = try await control.deliver(Self.proceedPrompt(node: node, option: option, by: actor,
                    settings: settings(), taskID: taskID, agentID: agentID), taskID: taskID, agentID: agentID)
            } catch {
                settled.deliveryError = error.localizedDescription
            }
        }
        return settled
    }

    /// "A", "a", "recommended", "next" (the first untried option), or an option's exact label.
    static func resolve(_ value: String, in node: DecisionNode) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed.lowercased() {
        case "recommended", "continue", "default": return node.recommendedOptionID
        case "next", "second", "fallback": return node.nextUntriedOptionID ?? node.options.dropFirst().first?.id
        default:
            return node.option(trimmed)?.id
                ?? node.options.first { $0.label.caseInsensitiveCompare(trimmed) == .orderedSame }?.id
        }
    }

    static func proceedPrompt(node: DecisionNode, option: DecisionOption, by actor: DecisionActor,
                              settings: DecisionAutomationSettings, taskID: String, agentID: String) -> String {
        let who: String
        switch actor {
        case .auto: who = "No reply came within \(settings.windowDescription), so Focus Queue chose the recommended option"
        case .continue: who = "The user said continue, which means the recommended option"
        case .user: who = "The user chose"
        case .agent: who = "You chose"
        }
        return "[Focus Queue] Decision \(node.id) (\(node.title)): \(who): option \(option.id), \(option.label). Proceed with it."
            + " If it does not work as desired, rewind with `focus-queue-session decision rewind \(taskID) \(agentID) \(node.id) --reason \"<why>\"`."
    }

    // MARK: Auto-decide

    /// Settles every overdue pending node with its recommended option and
    /// resumes its agent. Safe to run from several processes: only the call that
    /// settles a node delivers the prompt.
    public func applyDue(now: Date = Date(), settings: DecisionAutomationSettings? = nil) async -> [Settled] {
        let settings = settings ?? self.settings()
        guard settings.autoDecide else { return [] }
        var settled: [Settled] = []
        let contexts = TaskContextStore(root: root)
        for taskID in store.taskIDsWithTrees() {
            let context = try? await contexts.load(ticketID: taskID)
            for tree in store.trees(taskID: taskID) {
                // Never revive an archived or finished agent on its own.
                guard let agent = context?.subtasks.first(where: { $0.id.caseInsensitiveCompare(tree.agentID) == .orderedSame }),
                      agent.status != .completed, agent.agentRemovedAt == nil else { continue }
                for node in tree.pendingNodes {
                    guard let due = settings.dueDate(for: node), due <= now,
                          let recommended = node.recommendedOptionID else { continue }
                    if let result = try? await choose(taskID: tree.taskID, agentID: tree.agentID, nodeID: node.id,
                                                      optionID: recommended, by: .auto, resume: true) {
                        settled.append(result)
                    }
                }
            }
        }
        return settled
    }

    // MARK: Rewind

    /// Restores the worktree to a node's checkpoint (saving the current state
    /// first), forks the conversation at the node, records the new path, and
    /// restarts the agent there with `option` (default: the next untried one).
    public func rewind(taskID: String, agentID: String, nodeID: String, optionID: String?, by actor: DecisionActor,
                       reason: String?, restart: Bool = true, deferRestart: Bool = false) async throws -> Rewound {
        let store = self.store
        guard let tree = try store.load(taskID: taskID, agentID: agentID) else { throw DecisionTreeError.noTree(agentID) }
        guard let node = tree.node(nodeID) else { throw DecisionTreeError.unknownNode(nodeID) }
        let settings = self.settings()
        if actor == .agent || actor == .auto, !settings.autoRewind {
            throw DecisionTreeError.notAllowed("Automatic rewinds are off in Focus Queue Settings. Ask the user first: `focus-queue-session attention \(taskID) \(agentID) approval \"Rewind \(node.id) to the next option?\"`.")
        }
        let optionValue = optionID ?? node.nextUntriedOptionID
        guard let optionValue else { throw DecisionTreeError.noUntriedOption(node.id) }
        guard let resolved = Self.resolve(optionValue, in: node), let option = node.option(resolved) else {
            throw DecisionTreeError.unknownOption(optionValue, node.id)
        }
        guard let checkpoint = node.checkpoint else { throw DecisionTreeError.nothingToRewind(node.id) }
        let agent = try await self.agent(taskID: taskID, agentID: agentID)
        let workspace = agent.workspace ?? checkpoint.workspace
        let stamp = DecisionTreeStore.timestamp().filter { $0.isNumber }.prefix(14)
        let restore = try await checkpointing.restore(
            workspace: workspace, to: checkpoint,
            preserving: DecisionTreeStore.ref(taskID: agent.taskID, agentID: agent.agentID, name: "\(node.id)-abandoned-\(stamp)"),
            message: "Focus Queue: work abandoned when \(agent.taskID) rewound to decision \(node.id)\n\nReason: \(reason ?? "not given")",
            push: true)
        var sessionID: String?
        var forked = false
        switch agent.provider {
        case .claude:
            if let snapshot = node.conversation?.snapshotPath, FileManager.default.fileExists(atPath: snapshot) {
                sessionID = try DecisionConversations.materializeClaude(
                    snapshot: URL(fileURLWithPath: snapshot), originalSessionID: node.conversation?.sessionID,
                    workspace: workspace, root: claudeRoot)
                forked = true
            } else {
                sessionID = agent.sessionID
            }
        case .codex, .kimi, .copilot:
            // Managed Codex, Kimi, and Copilot panes cannot resume mid-conversation
            // yet: the same session hears that the turns after the decision are abandoned.
            sessionID = agent.sessionID
        }
        let prompt = DecisionConversations.rewindPrompt(
            taskID: agent.taskID, agentID: agent.agentID, node: node, option: option, reason: reason,
            restore: restore, conversationForked: forked, provider: agent.provider)
        let now = DecisionTreeStore.timestamp()
        // Only a forked conversation needs a new process; otherwise the prompt goes to the live one.
        let restarts = restart && control != nil && forked
        let updated = try store.update(taskID: agent.taskID, agentID: agent.agentID) { tree -> DecisionTree in
            guard var current = tree else { throw DecisionTreeError.noTree(agentID) }
            try current.rewind(to: node.id, optionID: option.id, by: actor, reason: reason,
                               rewoundFrom: restore.saved, sessionID: forked ? sessionID : nil, now: now)
            current.pendingRestart = restarts && deferRestart
                ? DecisionPendingRestart(nodeID: node.id, prompt: prompt, requestedAt: now) : nil
            tree = current
            return current
        }
        let contexts = TaskContextStore(root: root)
        if forked, let sessionID {
            _ = try? await contexts.recordAgentIdentity(ticketID: agent.taskID, subtaskID: agent.agentID, sessionID: sessionID)
        }
        var restartResult: String?
        var restartError: String?
        if restart, let control {
            do {
                if !restarts {
                    restartResult = try await control.deliver(prompt, taskID: agent.taskID, agentID: agent.agentID)
                } else {
                    restartResult = try await control.restart(
                        taskID: agent.taskID, agentID: agent.agentID, provider: agent.provider, sessionID: sessionID,
                        forkNatively: false, prompt: prompt, deferred: deferRestart)
                }
            } catch {
                restartError = error.localizedDescription
            }
        }
        let summary = "Rewound to decision \(node.id) by \(actor.logLabel); now taking option \(option.id) (\(option.label))."
        _ = try? await contexts.reportAttention(ticketID: agent.taskID, subtaskID: agent.agentID, attention: nil,
                                                summary: summary)
        try? await contexts.appendAgentLog(
            ticketID: agent.taskID, subtaskID: agent.agentID,
            entry: summary + " Worktree restored to \(checkpoint.shortCommit)"
                + (restore.movedBranch ? " (branch moved back to \(String(checkpoint.parent?.prefix(10) ?? "?")))" : "")
                + "; abandoned work saved at \(restore.saved.ref) (\(restore.saved.shortCommit))"
                + (restore.saved.pushed ? ", pushed." : "; push failed: \(restore.saved.pushError ?? "unknown").")
                + (forked ? " Conversation forked as \(sessionID ?? "?")." : " Conversation not forked.")
                + (reason.map { " Reason: \($0)" } ?? "")
                + (restartError.map { " Restart failed: \($0)" } ?? ""))
        store.notify(taskID: agent.taskID, agentID: agent.agentID, event: "rewind")
        Self.notifyContextChanged()
        return Rewound(tree: updated, node: updated.node(node.id) ?? node, option: option, restore: restore,
                       sessionID: sessionID, conversationForked: forked, restart: restartResult,
                       restartError: restartError, prompt: prompt)
    }

    /// Performs the restart an agent requested on itself, once its pane can close.
    public func performPendingRestart(taskID: String, agentID: String, delaySeconds: Int) async throws -> String {
        if delaySeconds > 0 { try await Task.sleep(nanoseconds: UInt64(delaySeconds) * 1_000_000_000) }
        let store = self.store
        guard let pending = try store.update(taskID: taskID, agentID: agentID, { tree -> DecisionPendingRestart? in
            let pending = tree?.pendingRestart
            tree?.pendingRestart = nil
            return pending
        }) else { return "nothing pending" }
        guard let control else { throw DecisionTreeError.notAllowed("No agent control is available.") }
        let agent = try await self.agent(taskID: taskID, agentID: agentID)
        let tree = try store.load(taskID: taskID, agentID: agentID)
        let outcome = try await control.restart(
            taskID: agent.taskID, agentID: agent.agentID, provider: agent.provider,
            sessionID: tree?.node(pending.nodeID)?.activeAttempt?.sessionID ?? agent.sessionID,
            forkNatively: false, prompt: pending.prompt, deferred: false)
        try? await TaskContextStore(root: root).appendAgentLog(
            ticketID: agent.taskID, subtaskID: agent.agentID,
            entry: "Restarted the agent for decision \(pending.nodeID): \(outcome).")
        store.notify(taskID: agent.taskID, agentID: agent.agentID, event: "restart")
        Self.notifyContextChanged()
        return outcome
    }

    // MARK: Push retry

    /// Pushes every checkpoint in the tree that has not reached its remote yet.
    public func pushPending(taskID: String, agentID: String) async throws -> DecisionTree {
        guard let tree = try store.load(taskID: taskID, agentID: agentID) else { throw DecisionTreeError.noTree(agentID) }
        var pushed: [String: DecisionCheckpoint] = [:]
        for node in tree.nodes {
            if let checkpoint = node.checkpoint, !checkpoint.pushed {
                pushed[node.id] = await checkpointing.push(checkpoint)
            }
        }
        guard !pushed.isEmpty else { return tree }
        let updated = try store.update(taskID: taskID, agentID: agentID) { tree -> DecisionTree in
            guard var current = tree else { throw DecisionTreeError.noTree(agentID) }
            for (id, checkpoint) in pushed {
                if let index = current.index(of: id) { current.nodes[index].checkpoint = checkpoint }
            }
            current.updatedAt = DecisionTreeStore.timestamp()
            tree = current
            return current
        }
        store.notify(taskID: taskID, agentID: agentID)
        return updated
    }

    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        return "at " + formatter.string(from: date)
    }

    static func notifyContextChanged() {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(AgentRegistrationInbox.notificationName), object: nil, userInfo: nil, deliverImmediately: true)
    }
}
