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
            "Usage: focus-queue-session review-push <TASK-ID> <SUBTASK-ID> | workspace <TASK-ID> <SUBTASK-ID> <absolute-path> | diagnose <TASK-ID> | attach <TASK-ID> | context <TASK-ID> | plan <TASK-ID> | add <TASK-ID> <codex|claude> <title> | rename <TASK-ID> <SUBTASK-ID> <title> | progress <TASK-ID> <SUBTASK-ID> <queued|working|idle|blocked> <summary> | complete <TASK-ID> <SUBTASK-ID> <summary> | agents clear --all | runtime repair <TASK-ID> <SUBTASK-ID> | library migrate|status|task <TASK-ID>|document <TASK-ID> <markdown-path> [guide|architecture|reference]|export <destination>|restore <source> | architecture <TASK-ID> [repository-path]"
        case .missingSessionIdentity:
            "No Codex or Claude session ID was found in the environment or current WezTerm pane."
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
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments.first == "tmux" { try await tmuxCommand(arguments: arguments) }
            else if arguments.first == "--help" || arguments.first == "help" {
                print(SessionRegistrationError.usage.localizedDescription)
                print("Persistent terminals: tmux list | tmux start <name> [--cwd <directory>] [-- <command> ...] | tmux attach <name> | tmux ssh-command <user@host> <name>")
            }
            else if arguments.first == "agents" { try await agentsCommand(arguments: arguments) }
            else if arguments.first == "runtime" { try await runtimeCommand(arguments: arguments) }
            else if arguments.first == "library" { try await libraryCommand(arguments: arguments) }
            else if arguments.first == "architecture" { try await architectureCommand(arguments: arguments) }
            else if arguments.first == "diagnose" { try await diagnose(arguments: arguments) }
            else if arguments.first == "attach" { try await register() }
            else { try await updateContext(arguments: arguments) }
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            Darwin.exit(1)
        }
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
        let registrations = try await inbox.pending()
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
        let name = try TmuxController.sessionName(subtaskID: subtaskID)
        let configuration = try loadConfiguration(from: root)
        guard let executable = configuration.tmuxExecutable
            ?? SetupEnvironment.executable("tmux") else {
            throw TmuxError.unavailable("The configured executable is missing.")
        }
        let runtime = try await TmuxController().inspect(
            name: name, executable: executable)
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
        let controller = TmuxController()
        switch arguments[1] {
        case "list" where arguments.count == 2:
            try emit(try await controller.list(executable: executable))
        case "attach" where arguments.count == 3:
            _ = try await controller.inspect(name: arguments[2], executable: executable)
            guard isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0 else {
                throw TmuxError.unavailable("Attach needs an interactive terminal. Use ssh -t when connecting remotely.")
            }
            let command = try TmuxController.attachCommand(name: arguments[2], executable: executable)
            let pointers = command.map { strdup($0) } + [nil]
            defer { for pointer in pointers { free(pointer) } }
            _ = pointers.withUnsafeBufferPointer { execv(command[0], $0.baseAddress!) }
            throw TmuxError.unavailable("Could not execute tmux: \(String(cString: strerror(errno)))")
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
        FileHandle.standardOutput.write(try encoder.encode(value))
        FileHandle.standardOutput.write(Data("\n".utf8))
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

    private static func register() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 2, arguments[0] == "attach", !arguments[1].isEmpty else {
            throw SessionRegistrationError.usage
        }

        let ticketID = arguments[1].uppercased()
        let environment = ProcessInfo.processInfo.environment
        guard let subtaskID = TaskSessionBinding.subtaskID(
            ticketID: ticketID, environment: environment) else {
            throw SessionRegistrationError.missingManagedRuntime
        }
        let inferredRuntime = environment["FOCUS_QUEUE_TMUX_NAME"].flatMap {
            $0.isEmpty ? nil : AgentRuntimeMode.tmux
        }
        guard let runtimeMode = environment["FOCUS_QUEUE_RUNTIME_MODE"]
            .flatMap(AgentRuntimeMode.init(rawValue:)) ?? inferredRuntime else {
            throw SessionRegistrationError.missingManagedRuntime
        }

        let supportDirectory = supportDirectory(environment: environment)
        let configuration = try loadConfiguration(from: supportDirectory)
        let library = DurableLibraryStore(root: supportDirectory)
        let controller = WezTermController()
        let store = TaskContextStore(root: supportDirectory)
        guard var context = try await store.load(ticketID: ticketID),
              let originalSubtask = context.subtasks.first(where: { $0.id == subtaskID }) else {
            throw TaskContextError.missingSubtask(subtaskID)
        }
        guard originalSubtask.runtimeMode == runtimeMode
            || (originalSubtask.runtimeMode == nil && runtimeMode == .tmux) else {
            throw TaskContextError.commandFailed(
                "This pane does not match the runtime selected when the subtask was created.")
        }

        var tmux: TmuxSessionReference?
        var directPaneID: Int?
        var wezTermConfiguration = configuration.wezTerm
        switch runtimeMode {
        case .tmux:
            guard let tmuxName = environment["FOCUS_QUEUE_TMUX_NAME"], !tmuxName.isEmpty,
                  tmuxName == (try? TmuxController.sessionName(subtaskID: subtaskID)) else {
                throw SessionRegistrationError.missingManagedRuntime
            }
            guard let executable = configuration.tmuxExecutable
                ?? SetupEnvironment.executable("tmux") else {
                throw TmuxError.unavailable("The configured executable is missing.")
            }
            let inspected = try await TmuxController().inspect(
                name: tmuxName, executable: executable)
            guard inspected.paneID == environment["TMUX_PANE"] else {
                throw TmuxError.changed
            }
            if let saved = originalSubtask.tmux, saved != inspected {
                throw TmuxError.changed
            }
            if originalSubtask.tmux == nil || originalSubtask.runtimeMode == nil {
                context = try await store.setManagedRuntime(
                    ticketID: ticketID, subtaskID: subtaskID, tmux: inspected)
            }
            tmux = inspected
        case .terminal:
            guard environment["FOCUS_QUEUE_TMUX_NAME"] == nil,
                  let paneText = environment["WEZTERM_PANE"],
                  let paneID = Int(paneText), paneID >= 0 else {
                throw SessionRegistrationError.missingManagedRuntime
            }
            let socketPath = environment["WEZTERM_UNIX_SOCKET"].flatMap {
                $0.isEmpty ? nil : $0
            }
            if let savedPane = originalSubtask.terminalPaneID, savedPane != paneID {
                throw TaskContextError.commandFailed(
                    "This pane is not the direct terminal saved for this subtask.")
            }
            if let savedSocket = originalSubtask.terminalSocketPath,
               let socketPath, savedSocket != socketPath {
                throw TaskContextError.commandFailed(
                    "This terminal connection is not the one saved for this subtask.")
            }
            if originalSubtask.terminalPaneID == nil {
                context = try await store.setDirectRuntime(
                    ticketID: ticketID, subtaskID: subtaskID,
                    paneID: paneID, socketPath: socketPath)
            }
            directPaneID = paneID
            wezTermConfiguration.socketPath = socketPath ?? wezTermConfiguration.socketPath
        }

        guard let subtask = context.subtasks.first(where: { $0.id == subtaskID }) else {
            throw TaskContextError.missingSubtask(subtaskID)
        }

        let providerAndSession: (AgentProvider, String)
        if let identity = TaskSessionBinding.providerSession(environment: environment) {
            providerAndSession = identity
        } else {
            let agents: [RunningAgentSession]
            if let tmux {
                agents = try await controller.agents(onTTY: tmux.tty)
            } else {
                agents = try await controller.listRunningAgents(
                    configuration: wezTermConfiguration).filter {
                        $0.pane.paneID == directPaneID && $0.provider == subtask.provider
                    }
            }
            guard let agent = agents.first else {
                throw SessionRegistrationError.missingSessionIdentity
            }
            providerAndSession = (agent.provider, agent.sessionID)
        }
        guard subtask.provider == providerAndSession.0 else {
            throw TaskContextError.commandFailed(
                "This subtask is assigned to \(subtask.provider.displayName). Attach an agent from that provider or create a matching subtask.")
        }

        var session = TaskAgentSession(
            ticketID: ticketID,
            provider: providerAndSession.0,
            sessionID: providerAndSession.1,
            tabTitle: ticketID,
            workingDirectory: environment["PWD"] ?? FileManager.default.currentDirectoryPath,
            paneID: directPaneID,
            tmux: tmux
        ).canonicalizedForTerminal()
        session = session.withContext(
            context, subtask: subtask, supportDirectory: supportDirectory)
        let inbox = AgentRegistrationInbox(
            directory: supportDirectory.appendingPathComponent("agent-registrations", isDirectory: true)
        )
        try await inbox.submit(session)
        if FileManager.default.isExecutableFile(atPath: configuration.wezTerm.executable) {
            do {
                if tmux != nil {
                    try await controller.labelTmuxClients(
                        session: session, configuration: configuration.wezTerm)
                } else if let directPaneID {
                    try await controller.attach(
                        paneID: directPaneID, tabTitle: session.terminalTabTitle,
                        windowTitle: session.terminalWindowTitle,
                        configuration: wezTermConfiguration)
                }
            }
            catch { FileHandle.standardError.write(Data("Session registered; desktop labels are pending: \(error.localizedDescription)\n".utf8)) }
        }
        do { try await library.recordSession(session) }
        catch { historyWarning(error) }
        let attachedContext = try await store.attachSubtask(
            ticketID: ticketID, subtaskID: subtaskID,
            provider: providerAndSession.0, sessionID: providerAndSession.1)
        await mirrorContext(attachedContext, root: supportDirectory)
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(AgentRegistrationInbox.notificationName),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )

        let result: [String: Any] = [
            "provider": providerAndSession.0.rawValue,
            "sessionID": providerAndSession.1,
            "taskID": ticketID,
            "paneID": directPaneID.map(String.init) ?? tmux?.paneID ?? "",
            "runtime": runtimeMode.rawValue,
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
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
        if command == "plan", arguments.count == 2 {
            FileHandle.standardOutput.write(Data(try await store.readPlan(ticketID: arguments[1]).utf8))
            return
        }
        if command == "add", arguments.count == 4, let provider = AgentProvider(rawValue: arguments[2]) {
            let title = arguments[3].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw SessionRegistrationError.usage }
            let subtask = TaskSubtask(title: String(title.prefix(200)), provider: provider)
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
        if command == "context", arguments.count == 2 {
            guard let context = try await store.load(ticketID: arguments[1]) else { throw TaskContextError.missingContext(arguments[1]) }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            FileHandle.standardOutput.write(try encoder.encode(context))
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

private struct ArchitectureCLIResult: Encodable {
    let taskID: String
    let indexPath: String
    let statePath: String
    let cardCount: Int
    let sourceCount: Int
    let truncated: Bool
}
