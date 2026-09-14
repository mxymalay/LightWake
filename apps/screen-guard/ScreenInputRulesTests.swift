import Foundation

@main
enum ScreenInputRulesTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lightwake-rules-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScreenInputRuleStore(fileURL: root.appendingPathComponent("rules.json"))
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) { precondition(condition(), message); count += 1 }
        check(store.load().isEmpty && !FileManager.default.fileExists(atPath: root.path), "No default key interception or writes")
        var keyboard = ScreenInputRule()
        keyboard.name = "Keyboard project"; keyboard.code = 96; keyboard.modifiers = 3
        keyboard.target = ScreenRuleTarget(applicationIdentifier: "com.example.Editor", applicationName: "Editor", folderPath: root.path)
        var mouse = ScreenInputRule(); mouse.name = "Mouse app"; mouse.kind = .mouse; mouse.code = 3
        mouse.target.applicationIdentifier = "com.apple.finder"
        var mapped = ScreenInputRule(); mapped.name = "HOME"; mapped.kind = .mapped
        mapped.id = ScreenInputContract.legacyRuleID; mapped.target.applicationIdentifier = "com.openai.codex"
        try store.save([keyboard, mouse, mapped])
        check(store.load() == [keyboard, mouse, mapped], "Each input preserves its own application and folder")
        check(keyboard.matches(kind: .keyboard, code: 96, modifiers: 3), "Exact keyboard combination matches")
        check(!keyboard.matches(kind: .keyboard, code: 96, modifiers: 0), "Other modifier combinations do not trigger")
        check(!mouse.matches(kind: .keyboard, code: 3, modifiers: 0), "Keyboard and mouse codes never alias")
        check(mouse.matches(kind: .mouse, code: 3, modifiers: 0), "Selected mouse button matches")
        check(store.mappedRule(mapped.id)?.target.applicationIdentifier == "com.openai.codex", "Mapped input resolves only its own target")
        check(store.mappedRule(keyboard.id) == nil, "External calls cannot invoke a keyboard rule")
        check(ScreenInputContract.mappedRuleID(from: URL(string: mapped.triggerURL)!) == mapped.id, "Stable mapped-input URL")
        for text in ["lightwake://trigger/unknown", "lightwake://trigger/legacy-toggle?app=bad", "lightwake://other/legacy-toggle", "lightwake://trigger/legacy-toggle#x", "https://trigger/legacy-toggle", "lightwake://user@trigger/legacy-toggle"] {
            check(ScreenInputContract.mappedRuleID(from: URL(string: text)!) == nil, "Malformed or extended requests have no effect")
        }
        var duplicate = keyboard; duplicate.id = UUID().uuidString
        do { try store.save([keyboard, duplicate]); preconditionFailure("Conflicting shortcuts accepted") } catch {}
        check(store.load() == [keyboard, mouse, mapped], "Rejected edits preserve saved rules")
        duplicate.enabled = false
        try store.save([keyboard, duplicate])
        check(store.load().count == 2, "A disabled draft may reuse a shortcut")
        for target in [ScreenInputContract.controllerID, "local.xy.turn-on-display", "bad;command"] {
            var invalid = mouse; invalid.target.applicationIdentifier = target
            do { try store.save([invalid]); preconditionFailure("Invalid target accepted") } catch {}
        }
        mapped.enabled = false; try store.save([mapped])
        check(store.mappedRule(mapped.id) == nil, "Disabled mapped input cannot activate its target")
        try Data("{\"version\":2,\"rules\":[]}".utf8).write(to: store.fileURL)
        check(store.load().isEmpty, "Unknown configuration version does not run actions")
        print("PASS: \(count) per-input rules, app/project targets, disabled defaults and interface validation checks.")
    }
}
