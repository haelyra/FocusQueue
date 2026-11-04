import Foundation
import FocusQueueCore
import Testing
@testable import ECCFocusQueue

@Suite("First-run walkthrough")
@MainActor
struct WalkthroughTests {
  private func freshModel(
    accounts: @escaping @Sendable (AgentProvider) async -> ProviderAccountState = { _ in .signedIn }
  ) async -> (QueueViewModel, AppPaths, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("walkthrough \(UUID().uuidString)")
    let paths = AppPaths.live(environment: ["FOCUS_QUEUE_SUPPORT_DIR": root.path])
    let model = QueueViewModel(paths: paths, checkProviderAccount: accounts)
    await model.bootstrap()
    await model.bootstrapTail?.value
    return (model, paths, root)
  }

  @Test("Skipping ends the tour for good and completes first-run setup")
  func skipPersists() async throws {
    let (model, paths, root) = await freshModel()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(model.walkthrough != nil)
    model.finishWalkthrough()
    #expect(model.walkthrough == nil)
    #expect(model.localState.walkthroughCompletedAt != nil)
    #expect(model.config.setupCompleted == true)
    // Saves are debounced; poll briefly for the persisted files.
    var restarted: QueueViewModel?
    for _ in 0..<40 {
      try await Task.sleep(for: .milliseconds(100))
      let config = try? JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: paths.configurationFile))
      if config?.setupCompleted == true { break }
    }
    restarted = QueueViewModel(paths: paths, checkProviderAccount: { _ in .signedIn })
    await restarted?.bootstrap()
    await restarted?.bootstrapTail?.value
    #expect(restarted?.walkthrough == nil)
    #expect(restarted?.isSetupPresented == false)
  }

  @Test("With no provider signed in, finishing the tour leaves the queue gated until one signs in")
  func signInGate() async throws {
    let signedIn = SignedInProviders()
    let (model, _, root) = await freshModel(accounts: { provider in
      await signedIn.contains(provider) ? .signedIn : .signedOut
    })
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(!model.requiresProviderSignIn, "The tour shows its own sign-in step")
    model.finishWalkthrough()
    for _ in 0..<40 where !model.requiresProviderSignIn { try await Task.sleep(for: .milliseconds(50)) }
    #expect(model.requiresProviderSignIn)
    model.requestNewTask()
    #expect(model.newTaskRequest == nil)

    await signedIn.insert(.codex)
    await model.refreshProviderAccounts()
    #expect(!model.requiresProviderSignIn)
    model.requestNewTask()
    #expect(model.newTaskRequest != nil)
  }

  @Test("A check that cannot run lets the user continue past the gate")
  func unverifiedGate() async throws {
    let (model, _, root) = await freshModel(accounts: { $0 == .claude ? .failed("timed out") : .notInstalled })
    defer { try? FileManager.default.removeItem(at: root) }
    model.finishWalkthrough()
    for _ in 0..<40 where !model.requiresProviderSignIn { try await Task.sleep(for: .milliseconds(50)) }
    #expect(model.requiresProviderSignIn)
    model.continueWithoutVerifiedSignIn()
    #expect(!model.requiresProviderSignIn)
  }

  @Test("Back and Next walk every step, and Next on the last step finishes")
  func navigation() async throws {
    let (model, _, root) = await freshModel()
    defer { try? FileManager.default.removeItem(at: root) }
    model.retreatWalkthrough()
    #expect(model.walkthrough?.step == .welcome)
    model.advanceWalkthrough()
    #expect(model.walkthrough?.step == .terminal)
    model.retreatWalkthrough()
    #expect(model.walkthrough?.step == .welcome)
    for _ in 1..<WalkthroughStep.allCases.count { model.advanceWalkthrough() }
    #expect(model.walkthrough?.step == .help)
    model.advanceWalkthrough()
    #expect(model.walkthrough == nil)
    #expect(model.localState.walkthroughCompletedAt != nil)
  }

  @Test("The minimize step advances once the panel comes back")
  func minimizeGoal() async throws {
    let (model, _, root) = await freshModel()
    defer { try? FileManager.default.removeItem(at: root) }
    while model.walkthrough?.step != .minimize { model.advanceWalkthrough() }
    model.checkWalkthroughGoal()
    #expect(model.walkthrough?.step == .minimize)
    model.setPanelMode(.collapsed)
    model.checkWalkthroughGoal()
    #expect(model.walkthrough?.step == .minimize)
    model.setPanelMode(.expanded)
    model.checkWalkthroughGoal()
    #expect(model.walkthrough?.step == .rightClick)
  }

  @Test("Choosing a terminal stores it for managed agent windows")
  func terminalChoice() async throws {
    let (model, _, root) = await freshModel()
    defer { try? FileManager.default.removeItem(at: root) }
    model.setManagedTerminal(.ghostty)
    #expect(model.config.wezTerm.applicationName == "Ghostty")
    #expect(model.config.wezTerm.terminalApp == .ghostty)
    model.setManagedTerminal(.terminal)
    #expect(model.config.wezTerm.terminalApp.requiresTmux)
  }

  @Test("Replay restarts the tour at the welcome card")
  func replay() async throws {
    let (model, _, root) = await freshModel()
    defer { try? FileManager.default.removeItem(at: root) }
    model.finishWalkthrough()
    model.setPanelMode(.collapsed)
    model.startWalkthrough()
    #expect(model.walkthrough?.step == .welcome)
    #expect(model.panelMode == .expanded)
  }
}

private actor SignedInProviders {
  private var providers: Set<AgentProvider> = []
  func contains(_ provider: AgentProvider) -> Bool { providers.contains(provider) }
  func insert(_ provider: AgentProvider) { providers.insert(provider) }
}
