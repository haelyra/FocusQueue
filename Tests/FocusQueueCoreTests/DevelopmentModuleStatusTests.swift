import Foundation
import Testing
@testable import FocusQueueCore

@Suite("Reversible module lifecycle")
struct DevelopmentModuleStatusTests {
  @Test("Every lifecycle selection survives reload and reconciliation, including undo")
  func lifecyclePersistence() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DevelopmentProcessStore(root: root)
    _ = try store.setEnabled(true, projectID: "sample")
    var process = try store.addModule(name: "Search", file: nil, projectID: "sample")
    let id = try #require(process.modules.first?.id)
    _ = try store.link(taskID: "SAM-1", step: "build", module: id, projectID: "sample")
    for status in DevelopmentModuleStatus.allCases + DevelopmentModuleStatus.allCases.reversed() {
      _ = try store.setModuleStatus(status, moduleID: id, projectID: "sample")
      process = try #require(try store.load(projectID: "sample"))
      for isOpen in [true, false] {
        _ = process.reconcile(tickets: [.init(id: "SAM-1", title: "Build search", status: isOpen ? "in-progress" : "resolved", isOpen: isOpen)])
        let module = try #require(process.modules.first)
        #expect(DevelopmentModuleStatus(of: module, hasOpenLinkedWork: isOpen) == status)
        if status == .planned || status == .inProgress {
          #expect(!module.implemented && !module.qaAccepted && !module.criteriaAccepted)
        }
      }
    }
  }

  @Test("Criteria review never fabricates implementation or human QA and keeps sequential gates")
  func criteriaIsIndependent() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DevelopmentProcessStore(root: root)
    _ = try store.setEnabled(true, projectID: "sample")
    _ = try store.addModule(name: "Search", file: nil, projectID: "sample")
    var process = try store.addModule(name: "Sync", file: nil, projectID: "sample")
    let first = process.modules[0].id, second = process.modules[1].id
    _ = try store.setModuleReviewOrder(.sequential, projectID: "sample")
    #expect(throws: DevelopmentProcessError.self) {
      try store.setModuleStatus(.criteriaAccepted, moduleID: second, projectID: "sample")
    }
    process = try store.setModuleStatus(.criteriaAccepted, moduleID: first, projectID: "sample")
    #expect(process.modules[0].criteriaAccepted)
    #expect(!process.modules[0].implemented && !process.modules[0].qaAccepted)
    _ = try store.setModuleStatus(.criteriaAccepted, moduleID: second, projectID: "sample")
    // Undo is allowed even when later modules already have acceptance.
    process = try store.setModuleStatus(.planned, moduleID: first, projectID: "sample")
    #expect(!process.modules[0].criteriaAccepted && process.modules[1].criteriaAccepted)
    #expect(throws: DevelopmentProcessError.self) {
      try store.setModuleStatus(.planned, moduleID: "missing", projectID: "sample")
    }
  }

  @Test("Legacy modules retain automatic completion and older payloads decode")
  func legacyAutomaticProgress() throws {
    let json = #"{"id":"search","name":"Search","criteriaAccepted":false,"implemented":false,"qaAccepted":false}"#
    let module = try JSONDecoder().decode(DevelopmentModule.self, from: Data(json.utf8))
    #expect(module.selectedStatus == nil)
    #expect(DevelopmentModuleStatus(of: module, hasOpenLinkedWork: true) == .inProgress)
    var process = DevelopmentProcess(modules: [module], links: ["SAM-1": .init(phase: .implementation, step: "build", moduleID: "search", source: .human)])
    let changed = process.reconcile(tickets: [.init(id: "SAM-1", title: "Build", status: "resolved", isOpen: false)])
    #expect(changed)
    #expect(process.modules[0].implemented && !process.modules[0].qaAccepted && !process.modules[0].criteriaAccepted)
    #expect(DevelopmentPhase.implementation.title == "Modules")
    #expect(DevelopmentPhase.implementation.rawValue == "implementation")
  }
}
