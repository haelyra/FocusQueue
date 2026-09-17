import Foundation
import Observation
import FocusQueueCore

@MainActor @Observable
final class WorkspacePreviewModel {
  private(set) var workspace: AgentWorkspace?
  private(set) var hasUncommittedChanges: Bool?
  private(set) var isLoading = false
  private(set) var error: String?
  private(set) var inspectedPath: String?
  private var requestID = UUID()

  func launchBlockReason(path: String, createWorktree: Bool) -> String? {
    launchBlockReason(path: path, policy: createWorktree ? .isolatedCleanCheckout : .existingCheckout)
  }

  func launchBlockReason(path: String, policy: AgentWorkspacePolicy) -> String? {
    guard !path.isEmpty else { return "Choose a workspace to start an agent." }
    guard inspectedPath == path else { return "Checking the selected workspace…" }
    if let error { return error }
    guard workspace?.path == path, let hasUncommittedChanges, !isLoading else {
      return "Checking the selected workspace…"
    }
    if policy == .isolatedCleanCheckout && hasUncommittedChanges {
      return "This checkout has uncommitted changes. Use this checkout, or choose a repository checkout for the new worktree."
    }
    return nil
  }

  func load(path: String,
    changesLookup: @Sendable (String) async throws -> Bool = {
      try await TaskWorktreeManager().hasUncommittedChanges(at: $0)
    },
    lookup: @Sendable (String) async throws -> AgentWorkspace = {
      try await TaskWorktreeManager().workspace(at: $0)
    }
  ) async {
    let id = UUID()
    requestID = id
    inspectedPath = path
    workspace = nil
    hasUncommittedChanges = nil
    isLoading = !path.isEmpty
    error = nil
    defer { if requestID == id { isLoading = false } }
    guard !path.isEmpty else { return }
    do {
      try await Task.sleep(for: .milliseconds(150))
      let result = try await lookup(path)
      let hasChanges = try await changesLookup(path)
      guard !Task.isCancelled, requestID == id else { return }
      workspace = result
      hasUncommittedChanges = hasChanges
    } catch is CancellationError {
      // SwiftUI cancels this lookup whenever the path changes or the sheet closes.
    } catch {
      guard !Task.isCancelled, requestID == id else { return }
      self.error = error.localizedDescription
    }
  }
}
