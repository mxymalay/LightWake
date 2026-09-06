import SwiftUI
import WidgetKit

@main
struct SystemStatusApp: App {
    var body: some Scene {
        WindowGroup("系统状态") { SetupView() }
            .windowResizability(.contentSize)
    }
}

struct SetupView: View {
    @State private var entry = DashboardEntry.loading
    @State private var vertical = false
    @State private var simple = true
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("系统状态小组件").font(.title2.bold())
            Picker("样式", selection: $simple) {
                Text("详细版").tag(false)
                Text("简洁版").tag(true)
            }.pickerStyle(.segmented)
            if !simple {
                Picker("布局", selection: $vertical) {
                    Text("横向").tag(false)
                    Text("竖向").tag(true)
                }.pickerStyle(.segmented)
            }
            Group {
                if simple {
                    SimpleDashboardView(entry: entry, nativeBlur: true, onRefresh: refresh)
                } else {
                    DashboardView(entry: entry, large: vertical, vertical: vertical, onRefresh: refresh)
                }
            }.padding(16).frame(width: 364, height: !simple && vertical ? 354 : 190)
                .background {
                    if simple { GlassPreviewBackground() }
                    else { RoundedRectangle(cornerRadius: 22).fill(.regularMaterial) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 22))
            Text("打开通知中心 → 编辑小组件 → 系统状态\n可选详细横排、详细竖排、简洁横排。")
                .font(.system(size: 13)).lineSpacing(5)
            Text("数值显示采样时刻的状态。点击右上角 ↻ 可更新，自动刷新由 macOS 安排。预计续航随负载变化；插电时显示「已接电源」。简洁版背景透出桌面壁纸；此处预览透出窗口后方内容。竖向版使用原生大号尺寸。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("刷新预览", action: refresh)
                Spacer()
                Button("完成") { NSApplication.shared.terminate(nil) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 412)
        .task { entry = await MetricsLoader.load(); WidgetCenter.shared.reloadAllTimelines() }
    }
    private func refresh() {
        Task { entry = await MetricsLoader.load(); WidgetCenter.shared.reloadAllTimelines() }
    }
}

private struct GlassPreviewBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
