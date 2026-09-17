import Foundation

/// A launch receipt exists before a provider has a conversation UUID. Optional
/// metadata never grants permission to resume, complete, or delete anything.
public struct AgentIntakeReceipt: Decodable, Identifiable, Sendable {
    public let launchID: String
    public let cwd: String
    public let title: String?
    public let role: String?
    public let phase: String?
    public let note: String?
    public let processID: Int32?
    public let processStartedAt: String?
    public let sessionID: String?
    public let taskID: String?
    public let agentID: String?
    public let reference: TmuxSessionReference?
    public var id: String { "intake-" + launchID }

    private enum CodingKeys: String, CodingKey {
        case launchID, cwd, title, role, phase, note, processID, processStartedAt, sessionID, taskID, agentID, reference
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        launchID = try values.decode(String.self, forKey: .launchID)
        cwd = (try? values.decodeIfPresent(String.self, forKey: .cwd)) ?? ""
        title = try? values.decodeIfPresent(String.self, forKey: .title)
        role = try? values.decodeIfPresent(String.self, forKey: .role)
        phase = try? values.decodeIfPresent(String.self, forKey: .phase)
        note = try? values.decodeIfPresent(String.self, forKey: .note)
        processID = try? values.decodeIfPresent(Int32.self, forKey: .processID)
        processStartedAt = try? values.decodeIfPresent(String.self, forKey: .processStartedAt)
        sessionID = try? values.decodeIfPresent(String.self, forKey: .sessionID)
        taskID = try? values.decodeIfPresent(String.self, forKey: .taskID)
        agentID = try? values.decodeIfPresent(String.self, forKey: .agentID)
        reference = try? values.decodeIfPresent(TmuxSessionReference.self, forKey: .reference)
    }

    public var pendingRegistration: ExternalAgentRegistration {
        ExternalAgentRegistration(id: id, provider: .codex, sessionID: nil, agentID: launchID,
            cwd: cwd, title: title?.isEmpty == false ? title! : "Codex agent",
            reason: note ?? "Tracked launch. Waiting for provider identity and optional task details.",
            eventName: phase ?? "pending", updatedAt: .distantPast, tmux: reference)
    }
}

public enum AgentIntakeStore {
    public static func load(root: URL) -> [AgentIntakeReceipt] {
        let directory = root.appendingPathComponent("tracking/launches")
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return [] }
        return urls.compactMap { url in
            guard url.pathExtension == "json",
                (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                let data = try? Data(contentsOf: url),
                let receipt = try? JSONDecoder().decode(AgentIntakeReceipt.self, from: data),
                UUID(uuidString: receipt.launchID) != nil else { return nil }
            return receipt
        }
    }

    /// Exact pane identity or process ancestry connects the provisional receipt
    /// to an already verified native session ID. CWD alone is never sufficient.
    public static func match(_ process: KnownProviderProcess, tmux: TmuxSessionReference?,
                             receipts: [AgentIntakeReceipt], parents: [Int32: ProcessIdentity],
                             candidateSessionsForProcess: Set<String> = []) -> AgentIntakeReceipt? {
        let matches = receipts.filter { receipt in
            guard receipt.phase != "blocked" else { return false }
            guard receipt.cwd.hasPrefix("/") else { return false }
            if let exact = receipt.sessionID, exact.lowercased() != process.sessionID.lowercased() { return false }
            // A provider can own a parent and several child threads in one PID.
            // Process/pane identity alone cannot select the launch's root UUID.
            if candidateSessionsForProcess.count > 1 && receipt.sessionID == nil { return false }
            if let reference = receipt.reference { return reference == tmux }
            guard let ancestor = receipt.processID, let started = receipt.processStartedAt,
                parents[ancestor]?.startedAt == started else { return false }
            var pid = process.processID
            var visited = Set<Int32>()
            for _ in 0..<64 {
                if pid == ancestor { return ExternalAgentRegistry.normalized(receipt.cwd) == ExternalAgentRegistry.normalized(process.cwd) }
                guard visited.insert(pid).inserted, let parent = parents[pid]?.parent, parent > 1 else { return false }
                pid = parent
            }
            return false
        }
        return matches.count == 1 ? matches[0] : nil
    }

    public struct ProcessIdentity: Sendable {
        public let parent: Int32
        public let startedAt: String
        public init(parent: Int32, startedAt: String) { self.parent = parent; self.startedAt = startedAt }
    }

    public static func processParents(runner: any ProcessRunning = FoundationProcessRunner()) async throws -> [Int32: ProcessIdentity] {
        let result = try await runner.run(.init(executable: "/bin/ps", arguments: ["-axo", "pid=,ppid=,lstart="], timeoutSeconds: 10))
        guard result.succeeded else { throw TaskContextError.commandFailed("Could not inspect launch process ancestry.") }
        return Dictionary(result.standardOutput.split(separator: "\n").compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 3, let pid = Int32(fields[0]), let parent = Int32(fields[1]) else { return nil }
            return (pid, ProcessIdentity(parent: parent, startedAt: fields.dropFirst(2).joined(separator: " ")))
        }, uniquingKeysWith: { _, last in last })
    }

    public static func resolve(_ receipt: AgentIntakeReceipt, sessionID: String, root: URL) throws {
        guard UUID(uuidString: sessionID) != nil else { throw TaskContextError.invalidIdentifier }
        let directory = root.appendingPathComponent("tracking/resolutions")
        guard (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw TaskContextError.commandFailed("Tracking resolution storage is redirected.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent(receipt.launchID + ".json")
        let data = try JSONSerialization.data(withJSONObject: ["launchID": receipt.launchID, "sessionID": sessionID.lowercased()], options: .sortedKeys)
        if let existing = try? Data(contentsOf: path), existing != data {
            throw TaskContextError.commandFailed("This launch already has a different resolved identity; retained for review.")
        }
        if (try? Data(contentsOf: path)) != data {
            try data.write(to: path, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        }
    }

    public static func unresolved(root: URL) -> [AgentIntakeReceipt] {
        load(root: root).filter { !isResolved($0, root: root) }
    }

    private static func isResolved(_ receipt: AgentIntakeReceipt, root: URL) -> Bool {
        let path = root.appendingPathComponent("tracking/resolutions/\(receipt.launchID).json")
        guard let data = try? Data(contentsOf: path),
            let value = try? JSONSerialization.jsonObject(with: data) as? [String: String],
            value["launchID"] == receipt.launchID,
            value["sessionID"].flatMap(UUID.init(uuidString:)) != nil else { return false }
        return true
    }

    public static func pending(root: URL) -> [ExternalAgentRegistration] {
        unresolved(root: root).map(\.pendingRegistration)
    }
}
