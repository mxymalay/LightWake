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
        let detail = NSTextField(wrappingLabelWithString: "部分 Codex 后台检查会唤醒显示器。开启保护后，轻醒会在熄屏、锁屏或自动熄屏模式中暂停电脑操作服务。")
        let effects = NSTextField(wrappingLabelWithString: "开启前请了解：\n• 桌面操作与屏幕历史记录会暂停，相关请求可能超时。\n• 屏幕历史可能停止，需要你在 Codex 设置中手动重新开启。\n• 恢复正常使用电脑后，轻醒只恢复服务进程，不会替你开启历史记录。\n• 这是本地防护，无法保证拦住所有来源的亮屏。")
        effects.textColor = .secondaryLabelColor
        let choice = NSTextField(wrappingLabelWithString: "默认关闭。只有你确认开启后才安装后台保护，并记住你的选择。")
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
                let alert = NSAlert()
                alert.messageText = "开启 Codex 防亮屏保护？"
                alert.informativeText = "保护期间电脑操作会暂停，相关请求可能超时。屏幕历史记录可能停止且无法自动恢复，需要你在 Codex 设置中重新开启。轻醒不会替你开启历史记录。"
                alert.alertStyle = .warning
                // Cancel is the default button; pressing Return is not consent.
                alert.addButton(withTitle: "取消")
                alert.addButton(withTitle: "了解副作用并开启")
                let confirmed = alert.runModal() == .alertSecondButtonReturn
                _ = try manager.enable(confirmed: confirmed)
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
        status.stringValue = manager.statusText
    }

    deinit { timer?.invalidate() }
}
