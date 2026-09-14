import Foundation
import Darwin

/// Process freezing is withdrawn after a real lock/unlock stall. Reading the
/// settings remains inert; old installations can still opt out and clean up.
final class QuietProtectionManager {
    static let resourceNames = ["quiet_service_guard.py", "quiet_desktop_check.py", "quiet-sky.mjs"]
    static let label = "local.xy.lightwake.quiet-desktop"
    static let unavailableReason = "进程暂停保护已停用：实测出现指纹解锁卡住，兼容性尚未解决。按键规则仍可正常配置。"
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
            return count > 0 ? "旧版保护正在关闭：仍有待恢复服务，暂勿再次锁屏；若解锁卡住请停止测试。" : Self.unavailableReason
        }
        return "检测到旧版保护仍开启，请取消勾选以停止暂停服务。此版本不再支持重新开启。"
    }

    @discardableResult
    func enable(confirmed: Bool) throws -> Bool {
        guard confirmed else { return false }
        throw failure(Self.unavailableReason)
    }

    func disable() throws {
        // The running helper stops acquiring new suspensions and cleans up its
        // own journal only once the desktop is ready. Never SIGCONT here.
        guard isEnabled else { return }
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
