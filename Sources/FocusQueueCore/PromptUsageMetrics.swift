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

    public init(source: String, component: String, provider: String? = nil, model: String? = nil,
                taskID: String? = nil, characters: Int = 0, actualInputTokens: Int? = nil,
                actualOutputTokens: Int? = nil, timestamp: Date = Date(), id: String = UUID().uuidString) {
        self.id = id; self.timestamp = timestamp; self.source = source; self.component = component
        self.provider = provider; self.model = model; self.taskID = taskID
        self.characters = characters
        self.estimatedInputTokens = Int((Double(characters) / 4.0).rounded())
        self.actualInputTokens = actualInputTokens; self.actualOutputTokens = actualOutputTokens
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
