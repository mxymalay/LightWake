import AppKit
import OSLog
import ServiceManagement

/// 轻醒的唯一入口。
///
/// 合成单 app 之后不再有"角色"这回事 —— 同一个进程既是熄屏模式、也是设置面板、
/// 也是按键规则的执行者，靠**怎么被唤起的**来分派：
///
/// - 双击桌面上的「轻醒」→ `applicationShouldHandleReopen` → **切换熄屏模式**
/// - 键盘 / 鼠标 / 外部映射工具打开 `lightwake://trigger/<规则 id>` → `application(_:open:)`
/// - `lightwake://toggle` → 切换熄屏模式（给将来可能加的轻量启动器留的口子）
/// - `--listen` → 只跑按键监听的进程（由 launchd 拉起，不装菜单栏图标）
/// - `--request-input-access` → 申请"输入监控"权限后立刻退出
///
/// 进程常驻（`LSUIElement`，装到 /Applications 后随登录启动），菜单栏图标一直在，
/// 设置从那里进。这是有意为之：以前熄屏模式一结束进程就退出，桌面上必须摆四个
/// 双击目标才够用；现在只有一个按钮，其余入口收进菜单栏。
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var guardController: ScreenGuardController?
    private var settings: QuietProtectionSettings?
    private var buttonController: ScreenButtonController?
    private var inputRuntime: ScreenInputRuntime?
    private var statusItem: NSStatusItem?
    /// 最近一次处理 URL 的时刻。冷启动时 macOS 会先送 URL 再送 reopen，
    /// 那一下 reopen 不是"用户双击了按钮"，不能让它把刚做的动作又切回去。
    private var lastURLHandling: TimeInterval = -.infinity
    private let listening = CommandLine.arguments.contains("--listen")
    private let logger = Logger(subsystem: "local.xy.lightwake", category: "lifecycle")

    func applicationDidFinishLaunching(_ notification: Notification) {
        if listening {
            // launchd 拉起的监听进程：不要菜单栏图标，也不要登录项
            inputRuntime = ScreenInputRuntime(controller: button())
            inputRuntime?.start()
            return
        }
        installMenu()
        registerAsLoginItem()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard ProcessInfo.processInfo.systemUptime - lastURLHandling > 1 else { return false }
        toggle()
        return false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        lastURLHandling = ProcessInfo.processInfo.systemUptime
        for url in urls {
            if url.scheme == "lightwake", url.host == "toggle" {
                toggle()
                continue
            }
            guard let id = ScreenInputContract.mappedRuleID(from: url),
                  let rule = ScreenInputRuleStore().mappedRule(id) else { continue }
            button().perform(rule)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 关掉设置窗口不该把轻醒带走
        false
    }

    // MARK: - 熄屏模式

    private var guardRunning: Bool { guardController?.running == true }

    /// 一个动作，两个方向。
    ///
    /// 「关闭屏幕」「开启屏幕」「轻醒按键」三个入口本来就在问同一个问题 ——
    /// `ScreenButtonState.action` 就是那个问题本身，它们只是各自只会走一边。
    /// 合成单 app 之后这里也走同一个函数，免得"该关还是该开"出现第二份判断。
    ///
    /// 注意它不是单纯取反：屏幕已熄或会话已锁时它会选「开」。那是刻意的安全偏置 ——
    /// 宁可多亮一次屏，也不要在用户看不到的时候开始倒计时关屏。
    private func toggle() {
        switch ScreenButtonState.action(guardActive: guardRunning,
                                        session: ScreenGuardController.currentSession(),
                                        displayAsleep: CGDisplayIsAsleep(CGMainDisplayID()) != 0) {
        case .startCountdown: enterOffMode()
        case .keepScreenOn: exitOffMode()
        case .none: break
        }
    }

    private func enterOffMode() {
        guard !guardRunning else { return }
        // 每次进入都用新的控制器：它的生命周期就是"一段熄屏模式"，
        // 这样 stop() 里那套取消逻辑（定时器、通知观察者、电源断言）不用考虑复用。
        let controller = ScreenGuardController(finished: { [weak self] in
            self?.guardController = nil
            self?.refreshMenu()
        })
        guardController = controller
        do {
            try controller.start()
        } catch {
            guardController = nil
            report(error, title: "无法进入熄屏模式")
        }
        refreshMenu()
    }

    private func exitOffMode() {
        guardController?.turnOn()
        guardController = nil
        refreshMenu()
    }

    // MARK: - 按键规则

    private func button() -> ScreenButtonController {
        if let buttonController { return buttonController }
        let controller = ScreenButtonController(
            guardRunning: { [weak self] in self?.guardRunning ?? false },
            openApplication: { [weak self] identifier, activates, completion in
                // 进/出熄屏模式在单 app 里是进程内动作 —— 以前它们是两个独立的
                // bundle，靠 openApplication 启动；现在拦下来直接在本进程执行。
                switch identifier {
                case ScreenInputContract.enterOffModeCommand:
                    self?.enterOffMode()
                    completion(nil)
                case ScreenInputContract.exitOffModeCommand:
                    self?.exitOffMode()
                    completion(nil)
                default:
                    // 规则的目标可能是任意一个别人的应用，照旧交给系统打开。
                    // 这里直接用控制器自己的实现，不另写一份。
                    ScreenButtonController.openApplication(identifier: identifier, activates: activates, completion: completion)
                }
            })
        buttonController = controller
        return controller
    }

    // MARK: - 菜单栏

    private func installMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        refreshMenu()
    }

    private func refreshMenu() {
        guard let item = statusItem else { return }
        let running = guardRunning
        item.button?.image = NSImage(systemSymbolName: running ? "display.trianglebadge.exclamationmark" : "display",
                                     accessibilityDescription: "轻醒")
        item.button?.toolTip = running ? "轻醒：熄屏模式进行中" : "轻醒"

        let menu = NSMenu()
        let toggle = NSMenuItem(title: running ? "开启屏幕（退出熄屏模式）" : "关闭屏幕",
                                action: #selector(toggleFromMenu), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        let sleep = NSMenuItem(title: "立即关闭屏幕", action: #selector(sleepNow), keyEquivalent: "")
        sleep.target = self
        sleep.isEnabled = running
        menu.addItem(sleep)

        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "轻醒设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出轻醒", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
    }

    @objc private func toggleFromMenu() { toggle() }

    @objc private func sleepNow() { guardController?.sleepAgain() }

    @objc private func openSettings() {
        // 设置面板就在本进程里 —— 以前它是个独立 app，还得去找兄弟 bundle。
        // 进设置不再顺手退出熄屏模式；用户想退，菜单里那条就在上面。
        if settings == nil { settings = QuietProtectionSettings() }
        NSApp.activate(ignoringOtherApps: true)
        settings?.present()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - 登录项

    private func registerAsLoginItem() {
        // SMAppService 记的是 bundle 路径。从构建目录跑会注册一个临时路径，
        // 所以只在真的装到 /Applications 之后才注册。
        guard Bundle.main.bundlePath.hasPrefix("/Applications/") else {
            logger.info("不在应用程序目录，跳过登录项注册")
            return
        }
        let service = SMAppService.mainApp
        guard service.status != .enabled else { return }
        do { try service.register() }
        catch { logger.error("登录项注册失败：\(error.localizedDescription, privacy: .public)") }
    }

    private func report(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}

@main
struct LightWakeApplication {
    static func main() {
        // Retire an old opt-in without installing a job, signalling a service,
        // activating an application or changing authentication/display state.
        do { try QuietProtectionManager().disable() }
        catch { Logger(subsystem: "local.xy.lightwake", category: "quiet-protection").error("Could not disable legacy protection: \(error.localizedDescription, privacy: .public)") }
        if CommandLine.arguments.contains("--request-input-access") {
            _ = CGRequestListenEventAccess()
            return
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
