import SwiftUI
import WidgetKit
import AppIntents

struct SimpleDashboardView: View {
    @Environment(\.colorScheme) private var systemColorScheme
    let entry: DashboardEntry
    var vertical = false
    var nativeBlur = false
    var onRefresh: (() -> Void)? = nil

    var body: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = vertical ? 8 : 22
            let availableDiameter = vertical
                ? min(geometry.size.width, (geometry.size.height - spacing * 3 - 91) / 4)
                : min((geometry.size.width - spacing * 3) / 4, geometry.size.height - 70)
            let diameter = max(0, min(vertical ? 50 : 56, availableDiameter))

            Group {
                if vertical {
                    VStack(spacing: spacing) { rings(diameter: diameter) }
                } else {
                    HStack(alignment: .top, spacing: spacing) { rings(diameter: diameter) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, vertical ? 0 : 22)
            .overlay(alignment: .topTrailing) { refreshButton }
        }
        // The native blurred container uses a light foreground, like Batteries.
        .environment(\.colorScheme, nativeBlur ? .dark : systemColorScheme)
        .widgetAccentable(false)
    }

    @ViewBuilder private var refreshButton: some View {
        Group {
            if let onRefresh {
                Button(action: onRefresh) { refreshIcon }
            } else {
                Button(intent: RefreshMetricsIntent()) { refreshIcon }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel("刷新系统状态")
    }

    private var refreshIcon: some View {
        Image(systemName: "arrow.clockwise")
            .font(.system(size: 11, weight: .semibold))
            .frame(width: 22, height: 22)
            .contentShape(Circle())
    }

    @ViewBuilder private func rings(diameter: CGFloat) -> some View {
        SimpleStatusRing(title: "CPU", symbol: "cpu",
                         value: percent(entry.cpu), fraction: fraction(entry.cpu),
                         diameter: diameter, vertical: vertical, nativeBlur: nativeBlur, isExample: entry.isExample)
        SimpleStatusRing(title: "内存", symbol: "memorychip", value: percent(entry.memory),
                         fraction: fraction(entry.memory), diameter: diameter, vertical: vertical, nativeBlur: nativeBlur)
        SimpleStatusRing(title: entry.powerLabel, symbol: "bolt.fill", value: powerValue,
                         detail: batteryDetail, fraction: nil, diameter: diameter, vertical: vertical, nativeBlur: nativeBlur)
        SimpleStatusRing(title: "硬盘", symbol: "internaldrive",
                         value: diskFraction.map { percent($0 * 100) } ?? "—",
                         fraction: diskFraction, diameter: diameter, vertical: vertical, nativeBlur: nativeBlur)
    }

    private func fraction(_ percentage: Double?) -> Double? {
        guard let percentage, percentage.isFinite else { return nil }
        return min(1, max(0, percentage / 100))
    }

    private func percent(_ percentage: Double?) -> String {
        guard let fraction = fraction(percentage) else { return "—" }
        return String(format: "%.0f%%", fraction * 100)
    }

    private var diskFraction: Double? {
        guard let used = entry.diskUsed, let total = entry.diskTotal, total > 0 else { return nil }
        return min(1, max(0, Double(used) / Double(total)))
    }

    private var validPower: Double? {
        guard let watts = entry.power, watts.isFinite, watts >= 0 else { return nil }
        return watts
    }

    private var powerValue: String {
        validPower.map { String(format: "%.1f W", $0) } ?? "—"
    }

    private var batteryDetail: String? {
        switch entry.batteryState {
        case .battery:
            guard let hours = entry.batteryRemainingHours, hours.isFinite, hours >= 0 else {
                return "估算中"
            }
            return hours < 0.1 ? "预计<0.1 h" : String(format: "预计%.1f h", hours)
        case .external:
            return entry.powerLabel.contains("估算") ? "已接电·估算" : "已接电"
        case .unavailable:
            return entry.powerLabel.contains("估算") ? "估算" : nil
        }
    }
}

private struct SimpleStatusRing: View {
    let title: String
    let symbol: String
    let value: String
    var detail: String? = nil
    let fraction: Double?
    let diameter: CGFloat
    let vertical: Bool
    let nativeBlur: Bool
    var isExample = false

    private var strokeWidth: CGFloat { diameter * 0.115 }
    private var textWidth: CGFloat { vertical ? max(88, diameter) : diameter }
    private let ringColor = Color(red: 0.28, green: 0.87, blue: 0.37)

    var body: some View {
        VStack(spacing: vertical ? 3 : 7) {
            ZStack {
                // A nil fraction (including watts, which have no maximum) leaves only the track.
                Circle().strokeBorder(nativeBlur ? Color.white.opacity(0.13) : ringColor.opacity(0.17), lineWidth: strokeWidth)
                if let fraction, fraction.isFinite, fraction > 0 {
                    Circle()
                        .inset(by: strokeWidth / 2)
                        .trim(from: 0, to: min(1, max(0, fraction)))
                        .stroke(ringColor, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Image(systemName: symbol)
                    .font(.system(size: diameter * 0.34, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .frame(width: diameter, height: diameter)

            VStack(spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(value)
                        .font(.system(size: vertical ? 15 : 16.5, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                    if isExample {
                        Text("示例")
                            .font(.system(size: 6.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                if let detail {
                    Text(detail)
                        .font(.system(size: vertical ? 7.5 : 8, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(width: textWidth)
        }
        .frame(width: textWidth)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, value, detail, isExample ? "示例" : nil].compactMap { $0 }.joined(separator: "，"))
    }
}
