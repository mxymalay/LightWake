import AppKit

final class QuietProtectionSettings: NSWindowController {
    init(inputStore: ScreenInputRuleStore = ScreenInputRuleStore()) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "轻醒设置"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let title = NSTextField(labelWithString: "关屏与亮屏说明")
        title.font = .systemFont(ofSize: 23, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: "Codex 读取桌面、使用桌面历史记录或执行电脑操作时，可能触发亮屏，尤其是涉及实时截图或窗口检查的任务。")
        let effects = NSTextField(wrappingLabelWithString: "轻醒用于关闭显示器并让后台任务继续运行，无法保证阻止 Codex 或其他软件唤醒显示器。\n\n自动熄屏模式中，屏幕唤醒且桌面已解锁时，轻醒会重新开始 20 秒倒计时。锁屏期间由 macOS 管理显示器，轻醒不执行倒计时关屏，密码和指纹解锁交由系统处理。")
        effects.textColor = .secondaryLabelColor
        let controls = NSTextField(wrappingLabelWithString: "只有你配置的指定按键才会打开对应应用或项目文件夹。若需要解锁，会等你正常解锁后再打开；普通亮屏不选择应用。需要持续亮屏时，请打开“开启屏幕”退出自动熄屏模式。")
        controls.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, detail, effects, controls])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        let tabs = NSTabView(frame: window.contentView!.bounds)
        tabs.autoresizingMask = [.width, .height]
        let input = NSTabViewItem(identifier: "input-rules"); input.label = "按键规则"
        input.view = InputRulesSettingsView(store: inputStore)
        let usage = NSTabViewItem(identifier: "usage"); usage.label = "使用说明"
        let content = NSView(); usage.view = content
        tabs.addTabViewItem(input); tabs.addTabViewItem(usage)
        window.contentView!.addSubview(tabs)
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 26),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20)
        ])
        for field in [detail, effects, controls] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func present() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
