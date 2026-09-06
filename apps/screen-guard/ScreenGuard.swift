import AppKit
import IOKit.pwr_mgt

let stopNotification = Notification.Name("local.xy.screen-guard.turn-on")

final class NoticeView: NSView {
    let title = NSTextField(labelWithString: "")
    let subtitle = NSTextField(labelWithString: "")
    let symbol = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.14, alpha: 0.97).cgColor
        layer?.cornerRadius = 20
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        symbol.frame = NSRect(x: 24, y: 36, width: 40, height: 40)
        symbol.contentTintColor = NSColor(calibratedRed: 0.42, green: 0.78, blue: 1, alpha: 1)
        title.frame = NSRect(x: 84, y: 59, width: 420, height: 30)
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.textColor = .white
        subtitle.frame = NSRect(x: 84, y: 25, width: 420, height: 25)
        subtitle.font = .systemFont(ofSize: 15)
        subtitle.textColor = NSColor.white.withAlphaComponent(0.78)
        addSubview(symbol)
        addSubview(title)
        addSubview(subtitle)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func update(title: String, subtitle: String, countdown: Bool) {
        self.title.stringValue = title
        self.subtitle.stringValue = subtitle
        symbol.image = NSImage(systemSymbolName: countdown ? "timer" : "display", accessibilityDescription: nil)
        symbol.contentTintColor = countdown ? .systemOrange : NSColor(calibratedRed: 0.42, green: 0.78, blue: 1, alpha: 1)
    }
}

protocol ScreenNoticing {
    func show(title: String, subtitle: String, countdown: Bool)
    func showCountdown(seconds: Int)
    func hide()
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
    private let bannerSize = NSSize(width: 530, height: 112)
    private let cornerSize = NSSize(width: 72, height: 64)
    var panels: [NSPanel] = []
    private(set) var shownTitle: String?
    private(set) var shownSeconds: Int?
    private var compact = false
    private var movement: Timer?

    func show(title: String, subtitle: String, countdown: Bool = false) {
        stopMovement()
        compact = false
        shownTitle = title
        shownSeconds = nil
        let screens = NSScreen.screens
        preparePanels(screens: screens)
        for (panel, screen) in zip(panels, screens) {
            guard let content = panel.contentView as? NoticeSurface else { continue }
            content.banner.update(title: title, subtitle: subtitle, countdown: countdown)
            content.showBanner()
            panel.setFrame(bannerFrame(screen: screen), display: true)
            panel.orderFrontRegardless()
        }
    }

    func showCountdown(seconds: Int) {
        let screens = NSScreen.screens
        let alreadyCompact = compact && panels.count == screens.count
        preparePanels(screens: screens)
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

    private func preparePanels(screens: [NSScreen]) {
        if panels.count != screens.count {
            stopMovement()
            panels.forEach { $0.orderOut(nil) }
            panels = screens.map { screen in
                let p = NSPanel(contentRect: bannerFrame(screen: screen), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
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
                p.contentView = NoticeSurface(frame: NSRect(origin: .zero, size: bannerSize))
                return p
            }
        }
    }

    private func bannerFrame(screen: NSScreen) -> NSRect {
        let frame = screen.visibleFrame
        return NSRect(x: frame.midX - bannerSize.width / 2, y: frame.maxY - 140, width: bannerSize.width, height: bannerSize.height)
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
    private var statusItem: NSStatusItem?

    init(store: ScreenControlStore = ScreenControlStore(), notice: ScreenNoticing = ScreenNotice(), now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, sleepDisplay: @escaping () throws -> Void = ScreenGuardController.performDisplaySleep, finished: @escaping () -> Void) {
        self.store = store
        self.notice = notice
        self.now = now
        self.sleepDisplay = sleepDisplay
        self.finished = finished
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
        makeMenu()
        timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = 0.04
        RunLoop.main.add(timer!, forMode: .common)
        startCountdown()
    }

    private func registerNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.screenSlept() })
        observers.append(center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.screenWoke() })
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(externalTurnOn), name: stopNotification, object: nil, suspensionBehavior: .deliverImmediately)
    }

    private func permitted() -> Bool {
        guard running else { return false }
        guard store.matches(token) else { stop(); return false }
        return true
    }

    func tick() {
        guard permitted() else { return }
        apply(state.tick(now: now()))
    }

    func screenSlept() {
        guard permitted() else { return }
        apply(state.screenDidSleep(now: now()))
    }

    func screenWoke() {
        guard permitted() else { return }
        apply(state.screenDidWake(now: now()))
    }

    func startCountdown() {
        guard permitted() else { return }
        apply(state.startCountdown(now: now()))
    }

    @objc func sleepAgain() {
        guard permitted() else { return }
        apply(state.enable(now: now()))
    }

    private func apply(_ phase: GuardPhase) {
        guard running else { return }
        // Sleep commands are actions, so repeat requests must not be deduplicated.
        if phase == lastPhase && phase != .sleepNow { return }
        lastPhase = phase
        switch phase {
        case .initialReminder:
            notice.show(title: "屏幕将在 5 秒后关闭", subtitle: "双击桌面上的「开启屏幕」可取消", countdown: false)
        case .reminder:
            notice.show(title: "屏幕将临时亮起 20 秒", subtitle: "需要继续使用？请双击桌面上的「开启屏幕」", countdown: false)
        case .countdown(let seconds):
            notice.showCountdown(seconds: seconds)
        case .sleepNow:
            notice.hide()
            guard permitted() else { return }
            do {
                let performed = try store.performIfMatches(token, action: sleepDisplay)
                if !performed { stop() }
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
        if let item = statusItem { NSStatusBar.system.removeStatusItem(item); statusItem = nil }
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

    private func makeMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "display", accessibilityDescription: "自动熄屏模式")
        item.button?.toolTip = "自动熄屏模式：唤醒 20 秒后再次关闭屏幕"
        let menu = NSMenu()
        let on = NSMenuItem(title: "开启屏幕（退出模式）", action: #selector(turnOn), keyEquivalent: "")
        on.target = self
        menu.addItem(on)
        let off = NSMenuItem(title: "立即关闭屏幕", action: #selector(sleepAgain), keyEquivalent: "")
        off.target = self
        menu.addItem(off)
        item.menu = menu
        statusItem = item
    }
}
