import Foundation

enum ScreenInputKind: String, Codable, CaseIterable { case keyboard, mouse, mapped }
enum ScreenRuleAction: String, Codable { case wake, toggle }

struct ScreenRuleTarget: Codable, Equatable {
    var applicationIdentifier: String?
    var applicationName: String?
    var folderPath: String?
}

struct ScreenInputRule: Codable, Equatable, Identifiable {
    var id = UUID().uuidString.lowercased()
    var name = "新规则"
    var enabled = true
    var kind = ScreenInputKind.keyboard
    var code: Int? = nil
    // Stable, device-independent modifier bits: command, option, control, shift.
    var modifiers: UInt64 = 0
    var keyLabel = "尚未录制"
    var action = ScreenRuleAction.wake
    var onlyWhileResting = true
    var target = ScreenRuleTarget()

    var triggerURL: String { "lightwake://trigger/\(id)" }
    func matches(kind: ScreenInputKind, code: Int, modifiers: UInt64) -> Bool {
        enabled && self.kind == kind && self.code == code && self.modifiers == modifiers
    }
}

enum ScreenInputContract {
    static let version = 1
    static let legacyRuleID = "legacy-toggle"
    static let controllerID = "local.xy.screen-guard-control"
    static let reloadNotification = "local.xy.lightwake.input-rules-changed"
    static func mappedRuleID(from url: URL) -> String? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "lightwake", parts.host == "trigger", parts.port == nil,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else { return nil }
        let id = String(parts.path.dropFirst())
        guard parts.path == "/" + id, validID(id) else { return nil }
        return id
    }
    static func validID(_ id: String) -> Bool {
        id == legacyRuleID || UUID(uuidString: id) != nil
    }
    static func validApplication(_ identifier: String) -> Bool {
        let own = [controllerID, "local.xy.turn-off-display", "local.xy.turn-on-display", "local.xy.lightwake-settings"]
        return identifier.count <= 255 && !own.contains(identifier)
            && identifier.range(of: "^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+$", options: .regularExpression) != nil
    }
}

final class ScreenInputRuleStore {
    struct Document: Codable { var version = 1; var rules: [ScreenInputRule] }
    let fileURL: URL
    init(fileURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ScreenGuard/input-rules.json")) { self.fileURL = fileURL }
    func load() -> [ScreenInputRule] {
        guard let bytes = try? Data(contentsOf: fileURL), bytes.count <= 65536,
              let document = try? JSONDecoder().decode(Document.self, from: bytes), document.version == 1,
              (try? validate(document.rules)) != nil else { return [] }
        return document.rules
    }
    func save(_ rules: [ScreenInputRule]) throws {
        try validate(rules)
        let bytes = try JSONEncoder().encode(Document(rules: rules))
        guard bytes.count <= 65536 else { throw error("规则过多，请减少规则。") }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
    func mappedRule(_ id: String) -> ScreenInputRule? {
        load().first { $0.enabled && $0.kind == .mapped && $0.id == id }
    }
    private func validate(_ rules: [ScreenInputRule]) throws {
        guard rules.count <= 40 else { throw error("最多保存 40 条规则。") }
        var ids = Set<String>(), inputs = Set<String>()
        for rule in rules {
            guard ScreenInputContract.validID(rule.id), ids.insert(rule.id).inserted,
                  !rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, rule.name.count <= 80,
                  rule.modifiers <= 15 else { throw error("规则名称或标识无效。") }
            if rule.kind != .mapped {
                guard let code = rule.code, (0...(rule.kind == .keyboard ? 127 : 31)).contains(code) else {
                    throw error("请先录制具体的键盘或鼠标按键。")
                }
                if rule.enabled && !inputs.insert("\(rule.kind.rawValue):\(code):\(rule.modifiers)").inserted {
                    throw error("同一个按键组合只能启用一条规则，请修改冲突的规则。")
                }
            }
            if let app = rule.target.applicationIdentifier, !ScreenInputContract.validApplication(app) {
                throw error("目标应用无效，或会递归调用轻醒自身。")
            }
            if let path = rule.target.folderPath, !path.hasPrefix("/") || path.contains("\0") || path.count > 4096 {
                throw error("请选择有效的项目文件夹。")
            }
        }
    }
    private func error(_ message: String) -> Error {
        NSError(domain: "LightWake.InputRules", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

enum KarabinerBindingReader {
    static func legacySummary(at file: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/karabiner/karabiner.json")) -> String {
        guard let bytes = try? Data(contentsOf: file), bytes.count < 8388608,
              let data = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
              let profiles = data["profiles"] as? [[String: Any]],
              let profile = profiles.first(where: { $0["selected"] as? Bool == true }),
              let modifications = profile["complex_modifications"] as? [String: Any],
              let rules = modifications["rules"] as? [[String: Any]] else { return "未检测到现有 Karabiner 映射。" }
        var found: [String] = []
        for rule in rules {
            for mapping in rule["manipulators"] as? [[String: Any]] ?? [] {
                let outputs = ["to", "to_if_alone", "to_if_held_down", "to_after_key_up"].flatMap { mapping[$0] as? [[String: Any]] ?? [] }
                let matches = outputs.contains { output in
                    guard let software = output["software_function"] as? [String: Any],
                          let application = software["open_application"] as? [String: Any] else { return false }
                    return application["bundle_identifier"] as? String == ScreenInputContract.controllerID
                        || (application["file_path"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent == "轻醒按键.app" } == true
                }
                guard matches, let from = mapping["from"] as? [String: Any] else { continue }
                let button = from["pointing_button"] as? String ?? from["key_code"] as? String ?? "未知按键"
                let conditions = mapping["conditions"] as? [[String: Any]] ?? []
                let joycon = conditions.contains { condition in
                    (condition["identifiers"] as? [[String: Any]] ?? []).contains { $0["vendor_id"] as? Int == 1406 && $0["product_id"] as? Int == 8199 }
                }
                found.append(joycon && button == "button13" ? "Joy-Con HOME（button13）" : button)
            }
        }
        return found.isEmpty ? "未检测到现有 Karabiner 映射。" : "现有兼容入口：" + found.joined(separator: "、")
    }
}
