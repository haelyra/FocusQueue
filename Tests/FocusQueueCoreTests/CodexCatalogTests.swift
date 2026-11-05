import Foundation
import Testing

@testable import FocusQueueCore

private actor CatalogRunner: ProcessRunning {
  private(set) var limit: Int?
  func run(_ specification: ProcessSpecification) -> ProcessResult {
    limit = specification.maximumOutputBytes
    return ProcessResult(exitCode: 1, standardOutput: "", standardError: "", timedOut: false)
  }
}

@Suite("Codex catalog")
struct CodexCatalogTests {
  private static let models = #"""
    {"models":[{"slug":"gpt-6.1-sol","visibility":"list"},{"slug":"gpt-6-luna","visibility":"list"},
    {"slug":"gpt-reserve","visibility":"hide"}]}
    """#

  private func output(_ models: String, help: String = "Usage: codex [OPTIONS]\n      --no-daemon\n") -> String {
    "welcome from a shell profile\n" + models + "\n" + CodexCatalog.helpMarker + "\n" + help
  }

  @Test("Reads listed models past shell noise and skips hidden ones")
  func parsesListedModels() throws {
    let catalog = try #require(CodexCatalog.parse(output(Self.models)))
    #expect(catalog.models == ["gpt-6.1-sol", "gpt-6-luna"])
    #expect(catalog.supportsNoDaemon)
  }

  @Test("A CLI whose help has no --no-daemon must not be sent the flag")
  func olderCLI() throws {
    let catalog = try #require(CodexCatalog.parse(output(Self.models, help: "Usage: codex [OPTIONS]\n")))
    #expect(!catalog.supportsNoDaemon)
  }

  @Test("An unreadable model list keeps every model, and no help output proves nothing")
  func unreadableOutput() throws {
    let catalog = try #require(CodexCatalog.parse(output("error: unknown subcommand")))
    #expect(catalog.models.isEmpty)
    #expect(catalog.offers("gpt-6-luna"))
    #expect(CodexCatalog.parse("no marker at all") == nil)
    #expect(CodexCatalog.parse(CodexCatalog.helpMarker + "\nnot help") == nil)
  }

  @Test("A built-in model this account lacks is hidden; a hand-added model is not")
  func hidesOnlyMissingBuiltIns() {
    let catalog = CodexCatalog(models: ["gpt-6.1-sol", "gpt-6.1-terra"])
    #expect(!catalog.offers("gpt-6-luna"))
    #expect(catalog.offers("gpt-6.1-sol"))
    #expect(catalog.offers("my-own-model"))
    let picked = catalog.choices(from: [
      AgentModelChoice(provider: .codex, label: "gpt-6.1-sol", model: "gpt-6.1-sol"),
      AgentModelChoice(provider: .codex, label: "gpt-6-luna", model: "gpt-6-luna"),
      AgentModelChoice(provider: .codex, label: "Mine", model: "my-own-model"),
    ])
    #expect(picked.compactMap(\.model) == ["gpt-6.1-sol", "my-own-model", "gpt-6.1-terra"])
  }

  @Test("The read keeps the whole catalog, which outgrows the default output limit")
  func readsFullCatalog() async {
    let runner = CatalogRunner()
    _ = await CodexCatalog.load(runner: runner, shell: "/bin/zsh")
    #expect(await runner.limit ?? 0 >= 2_000_000, "The real catalog is about 650 KB and the runner keeps its tail")
  }

  @Test("The harness marker names the refused model")
  func refusedModel() {
    #expect(CodexCatalog.unavailableModel(in: "pong\n\nfocus-queue-model-unavailable: gpt-6-luna\n") == "gpt-6-luna")
    #expect(CodexCatalog.unavailableModel(in: "pong") == nil)
  }
}
