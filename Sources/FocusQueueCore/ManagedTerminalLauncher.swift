import Foundation

/// Opens a new desktop terminal view for one already verified tmux pane.
///
/// Managed recall intentionally does not discover or reuse a GUI pane. The
/// durable identity is tmux's server/session/pane tuple, so every button press
/// performs the same operation a user would: open a terminal and attach to the
/// exact pane.
enum ManagedTerminalLauncher {
  static func open(
    reference: TmuxSessionReference,
    configuration: WezTermConfiguration,
    runner: any ProcessRunning
  ) async throws -> TerminalActionResult {
    let attach = try TmuxController.attachCommand(reference: reference)
    do {
      try await TerminalCommandLauncher.open(attach, configuration: configuration, runner: runner)
    } catch WezTermError.actionFailed(let detail) {
      throw WezTermError.actionFailed("The managed agent is still running, but \(detail)")
    }
    return .spawned(paneID: nil)
  }
}
