import Foundation
import Darwin

public struct SystemMetricsSample: Sendable {
    /// Aggregate machine CPU utilization over the interval since the last sample.
    /// Nil means that a baseline or a nonzero tick interval is not available yet.
    public let cpuPercent: Double?
    /// Estimated occupied physical memory, excluding readily purgeable anonymous pages.
    /// This is not a claim of exact equality with Activity Monitor's Memory Used.
    public let memoryUsedBytes: UInt64
    public let memoryTotalBytes: UInt64
    public var memoryPercent: Double {
        guard memoryTotalBytes > 0 else { return 0 }
        return min(100, 100 * Double(memoryUsedBytes) / Double(memoryTotalBytes))
    }

    public init(cpuPercent: Double?, memoryUsedBytes: UInt64, memoryTotalBytes: UInt64) {
        self.cpuPercent = cpuPercent
        self.memoryUsedBytes = min(memoryUsedBytes, memoryTotalBytes)
        self.memoryTotalBytes = memoryTotalBytes
    }
}

struct CPUTicks {
    let user: UInt32
    let system: UInt32
    let idle: UInt32
    let nice: UInt32
}

struct CPUUsageTracker {
    private var previous: CPUTicks?

    mutating func consume(_ current: CPUTicks) -> Double? {
        defer { previous = current }
        guard let previous else { return nil }
        // Mach exposes each cumulative counter as a 32-bit natural_t. Subtract
        // modulo 2^32 separately, then widen before summing to avoid overflow.
        let user = UInt64(current.user &- previous.user)
        let system = UInt64(current.system &- previous.system)
        let nice = UInt64(current.nice &- previous.nice)
        let idle = UInt64(current.idle &- previous.idle)
        let busy = user + system + nice
        let total = busy + idle
        guard total > 0 else { return nil }
        return min(100, max(0, 100 * Double(busy) / Double(total)))
    }

    mutating func reset() { previous = nil }
}

enum SystemMetricMath {
    static func memoryUsedBytes(internalPages: UInt64, purgeablePages: UInt64,
                                wiredPages: UInt64, compressorPages: UInt64,
                                pageSize: UInt64, physicalBytes: UInt64) -> UInt64 {
        guard pageSize > 0, physicalBytes > 0 else { return 0 }
        let anonymous = internalPages > purgeablePages ? internalPages - purgeablePages : 0
        let (anonymousAndWired, sumOverflow) = anonymous.addingReportingOverflow(wiredPages)
        guard !sumOverflow else { return physicalBytes }
        let (pages, compressorOverflow) = anonymousAndWired.addingReportingOverflow(compressorPages)
        guard !compressorOverflow else { return physicalBytes }
        let (bytes, productOverflow) = pages.multipliedReportingOverflow(by: pageSize)
        return productOverflow ? physicalBytes : min(bytes, physicalBytes)
    }
}

public enum SystemMetricsError: LocalizedError {
    case machCall(operation: String, code: kern_return_t)
    case incompleteStatistics(operation: String)

    public var errorDescription: String? {
        switch self {
        case let .machCall(operation, code):
            return "\(operation) failed (Mach error \(code))."
        case let .incompleteStatistics(operation):
            return "\(operation) returned incomplete system statistics."
        }
    }
}

/// Reuse one sampler for successive readings. WidgetKit providers can take a
/// baseline, wait about 0.3 seconds, then take their timeline entry's sample.
/// The lock serializes reads and CPU resets, including asynchronous callers.
public final class SystemMetricsSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var cpu = CPUUsageTracker()
    private let physicalBytes = ProcessInfo.processInfo.physicalMemory

    public init() {}

    public func sample() throws -> SystemMetricsSample {
        lock.lock()
        defer { lock.unlock() }

        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }

        var pageSize: vm_size_t = 0
        try check(host_page_size(host, &pageSize), operation: "host_page_size")
        guard pageSize > 0 else {
            throw SystemMetricsError.incompleteStatistics(operation: "host_page_size")
        }

        var vm = vm_statistics64_data_t()
        let vmCapacity = MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        var vmCount = mach_msg_type_number_t(vmCapacity)
        let vmResult = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: vmCapacity) {
                host_statistics64(host, HOST_VM_INFO64, $0, &vmCount)
            }
        }
        try check(vmResult, operation: "host_statistics64")
        // A newer SDK can describe trailing fields an older kernel does not
        // return. Require only the bytes through the last field we consume.
        let requiredVMBytes = MemoryLayout<vm_statistics64_data_t>.offset(of: \.internal_page_count)!
            + MemoryLayout<natural_t>.size
        guard Int(vmCount) * MemoryLayout<integer_t>.size >= requiredVMBytes else {
            throw SystemMetricsError.incompleteStatistics(operation: "host_statistics64")
        }

        var cpuInfo = host_cpu_load_info_data_t()
        let cpuCapacity = MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        var cpuCount = mach_msg_type_number_t(cpuCapacity)
        let cpuResult = withUnsafeMutablePointer(to: &cpuInfo) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: cpuCapacity) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &cpuCount)
            }
        }
        try check(cpuResult, operation: "host_statistics")
        guard cpuCount >= cpuCapacity else {
            throw SystemMetricsError.incompleteStatistics(operation: "host_statistics")
        }
        // mach/machine.h defines USER=0, SYSTEM=1, IDLE=2, NICE=3.
        let ticks = CPUTicks(user: cpuInfo.cpu_ticks.0, system: cpuInfo.cpu_ticks.1,
                             idle: cpuInfo.cpu_ticks.2, nice: cpuInfo.cpu_ticks.3)

        // SDK mach/vm_statistics.h: internal pages are anonymous; compressor
        // pages are physical storage for compressed data. File-backed pages,
        // free pages, and logical uncompressed size are intentionally not added.
        let used = SystemMetricMath.memoryUsedBytes(
            internalPages: UInt64(vm.internal_page_count),
            purgeablePages: UInt64(vm.purgeable_count),
            wiredPages: UInt64(vm.wire_count),
            compressorPages: UInt64(vm.compressor_page_count),
            pageSize: UInt64(pageSize), physicalBytes: physicalBytes
        )
        return SystemMetricsSample(cpuPercent: cpu.consume(ticks),
                                   memoryUsedBytes: used, memoryTotalBytes: physicalBytes)
    }

    /// Call after wake or another break in the desired CPU measurement interval.
    public func resetCPU() {
        lock.lock()
        defer { lock.unlock() }
        cpu.reset()
    }

    private func check(_ result: kern_return_t, operation: String) throws {
        guard result == KERN_SUCCESS else {
            throw SystemMetricsError.machCall(operation: operation, code: result)
        }
    }
}
