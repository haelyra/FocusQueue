import FocusQueueCore
import SwiftUI

/// Live capacity feed for the queue panel and the task creator. Samples the
/// machine every two seconds, reloads the 5-hour token total every minute,
/// and cycles one recommendation tip every other sample.
@MainActor
@Observable
final class QueueCapacityModel {
  private(set) var snapshot: SystemCapacitySnapshot?
  private(set) var trend: CapacityTrend = .steady
  private(set) var advice: LaunchAdvice?
  private(set) var tipIndex = 0

  @ObservationIgnored private let monitor = SystemCapacityMonitor()
  @ObservationIgnored private let supportDirectory: URL
  @ObservationIgnored private let liveAgentCount: @MainActor () -> Int
  @ObservationIgnored private var sampleTask: Task<Void, Never>?
  @ObservationIgnored private var tokensLast5Hours = 0
  @ObservationIgnored private var samplesSinceTokenLoad = Int.max

  init(supportDirectory: URL, liveAgentCount: @escaping @MainActor () -> Int) {
    self.supportDirectory = supportDirectory
    self.liveAgentCount = liveAgentCount
  }

  var currentTip: String? {
    guard let tips = advice?.tips, !tips.isEmpty else { return nil }
    return tips[tipIndex % tips.count]
  }

  func start() {
    guard sampleTask == nil else { return }
    sampleTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        self.sample()
        try? await Task.sleep(for: .seconds(2))
      }
    }
  }

  func stop() {
    sampleTask?.cancel()
    sampleTask = nil
  }

  private func sample() {
    samplesSinceTokenLoad += 1
    if samplesSinceTokenLoad >= 30 {
      samplesSinceTokenLoad = 0
      let directory = supportDirectory
      Task.detached(priority: .utility) { [weak self] in
        let tokens = QueueCapacityModel.tokensUsed(lastHours: 5, supportDirectory: directory)
        await self?.acceptTokens(tokens)
      }
    }
    let reading = monitor.sample(liveAgentCount: liveAgentCount(), tokensLast5Hours: tokensLast5Hours)
    snapshot = reading
    trend = monitor.trend
    advice = LaunchAdvisor.advise(snapshot: reading, trend: monitor.trend)
    // Two-second samples make a tip change land about every four seconds.
    tipIndex += 1
  }

  private func acceptTokens(_ tokens: Int) {
    tokensLast5Hours = tokens
  }

  /// Reported tokens when available, the character estimate otherwise.
  nonisolated static func tokensUsed(lastHours hours: Int, supportDirectory: URL, now: Date = Date()) -> Int {
    let cutoff = now.addingTimeInterval(-TimeInterval(hours) * 3_600)
    return PromptUsageMetrics.load(in: supportDirectory)
      .filter { $0.timestamp >= cutoff }
      .reduce(0) { $0 + ($1.reportedTotalTokens ?? $1.estimatedInputTokens) }
  }
}

/// The compact hardware and budget readout. Sits above the queue's new-task
/// row and at the top of the task creator; advisory only, it never blocks a
/// launch.
struct CapacityPanelView: View {
  let capacity: QueueCapacityModel
  var scheduledCount: Int = 0

  private func barColor(_ fraction: Double) -> Color {
    if fraction >= 0.90 { return .red }
    if fraction >= 0.75 { return .orange }
    return .green
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let snapshot = capacity.snapshot, let advice = capacity.advice {
        HStack(spacing: 6) {
          Circle()
            .fill(readinessColor(advice.readiness))
            .frame(width: 7, height: 7)
          Text(advice.readiness.headline)
            .font(.system(size: 11, weight: .semibold))
          if scheduledCount > 0 {
            Text("· \(scheduledCount) scheduled")
              .font(.system(size: 10, weight: .medium))
              .foregroundStyle(.secondary)
          }
          Spacer()
          trendLabel
        }
        HStack(spacing: 12) {
          meter("CPU", fraction: snapshot.cpuUsedFraction,
                detail: "\(Int((snapshot.cpuUsedFraction * 100).rounded()))% · \(snapshot.cpuCoreCount) cores")
          meter("Memory", fraction: snapshot.memoryUsedFraction,
                detail: "\(LaunchAdvisor.gigabytes(snapshot.memoryUsedBytes))/\(LaunchAdvisor.gigabytes(snapshot.memoryTotalBytes)) GB")
        }
        HStack(spacing: 10) {
          if snapshot.tokensLast5Hours > 0 {
            Label("~\(LaunchAdvisor.compactTokens(snapshot.tokensLast5Hours)) tokens · 5h", systemImage: "bolt.fill")
          }
          if snapshot.liveAgentCount > 0 {
            Label("\(snapshot.liveAgentCount) live", systemImage: "person.fill")
          }
          if snapshot.swapUsedBytes > 0 {
            Label("swap \(LaunchAdvisor.gigabytes(snapshot.swapUsedBytes)) GB", systemImage: "arrow.triangle.swap")
          }
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
        if let tip = capacity.currentTip {
          Text(tip)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .id(tip)
            .transition(.opacity)
        }
      } else {
        HStack(spacing: 6) {
          ProgressView().controlSize(.small)
          Text("Reading machine load…").font(.system(size: 11)).foregroundStyle(.secondary)
        }
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
    .animation(.easeInOut(duration: 0.3), value: capacity.tipIndex)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Machine capacity estimate")
  }

  @ViewBuilder private var trendLabel: some View {
    let (symbol, text) = trendPresentation
    Label(text, systemImage: symbol)
      .font(.system(size: 10, weight: .medium))
      .foregroundStyle(.secondary)
      .labelStyle(.titleAndIcon)
  }

  private var trendPresentation: (String, String) {
    switch capacity.trend {
    case .rising: ("arrow.up.right", "Load rising")
    case .steady: ("arrow.right", "Steady")
    case .easing: ("arrow.down.right", "Easing")
    }
  }

  private func readinessColor(_ readiness: LaunchReadiness) -> Color {
    switch readiness {
    case .comfortable: .green
    case .cautious: .orange
    case .strained: .red
    }
  }

  private func meter(_ label: String, fraction: Double, detail: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack {
        Text(label).font(.system(size: 10, weight: .semibold))
        Spacer()
        Text(detail).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
      }
      GeometryReader { geometry in
        ZStack(alignment: .leading) {
          RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.08))
          RoundedRectangle(cornerRadius: 3)
            .fill(barColor(fraction))
            .frame(width: max(3, geometry.size.width * min(1, fraction)))
        }
      }
      .frame(height: 6)
    }
    .frame(maxWidth: .infinity)
  }
}
