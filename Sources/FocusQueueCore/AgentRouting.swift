import CryptoKit
import Darwin
import Foundation

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

public struct AgentRouteInspectionRequest: Sendable {
    public var prompt: String
    public var provider: AgentProvider
    public var source: AgentRouteSource

    public init(prompt: String, provider: AgentProvider, source: AgentRouteSource) {
        self.prompt = prompt
        self.provider = provider
        self.source = source
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
    public let inferredProjectID: String?
    public let repositoryPath: String?
    public let createdAt: Date
    public var startedAt: Date?
    public var taskID: String?
    public var subtaskID: String?

    public init(routeID: String, prompt: String, provider: AgentProvider,
                source: AgentRouteSource, inferredProjectID: String?, repositoryPath: String?,
                createdAt: Date = Date()) {
        schemaVersion = 1
        self.routeID = routeID
        self.prompt = prompt
        self.provider = provider
        self.source = source
        self.inferredProjectID = inferredProjectID
        self.repositoryPath = repositoryPath
        self.createdAt = createdAt
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
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AgentRouteIntent.self, from: Data(contentsOf: source))
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
        let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw TaskContextError.commandFailed("Routing needs the full initial prompt.")
        }
        let routeID = UUID().uuidString.lowercased()
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
        let status: AgentRouteInspectionStatus = configuration.automaticAgentRouting ? .ready : .disabled
        let projectPlan = try project.map { try ProjectContextStore(root: root).planURL(projectID: $0.id).path }
        let intent = AgentRouteIntent(
            routeID: routeID, prompt: prompt, provider: request.provider, source: request.source,
            inferredProjectID: project?.id,
            repositoryPath: matchedProject?.repositoryPath ?? request.source.cwd)
        _ = try AgentRouteStore(root: root).save(intent)
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
    public var tmuxPaneID: String?
    public var tmuxPanePID: Int?
    public var tty: String?
    public var terminalApplication: String
    public var terminalPaneID: Int?
    public var terminalSocketPath: String?
    public var attachCommand: [String]

    public init(mode: AgentRuntimeMode, tmuxExecutable: String? = nil,
                tmuxServerName: String? = nil,
                tmuxName: String? = nil, tmuxPaneID: String? = nil,
                tmuxPanePID: Int? = nil, tty: String? = nil,
                terminalApplication: String, terminalPaneID: Int? = nil,
                terminalSocketPath: String? = nil, attachCommand: [String]) {
        self.mode = mode
        self.tmuxExecutable = tmuxExecutable
        self.tmuxServerName = tmuxServerName
        self.tmuxName = tmuxName
        self.tmuxPaneID = tmuxPaneID
        self.tmuxPanePID = tmuxPanePID
        self.tty = tty
        self.terminalApplication = terminalApplication
        self.terminalPaneID = terminalPaneID
        self.terminalSocketPath = terminalSocketPath
        self.attachCommand = attachCommand
    }
}

public enum AgentStartupStatus: String, Codable, Equatable, Sendable {
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
    public var providerSessionID: String?
    public var providerLaunchCommand: [String]
    public var providerResumeCommand: [String]?
    public var promptByteCount: Int
    public var promptSHA256: String
    public var workspace: AgentWorkspace
    public var runtime: AgentStartupRuntime
    public var context: AgentStartupContextPaths
    public var source: AgentRouteSource
    public var createdAt: Date
    public var updatedAt: Date

    public init(routeID: String, status: AgentStartupStatus,
                projectID: String = "", projectName: String = "",
                taskID: String, taskTitle: String = "",
                subtaskID: String, title: String, description: String,
                provider: AgentProvider, model: String? = nil, effort: String? = nil,
                providerVersion: String? = nil, providerSessionID: String? = nil,
                providerLaunchCommand: [String] = [], providerResumeCommand: [String]? = nil,
                promptByteCount: Int, promptSHA256: String, workspace: AgentWorkspace,
                runtime: AgentStartupRuntime, context: AgentStartupContextPaths,
                source: AgentRouteSource, createdAt: Date = Date(), updatedAt: Date = Date()) {
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
        self.providerSessionID = providerSessionID
        self.providerLaunchCommand = providerLaunchCommand
        self.providerResumeCommand = providerResumeCommand
        self.promptByteCount = promptByteCount
        self.promptSHA256 = promptSHA256
        self.workspace = workspace
        self.runtime = runtime
        self.context = context
        self.source = source
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
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(receipt).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return destination
    }

    public func load(taskID: String, subtaskID: String) throws -> AgentStartupReceipt? {
        let source = try url(taskID: taskID, subtaskID: subtaskID)
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AgentStartupReceipt.self, from: Data(contentsOf: source))
    }

    public func register(taskID: String, subtaskID: String, providerSessionID: String) throws {
        guard UUID(uuidString: providerSessionID) != nil,
              var receipt = try load(taskID: taskID, subtaskID: subtaskID) else { return }
        receipt.providerSessionID = providerSessionID.lowercased()
        var profile: [String] = []
        if let model = receipt.model { profile += ["--model", model] }
        if let effort = receipt.effort {
            profile += receipt.provider == .codex
                ? ["-c", "model_reasoning_effort=\(effort)"]
                : ["--effort", effort]
        }
        let contextDirectory = URL(fileURLWithPath: receipt.context.taskContext)
            .deletingLastPathComponent().path
        receipt.providerResumeCommand = receipt.provider == .codex
            ? [receipt.provider.executableName, "resume", providerSessionID.lowercased(),
               "--cd", receipt.workspace.path] + profile + ["--add-dir", contextDirectory]
            : [receipt.provider.executableName, "--resume", providerSessionID.lowercased()]
                + profile + ["--add-dir", contextDirectory]
        receipt.status = .registered
        receipt.updatedAt = Date()
        try save(receipt)
    }
}
