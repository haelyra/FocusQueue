import Foundation

public enum AgentCompletionTerminal: Sendable {
  case managed(TmuxSessionReference)
  case direct(DirectAgentLaunchReceipt)
  case absent
}

/// Text and paths remain positional arguments, including when the user copies
/// the resume command into a shell. Never resume an arbitrary/latest session.
public struct AgentCompletionMessage: Sendable {
  public let text: String
  public let directory: String
  public let resumeCommand: String

  public init(context: TaskContext, subtask: TaskSubtask, taskCompleted: Bool) throws {
    guard let session = subtask.sessionID, UUID(uuidString: session) != nil,
          let directory = subtask.workspace?.path ?? context.worktreePath,
          directory.hasPrefix("/") else {
      throw TaskContextError.commandFailed("The terminal was retained because its exact conversation or workspace is unknown.")
    }
    self.directory = directory
    let arguments = [subtask.provider.executableName] + subtask.provider.resumeArguments(sessionID: session)
    resumeCommand = "cd -- \(Self.quote(directory)) && " + arguments.map(Self.quote).joined(separator: " ")
    let scope = taskCompleted ? "Task \(context.ticketID)" : "Subtask for \(context.ticketID)"
    text = "Agent exited. \(scope) is complete.\nYou may close this window, or continue the conversation with:\n\n\(resumeCommand)\n"
  }

  public func command(shellPath: String? = nil) -> [String] {
    let shell = InteractiveAgentShell.executable(preferred: shellPath)
    return ["/bin/sh", "-c", "cd -- \"$1\" || exit 72; printf '\\n%s\\n' \"$2\"; exec \"$3\" -i",
            "focus-queue-completed", directory, text, shell]
  }

  private static func quote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
