import Foundation

/// A project's development process: Planning → Phase 0 → Phase 1+ → Phase N−1 → Phase N.
/// The state lives in `development.json` beside the project's plan; a file with
/// `enabled == true` is the feature flag, so launch briefs read it straight from the
/// project folder without a config round-trip.
public enum DevelopmentPhase: String, Codable, CaseIterable, Sendable {
    case planning, phase0, implementation, prerelease, release

    public var title: String {
        switch self {
        case .planning: "Planning"
        case .phase0: "Phase 0"
        case .implementation: "Phase 1+"
        case .prerelease: "Phase N−1"
        case .release: "Phase N"
        }
    }

    public var next: DevelopmentPhase? {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self), index + 1 < all.count else { return nil }
        return all[index + 1]
    }
}

public enum DevelopmentStepStatus: String, Codable, CaseIterable, Sendable {
    case pending, inProgress, done, accepted

    public var isComplete: Bool { self == .done || self == .accepted }
}

/// One step in the static catalog. State lives in `DevelopmentStepState`; the catalog
/// entry only describes what the step is and what it produces.
public struct DevelopmentStep: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let summary: String
    /// Files the step produces, relative to the project directory.
    public let artifacts: [String]

    public init(id: String, title: String, summary: String, artifacts: [String] = []) {
        self.id = id; self.title = title; self.summary = summary; self.artifacts = artifacts
    }
}

public struct DevelopmentStepState: Codable, Equatable, Sendable {
    public var status: DevelopmentStepStatus
    public var note: String?
    public var updatedAt: Date

    public init(status: DevelopmentStepStatus = .pending, note: String? = nil, updatedAt: Date = Date()) {
        self.status = status; self.note = note; self.updatedAt = updatedAt
    }
}

/// A feature module tracked through the process. Success criteria are accepted
/// strictly in order, matching the sequential human review in the process design.
public struct DevelopmentModule: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// Module design file, relative to the project directory.
    public var file: String?
    public var criteriaAccepted: Bool
    /// Justification of completion was recorded for this module.
    public var implemented: Bool
    /// Human QA verified the module.
    public var qaAccepted: Bool

    public init(id: String = UUID().uuidString.lowercased(), name: String, file: String? = nil,
                criteriaAccepted: Bool = false, implemented: Bool = false, qaAccepted: Bool = false) {
        self.id = id; self.name = name; self.file = file
        self.criteriaAccepted = criteriaAccepted; self.implemented = implemented; self.qaAccepted = qaAccepted
    }
}

public struct DevelopmentProcess: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// The feature flag: projects without a development.json, or with this false,
    /// get no process enforcement in briefs or the tab.
    public var enabled: Bool
    public var currentPhase: DevelopmentPhase
    /// State per catalog step id; a missing entry means pending.
    public var steps: [String: DevelopmentStepState]
    public var modules: [DevelopmentModule]
    public var updatedAt: Date

    public init(enabled: Bool = true, currentPhase: DevelopmentPhase = .planning,
                steps: [String: DevelopmentStepState] = [:], modules: [DevelopmentModule] = [],
                schemaVersion: Int = DevelopmentProcess.currentSchemaVersion, updatedAt: Date = Date()) {
        self.schemaVersion = schemaVersion; self.enabled = enabled
        self.currentPhase = currentPhase; self.steps = steps; self.modules = modules
        self.updatedAt = updatedAt
    }

    public func status(of step: DevelopmentStep) -> DevelopmentStepStatus {
        steps[step.id]?.status ?? .pending
    }

    public var currentSteps: [DevelopmentStep] { DevelopmentProcessCatalog.steps(in: currentPhase) }

    /// Steps that are not yet accepted, per phase; drives the tab and briefs.
    public var pendingSteps: [DevelopmentStep] {
        currentSteps.filter { status(of: $0) != .accepted }
    }

    /// The step to present as current: the active one when a human has marked
    /// it, otherwise the first step that is neither done nor accepted.
    public var currentStep: DevelopmentStep? {
        let steps = currentSteps
        if let active = steps.first(where: { status(of: $0) == .inProgress }) { return active }
        return steps.first { !status(of: $0).isComplete }
    }

    public var phaseIsAccepted: Bool {
        currentSteps.allSatisfy { status(of: $0) == .accepted }
    }
}

/// The fixed phase and step catalog from the FOC-117 process design.
public enum DevelopmentProcessCatalog {
    public static func steps(in phase: DevelopmentPhase) -> [DevelopmentStep] {
        switch phase {
        case .planning:
            return [
                DevelopmentStep(id: "concept", title: "Concept declaration",
                    summary: "Functional criteria and main idea; the AI asks clarifying questions.",
                    artifacts: ["concept.md"]),
                DevelopmentStep(id: "research", title: "Research & system design",
                    summary: "Evidence compendium, then an explicit system design with a flow chart.",
                    artifacts: ["research.md", "design.md"]),
                DevelopmentStep(id: "prd", title: "Technical design & PRD",
                    summary: "Solidified technical and design choices, linked docs, and a flow chart.",
                    artifacts: ["prd.md"]),
                DevelopmentStep(id: "modules", title: "Module design files",
                    summary: "One file per feature: purpose, I/O endpoints and schemas, success criteria, debug logs. Accept each module's success criteria in order."),
                DevelopmentStep(id: "devplan", title: "Development plan",
                    summary: "Rough outline with a dependency tree; the human creates and checks off tasks.",
                    artifacts: ["devplan.md"]),
                DevelopmentStep(id: "contract", title: "Agent contract & orchestration",
                    summary: "Project system prompt for engineering agents plus orchestrator guidelines; the human reads both.",
                    artifacts: ["agent-contract.md", "orchestration.md"]),
            ]
        case .phase0:
            return [
                DevelopmentStep(id: "scaffolding", title: "Scaffolding & environment",
                    summary: "Scaffolding, CI, installs, environment setup, auths and keys, debug logs. Blockers go to the user for re-triage."),
                DevelopmentStep(id: "phase0-qa", title: "Phase 0 QA",
                    summary: "Justify each Phase 0 module's completion; the human verifies."),
            ]
        case .implementation:
            return [
                DevelopmentStep(id: "modules", title: "Module implementation",
                    summary: "Parallel module work; blockers are collected and re-triaged with the user."),
                DevelopmentStep(id: "module-qa", title: "Module QA",
                    summary: "Justify each module's completion; the human verifies."),
            ]
        case .prerelease:
            return [
                DevelopmentStep(id: "beta", title: "Beta testing & full QA",
                    summary: "Beta testing and full QA across the product."),
                DevelopmentStep(id: "latency", title: "Latency & optimization",
                    summary: "Measure latency against thresholds; optimize failing pipelines and repeat."),
            ]
        case .release:
            return [
                DevelopmentStep(id: "security", title: "Security review",
                    summary: "Static analysis and enforcement."),
                DevelopmentStep(id: "staging", title: "Staging & hardening",
                    summary: "Optional staging deploy, verification, network performance, security hardening."),
                DevelopmentStep(id: "deployment", title: "Deployment & distribution",
                    summary: "Ship and distribute."),
            ]
        }
    }

    public static func step(id: String, in phase: DevelopmentPhase) -> DevelopmentStep? {
        steps(in: phase).first { $0.id == id }
    }

    /// Guidance injected into agent briefs while the phase runs. Concise, action-first.
    public static func brief(for phase: DevelopmentPhase) -> String {
        switch phase {
        case .planning:
            "Produce planning artifacts, not implementation. Ask clarifying questions before writing; each artifact lands in the project folder as Markdown."
        case .phase0:
            "Scaffolding, CI, installs, environment, auths, and debug logs only. Surface blockers with `attention`; justify each Phase 0 module in your result."
        case .implementation:
            "Implement your assigned modules. Surface blockers with `attention`; justify each module's completion against its success criteria in your result."
        case .prerelease:
            "Beta testing, full QA, and latency measurement. Optimize failing pipelines and re-measure before marking work done."
        case .release:
            "Security review, staging verification, and hardening. No new features."
        }
    }
}

public enum DevelopmentProcessError: Error, Equatable {
    /// Module success criteria must be accepted in listed order.
    case outOfOrderAcceptance(module: String, blockedBy: String)
    case unknownModule(String)
    case unknownStep(String)
}

extension DevelopmentProcessError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .outOfOrderAcceptance(let module, let blockedBy):
            "Accept \(blockedBy)'s success criteria before \(module)'s; modules are reviewed in order."
        case .unknownModule(let id): "No module with id \(id)."
        case .unknownStep(let id): "No step with id \(id) in the current phase."
        }
    }
}

/// Loads and saves `development.json` in a project directory, beside plan.md.
public struct DevelopmentProcessStore: Sendable {
    public static let fileName = "development.json"

    public let root: URL
    public init(root: URL) { self.root = root }

    public func url(projectID: String) throws -> URL {
        try ProjectContextStore(root: root).planURL(projectID: projectID)
            .deletingLastPathComponent()
            .appendingPathComponent(Self.fileName)
    }

    public func load(projectID: String) throws -> DevelopmentProcess? {
        let url = try url(projectID: projectID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try JSONDecoder().decode(DevelopmentProcess.self, from: data)
    }

    /// Creates the default process file when missing and returns the state.
    @discardableResult
    public func ensure(projectID: String) throws -> DevelopmentProcess {
        if let existing = try load(projectID: projectID) { return existing }
        let process = DevelopmentProcess()
        try save(process, projectID: projectID)
        return process
    }

    public func save(_ process: DevelopmentProcess, projectID: String) throws {
        let url = try url(projectID: projectID)
        let directory = url.deletingLastPathComponent()
        guard (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw TaskContextError.commandFailed("Development process storage is redirected.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var copy = process
        copy.updatedAt = Date()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(copy)
        try ProjectFileLock.withLock(file: url) {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    public func setEnabled(_ enabled: Bool, projectID: String) throws -> DevelopmentProcess {
        var process = (try load(projectID: projectID)) ?? DevelopmentProcess(enabled: enabled)
        process.enabled = enabled
        try save(process, projectID: projectID)
        return process
    }

    public func setStepStatus(_ status: DevelopmentStepStatus, stepID: String,
                              projectID: String, note: String? = nil) throws -> DevelopmentProcess {
        var process = try ensure(projectID: projectID)
        guard DevelopmentProcessCatalog.step(id: stepID, in: process.currentPhase) != nil else {
            throw DevelopmentProcessError.unknownStep(stepID)
        }
        process.steps[stepID] = DevelopmentStepState(status: status, note: note)
        try save(process, projectID: projectID)
        return process
    }

    public func setPhase(_ phase: DevelopmentPhase, projectID: String) throws -> DevelopmentProcess {
        var process = try ensure(projectID: projectID)
        process.currentPhase = phase
        try save(process, projectID: projectID)
        return process
    }

    public func addModule(name: String, file: String?, projectID: String) throws -> DevelopmentProcess {
        var process = try ensure(projectID: projectID)
        process.modules.append(DevelopmentModule(name: name, file: file))
        try save(process, projectID: projectID)
        return process
    }

    /// Sequential acceptance: a module's criteria can be accepted only after every
    /// module listed before it.
    public func acceptCriteria(moduleID: String, projectID: String) throws -> DevelopmentProcess {
        var process = try ensure(projectID: projectID)
        guard let index = process.modules.firstIndex(where: { $0.id == moduleID }) else {
            throw DevelopmentProcessError.unknownModule(moduleID)
        }
        if let blocker = process.modules[..<index].first(where: { !$0.criteriaAccepted }) {
            throw DevelopmentProcessError.outOfOrderAcceptance(
                module: process.modules[index].name, blockedBy: blocker.name)
        }
        process.modules[index].criteriaAccepted = true
        try save(process, projectID: projectID)
        return process
    }

    public func setModuleImplemented(_ implemented: Bool, moduleID: String,
                                     projectID: String) throws -> DevelopmentProcess {
        var process = try ensure(projectID: projectID)
        guard let index = process.modules.firstIndex(where: { $0.id == moduleID }) else {
            throw DevelopmentProcessError.unknownModule(moduleID)
        }
        process.modules[index].implemented = implemented
        try save(process, projectID: projectID)
        return process
    }

    public func setModuleQAAccepted(_ accepted: Bool, moduleID: String,
                                    projectID: String) throws -> DevelopmentProcess {
        var process = try ensure(projectID: projectID)
        guard let index = process.modules.firstIndex(where: { $0.id == moduleID }) else {
            throw DevelopmentProcessError.unknownModule(moduleID)
        }
        process.modules[index].qaAccepted = accepted
        try save(process, projectID: projectID)
        return process
    }
}
