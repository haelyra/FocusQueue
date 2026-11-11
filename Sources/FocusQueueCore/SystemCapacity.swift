import Darwin
import Foundation

/// One reading of the local machine's load. Fractions run 0...1 across the
/// whole machine, not just Focus Queue's own processes: the user streams,
/// builds, and browses alongside the agents, and all of it shares the hardware.
public struct SystemCapacitySnapshot: Equatable, Sendable {
    public var sampledAt: Date
    /// Busy CPU across all cores since the previous sample; 0 until primed.
    public var cpuUsedFraction: Double
    public var cpuCoreCount: Int
    /// Active + wired + compressed memory over physical memory.
    public var memoryUsedFraction: Double
    public var memoryUsedBytes: UInt64
    public var memoryTotalBytes: UInt64
    public var swapUsedBytes: UInt64
    /// Agents the queue confirmed alive on the last refresh.
    public var liveAgentCount: Int
    /// Provider-reported (or estimated) tokens in the trailing 5-hour window.
    public var tokensLast5Hours: Int

    public init(sampledAt: Date = Date(), cpuUsedFraction: Double, cpuCoreCount: Int,
                memoryUsedFraction: Double, memoryUsedBytes: UInt64, memoryTotalBytes: UInt64,
                swapUsedBytes: UInt64, liveAgentCount: Int, tokensLast5Hours: Int) {
        self.sampledAt = sampledAt
        self.cpuUsedFraction = cpuUsedFraction
        self.cpuCoreCount = cpuCoreCount
        self.memoryUsedFraction = memoryUsedFraction
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryTotalBytes = memoryTotalBytes
        self.swapUsedBytes = swapUsedBytes
        self.liveAgentCount = liveAgentCount
        self.tokensLast5Hours = tokensLast5Hours
    }
}

/// Direction of recent headroom, from a short in-memory history.
public enum CapacityTrend: String, Equatable, Sendable {
    case rising, steady, easing

    /// Compares the recent third of the series against the earlier part.
    public static func compute(headroomSeries: [Double], sensitivity: Double = 0.04) -> CapacityTrend {
        guard headroomSeries.count >= 4 else { return .steady }
        let recentCount = max(1, headroomSeries.count / 3)
        let recent = headroomSeries.suffix(recentCount)
        let earlier = headroomSeries.dropLast(recentCount)
        let recentAverage = recent.reduce(0, +) / Double(recent.count)
        let earlierAverage = earlier.reduce(0, +) / Double(earlier.count)
        if recentAverage < earlierAverage - sensitivity { return .rising }
        if recentAverage > earlierAverage + sensitivity { return .easing }
        return .steady
    }
}

/// How welcoming the machine looks for one more agent right now. Advisory
/// only: nothing here blocks a launch.
public enum LaunchReadiness: String, Equatable, Sendable {
    case comfortable, cautious, strained

    public var headline: String {
        switch self {
        case .comfortable: "Comfortable"
        case .cautious: "Getting busy"
        case .strained: "Overloaded"
        }
    }
}

public struct LaunchAdvice: Equatable, Sendable {
    public var readiness: LaunchReadiness
    /// Rough count of additional heavy agents the machine could absorb.
    public var agentBudget: Int
    /// Short lines the view cycles through every few seconds.
    public var tips: [String]

    public init(readiness: LaunchReadiness, agentBudget: Int, tips: [String]) {
        self.readiness = readiness
        self.agentBudget = agentBudget
        self.tips = tips
    }
}

/// Guesswork thresholds for launch advice. The user asked for a feel, not a
/// governor, so every rule here only shapes the wording of the recommendation.
public enum LaunchAdvisor {
    /// A heavy local agent (builds, test servers, large reads) tends to hold
    /// around this much memory while it works.
    public static let estimatedAgentMemoryBytes: UInt64 = 1_500_000_000
    /// Cores one busy agent can keep warm during builds and test runs.
    public static let estimatedAgentCores: Double = 2
    public static let agentBudgetCap = 8

    public static func agentBudget(snapshot: SystemCapacitySnapshot) -> Int {
        let freeCores = (1 - snapshot.cpuUsedFraction) * Double(snapshot.cpuCoreCount)
        let cpuBudget = freeCores / estimatedAgentCores
        let freeBytes = Double(snapshot.memoryTotalBytes) * (1 - snapshot.memoryUsedFraction)
        let memoryBudget = freeBytes / Double(estimatedAgentMemoryBytes)
        return max(0, min(Int(min(cpuBudget, memoryBudget).rounded(.down)), agentBudgetCap))
    }

    public static func readiness(snapshot: SystemCapacitySnapshot) -> LaunchReadiness {
        if snapshot.cpuUsedFraction >= 0.90 || snapshot.memoryUsedFraction >= 0.90 {
            return .strained
        }
        // Heavy swap with high memory means the next launch likely page-thrashes.
        if snapshot.memoryUsedFraction >= 0.80, snapshot.swapUsedBytes > 4_000_000_000 {
            return .strained
        }
        if snapshot.cpuUsedFraction >= 0.72 || snapshot.memoryUsedFraction >= 0.78 {
            return .cautious
        }
        return .comfortable
    }

    public static func advise(snapshot: SystemCapacitySnapshot, trend: CapacityTrend) -> LaunchAdvice {
        let state = readiness(snapshot: snapshot)
        let budget = agentBudget(snapshot: snapshot)
        var tips: [String] = []
        switch state {
        case .comfortable:
            tips.append(budget > 0
                ? "Room for about \(budget) more agent\(budget == 1 ? "" : "s")."
                : "Light load, but no clear headroom for another heavy agent.")
        case .cautious:
            tips.append("One more agent is fine; a batch would slow everything down.")
        case .strained:
            tips.append("Saturated right now. Wait, or schedule the launch for later.")
        }
        tips.append("CPU \(Int((snapshot.cpuUsedFraction * 100).rounded()))% of \(snapshot.cpuCoreCount) cores"
            + (trend == .rising ? " and climbing." : trend == .easing ? " and easing." : "."))
        tips.append("Memory \(Self.gigabytes(snapshot.memoryUsedBytes)) of \(Self.gigabytes(snapshot.memoryTotalBytes)) GB used"
            + (snapshot.swapUsedBytes > 0 ? "; swap \(Self.gigabytes(snapshot.swapUsedBytes)) GB." : "."))
        if snapshot.liveAgentCount > 0 {
            tips.append("\(snapshot.liveAgentCount) agent\(snapshot.liveAgentCount == 1 ? " is" : "s are") live on this Mac.")
        }
        if snapshot.tokensLast5Hours > 0 {
            tips.append("About \(Self.compactTokens(snapshot.tokensLast5Hours)) tokens used in the last 5 hours.")
        }
        return LaunchAdvice(readiness: state, agentBudget: budget, tips: tips)
    }

    public static func gigabytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        return gb >= 10 ? String(format: "%.0f", gb) : String(format: "%.1f", gb)
    }

    public static func compactTokens(_ tokens: Int) -> String {
        if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000) }
        if tokens >= 1_000 { return String(format: "%.0fk", Double(tokens) / 1_000) }
        return "\(tokens)"
    }
}

/// Reads CPU, memory, and swap from the Mach host APIs. CPU usage is a delta
/// between two reads, so the first sample primes the counters and reports 0.
public struct SystemCapacitySampler: Sendable {
    public init() {}

    /// Cumulative (busy, total) CPU ticks across all cores since boot.
    public static func cpuTicks() -> (busy: UInt64, total: UInt64)? {
        var cpuInfo: processor_info_array_t?
        var cpuInfoCount: mach_msg_type_number_t = 0
        var coreCount: natural_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                         &coreCount, &cpuInfo, &cpuInfoCount)
        guard result == KERN_SUCCESS, let cpuInfo else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo),
                          vm_size_t(cpuInfoCount) * vm_size_t(MemoryLayout<integer_t>.size))
        }
        var busy: UInt64 = 0
        var total: UInt64 = 0
        for core in 0..<Int(coreCount) {
            let base = Int(CPU_STATE_MAX) * core
            let user = UInt64(bitPattern: Int64(cpuInfo[base + Int(CPU_STATE_USER)]))
            let system = UInt64(bitPattern: Int64(cpuInfo[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(bitPattern: Int64(cpuInfo[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(bitPattern: Int64(cpuInfo[base + Int(CPU_STATE_IDLE)]))
            busy += user + system + nice
            total += user + system + nice + idle
        }
        return (busy, total)
    }

    public static func cpuFraction(busyDelta: UInt64, totalDelta: UInt64) -> Double {
        guard totalDelta > 0 else { return 0 }
        return min(1, max(0, Double(busyDelta) / Double(totalDelta)))
    }

    /// Active + wired + compressed bytes and physical memory bytes.
    public static func memoryUsage() -> (used: UInt64, total: UInt64) {
        var total: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &total, &size, nil, 0)
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS, total > 0 else { return (0, total) }
        var pageSize = vm_size_t(0)
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS, pageSize > 0 else {
            return (0, total)
        }
        let usedPages = UInt64(statistics.active_count)
            + UInt64(statistics.wire_count) + UInt64(statistics.compressor_page_count)
        return (min(usedPages * UInt64(pageSize), total), total)
    }

    public static func memoryFraction(usedBytes: UInt64, totalBytes: UInt64) -> Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(usedBytes) / Double(totalBytes)))
    }

    public static func swapUsedBytes() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return usage.xsu_used
    }

    public static var coreCount: Int { ProcessInfo.processInfo.processorCount }
}

/// Keeps the previous CPU counters and a short headroom history so each
/// sample can report both instantaneous load and its direction.
public final class SystemCapacityMonitor {
    public private(set) var snapshot: SystemCapacitySnapshot?
    public private(set) var trend: CapacityTrend = .steady
    private var previousCPUTicks: (busy: UInt64, total: UInt64)?
    private var headroomSeries: [Double] = []
    private let historyLimit = 12

    public init() {
        previousCPUTicks = SystemCapacitySampler.cpuTicks()
    }

    @discardableResult
    public func sample(liveAgentCount: Int, tokensLast5Hours: Int, now: Date = Date()) -> SystemCapacitySnapshot {
        var cpuFraction = snapshot?.cpuUsedFraction ?? 0
        if let ticks = SystemCapacitySampler.cpuTicks() {
            if let previous = previousCPUTicks {
                cpuFraction = SystemCapacitySampler.cpuFraction(
                    busyDelta: ticks.busy &- previous.busy,
                    totalDelta: ticks.total &- previous.total)
            }
            previousCPUTicks = ticks
        }
        let memory = SystemCapacitySampler.memoryUsage()
        let memoryFraction = SystemCapacitySampler.memoryFraction(usedBytes: memory.used, totalBytes: memory.total)
        let reading = SystemCapacitySnapshot(
            sampledAt: now,
            cpuUsedFraction: cpuFraction,
            cpuCoreCount: SystemCapacitySampler.coreCount,
            memoryUsedFraction: memoryFraction,
            memoryUsedBytes: memory.used,
            memoryTotalBytes: memory.total,
            swapUsedBytes: SystemCapacitySampler.swapUsedBytes(),
            liveAgentCount: liveAgentCount,
            tokensLast5Hours: tokensLast5Hours)
        snapshot = reading
        let headroom = 1 - max(cpuFraction, memoryFraction)
        headroomSeries.append(headroom)
        if headroomSeries.count > historyLimit { headroomSeries.removeFirst() }
        trend = CapacityTrend.compute(headroomSeries: headroomSeries)
        return reading
    }
}
