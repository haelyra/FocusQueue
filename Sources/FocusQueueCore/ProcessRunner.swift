import Darwin
import Foundation

public struct ProcessSpecification: Sendable, Equatable {
    public let executable: String
    public let arguments: [String]
    public let workingDirectory: String?
    public let environment: [String: String]?
    public let timeoutSeconds: Int
    public let maximumOutputBytes: Int

    public init(
        executable: String,
        arguments: [String],
        workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        timeoutSeconds: Int = 30,
        maximumOutputBytes: Int = 128_000
    ) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.timeoutSeconds = timeoutSeconds
        self.maximumOutputBytes = maximumOutputBytes
    }
}

public struct ProcessResult: Sendable, Equatable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String
    public let timedOut: Bool

    public init(exitCode: Int32, standardOutput: String, standardError: String, timedOut: Bool) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.timedOut = timedOut
    }

    public var succeeded: Bool { exitCode == 0 && !timedOut }
}

public protocol ProcessRunning: Sendable {
    func run(_ specification: ProcessSpecification) async throws -> ProcessResult
}

public enum ProcessRunnerError: Error, LocalizedError {
    case executableMissing(String)
    case invalidWorkingDirectory(String)

    public var errorDescription: String? {
        switch self {
        case .executableMissing(let path):
            "Executable does not exist at \(path)."
        case .invalidWorkingDirectory(let path):
            "Working directory does not exist at \(path)."
        }
    }
}

public actor FoundationProcessRunner: ProcessRunning {
    public init() {}

    public func run(_ specification: ProcessSpecification) async throws -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: specification.executable) else {
            throw ProcessRunnerError.executableMissing(specification.executable)
        }
        if let workingDirectory = specification.workingDirectory,
           !FileManager.default.fileExists(atPath: workingDirectory) {
            throw ProcessRunnerError.invalidWorkingDirectory(workingDirectory)
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("focus-queue-process-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let outputURL = temporaryDirectory.appendingPathComponent("stdout")
        let errorURL = temporaryDirectory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)

        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer {
            try? outputHandle.close()
            try? errorHandle.close()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: specification.executable)
        process.arguments = specification.arguments
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        if let workingDirectory = specification.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }
        if let environment = specification.environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, supplied in supplied }
        }

        try process.run()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(specification.timeoutSeconds))
        var timedOut = false
        var wasCancelled = false
        var stopRequestedAt: ContinuousClock.Instant?
        var sentKill = false

        while process.isRunning {
            let now = clock.now
            if Task.isCancelled, stopRequestedAt == nil {
                wasCancelled = true
                stopRequestedAt = now
                process.terminate()
            } else if now >= deadline, stopRequestedAt == nil {
                timedOut = true
                stopRequestedAt = now
                process.terminate()
            }
            if let stopRequestedAt,
               now >= stopRequestedAt.advanced(by: .milliseconds(400)),
               !sentKill,
               process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
                sentKill = true
            }
            // A blocking waitUntilExit here can deadlock after Foundation has already
            // reported isRunning=false. Polling also lets cancellation tear down the
            // child before this actor accepts its next command.
            try? await Task.sleep(for: .milliseconds(25))
        }
        if wasCancelled {
            throw CancellationError()
        }
        try? outputHandle.synchronize()
        try? errorHandle.synchronize()

        let output = Self.boundedString(at: outputURL, maximumBytes: specification.maximumOutputBytes)
        let error = Self.boundedString(at: errorURL, maximumBytes: specification.maximumOutputBytes)
        return ProcessResult(
            exitCode: process.terminationStatus,
            standardOutput: output,
            standardError: error,
            timedOut: timedOut
        )
    }

    private static func boundedString(at url: URL, maximumBytes: Int) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        let bounded = data.count > maximumBytes ? data.suffix(maximumBytes) : data[...]
        return String(decoding: bounded, as: UTF8.self)
    }
}
