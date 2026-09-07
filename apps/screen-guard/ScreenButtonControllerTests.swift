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
        controller.press()
        check(wakeRequests == 2 && store.matches("off") && opened.suffix(2) == ["local.xy.turn-on-display", "com.openai.codex"],
              "One locked-screen press must wake, cancel the real token, and request Codex foreground")
        asleep = false
        clock = 111
        controller.press()
        check(opened.last == "com.openai.codex" && store.matches("off"),
              "Pressing again while locked cannot start a new off countdown")

        clock = 120
        session = .unlocked
        offRunning = false
        try store.write("stale-token-from-a-crashed-process")
        controller.press()
        check(opened.last == "local.xy.turn-off-display" && opened.count == 8,
              "A stale mode token without a running off app must not be treated as a countdown")
        clock = 130
        session = .unavailable
        controller.press()
        check(opened.count == 8 && wakeRequests == 3,
              "Unavailable console cannot open apps or wake another session")

        var keyboardRule = ScreenInputRule(); keyboardRule.code = 96
        keyboardRule.target = ScreenRuleTarget(applicationIdentifier: "com.example.Editor", applicationName: "Editor", folderPath: directory.path)
        session = .unlocked; offRunning = false; asleep = false; clock = 140
        controller.perform(keyboardRule)
        check(opened.count == 8, "A rest-only rule must not open a project during normal awake use")
        clock = 141; asleep = true
        controller.perform(keyboardRule)
        check(targets.last == keyboardRule.target && opened.last == "com.example.Editor", "Keyboard rule must carry its own app and folder")
        var mouseRule = ScreenInputRule(); mouseRule.kind = .mouse; mouseRule.code = 3
        mouseRule.target.applicationIdentifier = "com.apple.finder"
        clock = 142; controller.perform(mouseRule)
        check(opened.last == "com.apple.finder" && targets.last?.folderPath == nil, "Mouse rule cannot inherit the keyboard rule's project")
        let count = opened.count
        mouseRule.enabled = false; clock = 143; controller.perform(mouseRule)
        check(opened.count == count, "Disabled rules must never open a target")
        legacy.enabled = false; try rules.save([legacy]); clock = 144; controller.press()
        check(opened.count == count, "Disabling the legacy HOME rule must stop its app-open entry")
        try rules.save([]); clock = 145; controller.press()
        check(opened.count == count, "Deleting the legacy HOME rule must not revive the compatibility fallback")

        failures.forEach { print("FAIL: \($0)") }
        print(failures.isEmpty ? "PASS: screen-button routing, cancellation ordering, wake-and-focus, and stale-state checks" : "FAIL: \(failures.count) screen-button controller checks")
        if !failures.isEmpty { exit(1) }
    }
}
