import AppKit

@main
enum QuietSettingsLayoutTests {
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quiet-settings-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = QuietProtectionSettings(inputStore: ScreenInputRuleStore(fileURL: root.appendingPathComponent("input-rules.json")))
        let window = controller.window!
        precondition(!window.isVisible, "Layout checks must not open the desktop")
        let content = window.contentView!
        content.layoutSubtreeIfNeeded()
        var labels = 0
        var switches = 0
        var wakeNoticeFound = false
        func inspect(_ view: NSView) {
            if let button = view as? NSButton {
                precondition(!button.title.contains("防亮屏"), "Removed protection must have no settings control")
                if button.title == "启用这条规则" {
                    precondition(button.state == .off, "New input rules must remain disabled")
                    switches += 1
                }
            }
            if let field = view as? NSTextField {
                if field.stringValue.contains("Codex") && field.stringValue.contains("桌面历史记录") && field.stringValue.contains("可能触发亮屏") {
                    wakeNoticeFound = true
                }
                let frame = field.convert(field.bounds, to: content)
                precondition(content.bounds.insetBy(dx: -1, dy: -1).contains(frame), "Settings text escaped the window")
                precondition(field.frame.height >= field.fittingSize.height - 1, "Settings text was vertically truncated")
                labels += 1
            }
            for child in view.subviews { inspect(child) }
        }
        let tabs = content.subviews.first { $0 is NSTabView } as! NSTabView
        precondition(tabs.tabViewItems.map(\.label) == ["按键规则", "使用说明"])
        for item in tabs.tabViewItems {
            tabs.selectTabViewItem(item)
            content.layoutSubtreeIfNeeded()
            inspect(item.view!)
        }
        precondition(labels >= 5 && switches == 1 && wakeNoticeFound)
        precondition(!FileManager.default.fileExists(atPath: root.path), "Layout check installed a feature or wrote preferences")
        print("PASS: Codex wake notice present, protection control removed, no visible window or state changes, all \(labels) text labels fit.")
    }
}
