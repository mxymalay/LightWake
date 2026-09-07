import AppKit

@main
enum QuietSettingsLayoutTests {
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quiet-settings-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = QuietProtectionManager(directory: root, resources: root, launchAgents: root,
            run: { _ in preconditionFailure("Rendering preferences must never start a helper") })
        let controller = QuietProtectionSettings(manager: manager, inputStore: ScreenInputRuleStore(fileURL: root.appendingPathComponent("input-rules.json")))
        let window = controller.window!
        precondition(!window.isVisible && !manager.isEnabled, "New settings must stay off, without opening the desktop")
        let content = window.contentView!
        content.layoutSubtreeIfNeeded()
        var labels = 0
        var switches = 0
        func inspect(_ view: NSView) {
            if let button = view as? NSButton, button.title == "启用 Codex 防亮屏保护" || button.title == "启用这条规则" {
                precondition(button.state == .off, "New settings must visibly show protection off")
                switches += 1
            }
            if let field = view as? NSTextField {
                let frame = field.convert(field.bounds, to: content)
                precondition(content.bounds.insetBy(dx: -1, dy: -1).contains(frame), "Settings text escaped the window")
                precondition(field.frame.height >= field.fittingSize.height - 1, "Settings text was vertically truncated")
                labels += 1
            }
            for child in view.subviews { inspect(child) }
        }
        let tabs = content.subviews.first { $0 is NSTabView } as! NSTabView
        for item in tabs.tabViewItems {
            tabs.selectTabViewItem(item)
            content.layoutSubtreeIfNeeded()
            inspect(item.view!)
        }
        precondition(labels >= 5 && switches == 2)
        precondition(!FileManager.default.fileExists(atPath: root.path), "Layout check installed a feature or wrote preferences")
        print("PASS: settings switch off, no installation or visible window, all \(labels) text labels fit.")
    }
}
