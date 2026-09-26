import AppKit
import IOKit.pwr_mgt
import OSLog

let stopNotification = Notification.Name("local.xy.screen-guard.turn-on")

final class NoticeView: NSView {
    let title = NSTextField(labelWithString: "")
    let subtitle = NSTextField(labelWithString: "")
    let footnote = NSTextField(labelWithString: "")
    let symbol = NSImageView()

    /// 横幅高度跟着内容走：带补充行（进熄屏模式的提醒）才用加高版，
    /// 两行提示不留第三行的空，免得下面凭空缺一块。
    static func bannerHeight(hasFootnote: Bool) -> CGFloat { hasFootnote ? 132 : 112 }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.14, alpha: 0.97).cgColor
        layer?.cornerRadius = 20
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        symbol.contentTintColor = NSColor(calibratedRed: 0.42, green: 0.78, blue: 1, alpha: 1)
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.textColor = .white
        subtitle.font = .systemFont(ofSize: 15)
        subtitle.textColor = NSColor.white.withAlphaComponent(0.78)
        footnote.font = .systemFont(ofSize: 13)
        footnote.textColor = NSColor.white.withAlphaComponent(0.55)
        addSubview(symbol)
        addSubview(title)
        addSubview(subtitle)
        addSubview(footnote)
        layoutContent(hasFootnote: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    private func layoutContent(hasFootnote: Bool) {
        symbol.frame = NSRect(x: 24, y: hasFootnote ? 46 : 36, width: 40, height: 40)
        title.frame = NSRect(x: 84, y: hasFootnote ? 79 : 59, width: 420, height: 30)
        subtitle.frame = NSRect(x: 84, y: hasFootnote ? 45 : 25, width: 420, height: 25)
        footnote.frame = NSRect(x: 84, y: 16, width: 420, height: 20)
    }

    func update(title: String, subtitle: String, footnote: String? = nil, countdown: Bool = false) {
        self.title.stringValue = title
        self.subtitle.stringValue = subtitle
        self.footnote.stringValue = footnote ?? ""
        self.footnote.isHidden = footnote == nil
        layoutContent(hasFootnote: footnote != nil)
        symbol.image = NSImage(systemSymbolName: countdown ? "timer" : "display", accessibilityDescription: nil)
        symbol.contentTintColor = countdown ? .systemOrange : NSColor(calibratedRed: 0.42, green: 0.78, blue: 1, alpha: 1)
    }
}

protocol ScreenNoticing {
    func show(title: String, subtitle: String, countdown: Bool)
    func show(title: String, subtitle: String, footnote: String?, countdown: Bool)
    func showCountdown(seconds: Int)
    func hide()
}

extension ScreenNoticing {
    /// 没实现补充行版本的类型走这条转发：丢掉 footnote，按两行提示显示。
    func show(title: String, subtitle: String, footnote: String?, countdown: Bool) {
        show(title: title, subtitle: subtitle, countdown: countdown)
    }
}

/// 屏幕上出现的那些字。
///
/// 抽成常量不是为了复用，是为了**让测试能盯着它们**。3.0 把「关闭屏幕 / 开启屏幕 /
/// 轻醒按键 / 轻醒设置」四个双击目标合成一个「轻醒」，要是提示语里还让人去双击那个
/// 已经不存在的东西，用户就会照着一个空位置点 —— 这个错合并时真犯过一次，
/// 而当时的测试全都在断言"提示显示出来了没有"，没有一条在读它写了什么。
enum ScreenNoticeText {
    static let initialReminderTitle = "屏幕将在 5 秒后关闭"
    static let initialReminderSubtitle = "双击桌面上的「轻醒」可取消"
    /// 进熄屏模式时把"合盖不休"说在明处（README「合盖不休」一节），免得合盖之后
    /// 以为已经收工了。桌面按钮的 Finder 注释和安装说明里是同一件事。
    static let initialReminderFootnote = "合盖后电脑仍保持运行，后台任务继续"
    static let wakeReminderTitle = "屏幕将临时亮起 20 秒"
    static let wakeReminderSubtitle = "需要继续使用？请双击桌面上的「轻醒」"
    /// 退出熄屏模式时的回执。旧版由「开启屏幕.app」自己亮这一条。
    static let turnedOnTitle = "已开启屏幕"
    static let turnedOnSubtitle = "自动熄屏模式已关闭，可以正常使用电脑"
    /// 全部句子，给"不能指向已退役入口"那条测试用。
    static let all = [
        initialReminderTitle, initialReminderSubtitle, initialReminderFootnote,
        wakeReminderTitle, wakeReminderSubtitle,
        turnedOnTitle, turnedOnSubtitle,
    ]
}

/// 一条"亮一下就走"的提示。
///
/// 退出熄屏模式要告诉用户"屏幕开了"。旧版是「开启屏幕.app」亮一条横幅、整个 app
/// 1.5 秒后退出，横幅跟着进程一起消失；轻醒现在是常驻进程，没有"跟着退出"这回事，
/// 得自己收 —— 于是带出两个时序问题：
///
///  1. 用户在这 1.5 秒内又进了熄屏模式，迟到的 hide 不能把新的倒计时提示一起藏掉
///  2. 连点两次退出，只有最后一条该决定什么时候收
///
/// 定时器是注入的，测试里可以立刻把时间推到"该收"的那一刻，不用真的等 1.5 秒。
final class TransientNotice {
    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> Void

    private let notice: ScreenNoticing
    private let schedule: Scheduler
    /// 当前挂着的那次收走。谁手里的令牌还在，谁才有权 hide —— 被取消或被顶替的
    /// 回调会发现令牌已经过时，安静退出。
    private var pending: UUID?

    init(notice: ScreenNoticing, schedule: @escaping Scheduler = TransientNotice.afterDelay) {
        self.notice = notice
        self.schedule = schedule
    }

    static func afterDelay(seconds: TimeInterval, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func show(title: String, subtitle: String, seconds: TimeInterval) {
        cancel()
        let token = UUID()
        pending = token
        notice.show(title: title, subtitle: subtitle, footnote: nil, countdown: false)
        schedule(seconds) { [weak self] in
            guard let self, self.pending == token else { return }
            self.pending = nil
            self.notice.hide()
        }
    }

    /// 别的东西要占用这块地方（熄屏模式的提示条）之前必须先取消。
    func cancel() { pending = nil }
}

final class CornerCountdownView: NSView {
    let number = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.06, green: 0.13, blue: 0.17, alpha: 0.96).cgColor
        layer?.cornerRadius = 16
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(calibratedRed: 0.40, green: 0.88, blue: 0.81, alpha: 0.32).cgColor
        number.font = .monospacedDigitSystemFont(ofSize: 36, weight: .medium)
        number.textColor = NSColor(calibratedRed: 0.65, green: 0.96, blue: 0.89, alpha: 1)
        number.alignment = .center
        number.setAccessibilityLabel("自动熄屏倒计时")
        addSubview(number)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func update(seconds: Int) {
        number.stringValue = String(seconds)
        number.setAccessibilityValue("\(seconds) 秒")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height = number.intrinsicContentSize.height
        number.frame = NSRect(x: 4, y: (bounds.height - height) / 2, width: bounds.width - 8, height: height)
    }
}

private final class NoticeSurface: NSView {
    let banner: NoticeView
    let counter: CornerCountdownView

    override init(frame frameRect: NSRect) {
        banner = NoticeView(frame: NSRect(origin: .zero, size: frameRect.size))
        counter = CornerCountdownView(frame: NSRect(origin: .zero, size: frameRect.size))
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = 20
        banner.autoresizingMask = [.width, .height]
        counter.autoresizingMask = [.width, .height]
        addSubview(banner)
        addSubview(counter)
        showBanner()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func showBanner() {
        banner.alphaValue = 1
        counter.alphaValue = 0
        layer?.cornerRadius = 20
    }

    func transition(progress: Double) {
        banner.alphaValue = max(0, 1 - progress * 3)
        counter.alphaValue = min(1, max(0, (progress - 0.2) / 0.8))
        layer?.cornerRadius = 20 - 4 * progress
    }
}

final class ScreenNotice: ScreenNoticing {
    private let bannerWidth: CGFloat = 530
    private let cornerSize = NSSize(width: 72, height: 64)
    var panels: [NSPanel] = []
    private(set) var shownTitle: String?
    private(set) var shownSeconds: Int?
    private var compact = false
    private var movement: Timer?

    func show(title: String, subtitle: String, countdown: Bool) {
        show(title: title, subtitle: subtitle, footnote: nil, countdown: countdown)
    }

    func show(title: String, subtitle: String, footnote: String? = nil, countdown: Bool = false) {
        stopMovement()
        compact = false
        shownTitle = title
        shownSeconds = nil
        let size = NSSize(width: bannerWidth, height: NoticeView.bannerHeight(hasFootnote: footnote != nil))
        let screens = NSScreen.screens
        preparePanels(screens: screens, contentSize: size)
        for (panel, screen) in zip(panels, screens) {
            guard let content = panel.contentView as? NoticeSurface else { continue }
            content.banner.update(title: title, subtitle: subtitle, footnote: footnote, countdown: countdown)
            content.showBanner()
            panel.setFrame(bannerFrame(screen: screen, size: size), display: true)
            panel.orderFrontRegardless()
        }
    }

    func showCountdown(seconds: Int) {
        let screens = NSScreen.screens
        let alreadyCompact = compact && panels.count == screens.count
        preparePanels(screens: screens, contentSize: NSSize(width: bannerWidth, height: NoticeView.bannerHeight(hasFootnote: false)))
        shownTitle = nil
        shownSeconds = seconds
        compact = true
        for panel in panels {
            (panel.contentView as? NoticeSurface)?.counter.update(seconds: seconds)
            panel.orderFrontRegardless()
        }
        if alreadyCompact {
            if movement == nil {
                for (panel, screen) in zip(panels, screens) {
                    panel.setFrame(cornerFrame(screen: screen), display: true)
                }
            }
            return
        }
        moveToCorner(screens: screens)
    }

    private func preparePanels(screens: [NSScreen], contentSize: NSSize) {
        if panels.count != screens.count {
            stopMovement()
            panels.forEach { $0.orderOut(nil) }
            panels = screens.map { screen in
                let p = NSPanel(contentRect: bannerFrame(screen: screen, size: contentSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                p.isFloatingPanel = true
                p.hidesOnDeactivate = false
                p.becomesKeyOnlyIfNeeded = true
                p.isReleasedWhenClosed = false
                p.level = .floating
                p.backgroundColor = .clear
                p.isOpaque = false
                p.hasShadow = true
                p.ignoresMouseEvents = true
                p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
                p.contentView = NoticeSurface(frame: NSRect(origin: .zero, size: contentSize))
                return p
            }
        }
    }

    private func bannerFrame(screen: NSScreen, size: NSSize) -> NSRect {
        let frame = screen.visibleFrame
        return NSRect(x: frame.midX - size.width / 2, y: frame.maxY - 140, width: size.width, height: size.height)
    }

    private func cornerFrame(screen: NSScreen) -> NSRect {
        let frame = screen.visibleFrame
        return NSRect(x: frame.minX + 18, y: frame.maxY - cornerSize.height - 18, width: cornerSize.width, height: cornerSize.height)
    }

    private func moveToCorner(screens: [NSScreen]) {
        stopMovement()
        let origins = panels.map(\.frame)
        let targets = screens.map { cornerFrame(screen: $0) }
        let render: (Double) -> Void = { [weak self] progress in
            guard let self else { return }
            let eased = progress * progress * (3 - 2 * progress)
            for (index, panel) in self.panels.enumerated() where index < targets.count {
                let from = origins[index]
                let to = targets[index]
                let frame = NSRect(
                    x: from.minX + (to.minX - from.minX) * eased,
                    y: from.minY + (to.minY - from.minY) * eased,
                    width: from.width + (to.width - from.width) * eased,
                    height: from.height + (to.height - from.height) * eased
                )
                panel.setFrame(frame, display: true)
                (panel.contentView as? NoticeSurface)?.transition(progress: progress)
            }
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            render(1)
            return
        }
        let started = ProcessInfo.processInfo.systemUptime
        let animation = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            let progress = min(1, (ProcessInfo.processInfo.systemUptime - started) / 0.45)
            render(progress)
            if progress >= 1 { self.stopMovement() }
        }
        movement = animation
        RunLoop.main.add(animation, forMode: .common)
    }

    private func stopMovement() { movement?.invalidate(); movement = nil }

    func hide() {
        stopMovement()
        panels.forEach { $0.orderOut(nil) }
        shownTitle = nil
        shownSeconds = nil
        compact = false
    }

    deinit { movement?.invalidate() }
}

final class ScreenGuardController: NSObject {
    let store: ScreenControlStore
    let notice: ScreenNoticing
    let now: () -> TimeInterval
    let sessionStatus: () -> GuardSession
    let sleepDisplay: () throws -> Void
    let finished: () -> Void
    private(set) var token = ""
    private(set) var running = false
    private var state = GuardState()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var assertion: IOPMAssertionID = 0
    private var holdsAssertion = false
    private var lastPhase: GuardPhase = .inactive
    private let logger = Logger(subsystem: "local.xy.screen-guard", category: "lifecycle")

    init(store: ScreenControlStore = ScreenControlStore(), notice: ScreenNoticing = ScreenNotice(), now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, sessionStatus: @escaping () -> GuardSession = ScreenGuardController.currentSession, sleepDisplay: @escaping () throws -> Void = ScreenGuardController.performDisplaySleep, finished: @escaping () -> Void) {
        self.store = store
        self.notice = notice
        self.now = now
        self.sessionStatus = sessionStatus
        self.sleepDisplay = sleepDisplay
        self.finished = finished
    }

    static func currentSession() -> GuardSession {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session[kCGSessionOnConsoleKey as String] as? Bool == true,
              session[kCGSessionLoginDoneKey as String] as? Bool == true else {
            return .unavailable
        }
        // macOS omits this key for an unlocked session. Re-read at the action
        // boundary: display wake occurs before password authentication finishes.
        return session["CGSSessionScreenIsLocked"] as? Bool == true ? .locked : .unlocked
    }

    static func performDisplaySleep() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["displaysleepnow"]
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw NSError(domain: "ScreenGuard", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "系统未能关闭显示器。"])
        }
    }

    func start() throws {
        token = UUID().uuidString
        try store.write(token)
        running = true
        registerNotifications()
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "ScreenGuard keeps local tasks running while the display sleeps" as CFString, &assertion)
        guard result == kIOReturnSuccess else {
            try? store.write("off")
            stop(finish: false)
            throw NSError(domain: "ScreenGuard", code: Int(result), userInfo: [NSLocalizedDescriptionKey: "无法保持电脑唤醒，已取消自动熄屏。"])
        }
        holdsAssertion = true
        timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = 0.04
        RunLoop.main.add(timer!, forMode: .common)
        startCountdown()
    }

    private func registerNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.screenSlept() })
        observers.append(center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.screenWoke() })
        for name in [NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.tick() })
        }
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            DistributedNotificationCenter.default().addObserver(self, selector: #selector(sessionChanged), name: Notification.Name(name), object: nil, suspensionBehavior: .deliverImmediately)
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(externalTurnOn), name: stopNotification, object: nil, suspensionBehavior: .deliverImmediately)
    }

    @objc private func sessionChanged() {
        if Thread.isMainThread { tick() }
        else { DispatchQueue.main.async { [weak self] in self?.tick() } }
    }

    @discardableResult
    private func refreshSession() -> Bool {
        let session = sessionStatus()
        let changed = state.updateSession(session, now: now())
        if changed { logger.info("Session changed: \(String(describing: session), privacy: .public)") }
        return changed
    }

    private func permitted() -> Bool {
        guard running else { return false }
        guard store.matches(token) else { stop(); return false }
        return true
    }

    func tick() {
        guard permitted() else { return }
        refreshSession()
        apply(state.tick(now: now()))
    }

    func screenSlept() {
        guard permitted() else { return }
        refreshSession()
        logger.info("Display sleep notification")
        apply(state.screenDidSleep(now: now()))
    }

    func screenWoke() {
        guard permitted() else { return }
        refreshSession()
        logger.info("Display wake notification")
        apply(state.screenDidWake(now: now()))
    }

    func startCountdown() {
        guard permitted() else { return }
        refreshSession()
        apply(state.startCountdown(now: now()))
    }

    @objc func sleepAgain() {
        guard permitted() else { return }
        refreshSession()
        apply(state.enable(now: now()))
    }

    private func apply(_ phase: GuardPhase) {
        guard running else { return }
        // Sleep commands are actions, so repeat requests must not be deduplicated.
        if phase == lastPhase && phase != .sleepNow { return }
        lastPhase = phase
        switch phase {
        case .initialReminder:
            notice.show(title: ScreenNoticeText.initialReminderTitle,
                        subtitle: ScreenNoticeText.initialReminderSubtitle,
                        footnote: ScreenNoticeText.initialReminderFootnote,
                        countdown: false)
        case .reminder:
            notice.show(title: ScreenNoticeText.wakeReminderTitle,
                        subtitle: ScreenNoticeText.wakeReminderSubtitle,
                        countdown: false)
        case .countdown(let seconds):
            notice.showCountdown(seconds: seconds)
        case .sleepNow:
            notice.hide()
            guard permitted() else { return }
            do {
                var replacement: GuardPhase?
                let performed = try store.performIfMatches(token) {
                    // Authentication can finish while the mode lock is busy.
                    // Discard an expired password-screen deadline before pmset.
                    if refreshSession() {
                        replacement = state.tick(now: now())
                        return
                    }
                    logger.info("Requesting display sleep")
                    try sleepDisplay()
                }
                if !performed { stop() }
                else if let replacement { apply(replacement) }
            } catch { fail(error) }
        case .waitingForWake, .inactive:
            notice.hide()
        }
    }

    @objc private func externalTurnOn() {
        // Notifications may be delayed; the atomic preference is authoritative.
        if running && !store.matches(token) { stop() }
    }

    @objc func turnOn() {
        do { try store.write("off") }
        catch { fail(error); return }
        stop()
    }

    func stop(finish: Bool = true) {
        guard running else { return }
        running = false
        _ = state.disable()
        timer?.invalidate()
        timer = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        DistributedNotificationCenter.default().removeObserver(self)
        notice.hide()
        if holdsAssertion { IOPMAssertionRelease(assertion); holdsAssertion = false }
        if finish { finished() }
    }

    private func fail(_ error: Error) {
        stop(finish: false)
        let alert = NSAlert()
        alert.messageText = "屏幕模式已停止"
        alert.informativeText = error.localizedDescription
        alert.runModal()
        finished()
    }

    // 菜单栏图标和"轻醒设置"入口不在这里 —— 合成单 app 之后它们归应用层
    // （Main.swift 的 AppDelegate），因为图标要常驻、而常驻的前提是应用不随熄屏
    // 模式结束而退出。这个类只负责熄屏状态机 + 电源断言 + 提示条。
}
