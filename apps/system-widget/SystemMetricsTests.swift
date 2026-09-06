#if SYSTEM_METRICS_TESTS
import Foundation
import Darwin

@main
enum SystemMetricsTests {
    static func main() throws {
        var failures: [String] = []
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }
        func near(_ actual: Double?, _ expected: Double) -> Bool {
            guard let actual else { return false }
            return abs(actual - expected) < 0.000_001
        }

        // Catches lifetime-average CPU, omitted nice/system ticks, and per-core scaling.
        var cpu = CPUUsageTracker()
        expect(cpu.consume(CPUTicks(user: 1_000, system: 2_000, idle: 7_000, nice: 0)) == nil,
               "First CPU observation must establish a baseline")
        expect(near(cpu.consume(CPUTicks(user: 1_020, system: 2_010, idle: 7_060, nice: 10)), 40),
               "CPU must use interval deltas and count user, system, and nice as busy")
        expect(cpu.consume(CPUTicks(user: 1_020, system: 2_010, idle: 7_060, nice: 10)) == nil,
               "No elapsed ticks must produce no CPU reading")
        expect(near(cpu.consume(CPUTicks(user: 1_020, system: 2_010, idle: 7_160, nice: 10)), 0),
               "An entirely idle interval must return zero")
        expect(near(cpu.consume(CPUTicks(user: 1_100, system: 2_030, idle: 7_160, nice: 10)), 100),
               "An entirely busy interval must return 100, regardless of core count")
        cpu.reset()
        expect(cpu.consume(CPUTicks(user: 9, system: 8, idle: 7, nice: 6)) == nil,
               "Reset after waking must discard the previous baseline")

        // Catches trapping subtraction and summing UInt32 before widening.
        var wrapped = CPUUsageTracker()
        _ = wrapped.consume(CPUTicks(user: UInt32.max - 9, system: 0, idle: UInt32.max - 19, nice: 0))
        expect(near(wrapped.consume(CPUTicks(user: 10, system: 0, idle: 60, nice: 0)), 20),
               "Each UInt32 cumulative counter must tolerate wraparound")
        var wide = CPUUsageTracker()
        _ = wide.consume(CPUTicks(user: 0, system: 0, idle: 0, nice: 0))
        expect(near(wide.consume(CPUTicks(user: UInt32.max, system: UInt32.max,
                                         idle: UInt32.max, nice: UInt32.max)), 75),
               "Adding deltas across states must not overflow UInt32")

        // Catches counting purgeable pages and confusing compressed logical size with physical pages.
        expect(SystemMetricMath.memoryUsedBytes(internalPages: 100, purgeablePages: 30,
                                                 wiredPages: 20, compressorPages: 10,
                                                 pageSize: 4_096, physicalBytes: 1_048_576) == 409_600,
               "Memory must count non-purgeable anonymous pages, wired pages, and compressor pages")
        expect(SystemMetricMath.memoryUsedBytes(internalPages: 10, purgeablePages: 30,
                                                 wiredPages: 2, compressorPages: 3,
                                                 pageSize: 16_384, physicalBytes: 1_048_576) == 81_920,
               "Purgeable subtraction must clamp at zero before adding other categories")
        expect(SystemMetricMath.memoryUsedBytes(internalPages: 100, purgeablePages: 0,
                                                 wiredPages: 100, compressorPages: 100,
                                                 pageSize: 4_096, physicalBytes: 999) == 999,
               "Estimated memory must not exceed physical memory")
        expect(SystemMetricMath.memoryUsedBytes(internalPages: UInt64.max, purgeablePages: 0,
                                                 wiredPages: UInt64.max, compressorPages: UInt64.max,
                                                 pageSize: 16_384, physicalBytes: 8_000_000_000) == 8_000_000_000,
               "Unrepresentable page sums or products must saturate safely")
        expect(SystemMetricMath.memoryUsedBytes(internalPages: 1, purgeablePages: 0,
                                                 wiredPages: 0, compressorPages: 0,
                                                 pageSize: 0, physicalBytes: 1_000) == 0,
               "A zero page size must not manufacture occupied bytes")
        expect(SystemMetricsSample(cpuPercent: nil, memoryUsedBytes: 1, memoryTotalBytes: 0).memoryPercent == 0,
               "Unknown physical size must not produce NaN or infinity")
        expect(SystemMetricsSample(cpuPercent: nil, memoryUsedBytes: 4, memoryTotalBytes: 8).memoryPercent == 50,
               "Memory percentage must use occupied bytes over physical bytes")
        expect(SystemMetricsSample(cpuPercent: nil, memoryUsedBytes: 9, memoryTotalBytes: 8).memoryPercent == 100,
               "Memory percentage must remain within 0 through 100")

        if failures.isEmpty {
            print("PASS: 16 CPU and memory boundary assertions")
        } else {
            for failure in failures { print("FAIL: \(failure)") }
            exit(EXIT_FAILURE)
        }

        if CommandLine.arguments.contains("--sample") {
            let sampler = SystemMetricsSampler()
            let baseline = try sampler.sample()
            precondition(baseline.cpuPercent == nil)
            Thread.sleep(forTimeInterval: 0.3)
            let current = try sampler.sample()
            precondition(current.memoryTotalBytes > 0)
            precondition(current.memoryUsedBytes <= current.memoryTotalBytes)
            if let percent = current.cpuPercent { precondition((0...100).contains(percent)) }
            print("LIVE: cpu=\(current.cpuPercent.map { String(format: "%.2f", $0) } ?? "unavailable")% memory=\(current.memoryUsedBytes)/\(current.memoryTotalBytes) bytes (\(String(format: "%.2f", current.memoryPercent))%)")
            sampler.resetCPU()
            let afterReset = try sampler.sample()
            precondition(afterReset.cpuPercent == nil)
            print("PASS: live Mach sampling and wake reset")
        }
    }
}
#endif
