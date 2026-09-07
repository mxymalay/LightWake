import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var guardController: ScreenGuardController?
    var notice: ScreenNotice?
    var onExit: DispatchWorkItem?
    var settingsController: QuietProtectionSettings?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.object(forInfoDictionaryKey: "ScreenGuardRole") as? String == "settings" {
            let settings = QuietProtectionSettings()
            settingsController = settings
            settings.present()
        } else if Bundle.main.object(forInfoDictionaryKey: "ScreenGuardRole") as? String == "on" {
            turnOn()
        } else {
            let controller = ScreenGuardController { NSApp.terminate(nil) }
            guardController = controller
            do { try controller.start() }
            catch { showError(error) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let settingsController { settingsController.present(); return false }
        if let controller = guardController { controller.startCountdown() }
        else { turnOn() }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        settingsController != nil
    }

    private func turnOn() {
        onExit?.cancel()
        notice?.hide()
        do { try ScreenControlStore().write("off") }
        catch { showError(error); return }
        DistributedNotificationCenter.default().postNotificationName(stopNotification, object: nil, userInfo: nil, deliverImmediately: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        p.arguments = ["-u", "-t", "2"]
        try? p.run()
        let banner = ScreenNotice()
        notice = banner
        banner.show(title: "已开启屏幕", subtitle: "自动熄屏模式已关闭，可以正常使用电脑")
        let exit = DispatchWorkItem { NSApp.terminate(nil) }
        onExit = exit
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: exit)
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "无法设置屏幕模式"
        alert.informativeText = error.localizedDescription
        alert.runModal()
        NSApp.terminate(nil)
    }
}

@main
struct ScreenGuardApplication {
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
