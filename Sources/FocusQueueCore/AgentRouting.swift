import CryptoKit
import Darwin
import Foundation

func secureAgentRoutingData(at source: URL, maximumSize: Int = 1_048_576) throws -> Data? {
    let descriptor = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    if descriptor < 0, errno == ENOENT { return nil }
    guard descriptor >= 0 else {
        throw TaskContextError.commandFailed("Could not open the routing recovery record securely.")
    }
    defer { Darwin.close(descriptor) }
    var metadata = stat()
    guard Darwin.fstat(descriptor, &metadata) == 0,
          metadata.st_mode & S_IFMT == S_IFREG,
          metadata.st_uid == Darwin.geteuid(),
          metadata.st_nlink == 1,
          metadata.st_size >= 0,
          metadata.st_size <= maximumSize else {
        throw TaskContextError.commandFailed("The routing recovery record is unsafe or too large.")
    }
    var data = Data()
    data.reserveCapacity(Int(metadata.st_size))
    var buffer = [UInt8](repeating: 0, count: min(65_536, maximumSize + 1))
    while true {
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        guard count >= 0 else {
            throw TaskContextError.commandFailed("Could not read the routing recovery record securely.")
        }
        if count == 0 { break }
        guard data.count + count <= maximumSize else {
            throw TaskContextError.commandFailed("The routing recovery record is too large.")
        }
        data.append(buffer, count: count)
    }
    return data
}

public struct AgentRouteSource: Codable, Equatable, Sendable {
    public var providerSessionID: String?
    public var cwd: String
    public var tmuxName: String?
    public var tmuxPaneID: String?
    public var terminalPaneID: Int?
    public var terminalSocketPath: String?

    public init(providerSessionID: String? = nil, cwd: String,
                tmuxName: String? = nil, tmuxPaneID: String? = nil,
                terminalPaneID: Int? = nil, terminalSocketPath: String? = nil) {
        self.providerSessionID = providerSessionID
        self.cwd = cwd
        self.tmuxName = tmuxName
        self.tmuxPaneID = tmuxPaneID
        self.terminalPaneID = terminalPaneID
        self.terminalSocketPath = terminalSocketPath
    }
}

public enum AgentRouteOrigin: String, Codable, Equatable, Sendable {
    case automaticShell = "automatic-shell"
    case queueComposer = "queue-composer"
}

public struct AgentRouteInspectionRequest: Sendable {
    public var prompt: String
    public var provider: AgentProvider
    public var source: AgentRouteSource
    public var origin: AgentRouteOrigin
    public var composerCapability: String?

    public init(prompt: String, provider: AgentProvider, source: AgentRouteSource,
                origin: AgentRouteOrigin = .automaticShell,
                composerCapability: String? = nil) {
        self.prompt = prompt
        self.provider = provider
        self.source = source
        self.origin = origin
        self.composerCapability = composerCapability
    }
}

public struct AgentRouteCandidate: Codable, Equatable, Sendable {
    public var taskID: String
    public var title: String
    public var summary: String
    public var taskPlanPath: String
    public var taskContextPath: String
    public var taskLogPath: String

    public init(taskID: String, title: String, summary: String, taskPlanPath: String,
                taskContextPath: String, taskLogPath: String) {
        self.taskID = taskID
        self.title = title
        self.summary = summary
        self.taskPlanPath = taskPlanPath
        self.taskContextPath = taskContextPath
        self.taskLogPath = taskLogPath
    }
}

public struct AgentRouteTaskLocation: Equatable, Sendable {
    public let project: ProjectDefinition
    public let ticket: DashboardTicket

    public init(project: ProjectDefinition, ticket: DashboardTicket) {
        self.project = project
        self.ticket = ticket
    }
}

public enum AgentRouteTaskLocator {
    public static func locate(taskID: String,
                              projects: [ProjectDefinition]) async throws -> AgentRouteTaskLocation {
        let requested = taskID.uppercased()
        var matches: [AgentRouteTaskLocation] = []
        for project in projects where project.archivedAt == nil {
            let dashboardURL = URL(fileURLWithPath: project.dashboardPath)
            guard FileManager.default.fileExists(atPath: dashboardURL.path) else { continue }
            let dashboard = try await JSONDashboardRepository().load(from: dashboardURL)
            matches += dashboard.tickets.filter {
                $0.id.caseInsensitiveCompare(requested) == .orderedSame
            }.map { AgentRouteTaskLocation(project: project, ticket: $0) }
        }
        guard matches.count == 1, let match = matches.first else {
            throw TaskContextError.commandFailed(matches.isEmpty
                ? "The selected task does not exist."
                : "The selected task appears in more than one project dashboard.")
        }
        return match
    }
}

public enum AgentRouteInspectionStatus: String, Codable, Equatable, Sendable {
    case disabled
    case ready
    case noRepositoryMatch = "no-repository-match"
}

public struct AgentRouteInspection: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let status: AgentRouteInspectionStatus
    public let routeID: String
    public let automaticRoutingEnabled: Bool
    public let inferredProjectID: String?
    public let inferredProjectName: String?
    public let repositoryPath: String?
    public let projectPlanPath: String?
    public let candidates: [AgentRouteCandidate]
    public let source: AgentRouteSource
    public let startCommand: String
    public let newTaskCommand: String
    public let requiredParameters: [String]

    public init(status: AgentRouteInspectionStatus, routeID: String,
                automaticRoutingEnabled: Bool, inferredProjectID: String?,
                inferredProjectName: String?, repositoryPath: String?,
                projectPlanPath: String?, candidates: [AgentRouteCandidate],
                source: AgentRouteSource, startCommand: String,
                newTaskCommand: String, requiredParameters: [String]) {
        schemaVersion = 1
        self.status = status
        self.routeID = routeID
        self.automaticRoutingEnabled = automaticRoutingEnabled
        self.inferredProjectID = inferredProjectID
        self.inferredProjectName = inferredProjectName
        self.repositoryPath = repositoryPath
        self.projectPlanPath = projectPlanPath
        self.candidates = candidates
        self.source = source
        self.startCommand = startCommand
        self.newTaskCommand = newTaskCommand
        self.requiredParameters = requiredParameters
    }
}

public struct AgentRouteIntent: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let routeID: String
    public let prompt: String
    public let provider: AgentProvider
    public let source: AgentRouteSource
    public let origin: AgentRouteOrigin
    public let composerCapability: String?
    public let inferredProjectID: String?
    public let repositoryPath: String?
    public let createdAt: Date
    public var startedAt: Date?
    public var taskID: String?
    public var subtaskID: String?

    public init(routeID: String, prompt: String, provider: AgentProvider,
                source: AgentRouteSource, origin: AgentRouteOrigin = .automaticShell,
                composerCapability: String? = nil,
                inferredProjectID: String?, repositoryPath: String?,
                createdAt: Date = Date()) {
        schemaVersion = 1
        self.routeID = routeID
        self.prompt = prompt
        self.provider = provider
        self.source = source
        self.origin = origin
        self.composerCapability = composerCapability
        self.inferredProjectID = inferredProjectID
        self.repositoryPath = repositoryPath
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, routeID, prompt, provider, source, origin, composerCapability
        case inferredProjectID, repositoryPath, createdAt, startedAt, taskID, subtaskID
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        routeID = try values.decode(String.self, forKey: .routeID)
        prompt = try values.decode(String.self, forKey: .prompt)
        provider = try values.decode(AgentProvider.self, forKey: .provider)
        source = try values.decode(AgentRouteSource.self, forKey: .source)
        origin = try values.decodeIfPresent(AgentRouteOrigin.self, forKey: .origin) ?? .automaticShell
        composerCapability = try values.decodeIfPresent(String.self, forKey: .composerCapability)
        inferredProjectID = try values.decodeIfPresent(String.self, forKey: .inferredProjectID)
        repositoryPath = try values.decodeIfPresent(String.self, forKey: .repositoryPath)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        startedAt = try values.decodeIfPresent(Date.self, forKey: .startedAt)
        taskID = try values.decodeIfPresent(String.self, forKey: .taskID)
        subtaskID = try values.decodeIfPresent(String.self, forKey: .subtaskID)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(routeID, forKey: .routeID)
        try values.encode(prompt, forKey: .prompt)
        try values.encode(provider, forKey: .provider)
        try values.encode(source, forKey: .source)
        try values.encode(origin, forKey: .origin)
        try values.encodeIfPresent(composerCapability, forKey: .composerCapability)
        try values.encodeIfPresent(inferredProjectID, forKey: .inferredProjectID)
        try values.encodeIfPresent(repositoryPath, forKey: .repositoryPath)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encodeIfPresent(startedAt, forKey: .startedAt)
        try values.encodeIfPresent(taskID, forKey: .taskID)
        try values.encodeIfPresent(subtaskID, forKey: .subtaskID)
    }

    public func allowsRouting(automaticAgentRouting: Bool) -> Bool {
        automaticAgentRouting || origin == .queueComposer
    }
}

public struct AgentRouteStore: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }

    private func url(routeID: String) throws -> URL {
        guard UUID(uuidString: routeID) != nil else { throw TaskContextError.invalidIdentifier }
        return root.appendingPathComponent("agent-routes", isDirectory: true)
            .appendingPathComponent(routeID.lowercased() + ".json")
    }

    public func intentURL(routeID: String) throws -> URL { try url(routeID: routeID) }

    @discardableResult public func save(_ intent: AgentRouteIntent) throws -> URL {
        let destination = try url(routeID: intent.routeID)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(intent).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return destination
    }

    public func load(routeID: String) throws -> AgentRouteIntent? {
        let source = try url(routeID: routeID)
        guard let data = try secureAgentRoutingData(at: source) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AgentRouteIntent.self, from: data)
    }

    public func latest(
        sourceTmuxName: String, createdAfter: Date,
        origin: AgentRouteOrigin = .queueComposer
    ) throws -> AgentRouteIntent? {
        let directory = root.appendingPathComponent("agent-routes", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        let sources = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "json" }
            .sorted {
                (try? $0.resourceValues(forKeys: keys).contentModificationDate ?? .distantPast) ?? .distantPast
                  > (try? $1.resourceValues(forKeys: keys).contentModificationDate ?? .distantPast) ?? .distantPast
            }
            .prefix(256)
        var matches: [AgentRouteIntent] = []
        for source in sources {
            guard UUID(uuidString: source.deletingPathExtension().lastPathComponent) != nil,
                  let intent = try? load(
                    routeID: source.deletingPathExtension().lastPathComponent),
                  intent.origin == origin,
                  intent.source.tmuxName == sourceTmuxName,
                  intent.createdAt >= createdAfter.addingTimeInterval(-1) else { continue }
            matches.append(intent)
        }
        return matches.max { $0.createdAt < $1.createdAt }
    }

    public func claim(routeID: String, subtaskID: String) throws {
        let intentURL = try url(routeID: routeID)
        try FileManager.default.createDirectory(
            at: intentURL.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let lock = intentURL.appendingPathExtension("lock")
        let descriptor = Darwin.open(lock.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { flock(descriptor, LOCK_UN) }
        guard var intent = try load(routeID: routeID), intent.startedAt == nil else {
            throw TaskContextError.commandFailed("This route was already started. Reuse its saved startup receipt.")
        }
        intent.startedAt = Date()
        intent.subtaskID = subtaskID
        try save(intent)
    }

    public func setDestination(routeID: String, taskID: String) throws {
        guard var intent = try load(routeID: routeID), intent.startedAt != nil,
              intent.taskID == nil else {
            throw TaskContextError.commandFailed("The route destination is missing or already fixed.")
        }
        intent.taskID = taskID.uppercased()
        try save(intent)
    }

    /// A launch that failed before writing a durable startup receipt may retry
    /// with the same task and subtask identities. Once a receipt exists, callers
    /// must replay it instead of releasing the claim.
    public func releaseClaim(routeID: String, subtaskID: String) throws {
        let intentURL = try url(routeID: routeID)
        let lock = intentURL.appendingPathExtension("lock")
        let descriptor = Darwin.open(lock.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { flock(descriptor, LOCK_UN) }
        guard var intent = try load(routeID: routeID), intent.startedAt != nil,
              intent.subtaskID == subtaskID else { return }
        intent.startedAt = nil
        try save(intent)
    }

    public func retireUnstarted(routeID: String, sourceTmuxName: String) throws {
        let intentURL = try url(routeID: routeID)
        let lock = intentURL.appendingPathExtension("lock")
        let descriptor = Darwin.open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { flock(descriptor, LOCK_UN) }
        guard let intent = try load(routeID: routeID),
              intent.origin == .queueComposer,
              intent.source.tmuxName == sourceTmuxName,
              intent.startedAt == nil, intent.taskID == nil, intent.subtaskID == nil else {
            throw TaskContextError.commandFailed(
                "Only an unstarted route owned by the stopped router can be retired.")
        }
        try FileManager.default.removeItem(at: intentURL)
    }
}

public actor AgentRouteCoordinator {
    private let root: URL
    private let repositoryResolver: ProjectRepositoryResolver

    public init(root: URL, repositoryResolver: ProjectRepositoryResolver = ProjectRepositoryResolver()) {
        self.root = root
        self.repositoryResolver = repositoryResolver
    }

    public func inspect(_ request: AgentRouteInspectionRequest,
                        configuration: AppConfiguration) async throws -> AgentRouteInspection {
        var prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw TaskContextError.commandFailed("Routing needs the full initial prompt.")
        }
        let routeID = UUID().uuidString.lowercased()
        var composerClaim: (capability: String, routeID: String)?
        if request.origin == .queueComposer {
            guard let capability = request.composerCapability,
                  let tmuxName = request.source.tmuxName else {
                throw TaskContextError.commandFailed(
                    "The queue router is missing its one-use authorization.")
            }
            prompt = try QueueRouterRuntimeStore(root: root).claimRoute(
                capability: capability, sourceTmuxName: tmuxName,
                prompt: prompt, routeID: routeID)
            composerClaim = (capability, routeID)
        }
        var intentSaved = false
        defer {
            if !intentSaved, let composerClaim {
                try? QueueRouterRuntimeStore(root: root).releaseClaim(
                    capability: composerClaim.capability, routeID: composerClaim.routeID)
            }
        }
        let activeProjects = configuration.projects.filter { $0.archivedAt == nil }
        var matchedProject: ProjectDefinition?
        for candidate in activeProjects where !candidate.repositoryPath.isEmpty {
            if try await repositoryResolver.matches(path: request.source.cwd, project: candidate) {
                matchedProject = candidate
                break
            }
        }
        let project = matchedProject
            ?? activeProjects.first(where: { $0.id == ProjectCatalog.otherID })
        var candidates: [AgentRouteCandidate] = []
        if let project,
           FileManager.default.fileExists(atPath: project.dashboardPath) {
            let dashboard = try await JSONDashboardRepository().load(
                from: URL(fileURLWithPath: project.dashboardPath))
            candidates = dashboard.tickets.filter(\.isOpen).map { ticket in
                let directory = root.appendingPathComponent("tasks", isDirectory: true)
                    .appendingPathComponent(ticket.id.uppercased(), isDirectory: true)
                return AgentRouteCandidate(
                    taskID: ticket.id.uppercased(), title: ticket.title, summary: ticket.summary,
                    taskPlanPath: directory.appendingPathComponent("plan.md").path,
                    taskContextPath: directory.appendingPathComponent("context.json").path,
                    taskLogPath: directory.appendingPathComponent("agent-log.md").path)
            }
        }
        let status: AgentRouteInspectionStatus = request.origin == .queueComposer
            || configuration.automaticAgentRouting ? .ready : .disabled
        let projectPlan = try project.map { try ProjectContextStore(root: root).planURL(projectID: $0.id).path }
        let intent = AgentRouteIntent(
            routeID: routeID, prompt: prompt, provider: request.provider, source: request.source,
            origin: request.origin,
            composerCapability: request.composerCapability,
            inferredProjectID: project?.id,
            repositoryPath: matchedProject?.repositoryPath ?? request.source.cwd)
        _ = try AgentRouteStore(root: root).save(intent)
        intentSaved = true
        return AgentRouteInspection(
            status: status, routeID: routeID,
            automaticRoutingEnabled: configuration.automaticAgentRouting,
            inferredProjectID: project?.id, inferredProjectName: project?.name,
            repositoryPath: matchedProject?.repositoryPath ?? request.source.cwd,
            projectPlanPath: projectPlan,
            candidates: candidates, source: request.source,
            startCommand: "focus-queue-session route start \(routeID) --task <TASK-ID> --title <TITLE> --description <DESCRIPTION> --provider \(request.provider.rawValue) --workspace isolated-snapshot",
            newTaskCommand: "focus-queue-session route start \(routeID) --project \(project?.id ?? ProjectCatalog.otherID) --task-title <TASK-TITLE> --title <SUBTASK-TITLE> --description <DESCRIPTION> --provider \(request.provider.rawValue) --workspace isolated-snapshot",
            requiredParameters: ["task-or-project", "title", "description", "provider", "workspace"])
    }
}

public struct AgentStartupContextPaths: Codable, Equatable, Sendable {
    public var capsule: String?
    public var projectPlan: String?
    public var taskPlan: String
    public var taskContext: String
    public var taskLog: String

    public init(capsule: String? = nil, projectPlan: String? = nil, taskPlan: String,
                taskContext: String, taskLog: String) {
        self.capsule = capsule
        self.projectPlan = projectPlan
        self.taskPlan = taskPlan
        self.taskContext = taskContext
        self.taskLog = taskLog
    }
}

public struct AgentStartupRuntime: Codable, Equatable, Sendable {
    public var mode: AgentRuntimeMode
    public var tmuxExecutable: String?
    public var tmuxServerName: String?
    public var tmuxName: String?
    public var tmuxServerPID: Int?
    public var tmuxCreatedAt: Int?
    public var tmuxPaneID: String?
    public var tmuxPanePID: Int?
    public var tty: String?
    public var terminalApplication: String
    public var terminalPaneID: Int?
    public var terminalSocketPath: String?
    public var attachCommand: [String]

    public init(mode: AgentRuntimeMode, tmuxExecutable: String? = nil,
                tmuxServerName: String? = nil,
                tmuxName: String? = nil, tmuxServerPID: Int? = nil,
                tmuxCreatedAt: Int? = nil, tmuxPaneID: String? = nil,
                tmuxPanePID: Int? = nil, tty: String? = nil,
                terminalApplication: String, terminalPaneID: Int? = nil,
                terminalSocketPath: String? = nil, attachCommand: [String]) {
        self.mode = mode
        self.tmuxExecutable = tmuxExecutable
        self.tmuxServerName = tmuxServerName
        self.tmuxName = tmuxName
        self.tmuxServerPID = tmuxServerPID
        self.tmuxCreatedAt = tmuxCreatedAt
        self.tmuxPaneID = tmuxPaneID
        self.tmuxPanePID = tmuxPanePID
        self.tty = tty
        self.terminalApplication = terminalApplication
        self.terminalPaneID = terminalPaneID
        self.terminalSocketPath = terminalSocketPath
        self.attachCommand = attachCommand
    }

    public init(
        tmux: TmuxSessionReference, tmuxServerName: String,
        terminalApplication: String, terminalSocketPath: String?, attachCommand: [String]
    ) {
        self.init(
            mode: .tmux, tmuxExecutable: tmux.executable,
            tmuxServerName: tmuxServerName, tmuxName: tmux.name,
            tmuxServerPID: tmux.serverPID, tmuxCreatedAt: tmux.createdAt,
            tmuxPaneID: tmux.paneID, tmuxPanePID: tmux.panePID, tty: tmux.tty,
            terminalApplication: terminalApplication,
            terminalSocketPath: terminalSocketPath, attachCommand: attachCommand)
    }

    public var exactTmuxReference: TmuxSessionReference? {
        guard mode == .tmux, let name = tmuxName, let serverPID = tmuxServerPID,
              let createdAt = tmuxCreatedAt, let paneID = tmuxPaneID,
              let panePID = tmuxPanePID, let tty, let executable = tmuxExecutable else {
            return nil
        }
        guard (try? TmuxController.validateName(name)) != nil,
              serverPID > 0, serverPID <= Int(Int32.max), createdAt >= 0,
              paneID.range(of: "^%[0-9]+$", options: .regularExpression) != nil,
              panePID > 0, panePID <= Int(Int32.max), tty.hasPrefix("/dev/"),
              executable.hasPrefix("/"), !executable.contains("\0") else { return nil }
        return TmuxSessionReference(
            name: name, serverPID: serverPID, createdAt: createdAt,
            paneID: paneID, panePID: panePID, tty: tty, executable: executable)
    }
}

public enum AgentStartupStatus: String, Codable, Equatable, Sendable {
    case starting
    case launched
    case registered
    case failed
}

public struct AgentStartupReceipt: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public var routeID: String
    public var status: AgentStartupStatus
    public var projectID: String
    public var projectName: String
    public var taskID: String
    public var taskTitle: String
    public var subtaskID: String
    public var title: String
    public var description: String
    public var provider: AgentProvider
    public var model: String?
    public var effort: String?
    public var providerVersion: String?
    public var reservedProviderSessionID: String?
    public var providerSessionID: String?
    public var providerLaunchCommand: [String]
    public var providerResumeCommand: [String]?
    public var promptByteCount: Int
    public var promptSHA256: String
    public var workspace: AgentWorkspace
    public var runtime: AgentStartupRuntime?
    public var context: AgentStartupContextPaths
    public var source: AgentRouteSource
    public var orchestrationPreparedAt: Date?
    public var handoffCompletedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(routeID: String, status: AgentStartupStatus,
                projectID: String = "", projectName: String = "",
                taskID: String, taskTitle: String = "",
                subtaskID: String, title: String, description: String,
                provider: AgentProvider, model: String? = nil, effort: String? = nil,
                providerVersion: String? = nil, reservedProviderSessionID: String? = nil,
                providerSessionID: String? = nil,
                providerLaunchCommand: [String] = [], providerResumeCommand: [String]? = nil,
                promptByteCount: Int, promptSHA256: String, workspace: AgentWorkspace,
                runtime: AgentStartupRuntime? = nil, context: AgentStartupContextPaths,
                source: AgentRouteSource, orchestrationPreparedAt: Date? = nil,
                handoffCompletedAt: Date? = nil,
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        schemaVersion = 1
        self.routeID = routeID
        self.status = status
        self.projectID = projectID
        self.projectName = projectName
        self.taskID = taskID
        self.taskTitle = taskTitle
        self.subtaskID = subtaskID
        self.title = title
        self.description = description
        self.provider = provider
        self.model = model
        self.effort = effort
        self.providerVersion = providerVersion
        self.reservedProviderSessionID = reservedProviderSessionID
        self.providerSessionID = providerSessionID
        self.providerLaunchCommand = providerLaunchCommand
        self.providerResumeCommand = providerResumeCommand
        self.promptByteCount = promptByteCount
        self.promptSHA256 = promptSHA256
        self.workspace = workspace
        self.runtime = runtime
        self.context = context
        self.source = source
        self.orchestrationPreparedAt = orchestrationPreparedAt
        self.handoffCompletedAt = handoffCompletedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static func promptDigest(_ prompt: String) -> String {
        SHA256.hash(data: Data(prompt.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct AgentStartupReceiptStore: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }

    public func url(taskID: String, subtaskID: String) throws -> URL {
        func valid(_ value: String) -> Bool {
            !value.isEmpty && value.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
            }
        }
        guard valid(taskID), valid(subtaskID) else {
            throw TaskContextError.invalidIdentifier
        }
        return root.appendingPathComponent("logs/agent-startups", isDirectory: true)
            .appendingPathComponent(taskID.uppercased(), isDirectory: true)
            .appendingPathComponent(subtaskID.lowercased() + ".json")
    }

    @discardableResult public func save(_ receipt: AgentStartupReceipt) throws -> URL {
        let destination = try url(taskID: receipt.taskID, subtaskID: receipt.subtaskID)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return try withLock(taskID: receipt.taskID, subtaskID: receipt.subtaskID) {
            var merged = receipt
            if let saved = try load(taskID: receipt.taskID, subtaskID: receipt.subtaskID),
               saved.routeID == receipt.routeID {
                if saved.status == .registered {
                    merged.status = .registered
                }
                merged.reservedProviderSessionID = saved.reservedProviderSessionID
                    ?? merged.reservedProviderSessionID
                merged.providerSessionID = saved.providerSessionID ?? merged.providerSessionID
                merged.providerResumeCommand = saved.providerResumeCommand
                    ?? merged.providerResumeCommand
                if saved.runtime?.exactTmuxReference != nil || merged.runtime == nil {
                    merged.runtime = saved.runtime ?? merged.runtime
                }
                merged.orchestrationPreparedAt = saved.orchestrationPreparedAt
                    ?? merged.orchestrationPreparedAt
                merged.handoffCompletedAt = saved.handoffCompletedAt
                    ?? merged.handoffCompletedAt
                if saved.updatedAt > merged.updatedAt { merged.updatedAt = saved.updatedAt }
            }
            return try saveUnlocked(merged, destination: destination)
        }
    }

    @discardableResult private func saveUnlocked(
        _ receipt: AgentStartupReceipt, destination: URL
    ) throws -> URL {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(receipt).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return destination
    }

    public func load(taskID: String, subtaskID: String) throws -> AgentStartupReceipt? {
        let source = try url(taskID: taskID, subtaskID: subtaskID)
        guard let data = try secureAgentRoutingData(at: source) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AgentStartupReceipt.self, from: data)
    }

    public func remove(taskID: String, subtaskID: String) throws {
        let source = try url(taskID: taskID, subtaskID: subtaskID)
        try withLock(taskID: taskID, subtaskID: subtaskID) {
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.removeItem(at: source)
            }
        }
    }

    public func register(taskID: String, subtaskID: String, providerSessionID: String) throws {
        try withLock(taskID: taskID, subtaskID: subtaskID) {
            guard var receipt = try load(taskID: taskID, subtaskID: subtaskID),
                  receipt.provider.isValidSessionID(providerSessionID) else { return }
            if let savedSessionID = receipt.providerSessionID,
               savedSessionID.caseInsensitiveCompare(providerSessionID) != .orderedSame {
                throw TaskContextError.commandFailed(
                    "The startup receipt is already bound to a different provider session.")
            }
            if let reservedSessionID = receipt.reservedProviderSessionID,
               reservedSessionID.caseInsensitiveCompare(providerSessionID) != .orderedSame {
                throw TaskContextError.commandFailed(
                    "The startup receipt reserved a different provider session.")
            }
            receipt.providerSessionID = providerSessionID.lowercased()
            var profile: [String] = []
            if let model = receipt.model { profile += ["--model", model] }
            if let effort = receipt.effort {
                profile += receipt.provider.effortArguments(effort: effort)
            }
            let contextDirectory = URL(fileURLWithPath: receipt.context.taskContext)
                .deletingLastPathComponent().path
            receipt.providerResumeCommand = [receipt.provider.executableName]
                + receipt.provider.resumeArguments(sessionID: providerSessionID.lowercased())
                + (receipt.provider == .codex ? ["--cd", receipt.workspace.path] : [])
                + profile + ["--add-dir", contextDirectory]
            receipt.status = .registered
            receipt.updatedAt = Date()
            let destination = try url(taskID: taskID, subtaskID: subtaskID)
            try saveUnlocked(receipt, destination: destination)
        }
    }

    public func reserveProviderSession(
        taskID: String, subtaskID: String, providerSessionID: String
    ) throws {
        try withLock(taskID: taskID, subtaskID: subtaskID) {
            guard var receipt = try load(taskID: taskID, subtaskID: subtaskID) else {
                throw TaskContextError.commandFailed("The startup receipt is missing.")
            }
            guard receipt.provider.isValidSessionID(providerSessionID) else {
                throw TaskContextError.invalidIdentifier
            }
            if let savedSessionID = receipt.providerSessionID ?? receipt.reservedProviderSessionID,
               savedSessionID.caseInsensitiveCompare(providerSessionID) != .orderedSame {
                throw TaskContextError.commandFailed(
                    "The startup receipt is already bound to a different provider session.")
            }
            receipt.reservedProviderSessionID = providerSessionID.lowercased()
            receipt.updatedAt = Date()
            let destination = try url(taskID: taskID, subtaskID: subtaskID)
            try saveUnlocked(receipt, destination: destination)
        }
    }

    public func completeHandoff(
        taskID: String, subtaskID: String, expectedSessionID: String
    ) throws {
        try withLock(taskID: taskID, subtaskID: subtaskID) {
            guard var receipt = try load(taskID: taskID, subtaskID: subtaskID) else {
                throw TaskContextError.commandFailed(
                    "The routed agent is not registered and prepared, so its handoff cannot be completed.")
            }
            guard receipt.provider.isValidSessionID(expectedSessionID) else {
                throw TaskContextError.invalidIdentifier
            }
            guard receipt.status == .registered,
                  receipt.providerSessionID?.caseInsensitiveCompare(expectedSessionID)
                    == .orderedSame,
                  receipt.orchestrationPreparedAt != nil else {
                throw TaskContextError.commandFailed(
                    "The routed agent is not registered and prepared, so its handoff cannot be completed.")
            }
            receipt.handoffCompletedAt = receipt.handoffCompletedAt ?? Date()
            receipt.updatedAt = Date()
            let destination = try url(taskID: taskID, subtaskID: subtaskID)
            try saveUnlocked(receipt, destination: destination)
        }
    }

    public func markOrchestrationPrepared(taskID: String, subtaskID: String) throws {
        try withLock(taskID: taskID, subtaskID: subtaskID) {
            guard var receipt = try load(taskID: taskID, subtaskID: subtaskID),
                  receipt.runtime?.exactTmuxReference != nil else {
                throw TaskContextError.commandFailed(
                    "The routed agent has no exact managed runtime to prepare.")
            }
            receipt.orchestrationPreparedAt = receipt.orchestrationPreparedAt ?? Date()
            receipt.updatedAt = Date()
            let destination = try url(taskID: taskID, subtaskID: subtaskID)
            try saveUnlocked(receipt, destination: destination)
        }
    }

    private func withLock<T>(
        taskID: String, subtaskID: String, _ body: () throws -> T
    ) throws -> T {
        let destination = try url(taskID: taskID, subtaskID: subtaskID)
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let lock = destination.appendingPathExtension("lock")
        let descriptor = Darwin.open(
            lock.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == Darwin.geteuid(), metadata.st_nlink == 1,
              metadata.st_mode & mode_t(0o077) == 0 else {
            throw TaskContextError.commandFailed("The startup receipt lock is unsafe.")
        }
        guard flock(descriptor, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}
