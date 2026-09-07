import Foundation
import Darwin

/// Installing the apps or reading this object never installs a background job.
/// Only enable(confirmed: true), called after the user's UI confirmation, does.
final class QuietProtectionManager {
    static let resourceNames = ["quiet_service_guard.py", "quiet_desktop_check.py", "quiet-sky.mjs"]
    static let label = "local.xy.lightwake.quiet-desktop"
    private struct Preferences: Codable {
        var enabled: Bool
        var consentVersion: Int
    }
    let directory: URL
    let resources: URL
    let launchAgents: URL
    private let run: ([String]) throws -> Int32
    var preferencesURL: URL { directory.appendingPathComponent("preferences.json") }
    var agentURL: URL { launchAgents.appendingPathComponent(Self.label + ".plist") }
    private var domain: String { "gui/\(getuid())" }

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScreenGuard/QuietDesktop", isDirectory: true),
         resources: URL = (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("quiet-desktop"),
         launchAgents: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents"),
         run: @escaping ([String]) throws -> Int32 = QuietProtectionManager.runCommand) {
        self.directory = directory
        self.resources = resources
        self.launchAgents = launchAgents
        self.run = run
    }

    var isEnabled: Bool {
        guard let bytes = try? Data(contentsOf: preferencesURL), bytes.count <= 4096,
              let preferences = try? JSONDecoder().decode(Preferences.self, from: bytes) else { return false }
        return preferences.enabled && preferences.consentVersion == 1
    }

    var statusText: String {
        let ownedURL = directory.appendingPathComponent("runtime/owned.json")
        let owned = (try? Data(contentsOf: ownedURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let count = (owned?["owned"] as? [Any])?.count ?? 0
        if !isEnabled {
            return count > 0 ? "正在关闭：等待正常亮屏、解锁并退出自动熄屏模式后恢复服务。" : "已关闭。不会暂停 Codex 的电脑操作服务。"
        }
        if count > 0 { return "保护中：电脑操作服务已暂停。" }
        let statusURL = directory.appendingPathComponent("runtime/status.json")
        guard let info = try? FileManager.default.attributesOfItem(atPath: statusURL.path),
              let modified = info[.modificationDate] as? Date, Date().timeIntervalSince(modified) < 30 else {
            return "已启用，等待后台状态。若长时间没有更新，请关闭后重新开启。"
        }
        return "已启用。熄屏、锁屏或自动熄屏模式中会暂停电脑操作服务。"
    }

    @discardableResult
    func enable(confirmed: Bool) throws -> Bool {
        guard confirmed else { return false }
        for name in Self.resourceNames {
            guard FileManager.default.fileExists(atPath: resources.appendingPathComponent(name).path) else {
                throw failure("安装文件不完整，请重新构建并复制「轻醒设置.app」。")
            }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("runtime"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        for name in Self.resourceNames {
            let target = directory.appendingPathComponent(name)
            try Data(contentsOf: resources.appendingPathComponent(name)).write(to: target, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        }
        let job: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": ["/usr/bin/python3", directory.appendingPathComponent("quiet_service_guard.py").path, "run"],
            "RunAtLoad": true, "KeepAlive": ["SuccessfulExit": false], "ThrottleInterval": 5,
            "ProcessType": "Background", "LimitLoadToSessionType": "Aqua",
            "WorkingDirectory": directory.path,
            "StandardOutPath": directory.appendingPathComponent("runtime/launchd.stdout.log").path,
            "StandardErrorPath": directory.appendingPathComponent("runtime/launchd.stderr.log").path
        ]
        try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0).write(to: agentURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: agentURL.path)
        try writePreference(true)
        do {
            let loaded = try run(["/bin/launchctl", "print", domain + "/" + Self.label]) == 0
            let arguments = loaded ? ["/bin/launchctl", "kickstart", "-k", domain + "/" + Self.label]
                : ["/bin/launchctl", "bootstrap", domain, agentURL.path]
            let code = try run(arguments)
            guard code == 0 else { throw failure("后台保护启动失败（错误码 \(code)），已保持关闭。") }
        } catch {
            try writePreference(false)
            throw error
        }
        return true
    }

    func disable() throws {
        // The running helper stops acquiring new suspensions and cleans up its
        // own journal only once the desktop is ready. Never SIGCONT here.
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try writePreference(false)
    }

    private func writePreference(_ enabled: Bool) throws {
        let bytes = try JSONEncoder().encode(Preferences(enabled: enabled, consentVersion: 1))
        try bytes.write(to: preferencesURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: preferencesURL.path)
    }

    private func failure(_ message: String) -> Error {
        NSError(domain: "LightWake.QuietProtection", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func runCommand(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
