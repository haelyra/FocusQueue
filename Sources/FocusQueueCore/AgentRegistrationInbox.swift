import Foundation
import CryptoKit
import Darwin

public struct PendingAgentRegistration: Sendable {
    public let session: TaskAgentSession
    fileprivate let filename: String
    fileprivate let generation: String
}

public actor AgentRegistrationInbox {
    public static let notificationName = "com.haelyra.ecc-focus-queue.agent-registration"

    private let directory: URL
    private let files: FileManager

    public init(directory: URL, files: FileManager = .default) {
        self.directory = directory
        self.files = files
    }

    public func submit(_ session: TaskAgentSession) throws {
        try prepareDirectory()
        try withLock {
            let filename = Self.filename(for: session)
            let destination = directory.appendingPathComponent(filename)
            if files.fileExists(atPath: destination.path), try isSymbolicLink(destination) {
                throw TaskContextError.commandFailed("Agent registration storage is redirected.")
            }
            for url in (try? files.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey],
                options: [.skipsHiddenFiles])) ?? []
            where url.pathExtension == "json" && url != destination {
                guard (try? isSymbolicLink(url)) != true else { continue }
                guard let data = try? Data(contentsOf: url),
                      let pending = try? JSONDecoder().decode(TaskAgentSession.self, from: data),
                      pending.provider == session.provider,
                      pending.sessionID.caseInsensitiveCompare(session.sessionID) == .orderedSame
                else { continue }
                try? files.removeItem(at: url)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(session).write(to: destination, options: .atomic)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
    }

    public func submitRegisteredSession(
        context: TaskContext, subtaskID: String, provider: AgentProvider,
        sessionID: String, supportDirectory: URL
    ) throws {
        guard let subtask = context.subtasks.first(where: { $0.id == subtaskID }),
              subtask.provider == provider,
              subtask.sessionID?.caseInsensitiveCompare(sessionID) == .orderedSame
        else {
            throw TaskContextError.commandFailed(
                "The routed agent could not publish its registered session.")
        }
        try submit(TaskAgentSession(
            id: UUID(uuidString: subtaskID) ?? UUID(),
            ticketID: context.ticketID, provider: provider, sessionID: sessionID,
            tabTitle: subtask.title, taskTitle: context.title,
            workingDirectory: subtask.workspace?.path
                ?? context.worktreePath ?? context.repositoryPath ?? "",
            subtaskID: subtask.id, contextDirectory: context.contextDirectory.path,
            supportDirectory: supportDirectory.path, tmux: subtask.tmux))
    }

    public func pendingRecords() throws -> [PendingAgentRegistration] {
        guard files.fileExists(atPath: directory.path) else { return [] }
        try prepareDirectory()
        return try withLock {
            try files.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard (try? isSymbolicLink(url)) != true else { return nil }
                guard (try? files.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: url.path)) != nil else {
                    return nil
                }
                guard let data = try? Data(contentsOf: url) else { return nil }
                guard let session = try? JSONDecoder().decode(TaskAgentSession.self, from: data) else {
                    return nil
                }
                return PendingAgentRegistration(
                    session: session, filename: url.lastPathComponent,
                    generation: Self.digest(data))
            }
        }
    }

    public func pending() throws -> [TaskAgentSession] {
        try pendingRecords().map(\.session)
    }

    public func acknowledge(_ records: [PendingAgentRegistration]) {
        guard files.fileExists(atPath: directory.path),
              (try? prepareDirectory()) != nil else { return }
        try? withLock {
            for record in records {
                let url = directory.appendingPathComponent(record.filename)
                guard url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
                      (try? isSymbolicLink(url)) != true,
                      let data = try? Data(contentsOf: url),
                      Self.digest(data) == record.generation
                else { continue }
                try? files.removeItem(at: url)
            }
        }
    }

    private func prepareDirectory() throws {
        if files.fileExists(atPath: directory.path) {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw TaskContextError.commandFailed("Agent registration storage is redirected.")
            }
        } else {
            try files.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func isSymbolicLink(_ url: URL) throws -> Bool {
        try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        let lockURL = directory.appendingPathComponent(".inbox.lock")
        let descriptor = Darwin.open(
            lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw TaskContextError.commandFailed("Agent registration storage could not be locked.")
        }
        defer { Darwin.close(descriptor) }
        guard fchmod(descriptor, 0o600) == 0 else {
            throw TaskContextError.commandFailed("Agent registration lock permissions could not be secured.")
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw TaskContextError.commandFailed("Agent registration storage could not be locked.")
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    private static func filename(for session: TaskAgentSession) -> String {
        let identity = "\(session.provider.rawValue):\(session.sessionID.lowercased())"
        return digest(Data(identity.utf8)) + ".json"
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
