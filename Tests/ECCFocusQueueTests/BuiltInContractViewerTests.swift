import FocusQueueCore
import Foundation
import Testing

@testable import ECCFocusQueue

@Suite("Built-in contracts in the app")
@MainActor
struct BuiltInContractViewerTests {
  /// The repository's Config folder, which the app bundles as its resources.
  static let config = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Config", isDirectory: true)

  @Test("Launch writes every built-in contract, and Settings opens one in full in the document viewer")
  func launchWritesAndSettingsOpens() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("built-in-viewer \(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let model = QueueViewModel(paths: AppPaths.live(environment: ["FOCUS_QUEUE_SUPPORT_DIR": root.path]))
    model.builtInContractResources = Self.config
    await model.bootstrap()
    await model.bootstrapTail?.value

    for contract in BuiltInAgentContract.allCases {
      #expect(model.builtInContractAvailable(contract))
      #expect(FileManager.default.fileExists(atPath: contract.url(root: root).path))
    }

    model.openBuiltInContract(.orchestrator)
    #expect(model.isDocumentViewerPresented && model.documentViewerScope == nil)
    #expect(model.documentViewer.tabs.map(\.lastPathComponent) == ["orchestrator-rules.md"])
    model.openBuiltInContract(.claude)
    #expect(model.documentViewer.tabs.map(\.lastPathComponent) == ["orchestrator-rules.md", "claude-agent-contract.md"])
    #expect(model.builtInContractError == nil)

    // A development build has no bundled payloads: the button is disabled and
    // an attempt explains why instead of opening a stale copy.
    model.builtInContractResources = nil
    #expect(!model.builtInContractAvailable(.kimi) && model.builtInContractAvailable(.orchestrator))
    model.openBuiltInContract(.kimi)
    #expect(model.builtInContractError?.contains("Kimi") == true)
    #expect(!model.documentViewer.tabs.map(\.lastPathComponent).contains("kimi-agent-contract.md"))
  }
}
