import Foundation

@main
enum QuietProtectionTests {
    static func main() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("lightwake-consent-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let resources = base.appendingPathComponent("resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        for name in QuietProtectionManager.resourceNames {
            try Data("fixture \(name)".utf8).write(to: resources.appendingPathComponent(name))
        }
        let root = base.appendingPathComponent("Another User/Application Support/ScreenGuard/QuietDesktop")
        let agents = base.appendingPathComponent("Another User/LaunchAgents")
        var commands: [[String]] = []
        let manager = QuietProtectionManager(directory: root, resources: resources, launchAgents: agents,
            run: { arguments in commands.append(arguments); return arguments.contains("print") ? 1 : 0 })
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            count += 1
        }
        check(!manager.isEnabled, "New users must start disabled")
        check(!FileManager.default.fileExists(atPath: root.path) && commands.isEmpty,
              "Opening preferences must not install or start background work")
        let cancelled = try manager.enable(confirmed: false)
        check(!cancelled, "Cancel must reject enabling")
        check(!manager.isEnabled && commands.isEmpty && !FileManager.default.fileExists(atPath: root.path),
              "Cancel must not leave preferences or an installed service")
        do {
            _ = try manager.enable(confirmed: true)
            print("FAIL: the withdrawn process-freezing feature can still be enabled and installed")
            exit(1)
        } catch {}
        check(!manager.isEnabled && commands.isEmpty && !FileManager.default.fileExists(atPath: root.path),
              "Even explicit old consent must not install or start withdrawn protection")
        try manager.disable()
        check(!FileManager.default.fileExists(atPath: root.path), "Retiring protection on a fresh install must create no state")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("runtime"), withIntermediateDirectories: true)
        try Data("{\"enabled\":true,\"consentVersion\":1}".utf8).write(to: manager.preferencesURL)
        let journal = root.appendingPathComponent("runtime/owned.json")
        let legacyOwnership = Data("{\"version\":1,\"owned\":[{\"pid\":123}]}".utf8)
        try legacyOwnership.write(to: journal)
        let reopened = QuietProtectionManager(directory: root, resources: resources, launchAgents: agents,
            run: { _ in preconditionFailure("Reading saved consent must not start a service") })
        check(reopened.isEnabled && commands.isEmpty, "Reading a legacy choice must not start or resume its service")
        try manager.disable()
        check(!manager.isEnabled && commands.isEmpty,
              "Retirement must disable old consent without issuing process or desktop commands")
        let retainedJournal = try Data(contentsOf: journal)
        check(retainedJournal == legacyOwnership, "Retirement must preserve ownership for safe cleanup")
        let preference = try Data(contentsOf: manager.preferencesURL)
        try manager.disable()
        let unchangedPreference = try Data(contentsOf: manager.preferencesURL)
        check(unchangedPreference == preference && commands.isEmpty, "Repeated app launches must keep retirement idempotent")
        try Data("{\"enabled\":true}".utf8).write(to: manager.preferencesURL)
        check(!manager.isEnabled, "A legacy preference without consent cannot enable the feature")
        print("PASS: \(count) withdrawn-feature and legacy-retirement checks; no process or desktop action occurred.")
    }
}
