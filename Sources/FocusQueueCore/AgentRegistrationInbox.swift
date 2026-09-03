import Foundation

public actor AgentRegistrationInbox {
    public static let notificationName = "com.haelyra.ecc-focus-queue.agent-registration"

    private let directory: URL
    private let files: FileManager

    public init(directory: URL, files: FileManager = .default) {
        self.directory = directory
        self.files = files
    }

    public func submit(_ session: TaskAgentSession) throws {
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(session.id.uuidString).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(session).write(to: destination, options: .atomic)
    }

    public func pending() throws -> [TaskAgentSession] {
        guard files.fileExists(atPath: directory.path) else { return [] }
        return try files.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        .compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(TaskAgentSession.self, from: data)
        }
    }

    public func acknowledge(_ sessions: [TaskAgentSession]) {
        for session in sessions {
            let url = directory.appendingPathComponent("\(session.id.uuidString).json")
            try? files.removeItem(at: url)
        }
    }
}
