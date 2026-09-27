import Foundation

/// One escalation launch request written by the ingestion pipeline.
public struct AgentLaunchRequest: Codable, Equatable, Sendable {
    public var version: Int?
    public var ticketId: String
    public var title: String?
    public var provider: String?
    public var model: String?
    public var effort: String?
    public var prompt: String?
    public var requestedAt: String?

    public init(ticketId: String, title: String? = nil, provider: String? = nil,
                model: String? = nil, effort: String? = nil, prompt: String? = nil,
                version: Int? = nil, requestedAt: String? = nil) {
        self.ticketId = ticketId
        self.title = title
        self.provider = provider
        self.model = model
        self.effort = effort
        self.prompt = prompt
        self.version = version
        self.requestedAt = requestedAt
    }
}

/// Consumes launch requests dropped into the ingestion runtime directory.
public actor AgentLaunchRequestInbox {
    private let directory: URL
    private let files: FileManager

    public init(directory: URL, files: FileManager = .default) {
        self.directory = directory
        self.files = files
    }

    public func pending() throws -> [AgentLaunchRequest] {
        guard files.fileExists(atPath: directory.path) else { return [] }
        return try files.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(AgentLaunchRequest.self, from: data)
        }
        .filter { !$0.ticketId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Removes the files that actually carried this ticket's request, never a
    /// path derived from the untrusted identifier.
    public func consume(_ request: AgentLaunchRequest) {
        guard let urls = try? files.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return }
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let candidate = try? JSONDecoder().decode(AgentLaunchRequest.self, from: data),
                  candidate.ticketId == request.ticketId else { continue }
            try? files.removeItem(at: url)
        }
    }
}
