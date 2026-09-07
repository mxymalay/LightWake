import AppKit
import OSLog

final class AppDelegate: NSObject, NSApplicationDelegate {
    var guardController: ScreenGuardController?
    var notice: ScreenNotice?
    var onExit: DispatchWorkItem?
    var buttonController: ScreenButtonController?
    var settingsController: QuietProtectionSettings?
    var inputRuntime: ScreenInputRuntime?
    private var receivedURL = false
    private var role: String { Bundle.main.object(forInfoDictionaryKey: "ScreenGuardRole") as? String ?? "off" }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if role == "controller" {
            let controller = buttonController ?? ScreenButtonController()
            buttonController = controller
            if CommandLine.arguments.contains("--listen") {
                inputRuntime = ScreenInputRuntime(controller: controller)
                inputRuntime?.start()
            } else if !receivedURL && notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool == true {
                controller.press()
            }
        } else if role == "on" {
            turnOn()
        } else if role == "settings" {
            let settings = QuietProtectionSettings()
            settingsController = settings
            settings.present()
        } else {
            let controller = ScreenGuardController { NSApp.terminate(nil) }
            guardController = controller
            do { try controller.start() }
            catch { showError(error) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if role == "controller" {
            buttonController?.press()
            return false
        }
        if let settingsController { settingsController.present(); return false }
        if let controller = guardController { controller.startCountdown() }
        else { turnOn() }
        return false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard role == "controller" else { return }
        receivedURL = true
        if buttonController == nil { buttonController = ScreenButtonController() }
        for url in urls {
            guard let id = ScreenInputContract.mappedRuleID(from: url), let rule = ScreenInputRuleStore().mappedRule(id) else { continue }
            buttonController?.perform(rule)
        }
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
        // Retire an old opt-in without installing a job, signalling a service,
        // activating an application or changing authentication/display state.
        do { try QuietProtectionManager().disable() }
        catch { Logger(subsystem: "local.xy.screen-guard", category: "quiet-protection").error("Could not disable legacy protection: \(error.localizedDescription, privacy: .public)") }
        if CommandLine.arguments.contains("--request-input-access") {
            _ = CGRequestListenEventAccess()
            return
        }
        let application = NSApplication.shared
        let isController = Bundle.main.object(forInfoDictionaryKey: "ScreenGuardRole") as? String == "controller"
        application.setActivationPolicy(isController ? .prohibited : .accessory)
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
