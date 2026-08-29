import Foundation

public protocol FileAccessing: Sendable {
    func read(from url: URL) throws -> Data
    func write(_ data: Data, to url: URL) throws
    func createDirectory(at url: URL) throws
    func fileExists(at url: URL) -> Bool
    func modificationDate(at url: URL) throws -> Date?
}

public struct SystemFileAccessor: FileAccessing {
    public init() {}

    public func read(from url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    public func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    public func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func modificationDate(at url: URL) throws -> Date? {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return attributes[.modificationDate] as? Date
    }
}

public protocol ConfigurationLoading: Sendable {
    func loadOrCreate(default defaultConfiguration: AppConfiguration) async throws -> AppConfiguration
}

public actor JSONConfigurationRepository: ConfigurationLoading {
    private let url: URL
    private let files: any FileAccessing

    public init(url: URL, files: any FileAccessing = SystemFileAccessor()) {
        self.url = url
        self.files = files
    }

    public func loadOrCreate(default defaultConfiguration: AppConfiguration) throws -> AppConfiguration {
        if !files.fileExists(at: url) {
            let data = try Self.encoder.encode(defaultConfiguration)
            try files.write(data, to: url)
            return try defaultConfiguration.validated()
        }

        let data = try files.read(from: url)
        return try JSONDecoder().decode(AppConfiguration.self, from: data).validated()
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

public protocol DashboardLoading: Sendable {
    func load(from url: URL) async throws -> DashboardDocument
    func modificationDate(at url: URL) async throws -> Date?
}

public actor JSONDashboardRepository: DashboardLoading {
    private let files: any FileAccessing

    public init(files: any FileAccessing = SystemFileAccessor()) {
        self.files = files
    }

    public func load(from url: URL) throws -> DashboardDocument {
        let data = try files.read(from: url)
        return try JSONDecoder().decode(DashboardDocument.self, from: data)
    }

    public func modificationDate(at url: URL) throws -> Date? {
        try files.modificationDate(at: url)
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
