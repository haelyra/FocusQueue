import Darwin
import Foundation

/// Local metadata only. Prompt contents never enter the analytics file.
public struct PromptUsageEvent: Codable, Sendable, Identifiable {
    public let id: String
    public let timestamp: Date
    public let source: String
    public let component: String
    public let provider: String?
    public let model: String?
    public let taskID: String?
    public let characters: Int
    public let estimatedInputTokens: Int
    public let actualInputTokens: Int?
    public let actualOutputTokens: Int?
    public let actualTotalTokens: Int?
    public let cachedInputTokens: Int?
    public let runID: String?
    public let scope: String?

    public init(source: String, component: String, provider: String? = nil, model: String? = nil,
                taskID: String? = nil, characters: Int = 0, actualInputTokens: Int? = nil,
                actualOutputTokens: Int? = nil, actualTotalTokens: Int? = nil,
                cachedInputTokens: Int? = nil, runID: String? = nil, scope: String? = "app",
                timestamp: Date = Date(), id: String = UUID().uuidString) {
        self.id = id; self.timestamp = timestamp; self.source = source; self.component = component
        self.provider = provider; self.model = model; self.taskID = taskID
        self.characters = characters
        self.estimatedInputTokens = Int((Double(characters) / 4.0).rounded())
        self.actualInputTokens = actualInputTokens; self.actualOutputTokens = actualOutputTokens
        self.actualTotalTokens = actualTotalTokens; self.cachedInputTokens = cachedInputTokens
        self.runID = runID; self.scope = scope
    }
}

public extension PromptUsageEvent {
    /// The whole prompt the provider processed. Claude reports cache reads and
    /// writes outside `input_tokens`, so its recorders store them in
    /// `cachedInputTokens`; Codex and Kimi already count cached tokens as input.
    var reportedInputTokens: Int? {
        guard let input = actualInputTokens else { return nil }
        return provider == "claude" ? input + (cachedInputTokens ?? 0) : input
    }

    /// Input plus output. Older Claude records stored a total without cached input,
    /// so the total is rebuilt from its parts whenever they exist.
    var reportedTotalTokens: Int? {
        guard reportedInputTokens != nil || actualOutputTokens != nil else { return actualTotalTokens }
        return (reportedInputTokens ?? 0) + (actualOutputTokens ?? 0)
    }
}

public struct PromptUsageSummary: Sendable {
    public let runs: Int
    public let estimatedTokens: Int
    public let estimatedAverage: Int
    public let actualTokens: Int?
    public let actualAverage: Int?
    public let reportedRuns: Int
    public let reportedInputTokens: Int
    public let reportedOutputTokens: Int
    public let cachedInputTokens: Int

    public init(events: [PromptUsageEvent]) {
        runs = Set(events.compactMap(\.runID)).count
        estimatedTokens = events.filter { $0.scope != "provider" }
            .reduce(0) { $0 + $1.estimatedInputTokens }
        estimatedAverage = runs > 0 ? estimatedTokens / runs : 0
        let providerEvents = events.filter { $0.scope == "provider" }
        let reports = providerEvents.compactMap(\.reportedTotalTokens)
        reportedRuns = reports.count
        actualTokens = reports.isEmpty ? nil : reports.reduce(0, +)
        actualAverage = reports.isEmpty ? nil : reports.reduce(0, +) / reports.count
        reportedInputTokens = providerEvents.compactMap(\.reportedInputTokens).reduce(0, +)
        reportedOutputTokens = events.compactMap(\.actualOutputTokens).reduce(0, +)
        cachedInputTokens = events.compactMap(\.cachedInputTokens).reduce(0, +)
    }
}

public enum PromptUsageMetrics {
    public static func file(in supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent("analytics/prompt-usage.jsonl")
    }

    public static func record(_ event: PromptUsageEvent, in supportDirectory: URL) {
        let url = file(in: supportDirectory)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            var data = try JSONEncoder.analytics.encode(event)
            data.append(0x0A)
            let descriptor = Darwin.open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { return }
            defer { Darwin.close(descriptor) }
            guard flock(descriptor, LOCK_EX) == 0 else { return }
            defer { flock(descriptor, LOCK_UN) }
            var offset = 0
            try data.withUnsafeBytes { buffer in
                while offset < data.count {
                    let written = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), data.count - offset)
                    guard written > 0 else { throw CocoaError(.fileWriteUnknown) }
                    offset += written
                }
            }
        } catch {
            // Analytics must never prevent an agent launch or model request.
        }
    }

    public static func load(in supportDirectory: URL) -> [PromptUsageEvent] {
        guard let data = try? Data(contentsOf: file(in: supportDirectory)),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            try? JSONDecoder.analytics.decode(PromptUsageEvent.self, from: Data($0.utf8))
        }
    }
}

private extension JSONEncoder {
    static var analytics: JSONEncoder { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; return encoder }
}

private extension JSONDecoder {
    static var analytics: JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }
}
