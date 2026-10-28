import Foundation
import FocusQueueCore
import Testing
@testable import ECCFocusQueue

@Suite("First-run setup")
@MainActor
struct SetupWizardTests {
  @Test("An empty account boots into a working queue and setup remains pending across restart")
  func firstRun() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("first-run \(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths.live(environment: ["FOCUS_QUEUE_SUPPORT_DIR": root.path])
    let model = QueueViewModel(paths: paths)
    await model.bootstrap()
    await model.bootstrapTail?.value
    #expect(model.configurationIsLoaded)
    #expect(model.isSetupPresented)
    #expect(model.loadError == nil)
    #expect(model.dashboard.tickets.isEmpty)
    #expect(!model.config.verifier.enabled)
    model.isSetupPresented = false
    let restarted = QueueViewModel(paths: paths)
    await restarted.bootstrap()
    await restarted.bootstrapTail?.value
    #expect(restarted.isSetupPresented)
    #expect(!FileManager.default.fileExists(atPath: paths.ingestionConfigurationFile.path))
    #expect(await restarted.finishSetup(restarted.config))
    // Finishing setup leaves a starter source file for connector diagnostics.
    let ingestion = try #require(JSONSerialization.jsonObject(
      with: Data(contentsOf: paths.ingestionConfigurationFile)) as? [String: Any])
    #expect(ingestion["dashboardPath"] as? String == restarted.config.dashboardPath)
    #expect(!restarted.isSetupPresented)
    let saved = try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: paths.configurationFile))
    #expect(saved.setupCompleted == true)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("backups").path).count == 1)
  }

  @Test("Invalid setup preserves the last usable configuration")
  func invalidConfiguration() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("invalid-setup \(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths.live(environment: ["FOCUS_QUEUE_SUPPORT_DIR": root.path])
    let model = QueueViewModel(paths: paths)
    await model.bootstrap()
    await model.bootstrapTail?.value
    let original = try Data(contentsOf: paths.configurationFile)
    var draft = model.config
    draft.dashboardPath = root.appendingPathComponent("missing/dashboard.json").path
    #expect(await model.finishSetup(draft) == false)
    #expect(!FileManager.default.fileExists(atPath: paths.ingestionConfigurationFile.path))
    #expect(model.setupError != nil)
    #expect(try Data(contentsOf: paths.configurationFile) == original)
  }
}
