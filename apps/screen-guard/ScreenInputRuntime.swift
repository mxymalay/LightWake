import AppKit

enum ScreenInputModifiers {
    static func bits(_ flags: CGEventFlags) -> UInt64 {
        (flags.contains(.maskCommand) ? 1 : 0) | (flags.contains(.maskAlternate) ? 2 : 0)
        | (flags.contains(.maskControl) ? 4 : 0) | (flags.contains(.maskShift) ? 8 : 0)
    }
    static func bits(_ flags: NSEvent.ModifierFlags) -> UInt64 {
        (flags.contains(.command) ? 1 : 0) | (flags.contains(.option) ? 2 : 0)
        | (flags.contains(.control) ? 4 : 0) | (flags.contains(.shift) ? 8 : 0)
    }
    static func label(_ bits: UInt64) -> String {
        [(UInt64(4), "⌃"), (2, "⌥"), (8, "⇧"), (1, "⌘")].filter { bits & $0.0 != 0 }.map(\.1).joined()
    }
}

/// Passive, explicit-rule matching. No text or input history is retained.
final class ScreenInputRuntime {
    private let store: ScreenInputRuleStore
    private let controller: ScreenButtonController
    private var rules: [ScreenInputRule] = []
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var observer: NSObjectProtocol?
    private var timer: Timer?
    private var lastResting: TimeInterval = -.infinity

    init(store: ScreenInputRuleStore = ScreenInputRuleStore(), controller: ScreenButtonController) {
        self.store = store; self.controller = controller
    }
    func start() {
        reload()
        observer = DistributedNotificationCenter.default().addObserver(forName: Notification.Name(ScreenInputContract.reloadNotification), object: nil, queue: .main) { [weak self] _ in self?.reload() }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Preserve the state just before a physical key wakes the display.
            if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { self.lastResting = ProcessInfo.processInfo.systemUptime }
        }
    }
    private func reload() {
        rules = store.load().filter { $0.enabled && $0.kind != .mapped }
        if let tap { CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
        let permission = CGPreflightListenEventAccess()
        if !rules.isEmpty && permission {
            let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
            tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                eventsOfInterest: mask, callback: { _, type, event, context in
                    guard let context else { return Unmanaged.passUnretained(event) }
                    let runtime = Unmanaged<ScreenInputRuntime>.fromOpaque(context).takeUnretainedValue()
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        if let tap = runtime.tap, CGPreflightListenEventAccess() { CGEvent.tapEnable(tap: tap, enable: true) }
                    } else { runtime.handle(type, event: event) }
                    return Unmanaged.passUnretained(event)
                }, userInfo: Unmanaged.passUnretained(self).toOpaque())
            if let tap {
                source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
                if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        let state: [String: Any] = ["permission": permission, "listening": tap != nil, "ruleCount": rules.count,
                                    "updatedAt": Date().timeIntervalSince1970]
        if let bytes = try? JSONSerialization.data(withJSONObject: state) {
            try? bytes.write(to: store.fileURL.deletingLastPathComponent().appendingPathComponent("input-rules-status.json"), options: .atomic)
        }
    }
    private func handle(_ type: CGEventType, event: CGEvent) {
        let kind: ScreenInputKind = type == .keyDown ? .keyboard : .mouse
        if kind == .keyboard && event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return }
        let code = Int(event.getIntegerValueField(kind == .keyboard ? .keyboardEventKeycode : .mouseEventButtonNumber))
        let modifiers = ScreenInputModifiers.bits(event.flags)
        guard let rule = rules.first(where: { $0.matches(kind: kind, code: code, modifiers: modifiers) }) else { return }
        let recentlyResting = ProcessInfo.processInfo.systemUptime - lastResting < 1
        if rule.action == .wake { lastResting = -.infinity }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.store.load().contains(rule) else { return }
            self.controller.perform(rule, recentlyResting: recentlyResting)
        }
    }
    deinit {
        timer?.invalidate()
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        if let tap { CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    }
}

final class ScreenInputServiceManager {
    static let label = "local.xy.lightwake.input-rules"
    private let run: ([String]) throws -> Int32
    let helper: URL
    let agentURL: URL
    init(helper: URL = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("轻醒按键.app"),
         agentURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist"),
         run: @escaping ([String]) throws -> Int32 = ScreenInputServiceManager.runCommand) {
        self.helper = helper; self.agentURL = agentURL; self.run = run
    }
    func apply(_ rules: [ScreenInputRule]) throws {
        DistributedNotificationCenter.default().postNotificationName(Notification.Name(ScreenInputContract.reloadNotification), object: nil, userInfo: nil, deliverImmediately: true)
        let domain = "gui/\(getuid())"
        let needed = rules.contains { $0.enabled && $0.kind != .mapped }
        if !needed {
            if FileManager.default.fileExists(atPath: agentURL.path) {
                _ = try run(["/bin/launchctl", "bootout", domain, agentURL.path])
                try FileManager.default.removeItem(at: agentURL)
            }
            return
        }
        try validateHelper()
        try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let job: [String: Any] = ["Label": Self.label, "ProgramArguments": [helper.appendingPathComponent("Contents/MacOS/ScreenGuard").path, "--listen"],
            "RunAtLoad": true, "KeepAlive": ["SuccessfulExit": false], "ProcessType": "Interactive", "LimitLoadToSessionType": "Aqua"]
        try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0).write(to: agentURL, options: .atomic)
        let loaded = try run(["/bin/launchctl", "print", domain + "/" + Self.label]) == 0
        if !loaded {
            guard try run(["/bin/launchctl", "bootstrap", domain, agentURL.path]) == 0 else {
                throw failure("按键服务启动失败，规则尚未生效。")
            }
        }
        DistributedNotificationCenter.default().postNotificationName(Notification.Name(ScreenInputContract.reloadNotification), object: nil, userInfo: nil, deliverImmediately: true)
    }
    func requestInputPermission() throws {
        try validateHelper()
        _ = try run([helper.appendingPathComponent("Contents/MacOS/ScreenGuard").path, "--request-input-access"])
        DistributedNotificationCenter.default().postNotificationName(Notification.Name(ScreenInputContract.reloadNotification), object: nil, userInfo: nil, deliverImmediately: true)
    }
    private func validateHelper() throws {
        guard let bundle = Bundle(url: helper), bundle.bundleIdentifier == ScreenInputContract.controllerID,
              bundle.object(forInfoDictionaryKey: "ScreenInputRulesVersion") as? Int == 1 else {
            throw failure("请将本次构建的「轻醒按键.app」与「轻醒设置.app」一起安装，再启用按键规则。")
        }
    }
    private func failure(_ text: String) -> Error { NSError(domain: "LightWake.InputRules", code: 4, userInfo: [NSLocalizedDescriptionKey: text]) }
    private static func runCommand(_ args: [String]) throws -> Int32 {
        let process = Process(); process.executableURL = URL(fileURLWithPath: args[0]); process.arguments = Array(args.dropFirst())
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); return process.terminationStatus
    }
}
