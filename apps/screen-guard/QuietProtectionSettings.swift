import AppKit

final class QuietProtectionSettings: NSWindowController {
    private let manager: QuietProtectionManager
    private let toggle = NSButton(checkboxWithTitle: "启用 Codex 防亮屏保护", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private var timer: Timer?

    init(manager: QuietProtectionManager = QuietProtectionManager(), inputStore: ScreenInputRuleStore = ScreenInputRuleStore()) {
        self.manager = manager
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "轻醒设置"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let title = NSTextField(labelWithString: "让屏幕安静休息")
        title.font = .systemFont(ofSize: 23, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: "自动熄屏仍可使用。锁屏期间，轻醒不再因倒计时到期而关屏，身份验证交由 macOS 处理；正常解锁后才重新开始桌面倒计时。")
        let effects = NSTextField(wrappingLabelWithString: "普通软件也能向 macOS 请求亮屏，轻醒目前不能统一拦截所有软件。通过冻结电脑操作服务防亮屏的旧方案曾伴随指纹解锁卡住，已撤下。\n\n需要操作桌面的任务可以先检查熄屏和锁屏状态，暂缓桌面操作；代码、构建等后台工作可继续。\n\n按键规则、应用和项目选择仍可使用。轻醒不会自动解锁，也不会替你开启屏幕历史记录。")
        effects.textColor = .secondaryLabelColor
        let choice = NSTextField(wrappingLabelWithString: "开关暂不可开启。旧版已开启的保护仍可关闭；新版本启动时也会关闭旧选择。")
        choice.textColor = .secondaryLabelColor
        toggle.target = self
        toggle.action = #selector(toggleProtection)
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 12)
        let stack = NSStackView(views: [title, detail, toggle, effects, choice, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        let tabs = NSTabView(frame: window.contentView!.bounds)
        tabs.autoresizingMask = [.width, .height]
        let input = NSTabViewItem(identifier: "input-rules"); input.label = "按键规则"
        input.view = InputRulesSettingsView(store: inputStore)
        let protection = NSTabViewItem(identifier: "quiet-protection"); protection.label = "防亮屏保护"
        let content = NSView(); protection.view = content
        tabs.addTabViewItem(input); tabs.addTabViewItem(protection)
        window.contentView!.addSubview(tabs)
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 26),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20)
        ])
        for field in [detail, effects, choice, status] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        refresh()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func present() {
        refresh()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    @objc private func toggleProtection() {
        do {
            if toggle.state == .on {
                _ = try manager.enable(confirmed: true)
            } else {
                try manager.disable()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "未能更改防亮屏保护"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        refresh()
    }

    private func refresh() {
        toggle.state = manager.isEnabled ? .on : .off
        toggle.isEnabled = manager.isEnabled
        status.stringValue = manager.statusText
    }

    deinit { timer?.invalidate() }
}
