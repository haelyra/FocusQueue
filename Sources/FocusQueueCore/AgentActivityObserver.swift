import Foundation

/// Observes structured events for an already registered conversation. Never guesses identity
/// from a transcript, treats prose as approval, or marks the assignment complete from a reply.
public struct AgentActivityEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case working, result, attention(AgentAttention) }
    public let id: String
    public let date: Date
    public let kind: Kind
    public let summary: String

    public static func latest(in data: Data, provider: AgentProvider, sessionID: String) -> Self? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        var latest: Self?
        for line in data.split(separator: 10) {
            guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let timestamp = record["timestamp"] as? String,
                  let date = fractional.date(from: timestamp) ?? plain.date(from: timestamp) else { continue }
            var kind: Kind?
            var summary = ""
            if provider == .codex, let payload = record["payload"] as? [String: Any] {
                if let thread = payload["thread_id"] as? String, thread.lowercased() != sessionID.lowercased() { continue }
                let type = payload["type"] as? String
                if record["type"] as? String == "event_msg" {
                    switch type {
                    case "task_started", "turn_started", "user_message": kind = .working
                    case "task_complete", "task_completed", "turn_complete", "turn_completed":
                        kind = .result; summary = payload["last_agent_message"] as? String ?? "New agent response"
                    case "turn_aborted": kind = .attention(.interrupted); summary = "The agent turn was interrupted."
                    case "exec_approval_request", "apply_patch_approval_request":
                        kind = .attention(.approval); summary = "The agent is waiting for approval in its terminal."
                    case "request_user_input": kind = .attention(.question); summary = "The agent has a question to answer."
                    case "error": kind = .attention(.failed); summary = payload["message"] as? String ?? "The agent reported a problem."
                    default: break
                    }
                } else if record["type"] as? String == "response_item" {
                    if type == "message", payload["role"] as? String == "assistant", payload["phase"] as? String == "final_answer" {
                        kind = .result
                        summary = (payload["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
                    } else if ["function_call", "custom_tool_call"].contains(type ?? ""),
                              (payload["name"] as? String)?.contains("request_user_input") == true {
                        kind = .attention(.question); summary = "The agent has a question to answer."
                    } else if ["function_call_output", "custom_tool_call_output"].contains(type ?? "") {
                        kind = .working
                    }
                }
            } else if provider == .claude {
                guard (record["sessionId"] as? String)?.lowercased() == sessionID.lowercased(),
                      record["isSidechain"] as? Bool != true else { continue }
                let type = record["type"] as? String
                if type == "user" {
                    let message = record["message"] as? [String: Any]
                    let text = message?["content"] as? String
                        ?? (message?["content"] as? [[String: Any]])?.first?["text"] as? String
                    if ["[Request interrupted by user]", "[Request interrupted by user for tool use]"].contains(text ?? "") {
                        kind = .attention(.interrupted); summary = "The agent turn was interrupted."
                    } else { kind = .working }
                }
                if type == "assistant", let message = record["message"] as? [String: Any] {
                    let content = message["content"] as? [[String: Any]] ?? []
                    if record["isApiErrorMessage"] as? Bool == true {
                        kind = .attention(.failed)
                    } else if content.contains(where: { $0["name"] as? String == "AskUserQuestion" }) {
                        kind = .attention(.question)
                    } else if message["stop_reason"] as? String == "max_tokens" {
                        kind = .attention(.incomplete)
                    } else if ["end_turn", "stop_sequence"].contains(message["stop_reason"] as? String ?? ""),
                              content.contains(where: { $0["type"] as? String == "text" }) {
                        kind = .result
                    }
                    summary = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
                    if summary.isEmpty, kind == .attention(.question) { summary = "The agent has a question to answer." }
                }
            }
            guard let kind else { continue }
            let id = (record["uuid"] as? String ?? record["id"] as? String ?? timestamp) + ":\(kind)"
            let event = Self(id: id, date: date, kind: kind, summary: String(summary.prefix(2_000)))
            if date >= (latest?.date ?? .distantPast) { latest = event }
        }
        return latest
    }
}

public actor AgentActivityObserver {
    private let codexRoot: URL
    private let claudeRoot: URL
    private var locations: [String: URL] = [:]
    private var searchedAt: [String: Date] = [:]

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        codexRoot = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".codex")
        claudeRoot = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".claude")
    }

    public func latest(for agent: TaskSubtask) throws -> AgentActivityEvent? {
        guard let sessionID = agent.sessionID, UUID(uuidString: sessionID) != nil else { return nil }
        let key = agent.provider.rawValue + ":" + sessionID.lowercased()
        if locations[key] == nil, Date().timeIntervalSince(searchedAt[key] ?? .distantPast) >= 60 {
            searchedAt[key] = Date()
            let root = agent.provider == .codex ? codexRoot.appendingPathComponent("sessions") : claudeRoot.appendingPathComponent("projects")
            if let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                var inspected = 0
                for case let url as URL in files {
                    inspected += 1
                    if inspected > 50_000 { break }
                    guard url.pathExtension == "jsonl", url.lastPathComponent.lowercased().hasSuffix(sessionID.lowercased() + ".jsonl") else { continue }
                    locations[key] = url
                    break
                }
            }
        }
        guard let url = locations[key] else { return nil }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        try handle.seek(toOffset: end > 262_144 ? end - 262_144 : 0)
        return AgentActivityEvent.latest(in: try handle.readToEnd() ?? Data(), provider: agent.provider, sessionID: sessionID)
    }
}
