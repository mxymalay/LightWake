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
        let controller = ScreenGuardController(store: store, notice: notice, now: { clock }, sessionStatus: { .unlocked }, sleepDisplay: { sleeps += 1 }, finished: { finishes += 1 })
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
        let second = ScreenGuardController(store: store, notice: secondNotice, now: { clock }, sessionStatus: { .unlocked }, sleepDisplay: { sleeps += 1 }, finished: { finishes += 1 })
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
        let reopened = ScreenGuardController(store: store, notice: reopenedNotice, now: { clock }, sessionStatus: { .unlocked }, sleepDisplay: { sleeps += 1 }, finished: { finishes += 1 })
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
        let cancelled = ScreenGuardController(store: store, notice: cancelledNotice, now: { clock }, sessionStatus: { .unlocked }, sleepDisplay: { sleeps += 1 }, finished: { finishes += 1 })
        clock = 500
        try cancelled.start()
        clock = 501
        cancelled.turnOn()
        clock = 505
        cancelled.tick()
        check(!cancelled.running && finishes == 4 && sleeps == 4 && cancelledNotice.title == nil && cancelledNotice.compactSeconds == nil,
              "Turning on during the first three seconds cancels the reminder and all later countdown work")

        // Regression: authenticating must not consume the desktop's wake window.
        var session: GuardSession = .unlocked
        let unlockedNotice = RecordingNotice()
        let unlockController = ScreenGuardController(store: store, notice: unlockedNotice, now: { clock }, sessionStatus: { session }, sleepDisplay: { sleeps += 1 }, finished: { finishes += 1 })
        clock = 600
        try unlockController.start()
        clock = 605
        unlockController.tick()
        unlockController.screenSlept()
        session = .locked
        unlockController.tick()
        clock = 700
        unlockController.screenWoke()
        clock = 717
        session = .unlocked
        // Poll first, before any unlock notification can arrive.
        unlockController.tick()
        clock = 720
        unlockController.tick()
        check(sleeps == 5 && unlockedNotice.compactSeconds == 17,
              "Unlock must start a full desktop window instead of executing the password-screen deadline")
        clock = 726
        unlockController.screenWoke()
        check(unlockedNotice.compactSeconds == 11, "Delayed wake after unlock cannot extend the desktop deadline")
        clock = 737
        unlockController.tick()
        check(sleeps == 6, "The fresh desktop window still expires exactly twenty seconds after unlock")
        unlockController.screenSlept()
        session = .locked
        unlockController.tick()
        clock = 800
        unlockController.screenWoke()
        session = .unlocked
        clock = 830
        unlockController.tick()
        check(sleeps == 6 && unlockedNotice.title?.contains("20") == true,
              "A delayed timer must observe unlock before consuming an already expired locked deadline")
        clock = 833
        unlockController.tick()
        check(unlockedNotice.compactSeconds == 17, "Late unlock still gets three seconds of reminder")
        session = .locked
        unlockController.tick()
        check(unlockedNotice.title == nil && unlockedNotice.compactSeconds == nil,
              "Locking must hide desktop countdown UI")
        try store.write("off")
        session = .unlocked
        clock = 900
        unlockController.tick()
        check(!unlockController.running && sleeps == 6 && finishes == 5,
              "Cancellation while locked must survive unlock without new sleep or UI")

        // The session may change while waiting for the cross-process mode lock.
        var sessionReads = 0
        var lockOnSecondRead = false
        var raceSession: GuardSession = .unlocked
        let raceNotice = RecordingNotice()
        let race = ScreenGuardController(store: store, notice: raceNotice, now: { clock }, sessionStatus: {
            sessionReads += 1
            if lockOnSecondRead && sessionReads >= 2 { return .locked }
            return raceSession
        }, sleepDisplay: { sleeps += 1 }, finished: { finishes += 1 })
        clock = 1_000
        try race.start()
        clock = 1_005
        race.tick()
        race.screenSlept()
        clock = 1_100
        race.screenWoke()
        clock = 1_120
        sessionReads = 0
        lockOnSecondRead = true
        race.tick()
        check(sleeps == 7 && raceNotice.title == nil && raceNotice.compactSeconds == nil,
              "Lock beginning after timer evaluation must cancel sleep at the final action boundary")
        lockOnSecondRead = false
        raceSession = .locked
        for time in [1_121.0, 1_140.0, 1_160.0, 1_500.0] {
            clock = time
            race.tick()
            race.screenWoke()
            check(sleeps == 7 && raceNotice.title == nil && raceNotice.compactSeconds == nil,
                  "Locked wake notifications and old retries must never interrupt authentication")
        }
        raceSession = .unlocked
        clock = 1_501
        race.tick()
        check(sleeps == 7 && raceNotice.title?.contains("20") == true,
              "Normal authentication completion gets a full desktop window")
        clock = 1_504
        race.tick()
        check(raceNotice.compactSeconds == 17, "Unlock starts the fresh deadline only once")
        clock = 1_521
        race.tick()
        check(sleeps == 8, "Automatic screen-off remains functional on the unlocked desktop")
        race.turnOn()
        check(finishes == 6, "Race regression releases the running controller")

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
