import AppKit

@main
enum ScreenButtonControllerTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ScreenControlStore(directory: directory)
        let rules = ScreenInputRuleStore(fileURL: directory.appendingPathComponent("input-rules.json"))
        var legacy = ScreenInputRule()
        legacy.id = ScreenInputContract.legacyRuleID; legacy.kind = .mapped; legacy.action = .toggle; legacy.onlyWhileResting = false
        legacy.target.applicationIdentifier = "com.openai.codex"
        try rules.save([legacy])
        defer { try? FileManager.default.removeItem(at: directory) }
        var clock: TimeInterval = 100
        var asleep = false
        var session: GuardSession = .unlocked
        var offRunning = false
        var wakeRequests = 0
        var opened: [String] = []
        var activation: [Bool] = []
        var offWasWrittenBeforeOnLaunch = false
        var failures: [String] = []
        var targets: [ScreenRuleTarget] = []
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }
        let controller = ScreenButtonController(store: store, now: { clock },
            sessionStatus: { session }, displayAsleep: { asleep }, guardRunning: { offRunning },
            wakeDisplay: { wakeRequests += 1 }, openApplication: { identifier, activates, completion in
                opened.append(identifier)
                activation.append(activates)
                if identifier == "local.xy.turn-off-display" {
                    offRunning = true
                    try! store.write("test-session")
                } else if identifier == "local.xy.turn-on-display" {
                    offWasWrittenBeforeOnLaunch = store.matches("off")
                    offRunning = false
                }
                completion(nil)
            }, openTarget: { target, completion in
                targets.append(target)
                if let identifier = target.applicationIdentifier { opened.append(identifier); activation.append(true) }
                completion(nil)
            }, rules: rules)

        controller.press()
        check(opened == ["local.xy.turn-off-display"] && store.matches("test-session"),
              "Normal press must open the off app and use its real mode token")
        controller.press()
        check(opened.count == 1, "Duplicate launch/reopen delivery cannot toggle twice")
        clock = 101
        controller.press()
        check(opened == ["local.xy.turn-off-display", "local.xy.turn-on-display", "com.openai.codex"],
              "Countdown press must open the on app followed by Codex")
        check(activation == [false, false, true], "Only Codex takes the foreground")
        check(offWasWrittenBeforeOnLaunch, "Cancel the mode before asynchronously launching the on app")

        clock = 110
        offRunning = true
        try store.write("sleeping-session")
        asleep = true
        session = .locked
        let targetsBeforeLock = targets.count
        controller.press()
        check(wakeRequests == 2 && store.matches("off") && opened.last == "local.xy.turn-on-display" && targets.count == targetsBeforeLock,
              "A locked-screen press must wake and cancel the token, but wait for manual unlock before opening Codex")
        asleep = false
        clock = 111
        controller.press()
        check(opened.last == "local.xy.turn-on-display" && store.matches("off") && targets.count == targetsBeforeLock,
              "Pressing again while locked cannot start a new countdown or open Codex before authentication")

        clock = 112; controller.checkPendingTarget()
        check(targets.count == targetsBeforeLock, "A timer must not open the target while the session remains locked")
        session = .unlocked
        clock = 113; controller.checkPendingTarget()
        check(targets.count == targetsBeforeLock, "Wait for the desktop transition after authentication")
        clock = 114; controller.checkPendingTarget()
        check(targets.count == targetsBeforeLock + 1 && opened.last == "com.openai.codex",
              "Manual unlock must restore the requested Codex target without another button press")
        clock = 115; controller.checkPendingTarget()
        check(targets.count == targetsBeforeLock + 1, "Repeated checks after unlock must not repeatedly steal focus")

        clock = 120
        session = .unlocked
        offRunning = false
        try store.write("stale-token-from-a-crashed-process")
        controller.press()
        check(opened.last == "local.xy.turn-off-display" && opened.count == 7,
              "A stale mode token without a running off app must not be treated as a countdown")
        clock = 130
        session = .unavailable
        controller.press()
        check(opened.count == 7 && wakeRequests == 3,
              "Unavailable console cannot open apps or wake another session")

        var keyboardRule = ScreenInputRule(); keyboardRule.code = 96
        keyboardRule.target = ScreenRuleTarget(applicationIdentifier: "com.example.Editor", applicationName: "Editor", folderPath: directory.path)
        try rules.save([legacy, keyboardRule])
        session = .unlocked; offRunning = false; asleep = false; clock = 140
        controller.perform(keyboardRule)
        check(opened.count == 7, "A rest-only rule must not open a project during normal awake use")
        clock = 141; asleep = true
        controller.perform(keyboardRule)
        asleep = false; controller.checkPendingTarget()
        clock = 142; controller.checkPendingTarget()
        check(targets.last == keyboardRule.target && opened.last == "com.example.Editor", "Keyboard rule must carry its own app and folder")
        var mouseRule = ScreenInputRule(); mouseRule.kind = .mouse; mouseRule.code = 3
        mouseRule.target.applicationIdentifier = "com.apple.finder"
        try rules.save([legacy, keyboardRule, mouseRule])
        clock = 143; controller.perform(mouseRule, recentlyResting: true)
        check(opened.last == "com.apple.finder" && targets.last?.folderPath == nil, "Mouse rule cannot inherit the keyboard rule's project")
        let count = opened.count
        mouseRule.enabled = false; clock = 144; controller.perform(mouseRule)
        check(opened.count == count, "Disabled rules must never open a target")
        legacy.enabled = false; try rules.save([legacy]); clock = 145; controller.press()
        check(opened.count == count, "Disabling the legacy HOME rule must stop its app-open entry")
        try rules.save([]); clock = 146; controller.press()
        check(opened.count == count, "Deleting the legacy HOME rule must not revive the compatibility fallback")

        let ordinaryUnlockTargets = targets.count
        let ordinaryUnlockWakes = wakeRequests
        session = .locked; clock = 200; controller.checkPendingTarget()
        session = .unlocked; clock = 201; controller.checkPendingTarget()
        clock = 202; controller.checkPendingTarget()
        check(targets.count == ordinaryUnlockTargets && wakeRequests == ordinaryUnlockWakes,
              "An ordinary lock/unlock without a pending rule must neither open an app nor request display wake")

        // Unavailable sessions, asleep displays and relocks must all postpone
        // foreground activation; no authentication or wake call belongs in a poll.
        legacy.enabled = true; mouseRule.enabled = true
        try rules.save([legacy, keyboardRule, mouseRule])
        let waitingTargets = targets.count
        session = .locked; asleep = true; clock = 210; controller.perform(keyboardRule)
        session = .unlocked; clock = 211; controller.checkPendingTarget()
        check(targets.count == waitingTargets, "An unlocked session with an asleep display must still defer its target")
        session = .unavailable; asleep = false; clock = 212; controller.checkPendingTarget()
        session = .unlocked; clock = 213; controller.checkPendingTarget()
        session = .locked; clock = 214; controller.checkPendingTarget()
        session = .unlocked; clock = 215; controller.checkPendingTarget()
        clock = 215.3; controller.checkPendingTarget()
        check(targets.count == waitingTargets, "Relocking must restart the stable-desktop wait")
        clock = 216; controller.checkPendingTarget()
        check(targets.count == waitingTargets + 1 && targets.last == keyboardRule.target,
              "A stable manual unlock must preserve both the original app and its project folder")
        check(wakeRequests == ordinaryUnlockWakes + 1, "Waiting for unlock must never issue additional wake requests")

        for cancellation in ["disabled", "deleted", "edited", "screen-off"] {
            try rules.save([legacy, keyboardRule, mouseRule])
            try store.write("off")
            offRunning = false; session = .locked; clock += 10
            let previousTargets = targets.count
            controller.perform(keyboardRule)
            switch cancellation {
            case "disabled":
                var changed = keyboardRule; changed.enabled = false; try rules.save([changed])
            case "deleted": try rules.save([])
            case "edited":
                var changed = keyboardRule; changed.target = mouseRule.target; try rules.save([changed])
            default: try store.write("new-screen-off-mode")
            }
            controller.checkPendingTarget()
            // Restoring the old configuration cannot resurrect a cancelled request.
            try rules.save([legacy, keyboardRule, mouseRule]); try store.write("off")
            session = .unlocked; clock += 1; controller.checkPendingTarget()
            clock += 1; controller.checkPendingTarget()
            check(targets.count == previousTargets, "\(cancellation) must cancel the pending target permanently")
        }

        let latestTargets = targets.count
        session = .locked; clock += 10; controller.perform(keyboardRule)
        clock += 1; controller.perform(mouseRule)
        session = .unlocked; clock += 1; controller.checkPendingTarget()
        clock += 1; controller.checkPendingTarget()
        check(targets.count == latestTargets + 1 && targets.last == mouseRule.target,
              "The most recent explicit rule must replace the previous target while waiting for unlock")

        let cancelledTargets = targets.count
        session = .locked; clock += 10; controller.perform(keyboardRule)
        session = .unlocked; clock += 1; controller.press()
        check(opened.last == "local.xy.turn-off-display", "A new normal toggle must still start its countdown while a target was pending")
        try store.write("off"); offRunning = false
        clock += 1; controller.checkPendingTarget()
        clock += 1; controller.checkPendingTarget()
        check(targets.count == cancelledTargets, "Starting a new countdown must cancel the pending foreground target")

        // Exercise real timer delivery against injected state and actions. No
        // physical display, session, input or application is touched by this test.
        session = .locked; clock += 10; controller.perform(keyboardRule)
        session = .unlocked; clock += 1
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        check(targets.count == cancelledTargets, "The automatic timer must allow the desktop transition to finish")
        clock += 1
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        check(targets.count == cancelledTargets + 1 && targets.last == keyboardRule.target,
              "Unlock must open the pending target automatically, without another input or manual poll")

        var onCompletions: [(Error?) -> Void] = []
        var asyncTargets: [ScreenRuleTarget] = []
        let delayedController = ScreenButtonController(store: store, now: { clock },
            sessionStatus: { session }, displayAsleep: { asleep }, guardRunning: { false },
            wakeDisplay: {}, openApplication: { _, _, completion in onCompletions.append(completion) },
            openTarget: { target, completion in asyncTargets.append(target); completion(nil) }, rules: rules)
        session = .locked; clock += 10; delayedController.perform(keyboardRule)
        clock += 1; delayedController.perform(mouseRule)
        onCompletions.removeFirst()(nil)
        check(asyncTargets.isEmpty && onCompletions.count == 1,
              "A newer queued rule must supersede the old target across an asynchronous on-app launch")
        onCompletions.removeFirst()(nil)
        session = .unlocked; clock += 1; delayedController.checkPendingTarget()
        clock += 1; delayedController.checkPendingTarget()
        check(asyncTargets == [mouseRule.target], "Asynchronous launch completion must retain only the newest rule's target")

        failures.forEach { print("FAIL: \($0)") }
        print(failures.isEmpty ? "PASS: screen-button routing, manual-unlock deferral, automatic retry, cancellation, and stale-state checks" : "FAIL: \(failures.count) screen-button controller checks")
        if !failures.isEmpty { exit(1) }
    }
}
