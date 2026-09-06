import SwiftUI
import WidgetKit
import AppIntents

let metricsWidgetKind = "SystemStatusDashboard"
let verticalMetricsWidgetKind = "SystemStatusVerticalDashboard"

struct DashboardEntry: TimelineEntry {
    let date: Date
    let cpu: Double?
    let memory: Double?
    let memoryUsed: UInt64?
    let memoryTotal: UInt64?
    let power: Double?
    let powerLabel: String
    let batteryRemainingHours: Double?
    let batteryState: BatteryPowerState
    let diskUsed: UInt64?
    let diskTotal: UInt64?
    let diskFree: UInt64?
    let isExample: Bool
    let failed: Bool
    static let loading = DashboardEntry(date: .now, cpu: nil, memory: nil, memoryUsed: nil, memoryTotal: nil, power: nil, powerLabel: "功率", batteryRemainingHours: nil, batteryState: .unavailable, diskUsed: nil, diskTotal: nil, diskFree: nil, isExample: false, failed: false)
    static let example = DashboardEntry(date: .now, cpu: 27, memory: 51, memoryUsed: 24_500_000_000, memoryTotal: 48_000_000_000, power: 15.6, powerLabel: "电池放电功率", batteryRemainingHours: 5.2, batteryState: .battery, diskUsed: 425_000_000_000, diskTotal: 1_000_000_000_000, diskFree: 575_000_000_000, isExample: true, failed: false)
}

struct RefreshMetricsIntent: AppIntent {
    static var title: LocalizedStringResource = "刷新系统状态"
    static var description = IntentDescription("重新采样 CPU、内存、功率、电池续航与硬盘容量。")
    func perform() async throws -> some IntentResult {
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

struct MetricsLoader {
    static func load() async -> DashboardEntry {
        let sampler = SystemMetricsSampler()
        _ = try? sampler.sample()
        try? await Task.sleep(for: .milliseconds(350))
        let system = try? sampler.sample()
        let extra = try? SupplementalMetricsSampler().sample()
        return DashboardEntry(date: .now, cpu: system?.cpuPercent, memory: system?.memoryPercent, memoryUsed: system?.memoryUsedBytes, memoryTotal: system?.memoryTotalBytes, power: extra?.powerWatts, powerLabel: extra?.powerLabel ?? "功率", batteryRemainingHours: extra?.batteryRemainingHours, batteryState: extra?.batteryState ?? .unavailable, diskUsed: extra?.diskUsedBytes, diskTotal: extra?.diskTotalBytes, diskFree: extra?.diskFreeBytes, isExample: false, failed: system == nil && extra == nil)
    }
}

func shortCapacity(_ bytes: UInt64?) -> String {
    guard let bytes else { return "—" }
    let value = Double(bytes)
    if value >= 1_000_000_000_000 { return String(format: "%.1f TB", value / 1_000_000_000_000) }
    return String(format: "%.0f GB", value / 1_000_000_000)
}

struct MetricRing: View {
    let symbol: String
    let fraction: Double?
    let color: Color
    let size: CGFloat
    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.15), lineWidth: 5)
            if let fraction {
                Circle().trim(from: 0, to: min(1, max(0, fraction)))
                    .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Image(systemName: symbol).font(.system(size: size * 0.32, weight: .medium)).foregroundStyle(color)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let fraction: Double?
    let color: Color
    let large: Bool
    var vertical = false
    var body: some View {
        Group {
            if vertical {
                HStack(spacing: 13) {
                    MetricRing(symbol: symbol, fraction: fraction, color: color, size: 36)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.system(size: 12, weight: .medium))
                        Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                    Spacer(minLength: 4)
                    Text(value).font(.system(size: 23, weight: .semibold, design: .rounded))
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
                }
                .padding(.horizontal, 12)
                .frame(height: 58)
                .background(color.opacity(0.055), in: RoundedRectangle(cornerRadius: 13))
            } else {
                column
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)，\(value)，\(detail)")
    }
    private var column: some View {
        VStack(spacing: large ? 4 : 3) {
            MetricRing(symbol: symbol, fraction: fraction, color: color, size: large ? 50 : 40)
            Text(value).font(.system(size: large ? 24 : 19, weight: .semibold, design: .rounded)).monospacedDigit().minimumScaleFactor(0.7).lineLimit(1)
            Text(title).font(.system(size: large ? 12 : 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
            Text(detail).font(.system(size: large ? 10 : 8.5)).foregroundStyle(.secondary).minimumScaleFactor(0.7).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

struct DashboardView: View {
    var entry: DashboardEntry
    var large = false
    var vertical = false
    var onRefresh: (() -> Void)? = nil
    private var diskFraction: Double? {
        guard let used = entry.diskUsed, let total = entry.diskTotal, total > 0 else { return nil }
        return Double(used) / Double(total)
    }
    private func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f%%", value)
    }
    private var memoryDetail: String {
        guard let used = entry.memoryUsed, let total = entry.memoryTotal else { return "—" }
        return String(format: "%.0f / %.0f GiB", Double(used) / 1_073_741_824, Double(total) / 1_073_741_824)
    }
    private var diskDetail: String {
        guard let used = entry.diskUsed, let total = entry.diskTotal else { return "—" }
        return String(format: "%.0f / %.0f GB", Double(used) / 1_000_000_000, Double(total) / 1_000_000_000)
    }
    private var powerTitle: String {
        if entry.batteryState == .battery || entry.powerLabel.contains("电池") { return "电池功率" }
        return entry.power == nil ? "功率" : "输入功率"
    }
    private var powerDetail: String {
        switch entry.batteryState {
        case .battery:
            guard let hours = entry.batteryRemainingHours, hours.isFinite, hours >= 0 else { return "续航估算中" }
            if hours < 0.1 { return "预计还能使用 <0.1 h" }
            return String(format: "预计还能使用 %.1f h", hours)
        case .external:
            return entry.powerLabel.contains("估算") ? "已接电源 · 估算" : "已接电源"
        case .unavailable:
            return "续航暂不可用"
        }
    }
    var body: some View {
        VStack(spacing: vertical ? 10 : large ? 12 : 5) {
            HStack {
                Label(vertical ? "系统状态 · 竖向" : "系统状态", systemImage: "waveform.path.ecg")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Group {
                    if let onRefresh { Button(action: onRefresh) { refreshIcon } }
                    else { Button(intent: RefreshMetricsIntent()) { refreshIcon } }
                }
                .buttonStyle(.plain)
                .background(.primary.opacity(0.055), in: Circle())
                .accessibilityLabel("刷新系统状态")
            }
            if vertical {
                VStack(spacing: 8) { tiles }
            } else if large {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) { tiles }
            } else {
                HStack(alignment: .top, spacing: 10) { tiles }
            }
            Spacer(minLength: 0)
            HStack(spacing: 3) {
                Circle().fill(entry.failed ? Color.orange : Color.secondary.opacity(0.45)).frame(width: 4, height: 4)
                if entry.isExample {
                    Text("示例预览")
                } else if entry.failed {
                    Text("读取失败，请点右上角刷新")
                } else {
                    Text("采样于")
                    Text(entry.date, style: .time).monospacedDigit()
                    Text("· 点 ↻ 更新")
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
        }
        .widgetAccentable(false)
    }
    private var refreshIcon: some View {
        Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold)).frame(width: 20, height: 20)
    }
    @ViewBuilder private var tiles: some View {
        MetricTile(title: "CPU", value: percent(entry.cpu), detail: "全机使用率", symbol: "cpu", fraction: entry.cpu.map { $0 / 100 }, color: .cyan, large: large, vertical: vertical)
        MetricTile(title: "内存", value: percent(entry.memory), detail: memoryDetail, symbol: "memorychip", fraction: entry.memory.map { $0 / 100 }, color: .purple, large: large, vertical: vertical)
        MetricTile(title: powerTitle, value: entry.power.map { String(format: "%.1f W", $0) } ?? "—", detail: powerDetail, symbol: "bolt.fill", fraction: nil, color: .orange, large: large, vertical: vertical)
        MetricTile(title: "硬盘", value: diskFraction.map { String(format: "%.0f%%", $0 * 100) } ?? "—", detail: diskDetail, symbol: "internaldrive", fraction: diskFraction, color: .green, large: large, vertical: vertical)
    }
}
