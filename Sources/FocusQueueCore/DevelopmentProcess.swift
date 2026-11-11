import Foundation

/// A project's development process: Planning → Phase 0 → Phase 1+ → Phase N−1 → Phase N.
/// The state lives in `development.json` beside the project's plan; a file with
/// `enabled == true` is the feature flag, so launch briefs read it straight from the
/// project folder without a config round-trip.
///
/// Updates happen outside working agents: the human accepts steps in the Project tab,
/// task status raises linked steps deterministically (`reconcile`), and the placement
/// model links new tasks and files to steps in the background (`DevelopmentSteward`).
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

    /// Automatic updates only raise a step; this order defines "raise".
    public var rank: Int {
        switch self {
        case .pending: 0
        case .inProgress: 1
        case .done: 2
        case .accepted: 3
        }
    }
}

/// Who last changed a step or link. Automatic sources never override a human.
public enum DevelopmentUpdateSource: String, Codable, Sendable {
    case human
    /// Derived from linked task status, no model involved.
    case tasks
    /// Proposed by the background placement-model steward.
    case steward
}

/// One step in the static catalog. State lives in `DevelopmentStepState`; the catalog
/// entry only describes what the step is and what it produces.
public struct DevelopmentStep: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let summary: String
    /// Files the step produces, relative to the project directory.
    public let artifacts: [String]
    /// The planning guideline for the step (experimental; see `DevelopmentGuidelines`).
    public let guideline: String?
    /// Documents the step produces only while the project uses planning guidelines.
    public let guidelineArtifacts: [String]
    /// An experimental step is tracked and shown but never gates the phase: it is
    /// not required for phase acceptance, never the current step, and never listed
    /// as a next step. Its documents can start as stubs and fill in later phases.
    public let isExperimental: Bool

    public init(id: String, title: String, summary: String, artifacts: [String] = [],
                guideline: String? = nil, guidelineArtifacts: [String] = [],
                isExperimental: Bool = false) {
        self.id = id; self.title = title; self.summary = summary; self.artifacts = artifacts
        self.guideline = guideline; self.guidelineArtifacts = guidelineArtifacts
        self.isExperimental = isExperimental
    }
}

public struct DevelopmentStepState: Codable, Equatable, Sendable {
    public var status: DevelopmentStepStatus
    /// Human note, or the evidence an automatic source cited.
    public var note: String?
    public var updatedAt: Date
    /// nil in files written before automatic updates existed; read as human.
    public var source: DevelopmentUpdateSource?
    /// Artifact file names the human checked off in the document viewer.
    public var checkedArtifacts: [String]

    public init(status: DevelopmentStepStatus = .pending, note: String? = nil, updatedAt: Date = Date(),
                source: DevelopmentUpdateSource? = .human, checkedArtifacts: [String] = []) {
        self.status = status; self.note = note; self.updatedAt = updatedAt; self.source = source
        self.checkedArtifacts = checkedArtifacts
    }

    private enum CodingKeys: String, CodingKey { case status, note, updatedAt, source, checkedArtifacts }

    /// Files written before artifact reviews lack the key; read them as unchecked.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(DevelopmentStepStatus.self, forKey: .status)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        source = try container.decodeIfPresent(DevelopmentUpdateSource.self, forKey: .source)
        checkedArtifacts = try container.decodeIfPresent([String].self, forKey: .checkedArtifacts) ?? []
    }

    public var isAutomatic: Bool { source == .tasks || source == .steward }
}

/// Which step (and optionally module) a task serves. A nil step records that the
/// task is outside the process, so its agents get no process line at all.
public struct DevelopmentTaskLink: Codable, Equatable, Sendable {
    public var phase: DevelopmentPhase
    public var step: String?
    public var moduleID: String?
    public var source: DevelopmentUpdateSource
    public var updatedAt: Date

    public init(phase: DevelopmentPhase, step: String?, moduleID: String? = nil,
                source: DevelopmentUpdateSource, updatedAt: Date = Date()) {
        self.phase = phase; self.step = step; self.moduleID = moduleID
        self.source = source; self.updatedAt = updatedAt
    }
}

/// The last background steward pass. The signature covers only what needs a model
/// (unlinked tasks, project files, phase), so ordinary status changes never re-run it.
public struct DevelopmentStewardRun: Codable, Equatable, Sendable {
    public var signature: String
    public var ranAt: Date
    public var model: String?
    public var error: String?
    public var summary: String?

    public init(signature: String, ranAt: Date = Date(), model: String? = nil,
                error: String? = nil, summary: String? = nil) {
        self.signature = signature; self.ranAt = ranAt; self.model = model
        self.error = error; self.summary = summary
    }
}

/// The task facts the process needs, independent of the dashboard schema.
public struct DevelopmentTicket: Equatable, Sendable {
    public var id: String
    public var title: String
    public var summary: String
    public var status: String
    public var isOpen: Bool
    public var updatedAt: String?

    public init(id: String, title: String, summary: String = "", status: String, isOpen: Bool,
                updatedAt: String? = nil) {
        self.id = id.uppercased(); self.title = title; self.summary = summary
        self.status = status; self.isOpen = isOpen; self.updatedAt = updatedAt
    }

    public init(_ ticket: DashboardTicket) {
        self.init(id: ticket.id, title: ticket.title, summary: ticket.summary, status: ticket.status,
                  isOpen: ticket.isOpen, updatedAt: ticket.updatedAt)
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
    /// Task ID (uppercase) → the step it serves.
    public var links: [String: DevelopmentTaskLink]
    /// Task ID (uppercase) → the task IDs it waits on. Human-set; drives the
    /// phase view's dependency order and the dependency line on each card.
    public var dependencies: [String: [String]]
    public var steward: DevelopmentStewardRun?
    /// Role (`engineering`, `orchestrator`) → the owner's sign-off of that agent
    /// contract. Only signed text reaches agents; see `AgentContract`.
    public var contracts: [String: AgentContractSignoff]
    /// Experimental planning guidelines (KAI-016). Nil is off, and keeps the file,
    /// the tab, and briefs exactly as before the feature existed.
    public var planningGuidelines: Bool?
    /// Catalog document → this project's own file name, for projects whose
    /// documents predate the catalog names. Applies only with guidelines on.
    public var artifactNames: [String: String]?
    public var updatedAt: Date

    public init(enabled: Bool = true, currentPhase: DevelopmentPhase = .planning,
                steps: [String: DevelopmentStepState] = [:], modules: [DevelopmentModule] = [],
                links: [String: DevelopmentTaskLink] = [:], dependencies: [String: [String]] = [:],
                steward: DevelopmentStewardRun? = nil,
                contracts: [String: AgentContractSignoff] = [:],
                schemaVersion: Int = DevelopmentProcess.currentSchemaVersion, updatedAt: Date = Date()) {
        self.schemaVersion = schemaVersion; self.enabled = enabled
        self.currentPhase = currentPhase; self.steps = steps; self.modules = modules
        self.links = links; self.dependencies = dependencies
        self.steward = steward; self.contracts = contracts
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, enabled, currentPhase, steps, modules, links, dependencies, steward, contracts
        case planningGuidelines, artifactNames, updatedAt
    }

    /// Every field is optional on read, so files from earlier builds and partial
    /// hand-written files decode instead of failing the Project tab.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        currentPhase = try container.decodeIfPresent(DevelopmentPhase.self, forKey: .currentPhase) ?? .planning
        steps = try container.decodeIfPresent([String: DevelopmentStepState].self, forKey: .steps) ?? [:]
        modules = try container.decodeIfPresent([DevelopmentModule].self, forKey: .modules) ?? []
        links = try container.decodeIfPresent([String: DevelopmentTaskLink].self, forKey: .links) ?? [:]
        dependencies = try container.decodeIfPresent([String: [String]].self, forKey: .dependencies) ?? [:]
        steward = try container.decodeIfPresent(DevelopmentStewardRun.self, forKey: .steward)
        contracts = try container.decodeIfPresent([String: AgentContractSignoff].self, forKey: .contracts) ?? [:]
        planningGuidelines = try container.decodeIfPresent(Bool.self, forKey: .planningGuidelines)
        artifactNames = try container.decodeIfPresent([String: String].self, forKey: .artifactNames)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    public func status(of step: DevelopmentStep) -> DevelopmentStepStatus {
        steps[step.id]?.status ?? .pending
    }

    public var currentSteps: [DevelopmentStep] { DevelopmentProcessCatalog.steps(in: currentPhase) }

    /// The current phase's steps that gate it; experimental steps never do.
    public var gatingSteps: [DevelopmentStep] { currentSteps.filter { !$0.isExperimental } }

    /// Gating steps that are not yet accepted; drives the tab and briefs.
    public var pendingSteps: [DevelopmentStep] {
        gatingSteps.filter { status(of: $0) != .accepted }
    }

    /// The step to present as current: the active one when a human has marked
    /// it, otherwise the first step that is neither done nor accepted.
    /// Experimental steps are never current, so they cannot hold a phase back.
    public var currentStep: DevelopmentStep? {
        let steps = gatingSteps
        if let active = steps.first(where: { status(of: $0) == .inProgress }) { return active }
        return steps.first { !status(of: $0).isComplete }
    }

    /// Every gating step is accepted. Experimental steps may stay open.
    public var phaseIsAccepted: Bool {
        gatingSteps.allSatisfy { status(of: $0) == .accepted }
    }

    /// Open linked tasks that belong to a phase after the current one: the
    /// tracker is behind the real work. The phase itself stays a human move.
    public func tasksAhead(tickets: [DevelopmentTicket]) -> (phase: DevelopmentPhase, taskIDs: [String])? {
        let open = Set(tickets.filter(\.isOpen).map(\.id))
        let order = DevelopmentPhase.allCases
        guard let current = order.firstIndex(of: currentPhase) else { return nil }
        let ahead = links.filter { taskID, link in
            link.step != nil && open.contains(taskID)
                && (order.firstIndex(of: link.phase) ?? 0) > current
        }
        guard let nearest = ahead.values.map(\.phase).min(by: {
            (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0)
        }) else { return nil }
        return (nearest, ahead.filter { $0.value.phase == nearest }.keys.sorted())
    }

    /// Task IDs linked to a current-phase step, sorted for stable display.
    public func linkedTaskIDs(step stepID: String) -> [String] {
        links.filter { $0.value.phase == currentPhase && $0.value.step == stepID }.keys.sorted()
    }

    public func linkedTaskIDs(module moduleID: String) -> [String] {
        links.filter { $0.value.moduleID == moduleID }.keys.sorted()
    }

    /// The phase the queue groups a task under: its linked step's phase, or
    /// nil when the task is unlinked or marked outside the process.
    public func phase(ofTask taskID: String) -> DevelopmentPhase? {
        guard let link = links[taskID.uppercased()], link.step != nil else { return nil }
        return link.phase
    }

    /// The task IDs `taskID` waits on, in stored order.
    public func prerequisites(of taskID: String) -> [String] {
        dependencies[taskID.uppercased()] ?? []
    }

    /// Validated in-place edit behind `DevelopmentProcessStore.setDependencies`.
    public mutating func setDependencies(taskID: String, prerequisites: [String]) throws {
        let taskID = taskID.uppercased()
        var unique: [String] = []
        for raw in prerequisites {
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard !id.isEmpty, !unique.contains(id) else { continue }
            guard id != taskID else { throw DevelopmentProcessError.dependencyCycle([taskID, taskID]) }
            unique.append(id)
        }
        var next = dependencies
        if unique.isEmpty { next.removeValue(forKey: taskID) } else { next[taskID] = unique }
        if let cycle = Self.cycle(in: next, from: taskID) {
            throw DevelopmentProcessError.dependencyCycle(cycle)
        }
        dependencies = next
    }

    /// The first cycle reachable from `start`, as a closed path, or nil.
    static func cycle(in graph: [String: [String]], from start: String) -> [String]? {
        var path: [String] = []
        var finished: Set<String> = []
        func visit(_ node: String) -> [String]? {
            if let index = path.firstIndex(of: node) { return Array(path[index...]) + [node] }
            guard !finished.contains(node) else { return nil }
            path.append(node)
            for next in graph[node] ?? [] { if let found = visit(next) { return found } }
            path.removeLast()
            finished.insert(node)
            return nil
        }
        return visit(start)
    }

    /// Raises a current-phase step without ever lowering it or reaching `accepted`,
    /// which stays a human decision. A step a human reset to pending holds there.
    /// Returns whether anything changed.
    @discardableResult
    public mutating func raise(stepID: String, to status: DevelopmentStepStatus,
                               source: DevelopmentUpdateSource, note: String?, now: Date = Date()) -> Bool {
        guard status != .accepted, source != .human,
              DevelopmentProcessCatalog.step(id: stepID, in: currentPhase) != nil else { return false }
        let existing = steps[stepID]
        if let existing, !existing.isAutomatic, existing.status == .pending { return false }
        guard status.rank > (existing?.status ?? .pending).rank else { return false }
        steps[stepID] = DevelopmentStepState(status: status, note: note ?? existing?.note,
                                             updatedAt: now, source: source,
                                             checkedArtifacts: existing?.checkedArtifacts ?? [])
        return true
    }

    /// Deterministic progress from linked tasks: an open linked task makes its step
    /// active; once every linked task is closed the step is done and its modules are
    /// implemented. Links to tasks that no longer exist are dropped. No model call.
    @discardableResult
    public mutating func reconcile(tickets: [DevelopmentTicket], now: Date = Date()) -> Bool {
        let byID = Dictionary(tickets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var changed = false
        for taskID in links.keys where byID[taskID] == nil {
            links.removeValue(forKey: taskID); changed = true
        }
        for (taskID, prerequisites) in dependencies {
            let kept = byID[taskID] == nil ? [] : prerequisites.filter { byID[$0] != nil }
            guard kept != prerequisites else { continue }
            if kept.isEmpty { dependencies.removeValue(forKey: taskID) } else { dependencies[taskID] = kept }
            changed = true
        }
        for step in currentSteps {
            let linked = linkedTaskIDs(step: step.id).compactMap { byID[$0] }
            guard !linked.isEmpty else { continue }
            let open = linked.filter(\.isOpen)
            let target: DevelopmentStepStatus = open.isEmpty ? .done : .inProgress
            let evidence = open.isEmpty
                ? "Linked tasks closed: \(linked.map(\.id).joined(separator: ", "))."
                : "Linked tasks open: \(open.map(\.id).joined(separator: ", "))."
            if raise(stepID: step.id, to: target, source: .tasks, note: evidence, now: now) { changed = true }
        }
        for index in modules.indices where !modules[index].implemented {
            let linked = linkedTaskIDs(module: modules[index].id).compactMap { byID[$0] }
            if !linked.isEmpty, linked.allSatisfy({ !$0.isOpen }) {
                modules[index].implemented = true; changed = true
            }
        }
        return changed
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
                    artifacts: ["concept.md"], guideline: "concept-guideline.md"),
                DevelopmentStep(id: "research", title: "Research & system design",
                    summary: "Evidence compendium, then an explicit system design with a flow chart.",
                    artifacts: ["research.md", "design.md"], guideline: "research-guideline.md"),
                DevelopmentStep(id: "prd", title: "Technical design & PRD",
                    summary: "Solidified technical and design choices, linked docs, and a flow chart.",
                    artifacts: ["prd.md"], guideline: "prd-guideline.md",
                    guidelineArtifacts: ["technical-design.md"]),
                DevelopmentStep(id: "modules", title: "Module design files",
                    summary: "Experimental, optional: one file per module, started as a stub and filled to implementation depth in the phase that builds it. Never blocks the phase.",
                    guideline: "module-guideline.md", isExperimental: true),
                DevelopmentStep(id: "devplan", title: "Development plan",
                    summary: "Rough outline with a dependency tree; the human creates and checks off tasks.",
                    artifacts: ["devplan.md"], guideline: "devplan-guideline.md"),
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
                // Distinct from Planning's "modules": step state is keyed by ID alone.
                DevelopmentStep(id: "build", title: "Module implementation",
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

    /// Step IDs are unique across phases, so an ID alone names its phase.
    public static func phase(ofStep id: String) -> DevelopmentPhase? {
        DevelopmentPhase.allCases.first { step(id: id, in: $0) != nil }
    }

    /// The catalog step that produces a file name, across all phases, so the
    /// document viewer can offer a review toggle even after the phase moved on.
    public static func step(forArtifact fileName: String, includingGuidelineArtifacts: Bool = false) -> DevelopmentStep? {
        DevelopmentPhase.allCases.lazy.flatMap { steps(in: $0) }.first {
            $0.artifacts.contains(fileName) || (includingGuidelineArtifacts && $0.guidelineArtifacts.contains(fileName))
        }
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
    /// A document cannot be checked off before it exists.
    case missingArtifact(String)
    /// A dependency edit would make tasks wait on each other; the closed path.
    case dependencyCycle([String])
}

extension DevelopmentProcessError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .outOfOrderAcceptance(let module, let blockedBy):
            "Accept \(blockedBy)'s success criteria before \(module)'s; modules are reviewed in order."
        case .unknownModule(let id): "No module with id \(id)."
        case .unknownStep(let id): "No step with id \(id) in this phase."
        case .missingArtifact(let file): "\(file) does not exist yet; create the document before checking it off."
        case .dependencyCycle(let path):
            path.count == 2 && path[0] == path[1]
                ? "\(path[0]) cannot depend on itself."
                : "Dependencies would form a cycle: \(path.joined(separator: " → "))."
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
        return try mutate(projectID: projectID) { _ in }
    }

    public func save(_ process: DevelopmentProcess, projectID: String) throws {
        let url = try validatedURL(projectID: projectID)
        var stamped = process
        stamped.updatedAt = Date()
        try ProjectFileLock.withLock(file: url) { try write(stamped, to: url) }
    }

    /// The single write path: load, edit, and write under one lock, so the app,
    /// the CLI, and the background steward never drop each other's changes.
    /// A missing file starts from the default (enabled) process.
    @discardableResult
    public func mutate(projectID: String,
                       _ body: (inout DevelopmentProcess) throws -> Void) throws -> DevelopmentProcess {
        let url = try validatedURL(projectID: projectID)
        return try ProjectFileLock.withLock(file: url) {
            let existed = FileManager.default.fileExists(atPath: url.path)
            // A malformed file throws here and is never overwritten.
            var process = existed
                ? try JSONDecoder().decode(DevelopmentProcess.self, from: Data(contentsOf: url))
                : DevelopmentProcess()
            let original = process
            try body(&process)
            guard process != original || !existed else { return process }
            process.updatedAt = Date()
            try write(process, to: url)
            return process
        }
    }

    private func validatedURL(projectID: String) throws -> URL {
        let url = try url(projectID: projectID)
        let directory = url.deletingLastPathComponent()
        guard (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw TaskContextError.commandFailed("Development process storage is redirected.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return url
    }

    /// Caller holds the lock and has stamped `updatedAt`, so the value a mutation
    /// returns is exactly what is on disk.
    private func write(_ process: DevelopmentProcess, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(process).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func setEnabled(_ enabled: Bool, projectID: String) throws -> DevelopmentProcess {
        try mutate(projectID: projectID) { $0.enabled = enabled }
    }

    /// A human status change. Accepting the last step of a phase advances the
    /// project to the next phase, so the tracker never waits on an extra click.
    /// Document check-offs survive status changes: the documents stay reviewed.
    public func setStepStatus(_ status: DevelopmentStepStatus, stepID: String,
                              projectID: String, note: String? = nil) throws -> DevelopmentProcess {
        try mutate(projectID: projectID) { process in
            guard DevelopmentProcessCatalog.step(id: stepID, in: process.currentPhase) != nil else {
                throw DevelopmentProcessError.unknownStep(stepID)
            }
            let checked = process.steps[stepID]?.checkedArtifacts ?? []
            process.steps[stepID] = DevelopmentStepState(status: status, note: note, source: .human,
                                                         checkedArtifacts: checked)
            if status == .accepted, process.phaseIsAccepted, let next = process.currentPhase.next {
                process.currentPhase = next
            }
        }
    }

    /// A step artifact lives beside the project plan. Artifact names come from
    /// the catalog, so this never addresses a path outside the project folder.
    public func artifactURL(projectID: String, artifact: String) throws -> URL {
        try url(projectID: projectID).deletingLastPathComponent().appendingPathComponent(artifact)
    }

    /// The project's file for a catalog document, through its `artifactNames` map.
    public func artifactURL(projectID: String, artifact: String, process: DevelopmentProcess?) throws -> URL {
        try artifactURL(projectID: projectID, artifact: process?.fileName(forArtifact: artifact) ?? artifact)
    }

    /// A human document check-off from the Project tab's document viewer. When
    /// every artifact of the step exists on disk and is checked off, the step
    /// is marked done; acceptance and phase moves stay explicit human clicks.
    /// Unchecking never lowers the status: the marker is the user's control.
    public func setArtifactChecked(_ checked: Bool, stepID: String, artifact: String,
                                   projectID: String) throws -> DevelopmentProcess {
        return try mutate(projectID: projectID) { process in
            guard let step = DevelopmentProcessCatalog.step(
                    forArtifact: artifact, includingGuidelineArtifacts: process.usesPlanningGuidelines),
                  step.id == stepID else {
                throw DevelopmentProcessError.unknownStep(stepID)
            }
            let file = try artifactURL(projectID: projectID, artifact: artifact, process: process)
            if checked, !FileManager.default.fileExists(atPath: file.path) {
                throw DevelopmentProcessError.missingArtifact(process.fileName(forArtifact: artifact))
            }
            if checked {
                try checkOffArtifact(artifact, in: &process, projectID: projectID)
            } else {
                var state = process.steps[stepID] ?? DevelopmentStepState()
                state.checkedArtifacts.removeAll { $0 == artifact }
                state.source = state.source ?? .human
                process.steps[stepID] = state
            }
        }
    }

    /// Checks a step document off inside a mutation. When every document of the
    /// step exists and is checked off, the step is marked done.
    func checkOffArtifact(_ artifact: String, in process: inout DevelopmentProcess,
                          projectID: String) throws {
        guard let step = DevelopmentProcessCatalog.step(
                forArtifact: artifact, includingGuidelineArtifacts: process.usesPlanningGuidelines) else {
            throw DevelopmentProcessError.unknownStep(artifact)
        }
        var state = process.steps[step.id] ?? DevelopmentStepState()
        if !state.checkedArtifacts.contains(artifact) { state.checkedArtifacts.append(artifact) }
        state.source = state.source ?? .human
        // Guideline-only documents (technical-design.md) are experimental, so
        // they never hold the step back: the catalog documents decide "done".
        let artifacts = step.artifacts.isEmpty ? process.artifacts(of: step) : step.artifacts
        let allChecked = artifacts.allSatisfy { state.checkedArtifacts.contains($0) }
        if allChecked, !state.status.isComplete,
           artifacts.allSatisfy({ [process] in
               (try? artifactURL(projectID: projectID, artifact: $0, process: process))
                   .map { FileManager.default.fileExists(atPath: $0.path) } ?? false
           }) {
            state.status = .done
            state.note = "All documents reviewed."
            state.source = .human
        }
        process.steps[step.id] = state
    }

    public func setPhase(_ phase: DevelopmentPhase, projectID: String) throws -> DevelopmentProcess {
        try mutate(projectID: projectID) { $0.currentPhase = phase }
    }

    public func addModule(name: String, file: String?, projectID: String) throws -> DevelopmentProcess {
        try mutate(projectID: projectID) { $0.modules.append(DevelopmentModule(name: name, file: file)) }
    }

    /// A human link: the steward never overrides it. A nil step marks the task as
    /// outside the process. `module` matches a module name or ID.
    public func link(taskID: String, step: String?, module: String? = nil,
                     projectID: String) throws -> DevelopmentProcess {
        try mutate(projectID: projectID) { process in
            var phase = process.currentPhase
            if let step {
                guard let owner = DevelopmentProcessCatalog.phase(ofStep: step) else {
                    throw DevelopmentProcessError.unknownStep(step)
                }
                phase = owner
            }
            var moduleID: String?
            if let module, !module.isEmpty {
                guard let match = process.modules.first(where: {
                    $0.id == module || $0.name.caseInsensitiveCompare(module) == .orderedSame
                }) else { throw DevelopmentProcessError.unknownModule(module) }
                moduleID = match.id
            }
            process.links[taskID.uppercased()] = DevelopmentTaskLink(
                phase: phase, step: step, moduleID: moduleID, source: .human)
        }
    }

    public func unlink(taskID: String, projectID: String) throws -> DevelopmentProcess {
        try mutate(projectID: projectID) { $0.links.removeValue(forKey: taskID.uppercased()) }
    }

    /// A human dependency edit: `taskID` waits on `prerequisites`, replacing any
    /// earlier list. An empty list clears it. Self-references and cycles throw,
    /// so the phase view always has a valid order.
    public func setDependencies(taskID: String, prerequisites: [String],
                                projectID: String) throws -> DevelopmentProcess {
        try mutate(projectID: projectID) { process in
            try process.setDependencies(taskID: taskID, prerequisites: prerequisites)
        }
    }

    /// Sequential acceptance: a module's criteria can be accepted only after every
    /// module listed before it.
    public func acceptCriteria(moduleID: String, projectID: String) throws -> DevelopmentProcess {
        try mutate(projectID: projectID) { process in
            guard let index = process.modules.firstIndex(where: { $0.id == moduleID }) else {
                throw DevelopmentProcessError.unknownModule(moduleID)
            }
            if let blocker = process.modules[..<index].first(where: { !$0.criteriaAccepted }) {
                throw DevelopmentProcessError.outOfOrderAcceptance(
                    module: process.modules[index].name, blockedBy: blocker.name)
            }
            process.modules[index].criteriaAccepted = true
        }
    }

    public func setModuleImplemented(_ implemented: Bool, moduleID: String,
                                     projectID: String) throws -> DevelopmentProcess {
        try mutate(projectID: projectID) { process in
            guard let index = process.modules.firstIndex(where: { $0.id == moduleID }) else {
                throw DevelopmentProcessError.unknownModule(moduleID)
            }
            process.modules[index].implemented = implemented
        }
    }

    public func setModuleQAAccepted(_ accepted: Bool, moduleID: String,
                                    projectID: String) throws -> DevelopmentProcess {
        try mutate(projectID: projectID) { process in
            guard let index = process.modules.firstIndex(where: { $0.id == moduleID }) else {
                throw DevelopmentProcessError.unknownModule(moduleID)
            }
            process.modules[index].qaAccepted = accepted
        }
    }
}
