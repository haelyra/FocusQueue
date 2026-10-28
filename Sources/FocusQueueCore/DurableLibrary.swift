import CryptoKit
import Darwin
import Foundation

public struct LibraryTask: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var ticketID: String
    public var title: String
    public var summary: String
    public var successCriteria: String
    public var status: String?
    public var priority: String?
    public var sourceUpdatedAt: Date?
    public var subtasks: [LibrarySubtask]
}

public struct LibrarySubtask: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var legacyID: String
    public var title: String
    public var status: String
    public var progressSummary: String
    public var lastHeartbeatAt: Date?
    public var lastOutputAt: Date?
    public var isCurrent = true
    public var parentSubtaskID: String?
    public var mergedIntoSubtaskID: String?
}

public struct LibrarySession: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var provider: String
    public var nativeSessionID: String
    public var providerInstallationID: UUID
    /// Unknown legacy accounts stay unknown. Credentials are never copied here.
    public var providerAccountRef: String?
    public var firstRecordedAt: Date
}

public struct LibraryAssignment: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var taskID: UUID
    public var sessionID: UUID
    public var subtaskID: UUID?
    public var source: String
    /// Import time is not an invented historical start time.
    public var recordedAt: Date
    public var endedAt: Date?
    /// Current relationship only; never evidence that an agent process is running.
    public var isCurrent: Bool { source != "historical-context" && endedAt == nil }
}

public struct LibraryExecutionLocator: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var sessionID: UUID
    public var deviceID: UUID
    public var workingDirectory: String?
    public var pathSource: String
    public var windowID: Int?
    public var tabID: Int?
    public var paneID: Int?
    public var availability: String = "unverified"
    public var recordedAt: Date
}

public struct LibraryRepository: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var taskID: UUID
    public var deviceID: UUID
    public var repositoryPath: String?
    public var worktreePath: String?
    public var branch: String?
    public var baseBranch: String?
    public var managedWorktree: Bool
}

public struct LibraryDocumentRevision: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var sha256: String
    public var blobPath: String
    public var byteCount: Int
    public var recordedAt: Date
}

public struct LibraryDocument: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var taskID: UUID?
    public var kind: String
    public var title: String
    /// Provenance only. Reading the retained document uses its relative blobPath.
    public var sourcePath: String
    public var sourceDeviceID: UUID
    public var revisions: [LibraryDocumentRevision]
}

public struct LibraryReportRun: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var nativeRunID: String
    public var reportDate: String?
    public var status: String
    public var documentID: UUID
}

public struct LibraryChange: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var revision: Int
    public var deviceID: UUID
    public var recordedAt: Date
    public var operation: String
}

public struct DurableLibrary: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var workspaceID: UUID
    public var name: String
    public var storageMode = "local"
    public var revision = 0
    public var tasks: [LibraryTask] = []
    public var sessions: [LibrarySession] = []
    public var assignments: [LibraryAssignment] = []
    public var executionLocators: [LibraryExecutionLocator] = []
    public var repositories: [LibraryRepository] = []
    public var documents: [LibraryDocument] = []
    public var reportRuns: [LibraryReportRun] = []
    public var changes: [LibraryChange] = []
    public var importWarnings: [String] = []
}

public struct DurableLibrarySummary: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var workspaceID: UUID
    public var deviceID: UUID
    public var storageMode: String
    public var revision: Int
    public var tasks: Int
    public var sessions: Int
    public var assignments: Int
    public var documents: Int
    public var documentRevisions: Int
    public var unknownAccounts: Int
    public var warnings: [String]
}

public enum DurableLibraryError: Error, LocalizedError {
    case unsupportedVersion(Int), unsafePath(String), invalidData(String), destinationExists(String)
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): "Library schema \(version) is newer than this app supports. Update the app; the library was left unchanged."
        case .unsafePath(let path): "Library operation refused an unsafe or linked path: \(path)"
        case .invalidData(let detail): "Library data is invalid: \(detail)"
        case .destinationExists(let path): "Choose a new, empty destination. Existing data was left unchanged: \(path)"
        }
    }
}

/// Durable history beside the existing editing stores. Immutable content-addressed
/// blobs plus one atomic manifest make retries safe. flock covers separate app/CLI
/// processes; actor isolation alone only covers callers of this particular actor.
public actor DurableLibraryStore {
    public nonisolated let root: URL
    public nonisolated var directory: URL { root.appendingPathComponent("library", isDirectory: true) }
    private let files = FileManager.default
    private struct Device: Codable {
        var id: UUID
        var providerInstallations: [String: UUID]
    }

    /// Identity of the manifest file a decoded copy came from. Writers replace
    /// the file atomically, which changes the inode; an in-place rewrite still
    /// changes the size or change time.
    private struct ManifestStamp: Equatable {
        var device: Int32
        var inode: UInt64
        var size: Int64
        var modified: [Int]
        var changed: [Int]
    }

    /// Decoding the manifest dominated every capture once history grew to tens
    /// of megabytes, and most captures change nothing. Reads reuse the decoded
    /// copy while the file on disk is the one it came from.
    private var cachedManifest: (stamp: ManifestStamp, library: DurableLibrary)?

    public init(root: URL) { self.root = root.standardizedFileURL }

    public func summary() throws -> DurableLibrarySummary {
        try locked {
            guard files.fileExists(atPath: directory.appendingPathComponent("manifest.json").path) else {
                throw DurableLibraryError.invalidData("No library exists yet. Run library migrate first.")
            }
            let library = try readLibrary()
            return try makeSummary(library)
        }
    }

    public func snapshot() throws -> DurableLibrary {
        try locked { try readLibrary() }
    }

    /// Both nil means an explicit complete legacy import. Supplied snapshots avoid
    /// filesystem scans during ordinary state/context updates. Nothing is deleted.
    @discardableResult
    public func reconcile(state: LocalState? = nil, contexts: [TaskContext]? = nil) throws -> DurableLibrarySummary {
        try locked {
            var library = try readLibrary()
            let original = library
            let device = try readDevice()
            if state == nil && contexts == nil {
                library.importWarnings = []
                try importLegacy(into: &library, device: device)
                let stateURL = root.appendingPathComponent("state.json")
                if files.fileExists(atPath: stateURL.path) {
                    do {
                        let saved = try JSONDecoder().decode(LocalState.self, from: safeData(stateURL))
                        try ingest(saved, into: &library, device: device)
                    } catch { library.importWarnings.append("state.json: \(error.localizedDescription)") }
                }
            } else {
                if let state { try ingest(state, into: &library, device: device) }
                for context in contexts ?? [] {
                    try ingest(context, into: &library, device: device)
                }
            }
            try commit(&library, original: original, operation: "reconcile", device: device)
            return try makeSummary(library)
        }
    }

    public func recordSession(_ session: TaskAgentSession) throws {
        try locked {
            var library = try readLibrary(); let original = library; let device = try readDevice()
            try ingest(LocalState(agentSessions: [session]), into: &library, device: device, completeSnapshot: false)
            try commit(&library, original: original, operation: "session-registration", device: device)
        }
    }

    public func captureDashboard(_ dashboard: DashboardDocument) throws {
        try locked {
            var library = try readLibrary(); let original = library; let device = try readDevice()
            try ingestDashboard(dashboard, into: &library, device: device)
            try commit(&library, original: original, operation: "dashboard", device: device)
        }
    }

    public func captureDocument(at url: URL, kind: String, ticketID: String? = nil) throws {
        try Self.requireTicketID(ticketID)
        try locked {
            var library = try readLibrary(); let original = library; let device = try readDevice()
            let taskID = ticketID.map { ensureTask($0, in: &library) }
            try capture(try safeData(url), source: url, kind: kind, taskID: taskID, into: &library, device: device)
            try commit(&library, original: original, operation: "document", device: device)
        }
    }

    /// Merge by message identity before the presentation cache truncates to 500.
    /// Missing messages in a later cache snapshot do not erase retained history.
    public func captureReport(data: Data, runID: String) throws {
        guard !runID.isEmpty else {
            throw DurableLibraryError.invalidData("Invalid report run ID")
        }
        try locked {
            var library = try readLibrary(); let original = library; let device = try readDevice()
            let report = try JSONDecoder().decode(DailyReportDocument.self, from: data)
            guard report.runID == runID else { throw DurableLibraryError.invalidData("Report identity mismatch") }
            try ingestReport(report, into: &library, device: device)
            try commit(&library, original: original, operation: "daily-report", device: device)
        }
    }

    public func captureConversation(data: Data, ticketID: String?) throws {
        try Self.requireTicketID(ticketID)
        try locked {
            var library = try readLibrary(); let original = library; let device = try readDevice()
            let source = ticketID.map { root.appendingPathComponent("tasks/\($0.uppercased())/conversation.json") }
                ?? root.appendingPathComponent("queue-conversation.json")
            let taskID = ticketID.map { ensureTask($0, in: &library) }
            try mergeConversation(data, source: source, taskID: taskID, into: &library, device: device)
            try commit(&library, original: original, operation: "conversation", device: device)
        }
    }

    /// Export a self-contained local library. Execution locators remain historical;
    /// the installation's private device identity and credentials are not exported.
    public func export(to destination: URL) throws {
        try locked {
            let library = try readLibrary()
            try Self.validate(library, at: directory)
            try Self.copyLibrary(from: directory, to: destination)
        }
    }

    /// Restore into a fresh support location. Never overwrites an existing library
    /// or binds old terminal locators to this installation's new device identity.
    public static func restore(from source: URL, to supportRoot: URL) throws {
        let files = FileManager.default
        try ensureSafePath(supportRoot)
        if files.fileExists(atPath: supportRoot.path),
           !(try files.contentsOfDirectory(atPath: supportRoot.path)).isEmpty {
            throw DurableLibraryError.destinationExists(supportRoot.path)
        }
        try ensureSafePath(source)
        let manifest = source.appendingPathComponent("manifest.json")
        try ensureSafePath(manifest)
        let library = try decode(Data(contentsOf: manifest))
        try validate(library, at: source)
        try files.createDirectory(at: supportRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try copyLibrary(from: source, to: supportRoot.appendingPathComponent("library"))
    }

    private func readLibrary() throws -> DurableLibrary {
        let url = directory.appendingPathComponent("manifest.json")
        guard files.fileExists(atPath: url.path) else {
            cachedManifest = nil
            return DurableLibrary(workspaceID: UUID(), name: "Personal workspace")
        }
        // Stat before reading. A replacement in between pairs an older stamp
        // with newer data, which only costs one more decode on the next read.
        let stamp = Self.manifestStamp(url)
        if let stamp, let cachedManifest, cachedManifest.stamp == stamp { return cachedManifest.library }
        let library = try Self.decode(safeData(url))
        cachedManifest = stamp.map { ($0, library) }
        return library
    }

    private static func manifestStamp(_ url: URL) -> ManifestStamp? {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return ManifestStamp(device: info.st_dev, inode: info.st_ino, size: info.st_size,
            modified: [info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec],
            changed: [info.st_ctimespec.tv_sec, info.st_ctimespec.tv_nsec])
    }

    private static func decode(_ data: Data) throws -> DurableLibrary {
        // A single decode. Probing the version first parsed the whole manifest
        // twice; the probe now runs only to explain a failure or another schema.
        let library: DurableLibrary
        do {
            library = try JSONDecoder().decode(DurableLibrary.self, from: data)
        } catch {
            let header = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let version = header?["schemaVersion"] as? Int else {
                throw DurableLibraryError.invalidData("Missing schemaVersion")
            }
            guard version == 1 else { throw DurableLibraryError.unsupportedVersion(version) }
            throw error
        }
        guard library.schemaVersion == 1 else { throw DurableLibraryError.unsupportedVersion(library.schemaVersion) }
        try validateRelationships(library)
        return library
    }

    private func readDevice() throws -> Device {
        let url = root.appendingPathComponent("library-device.json")
        let fileExists = files.fileExists(atPath: url.path)
        var device: Device
        if fileExists {
            device = try JSONDecoder().decode(Device.self, from: safeData(url))
        } else {
            device = Device(id: UUID(), providerInstallations: [:])
        }
        var needsSave = !fileExists
        for provider in AgentProvider.allCases where device.providerInstallations[provider.rawValue] == nil {
            device.providerInstallations[provider.rawValue] = UUID()
            needsSave = true
        }
        if needsSave { try writePrivate(try Self.encode(device), to: url) }
        return device
    }

    private func makeSummary(_ library: DurableLibrary) throws -> DurableLibrarySummary {
        DurableLibrarySummary(schemaVersion: library.schemaVersion, workspaceID: library.workspaceID,
            deviceID: try readDevice().id, storageMode: library.storageMode, revision: library.revision,
            tasks: library.tasks.count, sessions: library.sessions.count, assignments: library.assignments.count,
            documents: library.documents.count, documentRevisions: library.documents.reduce(0) { $0 + $1.revisions.count },
            unknownAccounts: library.sessions.filter { $0.providerAccountRef == nil }.count, warnings: library.importWarnings)
    }

    private func ensureTask(_ ticket: String, in library: inout DurableLibrary) -> UUID {
        let key = ticket.uppercased()
        if let task = library.tasks.first(where: { $0.ticketID == key }) { return task.id }
        let task = LibraryTask(id: UUID(), ticketID: key, title: key, summary: "", successCriteria: "", subtasks: [])
        library.tasks.append(task)
        return task.id
    }

    private func ensureSession(provider: String, nativeID: String, in library: inout DurableLibrary, device: Device) throws -> UUID {
        guard let installation = device.providerInstallations[provider] else {
            throw DurableLibraryError.invalidData("Missing \(provider) provider installation identity")
        }
        // These legacy adapters define UUID identities as case-insensitive. Future
        // adapters must retain opaque native IDs and define their own comparison.
        if let session = library.sessions.first(where: {
            $0.provider == provider && $0.providerInstallationID == installation
                && $0.nativeSessionID.caseInsensitiveCompare(nativeID) == .orderedSame
        }) { return session.id }
        let session = LibrarySession(id: UUID(), provider: provider, nativeSessionID: nativeID,
            providerInstallationID: installation, firstRecordedAt: Date())
        library.sessions.append(session)
        return session.id
    }

    private func assign(taskID: UUID, sessionID: UUID, subtaskID: UUID?, source: String, into library: inout DurableLibrary) {
        if library.assignments.contains(where: { $0.taskID == taskID && $0.sessionID == sessionID && $0.subtaskID == subtaskID && $0.source == source && $0.endedAt == nil }) { return }
        library.assignments.append(LibraryAssignment(id: UUID(), taskID: taskID, sessionID: sessionID,
            subtaskID: subtaskID, source: source, recordedAt: Date()))
    }

    private func ingest(_ state: LocalState, into library: inout DurableLibrary, device: Device, completeSnapshot: Bool = true) throws {
        var active = Set<UUID>()
        for saved in state.agentSessions {
            try Self.requireTicketID(saved.ticketID)
            let taskID = ensureTask(saved.ticketID, in: &library)
            let sessionID = try ensureSession(provider: saved.provider.rawValue, nativeID: saved.sessionID, in: &library, device: device)
            let subtaskID = library.tasks.first(where: { $0.id == taskID })?.subtasks.first(where: { $0.legacyID == saved.subtaskID })?.id
            assign(taskID: taskID, sessionID: sessionID, subtaskID: subtaskID, source: "registration", into: &library)
            for assignment in library.assignments where assignment.taskID == taskID && assignment.sessionID == sessionID && assignment.subtaskID == subtaskID && assignment.source == "registration" && assignment.endedAt == nil { active.insert(assignment.id) }
            updateLocator(sessionID: sessionID, directory: saved.workingDirectory.isEmpty ? nil : saved.workingDirectory,
                source: "saved-session", window: saved.windowID, tab: saved.tabID, pane: saved.paneID, into: &library, device: device)
        }
        // Only end registrations on this installation, never another device's.
        let localSessions = Set(library.sessions.filter { entry in
            device.providerInstallations.values.contains(entry.providerInstallationID)
                && (completeSnapshot || state.agentSessions.contains { saved in saved.provider.rawValue == entry.provider && saved.sessionID.caseInsensitiveCompare(entry.nativeSessionID) == .orderedSame })
        }.map(\.id))
        for i in library.assignments.indices where library.assignments[i].source == "registration"
            && library.assignments[i].endedAt == nil && localSessions.contains(library.assignments[i].sessionID)
            && !active.contains(library.assignments[i].id) { library.assignments[i].endedAt = Date() }
    }

    private func ingest(_ context: TaskContext, into library: inout DurableLibrary, device: Device) throws {
        try Self.requireTicketID(context.ticketID)
        let taskID = ensureTask(context.ticketID, in: &library)
        let index = library.tasks.firstIndex { $0.id == taskID }!
        var task = library.tasks[index]
        task.title = context.title; task.summary = context.summary; task.successCriteria = context.successCriteria
        task.sourceUpdatedAt = context.updatedAt
        for i in task.subtasks.indices { task.subtasks[i].isCurrent = false }
        var currentAssignments = Set<UUID>()
        for subtask in context.subtasks {
            let prior = task.subtasks.firstIndex { $0.legacyID == subtask.id }
            let entry = LibrarySubtask(id: prior.map { task.subtasks[$0].id } ?? UUID(), legacyID: subtask.id,
                title: subtask.title, status: subtask.status.rawValue, progressSummary: subtask.progressSummary,
                lastHeartbeatAt: subtask.lastHeartbeatAt,
                lastOutputAt: subtask.lastOutputAt,
                isCurrent: subtask.parentSubtaskID == nil && subtask.mergedIntoSubtaskID == nil,
                parentSubtaskID: subtask.parentSubtaskID, mergedIntoSubtaskID: subtask.mergedIntoSubtaskID)
            if let prior { task.subtasks[prior] = entry } else { task.subtasks.append(entry) }
        }
        let links = SubtaskLinks(context.subtasks)
        for subtask in context.subtasks {
            if let nativeID = subtask.sessionID, !nativeID.isEmpty {
                let sessionID = try ensureSession(provider: subtask.provider.rawValue, nativeID: nativeID, in: &library, device: device)
                let assignmentIDs = links.assignmentIDs(for: subtask)
                let linked = Set(task.subtasks.filter { assignmentIDs.contains($0.legacyID) }.map(\.id))
                if subtask.isAgentVisible {
                    for id in linked { assign(taskID: taskID, sessionID: sessionID, subtaskID: id, source: "task-context", into: &library) }
                }
                for assignment in library.assignments where subtask.isAgentVisible && assignment.taskID == taskID && assignment.sessionID == sessionID
                    && assignment.subtaskID.map(linked.contains) == true && assignment.source == "task-context" && assignment.endedAt == nil {
                    currentAssignments.insert(assignment.id)
                }
                if !library.executionLocators.contains(where: { $0.sessionID == sessionID && $0.deviceID == device.id && $0.pathSource == "saved-session" }) {
                    updateLocator(sessionID: sessionID, directory: subtask.workspace?.path ?? context.worktreePath ?? context.repositoryPath,
                        source: "task-context-fallback", window: nil, tab: nil, pane: nil, into: &library, device: device)
                }
            }
        }
        library.tasks[index] = task
        let localSessions = Set(library.sessions.filter { device.providerInstallations.values.contains($0.providerInstallationID) }.map(\.id))
        for i in library.assignments.indices where library.assignments[i].source == "task-context"
            && library.assignments[i].taskID == taskID && localSessions.contains(library.assignments[i].sessionID)
            && library.assignments[i].endedAt == nil && !currentAssignments.contains(library.assignments[i].id) {
            library.assignments[i].endedAt = Date()
        }
        let repository = LibraryRepository(id: library.repositories.first(where: { $0.taskID == taskID && $0.deviceID == device.id })?.id ?? UUID(),
            taskID: taskID, deviceID: device.id, repositoryPath: context.repositoryPath, worktreePath: context.worktreePath,
            branch: context.branch, baseBranch: context.baseBranch, managedWorktree: context.managedWorktree)
        if let i = library.repositories.firstIndex(where: { $0.id == repository.id }) { library.repositories[i] = repository }
        else { library.repositories.append(repository) }
        let source = root.appendingPathComponent("tasks/\(context.ticketID.uppercased())/context.json")
        try capture(Self.encode(context), source: source, kind: "task-context", taskID: taskID, into: &library, device: device)
        let plan = URL(fileURLWithPath: context.planPath)
        let expectedPlan = root.appendingPathComponent("tasks/\(context.ticketID.uppercased())/plan.md")
        guard plan.standardizedFileURL.path == expectedPlan.standardizedFileURL.path else {
            appendWarning("\(context.ticketID): noncanonical plan path was preserved but skipped during automatic import", to: &library)
            return
        }
        if files.fileExists(atPath: plan.path) {
            do { try capture(safeData(plan), source: plan, kind: "central-plan", taskID: taskID, into: &library, device: device) }
            catch { appendWarning("\(context.ticketID) plan: \(error.localizedDescription)", to: &library) }
        } else { appendWarning("\(context.ticketID): central plan is missing at \(context.planPath)", to: &library) }
    }

    private func ingestHistorical(_ context: TaskContext, into library: inout DurableLibrary, device: Device) throws {
        let taskID = ensureTask(context.ticketID, in: &library)
        let index = library.tasks.firstIndex { $0.id == taskID }!
        for subtask in context.subtasks {
            var entry = library.tasks[index].subtasks.first { $0.legacyID == subtask.id }
            if entry == nil {
                entry = LibrarySubtask(id: UUID(), legacyID: subtask.id, title: subtask.title,
                    status: subtask.status.rawValue, progressSummary: subtask.progressSummary,
                    lastHeartbeatAt: subtask.lastHeartbeatAt, lastOutputAt: subtask.lastOutputAt,
                    isCurrent: false)
                library.tasks[index].subtasks.append(entry!)
            }
            if let nativeID = subtask.sessionID, !nativeID.isEmpty {
                let sessionID = try ensureSession(provider: subtask.provider.rawValue, nativeID: nativeID, in: &library, device: device)
                assign(taskID: taskID, sessionID: sessionID, subtaskID: entry?.id, source: "historical-context", into: &library)
                if !library.executionLocators.contains(where: { $0.sessionID == sessionID && $0.deviceID == device.id }) {
                    updateLocator(sessionID: sessionID, directory: subtask.workspace?.path ?? context.worktreePath ?? context.repositoryPath,
                        source: "historical-context-fallback", window: nil, tab: nil, pane: nil, into: &library, device: device)
                }
            }
        }
    }

    private func updateLocator(sessionID: UUID, directory: String?, source: String, window: Int?, tab: Int?, pane: Int?, into library: inout DurableLibrary, device: Device) {
        let prior = library.executionLocators.firstIndex { $0.sessionID == sessionID && $0.deviceID == device.id }
        var locator = LibraryExecutionLocator(id: prior.map { library.executionLocators[$0].id } ?? UUID(),
            sessionID: sessionID, deviceID: device.id, workingDirectory: directory, pathSource: source,
            windowID: window, tabID: tab, paneID: pane, recordedAt: prior.map { library.executionLocators[$0].recordedAt } ?? Date())
        if let prior {
            if library.executionLocators[prior] != locator { locator.recordedAt = Date(); library.executionLocators[prior] = locator }
        } else { library.executionLocators.append(locator) }
    }

    private func ingestDashboard(_ dashboard: DashboardDocument, into library: inout DurableLibrary, device: Device) throws {
        for ticket in dashboard.tickets {
            try Self.requireTicketID(ticket.id)
            let id = ensureTask(ticket.id, in: &library)
            let i = library.tasks.firstIndex { $0.id == id }!
            library.tasks[i].title = ticket.title
            library.tasks[i].summary = ticket.summary
            library.tasks[i].status = ticket.status
            library.tasks[i].priority = ticket.priority
            if let criteria = ticket.doneWhen { library.tasks[i].successCriteria = criteria }
            try capture(Self.encode(ticket), source: root.appendingPathComponent("task-catalog/\(ticket.id).json"),
                kind: "task-definition", taskID: id, into: &library, device: device)
        }
    }

    private func ingestReport(_ report: DailyReportDocument, into library: inout DurableLibrary, device: Device) throws {
        let key = Self.digest(Data(report.runID.utf8))
        let source = root.appendingPathComponent("ingestion/retained-runs/\(key).json")
        try capture(Self.encode(report), source: source, kind: "daily-report", taskID: nil, into: &library, device: device)
        let docID = library.documents.first { $0.sourcePath == source.standardizedFileURL.path && $0.sourceDeviceID == device.id && $0.kind == "daily-report" }!.id
        if let i = library.reportRuns.firstIndex(where: { $0.nativeRunID == report.runID }) {
            library.reportRuns[i].status = report.status.rawValue
            library.reportRuns[i].documentID = docID
        } else {
            library.reportRuns.append(LibraryReportRun(id: UUID(), nativeRunID: report.runID,
                reportDate: report.reportDate, status: report.status.rawValue, documentID: docID))
        }
    }

    private func importLegacy(into library: inout DurableLibrary, device: Device) throws {
        let configURL = root.appendingPathComponent("config.json")
        if files.fileExists(atPath: configURL.path) {
            do {
                let config = try JSONDecoder().decode(AppConfiguration.self, from: safeData(configURL))
                let dashboard = try JSONDecoder().decode(DashboardDocument.self, from: safeData(URL(fileURLWithPath: config.dashboardPath)))
                try ingestDashboard(dashboard, into: &library, device: device)
            } catch { appendWarning("Dashboard: \(error.localizedDescription)", to: &library) }
        }
        let tasks = root.appendingPathComponent("tasks")
        for folder in try children(tasks) {
            let source = folder.appendingPathComponent("context.json")
            guard files.fileExists(atPath: source.path) else { continue }
            do {
                let context = try JSONDecoder().decode(TaskContext.self, from: safeData(source))
                guard context.ticketID.caseInsensitiveCompare(folder.lastPathComponent) == .orderedSame else {
                    throw DurableLibraryError.invalidData("Context ticket does not match its folder")
                }
                try ingest(context, into: &library, device: device)
                let taskID = ensureTask(context.ticketID, in: &library)
                for url in try descendants(folder) where ["md", "json"].contains(url.pathExtension.lowercased()) {
                    guard url.path != source.path && url.path != context.planPath else { continue }
                    do {
                        if url.lastPathComponent == "conversation.json" {
                            try mergeConversation(safeData(url), source: url, taskID: taskID, into: &library, device: device)
                        } else {
                            let data = try safeData(url)
                            if url.lastPathComponent == "context.json", url.path.contains("/archive/") {
                                let historical = try JSONDecoder().decode(TaskContext.self, from: data)
                                guard historical.ticketID.caseInsensitiveCompare(context.ticketID) == .orderedSame else {
                                    throw DurableLibraryError.invalidData("Archive ticket does not match its task")
                                }
                                try ingestHistorical(historical, into: &library, device: device)
                            }
                            try capture(data, source: url, kind: url.path.contains("/archive/") ? "task-snapshot" : (url.path.contains("/architecture/") ? "architecture" : "task-document"), taskID: taskID, into: &library, device: device)
                        }
                    } catch { appendWarning("\(url.lastPathComponent): \(error.localizedDescription)", to: &library) }
                }
            } catch { appendWarning("\(folder.lastPathComponent) context: \(error.localizedDescription)", to: &library) }
        }
        let queue = root.appendingPathComponent("queue-conversation.json")
        if files.fileExists(atPath: queue.path) {
            do { try mergeConversation(safeData(queue), source: queue, taskID: nil, into: &library, device: device) }
            catch { appendWarning("Queue conversation: \(error.localizedDescription)", to: &library) }
        }
        // Known report stores only. Never recursively import config, credentials,
        // provider home directories, arbitrary worktrees, or tool outputs.
        let runtime = root.appendingPathComponent("ingestion")
        var reports = try descendants(runtime.appendingPathComponent("reports"))
        reports += [runtime.appendingPathComponent("latest-report.json"), runtime.appendingPathComponent("report-presentation.json")]
        for url in reports where files.fileExists(atPath: url.path) && ["json", "md"].contains(url.pathExtension) {
            do {
                let data = try safeData(url)
                if url.lastPathComponent == "report-presentation.json" {
                    try capture(data, source: url, kind: "report-presentation", taskID: nil, into: &library, device: device)
                } else {
                    let report = try JSONDecoder().decode(DailyReportDocument.self, from: data)
                    try ingestReport(report, into: &library, device: device)
                }
            }
            catch { appendWarning("Report \(url.lastPathComponent): \(error.localizedDescription)", to: &library) }
        }
    }

    private func mergeConversation(_ data: Data, source: URL, taskID: UUID?, into library: inout DurableLibrary, device: Device) throws {
        guard let incoming = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw DurableLibraryError.invalidData("Conversation must be an array of messages")
        }
        var messages: [[String: Any]] = []
        let sourcePath = source.standardizedFileURL.path
        if let existing = library.documents.first(where: { $0.sourcePath == sourcePath && $0.sourceDeviceID == device.id && $0.kind == "conversation" }), let latest = existing.revisions.last {
            let saved = try safeData(directory.appendingPathComponent(latest.blobPath))
            guard let decoded = try JSONSerialization.jsonObject(with: saved) as? [[String: Any]] else {
                throw DurableLibraryError.invalidData("Retained conversation is unreadable")
            }
            messages = decoded
        }
        for message in incoming {
            guard let id = message["id"] as? String, !id.isEmpty else { throw DurableLibraryError.invalidData("Conversation message has no identity") }
            if let i = messages.firstIndex(where: { ($0["id"] as? String) == id }) { messages[i] = message }
            else { messages.append(message) }
        }
        try capture(JSONSerialization.data(withJSONObject: messages, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]),
            source: source, kind: "conversation", taskID: taskID, into: &library, device: device)
    }

    private func capture(_ data: Data, source: URL, kind: String, taskID: UUID?, into library: inout DurableLibrary, device: Device) throws {
        guard data.count <= 64 * 1024 * 1024 else {
            throw DurableLibraryError.invalidData("Document exceeds the current 64 MiB retention limit; original source remains available")
        }
        let digest = Self.digest(data)
        // Standardize once. Doing it inside the scan made a full import quadratic in URL work.
        let sourcePath = source.standardizedFileURL.path
        let prior = library.documents.firstIndex { $0.sourcePath == sourcePath && $0.sourceDeviceID == device.id && $0.kind == kind }
        if let prior, library.documents[prior].revisions.last?.sha256 == digest { return }
        let ext = source.pathExtension.lowercased() == "md" ? "md" : "json"
        let path = "blobs/\(digest).\(ext)"
        let blob = directory.appendingPathComponent(path)
        if files.fileExists(atPath: blob.path) {
            guard try Self.digest(safeData(blob)) == digest else { throw DurableLibraryError.invalidData("Existing blob checksum mismatch") }
        } else { try writePrivate(data, to: blob) }
        let revision = LibraryDocumentRevision(id: UUID(), sha256: digest, blobPath: path, byteCount: data.count, recordedAt: Date())
        if let prior { library.documents[prior].revisions.append(revision) }
        else {
            library.documents.append(LibraryDocument(id: UUID(), taskID: taskID, kind: kind,
                title: source.lastPathComponent, sourcePath: source.standardizedFileURL.path, sourceDeviceID: device.id, revisions: [revision]))
        }
    }

    private func commit(_ library: inout DurableLibrary, original: DurableLibrary, operation: String, device: Device) throws {
        let manifest = directory.appendingPathComponent("manifest.json")
        guard library != original || !files.fileExists(atPath: manifest.path) else { return }
        library.revision += 1
        library.changes.append(LibraryChange(id: UUID(), revision: library.revision, deviceID: device.id, recordedAt: Date(), operation: operation))
        cachedManifest = nil
        try writePrivate(Self.encode(library), to: manifest)
        // Cache only what a fresh read would accept, so an invalid write still
        // fails the next read exactly as before.
        if (try? Self.validateRelationships(library)) != nil, let stamp = Self.manifestStamp(manifest) {
            cachedManifest = (stamp, library)
        }
    }

    private func appendWarning(_ warning: String, to library: inout DurableLibrary) {
        if !library.importWarnings.contains(warning) { library.importWarnings.append(warning) }
    }

    private func safeData(_ url: URL) throws -> Data {
        try Self.ensureSafePath(url)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) <= 64 * 1024 * 1024 else {
            throw DurableLibraryError.invalidData("Expected regular file no larger than 64 MiB: \(url.path)")
        }
        return try Data(contentsOf: url)
    }

    private func children(_ url: URL) throws -> [URL] {
        guard files.fileExists(atPath: url.path) else { return [] }
        try Self.ensureSafePath(url)
        return try files.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]).filter {
            (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false
        }.sorted { $0.path < $1.path }
    }

    private func descendants(_ url: URL) throws -> [URL] {
        guard files.fileExists(atPath: url.path) else { return [] }
        try Self.ensureSafePath(url)
        guard let enumerator = files.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return [] }
        var result: [URL] = []
        for case let entry as URL in enumerator {
            let values = try entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if values.isRegularFile == true { result.append(entry) }
        }
        return result.sorted { $0.path < $1.path }
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        try Self.ensureSafePath(directory)
        try files.createDirectory(at: directory.appendingPathComponent("blobs"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = directory.appendingPathComponent(".lock")
        let descriptor = Darwin.open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw DurableLibraryError.unsafePath(lock.path) }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        try Self.ensureSafePath(url)
        try data.write(to: url, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func requireTicketID(_ value: String?) throws {
        if let value, value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) == nil {
            throw DurableLibraryError.invalidData("Invalid task alias")
        }
    }

    private static func ensureSafePath(_ url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.pathComponents.contains("..") else { throw DurableLibraryError.unsafePath(url.path) }
        var part = url
        while part.path != "/" {
            var metadata = stat()
            if lstat(part.path, &metadata) == 0 && (metadata.st_mode & S_IFMT) == S_IFLNK {
                // macOS exposes its standard temporary roots through these links.
                let target = try? FileManager.default.destinationOfSymbolicLink(atPath: part.path)
                let systemAlias = (part.path == "/var" && ["private/var", "/private/var"].contains(target ?? ""))
                    || (part.path == "/tmp" && ["private/tmp", "/private/tmp"].contains(target ?? ""))
                if !systemAlias { throw DurableLibraryError.unsafePath(part.path) }
            }
            part.deleteLastPathComponent()
        }
    }

    private static func validateRelationships(_ library: DurableLibrary) throws {
        func unique<T: Hashable>(_ values: [T]) -> Bool { Set(values).count == values.count }
        let tasks = Set(library.tasks.map(\.id)), sessions = Set(library.sessions.map(\.id))
        let documents = Set(library.documents.map(\.id))
        let subtasks = library.tasks.flatMap(\.subtasks)
        let revisions = library.documents.flatMap(\.revisions)
        guard unique(library.tasks.map(\.id)), unique(library.tasks.map(\.ticketID)),
              unique(library.sessions.map(\.id)), unique(library.assignments.map(\.id)),
              unique(library.executionLocators.map(\.id)), unique(library.repositories.map(\.id)),
              unique(library.documents.map(\.id)), unique(revisions.map(\.id)), unique(subtasks.map(\.id)),
              unique(library.reportRuns.map(\.id)), unique(library.reportRuns.map(\.nativeRunID)),
              unique(library.changes.map(\.id)), unique(library.changes.map(\.revision)),
              library.assignments.allSatisfy({ assignment in
                  tasks.contains(assignment.taskID) && sessions.contains(assignment.sessionID)
                      && (assignment.subtaskID == nil || library.tasks.first { $0.id == assignment.taskID }?.subtasks.contains { $0.id == assignment.subtaskID } == true)
              }),
              library.executionLocators.allSatisfy({ sessions.contains($0.sessionID) }),
              library.repositories.allSatisfy({ tasks.contains($0.taskID) }),
              library.documents.allSatisfy({ !$0.revisions.isEmpty && ($0.taskID == nil || tasks.contains($0.taskID!)) }),
              library.reportRuns.allSatisfy({ documents.contains($0.documentID) }),
              library.storageMode == "local", library.revision >= 0 else {
            throw DurableLibraryError.invalidData("Duplicate identity or broken library relationship")
        }
    }

    private static func validate(_ library: DurableLibrary, at root: URL) throws {
        try ensureSafePath(root)
        guard library.schemaVersion == 1 else { throw DurableLibraryError.unsupportedVersion(library.schemaVersion) }
        try validateRelationships(library)
        let tasks = Set(library.tasks.map(\.id))
        for doc in library.documents {
            if let task = doc.taskID, !tasks.contains(task) { throw DurableLibraryError.invalidData("Unknown document task") }
            for rev in doc.revisions {
                guard rev.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                      ["blobs/\(rev.sha256).md", "blobs/\(rev.sha256).json"].contains(rev.blobPath) else {
                    throw DurableLibraryError.invalidData("Invalid blob reference")
                }
                let url = root.appendingPathComponent(rev.blobPath)
                try ensureSafePath(url)
                let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard attributes.isRegularFile == true, (attributes.fileSize ?? 0) <= 64 * 1024 * 1024 else {
                    throw DurableLibraryError.invalidData("Oversized or nonregular blob")
                }
                let data = try Data(contentsOf: url)
                guard data.count == rev.byteCount && digest(data) == rev.sha256 else { throw DurableLibraryError.invalidData("Blob checksum mismatch") }
            }
        }
    }

    private static func copyLibrary(from source: URL, to destination: URL) throws {
        let files = FileManager.default
        try ensureSafePath(destination)
        guard !files.fileExists(atPath: destination.path) else { throw DurableLibraryError.destinationExists(destination.path) }
        try ensureSafePath(source.appendingPathComponent("manifest.json"))
        let manifestData = try Data(contentsOf: source.appendingPathComponent("manifest.json"))
        let library = try decode(manifestData)
        try validate(library, at: source)
        let parent = destination.deletingLastPathComponent()
        try files.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = parent.appendingPathComponent(".library-export-\(UUID().uuidString)")
        try files.createDirectory(at: staging.appendingPathComponent("blobs"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: staging) }
        var copied = Set<String>()
        for doc in library.documents {
            for rev in doc.revisions where copied.insert(rev.blobPath).inserted {
                try files.copyItem(at: source.appendingPathComponent(rev.blobPath), to: staging.appendingPathComponent(rev.blobPath))
            }
        }
        let stagedManifest = staging.appendingPathComponent("manifest.json")
        try manifestData.write(to: stagedManifest, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stagedManifest.path)
        try validate(library, at: staging)
        try files.moveItem(at: staging, to: destination)
    }

    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}
