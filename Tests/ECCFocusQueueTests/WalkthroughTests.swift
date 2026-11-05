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

  private func model(
    wezTermInstalled: Bool = true, catalog: CodexCatalog? = nil
  ) async throws -> (QueueViewModel, AppPaths, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("terminal \(UUID().uuidString)")
    let paths = AppPaths.live(environment: ["FOCUS_QUEUE_SUPPORT_DIR": root.path])
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    // Older installs saved WezTerm as the default terminal.
    var saved = SetupEnvironment.starter(supportDirectory: root)
    saved.wezTerm = .init(executable: "/nonexistent/wezterm", applicationName: "WezTerm")
    try SetupEnvironment.createStarterWorkspace(supportDirectory: root)
    try JSONEncoder().encode(saved).write(to: paths.configurationFile)
    let model = QueueViewModel(paths: paths, checkProviderAccount: { _ in .signedIn },
      loadCodexCatalog: { catalog }, isWezTermInstalled: { _ in wezTermInstalled })
    await model.bootstrap()
    await model.bootstrapTail?.value
    return (model, paths, root)
  }

  @Test("A saved WezTerm choice moves to macOS Terminal on a Mac without WezTerm, and stays moved")
  func missingWezTermMigrates() async throws {
    let (model, paths, root) = try await model(wezTermInstalled: false)
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(model.config.wezTerm.terminalApp == .terminal)
    var saved: AppConfiguration?
    for _ in 0..<40 {
      try await Task.sleep(for: .milliseconds(100))
      saved = try? JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: paths.configurationFile))
      if saved?.wezTerm.terminalApp == .terminal { break }
    }
    #expect(saved?.wezTerm.terminalApp == .terminal)
  }

  @Test("WezTerm stays selected when it is installed")
  func installedWezTermStays() async throws {
    let (model, _, root) = try await model(wezTermInstalled: true)
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(model.config.wezTerm.terminalApp == .wezTerm)
  }

  @Test("A saved model this Codex account lacks is hidden and is not sent")
  func unavailableModelFallsBack() async throws {
    let (model, _, root) = try await model(catalog: CodexCatalog(models: ["gpt-5.6-sol"]))
    defer { try? FileManager.default.removeItem(at: root) }
    model.setChatModel("gpt-6-luna", for: .codex)
    await model.refreshProviderAccounts()
    #expect(model.config.chatModels[.codex] == "gpt-6-luna", "The saved choice returns if the CLI is updated")
    #expect(model.effectiveChatModel(for: .codex) == nil)
    #expect(!model.agentModelChoices(for: .codex).contains { $0.model == "gpt-6-luna" })
    #expect(model.defaultAgentModel(for: .codex) == nil, "The standard model is not on this account either")
    model.setChatModel("gpt-5.6-sol", for: .codex)
    #expect(model.effectiveChatModel(for: .codex) == "gpt-5.6-sol")
  }

  @Test("A model Codex refuses mid-run leaves the picker")
  func refusedModelIsHidden() async throws {
    let (model, _, root) = try await model()
    defer { try? FileManager.default.removeItem(at: root) }
    model.setChatModel("gpt-6-luna", for: .codex)
    #expect(model.effectiveChatModel(for: .codex) == "gpt-6-luna")
    model.unavailableCodexModels.insert("gpt-6-luna")
    #expect(model.effectiveChatModel(for: .codex) == nil)
    #expect(!model.agentModelChoices(for: .codex).contains { $0.model == "gpt-6-luna" })
    #expect(model.agentModelChoices(for: .claude).isEmpty == false)
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

  private func signOutModel(
    accounts: @escaping @Sendable (AgentProvider) async -> ProviderAccountState,
    signOut: @escaping @Sendable (AgentProvider) async -> String?
  ) async -> (QueueViewModel, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sign out \(UUID().uuidString)")
    let model = QueueViewModel(paths: AppPaths.live(environment: ["FOCUS_QUEUE_SUPPORT_DIR": root.path]),
                               checkProviderAccount: accounts, signOutProviderAccount: signOut)
    await model.bootstrap()
    await model.bootstrapTail?.value
    return (model, root)
  }

  @Test("Signing out updates the card from a fresh status check")
  func signOutSucceeds() async {
    let signedIn = SignedInProviders()
    await signedIn.insert(.codex)
    let (model, root) = await signOutModel(
      accounts: { await signedIn.contains($0) ? .signedIn : .signedOut },
      signOut: { await signedIn.remove($0); return nil })
    defer { try? FileManager.default.removeItem(at: root) }
    await model.refreshProviderAccounts()
    #expect(model.providerAccounts[.codex] == .signedIn)
    await model.signOut(from: .codex)
    #expect(model.providerAccounts[.codex] == .signedOut)
    #expect(model.walkthroughMessage == "Signed out of Codex.")
    #expect(model.providersSigningOut.isEmpty)
  }

  @Test("A sign-out that leaves the account signed in is reported, even when the CLI exited cleanly")
  func signOutFails() async {
    let (model, root) = await signOutModel(accounts: { _ in .signedIn }, signOut: { _ in "keychain locked (exit 1)" })
    defer { try? FileManager.default.removeItem(at: root) }
    await model.signOut(from: .claude)
    #expect(model.providerAccounts[.claude] == .signedIn)
    #expect(model.walkthroughMessage == "Could not sign out of Claude: keychain locked (exit 1)")
    let (silent, silentRoot) = await signOutModel(accounts: { _ in .signedIn }, signOut: { _ in nil })
    defer { try? FileManager.default.removeItem(at: silentRoot) }
    await silent.signOut(from: .kimi)
    #expect(silent.walkthroughMessage == "Could not sign out of Kimi.")
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
  func remove(_ provider: AgentProvider) { providers.remove(provider) }
}
