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
        let accepted = try manager.enable(confirmed: true)
        check(accepted, "Explicit consent enables the feature")
        check(manager.isEnabled, "Confirmed choice must persist")
        let preference = try JSONSerialization.jsonObject(with: Data(contentsOf: manager.preferencesURL)) as! [String: Any]
        check(preference["consentVersion"] as? Int == 1 && preference["enabled"] as? Bool == true,
              "The helper must receive versioned explicit consent")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: manager.agentURL), format: nil) as! [String: Any]
        let arguments = plist["ProgramArguments"] as! [String]
        check(arguments == ["/usr/bin/python3", root.appendingPathComponent("quiet_service_guard.py").path, "run"],
              "Installed paths must follow the selected user's directory, including spaces")
        check((plist["KeepAlive"] as? [String: Bool])?["SuccessfulExit"] == false,
              "Clean opt-out must not be restarted by launchd")
        check(commands.contains { $0.contains("bootstrap") }, "Explicit consent starts the installed helper")
        for name in QuietProtectionManager.resourceNames {
            check(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path), "Missing portable resource")
        }
        let commandCount = commands.count
        let reopened = QuietProtectionManager(directory: root, resources: resources, launchAgents: agents,
            run: { _ in preconditionFailure("Reading saved consent must not start a service") })
        check(reopened.isEnabled && commands.count == commandCount, "Reopening settings only reads the saved choice")
        try manager.disable()
        check(!manager.isEnabled && commands.count == commandCount,
              "Opt-out only requests safe cleanup, never resumes a sleeping desktop")
        try Data("{\"enabled\":true}".utf8).write(to: manager.preferencesURL)
        check(!manager.isEnabled, "A legacy preference without consent cannot enable the feature")
        let brokenRoot = base.appendingPathComponent("failed-install")
        let broken = QuietProtectionManager(directory: brokenRoot, resources: resources, launchAgents: agents,
            run: { _ in 5 })
        do {
            _ = try broken.enable(confirmed: true)
            preconditionFailure("A failed launch must report failure")
        } catch {}
        check(!broken.isEnabled, "A failed launch must roll the opt-in back to off")
        print("PASS: \(count) explicit-consent and portable-install checks; no real launch agent was started.")
    }
}
