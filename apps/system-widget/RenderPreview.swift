import AppKit
import SwiftUI

@main
struct PreviewRenderer {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let actual = await MetricsLoader.load()
        let example = DashboardEntry.example
        func batteryExample(hours: Double?, state: BatteryPowerState) -> DashboardEntry {
            DashboardEntry(date: example.date, cpu: example.cpu, memory: example.memory,
                memoryUsed: example.memoryUsed, memoryTotal: example.memoryTotal,
                power: example.power, powerLabel: state == .external ? "输入功率（估算）" : "电池放电功率",
                batteryRemainingHours: hours, batteryState: state,
                diskUsed: example.diskUsed, diskTotal: example.diskTotal, diskFree: example.diskFree,
                isExample: true, failed: false)
        }
        let scenarios = [("actual", actual), ("example", example), ("unavailable", DashboardEntry.loading),
                         ("estimating", batteryExample(hours: nil, state: .battery)),
                         ("external", batteryExample(hours: nil, state: .external)),
                         ("low-battery", batteryExample(hours: 0.03, state: .battery))]
        for (name, entry) in scenarios {
            for (size, width, height, large, vertical, simple) in [
                ("medium", 338.0, 170.0, false, false, false),
                ("large", 338.0, 354.0, true, false, false),
                ("vertical", 338.0, 354.0, true, true, false),
                ("simple-horizontal", 338.0, 170.0, false, false, true)
            ] {
                let content = Group {
                    if simple { SimpleDashboardView(entry: entry, nativeBlur: true) }
                    else { DashboardView(entry: entry, large: large, vertical: vertical) }
                }
                let renderer = ImageRenderer(content: content
                    .padding(16).frame(width: width, height: height)
                    // Standalone PNGs cannot capture WidgetKit's wallpaper compositor.
                    // Use a labeled sample blue backdrop instead of a misleading white card.
                    .background(simple ? Color(red: 0.29, green: 0.47, blue: 0.64) : Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 23))
                    .overlay {
                        if simple {
                            RoundedRectangle(cornerRadius: 23).strokeBorder(.white.opacity(0.18), lineWidth: 0.7)
                        }
                    })
                renderer.scale = 2
                guard let cg = renderer.cgImage else { throw NSError(domain: "Preview", code: 1) }
                let rep = NSBitmapImageRep(cgImage: cg)
                let prefix = simple ? "sample-backdrop-" : ""
                try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("\(prefix)\(name)-\(size).png"))
            }
        }
        print("Rendered four layouts and six states. Simple PNGs have a sample blue backdrop; they do not capture native wallpaper blur.")
    }
}
