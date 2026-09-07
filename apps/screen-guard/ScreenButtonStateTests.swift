import Foundation

@main
enum ScreenButtonStateTests {
    static func main() {
        var failures: [String] = []
        let cases: [(Bool, GuardSession, Bool, ScreenButtonAction, String)] = [
            (false, .unlocked, false, .startCountdown, "Normal desktop starts the off flow"),
            (true, .unlocked, false, .keepScreenOn, "Visible countdown is cancelled"),
            (true, .unlocked, true, .keepScreenOn, "Sleeping display wakes and cancels the guard in one press"),
            (true, .locked, true, .keepScreenOn, "Locked sleeping display wakes and cancels the guard"),
            (true, .locked, false, .keepScreenOn, "Already visible password screen cancels the guard"),
            (false, .locked, false, .keepScreenOn, "Locked console must not start another countdown"),
            (false, .unlocked, true, .keepScreenOn, "Sleeping without a running guard still wakes"),
            (false, .unavailable, false, .none, "Unavailable console must not start the off app"),
            (true, .unavailable, true, .none, "Unavailable console must not control another user"),
        ]
        for (active, session, asleep, expected, context) in cases {
            let result = ScreenButtonState.action(guardActive: active, session: session, displayAsleep: asleep)
            if result != expected { failures.append("\(context): expected \(expected), got \(result)") }
        }
        failures.forEach { print("FAIL: \($0)") }
        print("\(cases.count - failures.count)/\(cases.count) screen-button state checks passed")
        if !failures.isEmpty { exit(1) }
    }
}
