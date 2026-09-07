#if GUARD_STATE_TESTS
import Foundation

@main
struct GuardStateTests {
    static func main() {
        var failures: [String] = []
        var checks = 0

        func expect(_ actual: GuardPhase, _ expected: GuardPhase, _ context: String) {
            checks += 1
            if actual != expected {
                failures.append("\(context): expected \(expected), got \(actual)")
            }
        }

        func expectChange(_ actual: Bool, _ expected: Bool, _ context: String) {
            checks += 1
            if actual != expected {
                failures.append("\(context): expected change \(expected), got \(actual)")
            }
        }

        // Explicit starts show a three-second notice, then two corner digits.
        do {
            var state = GuardState()
            expect(state.startCountdown(now: 100), .initialReminder, "start immediately shows initial notice")
            expect(state.screenDidWake(now: 102), .initialReminder, "wake during initial notice keeps its deadline")
            expect(state.tick(now: 102.999), .initialReminder, "initial notice remains for three seconds")
            expect(state.tick(now: 103), .countdown(2), "initial notice becomes corner countdown at three seconds")
            expect(state.screenDidWake(now: 103.999), .countdown(2), "duplicate wake preserves initial countdown")
            expect(state.tick(now: 104), .countdown(1), "initial countdown shows final digit")
            expect(state.tick(now: 104.999), .countdown(1), "display remains on before initial deadline")
            expect(state.tick(now: 105), .sleepNow, "initial deadline requests sleep")
            expect(state.tick(now: 105), .waitingForWake, "initial sleep request cannot repeat")
            expect(state.startCountdown(now: 106), .initialReminder, "another explicit open creates a new notice")
            expect(state.disable(), .inactive, "turning on cancels initial countdown")
            expect(state.tick(now: 111), .inactive, "cancelled countdown cannot sleep later")
        }

        // Reopening during either visible phase replaces the initial deadline.
        for restartTime in [101.0, 103.0, 104.999] {
            var state = GuardState()
            _ = state.startCountdown(now: 100)
            _ = state.tick(now: restartTime)
            expect(state.startCountdown(now: restartTime), .initialReminder, "explicit restart at \(restartTime)")
            expect(state.tick(now: restartTime + 2.999), .initialReminder, "restarted notice lasts three seconds")
            expect(state.tick(now: restartTime + 3), .countdown(2), "restarted corner countdown")
            expect(state.tick(now: restartTime + 5), .sleepNow, "restart gets a full five seconds")
        }

        // A real sleep or cancellation must remove an initial notice or digit.
        for stopTime in [101.0, 103.0, 104.5] {
            var state = GuardState()
            _ = state.startCountdown(now: 100)
            expect(state.screenDidSleep(now: stopTime), .waitingForWake, "early sleep during initial phase")
            expect(state.tick(now: 105), .waitingForWake, "early sleep cancels initial deadline")
            expect(state.screenDidWake(now: 110), .reminder, "wake after early initial sleep shows wake notice")
            expect(state.tick(now: 113), .countdown(17), "wake after early initial sleep gets seventeen digits")

            _ = state.startCountdown(now: 200)
            _ = state.tick(now: stopTime + 100)
            expect(state.disable(), .inactive, "disable during initial phase")
            expect(state.tick(now: 205), .inactive, "disabled initial phase cannot sleep")
        }

        // Late delivery skips expired presentation without extending five seconds.
        do {
            var state = GuardState()
            _ = state.startCountdown(now: 100)
            expect(state.tick(now: 125), .sleepNow, "delayed initial tick honors deadline")
            expect(state.tick(now: 125), .waitingForWake, "delayed initial tick cannot burst sleep requests")
            expect(state.tick(now: 144.999), .waitingForWake, "initial retry waits after actual sleep request")
            expect(state.tick(now: 145), .sleepNow, "initial retry uses actual request time")
        }

        // The menu's immediate action still retries if no sleep arrives.
        do {
            var state = GuardState()
            expect(state.tick(now: 0), .inactive, "initially inactive")
            expect(state.enable(now: 100), .sleepNow, "enable requests immediate sleep")
            expect(state.tick(now: 119.999), .waitingForWake, "no early initial retry")
            expect(state.tick(now: 120), .sleepNow, "initial retry at 20 seconds")
            expect(state.tick(now: 120.001), .waitingForWake, "sleep request is one-shot")
            expect(state.tick(now: 140), .sleepNow, "retry continues without sleep notification")
        }

        // A confirmed sleeping display must stay asleep without periodic actions.
        do {
            var state = GuardState()
            _ = state.enable(now: 100)
            expect(state.screenDidSleep(now: 101), .waitingForWake, "confirmed initial sleep")
            expect(state.tick(now: 120), .waitingForWake, "sleep cancels initial retry")
            expect(state.tick(now: 9_000), .waitingForWake, "no action while display sleeps")
        }

        // Wake boundaries: [0,3) notice, [3,20) corner countdown, then sleep.
        do {
            var state = GuardState()
            _ = state.enable(now: 0)
            _ = state.screenDidSleep(now: 1)
            expect(state.screenDidWake(now: 100), .reminder, "wake starts reminder")
            expect(state.tick(now: 102.999), .reminder, "wake notice remains for three seconds")
            expect(state.tick(now: 103), .countdown(17), "wake reminder collapses after three seconds")
            let samples: [(TimeInterval, GuardPhase)] = [
                (103, .countdown(17)),
                (103.999, .countdown(17)),
                (104, .countdown(16)),
                (104.999, .countdown(16)),
                (105, .countdown(15)),
                (110, .countdown(10)),
                (114.999, .countdown(6)),
                (115, .countdown(5)),
                (115.999, .countdown(5)),
                (116, .countdown(4)),
                (117, .countdown(3)),
                (118, .countdown(2)),
                (119, .countdown(1)),
                (119.999, .countdown(1)),
                (120, .sleepNow),
                (120.001, .waitingForWake)
            ]
            for (now, expected) in samples {
                expect(state.tick(now: now), expected, "wake boundary at \(now)")
            }
        }

        // Duplicate wake notifications must never shift the original deadline.
        do {
            var state = GuardState()
            _ = state.enable(now: 0)
            _ = state.screenDidSleep(now: 1)
            _ = state.screenDidWake(now: 100)
            expect(state.screenDidWake(now: 102), .reminder, "duplicate during reminder")
            expect(state.screenDidWake(now: 103), .countdown(17), "duplicate during collapse keeps countdown")
            expect(state.screenDidWake(now: 110), .countdown(10), "duplicate during corner countdown")
            expect(state.screenDidWake(now: 119), .countdown(1), "duplicate during countdown")
            expect(state.screenDidWake(now: 120), .sleepNow, "duplicate at original deadline")
            expect(state.screenDidWake(now: 121), .waitingForWake, "wake needs preceding sleep")
            expect(state.screenDidWake(now: 140), .sleepNow, "duplicate cannot postpone retry")
        }

        // Polling or mouse-driven refreshes do not extend the fixed window.
        do {
            var state = GuardState()
            _ = state.enable(now: 0)
            _ = state.screenDidSleep(now: 1)
            _ = state.screenDidWake(now: 100)
            for now in stride(from: 100.0, to: 120.0, by: 0.01) {
                _ = state.tick(now: now)
            }
            expect(state.tick(now: 120), .sleepNow, "frequent refreshes retain deadline")
        }

        // Only an actual sleep notification permits a fresh twenty-second wake.
        do {
            var state = GuardState()
            _ = state.enable(now: 0)
            expect(state.screenDidWake(now: 10), .waitingForWake, "wake before initial sleep ignored")
            expect(state.tick(now: 20), .sleepNow, "ignored wake preserves fallback")
            _ = state.screenDidSleep(now: 21)
            _ = state.screenDidWake(now: 100)
            expect(state.screenDidSleep(now: 112), .waitingForWake, "early sleep cancels wake window")
            expect(state.tick(now: 120), .waitingForWake, "old wake deadline cancelled")
            expect(state.screenDidWake(now: 130), .reminder, "next real wake restarts window")
            expect(state.tick(now: 145), .countdown(5), "new wake countdown")
            expect(state.tick(now: 150), .sleepNow, "new wake deadline")
        }

        // Delayed timer delivery must sleep immediately instead of restarting.
        do {
            var state = GuardState()
            _ = state.enable(now: 0)
            _ = state.screenDidSleep(now: 1)
            _ = state.screenDidWake(now: 100)
            expect(state.tick(now: 135), .sleepNow, "late timer honors expired deadline")
            expect(state.tick(now: 135), .waitingForWake, "late timer does not burst retries")
            expect(state.tick(now: 154.999), .waitingForWake, "retry waits a full interval")
            expect(state.tick(now: 155), .sleepNow, "late timer schedules retry from request")
        }

        // Disable must neutralize outstanding and future callbacks in every phase.
        for stopTime in [0.0, 2.0, 3.0, 7.0, 17.0, 20.0] {
            var state = GuardState()
            _ = state.enable(now: 0)
            if stopTime > 0 {
                _ = state.screenDidSleep(now: 0)
                _ = state.screenDidWake(now: 0)
                _ = state.tick(now: stopTime)
            }
            expect(state.disable(), .inactive, "disable at \(stopTime)")
            expect(state.tick(now: 1_000), .inactive, "disabled stale timer at \(stopTime)")
            expect(state.screenDidWake(now: 1_001), .inactive, "disabled wake at \(stopTime)")
            expect(state.screenDidSleep(now: 1_002), .inactive, "disabled sleep at \(stopTime)")
            checks += 1
            if state.isEnabled { failures.append("isEnabled remains true after disable") }
        }

        // Re-enabling starts a clean initial sleep attempt.
        do {
            var state = GuardState()
            _ = state.enable(now: 0)
            _ = state.screenDidSleep(now: 1)
            _ = state.screenDidWake(now: 10)
            _ = state.disable()
            expect(state.enable(now: 25), .sleepNow, "re-enable requests sleep")
            expect(state.tick(now: 30), .waitingForWake, "old deadline cannot survive re-enable")
            expect(state.tick(now: 45), .sleepNow, "new enable fallback")
            checks += 1
            if !state.isEnabled { failures.append("isEnabled remains false after enable") }
        }

        // Time spent entering a password must not consume the desktop window.
        do {
            var state = GuardState()
            _ = state.enable(now: 0)
            _ = state.screenDidSleep(now: 1)
            expectChange(state.updateSession(.locked, now: 50), true, "observe password lock")
            expect(state.screenDidWake(now: 100), .waitingForWake, "hide reminder behind password screen")
            expect(state.tick(now: 116), .waitingForWake, "hide corner countdown behind password screen")
            expectChange(state.updateSession(.unlocked, now: 117), true, "successful password unlock")
            expect(state.tick(now: 117), .reminder, "unlock shows a fresh desktop reminder")
            expect(state.tick(now: 119.999), .reminder, "unlock reminder lasts three seconds")
            expect(state.tick(now: 120), .countdown(17), "old password wake deadline cannot sleep desktop")
            expect(state.tick(now: 136.999), .countdown(1), "desktop gets the full twenty seconds")
            expect(state.tick(now: 137), .sleepNow, "new desktop deadline sleeps once")
        }

        // Both notification orders start once at unlock, not at password wake.
        for unlockBeforeWake in [false, true] {
            var state = GuardState()
            _ = state.enable(now: 0)
            _ = state.screenDidSleep(now: 1)
            _ = state.updateSession(.locked, now: 50)
            if !unlockBeforeWake {
                expect(state.screenDidWake(now: 100), .waitingForWake, "locked wake before unlock")
            }
            expectChange(state.updateSession(.unlocked, now: 117), true, "unlock transition in either event order")
            if unlockBeforeWake {
                expect(state.screenDidWake(now: 118), .reminder, "wake delivered after unlock retains its start")
            }
            expectChange(state.updateSession(.unlocked, now: 119), false, "duplicate unlock does not restart time")
            expect(state.screenDidWake(now: 125), .countdown(12), "duplicate display wake cannot extend unlock window")
            expectChange(state.updateSession(.unlocked, now: 136), false, "repeated unlocked polling is inert")
            expect(state.tick(now: 137), .sleepNow, "both event orders retain unlock deadline")
        }

        // Reconcile unlock before an overdue tick, including an old sleep retry.
        for expiredSleepAlreadyRequested in [false, true] {
            var state = GuardState()
            _ = state.enable(now: 0)
            _ = state.screenDidSleep(now: 1)
            _ = state.updateSession(.locked, now: 50)
            _ = state.screenDidWake(now: 100)
            if expiredSleepAlreadyRequested {
                expect(state.tick(now: 120), .waitingForWake, "locked deadline cannot interrupt authentication")
            }
            _ = state.updateSession(.unlocked, now: 145)
            expect(state.tick(now: 145), .reminder, "unlock cancels overdue wake or retry action")
            expect(state.tick(now: 148), .countdown(17), "late unlock keeps full visible countdown")
            expect(state.tick(now: 165), .sleepNow, "late unlock uses only its new deadline")
        }

        // An elapsed deadline is not evidence that authentication is idle.
        do {
            var state = GuardState()
            _ = state.updateSession(.locked, now: 0)
            expect(state.startCountdown(now: 10), .waitingForWake, "locked explicit close hides initial banner")
            expect(state.tick(now: 13), .waitingForWake, "locked explicit close hides initial digits")
            expect(state.tick(now: 15), .waitingForWake, "initial deadline yields to authentication")
            _ = state.screenDidSleep(now: 16)
            expect(state.screenDidWake(now: 100), .waitingForWake, "locked accidental wake has no desktop banner")
            expectChange(state.updateSession(.locked, now: 110), false, "duplicate lock cannot alter deadline")
            expect(state.tick(now: 119.999), .waitingForWake, "locked accidental wake stays bright for twenty seconds")
            expect(state.tick(now: 120), .waitingForWake, "twenty-second deadline yields to authentication")
            expect(state.tick(now: 1_800), .waitingForWake, "slow or retried authentication has no forced sleep deadline")
            expect(state.enable(now: 1_801), .waitingForWake, "a queued immediate action cannot sleep a locked session")
            _ = state.updateSession(.unlocked, now: 1_900)
            expect(state.tick(now: 1_900), .reminder, "completed authentication creates a fresh desktop window")
            expect(state.tick(now: 1_920), .sleepNow, "normal desktop auto-sleep still works")
        }

        // An inactive or unknown console session cannot send a global sleep command.
        do {
            var state = GuardState()
            expectChange(state.updateSession(.unavailable, now: 0), true, "observe unavailable session")
            expect(state.tick(now: 0), .inactive, "session loss does not enable guard")
            expect(state.enable(now: 10), .waitingForWake, "unavailable immediate menu action cannot sleep")
            expect(state.tick(now: 30), .waitingForWake, "unavailable immediate retry cannot sleep")
            expect(state.startCountdown(now: 40), .waitingForWake, "unavailable explicit start hides reminder")
            expect(state.tick(now: 45), .waitingForWake, "unavailable initial deadline cannot sleep")
            expect(state.screenDidSleep(now: 50), .waitingForWake, "unavailable display sleep stays hidden")
            expect(state.screenDidWake(now: 60), .waitingForWake, "unavailable wake cannot expose a reminder")
            expect(state.tick(now: 80), .waitingForWake, "unavailable wake deadline cannot sleep")
            expect(state.tick(now: 1_000), .waitingForWake, "prolonged absence never sends sleep")
            expectChange(state.updateSession(.unavailable, now: 1_001), false, "duplicate unavailable observation is inert")
            _ = state.updateSession(.unlocked, now: 1_010)
            expect(state.tick(now: 1_010), .reminder, "return to console starts fresh desktop window")
            expect(state.tick(now: 1_013), .countdown(17), "returned console gets full corner countdown")
            expect(state.tick(now: 1_030), .sleepNow, "returned console sleeps only at its new deadline")
        }

        // Losing the console must suppress even an already pending sleep/retry.
        for useImmediateMenu in [false, true] {
            var state = GuardState()
            _ = state.startCountdown(now: 100)
            if useImmediateMenu { _ = state.enable(now: 100) }
            _ = state.updateSession(.unavailable, now: 102)
            expect(state.tick(now: 1_000), .waitingForWake, "session loss suppresses outstanding deadline")
            _ = state.updateSession(.unlocked, now: 1_001)
            expect(state.tick(now: 1_001), .reminder, "return replaces outstanding deadline")
            expect(state.tick(now: 1_021), .sleepNow, "return creates only one new window")
        }

        // Cancellation remains authoritative across later lock and unlock events.
        for session in [GuardSession.locked, .unavailable] {
            var state = GuardState()
            _ = state.startCountdown(now: 100)
            _ = state.updateSession(session, now: 101)
            expect(state.disable(), .inactive, "cancel outside the unlocked desktop")
            expectChange(state.updateSession(.unlocked, now: 200), true, "observe unlock after cancellation")
            expect(state.tick(now: 200), .inactive, "unlock cannot enable a cancelled guard")
            expect(state.screenDidWake(now: 201), .inactive, "late display wake cannot enable cancelled guard")
            expect(state.tick(now: 1_000), .inactive, "cancelled guard has no future sleep deadline")
        }

        for failure in failures { print("FAIL: \(failure)") }
        print("\(checks - failures.count)/\(checks) GuardState checks passed")
        if !failures.isEmpty { exit(1) }
    }
}
#endif
