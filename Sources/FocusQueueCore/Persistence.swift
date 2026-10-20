import Darwin
import Foundation

public protocol FileAccessing: Sendable {
    func read(from url: URL) throws -> Data
    func write(_ data: Data, to url: URL) throws
    func createDirectory(at url: URL) throws
    func fileExists(at url: URL) -> Bool
    func modificationDate(at url: URL) throws -> Date?
    func removeItem(at url: URL) throws
}

public struct SystemFileAccessor: FileAccessing {
    public init() {}

    public func read(from url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    public func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let directoryAlreadyExisted = FileManager.default.fileExists(atPath: directory.path)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        if !directoryAlreadyExisted {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    public func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
    }

    public func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func modificationDate(at url: URL) throws -> Date? {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return attributes[.modificationDate] as? Date
    }

    public func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

/// Cross-process advisory locks shared by the app and command-line helpers.
/// Every writer locks the canonical target paths in the same sorted order.
public enum FocusQueueFileLock {
    public static func url(for targetURL: URL) -> URL {
        let target = targetURL.standardizedFileURL
        return target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).focus-queue.lock")
    }

    public static func withLocks<T>(for targetURLs: [URL], _ operation: () throws -> T) throws -> T {
        let targets = Dictionary(
            targetURLs.map { ($0.standardizedFileURL.path, $0.standardizedFileURL) },
            uniquingKeysWith: { first, _ in first }
        ).values.sorted { $0.path < $1.path }
        var descriptors: [Int32] = []
        do {
            for target in targets {
                let lockURL = url(for: target)
                let lockDirectory = lockURL.deletingLastPathComponent()
                let directoryAlreadyExisted = FileManager.default.fileExists(
                    atPath: lockDirectory.path)
                try FileManager.default.createDirectory(
                    at: lockDirectory,
                    withIntermediateDirectories: true
                )
                if !directoryAlreadyExisted {
                    try FileManager.default.setAttributes(
                        [.posixPermissions: 0o700],
                        ofItemAtPath: lockDirectory.path
                    )
                }
                let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, 0o600)
                guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
                guard flock(descriptor, LOCK_EX) == 0 else {
                    Darwin.close(descriptor)
                    throw CocoaError(.fileWriteUnknown)
                }
                descriptors.append(descriptor)
            }
        } catch {
            for descriptor in descriptors.reversed() {
                flock(descriptor, LOCK_UN)
                Darwin.close(descriptor)
            }
            throw error
        }
        defer {
            for descriptor in descriptors.reversed() {
                flock(descriptor, LOCK_UN)
                Darwin.close(descriptor)
            }
        }
        return try operation()
    }
}

public protocol ConfigurationLoading: Sendable {
    func loadOrCreate(default defaultConfiguration: AppConfiguration) async throws -> AppConfiguration
    func save(_ configuration: AppConfiguration) async throws
}

public actor JSONConfigurationRepository: ConfigurationLoading {
    private let url: URL
    private let files: any FileAccessing

    public init(url: URL, files: any FileAccessing = SystemFileAccessor()) {
        self.url = url
        self.files = files
    }

    public func loadOrCreate(default defaultConfiguration: AppConfiguration) throws -> AppConfiguration {
        try FocusQueueFileLock.withLocks(for: [url]) {
            if !files.fileExists(at: url) {
                let data = try Self.encoder.encode(defaultConfiguration)
                try files.write(data, to: url)
                return try defaultConfiguration.validated()
            }

            let data = try files.read(from: url)
            return try JSONDecoder().decode(AppConfiguration.self, from: data).validated()
        }
    }

    public func save(_ configuration: AppConfiguration) throws {
        let validated = try configuration.validated()
        let encoded = try Self.encoder.encode(validated)
        let writePreservingCompatibility = {
            guard self.files.fileExists(at: self.url) else {
                try self.files.write(encoded, to: self.url)
                return
            }
            let existingValue = try JSONSerialization.jsonObject(with: self.files.read(from: self.url))
            guard let existing = existingValue as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let legacyProjects = Self.classifyLegacyProjects(in: existing)
            guard legacyProjects != .ambiguous else { throw CocoaError(.fileReadCorruptFile) }
            guard var updated = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
            else { throw CocoaError(.fileWriteUnknown) }
            for (key, value) in existing
            where updated[key] == nil
                && Self.shouldPreserveConfigurationValue(
                    value, forKey: key, legacyProjects: legacyProjects)
            {
                updated[key] = value
            }
            let merged = try JSONSerialization.data(
                withJSONObject: updated,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try self.files.write(merged, to: self.url)
        }
        if files is SystemFileAccessor {
            try files.createDirectory(at: url.deletingLastPathComponent())
            try FocusQueueFileLock.withLocks(for: [url], writePreservingCompatibility)
        } else {
            try writePreservingCompatibility()
        }
    }

    private static let knownConfigurationKeys: Set<String> = [
        "appName", "dashboardPath", "workspacePath", "defaultPlacement",
        "refreshIntervalSeconds", "dailyRoutines", "wezTerm", "verifier", "dailyReport",
        "persistentTerminals", "tmuxExecutable", "setupCompleted", "focusQueueProjects",
        "focusQueueSelectedProjectID", "projects", "selectedProjectID", "completionReviewEnabled",
    ]

    private enum LegacyProjectMetadata: Equatable {
        case absent, empty, repository, queue, ambiguous
    }

    private static func classifyLegacyProjects(in configuration: [String: Any])
        -> LegacyProjectMetadata
    {
        guard let value = configuration["projects"] else { return .absent }
        guard let projects = value as? [[String: Any]] else { return .ambiguous }
        guard !projects.isEmpty else { return .empty }
        let isRepositoryCatalog = projects.allSatisfy {
            $0["id"] is String
                && $0["name"] is String
                && $0["repositoryPath"] is String
                && $0["dashboardPath"] == nil
                && $0["workspacePath"] == nil
        }
        if isRepositoryCatalog { return .repository }
        let isQueueCatalog = projects.allSatisfy {
            $0["id"] is String
                && $0["name"] is String
                && $0["dashboardPath"] is String
                && $0["workspacePath"] is String
                && $0["repositoryPath"] == nil
        }
        return isQueueCatalog ? .queue : .ambiguous
    }

    private static func shouldPreserveConfigurationValue(
        _ value: Any,
        forKey key: String,
        legacyProjects: LegacyProjectMetadata
    ) -> Bool {
        if key == "projects" || key == "selectedProjectID" {
            return legacyProjects == .repository
        }
        return !knownConfigurationKeys.contains(key)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

public protocol DailyReportStoring: Sendable {
    func load() async throws -> DailyReportDocument?
    func save(_ report: DailyReportDocument) async throws
}

public actor JSONDailyReportRepository: DailyReportStoring {
    private let url: URL
    private let files: any FileAccessing

    public init(url: URL, files: any FileAccessing = SystemFileAccessor()) {
        self.url = url
        self.files = files
    }

    public func load() throws -> DailyReportDocument? {
        guard files.fileExists(at: url) else { return nil }
        return try JSONDecoder().decode(DailyReportDocument.self, from: files.read(from: url))
    }

    public func save(_ report: DailyReportDocument) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try files.write(try encoder.encode(report), to: url)
    }
}

public protocol DailyReportApprovalStoring: Sendable {
    func load() async throws -> DailyReportApprovalRequest?
    func save(_ request: DailyReportApprovalRequest) async throws
}

public actor JSONDailyReportApprovalRepository: DailyReportApprovalStoring {
    private let url: URL
    private let files: any FileAccessing

    public init(url: URL, files: any FileAccessing = SystemFileAccessor()) {
        self.url = url
        self.files = files
    }

    public func load() throws -> DailyReportApprovalRequest? {
        guard files.fileExists(at: url) else { return nil }
        return try JSONDecoder().decode(
            DailyReportApprovalRequest.self,
            from: files.read(from: url)
        )
    }

    public func save(_ request: DailyReportApprovalRequest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try files.write(try encoder.encode(request), to: url)
    }
}

public protocol DashboardLoading: Sendable {
    func load(from url: URL) async throws -> DashboardDocument
    func modificationDate(at url: URL) async throws -> Date?
}

public struct DashboardRevision: Equatable, Sendable {
    fileprivate let contents: Data

    fileprivate init(contents: Data) {
        self.contents = contents
    }
}

public struct DashboardSnapshot: Equatable, Sendable {
    public let document: DashboardDocument
    public let revision: DashboardRevision

    public init(document: DashboardDocument, revision: DashboardRevision) {
        self.document = document
        self.revision = revision
    }
}

public enum DashboardMutationError: Error, LocalizedError, Equatable {
    case concurrentModification
    case duplicateTicketID(String)
    case ticketNotFound(String)
    case invalidTicketID
    case invalidTitle
    case invalidFieldValue(String)
    case invalidDocument

    public var errorDescription: String? {
        switch self {
        case .concurrentModification:
            "The dashboard changed before this edit could be saved. Refresh and try again."
        case .duplicateTicketID(let id):
            "A task with the identifier \(id) already exists."
        case .ticketNotFound(let id):
            "Task \(id) no longer exists in this project."
        case .invalidTicketID:
            "A task identifier cannot be empty or contain surrounding whitespace."
        case .invalidTitle:
            "A task title cannot be empty."
        case .invalidFieldValue(let field):
            "The \(field) value cannot be empty."
        case .invalidDocument:
            "The dashboard must be a JSON object containing a tickets array."
        }
    }
}

public protocol DashboardManaging: DashboardLoading {
    func loadSnapshot(from url: URL) async throws -> DashboardSnapshot
    func createTicket(
        _ ticket: DashboardTicket,
        in url: URL,
        expectedRevision: DashboardRevision,
        checking otherDashboardURLs: [URL]
    ) async throws -> DashboardSnapshot
    func renameTicket(
        id: String,
        to title: String,
        in url: URL,
        expectedRevision: DashboardRevision
    ) async throws -> DashboardSnapshot
    func resolveTicket(
        id: String,
        reason: String,
        evidence: [String],
        completedBy: String,
        in url: URL,
        expectedRevision: DashboardRevision
    ) async throws -> DashboardSnapshot
    func reopenTicket(
        id: String,
        in url: URL,
        expectedRevision: DashboardRevision
    ) async throws -> DashboardSnapshot
    func setTicketPriority(
        id: String,
        to priority: String,
        in url: URL,
        expectedRevision: DashboardRevision
    ) async throws -> DashboardSnapshot
    func setTicketStatus(
        id: String,
        to status: String,
        in url: URL,
        expectedRevision: DashboardRevision
    ) async throws -> DashboardSnapshot
    func setTicketDueDate(
        id: String,
        to dueDate: String?,
        source: String?,
        in url: URL,
        expectedRevision: DashboardRevision
    ) async throws -> DashboardSnapshot
}

public extension DashboardManaging {
    func createTicket(
        _ ticket: DashboardTicket,
        in url: URL,
        expectedRevision: DashboardRevision
    ) async throws -> DashboardSnapshot {
        try await createTicket(
            ticket,
            in: url,
            expectedRevision: expectedRevision,
            checking: []
        )
    }

}

enum DashboardFileLock {
    static func url(for dashboardURL: URL) -> URL {
        FocusQueueFileLock.url(for: dashboardURL)
    }
}

public actor JSONDashboardRepository: DashboardManaging {
    private let files: any FileAccessing

    public init(files: any FileAccessing = SystemFileAccessor()) {
        self.files = files
    }

    public func load(from url: URL) throws -> DashboardDocument {
        let data = try files.read(from: url)
        let document = try JSONDecoder().decode(DashboardDocument.self, from: data)
        guard Set(document.tickets.map(\.id)).count == document.tickets.count else {
            throw TaskContextError.commandFailed("The dashboard contains duplicate task IDs. Resolve them before updating the queue.")
        }
        return document
    }

    public func loadSnapshot(from url: URL) throws -> DashboardSnapshot {
        let data = try files.read(from: url)
        return DashboardSnapshot(
            document: try JSONDecoder().decode(DashboardDocument.self, from: data),
            revision: DashboardRevision(contents: data)
        )
    }

    public func createTicket(
        _ ticket: DashboardTicket,
        in url: URL,
        expectedRevision: DashboardRevision,
        checking otherDashboardURLs: [URL] = []
    ) throws -> DashboardSnapshot {
        try locked(url: url) {
            try createTicketLocked(
                ticket,
                in: url,
                expectedRevision: expectedRevision,
                checking: otherDashboardURLs
            )
        }
    }

    private func createTicketLocked(
        _ ticket: DashboardTicket,
        in url: URL,
        expectedRevision: DashboardRevision,
        checking otherDashboardURLs: [URL]
    ) throws -> DashboardSnapshot {
        let normalizedID = ticket.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty, normalizedID == ticket.id else {
            throw DashboardMutationError.invalidTicketID
        }
        guard !ticket.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DashboardMutationError.invalidTitle
        }

        let currentData = try currentData(at: url, expectedRevision: expectedRevision)
        var object = try dashboardObject(from: currentData)
        var tickets = try ticketObjects(in: object)
        guard !tickets.contains(where: { ticketID(in: $0).caseInsensitiveCompare(ticket.id) == .orderedSame }) else {
            throw DashboardMutationError.duplicateTicketID(ticket.id)
        }

        let target = url.standardizedFileURL
        for otherURL in otherDashboardURLs where otherURL.standardizedFileURL != target {
            let otherObject = try dashboardObject(from: files.read(from: otherURL))
            let duplicateExists = try ticketObjects(in: otherObject).contains {
                ticketID(in: $0).caseInsensitiveCompare(ticket.id) == .orderedSame
            }
            guard !duplicateExists else {
                throw DashboardMutationError.duplicateTicketID(ticket.id)
            }
        }

        let encodedTicket = try JSONEncoder().encode(ticket)
        guard let ticketObject = try JSONSerialization.jsonObject(with: encodedTicket) as? [String: Any] else {
            throw DashboardMutationError.invalidDocument
        }
        tickets.append(ticketObject)
        object["tickets"] = tickets
        return try save(object, to: url, expectedRevision: expectedRevision)
    }

    public func renameTicket(
        id: String,
        to title: String,
        in url: URL,
        expectedRevision: DashboardRevision
    ) throws -> DashboardSnapshot {
        try locked(url: url) {
            try renameTicketLocked(
                id: id,
                to: title,
                in: url,
                expectedRevision: expectedRevision
            )
        }
    }

    public func resolveTicket(
        id: String,
        reason: String,
        evidence: [String],
        completedBy: String,
        in url: URL,
        expectedRevision: DashboardRevision
    ) throws -> DashboardSnapshot {
        try locked(url: url) {
            let currentData = try currentData(at: url, expectedRevision: expectedRevision)
            var object = try dashboardObject(from: currentData)
            var tickets = try ticketObjects(in: object)
            guard let index = tickets.firstIndex(where: {
                ticketID(in: $0).caseInsensitiveCompare(id) == .orderedSame
            }) else {
                throw DashboardMutationError.ticketNotFound(id)
            }
            let timestamp = ISO8601DateFormatter().string(from: Date())
            var completion = tickets[index]["completion"] as? [String: Any] ?? [:]
            let existingResolutionPRs = tickets[index]["resolutionPrs"] as? [Int]
              ?? completion["resolutionPrs"] as? [Int] ?? []
            var retainedEvidence = completion["evidence"] as? [String] ?? []
            for item in evidence where !retainedEvidence.contains(item) {
                retainedEvidence.append(item)
            }
            completion["outcome"] = "completed"
            completion["reason"] = reason
            completion["resolutionPrs"] = existingResolutionPRs
            completion["evidence"] = retainedEvidence
            completion["completedBy"] = completedBy
            tickets[index]["status"] = "resolved"
            tickets[index]["completedAt"] = timestamp
            tickets[index]["updatedAt"] = timestamp
            tickets[index]["completion"] = completion
            object["tickets"] = tickets
            return try save(object, to: url, expectedRevision: expectedRevision)
        }
    }

    public func reopenTicket(
        id: String,
        in url: URL,
        expectedRevision: DashboardRevision
    ) throws -> DashboardSnapshot {
        try locked(url: url) {
            let currentData = try currentData(at: url, expectedRevision: expectedRevision)
            var object = try dashboardObject(from: currentData)
            var tickets = try ticketObjects(in: object)
            guard let index = tickets.firstIndex(where: {
                ticketID(in: $0).caseInsensitiveCompare(id) == .orderedSame
            }) else {
                throw DashboardMutationError.ticketNotFound(id)
            }

            let timestamp = ISO8601DateFormatter().string(from: Date())
            var history = tickets[index]["completionHistory"] as? [[String: Any]] ?? []
            var priorCompletion: [String: Any] = [
                "status": tickets[index]["status"] as? String ?? "resolved",
                "reopenedAt": timestamp,
            ]
            if let completedAt = tickets[index]["completedAt"] {
                priorCompletion["completedAt"] = completedAt
            }
            if let completion = tickets[index]["completion"] {
                priorCompletion["completion"] = completion
            }
            history.append(priorCompletion)

            tickets[index]["status"] = "open"
            tickets[index]["updatedAt"] = timestamp
            tickets[index]["completionHistory"] = history
            tickets[index].removeValue(forKey: "completedAt")
            tickets[index].removeValue(forKey: "completion")
            object["tickets"] = tickets
            return try save(object, to: url, expectedRevision: expectedRevision)
        }
    }

    public func setTicketPriority(
        id: String,
        to priority: String,
        in url: URL,
        expectedRevision: DashboardRevision
    ) throws -> DashboardSnapshot {
        try locked(url: url) {
            try updateTicketFieldLocked(
                id: id,
                field: "priority",
                value: priority,
                in: url,
                expectedRevision: expectedRevision
            )
        }
    }

    public func setTicketStatus(
        id: String,
        to status: String,
        in url: URL,
        expectedRevision: DashboardRevision
    ) throws -> DashboardSnapshot {
        try locked(url: url) {
            try updateTicketFieldLocked(
                id: id,
                field: "status",
                value: status,
                in: url,
                expectedRevision: expectedRevision
            )
        }
    }

    public func setTicketDueDate(
        id: String,
        to dueDate: String?,
        source: String?,
        in url: URL,
        expectedRevision: DashboardRevision
    ) throws -> DashboardSnapshot {
        try locked(url: url) {
            let currentData = try currentData(at: url, expectedRevision: expectedRevision)
            var object = try dashboardObject(from: currentData)
            var tickets = try ticketObjects(in: object)
            guard let index = tickets.firstIndex(where: {
                ticketID(in: $0).caseInsensitiveCompare(id) == .orderedSame
            }) else {
                throw DashboardMutationError.ticketNotFound(id)
            }
            if let dueDate {
                let normalized = dueDate.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty, TaskTriagePolicy.date(from: normalized) != nil else {
                    throw DashboardMutationError.invalidFieldValue("dueDate")
                }
                let normalizedSource = source?.trimmingCharacters(in: .whitespacesAndNewlines)
                tickets[index]["dueDate"] = normalized
                tickets[index]["dueDateSource"] = normalizedSource?.isEmpty == false
                    ? normalizedSource : "User specified"
            } else {
                tickets[index].removeValue(forKey: "dueDate")
                tickets[index].removeValue(forKey: "dueDateSource")
            }
            tickets[index]["updatedAt"] = ISO8601DateFormatter().string(from: Date())
            object["tickets"] = tickets
            return try save(object, to: url, expectedRevision: expectedRevision)
        }
    }

    /// Appends an evidence link; an existing link to the same URL is left unchanged.
    public func addTicketLink(
        id: String,
        label: String,
        url link: String,
        type: String?,
        in url: URL,
        expectedRevision: DashboardRevision
    ) throws -> DashboardSnapshot {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let link = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { throw DashboardMutationError.invalidFieldValue("label") }
        guard ResourceLocator.url(for: link) != nil else { throw DashboardMutationError.invalidFieldValue("url") }
        return try locked(url: url) {
            let currentData = try currentData(at: url, expectedRevision: expectedRevision)
            var object = try dashboardObject(from: currentData)
            var tickets = try ticketObjects(in: object)
            guard let index = tickets.firstIndex(where: {
                ticketID(in: $0).caseInsensitiveCompare(id) == .orderedSame
            }) else {
                throw DashboardMutationError.ticketNotFound(id)
            }
            var links = tickets[index]["links"] as? [[String: Any]] ?? []
            if links.contains(where: { ($0["url"] as? String) == link }) {
                return DashboardSnapshot(
                    document: try JSONDecoder().decode(DashboardDocument.self, from: currentData),
                    revision: DashboardRevision(contents: currentData))
            }
            var entry: [String: Any] = ["label": label, "url": link]
            if let type = type?.trimmingCharacters(in: .whitespacesAndNewlines), !type.isEmpty { entry["type"] = type }
            links.append(entry)
            tickets[index]["links"] = links
            tickets[index]["updatedAt"] = ISO8601DateFormatter().string(from: Date())
            object["tickets"] = tickets
            return try save(object, to: url, expectedRevision: expectedRevision)
        }
    }

    private func updateTicketFieldLocked(
        id: String,
        field: String,
        value: String,
        in url: URL,
        expectedRevision: DashboardRevision
    ) throws -> DashboardSnapshot {
        let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedValue.isEmpty else { throw DashboardMutationError.invalidFieldValue(field) }

        let currentData = try currentData(at: url, expectedRevision: expectedRevision)
        var object = try dashboardObject(from: currentData)
        var tickets = try ticketObjects(in: object)
        guard let index = tickets.firstIndex(where: {
            ticketID(in: $0).caseInsensitiveCompare(id) == .orderedSame
        }) else {
            throw DashboardMutationError.ticketNotFound(id)
        }
        tickets[index][field] = normalizedValue
        tickets[index]["updatedAt"] = ISO8601DateFormatter().string(from: Date())
        object["tickets"] = tickets
        return try save(object, to: url, expectedRevision: expectedRevision)
    }

    private func renameTicketLocked(
        id: String,
        to title: String,
        in url: URL,
        expectedRevision: DashboardRevision
    ) throws -> DashboardSnapshot {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else { throw DashboardMutationError.invalidTitle }

        let currentData = try currentData(at: url, expectedRevision: expectedRevision)
        var object = try dashboardObject(from: currentData)
        var tickets = try ticketObjects(in: object)
        guard let index = tickets.firstIndex(where: {
            ticketID(in: $0).caseInsensitiveCompare(id) == .orderedSame
        }) else {
            throw DashboardMutationError.ticketNotFound(id)
        }
        tickets[index]["title"] = normalizedTitle
        object["tickets"] = tickets
        return try save(object, to: url, expectedRevision: expectedRevision)
    }

    public func modificationDate(at url: URL) throws -> Date? {
        try files.modificationDate(at: url)
    }

    private func currentData(
        at url: URL,
        expectedRevision: DashboardRevision
    ) throws -> Data {
        let currentData = try files.read(from: url)
        guard DashboardRevision(contents: currentData) == expectedRevision else {
            throw DashboardMutationError.concurrentModification
        }
        return currentData
    }

    private func dashboardObject(from data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["tickets"] is [[String: Any]]
        else {
            throw DashboardMutationError.invalidDocument
        }
        return object
    }

    private func ticketObjects(in object: [String: Any]) throws -> [[String: Any]] {
        guard let tickets = object["tickets"] as? [[String: Any]] else {
            throw DashboardMutationError.invalidDocument
        }
        return tickets
    }

    private func ticketID(in object: [String: Any]) -> String {
        object["id"] as? String ?? ""
    }

    private func save(
        _ object: [String: Any],
        to url: URL,
        expectedRevision: DashboardRevision
    ) throws -> DashboardSnapshot {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        let document = try JSONDecoder().decode(DashboardDocument.self, from: data)
        _ = try currentData(at: url, expectedRevision: expectedRevision)
        try files.write(data, to: url)
        return DashboardSnapshot(
            document: document,
            revision: DashboardRevision(contents: data)
        )
    }

    private func locked<T>(url: URL, _ operation: () throws -> T) throws -> T {
        try FocusQueueFileLock.withLocks(for: [url], operation)
    }
}

public protocol LocalStateStoring: Sendable {
    func load() async throws -> LocalState
    func save(_ state: LocalState) async throws
}

public actor JSONLocalStateStore: LocalStateStoring {
    private let url: URL
    private let files: any FileAccessing
    private var cached: LocalState?

    public init(url: URL, files: any FileAccessing = SystemFileAccessor()) {
        self.url = url
        self.files = files
    }

    public func load() throws -> LocalState {
        if let cached {
            return cached
        }
        guard files.fileExists(at: url) else {
            let state = LocalState()
            cached = state
            return state
        }
        let state = try Self.decoder.decode(LocalState.self, from: files.read(from: url))
        cached = state
        return state
    }

    public func save(_ state: LocalState) throws {
        try files.write(try Self.encoder.encode(state), to: url)
        cached = state
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static var decoder: JSONDecoder {
        JSONDecoder()
    }
}

public actor ReviewArtifactStore {
    public let directory: URL
    private let files: any FileAccessing
    private let maximumLogCharacters: Int

    public init(
        directory: URL,
        files: any FileAccessing = SystemFileAccessor(),
        maximumLogCharacters: Int = 128_000
    ) {
        self.directory = directory
        self.files = files
        self.maximumLogCharacters = maximumLogCharacters
    }

    public nonisolated func requestURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    public nonisolated func logURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).log")
    }

    public func writeRequest(_ request: CompletionRequest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try files.write(try encoder.encode(request), to: requestURL(for: request.id))
    }

    @discardableResult
    public func writeLog(_ log: String, for id: UUID) throws -> URL {
        let bounded = String(log.prefix(maximumLogCharacters))
        try files.write(Data(bounded.utf8), to: logURL(for: id))
        return logURL(for: id)
    }
}
