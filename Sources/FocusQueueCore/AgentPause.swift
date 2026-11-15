import Foundation

/// Pause interrupts an agent's running turn in its managed tmux pane and
/// Resume asks it to carry on in the same conversation. Both keep the
/// provider process, so its context survives; only the provider's own
/// server-side prompt cache can expire while the agent waits.
public struct AgentPauseController: Sendable {
  /// Short, so a resume adds little to the conversation it continues.
  public static let resumePrompt =
    "Continue where you left off. Focus Queue paused your last turn; if a step was cut short, check its result before moving on."

  public enum PauseError: Error, LocalizedError, Equatable {
    case noManagedPane(String)
    case completed(String)
    case inputNotReady(String)
    case startupPrompt(String)
    case noSavedConversation(String)
    case runningElsewhere(String)

    public var errorDescription: String? {
      switch self {
      case .noManagedPane(let title):
        "\(title) has no Focus Queue tmux pane, so it cannot be paused or resumed from here. Open it and press Esc in its terminal."
      case .completed(let title):
        "\(title) already finished. Open it to give it new work."
      case .inputNotReady(let title):
        "\(title) did not show its input box in time, so the resume prompt was not sent. Open the agent and type continue."
      case .startupPrompt(let title):
        "\(title) is still asking whether to trust its folder. Esc would quit it, so Focus Queue did not pause it. Open the agent and answer the prompt."
      case .noSavedConversation(let title):
        "\(title)'s pane closed and it has no saved conversation to reopen. Start a new agent instead."
      case .runningElsewhere(let title):
        "\(title)'s conversation is still running outside its Focus Queue pane, so Play did not start a second copy. Open its existing terminal."
      }
    }
  }

  private let store: TaskContextStore
  private let tmux: TmuxController

  public init(store: TaskContextStore, tmux: TmuxController = TmuxController()) {
    self.store = store
    self.tmux = tmux
  }

  /// Interrupts the agent's current turn, then records the pause.
  @discardableResult
  public func pause(ticketID: String, subtaskID: String) async throws -> TaskContext {
    let (agent, reference) = try await managedPane(ticketID: ticketID, subtaskID: subtaskID)
    guard !Self.showsStartupPrompt(try await tmux.screen(reference)) else {
      throw PauseError.startupPrompt(agent.title)
    }
    try await tmux.interrupt(reference)
    return try await store.setPaused(ticketID: ticketID, subtaskID: subtaskID, paused: true)
  }

  /// Sends the resume prompt into the same conversation, then clears the pause.
  @discardableResult
  public func resume(
    ticketID: String, subtaskID: String, prompt: String = AgentPauseController.resumePrompt
  ) async throws -> TaskContext {
    let (agent, reference) = try await managedPane(ticketID: ticketID, subtaskID: subtaskID)
    // Claude puts an interrupted prompt that had no reply back in its input
    // box, so the note may join that text; a blank line keeps them apart.
    let submitted = try await tmux.submitPrompt(
      "\n\n" + prompt, to: reference, ready: Self.inputIsReady(for: agent.provider), timeout: .seconds(15))
    guard submitted else { throw PauseError.inputNotReady(agent.title) }
    return try await store.setPaused(ticketID: ticketID, subtaskID: subtaskID, paused: false)
  }

  /// What `play` did: typed into the live pane, or reopened the closed one.
  public enum PlayOutcome: String, Sendable, Equatable {
    case sent
    case reopened
  }

  /// The word Play sends when the caller gives no text.
  public static let playPrompt = "continue"

  /// Play sends `prompt` to the agent's conversation. A live pane gets it
  /// typed in, like Resume. A closed tmux pane is reopened on the saved
  /// conversation with the prompt, unless the conversation still runs
  /// elsewhere (`isRunningElsewhere`), which would fork it.
  public func play(
    ticketID: String, subtaskID: String, prompt: String = AgentPauseController.playPrompt,
    supportDirectory: URL, tmuxExecutable: String,
    launcher: TaskAgentLauncher = TaskAgentLauncher(),
    usageBarEnabled: Bool = true, codexSupportsNoDaemon: Bool = true, bypassPermissions: Bool = false,
    isRunningElsewhere: @Sendable (AgentProvider, String) async throws -> Bool
  ) async throws -> (TaskContext, PlayOutcome) {
    let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let message = text.isEmpty ? Self.playPrompt : text
    do {
      // Check first: the paste loop retries a closed pane until its timeout.
      let (_, reference) = try await managedPane(ticketID: ticketID, subtaskID: subtaskID)
      _ = try await tmux.verify(reference)
      return (try await resume(ticketID: ticketID, subtaskID: subtaskID, prompt: message), .sent)
    } catch TmuxError.stopped {}
    guard let context = try await store.load(ticketID: ticketID),
          let agent = context.subtasks.first(where: { $0.id == subtaskID }) else {
      throw TaskContextError.missingSubtask(subtaskID)
    }
    guard let sessionID = agent.sessionID else {
      throw PauseError.noSavedConversation(agent.title)
    }
    let identity = agent.provider == .codex ? CodexSessionLineage.root(of: sessionID) : sessionID
    if try await isRunningElsewhere(agent.provider, identity) {
      throw PauseError.runningElsewhere(agent.title)
    }
    let runtime = try await launcher.startManagedSession(
      context: context, subtask: agent, supportDirectory: supportDirectory,
      tmuxExecutable: tmuxExecutable, usageBarEnabled: usageBarEnabled,
      codexSupportsNoDaemon: codexSupportsNoDaemon, bypassPermissions: bypassPermissions,
      resumePrompt: message)
    _ = try await store.setManagedRuntime(
      ticketID: ticketID, subtaskID: subtaskID, tmux: runtime, status: .working)
    if agent.provider == .kimi {
      let submitted = try await tmux.submitPrompt(
        message, to: runtime, ready: TaskAgentLauncher.kimiInputIsReady, timeout: .seconds(45))
      guard submitted else { throw PauseError.inputNotReady(agent.title) }
    }
    return (try await store.setPaused(ticketID: ticketID, subtaskID: subtaskID, paused: false), .reopened)
  }

  /// A new agent's folder-trust prompt treats Esc as "exit" in Claude and Kimi.
  static func showsStartupPrompt(_ screen: String) -> Bool {
    let text = screen.lowercased()
    return ["trust this folder", "do you trust", "trust the contents of this directory"]
      .contains { text.contains($0) }
  }

  /// Claude and Codex accept typed input mid-turn, so only Kimi's input box
  /// must be visible before a paste.
  static func inputIsReady(for provider: AgentProvider) -> @Sendable (String) -> Bool {
    switch provider {
    case .kimi: TaskAgentLauncher.kimiInputIsReady
    case .claude, .codex: { _ in true }
    }
  }

  private func managedPane(ticketID: String, subtaskID: String) async throws -> (TaskSubtask, TmuxSessionReference) {
    guard let context = try await store.load(ticketID: ticketID) else { throw TaskContextError.missingContext(ticketID) }
    guard let agent = context.subtasks.first(where: { $0.id == subtaskID }) else { throw TaskContextError.missingSubtask(subtaskID) }
    guard agent.status != .completed else { throw PauseError.completed(agent.title) }
    guard let reference = agent.tmux else { throw PauseError.noManagedPane(agent.title) }
    return (agent, reference)
  }
}
