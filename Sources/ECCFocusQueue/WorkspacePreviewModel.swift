import Foundation
import Observation
import FocusQueueCore

@MainActor @Observable
final class WorkspacePreviewModel {
  private(set) var workspace: AgentWorkspace?
  private(set) var error: String?
  private var requestID = UUID()

  func load(path: String, lookup: @Sendable (String) async throws -> AgentWorkspace = {
    try await TaskWorktreeManager().workspace(at: $0)
  }) async {
    let id = UUID()
    requestID = id
    workspace = nil
    error = nil
    guard !path.isEmpty else { return }
    do {
      try await Task.sleep(for: .milliseconds(150))
      let result = try await lookup(path)
      guard !Task.isCancelled, requestID == id else { return }
      workspace = result
    } catch is CancellationError {
      // SwiftUI cancels this lookup whenever the path changes or the sheet closes.
    } catch {
      guard !Task.isCancelled, requestID == id else { return }
      self.error = error.localizedDescription
    }
  }
}
