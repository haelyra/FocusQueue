import CryptoKit
import Foundation

/// Keeps a running agent current with its user and project data.
///
/// A launch brief reaches only a fresh app launch. The provider's prompt hook covers
/// everything else: shell launches, resumed sessions, and facts saved after launch.
/// Each session gets the facts once, then again only when they change.
public enum SharedDataDelivery {
    static let receiptLifetime: TimeInterval = 30 * 86_400

    /// The context to add to this hook event, or nil when the session is already current.
    public static func context(payload: [String: Any], provider: String, projectID: String?,
                               root: URL, now: Date = Date()) -> String? {
        guard let projectID, (payload["agent_id"] as? String)?.isEmpty != false,
              let session = payload["session_id"] as? String, !session.isEmpty else { return nil }
        let event = payload["hook_event_name"] as? String
        guard event == "UserPromptSubmit" || event == "SessionStart" else { return nil }
        let facts = TaskContext.sharedDataBlock(root: root, projectID: projectID) ?? ""
        let digest = SHA256.hash(data: Data(facts.utf8)).map { String(format: "%02x", $0) }.joined()
        let receipt = receiptURL(provider: provider, session: session, root: root)
        // A cleared or compacted conversation has lost whatever it was given.
        let forgotten = event == "SessionStart"
        if !forgotten, (try? String(contentsOf: receipt, encoding: .utf8)) == digest { return nil }
        save(digest, to: receipt, now: now)
        // The launch brief already carries these facts when it is the first prompt.
        if facts.isEmpty || (payload["prompt"] as? String)?.contains(facts) == true { return nil }
        return "Focus Queue saved data for this project. Follow these standing instructions:\n" + facts
    }

    /// The JSON Claude Code reads from a hook's stdout to add context to the turn.
    public static func claudeHookOutput(event: String, context: String) -> Data? {
        try? JSONSerialization.data(withJSONObject: ["hookSpecificOutput": [
            "hookEventName": event, "additionalContext": context]], options: [.withoutEscapingSlashes])
    }

    private static func receiptURL(provider: String, session: String, root: URL) -> URL {
        let name = SHA256.hash(data: Data("\(provider)\n\(session.lowercased())".utf8))
            .map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("tracking/data-delivery/\(name)")
    }

    private static func save(_ digest: String, to receipt: URL, now: Date) {
        let directory = receipt.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? Data(digest.utf8).write(to: receipt, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receipt.path)
        PromptExtraction.prune(directory, keeping: receipt.lastPathComponent, now: now, lifetime: receiptLifetime)
    }
}
