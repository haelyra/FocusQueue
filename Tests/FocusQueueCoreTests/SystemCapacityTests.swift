import Foundation
import Testing
@testable import FocusQueueCore

@Suite("System capacity advisor")
struct SystemCapacityTests {
    private func snapshot(
        cpu: Double, memory: Double, cores: Int = 12, totalGB: UInt64 = 24,
        swapGB: UInt64 = 0, agents: Int = 2, tokens: Int = 100_000
    ) -> SystemCapacitySnapshot {
        let total = totalGB * 1_000_000_000
        return SystemCapacitySnapshot(
            cpuUsedFraction: cpu, cpuCoreCount: cores,
            memoryUsedFraction: memory, memoryUsedBytes: UInt64(memory * Double(total)),
            memoryTotalBytes: total, swapUsedBytes: swapGB * 1_000_000_000,
            liveAgentCount: agents, tokensLast5Hours: tokens)
    }

    @Test("CPU and memory fractions clamp to 0...1")
    func fractionClamping() {
        #expect(SystemCapacitySampler.cpuFraction(busyDelta: 0, totalDelta: 0) == 0)
        #expect(SystemCapacitySampler.cpuFraction(busyDelta: 50, totalDelta: 100) == 0.5)
        #expect(SystemCapacitySampler.cpuFraction(busyDelta: 150, totalDelta: 100) == 1)
        #expect(SystemCapacitySampler.memoryFraction(usedBytes: 5, totalBytes: 0) == 0)
        #expect(SystemCapacitySampler.memoryFraction(usedBytes: 15, totalBytes: 10) == 1)
    }

    @Test("Readiness thresholds follow CPU, memory, and swap pressure")
    func readinessThresholds() {
        #expect(LaunchAdvisor.readiness(snapshot: snapshot(cpu: 0.30, memory: 0.50)) == .comfortable)
        #expect(LaunchAdvisor.readiness(snapshot: snapshot(cpu: 0.75, memory: 0.50)) == .cautious)
        #expect(LaunchAdvisor.readiness(snapshot: snapshot(cpu: 0.30, memory: 0.80)) == .cautious)
        #expect(LaunchAdvisor.readiness(snapshot: snapshot(cpu: 0.95, memory: 0.50)) == .strained)
        #expect(LaunchAdvisor.readiness(snapshot: snapshot(cpu: 0.30, memory: 0.92)) == .strained)
        // High memory alone is cautious; heavy swap on top of it is strained.
        #expect(LaunchAdvisor.readiness(snapshot: snapshot(cpu: 0.30, memory: 0.85)) == .cautious)
        #expect(LaunchAdvisor.readiness(snapshot: snapshot(cpu: 0.30, memory: 0.85, swapGB: 6)) == .strained)
    }

    @Test("Agent budget shrinks as CPU and memory fill")
    func agentBudget() {
        // 12 idle cores / 2 per agent = 6; 24 idle GB / 1.5 GB per agent = 16; CPU wins.
        #expect(LaunchAdvisor.agentBudget(snapshot: snapshot(cpu: 0.0, memory: 0.0)) == 6)
        // 50% memory used leaves 12 GB / 1.5 GB = 8; still capped by the 6 from CPU.
        #expect(LaunchAdvisor.agentBudget(snapshot: snapshot(cpu: 0.0, memory: 0.50)) == 6)
        // 75% memory used leaves 6 GB / 1.5 = 4 agents.
        #expect(LaunchAdvisor.agentBudget(snapshot: snapshot(cpu: 0.0, memory: 0.75)) == 4)
        // 75% CPU busy leaves 3 cores / 2 per agent = 1 agent.
        #expect(LaunchAdvisor.agentBudget(snapshot: snapshot(cpu: 0.75, memory: 0.0)) == 1)
        #expect(LaunchAdvisor.agentBudget(snapshot: snapshot(cpu: 1.0, memory: 1.0)) == 0)
    }

    @Test("Trend follows the recent third of the headroom series")
    func trendComputation() {
        #expect(CapacityTrend.compute(headroomSeries: []) == .steady)
        #expect(CapacityTrend.compute(headroomSeries: [0.5, 0.5, 0.5]) == .steady)
        // Headroom collapsing means load is rising.
        #expect(CapacityTrend.compute(headroomSeries: [0.8, 0.8, 0.8, 0.3, 0.3]) == .rising)
        #expect(CapacityTrend.compute(headroomSeries: [0.2, 0.2, 0.2, 0.7, 0.7]) == .easing)
        #expect(CapacityTrend.compute(headroomSeries: [0.5, 0.5, 0.5, 0.52, 0.48]) == .steady)
    }

    @Test("Advice always carries a recommendation and detail tips")
    func adviceTips() {
        let advice = LaunchAdvisor.advise(snapshot: snapshot(cpu: 0.2, memory: 0.4, agents: 3, tokens: 2_500_000), trend: .steady)
        #expect(advice.readiness == .comfortable)
        #expect(advice.agentBudget > 0)
        #expect(advice.tips.count >= 4)
        #expect(advice.tips[0].contains("more agent"))
        #expect(advice.tips.contains { $0.contains("tokens") })
        let strained = LaunchAdvisor.advise(snapshot: snapshot(cpu: 0.97, memory: 0.95), trend: .rising)
        #expect(strained.tips[0].contains("schedule"))
    }

    @Test("Formatting stays compact for the panel")
    func formatting() {
        #expect(LaunchAdvisor.gigabytes(24_000_000_000) == "24")
        #expect(LaunchAdvisor.gigabytes(1_500_000_000) == "1.5")
        #expect(LaunchAdvisor.compactTokens(2_500_000) == "2.5M")
        #expect(LaunchAdvisor.compactTokens(42_000) == "42k")
        #expect(LaunchAdvisor.compactTokens(900) == "900")
    }

    @Test("The monitor samples real hardware and tracks headroom history")
    func monitorSampling() {
        let monitor = SystemCapacityMonitor()
        let reading = monitor.sample(liveAgentCount: 2, tokensLast5Hours: 1_000)
        #expect(reading.cpuCoreCount > 0)
        #expect(reading.memoryTotalBytes > 0)
        #expect(reading.memoryUsedFraction > 0 && reading.memoryUsedFraction <= 1)
        #expect(reading.cpuUsedFraction >= 0 && reading.cpuUsedFraction <= 1)
        #expect(monitor.snapshot == reading)
        #expect(monitor.trend == .steady)
    }
}
