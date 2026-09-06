#if POWER_DISK_METRICS_TESTS
import Foundation
import Darwin

@main
enum PowerDiskMetricsTests {
    static func main() throws {
        var failures: [String] = []
        var count = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            count += 1
            if !condition() { failures.append(message) }
        }
        func near(_ value: Double?, _ expected: Double) -> Bool {
            guard let value else { return false }
            return abs(value - expected) < 0.000_001
        }
        func power(_ values: [String: Any]) -> PowerMetricReading {
            PowerMetricParser.reading(properties: values)
        }
        let liveFixture: [String: Any] = [
            "ExternalConnected": true, "IsCharging": false,
            "Amperage": 0, "Voltage": 13_058,
            "PowerTelemetryData": ["SystemPowerIn": 15_631,
                                   "SystemCurrentIn": 559, "SystemVoltageIn": 27_915]
        ]
        // Catches a factor-of-1000 error and interpreting a full battery's 0 mA as 0 W.
        let input = power(liveFixture)
        expect(near(input.watts, 15.631), "Cross-checked input telemetry must convert mW to W")
        expect(input.label.contains("输入") && input.label.contains("估算"),
               "Undocumented input telemetry must retain an explicit estimate label")
        var charging = liveFixture
        charging["IsCharging"] = true
        charging["Amperage"] = 2_000
        expect(near(power(charging).watts, 15.631), "Charging must not be subtracted from input power")

        // Catches accepting an unverified private field or obviously inconsistent units.
        expect(power(["ExternalConnected": true,
                      "PowerTelemetryData": ["SystemPowerIn": 15_631]]).watts == nil,
               "An input-power field without voltage/current corroboration must be unavailable")
        expect(power(["ExternalConnected": true,
                      "PowerTelemetryData": ["SystemPowerIn": 100_000,
                                             "SystemCurrentIn": 500, "SystemVoltageIn": 20_000]]).watts == nil,
               "Telemetry inconsistent with voltage times current must be rejected")
        expect(power(["ExternalConnected": true,
                      "PowerTelemetryData": ["SystemLoad": 15_000]]).watts == nil,
               "SystemLoad alone must not manufacture whole-system watts")
        expect(power(["ExternalConnected": true,
                      "PowerTelemetryData": ["SystemPowerIn": 0,
                                             "SystemCurrentIn": 0, "SystemVoltageIn": 20_000]]).watts == nil,
               "Missing or zero telemetry must not advertise zero machine consumption")
        expect(power(["ExternalConnected": true,
                      "PowerTelemetryData": ["SystemPowerIn": Double.nan,
                                             "SystemCurrentIn": 500, "SystemVoltageIn": 20_000]]).watts == nil,
               "Nonfinite input readings must be rejected")
        expect(power(["ExternalConnected": true,
                      "PowerTelemetryData": ["SystemPowerIn": true,
                                             "SystemCurrentIn": true, "SystemVoltageIn": true]]).watts == nil,
               "Booleans are not numeric telemetry")

        // Hand fixture: -1000 mA at 12000 mV discharges 12 W; charging is not consumption.
        let battery: [String: Any] = ["ExternalConnected": false, "IsCharging": false,
                                      "Amperage": -1_000, "Voltage": 12_000]
        expect(near(power(battery).watts, 12), "Battery discharge must use mA times mV divided by one million")
        expect(power(battery).label.contains("电池放电"), "A battery reading must identify its narrower scope")
        var encoded = battery
        encoded["Amperage"] = NSNumber(value: UInt64.max - 999)
        expect(near(power(encoded).watts, 12), "Unsigned 64-bit registry currents must preserve their signed meaning")
        var invalid = battery
        invalid["Amperage"] = 1_000
        expect(power(invalid).watts == nil, "Positive current must not be mislabeled battery discharge")
        invalid = battery
        invalid["IsCharging"] = true
        expect(power(invalid).watts == nil, "Charging state must prevent a discharge reading")
        invalid = battery
        invalid["Voltage"] = -12_000
        expect(power(invalid).watts == nil, "Negative battery voltage must be rejected")
        invalid = battery
        invalid.removeValue(forKey: "ExternalConnected")
        expect(power(invalid).watts == nil, "Unknown power-source state must not be assumed battery discharge")
        expect(power([:]).watts == nil && !power([:]).label.isEmpty,
               "Unsupported hardware must return unavailable with a reason")

        // Public IOPowerSources descriptions report Time to Empty in minutes,
        // while Current Capacity / Max Capacity can be percentages, not mAh.
        let runtimeFixture: [String: Any] = [
            "Type": "InternalBattery", "Is Present": true,
            "Power Source State": "Battery Power", "Is Charging": false,
            "Time to Empty": 150, "Current Capacity": 75, "Max Capacity": 100
        ]
        func runtime(_ source: [String: Any]) -> BatteryMetricReading {
            BatteryMetricParser.reading(powerSources: [source])
        }
        let batteryRuntime = runtime(runtimeFixture)
        expect(batteryRuntime.state == .battery && near(batteryRuntime.remainingHours, 2.5),
               "150 minutes of battery runtime must become 2.5 hours")

        var runtimeSource = runtimeFixture
        runtimeSource["Power Source State"] = "AC Power"
        for isCharging in [false, true] {
            runtimeSource["Is Charging"] = isCharging
            let externalRuntime = runtime(runtimeSource)
            expect(externalRuntime.state == .external && externalRuntime.remainingHours == nil,
                   "External power must suppress even a stale time-to-empty estimate")
        }
        runtimeSource = runtimeFixture
        runtimeSource["Is Charging"] = true
        expect(runtime(runtimeSource).remainingHours == nil,
               "Charging must suppress a time-to-empty estimate even with inconsistent battery state")
        for key in ["Type", "Is Present", "Power Source State", "Is Charging"] {
            runtimeSource = runtimeFixture
            runtimeSource.removeValue(forKey: key)
            expect(runtime(runtimeSource).remainingHours == nil,
                   "Missing source identity or state must not fabricate runtime: \(key)")
        }
        runtimeSource = runtimeFixture
        runtimeSource["Is Present"] = false
        expect(runtime(runtimeSource).state == .unavailable && runtime(runtimeSource).remainingHours == nil,
               "An absent battery must not retain a runtime estimate")
        runtimeSource = runtimeFixture
        runtimeSource["Power Source State"] = "Off Line"
        expect(runtime(runtimeSource).state == .unavailable && runtime(runtimeSource).remainingHours == nil,
               "Offline power sources must not be assumed to supply battery power")
        runtimeSource = runtimeFixture
        runtimeSource["Is Charging"] = 0
        expect(runtime(runtimeSource).remainingHours == nil,
               "Arbitrary numeric state must not stand in for the documented CFBoolean")

        runtimeSource = runtimeFixture
        runtimeSource.removeValue(forKey: "Time to Empty")
        expect(runtime(runtimeSource).state == .battery && runtime(runtimeSource).remainingHours == nil,
               "Missing time-to-empty must remain unavailable; percentage capacity is not mAh")
        runtimeSource = runtimeFixture
        runtimeSource["Time to Empty"] = 0
        expect(runtime(runtimeSource).state == .battery && near(runtime(runtimeSource).remainingHours, 0),
               "Zero estimated minutes must remain a valid battery estimate of 0.0 hours")
        for estimate: Any in [-1, -2, -150, 65_535, Int32.max,
                              Double.nan, Double.infinity, true, "150", 150.5] {
            runtimeSource = runtimeFixture
            runtimeSource["Time to Empty"] = estimate
            expect(runtime(runtimeSource).state == .battery && runtime(runtimeSource).remainingHours == nil,
                   "Unknown, malformed, or implausible time-to-empty must be rejected: \(estimate)")
        }
        runtimeSource = runtimeFixture
        runtimeSource["Type"] = "UPS"
        expect(runtime(runtimeSource).state == .unavailable && runtime(runtimeSource).remainingHours == nil,
               "A UPS estimate must not be labeled as the Mac battery's runtime")
        let mixedSources = BatteryMetricParser.reading(powerSources: [runtimeSource, runtimeFixture])
        expect(mixedSources.state == .battery && near(mixedSources.remainingHours, 2.5),
               "A non-battery power source before the internal battery must not hide battery runtime")
        let noSources = BatteryMetricParser.reading(powerSources: [])
        expect(noSources.state == .unavailable && noSources.remainingHours == nil,
               "No power sources must report unavailable without inventing a battery")
        let multipleBatteries = BatteryMetricParser.reading(powerSources: [runtimeFixture, runtimeFixture])
        expect(multipleBatteries.remainingHours == nil,
               "Multiple internal batteries need an aggregate estimate; one battery cannot represent all")

        let disk = try DiskMetricMath.capacity(total: 1_000, available: 350)
        expect(disk.used == 650 && disk.total == 1_000 && disk.free == 350,
               "Disk used bytes must equal total minus ordinary available bytes")
        let full = try DiskMetricMath.capacity(total: 1_000, available: 0)
        expect(full.used == 1_000 && full.free == 0, "A full volume must be represented without underflow")
        for (total, available) in [(0, 0), (-1, 0), (1_000, -1), (1_000, 1_001)] {
            do {
                _ = try DiskMetricMath.capacity(total: total, available: available)
                expect(false, "Invalid disk capacity must be rejected: \(total), \(available)")
            } catch { expect(true, "Invalid disk capacity rejected") }
        }

        if !failures.isEmpty {
            failures.forEach { print("FAIL: \($0)") }
            exit(EXIT_FAILURE)
        }
        print("PASS: \(count) power, battery runtime, and disk assertions")
        if CommandLine.arguments.contains("--sample") {
            let sample = try SupplementalMetricsSampler().sample()
            precondition(sample.diskTotalBytes > 0)
            precondition(sample.diskUsedBytes + sample.diskFreeBytes == sample.diskTotalBytes)
            if let watts = sample.powerWatts { precondition(watts.isFinite && watts > 0 && watts <= 1_000) }
            if let hours = sample.batteryRemainingHours {
                precondition(sample.batteryState == .battery && hours.isFinite && hours >= 0 && hours <= 168)
            }
            print("LIVE: power=\(sample.powerWatts.map { String(format: "%.3f W", $0) } ?? "unavailable") [\(sample.powerLabel)], battery state=\(sample.batteryState), runtime=\(sample.batteryRemainingHours.map { String(format: "%.2f h", $0) } ?? "unavailable"), disk used=\(sample.diskUsedBytes), free=\(sample.diskFreeBytes), total=\(sample.diskTotalBytes) bytes")
        }
    }
}
#endif
