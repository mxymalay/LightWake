import AppKit

@main
enum ScreenInputServiceTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lightwake-input-service-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("Applications/轻醒按键.app")
        let agent = root.appendingPathComponent("LaunchAgents/input-rules.plist")
        var calls: [[String]] = []
        let manager = ScreenInputServiceManager(helper: helper, agentURL: agent, run: { args in
            calls.append(args); return args.contains("print") ? 1 : 0
        })
        try manager.apply([])
        precondition(calls.isEmpty && !FileManager.default.fileExists(atPath: root.path), "Default-off input rules cannot install or start a job")
        var mapped = ScreenInputRule(); mapped.kind = .mapped
        try manager.apply([mapped])
        precondition(calls.isEmpty && !FileManager.default.fileExists(atPath: root.path), "External mappings do not require global input listening")
        var keyboard = ScreenInputRule(); keyboard.code = 96; keyboard.modifiers = 1
        do { try manager.apply([keyboard]); preconditionFailure("Unverified helper was started") } catch {}
        precondition(calls.isEmpty, "An old helper must not receive --listen and accidentally toggle the screen")
        let contents = helper.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": ScreenInputContract.controllerID, "CFBundleExecutable": "ScreenGuard", "CFBundlePackageType": "APPL", "ScreenInputRulesVersion": 1]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        try manager.apply([keyboard])
        let job = try PropertyListSerialization.propertyList(from: Data(contentsOf: agent), format: nil) as! [String: Any]
        precondition(job["ProgramArguments"] as? [String] == [helper.appendingPathComponent("Contents/MacOS/ScreenGuard").path, "--listen"], "Login startup must listen without invoking a screen action")
        precondition(!calls.contains { $0.contains("--request-input-access") }, "Saving a rule cannot automatically prompt for input permission")
        try manager.apply([])
        precondition(!FileManager.default.fileExists(atPath: agent.path) && calls.last?.contains("bootout") == true, "Removing the last input rule removes its login job")
        print("PASS: input-listener opt-in, portable launch arguments, old-helper rejection and removal; no real job or input monitor started.")
    }
}
