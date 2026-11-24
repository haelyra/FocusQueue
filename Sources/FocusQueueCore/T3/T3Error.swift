import Foundation

/// Every failure the T3 Code runtime reports. `rejected` is a definite refusal;
/// `outcomeUnknown` means the request may have taken effect.
public enum T3Error: Error, Equatable, Sendable {
    case notRunning
    case unauthorized
    case accessTooLow
    case serverTooOld(String?)
    case otherServer(expected: String, actual: String)
    case rejected(code: String, message: String)
    case outcomeUnknown(String)
    case threadNotFound(String)
    case requestNotOpen(String)
    case projectAlreadyRegistered
    case checkoutInManagedFolder(String)
    case invalidResponse(String)
    case signInCancelled
    case signInTimedOut
}

extension T3Error: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notRunning: "T3 Code is not running"
        case .unauthorized: "Access expired or revoked. Reconnect T3 Code"
        case .accessTooLow: "Access too low: reconnect and choose Full access"
        case .serverTooOld(let version):
            "T3 Code \(version ?? "") is too old. Live updates need T3 Code \(T3Defaults.minimumVersion) or later"
                .replacingOccurrences(of: "  ", with: " ")
        case .otherServer: "On another T3 Code server"
        case .rejected(_, let message): message
        case .outcomeUnknown(let detail): "Launch status unknown: \(detail)"
        case .threadNotFound: "Thread missing"
        case .requestNotOpen: "This question is no longer open"
        case .projectAlreadyRegistered: "The workspace is already registered to a project."
        case .checkoutInManagedFolder(let folder):
            "The agent checkout would be inside T3 Code's worktree folder \(folder), which T3 Code may delete. Move T3 Code's worktree location or the repository."
        case .invalidResponse(let detail): "Unexpected T3 Code response: \(detail)"
        case .signInCancelled: "The T3 Code sign-in was not completed"
        case .signInTimedOut: "The T3 Code sign-in timed out"
        }
    }

    /// The request may have reached T3 Code, so its effect must be reconciled, not assumed.
    public var isOutcomeUnknown: Bool {
        if case .outcomeUnknown = self { return true }
        return false
    }

    /// The server could not be reached or answered ambiguously.
    public var isConnectivity: Bool {
        switch self {
        case .notRunning, .outcomeUnknown: true
        default: false
        }
    }
}
