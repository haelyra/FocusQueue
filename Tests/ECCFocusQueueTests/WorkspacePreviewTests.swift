import Foundation
import Testing
import FocusQueueCore
@testable import ECCFocusQueue

@Suite("Workspace preview cancellation") @MainActor
struct WorkspacePreviewTests {
  @Test("Changing paths cancels stale failures and only the latest workspace is displayed")
  func cancellation() async throws {
    let model = WorkspacePreviewModel()
    let first = Task {
      await model.load(path: "/old") { _ in
        try await Task.sleep(for: .seconds(10))
        throw CancellationError()
      }
    }
    try await Task.sleep(for: .milliseconds(180))
    first.cancel()
    await model.load(path: "/new") { path in AgentWorkspace(path: path, repositoryPath: path, branch: "current") }
    await first.value
    #expect(model.error == nil)
    #expect(model.workspace?.path == "/new")
    await model.load(path: "/bad") { _ in throw TaskContextError.unsafeWorktree("Missing workspace") }
    #expect(model.error == "Missing workspace")
    await model.load(path: "")
    #expect(model.error == nil)
    #expect(model.workspace == nil)
  }
}
