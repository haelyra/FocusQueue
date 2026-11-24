import Foundation

/// Builds the `answers` object `t3_pending_request respond` expects.
public enum T3AnswerBuilder {
    /// Each question maps to its typed text when present, otherwise its selected option label.
    /// Questions with neither are left out.
    public static func answers(for request: T3PendingRequest, selections: [String: String],
                               freeText: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for question in request.questions {
            let typed = freeText[question.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !typed.isEmpty { result[question.id] = typed }
            else if let selected = selections[question.id], !selected.isEmpty { result[question.id] = selected }
        }
        return result
    }

    /// Every question has an answer.
    public static func isComplete(_ request: T3PendingRequest, selections: [String: String],
                                  freeText: [String: String]) -> Bool {
        let answers = answers(for: request, selections: selections, freeText: freeText)
        return request.questions.allSatisfy { answers[$0.id] != nil }
    }
}

/// What a T3 agent row shows. No approve or deny action exists: T3 Code does
/// not let outside apps answer permission requests.
public struct T3RowPresentation: Equatable, Sendable {
    public enum Action: String, Equatable, Sendable {
        case openInT3, answer, removeAgent, sendPrompt, stop
    }

    /// Short state label, such as "Needs an answer".
    public var badge: String?
    /// Further lines: approval, reachability, launch, cleanup.
    public var notes: [String]
    public var actions: [Action]

    public static let needsAnswer = "Needs an answer"
    public static let needsApproval = "Needs approval"
    public static let unreachable = "T3 Code unreachable"
    public static let otherServer = "On another T3 Code server"
    public static let threadMissing = "Thread missing"
    public static let launchUnknown = "Launch status unknown, reconciling"

    public static func make(_ subtask: TaskSubtask) -> T3RowPresentation {
        var badge: String?
        var notes: [String] = []
        var actions: [Action] = []
        let reference = subtask.t3

        if subtask.t3Launch?.phase == .unknown || (subtask.t3Launch != nil && reference == nil) {
            if subtask.t3Launch?.phase == .unknown { badge = launchUnknown }
        }
        if let reference {
            switch reference.reachability {
            case .unreachable: badge = unreachable
            case .otherServer: badge = otherServer
            case .threadMissing:
                badge = threadMissing
                actions.append(.removeAgent)
            case .reachable:
                if !reference.openQuestionIds.isEmpty {
                    badge = needsAnswer
                    actions.append(.answer)
                    if reference.pendingApprovalCount > 0 { notes.append(needsApproval) }
                } else if reference.pendingApprovalCount > 0 {
                    badge = needsApproval
                }
            }
            switch reference.cleanup {
            case .pending(let reason): notes.append("Cleanup pending: \(reason)")
            case .retained(let message): notes.append(message)
            case .removed, nil: break
            }
            if reference.reachability != .threadMissing { actions.insert(.openInT3, at: 0) }
            if reference.reachability == .reachable, subtask.status != .completed, reference.archivedAt == nil {
                actions += [.sendPrompt, .stop]
            }
        }
        return T3RowPresentation(badge: badge, notes: notes, actions: actions)
    }
}
