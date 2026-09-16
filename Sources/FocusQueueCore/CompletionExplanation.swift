import Foundation

public enum CompletionExplanation {
    /// Older verifiers led with a verdict and UUID. Surface the actual reason instead.
    public static func concise(_ summary: String) -> String {
        let paragraphs = summary.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let reason = paragraphs.first(where: {
            let line = $0.lowercased()
            return !line.hasPrefix("completion rejected for subtask") && !line.hasPrefix("verdict:")
        }) ?? paragraphs.first ?? "Review details are available."
        let line = reason.components(separatedBy: "\n").first ?? reason
        return line.count > 220 ? String(line.prefix(217)) + "…" : line
    }
}
