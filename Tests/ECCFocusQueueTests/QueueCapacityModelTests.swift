import Foundation
import Testing

@testable import ECCFocusQueue

@Suite("Queue capacity model")
@MainActor
struct QueueCapacityModelTests {
  private func makeModel() -> QueueCapacityModel {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("QueueCapacityModelTests-\(UUID().uuidString)", isDirectory: true)
    return QueueCapacityModel(supportDirectory: directory, liveAgentCount: { 2 })
  }

  @Test("The first sample succeeds instead of overflowing the reload counter")
  func firstSampleDoesNotOverflow() {
    let model = makeModel()
    model.sample()
    #expect(model.snapshot != nil)
    #expect(model.advice != nil)
    #expect(model.samplesSinceTokenLoad == 1)
  }

  @Test("The token reload counter stays bounded and reloads once per window")
  func reloadCounterStaysBounded() {
    let model = makeModel()
    let window = QueueCapacityModel.samplesPerTokenReload
    // Reloads land on samples 1, window + 1, and 2 * window + 1.
    for _ in 0..<(2 * window + 5) {
      model.sample()
      #expect((1...window).contains(model.samplesSinceTokenLoad))
    }
    #expect(model.samplesSinceTokenLoad == 5)
  }
}
