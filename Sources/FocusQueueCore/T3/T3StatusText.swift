import Foundation

/// User-facing text for the T3 Code settings section. Pure, so it is unit tested without UI.
public enum T3StatusText {
    public static let insecureURLMessage = "Use https for servers that are not on this Mac"
    public static let fullAccessNote = "Focus Queue needs Full access. Choose Full access on T3 Code's approval page."
    public static let expiryNote = "Reconnect soon"
    public static let expiryWarningInterval: TimeInterval = 3 * 24 * 60 * 60

    public static func text(for status: T3ConnectionStatus, state: T3ConnectionState?, now: Date) -> String {
        let base = baseText(for: status, state: state)
        guard case .connected = status, expiresSoon(state, now: now) else { return base }
        return base + " · " + expiryNote
    }

    /// `http://127.0.0.1…`, `http://localhost…`, or any `https://…` host.
    public static func isAcceptableServerURL(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty else { return false }
        switch scheme {
        case "https":
            return true
        case "http":
            return host == "127.0.0.1" || host == "localhost"
        default:
            return false
        }
    }

    private static func baseText(for status: T3ConnectionStatus, state: T3ConnectionState?) -> String {
        switch status {
        case .disconnected:
            return "Not connected"
        case .signingIn:
            return "Approve Focus Queue in T3 Code"
        case .connected(_, let version):
            let label = state?.environmentLabel ?? "T3 Code server"
            return "Connected to \(label), T3 Code \(version)"
        case .unreachable:
            return "T3 Code is not running"
        case .serverTooOld(let version):
            let name = version.map { "T3 Code \($0)" } ?? "T3 Code"
            return "\(name) is too old. Live updates need T3 Code 0.1.12 or later"
        case .accessTooLow:
            return "Access too low: reconnect and choose Full access"
        case .unauthorized:
            return "Access expired or revoked. Reconnect T3 Code"
        case .otherServer:
            return "Connected to a different T3 Code server than your existing agents"
        }
    }

    private static func expiresSoon(_ state: T3ConnectionState?, now: Date) -> Bool {
        guard let expiresAt = state?.tokenExpiresAt else { return false }
        return expiresAt.timeIntervalSince(now) <= expiryWarningInterval
    }
}
