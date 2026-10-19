import Foundation
import Testing
@testable import FocusQueueCore

@Suite("Per-launch provider plugins and launch presets")
struct ProviderPluginTests {
  @Test("Plugin overrides become provider flags and never touch saved settings")
  func pluginArguments() throws {
    #expect(AgentProvider.claude.pluginArguments(overrides: [:]).isEmpty)
    let claude = AgentProvider.claude.pluginArguments(overrides: ["swift-lsp@official": false, "ecc@ecc": true])
    #expect(claude.first == "--settings")
    let settings = try #require(
      JSONSerialization.jsonObject(with: Data(claude[1].utf8)) as? [String: [String: Bool]])
    #expect(settings == ["enabledPlugins": ["ecc@ecc": true, "swift-lsp@official": false]])
    #expect(AgentProvider.codex.pluginArguments(overrides: ["ecc@ecc": false, "b@m": true])
      == ["-c", "plugins.b@m.enabled=true", "-c", "plugins.ecc@ecc.enabled=false"])
    #expect(AgentProvider.codex.pluginArguments(overrides: ["a.b@m": true, "x y": true, "q\"@m": true]).isEmpty,
      "IDs a dotted -c path cannot address are dropped, not mangled")
    #expect(AgentProvider.kimi.pluginArguments(overrides: ["ecc@ecc": true]).isEmpty)
  }

  @Test("The catalog reads installs and saved enablement, ECC first")
  func catalog() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-home-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let claude = home.appendingPathComponent(".claude/plugins")
    try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
    try Data(#"{"version":2,"plugins":{"swift-lsp@official":[{}],"ecc@ecc":[{}],"zeta@m":[{}]}}"#.utf8)
      .write(to: claude.appendingPathComponent("installed_plugins.json"))
    try Data(#"{"enabledPlugins":{"swift-lsp@official":true,"ecc@ecc":false}}"#.utf8)
      .write(to: home.appendingPathComponent(".claude/settings.json"))
    #expect(ProviderPluginCatalog.installed(for: .claude, home: home) == [
      ProviderPlugin(id: "ecc@ecc", name: "ecc", enabled: false),
      ProviderPlugin(id: "swift-lsp@official", name: "swift-lsp", enabled: true),
      ProviderPlugin(id: "zeta@m", name: "zeta", enabled: false),
    ])

    try FileManager.default.createDirectory(
      at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
    try Data("""
      model = "gpt"
      [plugins."other@m"]
      source = "x"
      [plugins."ecc@ecc"]
      enabled = false # off for now
      [plugins."ecc@ecc".extra]
      enabled = true
      [hooks.state."ecc@ecc:hooks/codex-hooks.json:session_start:0:0"]
      enabled = true
      """.utf8).write(to: home.appendingPathComponent(".codex/config.toml"))
    #expect(ProviderPluginCatalog.installed(for: .codex, home: home) == [
      ProviderPlugin(id: "ecc@ecc", name: "ecc", enabled: false),
      ProviderPlugin(id: "other@m", name: "other", enabled: true),
    ])
    #expect(ProviderPluginCatalog.installed(for: .kimi, home: home).isEmpty)
    #expect(ProviderPluginCatalog.installed(for: .claude, home: home.appendingPathComponent("absent")).isEmpty)
  }

  @Test("App launches export their placement capsule and plugin flags")
  func launcherCommand() throws {
    let context = TaskContext(ticketID: "FOC-9", title: "Creator", summary: "", successCriteria: "",
      planPath: "/tmp/support/tasks/FOC-9/plan.md", worktreePath: "/tmp/work", updatedAt: Date())
    let launchID = "0d6c1ad4-6b7f-4cf4-9a49-2a9b0b0a8b11"
    var subtask = TaskSubtask(id: "agent", title: "Creator agent", provider: .claude, runtimeMode: .tmux)
    subtask.launchConfiguration = AgentLaunchConfiguration(
      model: "haiku", launchID: launchID, pluginOverrides: ["ecc@ecc": true])
    let command = try TaskAgentLauncher.command(
      context: context, subtask: subtask, supportDirectory: URL(fileURLWithPath: "/tmp/support"))
    #expect(command.contains("FOCUS_QUEUE_LAUNCH_ID=\(launchID)"))
    #expect(command.contains("FOCUS_QUEUE_AGENT_CONTEXT=/tmp/support/tracking/placements/\(launchID).json"))
    let settings = try #require(command.firstIndex(of: "--settings"))
    #expect(command[settings + 1] == #"{"enabledPlugins":{"ecc@ecc":true}}"#)

    subtask.launchConfiguration = AgentLaunchConfiguration(launchID: "not-a-uuid")
    let unsafe = try TaskAgentLauncher.command(
      context: context, subtask: subtask, supportDirectory: URL(fileURLWithPath: "/tmp/support"))
    #expect(!unsafe.contains { $0.hasPrefix("FOCUS_QUEUE_AGENT_CONTEXT=") })
  }

  @Test("The last launch preset round-trips and a malformed one never blocks local state")
  func launchPresetPersistence() throws {
    var state = LocalState(routineDate: "2026-10-19")
    state.lastAgentLaunch = AgentLaunchPreset(
      provider: .codex, model: "gpt-6-luna", effort: "low", workspacePolicy: .isolatedCleanCheckout,
      useTmux: false, includePrompt: true, pluginOverrides: ["ecc@ecc": false])
    let encoded = try JSONEncoder().encode(state)
    #expect(try JSONDecoder().decode(LocalState.self, from: encoded) == state)
    #expect(String(decoding: encoded, as: UTF8.self).contains(#""workspacePolicy":"isolated-clean""#))

    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object["lastAgentLaunch"] = ["provider": "future-provider"]
    let tolerant = try JSONDecoder().decode(
      LocalState.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(tolerant.lastAgentLaunch == nil)
    #expect(tolerant.routineDate == "2026-10-19")
    #expect(AgentWorkspacePolicy(rawValue: "isolated-snapshot") == .isolatedCommittedSnapshot)
  }
}
