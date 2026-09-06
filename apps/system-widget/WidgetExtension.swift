import SwiftUI
import WidgetKit

struct MetricsProvider: TimelineProvider {
    func placeholder(in context: Context) -> DashboardEntry { .example }
    func getSnapshot(in context: Context, completion: @escaping (DashboardEntry) -> Void) {
        if context.isPreview { completion(.example); return }
        Task { completion(await MetricsLoader.load()) }
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<DashboardEntry>) -> Void) {
        Task {
            let sample = await MetricsLoader.load()
            completion(Timeline(entries: [sample], policy: .after(sample.date.addingTimeInterval(15 * 60))))
        }
    }
}

struct SystemStatusWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: DashboardEntry
    var body: some View {
        DashboardView(entry: entry, large: family == .systemLarge)
            .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct SystemStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: metricsWidgetKind, provider: MetricsProvider()) { entry in SystemStatusWidgetView(entry: entry) }
            .configurationDisplayName("系统状态")
            .description("CPU、内存、功率、电池预计续航与硬盘容量。点刷新获取最新采样。")
            .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct VerticalSystemStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: verticalMetricsWidgetKind, provider: MetricsProvider()) { entry in
            DashboardView(entry: entry, large: true, vertical: true)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("系统状态 · 竖向")
        .description("从上到下查看 CPU、内存、功率与硬盘。电池供电时显示预计剩余使用小时数。")
        .supportedFamilies([.systemLarge])
    }
}

struct SimpleHorizontalSystemStatusWidget: Widget {
    var body: some WidgetConfiguration {
        Self.configuration(nativeBlur: false)
    }
    static func configuration(nativeBlur: Bool) -> some WidgetConfiguration {
        StaticConfiguration(kind: "SystemStatusSimpleHorizontal", provider: MetricsProvider()) { entry in
            SimpleDashboardView(entry: entry, nativeBlur: nativeBlur)
                .containerBackground(for: .widget) {
                    if nativeBlur { Color.clear }
                    else { Rectangle().fill(.fill.tertiary) }
                }
        }
        .configurationDisplayName("系统状态 · 简洁横排")
        .description("绿色状态圆环横向排列，中心是图标，下方是数值，右上角可刷新。")
        .supportedFamilies([.systemMedium])
    }
}

// This wrapper uses the native blurred background also used by Batteries.
// The local compiler overlay only declares the installed system API; it does
// not ship a replacement WidgetKit. Earlier systems keep the standard widgets.
@available(macOS 26.0, *)
struct GlassSimpleHorizontalSystemStatusWidget: Widget {
    var body: some WidgetConfiguration {
        SimpleHorizontalSystemStatusWidget.configuration(nativeBlur: true).preferredBackgroundStyle(.blur)
    }
}

@main
struct SystemStatusWidgets: WidgetBundle {
    var body: some Widget {
        SystemStatusWidget()
        VerticalSystemStatusWidget()
        simpleWidgets
    }

    // Erase both availability branches through the same builder entry point.
    // WidgetBundleBuilder only accepts #available without an else clause.
    private var simpleWidgets: some Widget {
        if #available(macOS 26.0, *) {
            return WidgetBundleBuilder.buildOptional(WidgetBundleBuilder.buildLimitedAvailability(
                WidgetBundleBuilder.buildBlock(GlassSimpleHorizontalSystemStatusWidget())
            ))
        } else {
            return WidgetBundleBuilder.buildOptional(WidgetBundleBuilder.buildLimitedAvailability(
                WidgetBundleBuilder.buildBlock(SimpleHorizontalSystemStatusWidget())
            ))
        }
    }
}
