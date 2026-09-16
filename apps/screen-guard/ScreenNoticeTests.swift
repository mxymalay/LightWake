import AppKit

/// 假提示条：只记"最后被要求显示/隐藏的是什么"。
private final class StubNotice: ScreenNoticing {
    private(set) var shownTitle: String?
    private(set) var hides = 0

    func show(title: String, subtitle: String, countdown: Bool) { shownTitle = title }
    func showCountdown(seconds: Int) { shownTitle = nil }
    func hide() {
        hides += 1
        shownTitle = nil
    }
}

/// 假定时器：把"几秒后干什么"攒起来，由测试决定什么时候真的到点。
private final class ManualClock {
    private var pending: [(TimeInterval, () -> Void)] = []

    var delays: [TimeInterval] { pending.map(\.0) }

    func after(seconds: TimeInterval, _ work: @escaping () -> Void) {
        pending.append((seconds, work))
    }

    /// 让**所有**挂着的回调到点 —— 包括那些已经被取消或被顶替的。
    /// 它们必须自己发现令牌过时并安静退出，这正是要验的东西。
    func fireAll() {
        let work = pending
        pending = []
        for (_, block) in work { block() }
    }
}

/// 合并四个 app 之后，提示语和"回执什么时候收"都没有东西守着，于是各漏了一次。
/// 这里把两件事都钉住。
@main
struct ScreenNoticeTests {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }

        // MARK: - 提示语不能指向已经不存在的入口

        // 3.0 起这四个双击目标都没了，合成一个「轻醒」。提示语里再带书名号引用它们，
        // 就是把用户指向一个空位置。注意判据用带书名号的写法：「已开启屏幕」是回执
        // 文案，它含"开启屏幕"四个字但不是入口引用，不该被误伤。
        let retired = ["「开启屏幕」", "「关闭屏幕」", "「轻醒按键」", "「轻醒设置」"]
        for text in ScreenNoticeText.all {
            check(!retired.contains(where: text.contains),
                  "提示语不能让人去点已经不存在的入口：\(text)")
        }
        check(ScreenNoticeText.initialReminderSubtitle.contains("「轻醒」"),
              "取消方式必须指向现在唯一存在的那个按钮")
        check(ScreenNoticeText.wakeReminderSubtitle.contains("「轻醒」"),
              "重新开始倒计时的说明同样要指向「轻醒」")

        // MARK: - 回执亮一下就走

        let notice = StubNotice()
        let clock = ManualClock()
        let transient = TransientNotice(notice: notice, schedule: { seconds, work in clock.after(seconds: seconds, work) })
        transient.show(title: ScreenNoticeText.turnedOnTitle,
                       subtitle: ScreenNoticeText.turnedOnSubtitle,
                       seconds: 1.5)
        check(notice.shownTitle == ScreenNoticeText.turnedOnTitle && notice.hides == 0,
              "回执要先留着，不能一显示就收")
        check(clock.delays == [1.5], "按给定的秒数安排收走")
        clock.fireAll()
        check(notice.hides == 1 && notice.shownTitle == nil, "到点收走回执")

        // 用户在这 1.5 秒内又进了熄屏模式：迟到的 hide 不能落在新提示上。
        // 这条就是 AppDelegate.enterOffMode 里 turnedOnNotice.cancel() 的作用。
        let raceNotice = StubNotice()
        let raceClock = ManualClock()
        let race = TransientNotice(notice: raceNotice, schedule: { seconds, work in raceClock.after(seconds: seconds, work) })
        race.show(title: ScreenNoticeText.turnedOnTitle,
                  subtitle: ScreenNoticeText.turnedOnSubtitle,
                  seconds: 1.5)
        race.cancel()
        raceNotice.show(title: ScreenNoticeText.initialReminderTitle,
                        subtitle: ScreenNoticeText.initialReminderSubtitle,
                        countdown: false)
        raceClock.fireAll()
        check(raceNotice.hides == 0 && raceNotice.shownTitle == ScreenNoticeText.initialReminderTitle,
              "被取消的收走不能藏掉后来者的倒计时提示")

        // 连点两次退出：两条回执叠着，只有最后一条该决定什么时候收。
        let twiceNotice = StubNotice()
        let twiceClock = ManualClock()
        let twice = TransientNotice(notice: twiceNotice, schedule: { seconds, work in twiceClock.after(seconds: seconds, work) })
        twice.show(title: ScreenNoticeText.turnedOnTitle, subtitle: ScreenNoticeText.turnedOnSubtitle, seconds: 1.5)
        twice.show(title: ScreenNoticeText.turnedOnTitle, subtitle: ScreenNoticeText.turnedOnSubtitle, seconds: 1.5)
        twiceClock.fireAll()
        check(twiceNotice.hides == 1, "两次回执只收一次，且是最后一次说了算")

        print("PASS: \(checks) notice-text and transient-notice checks; no window or sleep command touched.")
    }
}
