import Foundation
import IOKit
import IOKit.ps

public enum BatteryPowerState: Sendable {
    case battery, external, unavailable
}

public struct SupplementalMetricsSample: Sendable {
    /// Estimated DC input power, or battery discharge power, according to powerLabel.
    /// This never represents a wall-socket meter or a guarantee of whole-machine power.
    public let powerWatts: Double?
    public let powerLabel: String
    /// OS estimate while discharging the internal battery; nil if unavailable.
    public let batteryRemainingHours: Double?
    public let batteryState: BatteryPowerState
    /// Home volume capacity; free excludes the separate purgeable-space estimates.
    public let diskUsedBytes: UInt64
    public let diskTotalBytes: UInt64
    public let diskFreeBytes: UInt64
}

struct PowerMetricReading {
    let watts: Double?
    let label: String
}

struct BatteryMetricReading {
    let remainingHours: Double?
    let state: BatteryPowerState
}

enum BatteryMetricParser {
    static func reading(powerSources: [[String: Any]]) -> BatteryMetricReading {
        let batteries = powerSources.filter {
            $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType &&
            boolean($0[kIOPSIsPresentKey]) == true
        }
        // A per-source estimate cannot represent multiple batteries or a UPS.
        guard batteries.count == 1, let source = batteries.first else {
            return BatteryMetricReading(remainingHours: nil, state: .unavailable)
        }
        let sourceState = source[kIOPSPowerSourceStateKey] as? String
        if sourceState == kIOPSACPowerValue {
            return BatteryMetricReading(remainingHours: nil, state: .external)
        }
        guard sourceState == kIOPSBatteryPowerValue,
              boolean(source[kIOPSIsChargingKey]) == false else {
            return BatteryMetricReading(remainingHours: nil, state: .unavailable)
        }

        // IOPSKeys.h documents Time to Empty as integer minutes, valid only
        // on battery while not charging; -1 means the OS is still calculating.
        // https://developer.apple.com/documentation/iokit/kiopstimetoemptykey
        // The seven-day ceiling rejects implausible values and raw hardware
        // sentinels such as 65535; it is a display validity guard, not an API limit.
        if let estimate = source[kIOPSTimeToEmptyKey] as? NSNumber,
           CFGetTypeID(estimate) != CFBooleanGetTypeID() {
            let minutes = estimate.doubleValue
            if minutes.isFinite, minutes >= 0, minutes <= 7 * 24 * 60,
               minutes == minutes.rounded() {
                return BatteryMetricReading(remainingHours: minutes / 60, state: .battery)
            }
        }
        // IOPS Current Capacity is commonly percent, not mAh. Do not divide
        // that value by current, or reuse a previous estimate after it expires.
        return BatteryMetricReading(remainingHours: nil, state: .battery)
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}

enum PowerMetricParser {
    static func reading(properties: [String: Any]) -> PowerMetricReading {
        let externalConnected = boolean(properties["ExternalConnected"])
        if externalConnected == true,
           let telemetry = properties["PowerTelemetryData"] as? [String: Any],
           let powerMilliwatts = number(telemetry["SystemPowerIn"]),
           let currentMilliamps = number(telemetry["SystemCurrentIn"]),
           let voltageMillivolts = number(telemetry["SystemVoltageIn"]),
           powerMilliwatts > 0, powerMilliwatts <= 1_000_000,
           currentMilliamps > 0, currentMilliamps <= 30_000,
           voltageMillivolts >= 4_000, voltageMillivolts <= 60_000 {
            // These private telemetry units are inferred, not an Apple API contract.
            // Corroborate every sample using P = IV and retain the estimate label.
            // The allowance covers independently sampled/rounded hardware fields.
            let reportedWatts = powerMilliwatts / 1_000
            let electricalWatts = currentMilliamps * voltageMillivolts / 1_000_000
            if electricalWatts <= 1_000,
               abs(reportedWatts - electricalWatts) <= max(0.5, reportedWatts * 0.10) {
                return PowerMetricReading(watts: reportedWatts, label: "输入功率（估算）")
            }
        }

        // IOPMPowerSource documents Amperage as signed mA and Voltage as mV:
        // https://developer.apple.com/documentation/kernel/iopmpowersource
        // Amperage may be an average reading. Do not use the undocumented
        // InstantAmperage or label charging power as computer consumption.
        if externalConnected == false,
           boolean(properties["IsCharging"]) == false,
           let voltage = number(properties["Voltage"]),
           voltage >= 1_000, voltage <= 30_000,
           let currentNumber = properties["Amperage"] as? NSNumber,
           CFGetTypeID(currentNumber) != CFBooleanGetTypeID() {
            // IORegistry can bridge a negative current as an unsigned 64-bit
            // NSNumber. int64Value preserves the two's-complement sign.
            let current = Double(currentNumber.int64Value)
            let watts = abs(current) * voltage / 1_000_000
            if current < 0, current >= -100_000, watts > 0, watts <= 1_000 {
                return PowerMetricReading(watts: watts, label: "电池放电功率")
            }
        }
        if externalConnected == true {
            return PowerMetricReading(watts: nil, label: "输入功率不可用（遥测未验证）")
        }
        return PowerMetricReading(watts: nil, label: "功率不可用（系统未提供有效读数）")
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber else { return nil }
        // Native IORegistry state properties are CFBoolean, not arbitrary numbers.
        guard CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}

enum SupplementalMetricError: LocalizedError {
    case diskCapacityUnavailable
    var errorDescription: String? { "无法读取有效的磁盘容量" }
}

enum DiskMetricMath {
    static func capacity(total: Int, available: Int) throws -> (used: UInt64, total: UInt64, free: UInt64) {
        guard total > 0, available >= 0, available <= total else {
            throw SupplementalMetricError.diskCapacityUnavailable
        }
        return (UInt64(total - available), UInt64(total), UInt64(available))
    }
}

public struct SupplementalMetricsSampler {
    public init() {}
    public func sample() throws -> SupplementalMetricsSample {
        // In a sandbox, the home directory can be the app's container. It remains
        // on the user's home volume and requires no access to user documents.
        // Only the ordinary available capacity is used, never ImportantUsage or
        // OpportunisticUsage values that can include reclaimable-space estimates.
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        let resources: URLResourceValues
        do {
            resources = try homeURL.resourceValues(forKeys: [
                .volumeTotalCapacityKey, .volumeAvailableCapacityKey
            ])
        } catch {
            throw SupplementalMetricError.diskCapacityUnavailable
        }
        guard let total = resources.volumeTotalCapacity,
              let available = resources.volumeAvailableCapacity else {
            throw SupplementalMetricError.diskCapacityUnavailable
        }
        let disk = try DiskMetricMath.capacity(total: total, available: available)
        let power = readPower()
        let battery = readBattery()
        return SupplementalMetricsSample(powerWatts: power.watts, powerLabel: power.label,
                                         batteryRemainingHours: battery.remainingHours, batteryState: battery.state,
                                         diskUsedBytes: disk.used, diskTotalBytes: disk.total,
                                         diskFreeBytes: disk.free)
    }

    private func readBattery() -> BatteryMetricReading {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let handles = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return BatteryMetricReading(remainingHours: nil, state: .unavailable)
        }
        let sources: [[String: Any]] = handles.compactMap { handle in
            guard let description = IOPSGetPowerSourceDescription(snapshot, handle)?.takeUnretainedValue()
                    as? [String: Any] else { return nil }
            // Retain only the metric and state keys needed by the parser.
            var values: [String: Any] = [:]
            for key in [kIOPSTypeKey, kIOPSIsPresentKey, kIOPSPowerSourceStateKey,
                        kIOPSIsChargingKey, kIOPSTimeToEmptyKey] {
                values[key] = description[key]
            }
            return values
        }
        return BatteryMetricParser.reading(powerSources: sources)
    }

    private func readPower() -> PowerMetricReading {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else {
            return PowerMetricReading(watts: nil, label: "功率不可用（系统未提供）")
        }
        defer { IOObjectRelease(service) }
        // Read only metric/state properties. Never retrieve or log an entire
        // battery registry record, which may contain serial numbers or IDs.
        var values: [String: Any] = [:]
        for key in ["PowerTelemetryData", "ExternalConnected", "IsCharging", "Amperage", "Voltage"] {
            if let value = IORegistryEntryCreateCFProperty(service, key as CFString,
                                                           kCFAllocatorDefault, 0) {
                values[key] = value.takeRetainedValue()
            }
        }
        return PowerMetricParser.reading(properties: values)
    }
}
