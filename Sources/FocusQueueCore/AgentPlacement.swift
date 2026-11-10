import Foundation

public enum AgentPlacementStatus: String, Codable, Sendable {
    case placed
    case projectInbox = "project-inbox"
    case blockedConflict = "blocked-conflict"
}

public struct AgentPlacementRequest: Sendable {
    public var launchID: String
    public var cwd: String
    public var prompt: String?
    public var explicitTaskID: String?
    public var inheritedTaskID: String?
    public var assignmentID: String?
    public var provider: AgentProvider
    public var sessionID: String?
    public var tmuxName: String?
    public var tmuxPaneID: String?
    public var createTaskIfNeeded: Bool
    /// The launch role (`coding`, `research`, `orchestrator`); nil reads the assigned agent's.
    public var role: String?

    public init(launchID: String, cwd: String, prompt: String? = nil,
                explicitTaskID: String? = nil, inheritedTaskID: String? = nil,
                assignmentID: String? = nil, provider: AgentProvider = .codex,
                sessionID: String? = nil, tmuxName: String? = nil,
                tmuxPaneID: String? = nil, createTaskIfNeeded: Bool = true, role: String? = nil) {
        self.launchID = launchID; self.cwd = cwd; self.prompt = prompt
        self.explicitTaskID = explicitTaskID; self.inheritedTaskID = inheritedTaskID
        self.assignmentID = assignmentID; self.provider = provider; self.sessionID = sessionID
        self.tmuxName = tmuxName; self.tmuxPaneID = tmuxPaneID
        self.createTaskIfNeeded = createTaskIfNeeded; self.role = role
    }
}

public struct AgentPlacementCapsule: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var launchID: String
    public var generatedAt: Date
    public var status: AgentPlacementStatus
    public var projectID: String
    public var projectName: String
    public var taskPrefix: String
    public var taskID: String?
    public var assignmentID: String?
    public var agentID: String?
    public var provider: AgentProvider
    public var sessionID: String?
    public var repositoryPath: String?
    public var repositoryRemote: String?
    public var workspacePath: String
    public var branch: String?
    public var tmuxName: String?
    public var tmuxPaneID: String?
    public var projectPlanPath: String
    public var taskPlanPath: String?
    public var taskLogPath: String?
    public var taskDataPath: String? = nil
    /// Saved facts every agent in this project follows. Both files exist once placement returns.
    public var projectDataPath: String? = nil
    public var userDataPath: String? = nil
    public var capsulePath: String
    public var reason: String?
    /// The launch objective, retained so app-side discovery can name and bind
    /// the agent even when provider hooks are not installed.
    public var promptHint: String?
    /// `engineering` or `orchestrator`: which signed project contract this agent follows.
    public var agentRole: String? = nil
    /// That contract's file, present once the owner signed it off.
    public var agentContractPath: String? = nil
}

public struct AgentPlacementCapsuleStore: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }

    public func url(launchID: String) throws -> URL {
        guard UUID(uuidString: launchID) != nil else { throw TaskContextError.invalidIdentifier }
        return root.appendingPathComponent("tracking/placements", isDirectory: true)
            .appendingPathComponent(launchID.lowercased() + ".json")
    }

    public func load(launchID: String) throws -> AgentPlacementCapsule? {
        let path = try url(launchID: launchID)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        guard (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw TaskContextError.commandFailed("The placement capsule is redirected.")
        }
        return try JSONDecoder().decode(AgentPlacementCapsule.self, from: Data(contentsOf: path))
    }

    public func save(_ capsule: AgentPlacementCapsule) throws {
        let path = try url(launchID: capsule.launchID)
        let directory = path.deletingLastPathComponent()
        guard (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw TaskContextError.commandFailed("Placement capsule storage is redirected.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(capsule).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    @discardableResult public func finalize(launchID: String, taskID: String?, agentID: String?,
                                             sessionID: String?) throws -> AgentPlacementCapsule? {
        guard var capsule = try load(launchID: launchID) else { return nil }
        capsule.taskID = taskID ?? capsule.taskID
        capsule.agentID = agentID ?? capsule.agentID
        capsule.sessionID = sessionID ?? capsule.sessionID
        capsule.generatedAt = Date()
        if capsule.taskID != nil { capsule.status = .placed; capsule.reason = nil }
        try save(capsule)
        return capsule
    }
}

public actor AgentPlacementResolver {
    public let root: URL
    private let repositoryResolver: ProjectRepositoryResolver

    public init(root: URL, runner: any ProcessRunning = FoundationProcessRunner()) {
        self.root = root
        self.repositoryResolver = ProjectRepositoryResolver(runner: runner)
    }

    @discardableResult public func resolve(_ request: AgentPlacementRequest,
                                            configuration: AppConfiguration) async throws -> AgentPlacementCapsule {
        guard UUID(uuidString: request.launchID) != nil,
              request.cwd.hasPrefix("/"), !request.cwd.contains("\0") else {
            throw TaskContextError.commandFailed("Placement requires a launch UUID and absolute working directory.")
        }
        let projects = ProjectCatalog.ensuringOther(
            in: configuration.projects, supportDirectory: root).filter { $0.archivedAt == nil }
        try ProjectCatalog.validate(projects)
        for project in projects { try ProjectCatalog.prepareFallbackStorage(for: project) }
        var dashboards: [(project: ProjectDefinition, url: URL, document: DashboardDocument)] = []
        for project in projects {
            let url = URL(fileURLWithPath: project.dashboardPath)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let document = try JSONDecoder().decode(
                DashboardDocument.self, from: Data(contentsOf: url))
            dashboards.append((project, url, document))
        }
        let contextStore = TaskContextStore(root: root)
        let contexts = try await contextStore.loadAvailableForDiscovery()
        let normalizedSession = request.sessionID?.lowercased()
        let sessionContext = normalizedSession.flatMap { sessionID in
            contexts.first { context in
                context.subtasks.contains { $0.sessionID?.lowercased() == sessionID && $0.agentRemovedAt == nil }
            }
        }
        let requestedTaskID = (sessionContext?.ticketID ?? request.explicitTaskID ?? request.inheritedTaskID)?.uppercased()
        let taskMatches = requestedTaskID.map { id in dashboards.flatMap { entry in
            entry.document.tickets.filter { $0.id.caseInsensitiveCompare(id) == .orderedSame }
                .map { (entry.project, entry.url, $0) }
        }} ?? []
        guard taskMatches.count <= 1 else {
            throw TaskContextError.commandFailed(
                "The task ID appears in more than one project dashboard. Resolve the duplicate before launching.")
        }
        var ticket = taskMatches.first?.2
        var context = sessionContext ?? requestedTaskID.flatMap { id in contexts.first { $0.ticketID.caseInsensitiveCompare(id) == .orderedSame } }

        var pathMatches: [ProjectDefinition] = []
        for project in projects where project.id != ProjectCatalog.otherID && !project.repositoryPath.isEmpty {
            if (try? await repositoryResolver.matches(path: request.cwd, project: project)) == true {
                pathMatches.append(project)
            }
        }
        let explicitProject = taskMatches.first?.0
            ?? context?.projectID.flatMap { id in projects.first { $0.id == id } }
            ?? requestedTaskID.flatMap { ProjectCatalog.project(forTaskID: $0, in: projects) }
        let project = explicitProject ?? (pathMatches.count == 1 ? pathMatches[0] : nil)
            ?? projects.first(where: { $0.id == ProjectCatalog.otherID }) ?? ProjectCatalog.other
        let ambiguousPath = explicitProject == nil && pathMatches.count > 1
        let conflictingPath = explicitProject?.repositoryPath.isEmpty == false
            && !pathMatches.contains(where: { $0.id == explicitProject?.id })
        let placementBlocked = ambiguousPath || conflictingPath

        let prompt = request.prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !placementBlocked, ticket == nil, context == nil, request.createTaskIfNeeded, !prompt.isEmpty,
           prompt.localizedCaseInsensitiveCompare("Codex agent") != .orderedSame {
            let title = TaskSubtask.agentName(prompt: prompt, provider: request.provider)
            let dashboardURL = URL(fileURLWithPath: project.dashboardPath)
            let taskID = try ProjectTaskStore(dashboardURL: dashboardURL, supportDirectory: root)
                .create(title: title, summary: String(prompt.prefix(2_000)), project: project)
            ticket = DashboardTicket(id: taskID, title: title, projectID: project.id,
                status: "backlog", summary: String(prompt.prefix(2_000)))
        }
        if let ticket, !placementBlocked {
            context = try await contextStore.ensureContext(ticket: DashboardTicket(
                id: ticket.id, title: ticket.title, projectID: project.id, category: ticket.category,
                priority: ticket.priority, status: ticket.status, summary: ticket.summary,
                next: ticket.next, doneWhen: ticket.doneWhen, updatedAt: ticket.updatedAt,
                completedAt: ticket.completedAt, completion: ticket.completion,
                taskType: ticket.taskType, recurrence: ticket.recurrence, worktree: ticket.worktree,
                resolutionPrs: ticket.resolutionPrs, prs: ticket.prs, links: ticket.links, steps: ticket.steps),
                worktreePath: request.cwd, project: project)
        }

        let workspace = try? await TaskWorktreeManager().workspace(at: request.cwd)
        if !placementBlocked, let assignmentID = request.assignmentID,
           !assignmentID.isEmpty, let ticketID = context?.ticketID,
           context?.subtasks.contains(where: { $0.id == assignmentID }) != true {
            let title = TaskSubtask.agentName(prompt: prompt, provider: request.provider)
            var subtask = TaskSubtask(id: assignmentID, title: title,
                assignmentDescription: String(prompt.prefix(2_000)), provider: request.provider,
                sessionID: normalizedSession, status: .working,
                progressSummary: "Started: \(title)", lastHeartbeatAt: Date(),
                includeInitializationPrompt: false,
                runtimeMode: request.tmuxPaneID == nil ? nil : .tmux)
            subtask.initialPrompt = prompt.isEmpty ? nil : String(prompt.prefix(4_000))
            subtask.workspace = workspace ?? AgentWorkspace(
                path: request.cwd,
                repositoryPath: project.repositoryPath.isEmpty ? request.cwd : project.repositoryPath)
            context = try await contextStore.upsertSubtask(ticketID: ticketID, subtask: subtask)
        }
        let projectPlan = try ProjectContextStore(root: root).ensurePlan(for: project)
        let capsuleURL = try AgentPlacementCapsuleStore(root: root).url(launchID: request.launchID)
        let status: AgentPlacementStatus = placementBlocked ? .blockedConflict : context == nil ? .projectInbox : .placed
        let capsule = AgentPlacementCapsule(
            launchID: request.launchID.lowercased(), generatedAt: Date(), status: status,
            projectID: project.id, projectName: project.name, taskPrefix: project.taskPrefix,
            taskID: context?.ticketID ?? ticket?.id ?? requestedTaskID,
            assignmentID: request.assignmentID, agentID: request.assignmentID,
            provider: request.provider, sessionID: normalizedSession,
            repositoryPath: workspace?.repositoryPath ?? (project.repositoryPath.isEmpty ? nil : project.repositoryPath),
            repositoryRemote: project.remote, workspacePath: request.cwd, branch: workspace?.branch,
            tmuxName: request.tmuxName, tmuxPaneID: request.tmuxPaneID,
            projectPlanPath: projectPlan.path, taskPlanPath: context?.planPath,
            taskLogPath: context?.agentLogURL.path, taskDataPath: context?.dataURL.path,
            projectDataPath: projectPlan.deletingLastPathComponent().appendingPathComponent("data.md").path,
            userDataPath: root.appendingPathComponent("user/data.md").path, capsulePath: capsuleURL.path,
            reason: ambiguousPath
                ? "The working directory matches more than one project. Choose a task or project before writing."
                : conflictingPath
                ? "The task and working directory identify different projects. Open the task's repository before writing."
                : context == nil ? "Project identified. Waiting for a task objective." : nil,
            promptHint: prompt.isEmpty ? nil : String(prompt.prefix(4_000)))
        var placed = capsule
        let assigned = request.assignmentID.flatMap { id in context?.subtasks.first { $0.id == id } }
        let role = AgentContractRole(launchRole: request.role ?? assigned?.launchConfiguration?.role)
        placed.agentRole = role.rawValue
        let projectDirectory = projectPlan.deletingLastPathComponent()
        if let data = try? Data(contentsOf: projectDirectory.appendingPathComponent(DevelopmentProcessStore.fileName)),
           let process = try? JSONDecoder().decode(DevelopmentProcess.self, from: data),
           process.enabled, process.contracts[role.rawValue] != nil {
            placed.agentContractPath = projectDirectory.appendingPathComponent(role.fileName).path
        }
        try AgentPlacementCapsuleStore(root: root).save(placed)
        return placed
    }
}
