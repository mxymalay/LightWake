import AppKit

final class RecordingNotice: ScreenNoticing {
    var title: String?
    var countdown = false
    var compactSeconds: Int?
    func show(title: String, subtitle: String, countdown: Bool) {
        self.title = title
        self.countdown = countdown
        compactSeconds = nil
    }
    func showCountdown(seconds: Int) {
        title = nil
        countdown = false
        compactSeconds = seconds
    }
    func hide() {
        title = nil
        countdown = false
        compactSeconds = nil
    }
}

@main
struct IntegrationTests {
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let store = ScreenControlStore(directory: directory.appendingPathComponent("integration-state"))
        defer { try? FileManager.default.removeItem(at: store.directory) }
        var clock: TimeInterval = 90
        var sleeps = 0
        var finishes = 0
        let notice = RecordingNotice()
        let controller = ScreenGuardController(store: store, notice: notice, now: { clock }, sleepDisplay: { sleeps += 1 }, finished: { finishes += 1 })
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }

        try controller.start()
        check(sleeps == 0 && notice.title?.contains("5") == true && !notice.countdown && notice.compactSeconds == nil,
              "Starting off must immediately show the three-second reminder without sleeping")
        for time in [90.999, 91.0, 92.0, 92.999] {
            clock = time
            controller.tick()
            check(sleeps == 0 && notice.title != nil && !notice.countdown && notice.compactSeconds == nil,
                  "The initial reminder must stay visible for the first three seconds")
        }
        for (time, seconds) in [(93.0, 2), (93.999, 2), (94.0, 1), (94.999, 1)] {
            clock = time
            controller.tick()
            check(sleeps == 0 && notice.title == nil && notice.compactSeconds == seconds,
                  "After three seconds the initial countdown must appear only in the corner")
        }
        clock = 95
        controller.tick()
        check(sleeps == 1 && notice.title == nil && notice.compactSeconds == nil,
              "At five seconds sleep once and hide both presentation modes")
        controller.tick()
        check(sleeps == 1, "The initial sleep request is one-shot")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        clock = 100
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        check(notice.title?.contains("20") == true && !notice.countdown && notice.compactSeconds == nil,
              "Actual wake must show the initial reminder")
        clock = 102.999
        controller.tick()
        check(notice.title != nil && notice.compactSeconds == nil, "Wake reminder remains before three seconds")
        clock = 103
        controller.tick()
        check(notice.title == nil && notice.compactSeconds == 17,
              "The wake reminder becomes a seventeen-second corner countdown at three seconds")
        clock = 110
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        check(notice.title == nil && notice.compactSeconds == 10,
              "Duplicate wake must preserve the original deadline and corner presentation")
        for (time, seconds) in [(114.999, 6), (115.0, 5), (116.0, 4), (119.0, 1), (119.999, 1)] {
            clock = time
            controller.tick()
            check(notice.title == nil && notice.compactSeconds == seconds && !notice.countdown,
                  "The final five seconds must remain in the corner without another large reminder")
        }
        clock = 120
        controller.tick()
        check(sleeps == 2 && notice.title == nil && notice.compactSeconds == nil, "At twenty seconds sleep and hide UI")
        controller.tick()
        check(sleeps == 2, "The same deadline must not execute sleep twice")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        clock = 200
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        check(notice.title?.contains("20") == true, "New actual sleep/wake creates a fresh window")
        clock = 219.99
        controller.tick()
        try store.write("off")
        clock = 220
        controller.tick()
        check(sleeps == 2, "On at deadline must cancel sleep")
        check(!controller.running && finishes == 1 && notice.title == nil && notice.compactSeconds == nil,
              "On cancels controller and both presentation modes")
        controller.screenWoke()
        controller.tick()
        check(sleeps == 2 && finishes == 1, "Stopped events cannot restart guard")

        let secondNotice = RecordingNotice()
        let second = ScreenGuardController(store: store, notice: secondNotice, now: { clock }, sleepDisplay: { sleeps += 1 }, finished: { finishes += 1 })
        clock = 300
        try second.start()
        clock = 304.999
        second.tick()
        try store.write("off")
        clock = 305
        second.tick()
        check(!second.running && secondNotice.title == nil && secondNotice.compactSeconds == nil && sleeps == 2,
              "Opening the screen just before the initial deadline must cancel sleep and the corner countdown")
        DistributedNotificationCenter.default().postNotificationName(stopNotification, object: nil, userInfo: nil, deliverImmediately: true)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.2))
        check(!second.running && finishes == 2, "On is observed before delayed initial sleep")
        check(sleeps == 2, "Cancelled initial work cannot sleep later")

        let reopenedNotice = RecordingNotice()
        let reopened = ScreenGuardController(store: store, notice: reopenedNotice, now: { clock }, sleepDisplay: { sleeps += 1 }, finished: { finishes += 1 })
        clock = 400
        try reopened.start()
        clock = 402
        reopened.startCountdown()
        clock = 404.999
        reopened.tick()
        check(sleeps == 2 && reopenedNotice.title != nil && reopenedNotice.compactSeconds == nil,
              "Reopening during the reminder restarts its full three-second display")
        clock = 405
        reopened.tick()
        check(sleeps == 2 && reopenedNotice.title == nil && reopenedNotice.compactSeconds == 2,
              "Reopening during the reminder also postpones the initial sleep deadline")
        clock = 406
        reopened.startCountdown()
        check(reopenedNotice.title != nil && reopenedNotice.compactSeconds == nil,
              "Reopening during the corner countdown restores the large reminder")
        clock = 407
        reopened.tick()
        check(sleeps == 2 && reopenedNotice.title != nil && reopenedNotice.compactSeconds == nil,
              "A reset countdown must cancel the previous deadline")
        clock = 409
        reopened.tick()
        check(sleeps == 2 && reopenedNotice.title == nil && reopenedNotice.compactSeconds == 2,
              "The restarted reminder transitions to the corner after three seconds")
        clock = 411
        reopened.tick()
        check(sleeps == 3 && reopenedNotice.title == nil && reopenedNotice.compactSeconds == nil,
              "Reopened countdown expires exactly once at the new five-second deadline")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        clock = 420
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        clock = 423
        reopened.tick()
        check(reopenedNotice.compactSeconds == 17, "Immediate-sleep menu test starts from a live corner countdown")
        reopened.sleepAgain()
        check(sleeps == 4 && reopenedNotice.title == nil && reopenedNotice.compactSeconds == nil,
              "The explicit immediate-sleep menu action remains immediate and hides the corner countdown")
        reopened.tick()
        check(sleeps == 4, "Immediate menu action must not leave a second pending countdown")
        reopened.turnOn()
        check(!reopened.running && finishes == 3, "Turning on finishes the reopened controller")

        let cancelledNotice = RecordingNotice()
        let cancelled = ScreenGuardController(store: store, notice: cancelledNotice, now: { clock }, sleepDisplay: { sleeps += 1 }, finished: { finishes += 1 })
        clock = 500
        try cancelled.start()
        clock = 501
        cancelled.turnOn()
        clock = 505
        cancelled.tick()
        check(!cancelled.running && finishes == 4 && sleeps == 4 && cancelledNotice.title == nil && cancelledNotice.compactSeconds == nil,
              "Turning on during the first three seconds cancels the reminder and all later countdown work")

        let canvas = NSView(frame: NSRect(x: 0, y: 0, width: 554, height: 260))
        let reminder = NoticeView(frame: NSRect(x: 12, y: 136, width: 530, height: 112))
        reminder.update(title: "屏幕将临时亮起 20 秒", subtitle: "需要继续使用？请双击桌面上的「开启屏幕」", countdown: false)
        let initialReminder = NoticeView(frame: NSRect(x: 12, y: 12, width: 530, height: 112))
        initialReminder.update(title: "5 秒后关闭屏幕", subtitle: "双击桌面上的「开启屏幕」可取消", countdown: false)
        canvas.addSubview(reminder)
        canvas.addSubview(initialReminder)
        let window = NSWindow(contentRect: canvas.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        guard let bitmap = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { fatalError("Preview image unavailable") }
        canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("PNG unavailable") }
        try png.write(to: directory.appendingPathComponent("notice-preview.png"))
        check(reminder.title.intrinsicContentSize.width < 420 && reminder.subtitle.intrinsicContentSize.width < 420, "Chinese reminder must fit without truncation")
        check(initialReminder.title.intrinsicContentSize.width < 420 && initialReminder.subtitle.intrinsicContentSize.width < 420,
              "Initial three-second reminder must fit without truncation")
        print("PASS: \(checks) controller and cancellation checks; preview rendered; no real sleep command executed.")
    }
}
