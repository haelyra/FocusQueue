import Darwin
import FocusQueueCore
import Foundation

enum SessionRegistrationError: Error, LocalizedError {
    case usage
    case missingSessionIdentity
    case missingManagedRuntime
    case missingLibraryTask(String)
    case invalidLibraryDocument
    case missingArchitectureRepository

    var errorDescription: String? {
        switch self {
        case .usage:
            "Usage: focus-queue-session intake-changed | data ensure | data place <user|project|task> <target-id> <fact> | placement [--prompt <text>] [--task <TASK-ID>] [--launch <UUID>] [--cwd <path>] [--no-create] | projects list|create --id <id> --name <name> --workspace <absolute-path> --from <project-id> --task <TASK-ID> [--task <TASK-ID> ...]|recover | queue list|move <TASK-ID> top|bottom|before <TARGET-ID>|after <TARGET-ID>|reorder <TASK-ID> [<TASK-ID> ...]|pin <TASK-ID>|unpin <TASK-ID>|reset | task create <PROJECT-ID> <title> <summary> | task rename <TASK-ID> <title...> | task priority <TASK-ID> <critical|high|medium|low> | task status <TASK-ID> <status> | task link <TASK-ID> <url> <label> [type] | review-push <TASK-ID> <SUBTASK-ID> | workspace <TASK-ID> <SUBTASK-ID> <absolute-path> | diagnose <TASK-ID> | cleanup <TASK-ID>|--completed|--orphans|--purge [--dry-run] | attach <TASK-ID> | context <TASK-ID> | plan <TASK-ID> | add <TASK-ID> <codex|claude|kimi> <title> <description> | rename <TASK-ID> <SUBTASK-ID> <title> | identify <TASK-ID> <SUBTASK-ID> <title> <description> | archive-agent <TASK-ID> <SUBTASK-ID> | progress <TASK-ID> <SUBTASK-ID> <queued|working|idle|blocked> <summary> | associate <TASK-ID> <AGENT-ID> <SUBTASK-ID> | attention <TASK-ID> <AGENT-ID> <approval|question|interrupted|incomplete|failed> <summary> | result <TASK-ID> <AGENT-ID> <summary> | complete <TASK-ID> <SUBTASK-ID> <summary> | agents clear --all | runtime repair <TASK-ID> <SUBTASK-ID> | library migrate|status|task <TASK-ID>|document <TASK-ID> <markdown-path> [guide|architecture|reference]|export <destination>|restore <source> | architecture <TASK-ID> [repository-path]"
        case .missingSessionIdentity:
            "No Codex, Claude, or Kimi session ID was found in the environment or current WezTerm pane."
        case .missingManagedRuntime:
            "This pane has no saved Focus Queue runtime identity. Start the agent from New Agent in Focus Queue."
        case .missingLibraryTask(let ticketID):
            "Task \(ticketID) is absent from the durable library. Run library migrate to import existing task files."
        case .invalidLibraryDocument:
            "Choose a .md file and a document kind of guide, architecture, or reference."
        case .missingArchitectureRepository:
            "This task has no repository path. Run architecture <TASK-ID> <repository-path> with an explicit repository."
        }
    }
}

@main enum FocusQueueSessionCLI {
    static func main() async {
        do {
            let arguments = withEnvironmentIdentity(Array(CommandLine.arguments.dropFirst()),
                environment: ProcessInfo.processInfo.environment)
            if arguments.first == "tmux" { try await tmuxCommand(arguments: arguments) }
            else if arguments.first == "--help" || arguments.first == "help" {
                print(SessionRegistrationError.usage.localizedDescription)
                print("Agent log: log <TASK-ID> <AGENT-ID> <entry> (append-only, task-locked)")
                print("Inside a managed pane, omit <TASK-ID> <SUBTASK-ID> from attach, context, plan, log, progress, attention, result, complete, identify, review-push, and workspace; they default to $FOCUS_QUEUE_TASK_ID and $FOCUS_QUEUE_SUBTASK_ID.")
                print("Agent rules: rules (lifecycle, plan, workspace, and map-scope rules for managed agents)")
                print("Launch brief preview: brief <TASK-ID> <SUBTASK-ID> (the exact prompt a fresh launch of that agent receives)")
                print("Maintenance: reconcile <TASK-ID> [--no-cleanup] (repair documents and save a receipt; optional workspace cleanup)")
                print("Status hooks: status-event --provider claude|codex|kimi (reads one provider hook payload on stdin; exits 0 silently)")
                print("Data placement: data-placement status|on|off (automatic native prompt capture; off by default)")
                print("Scoped data: data ensure | data place <user|project|task> <target-id> <one-or-two-sentence fact>")
                print("Completion cleanup: cleanup <TASK-ID> | cleanup --completed | cleanup --orphans | cleanup --purge, each with optional --dry-run (stops tmux, stages worktrees in .worktrees/.trash for 7 days, archives unmerged work under refs/focus-queue/archive/, deletes merged local and remote branches)")
                print("Persistent terminals: tmux list | tmux start <name> [--cwd <directory>] [-- <command> ...] | tmux start-agent <TASK-ID> <AGENT-ID> [--cwd <directory>] -- <command> ... | tmux attach <name> | tmux ssh-command <user@host> <name>")
                print("Task layouts: tmux panes <name> | tmux arrange <name> | tmux manual <name> | tmux save | tmux restore | tmux persistence")
            }
            else if arguments.first == "projects" { try projectsCommand(arguments: arguments) }
            else if arguments.first == "queue" { try await queueCommand(arguments: arguments) }
            else if arguments.first == "task" { try await taskCommand(arguments: arguments) }
            else if arguments.first == "placement" { try await placementCommand(arguments: arguments) }
            else if arguments.first == "agents" { try await agentsCommand(arguments: arguments) }
            else if arguments.first == "runtime" { try await runtimeCommand(arguments: arguments) }
            else if arguments.first == "library" { try await libraryCommand(arguments: arguments) }
            else if arguments.first == "architecture" { try await architectureCommand(arguments: arguments) }
            else if arguments.first == "diagnose" { try await diagnose(arguments: arguments) }
            else if arguments.first == "cleanup" { try await cleanupCommand(arguments: arguments) }
            else if arguments.first == "register-event" { try await registerEvent(arguments: arguments) }
            else if arguments.first == "status-event" { await statusEvent(arguments: arguments) }
            else if arguments.first == "data-placement" { try await dataPlacement(arguments: arguments) }
            else if arguments.first == "data" { try await dataCommand(arguments: arguments) }
            else if arguments == ["intake-changed"] {
                notifyContextChanged()
                try emit(["status": "notified"])
            }
            else if arguments == ["rules"] {
                let output = TaskContext.agentRules()
                recordAgentCommand("rules", output: output)
                print(output, terminator: "")
            }
            else if arguments.first == "attach" { try await register(arguments: arguments) }
            else if arguments.first == "reconcile", (2...3).contains(arguments.count) {
                guard arguments.count == 2 || arguments[2] == "--no-cleanup" else { throw SessionRegistrationError.usage }
                let root = supportDirectory(environment: ProcessInfo.processInfo.environment)
                let store = TaskContextStore(root: root)
                let context = try await store.load(ticketID: arguments[1])
                let ticket = DashboardTicket(id: arguments[1], title: context?.title ?? arguments[1],
                    status: "open", summary: context?.summary ?? "", doneWhen: context?.successCriteria)
                try emit(try await TaskMaintenance(root: root).run(ticket: ticket, allowCleanup: arguments.count == 2))
            }
            else { try await updateContext(arguments: arguments) }
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            Darwin.exit(1)
        }
    }

    private static func projectsCommand(arguments: [String]) throws {
        let root = supportDirectory(environment: ProcessInfo.processInfo.environment)
        let transaction = ProjectCreationTransaction(
            supportDirectory: root,
            configurationURL: root.appendingPathComponent("config.json"))
        let recoveries = try transaction.recoverPending()
        switch arguments.dropFirst().first {
        case "list" where arguments.count == 2:
            try emit(transaction.listProjects())
        case "recover" where arguments.count == 2:
            try emit(ProjectRecoveryList(recoveries: recoveries))
        case "create":
            var projectID: String?
            var name: String?
            var workspace: String?
            var sourceProjectID: String?
            var taskIDs: [String] = []
            var index = 2
            while index < arguments.count {
                guard index + 1 < arguments.count else { throw SessionRegistrationError.usage }
                let value = arguments[index + 1]
                switch arguments[index] {
                case "--id" where projectID == nil: projectID = value
                case "--name" where name == nil: name = value
                case "--workspace" where workspace == nil: workspace = value
                case "--from" where sourceProjectID == nil: sourceProjectID = value
                case "--task": taskIDs.append(value)
                default: throw SessionRegistrationError.usage
                }
                index += 2
            }
            guard let projectID, let name, let workspace, let sourceProjectID,
                  !taskIDs.isEmpty else { throw SessionRegistrationError.usage }
            let receipt = try transaction.create(ProjectCreationRequest(
                id: projectID,
                name: name,
                workspacePath: workspace,
                sourceProjectID: sourceProjectID,
                taskIDs: taskIDs))
            try emit(receipt)
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name(ProjectCatalogChangeNotification.name),
                object: nil,
                userInfo: nil,
                deliverImmediately: true)
        default:
            throw SessionRegistrationError.usage
        }
    }

    private static func queueCommand(arguments: [String]) async throws {
        let root = supportDirectory(environment: ProcessInfo.processInfo.environment)
        let config = try loadConfiguration(from: root)
        let stateStore = JSONLocalStateStore(url: root.appendingPathComponent("state.json"))
        var state = try await stateStore.load()
        let showsAllProjects = state.showsAllProjects ?? true
        let repository = JSONDashboardRepository()
        let dashboard: DashboardDocument
        if showsAllProjects {
            var tickets: [DashboardTicket] = []
            var seen = Set<String>()
            for url in ProjectCatalog.mergedDashboardURLs(in: config.projects) {
                guard let document = try? await repository.load(from: url) else { continue }
                for ticket in document.tickets where seen.insert(ticket.id).inserted {
                    tickets.append(ticket)
                }
            }
            dashboard = DashboardDocument(tickets: tickets)
        } else {
            dashboard = try await repository.load(from: URL(fileURLWithPath: config.dashboardPath))
        }
        let store = QueueOrderStore(
            root: root,
            projectID: showsAllProjects ? ProjectCatalog.allProjectsScopeID : config.selectedProjectID)
        let requestedScope = ProcessInfo.processInfo.environment["FOCUS_QUEUE_PROJECT_ID"].flatMap { $0.isEmpty ? nil : $0 }
        guard requestedScope == nil || requestedScope == config.selectedProjectID
            || (showsAllProjects && config.projects.contains { $0.id == requestedScope }) else {
            throw TaskContextError.commandFailed(
                "The requested project is not the active dashboard. Select it before changing its queue.")
        }
        let contextStore = TaskContextStore(root: root)
        var contexts = try await contextStore.loadAvailableForDiscovery()
        let currentMode: QueueActivitySortMode
        if state.queueActivitySortMode == .manual {
            currentMode = .recentActivity
            state.queueActivitySortMode = currentMode
        } else {
            currentMode = state.queueActivitySortMode ?? .recentActivity
        }

        func presentation(_ contexts: [TaskContext]) throws -> (
            automatic: [DashboardTicket], displayed: [DashboardTicket]
        ) {
            let pinnedDates = Dictionary(uniqueKeysWithValues: contexts.compactMap { context in
                context.pinnedAt.map { (context.ticketID, $0) }
            })
            let automatic = QueueOrderStore.automaticTickets(
                dashboard.tickets,
                deferredTicketIDs: state.deferredTicketIDs,
                mode: currentMode,
                contexts: contexts)
            let automaticIDs = automatic.map(\.id)
            guard let override = try store.applicableOrder(
                automaticIDs: automaticIDs, sortMode: currentMode)
            else { return (automatic, automatic) }
            let manuallyOrdered = QueueOrderStore.orderedTickets(automatic, savedIDs: override)
            return (automatic, QueueOrderStore.prioritizingPins(
                manuallyOrdered, pinnedAtByTicketID: pinnedDates))
        }

        var projection = try presentation(contexts)
        switch arguments.dropFirst().first {
        case "list" where arguments.count == 2: break
        case "reset" where arguments.count == 2:
            try store.reset()
        case "move" where arguments.count == 4 || arguments.count == 5:
            let placement: QueuePlacement
            switch arguments[3] {
            case "top" where arguments.count == 4: placement = .top
            case "bottom" where arguments.count == 4: placement = .bottom
            case "before" where arguments.count == 5: placement = .before(arguments[4].uppercased())
            case "after" where arguments.count == 5: placement = .after(arguments[4].uppercased())
            default: throw SessionRegistrationError.usage
            }
            let automaticIDs = projection.automatic.map(\.id)
            try store.move(arguments[2].uppercased(), to: placement,
                tickets: dashboard.tickets, fallbackIDs: automaticIDs,
                currentIDs: projection.displayed.map(\.id),
                automaticBaselineIDs: automaticIDs, sortMode: currentMode)
        case "reorder" where arguments.count > 2:
            let automaticIDs = projection.automatic.map(\.id)
            try store.setOrder(arguments.dropFirst(2).map { $0.uppercased() },
                tickets: dashboard.tickets, fallbackIDs: automaticIDs,
                currentIDs: projection.displayed.map(\.id),
                automaticBaselineIDs: automaticIDs, sortMode: currentMode)
        case "pin" where arguments.count == 3,
             "unpin" where arguments.count == 3:
            let ticketID = arguments[2].uppercased()
            guard let ticket = dashboard.tickets.first(where: { $0.id == ticketID && $0.isOpen }) else {
                throw TaskContextError.commandFailed("No open task named \(ticketID) exists in this queue.")
            }
            if try await contextStore.load(ticketID: ticketID) == nil {
                let project = ticket.projectID.flatMap { id in config.projects.first { $0.id == id } }
                _ = try await contextStore.ensureContext(ticket: ticket, project: project)
            }
            _ = try await contextStore.setPinned(
                ticketID: ticketID,
                at: arguments[1] == "pin" ? Date() : nil)
            contexts = try await contextStore.loadAvailableForDiscovery()
        default: throw SessionRegistrationError.usage
        }
        projection = try presentation(contexts)
        try emit(["order": projection.displayed.map(\.id)])
        if arguments.dropFirst().first != "list" {
            try await stateStore.save(state)
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name(QueueOrderStore.changeNotificationName),
                object: nil, userInfo: nil, deliverImmediately: true)
        }
        notifyContextChanged()
    }

    private static func taskCommand(arguments: [String]) async throws {
        let root = supportDirectory(environment: ProcessInfo.processInfo.environment)
        let config = try loadConfiguration(from: root)
        let state = try await JSONLocalStateStore(url: root.appendingPathComponent("state.json")).load()
        let showsAllProjects = state.showsAllProjects ?? true
        let dashboardURLs = showsAllProjects
            ? ProjectCatalog.mergedDashboardURLs(in: config.projects)
            : [URL(fileURLWithPath: config.dashboardPath)]
        let repository = JSONDashboardRepository()
        guard arguments.count >= 3 else { throw SessionRegistrationError.usage }
        let action = arguments[1]
        let ticketID = arguments[2]
        switch action {
        case "create" where arguments.count == 5:
            guard let project = config.projects.first(where: { $0.id == ticketID && $0.archivedAt == nil }) else {
                throw TaskContextError.commandFailed("Unknown or archived project \(ticketID).")
            }
            let title = arguments[3].trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = arguments[4].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !summary.isEmpty, title.count <= 80, summary.count <= 200 else {
                throw TaskContextError.commandFailed("A deferred task needs a title (up to 80 characters) and summary (up to 200 characters).")
            }
            let targetURL = URL(fileURLWithPath: project.dashboardPath)
            let others = config.projects.filter { $0.id != project.id }.map { URL(fileURLWithPath: $0.dashboardPath) }
            for attempt in 0..<3 {
                let snapshot = try await repository.loadSnapshot(from: targetURL)
                if let existing = snapshot.document.tickets.first(where: {
                    $0.projectID == project.id && $0.title.caseInsensitiveCompare(title) == .orderedSame
                        && $0.summary.caseInsensitiveCompare(summary) == .orderedSame && $0.isOpen
                }) {
                    try emit(["taskID": existing.id, "created": "false"])
                    return
                }
                var known = snapshot.document.tickets
                for url in others { known += (try await repository.load(from: url)).tickets }
                let prefix = project.taskPrefix + "-"
                let numbers = known.compactMap { ticket -> (Int, Int)? in
                    guard ticket.id.uppercased().hasPrefix(prefix),
                          let number = Int(ticket.id.dropFirst(prefix.count)) else { return nil }
                    return (number, ticket.id.count - prefix.count)
                }
                let width = max(3, numbers.map { $0.1 }.max() ?? 0)
                let next = (numbers.map { $0.0 }.max() ?? 0) + 1
                let newID = "\(prefix)\(String(format: "%0\(width)d", next))"
                let day = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
                let ticket = DashboardTicket(id: newID, title: title, projectID: project.id,
                    category: project.name, status: "backlog", summary: summary,
                    next: "Review this deferred requirement and choose an owner.",
                    doneWhen: TaskContext.genericSuccessCriteria, updatedAt: day, createdAt: day)
                do {
                    _ = try await repository.createTicket(ticket, in: targetURL,
                        expectedRevision: snapshot.revision, checking: others)
                    _ = try await TaskContextStore(root: root).ensureContext(ticket: ticket)
                    try emit(["taskID": newID, "created": "true"])
                    notifyContextChanged()
                    return
                } catch {
                    if attempt == 2 { throw error }
                }
            }
            throw TaskContextError.commandFailed("The dashboard kept changing while creating the deferred task.")
        case "rename" where arguments.count > 3:
            let title = arguments.dropFirst(3).joined(separator: " ")
            let updated = try await mutateTicket(ticketID, in: dashboardURLs, repository: repository) { url, snapshot in
                try await repository.renameTicket(id: ticketID, to: title, in: url, expectedRevision: snapshot.revision)
            }
            try emit(["updated": ticketID, "title": updated.document.tickets.first { $0.id.caseInsensitiveCompare(ticketID) == .orderedSame }?.title ?? title])
        case "priority" where arguments.count == 4:
            let priority = arguments[3].lowercased()
            guard ["critical", "high", "medium", "low"].contains(priority) else {
                throw SessionRegistrationError.usage
            }
            _ = try await mutateTicket(ticketID, in: dashboardURLs, repository: repository) { url, snapshot in
                try await repository.setTicketPriority(id: ticketID, to: priority, in: url, expectedRevision: snapshot.revision)
            }
            try emit(["updated": ticketID, "priority": priority])
        case "status" where arguments.count == 4:
            let status = arguments[3].lowercased()
            let updated = try await mutateTicket(ticketID, in: dashboardURLs, repository: repository) { url, snapshot in
                try await repository.setTicketStatus(id: ticketID, to: status, in: url, expectedRevision: snapshot.revision)
            }
            if let ticket = updated.document.tickets.first(where: {
                $0.id.caseInsensitiveCompare(ticketID) == .orderedSame
            }), !ticket.isOpen {
                let contextStore = TaskContextStore(root: root)
                if try await contextStore.load(ticketID: ticket.id) != nil {
                    _ = try await contextStore.setPinned(ticketID: ticket.id, at: nil)
                }
            }
            guard ["resolved", "cancelled"].contains(status) else {
                try emit(["updated": ticketID, "status": status])
                break
            }
            // Completion is final: the task's runtime, worktrees, and branches go now.
            notifyContextChanged()
            let report = await completionCleanup(root: root, config: config).run(ticketID: ticketID)
            try emit(["updated": ticketID, "status": status, "cleanup": report.summary])
        case "link" where (5...6).contains(arguments.count):
            let updated = try await mutateTicket(ticketID, in: dashboardURLs, repository: repository) { url, snapshot in
                try await repository.addTicketLink(id: ticketID, label: arguments[4], url: arguments[3],
                    type: arguments.count == 6 ? arguments[5] : nil, in: url, expectedRevision: snapshot.revision)
            }
            let links = updated.document.tickets.first { $0.id.caseInsensitiveCompare(ticketID) == .orderedSame }?.links ?? []
            try emit(["updated": ticketID, "links": "\(links.count)"])
        default:
            throw SessionRegistrationError.usage
        }
        notifyContextChanged()
    }

    static func completionCleanup(root: URL, config: AppConfiguration) -> TaskCompletionCleanup {
        TaskCompletionCleanup(root: root,
            projectRepositories: config.projects.flatMap { [$0.repositoryPath, $0.workspacePath] },
            tmuxExecutable: config.tmuxExecutable)
    }

    /// cleanup <TASK-ID> | --completed | --orphans | --purge, each with optional --dry-run.
    private static func cleanupCommand(arguments: [String]) async throws {
        let options = Set(arguments.dropFirst().filter { $0.hasPrefix("--") })
        let targets = arguments.dropFirst().filter { !$0.hasPrefix("--") }
        let modes = options.subtracting(["--dry-run"])
        guard options.isSubset(of: ["--dry-run", "--completed", "--orphans", "--purge"]),
              modes.count + targets.count == 1 || (modes == ["--completed", "--orphans"] && targets.isEmpty) else {
            throw SessionRegistrationError.usage
        }
        let dryRun = options.contains("--dry-run")
        let root = supportDirectory(environment: ProcessInfo.processInfo.environment)
        let config = try loadConfiguration(from: root)
        let cleanup = completionCleanup(root: root, config: config)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        if modes == ["--purge"] {
            let purged = dryRun ? [] : await cleanup.purgeExpiredStaging()
            FileHandle.standardOutput.write(try encoder.encode(["purged": purged]))
            FileHandle.standardOutput.write(Data("\n".utf8))
            return
        }
        var reports: [TaskCleanupReport] = []
        if let ticketID = targets.first {
            reports.append(await cleanup.run(ticketID: ticketID, dryRun: dryRun))
        } else {
            // Every dashboard must load: an unknown open task must never look orphaned.
            let repository = JSONDashboardRepository()
            var tickets: [DashboardTicket] = []
            var seen = Set<String>()
            for path in config.projects.map(\.dashboardPath) where seen.insert(path).inserted {
                tickets += try await repository.loadSnapshot(from: URL(fileURLWithPath: path)).document.tickets
            }
            if modes.contains("--completed") {
                let open = Set(tickets.filter(\.isOpen).map(\.id))
                for ticket in tickets where ticket.isCompleted {
                    reports.append(await cleanup.run(ticketID: ticket.id, dryRun: dryRun, protecting: open))
                }
            }
            if modes.contains("--orphans") {
                reports.append(await cleanup.sweepOrphans(
                    openTicketIDs: Set(tickets.filter(\.isOpen).map(\.id)), dryRun: dryRun))
            }
        }
        if !dryRun {
            _ = await cleanup.purgeExpiredStaging()
            notifyContextChanged()
        }
        FileHandle.standardOutput.write(try encoder.encode(reports))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func mutateTicket(
        _ ticketID: String,
        in dashboardURLs: [URL],
        repository: JSONDashboardRepository,
        _ mutation: (URL, DashboardSnapshot) async throws -> DashboardSnapshot
    ) async throws -> DashboardSnapshot {
        for url in dashboardURLs {
            guard let snapshot = try? await repository.loadSnapshot(from: url),
                  snapshot.document.tickets.contains(where: {
                      $0.id.caseInsensitiveCompare(ticketID) == .orderedSame
                  }) else { continue }
            return try await mutation(url, snapshot)
        }
        throw DashboardMutationError.ticketNotFound(ticketID)
    }

    private static func placementCommand(arguments: [String]) async throws {
        let environment = ProcessInfo.processInfo.environment
        let root = supportDirectory(environment: environment)
        var launchID = environment["FOCUS_QUEUE_LAUNCH_ID"]
        var cwd = FileManager.default.currentDirectoryPath
        var prompt: String?
        var taskID: String?
        var createTask = true
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--no-create":
                createTask = false; index += 1
            case "--launch", "--cwd", "--prompt", "--task":
                guard index + 1 < arguments.count else { throw SessionRegistrationError.usage }
                let value = arguments[index + 1]
                switch arguments[index] {
                case "--launch": launchID = value
                case "--cwd": cwd = value
                case "--prompt": prompt = value
                case "--task": taskID = value
                default: break
                }
                index += 2
            default: throw SessionRegistrationError.usage
            }
        }
        let identity = TaskSessionBinding.providerSession(environment: environment)
        if launchID == nil { launchID = identity?.1 ?? UUID().uuidString.lowercased() }
        if prompt == nil, let receipt = AgentIntakeStore.load(root: root).first(where: { $0.launchID == launchID }),
           receipt.title?.localizedCaseInsensitiveCompare("Codex agent") != .orderedSame {
            prompt = receipt.title
        }
        let provider = identity?.0 ?? environment["FOCUS_QUEUE_PROVIDER"].flatMap(AgentProvider.init(rawValue:)) ?? .codex
        let capsule = try await AgentPlacementResolver(root: root).resolve(AgentPlacementRequest(
            launchID: launchID!, cwd: cwd, prompt: prompt, explicitTaskID: taskID,
            inheritedTaskID: environment["FOCUS_QUEUE_TASK_ID"],
            assignmentID: environment["FOCUS_QUEUE_SUBTASK_ID"], provider: provider,
            sessionID: identity?.1, tmuxName: environment["FOCUS_QUEUE_TMUX_NAME"],
            tmuxPaneID: environment["TMUX_PANE"], createTaskIfNeeded: createTask),
            configuration: try loadConfiguration(from: root))
        try emit(capsule)
        notifyContextChanged()
    }

    private static func agentsCommand(arguments: [String]) async throws {
        guard arguments == ["agents", "clear", "--all"] else {
            throw SessionRegistrationError.usage
        }
        let root = supportDirectory(environment: ProcessInfo.processInfo.environment)
        let stateStore = JSONLocalStateStore(url: root.appendingPathComponent("state.json"))
        let contextStore = TaskContextStore(root: root)
        let inbox = AgentRegistrationInbox(
            directory: root.appendingPathComponent("agent-registrations", isDirectory: true))
        let library = DurableLibraryStore(root: root)
        var state = try await stateStore.load()
        let contexts = try await contextStore.loadAll()
        let registrations = try await inbox.pendingRecords()
        let removedSessions = state.agentSessions.count
        let removedSubtasks = contexts.reduce(0) { $0 + $1.subtasks.count }

        _ = try await library.reconcile(state: state, contexts: contexts)
        let clearedContexts = try await contextStore.clearAllSubtasks()
        state.agentSessions.removeAll()
        try await stateStore.save(state)
        await inbox.acknowledge(registrations)
        _ = try await library.reconcile(state: state, contexts: clearedContexts)

        try emit(AgentQueueClearResult(
            status: "cleared", removedSessions: removedSessions,
            removedSubtasks: removedSubtasks,
            acknowledgedRegistrations: registrations.count,
            runningProcessesTerminated: false))
    }

    /// Recovers the exact tmux identity after a launch receipt race. The
    /// deterministic session name prevents this command from adopting an
    /// unrelated process or creating a replacement.
    private static func runtimeCommand(arguments: [String]) async throws {
        if arguments.count == 4, arguments[1] == "locate",
           let provider = AgentProvider(rawValue: arguments[2]),
           provider.isValidSessionID(arguments[3]) {
            try await locateRuntime(provider: provider, sessionID: arguments[3].lowercased())
            return
        }
        guard arguments.count == 4, arguments[1] == "repair" else {
            throw SessionRegistrationError.usage
        }
        let ticketID = arguments[2].uppercased()
        let subtaskID = arguments[3]
        let root = supportDirectory(environment: ProcessInfo.processInfo.environment)
        let store = TaskContextStore(root: root)
        guard let context = try await store.load(ticketID: ticketID),
              let subtask = context.subtasks.first(where: { $0.id == subtaskID }) else {
            throw TaskContextError.missingSubtask(subtaskID)
        }
        guard subtask.runtimeMode == nil || subtask.runtimeMode == .tmux else {
            throw TaskContextError.commandFailed(
                "This subtask was launched as a direct terminal session, so it has no tmux runtime to repair.")
        }
        let configuration = try loadConfiguration(from: root)
        guard let executable = configuration.tmuxExecutable
            ?? SetupEnvironment.executable("tmux") else {
            throw TmuxError.unavailable("The configured executable is missing.")
        }
        let runtime = try await TmuxController().inspectAgent(
            taskID: ticketID, subtaskID: subtaskID, executable: executable)
        if let saved = subtask.tmux, saved != runtime { throw TmuxError.changed }
        let repaired = try await store.setManagedRuntime(
            ticketID: ticketID, subtaskID: subtaskID, tmux: runtime)
        await mirrorContext(repaired, root: root)
        notifyContextChanged()
        try emit(RuntimeRepairResult(
            status: "repaired", taskID: ticketID,
            subtaskID: subtaskID, runtime: runtime))
    }

    private static func tmuxCommand(arguments: [String]) async throws {
        guard arguments.count >= 2 else { throw SessionRegistrationError.usage }
        if arguments[1] == "ssh-command", arguments.count == 4 {
            print(try TmuxController.sshCommand(host: arguments[2], name: arguments[3]))
            return
        }
        let environment = ProcessInfo.processInfo.environment
        let configuration = try loadConfiguration(from: supportDirectory(environment: environment))
        guard let executable = configuration.tmuxExecutable ?? SetupEnvironment.executable("tmux") else {
            throw TmuxError.unavailable("Install tmux on this host, then choose its executable in setup.")
        }
        let persistence = ["start", "start-agent", "save", "restore", "persistence"].contains(arguments[1])
            ? try TmuxPersistence.prepare(executable: executable, supportDirectory: supportDirectory(environment: environment)) : nil
        let serverName: String
        if arguments[1] == "reflow", arguments.count == 5, arguments[3] == "--server" {
            try TmuxController.validateName(arguments[4]); serverName = arguments[4]
        } else if arguments[1] == "reference", [6, 10].contains(arguments.count),
                  arguments[arguments.count - 2] == "--server" {
            try TmuxController.validateName(arguments.last!); serverName = arguments.last!
        } else { serverName = TmuxController.serverName }
        let controller = TmuxController(serverName: serverName, configurationPath: persistence?.configurationURL.path ?? "/dev/null")
        switch arguments[1] {
        case "save" where arguments.count == 2:
            try await persistence!.enable()
            try await persistence!.save()
            print("Saved the managed tmux layout.")
        case "restore" where arguments.count == 2:
            try await persistence!.restoreLayout()
            print(TmuxPersistenceStatus.restoreExplanation)
        case "persistence" where arguments.count == 2:
            let status = persistence!.status()
            try emit(["available": String(status.available), "canRestore": String(status.canRestore),
                "directory": status.snapshotDirectory, "intervalMinutes": String(status.saveIntervalMinutes)])
        case "panes" where arguments.count == 3:
            let panes = try await controller.panes(name: arguments[2], executable: executable)
            try emit(panes.map { ["pane": $0.id, "session": $0.reference.name,
                "tab": String($0.windowIndex + 1), "agent": $0.subtaskID] })
        case "reflow" where arguments.count == 3 || (arguments.count == 5 && arguments[3] == "--server"):
            try await controller.reflow(name: arguments[2], executable: executable)
        case "arrange" where arguments.count == 3:
            try await controller.setAutomatic(name: arguments[2], executable: executable, enabled: true)
        case "manual" where arguments.count == 3:
            try await controller.setAutomatic(name: arguments[2], executable: executable, enabled: false)
        case "list" where arguments.count == 2:
            try emit(try await controller.list(executable: executable))
        case "reference" where arguments.count == 6 || arguments.count == 10:
            guard arguments[arguments.count - 2] == "--server",
                  arguments[3].range(of: "^%[0-9]+$", options: .regularExpression) != nil,
                  let pane = try await controller.panes(name: arguments[2], executable: executable)
                    .first(where: { $0.id == arguments[3] }) else { throw TmuxError.changed }
            if arguments.count == 10 {
                guard arguments[4] == "--task", arguments[6] == "--agent" else {
                    throw SessionRegistrationError.usage
                }
                _ = try await controller.verifyAgent(pane.reference, taskID: arguments[5],
                    subtaskID: arguments[7], executable: executable)
            } else { _ = try await controller.verify(pane.reference) }
            try emit(pane.reference)
        case "attach-reference" where arguments.count == 3 || arguments.count == 7:
            guard let data = arguments[2].data(using: .utf8),
                  let saved = try? JSONDecoder().decode(TmuxSessionReference.self, from: data),
                  saved.executable == executable else { throw TmuxError.changed }
            if arguments.count == 7 {
                guard arguments[3] == "--task", arguments[5] == "--agent" else {
                    throw SessionRegistrationError.usage
                }
                _ = try await controller.verifyAgent(
                    saved, taskID: arguments[4], subtaskID: arguments[6], executable: executable)
            } else {
                _ = try await controller.verify(saved)
            }
            try await controller.select(saved)
            guard isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0 else {
                throw TmuxError.unavailable("Attach needs an interactive terminal. Use ssh -t when connecting remotely.")
            }
            try TmuxController.exec(TmuxController.attachCommand(reference: saved))
        case "attach" where arguments.count == 3 || (arguments.count == 5 && arguments[3] == "--pane"):
            if arguments.count == 5 {
                guard arguments[4].range(of: "^%[0-9]+$", options: .regularExpression) != nil,
                      let pane = try await controller.panes(name: arguments[2], executable: executable)
                        .first(where: { $0.id == arguments[4] }) else { throw TmuxError.changed }
                try await controller.select(pane.reference)
            } else { _ = try await controller.inspect(name: arguments[2], executable: executable) }
            guard isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0 else {
                throw TmuxError.unavailable("Attach needs an interactive terminal. Use ssh -t when connecting remotely.")
            }
            try TmuxController.exec(TmuxController.attachCommand(name: arguments[2], executable: executable))
        case "start-agent" where arguments.count >= 6:
            let taskID = arguments[2]
            let agentID = arguments[3]
            var remaining = Array(arguments.dropFirst(4))
            var directory = FileManager.default.currentDirectoryPath
            if remaining.first == "--cwd" {
                guard remaining.count >= 3 else { throw SessionRegistrationError.usage }
                directory = remaining[1]
                remaining.removeFirst(2)
            }
            guard remaining.first == "--", remaining.count >= 2 else {
                throw SessionRegistrationError.usage
            }
            remaining.removeFirst()
            let reference = try await controller.startAgent(
                taskID: taskID, subtaskID: agentID, directory: directory,
                command: remaining, executable: executable)
            var warnings: [String] = []
            do { try await persistence!.enable() }
            catch { warnings.append("persistence: \(error.localizedDescription)") }
            let rawHelper = CommandLine.arguments[0]
            let helper = rawHelper.hasPrefix("/") ? rawHelper
                : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent(rawHelper).standardizedFileURL.path
            do {
                try await controller.configureTask(
                    name: reference.name, executable: executable, helper: helper,
                    supportDirectory: supportDirectory(environment: environment))
            } catch { warnings.append("layout hooks: \(error.localizedDescription)") }
            do { try await controller.reflow(name: reference.name, executable: executable) }
            catch { warnings.append("initial layout: \(error.localizedDescription)") }
            try emit(reference)
            if !warnings.isEmpty {
                FileHandle.standardError.write(Data(
                    "Agent pane started; optional tmux setup needs attention: \(warnings.joined(separator: "; "))\n".utf8))
            }
        case "start" where arguments.count >= 3:
            var remaining = Array(arguments.dropFirst(3))
            var directory = FileManager.default.currentDirectoryPath
            if remaining.first == "--cwd" {
                guard remaining.count >= 2 else { throw SessionRegistrationError.usage }
                directory = remaining[1]
                remaining.removeFirst(2)
            }
            if remaining.first == "--" { remaining.removeFirst() }
            else if !remaining.isEmpty { throw SessionRegistrationError.usage }
            let command = remaining.isEmpty ? [InteractiveAgentShell.executable(), "-l"] : remaining
            try emit(try await controller.start(name: arguments[2], directory: directory, command: command, executable: executable))
            try await persistence?.enable()
        default: throw SessionRegistrationError.usage
        }
    }

    private static func libraryCommand(arguments: [String]) async throws {
        guard arguments.count >= 2 else { throw SessionRegistrationError.usage }
        let root = supportDirectory(environment: ProcessInfo.processInfo.environment)
        let library = DurableLibraryStore(root: root)
        switch arguments[1] {
        case "migrate" where arguments.count == 2:
            try emit(try await library.reconcile())
        case "status" where arguments.count == 2:
            try emit(try await library.summary())
        case "document" where (4...5).contains(arguments.count):
            let url = URL(fileURLWithPath: arguments[3]).standardizedFileURL
            let kind = arguments.count == 5 ? arguments[4] : "reference"
            guard url.pathExtension.lowercased() == "md",
                ["guide", "architecture", "reference"].contains(kind) else {
                throw SessionRegistrationError.invalidLibraryDocument
            }
            let snapshot = try await library.snapshot()
            guard let task = snapshot.tasks.first(where: {
                $0.ticketID.caseInsensitiveCompare(arguments[2]) == .orderedSame
            }) else { throw SessionRegistrationError.missingLibraryTask(arguments[2]) }
            try await library.captureDocument(at: url, kind: kind, ticketID: task.ticketID)
            try emit(["status": "registered", "taskID": task.ticketID, "path": url.path, "kind": kind])
        case "task" where arguments.count == 3:
            let snapshot = try await library.snapshot()
            guard let task = snapshot.tasks.first(where: {
                $0.ticketID.caseInsensitiveCompare(arguments[2]) == .orderedSame
            }) else { throw SessionRegistrationError.missingLibraryTask(arguments[2]) }
            let assignments = snapshot.assignments.filter { $0.taskID == task.id }
            let sessions = Set(assignments.map(\.sessionID))
            try emit(LibraryTaskView(task: task,
                sessions: snapshot.sessions.filter { sessions.contains($0.id) },
                assignments: assignments,
                repositories: snapshot.repositories.filter { $0.taskID == task.id },
                documents: snapshot.documents.filter { $0.taskID == task.id },
                executionLocators: snapshot.executionLocators.filter { sessions.contains($0.sessionID) }))
        case "export" where arguments.count == 3:
            let destination = URL(fileURLWithPath: arguments[2])
            try await library.export(to: destination)
            try emit(["status": "exported", "destination": destination.path])
        case "restore" where arguments.count == 3:
            try DurableLibraryStore.restore(from: URL(fileURLWithPath: arguments[2]), to: root)
            try emit(["status": "restored", "supportDirectory": root.path])
        default: throw SessionRegistrationError.usage
        }
    }

    private static func architectureCommand(arguments: [String]) async throws {
        guard (2...3).contains(arguments.count) else { throw SessionRegistrationError.usage }
        let root = supportDirectory(environment: ProcessInfo.processInfo.environment)
        guard let context = try await TaskContextStore(root: root).load(ticketID: arguments[1]) else {
            throw TaskContextError.missingContext(arguments[1])
        }
        guard let repository = arguments.count == 3 ? arguments[2]
            : context.repositoryPath ?? context.worktreePath,
            !repository.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SessionRegistrationError.missingArchitectureRepository
        }
        let report = try ArchitectureContextService.generate(
            repositoryRoot: URL(fileURLWithPath: repository),
            outputDirectory: context.contextDirectory.appendingPathComponent("architecture"),
            cardDirectory: nil, budget: .init())
        let library = DurableLibraryStore(root: root)
        for url in [report.indexURL, report.stateURL] + report.cardURLs {
            try await library.captureDocument(at: url, kind: "architecture", ticketID: context.ticketID)
        }
        try emit(ArchitectureCLIResult(taskID: context.ticketID, indexPath: report.indexURL.path,
            statePath: report.stateURL.path, cardCount: report.cardCount,
            sourceCount: report.sourceCount, truncated: report.truncated))
    }

    private static func emit<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        recordAgentCommand(CommandLine.arguments.dropFirst().first ?? "command",
                           output: String(decoding: data, as: UTF8.self))
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func recordAgentCommand(_ command: String, output: String) {
        let environment = ProcessInfo.processInfo.environment
        guard environment["FOCUS_QUEUE_PROVIDER"] != nil else { return }
        PromptUsageMetrics.record(PromptUsageEvent(
            source: "agent_command", component: command,
            provider: environment["FOCUS_QUEUE_PROVIDER"], taskID: environment["FOCUS_QUEUE_TASK_ID"],
            characters: output.count, runID: UUID().uuidString, scope: "tool_output_estimate"),
            in: supportDirectory(environment: environment))
    }

    private static func mirrorContext(_ context: TaskContext, root: URL) async {
        do { _ = try await DurableLibraryStore(root: root).reconcile(contexts: [context]) }
        catch { historyWarning(error) }
    }

    private static func historyWarning(_ error: any Error) {
        FileHandle.standardError.write(Data(
            "Canonical files were preserved; durable history needs attention. Run library migrate to retry: \(error.localizedDescription)\n".utf8))
    }

    /// Read-only connection and saved-locator inspection, usable outside a terminal.
    private static func diagnose(arguments: [String]) async throws {
        guard arguments.count == 2 else { throw SessionRegistrationError.usage }
        let root = supportDirectory(environment: ProcessInfo.processInfo.environment)
        let config = try loadConfiguration(from: root)
        let connection = try await WezTermConnection.resolve(configuration: config.wezTerm,
            runner: FoundationProcessRunner())
        guard connection.result.succeeded else {
            throw WezTermError.actionFailed(connection.result.standardError)
        }
        let panes = try JSONDecoder().decode([WezTermPane].self, from: Data(connection.result.standardOutput.utf8))
        let live = try await WezTermController().listRunningAgents(configuration: connection.configuration)
        let state = try await JSONLocalStateStore(url: root.appendingPathComponent("state.json")).load()
        let sessions: [[String: Any]] = state.agentSessions.filter {
            $0.ticketID.caseInsensitiveCompare(arguments[1]) == .orderedSame
        }.map { session in
            var directory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: session.workingDirectory, isDirectory: &directory)
            let running = live.first { $0.provider == session.provider && $0.sessionID.caseInsensitiveCompare(session.sessionID) == .orderedSame }
            return ["provider": session.provider.rawValue, "sessionID": session.sessionID,
                    "workingDirectory": session.workingDirectory, "directoryExists": exists && directory.boolValue,
                    "verifiedLivePane": running.map { $0.pane.paneID as Any } ?? NSNull()]
        }
        let result: [String: Any] = ["mode": "read-only", "taskID": arguments[1].uppercased(),
            "socketPath": connection.configuration.socketPath ?? ProcessInfo.processInfo.environment["WEZTERM_UNIX_SOCKET"] ?? "default",
            "paneCount": panes.count, "sessions": sessions]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    /// Managed panes export their task and agent IDs, so agents may omit them. Each command has a
    /// fixed arity, so a short argument list is unambiguous.
    static func withEnvironmentIdentity(_ arguments: [String], environment: [String: String]) -> [String] {
        guard let command = arguments.first,
              let task = environment["FOCUS_QUEUE_TASK_ID"].flatMap({ $0.isEmpty ? nil : $0 }) else { return arguments }
        let taskAndAgent = ["progress": 5, "complete": 4, "attention": 5, "result": 4, "log": 4,
                            "identify": 5, "review-push": 3, "workspace": 4, "brief": 3]
        let taskOnly = ["attach": 2, "context": 2, "plan": 2]
        if let arity = taskAndAgent[command], arguments.count == arity - 2,
           let agent = environment["FOCUS_QUEUE_SUBTASK_ID"], !agent.isEmpty {
            return [command, task, agent] + arguments.dropFirst()
        }
        if let arity = taskOnly[command], arguments.count == arity - 1 {
            return [command, task] + arguments.dropFirst()
        }
        return arguments
    }

    private static func register(arguments: [String]) async throws {
        guard arguments.count == 2 else { throw SessionRegistrationError.usage }
        let environment = ProcessInfo.processInfo.environment
        guard let (provider, sessionID) = TaskSessionBinding.providerSession(environment: environment),
              UUID(uuidString: sessionID) != nil else { throw SessionRegistrationError.missingSessionIdentity }
        // A Codex sub-agent inherits its parent's history, including the startup
        // instruction to attach, but exports its own thread UUID. Attaching that
        // thread would add a second agent for one Codex session.
        if provider == .codex, let parent = CodexSessionLineage.subagentParent(of: sessionID) {
            var output = ["status": "subagent", "provider": provider.rawValue,
                          "sessionID": sessionID.lowercased(), "parentSessionID": parent,
                          "reason": ExternalAgentRegistry.codexSubagentReason]
            output["taskID"] = environment["FOCUS_QUEUE_TASK_ID"]
            output["subtaskID"] = environment["FOCUS_QUEUE_SUBTASK_ID"]
            try emit(output)
            return
        }
        let event = ExternalAgentEvent(sessionID: sessionID, cwd: FileManager.default.currentDirectoryPath,
            hookEventName: "ExplicitAttach")
        try await registerEvent(event, provider: provider, explicitTaskID: arguments[1], environment: environment)
    }

    /// Provider status hooks run on every tool call, so this path stays quiet and
    /// cheap: no output, no registration, and a failure never reaches the agent.
    /// The app reads the changed context on its next refresh.
    private static func statusEvent(arguments: [String]) async {
        let date = Date()
        guard arguments.count == 3, arguments[1] == "--provider",
              let provider = AgentProvider(rawValue: arguments[2]) else { return }
        var data = Data()
        while data.count <= 1_048_576,
              let chunk = try? FileHandle.standardInput.read(upToCount: min(65_536, 1_048_577 - data.count)),
              !chunk.isEmpty {
            data.append(chunk)
        }
        let environment = ProcessInfo.processInfo.environment
        guard data.count <= 1_048_576,
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        _ = try? await AgentHookStatus.apply(payload: payload, provider: provider, environment: environment,
            store: TaskContextStore(root: supportDirectory(environment: environment)), date: date)
    }

    private static func registerEvent(arguments: [String]) async throws {
        if ProcessInfo.processInfo.environment["FOCUS_QUEUE_EXTRACTION_CHILD"] == "1" {
            try emit(["status": "ignored"])
            return
        }
        var provider: AgentProvider?
        var taskID: String?
        var index = 1
        while index < arguments.count {
            guard index + 1 < arguments.count else { throw SessionRegistrationError.usage }
            switch arguments[index] {
            case "--provider": provider = AgentProvider(rawValue: arguments[index + 1])
            case "--task": taskID = arguments[index + 1]
            default: throw SessionRegistrationError.usage
            }
            index += 2
        }
        guard let provider else { throw SessionRegistrationError.usage }
        var data = Data()
        while data.count <= 1_048_576 {
            guard let chunk = try FileHandle.standardInput.read(upToCount: min(65_536, 1_048_577 - data.count)), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= 1_048_576 else { throw TaskContextError.commandFailed("Registration event exceeds 1 MB.") }
        let event = try JSONDecoder().decode(ExternalAgentEvent.self, from: data)
        try await registerEvent(event, provider: provider, explicitTaskID: taskID,
            environment: ProcessInfo.processInfo.environment)
    }

    private static func registerEvent(_ event: ExternalAgentEvent, provider: AgentProvider,
                                      explicitTaskID: String?, environment: [String: String]) async throws {
        let root = supportDirectory(environment: environment)
        let config = try loadConfiguration(from: root)
        let launchID = event.isSubagent
            ? (event.providerSessionID ?? event.sessionID.lowercased())
            : (environment["FOCUS_QUEUE_LAUNCH_ID"]
                ?? event.providerSessionID ?? UUID().uuidString.lowercased())
        let placement = try? await AgentPlacementResolver(root: root).resolve(AgentPlacementRequest(
            launchID: launchID, cwd: event.cwd, prompt: event.prompt,
            explicitTaskID: explicitTaskID, inheritedTaskID: environment["FOCUS_QUEUE_TASK_ID"],
            // An explicit attach is recovery authority for the task only. Do not
            // recreate a stale inherited assignment that the queue has removed.
            assignmentID: explicitTaskID == nil && !event.isSubagent
                ? environment["FOCUS_QUEUE_SUBTASK_ID"] : nil,
            provider: provider, sessionID: event.providerSessionID,
            tmuxName: environment["FOCUS_QUEUE_TMUX_NAME"], tmuxPaneID: environment["TMUX_PANE"],
            createTaskIfNeeded: !event.isSubagent
                && event.prompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false),
            configuration: config)
        if placement?.status == .blockedConflict {
            throw TaskContextError.commandFailed(placement?.reason ?? "Agent placement conflicts with its working directory.")
        }
        var runtime: TmuxSessionReference?
        var directPane: Int?
        if !event.isSubagent, let name = environment["FOCUS_QUEUE_TMUX_NAME"],
           let paneID = environment["TMUX_PANE"], let executable = config.tmuxExecutable ?? SetupEnvironment.executable("tmux") {
            runtime = try? await TmuxController().panes(name: name, executable: executable)
                .first(where: { $0.id == paneID })?.reference
        } else if !event.isSubagent, environment["TMUX"] == nil,
                  let pane = environment["WEZTERM_PANE"].flatMap(Int.init), pane >= 0 {
            directPane = pane
        }
        let registry = ExternalAgentRegistry(root: root)
        let record = try await registry.register(event, provider: provider,
            explicitTaskID: explicitTaskID ?? (event.isSubagent ? nil : placement?.taskID),
            environment: environment, tmux: runtime, paneID: directPane,
            socketPath: environment["WEZTERM_UNIX_SOCKET"])
        _ = try? AgentPlacementCapsuleStore(root: root).finalize(
            launchID: launchID, taskID: record.taskID, agentID: record.subtaskID,
            sessionID: record.sessionID)
        if let recordSession = record.session, FileManager.default.isExecutableFile(atPath: config.wezTerm.executable) {
            do {
                var session = recordSession
                if session.taskTitle == nil,
                   let context = try? await TaskContextStore(root: root).load(ticketID: session.ticketID) {
                    session.taskTitle = context.title
                }
                let controller = WezTermController()
                if session.tmux != nil { try await controller.labelTmuxClients(session: session, configuration: config.wezTerm) }
                else if let pane = session.paneID {
                    var connection = config.wezTerm
                    connection.socketPath = record.socketPath ?? connection.socketPath
                    try await controller.attach(paneID: pane, tabTitle: session.terminalTabTitle,
                        windowTitle: session.terminalWindowTitle, configuration: connection)
                }
            } catch { FileHandle.standardError.write(Data("Registered; terminal labels will retry when the connection is available.\n".utf8)) }
        }
        notifyContextChanged()
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(AgentRegistrationInbox.notificationName), object: nil, userInfo: nil, deliverImmediately: true)
        var output: [String: String] = ["status": record.status, "registrationID": record.id, "provider": provider.rawValue]
        output["sessionID"] = record.sessionID; output["taskID"] = record.taskID; output["subtaskID"] = record.subtaskID
        output["agentID"] = record.agentID; output["parentSessionID"] = record.parentSessionID
        output["placementPath"] = placement?.capsulePath
        try emit(output)
        if config.dataPlacementEnabled == true,
           environment["FOCUS_QUEUE_EXTRACTION_CHILD"] != "1",
           event.hookEventName == "UserPromptSubmit", !event.isSubagent,
           let prompt = event.prompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !prompt.isEmpty, prompt.count <= 4_000,
           let projectID = placement?.projectID {
            // The provider hook has a short deadline. Let extraction finish in a child
            // process while registration returns immediately to the user's agent.
            let script = root.appendingPathComponent("automation/Scripts/focus_queue_extractor.py")
            if FileManager.default.fileExists(atPath: script.path) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                var arguments = [script.path, "extract", "--prompt-stdin", "--project", projectID,
                                 "--provider", provider.rawValue, "--apply"]
                if let taskID = record.taskID { arguments += ["--task", taskID] }
                process.arguments = arguments
                var childEnvironment = environment
                childEnvironment["FOCUS_QUEUE_EXTRACTION_CHILD"] = "1"
                childEnvironment["FOCUS_QUEUE_SESSION_EXECUTABLE"] = CommandLine.arguments[0]
                process.environment = childEnvironment
                let input = Pipe()
                process.standardInput = input
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    input.fileHandleForWriting.write(Data(prompt.utf8))
                    try? input.fileHandleForWriting.close()
                } catch {
                    try? input.fileHandleForWriting.close()
                }
            }
        }
    }

    private static func dataPlacement(arguments: [String]) async throws {
        guard arguments.count == 2, ["on", "off", "status"].contains(arguments[1]) else {
            throw SessionRegistrationError.usage
        }
        let root = supportDirectory(environment: ProcessInfo.processInfo.environment)
        let repository = JSONConfigurationRepository(url: root.appendingPathComponent("config.json"))
        var configuration = try loadConfiguration(from: root)
        if arguments[1] != "status" {
            configuration.dataPlacementEnabled = arguments[1] == "on"
            try await repository.save(configuration)
        }
        try emit(["dataPlacementEnabled": configuration.dataPlacementEnabled == true])
    }

    private static func dataCommand(arguments: [String]) async throws {
        let root = supportDirectory(environment: ProcessInfo.processInfo.environment)
        if arguments == ["data", "ensure"] {
            try emit(ScopedDataPlacement.ensure(root: root, configuration: loadConfiguration(from: root)))
            return
        }
        guard arguments.count == 5, arguments[1] == "place" else {
            throw SessionRegistrationError.usage
        }
        let receipt = try await ScopedDataPlacement.place(
            scope: arguments[2], targetID: arguments[3], text: arguments[4],
            root: root, configuration: loadConfiguration(from: root))
        if receipt.added { notifyContextChanged() }
        try emit(receipt)
    }

    private static func locateRuntime(provider: AgentProvider, sessionID: String) async throws {
        do {
            let controller = WezTermController()
            let processes = try await controller.knownProviderProcesses(provider: provider).resolved
            guard let process = processes.first(where: { $0.sessionID == sessionID }) else {
                let complete = try await controller.knownProviderProcesses(provider: provider, requireComplete: true)
                if let appeared = complete.resolved.first(where: { $0.sessionID == sessionID }) {
                    try emit(RuntimeLocationResult(
                        status: "running", sessionID: sessionID, processID: Int(appeared.processID)))
                    return
                }
                // "Stopped" is only emitted when no live process could plausibly
                // own the requested session; unrelated identity-less processes
                // (another project's agent, a daemon) never block a resume.
                var blocked = false
                for process in complete.unresolved {
                    if await controller.unresolvedProcessCouldOwn(process, sessionID: sessionID) {
                        blocked = true
                        break
                    }
                }
                guard !blocked else {
                    throw WezTermError.actionFailed("A provider process has no exact session identity yet. Retry after startup.")
                }
                try emit(RuntimeLocationResult(status: "stopped", sessionID: sessionID)); return
            }
            var result = RuntimeLocationResult(
                status: "running", sessionID: sessionID, processID: Int(process.processID))
            let config = try loadConfiguration(from: supportDirectory(environment: ProcessInfo.processInfo.environment))
            if let tty = process.tty, let executable = config.tmuxExecutable ?? SetupEnvironment.executable("tmux"),
               let pane = try? await TmuxController().panes(executable: executable).first(where: { $0.reference.tty == tty }) {
                result.runtime = "tmux"
                result.tmuxName = pane.reference.name
                result.name = pane.reference.name
                result.serverPID = pane.reference.serverPID
                result.createdAt = pane.reference.createdAt
                result.paneID = pane.reference.paneID
                result.panePID = pane.reference.panePID
                result.tty = pane.reference.tty
                result.executable = pane.reference.executable
                result.agentID = pane.subtaskID
            }
            try emit(result)
        } catch {
            try emit(RuntimeLocationResult(
                status: "unknown", sessionID: sessionID, reason: error.localizedDescription))
        }
    }

    private static func supportDirectory(environment: [String: String]) -> URL {
        if let path = environment["FOCUS_QUEUE_SUPPORT_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ECC Focus Queue", isDirectory: true)
    }

    private static func updateContext(arguments: [String]) async throws {
        guard let command = arguments.first else { throw SessionRegistrationError.usage }
        let environment = ProcessInfo.processInfo.environment
        let root = supportDirectory(environment: environment)
        let store = TaskContextStore(root: root)
        if command == "log", arguments.count == 4 {
            try await store.appendAgentLog(ticketID: arguments[1], subtaskID: arguments[2], entry: arguments[3])
            notifyContextChanged()
            try emit(["appended": true])
            return
        }
        if ["review-push", "workspace"].contains(command) {
            guard arguments.count == (command == "workspace" ? 4 : 3),
                  let context = try await store.load(ticketID: arguments[1]),
                  let subtask = context.subtasks.first(where: { $0.id == arguments[2] }) else {
                throw SessionRegistrationError.usage
            }
            if command == "workspace" {
                var workspace = try await TaskWorktreeManager().workspace(at: arguments[3])
                if workspace.path == subtask.workspace?.path {
                    workspace.managed = subtask.workspace?.managed ?? false
                    workspace.baseBranch = subtask.workspace?.baseBranch ?? workspace.baseBranch
                    workspace.baseCommit = subtask.workspace?.baseCommit ?? workspace.baseCommit
                }
                let updated = try await store.setAgentWorkspace(ticketID: context.ticketID, subtaskID: subtask.id, workspace: workspace)
                await mirrorContext(updated, root: root)
                notifyContextChanged()
                try emit(workspace)
            } else {
                let configuration = try loadConfiguration(from: root)
                let receipt = try await PushReviewer().review(context: context, subtask: subtask,
                    configuration: configuration.verifier, supportDirectory: root)
                try emit(receipt)
                if !receipt.accepted {
                    throw TaskContextError.commandFailed("Push review rejected. Correct the reported additions, commit the correction, and run review-push again before pushing.")
                }
            }
            return
        }
        if command == "brief", arguments.count == 3 {
            guard let context = try await store.load(ticketID: arguments[1]),
                  let subtask = context.subtasks.first(where: { $0.id == arguments[2] }) else {
                throw TaskContextError.missingSubtask(arguments[2])
            }
            let output = subtask.includeInitializationPrompt
                ? context.agentPrompt(subtask: subtask) : context.agentBootstrap(subtask: subtask)
            recordAgentCommand("brief", output: output)
            print(output)
            return
        }
        if command == "plan", arguments.count == 2 {
            let output = try await store.readPlan(ticketID: arguments[1])
            recordAgentCommand("plan", output: output)
            FileHandle.standardOutput.write(Data(output.utf8))
            return
        }
        if command == "add", arguments.count == 5, let provider = AgentProvider(rawValue: arguments[2]) {
            let title = arguments[3].trimmingCharacters(in: .whitespacesAndNewlines)
            let description = arguments[4].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !description.isEmpty else { throw SessionRegistrationError.usage }
            let subtask = TaskSubtask(title: String(title.prefix(200)),
                assignmentDescription: String(description.prefix(2_000)), provider: provider,
                runtimeMode: nil)
            let context = try await store.upsertSubtask(ticketID: arguments[1], subtask: subtask)
            await mirrorContext(context, root: root)
            FileHandle.standardOutput.write(try JSONEncoder().encode(subtask))
            FileHandle.standardOutput.write(Data("\n".utf8))
            notifyContextChanged()
            return
        }
        if command == "rename", arguments.count == 4 {
            let context = try await store.renameSubtask(ticketID: arguments[1], subtaskID: arguments[2], title: arguments[3])
            await mirrorContext(context, root: root)
            FileHandle.standardOutput.write(try JSONEncoder().encode(context.subtasks.first { $0.id == arguments[2] }))
            FileHandle.standardOutput.write(Data("\n".utf8))
            notifyContextChanged()
            return
        }
        if command == "identify", arguments.count == 5 {
            let context = try await store.renameSubtask(
                ticketID: arguments[1], subtaskID: arguments[2], title: arguments[3],
                assignmentDescription: arguments[4])
            await mirrorContext(context, root: root)
            FileHandle.standardOutput.write(try JSONEncoder().encode(
                context.subtasks.first { $0.id == arguments[2] }))
            FileHandle.standardOutput.write(Data("\n".utf8))
            notifyContextChanged()
            return
        }
        if command == "archive-agent", arguments.count == 3 {
            guard let context = try await store.load(ticketID: arguments[1]),
                  context.subtasks.contains(where: { $0.id == arguments[2] && $0.hasAgent }) else {
                throw SessionRegistrationError.usage
            }
            let updated = try await store.archiveAgent(
                ticketID: context.ticketID, subtaskID: arguments[2])
            await mirrorContext(updated, root: root)
            notifyContextChanged()
            try emit([
                "status": "archived", "taskID": context.ticketID,
                "subtaskID": arguments[2],
            ])
            return
        }
        if command == "associate", arguments.count == 4 {
            let updated = try await store.associateAgent(ticketID: arguments[1], agentID: arguments[2], subtaskID: arguments[3])
            await mirrorContext(updated, root: root)
            notifyContextChanged()
            try emit(updated)
            return
        }
        if command == "attention" || command == "result" {
            let isResult = command == "result"
            guard arguments.count == (isResult ? 4 : 5) else { throw SessionRegistrationError.usage }
            let attention = isResult ? nil : AgentAttention(rawValue: arguments[3])
            guard isResult || attention != nil else { throw SessionRegistrationError.usage }
            let updated = try await store.reportAttention(ticketID: arguments[1], subtaskID: arguments[2],
                attention: attention, summary: arguments[isResult ? 3 : 4], result: isResult)
            await mirrorContext(updated, root: root)
            notifyContextChanged()
            try emit(updated)
            return
        }
        if command == "context", arguments.count == 2 {
            guard let context = try await store.load(ticketID: arguments[1]) else { throw TaskContextError.missingContext(arguments[1]) }
            // Document paths are derived, not stored, so add them for readers of the task state.
            guard var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(context)) as? [String: Any] else {
                throw TaskContextError.commandFailed("Task context did not encode as an object.")
            }
            object["agentLogPath"] = context.agentLogURL.path
            object["dataPath"] = context.dataURL.path
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            recordAgentCommand("context", output: String(decoding: data, as: UTF8.self))
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            return
        }
        let status: TaskSubtaskStatus
        let summary: String
        if command == "complete", arguments.count == 4 {
            status = .completed; summary = arguments[3]
        } else if command == "progress", arguments.count == 5, let supplied = TaskSubtaskStatus(rawValue: arguments[3]) {
            status = supplied; summary = arguments[4]
        } else { throw SessionRegistrationError.usage }
        let identity = TaskSessionBinding.providerSession(environment: environment)
        let context = try await store.load(ticketID: arguments[1])
        let assignedProvider = context?.subtasks.first(where: { $0.id == arguments[2] })?.provider
        // An orchestrator can report reviewed completion for another provider without taking its identity.
        let isAssignedAgent = TaskSessionBinding.subtaskID(ticketID: arguments[1], environment: environment) == arguments[2]
        let sessionID = isAssignedAgent && identity?.0 == assignedProvider ? identity?.1 : nil
        let updated = try await store.updateProgress(ticketID: arguments[1], subtaskID: arguments[2], status: status, summary: summary, sessionID: sessionID)
        await mirrorContext(updated, root: root)
        notifyContextChanged()
        let result = ["taskID": arguments[1].uppercased(), "subtaskID": arguments[2], "status": status.rawValue]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func notifyContextChanged() {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(AgentRegistrationInbox.notificationName), object: nil, userInfo: nil, deliverImmediately: true)
    }

    private static func loadConfiguration(from supportDirectory: URL) throws -> AppConfiguration {
        let url = supportDirectory.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return SetupEnvironment.starter(supportDirectory: supportDirectory) }
        return try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: url)).validated()
    }
}

private struct ProjectRecoveryList: Codable {
    let recoveries: [ProjectRecoveryReceipt]
}

private struct LibraryTaskView: Encodable {
    let task: LibraryTask
    let sessions: [LibrarySession]
    let assignments: [LibraryAssignment]
    let repositories: [LibraryRepository]
    let documents: [LibraryDocument]
    let executionLocators: [LibraryExecutionLocator]
}

private struct AgentQueueClearResult: Encodable {
    let status: String
    let removedSessions: Int
    let removedSubtasks: Int
    let acknowledgedRegistrations: Int
    let runningProcessesTerminated: Bool
}

private struct RuntimeRepairResult: Encodable {
    let status: String
    let taskID: String
    let subtaskID: String
    let runtime: TmuxSessionReference
}

private struct RuntimeLocationResult: Encodable {
    let status: String
    let sessionID: String
    var processID: Int?
    var reason: String?
    var runtime: String?
    var tmuxName: String?
    var name: String?
    var serverPID: Int?
    var createdAt: Int?
    var paneID: String?
    var panePID: Int?
    var tty: String?
    var executable: String?
    var agentID: String?

    init(status: String, sessionID: String, processID: Int? = nil, reason: String? = nil) {
        self.status = status
        self.sessionID = sessionID
        self.processID = processID
        self.reason = reason
    }
}

private struct ArchitectureCLIResult: Encodable {
    let taskID: String
    let indexPath: String
    let statePath: String
    let cardCount: Int
    let sourceCount: Int
    let truncated: Bool
}
