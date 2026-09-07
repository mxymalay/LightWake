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
        let controller = QuietProtectionSettings(manager: manager)
        let window = controller.window!
        precondition(!window.isVisible && !manager.isEnabled, "New settings must stay off, without opening the desktop")
        let content = window.contentView!
        content.layoutSubtreeIfNeeded()
        var labels = 0
        var switches = 0
        func inspect(_ view: NSView) {
            if let button = view as? NSButton {
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
        inspect(content)
        precondition(labels >= 5 && switches == 1)
        precondition(!FileManager.default.fileExists(atPath: root.path), "Layout check installed a feature or wrote preferences")
        print("PASS: settings switch off, no installation or visible window, all \(labels) text labels fit.")
    }
}
