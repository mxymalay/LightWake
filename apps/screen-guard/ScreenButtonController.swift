import AppKit
import OSLog

final class ScreenButtonController {
    typealias ApplicationOpener = (String, Bool, @escaping (Error?) -> Void) -> Void
    typealias TargetOpener = (ScreenRuleTarget, @escaping (Error?) -> Void) -> Void
    private let store: ScreenControlStore
    private let now: () -> TimeInterval
    private let sessionStatus: () -> GuardSession
    private let displayAsleep: () -> Bool
    private let guardRunning: () -> Bool
    private let wakeDisplay: () throws -> Void
    private let openApplication: ApplicationOpener
    private let openTarget: TargetOpener
    private let rules: ScreenInputRuleStore
    private var lastPress: [String: TimeInterval] = [:]
    private var opening = false
    private var queued: (ScreenInputRule, Bool)?
    private var pendingTarget: ScreenInputRule?
    private var targetTimer: Timer?
    private var needsDesktopSettling = false
    private var desktopReadySince: TimeInterval?
    private let logger = Logger(subsystem: "local.xy.screen-guard", category: "controller-button")

    init(store: ScreenControlStore = ScreenControlStore(),
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sessionStatus: @escaping () -> GuardSession = ScreenGuardController.currentSession,
         displayAsleep: @escaping () -> Bool = { CGDisplayIsAsleep(CGMainDisplayID()) != 0 },
         guardRunning: @escaping () -> Bool = {
             !NSRunningApplication.runningApplications(withBundleIdentifier: "local.xy.turn-off-display").isEmpty
         },
         wakeDisplay: @escaping () throws -> Void = ScreenButtonController.wakeDisplay,
         openApplication: @escaping ApplicationOpener = ScreenButtonController.openApplication,
         openTarget: @escaping TargetOpener = ScreenButtonController.openTarget,
         rules: ScreenInputRuleStore = ScreenInputRuleStore()) {
        self.store = store
        self.now = now
        self.sessionStatus = sessionStatus
        self.displayAsleep = displayAsleep
        self.guardRunning = guardRunning
        self.wakeDisplay = wakeDisplay
        self.openApplication = openApplication
        self.openTarget = openTarget
        self.rules = rules
    }

    deinit { targetTimer?.invalidate() }

    func press() {
        var legacy = rules.mappedRule(ScreenInputContract.legacyRuleID) ?? ScreenInputRule()
        if FileManager.default.fileExists(atPath: rules.fileURL.path) {
            guard let configured = rules.mappedRule(ScreenInputContract.legacyRuleID) else { return }
            legacy = configured
        } else {
            // Compatibility with existing app-open mappings: screen toggle only.
            legacy.id = ScreenInputContract.legacyRuleID
            legacy.kind = .mapped; legacy.action = .toggle; legacy.onlyWhileResting = false
        }
        perform(legacy)
    }

    func perform(_ rule: ScreenInputRule, recentlyResting: Bool = false) {
        guard rule.enabled else { return }
        let time = now()
        // A cold launch can also deliver a reopen event. Treat that burst as
        // one physical press, and never let it immediately undo itself.
        guard time - (lastPress[rule.id] ?? -.infinity) >= 0.18 else { return }
        lastPress[rule.id] = time
        if opening { queued = (rule, recentlyResting); return }
        handle(rule, recentlyResting: recentlyResting)
    }

    private func handle(_ rule: ScreenInputRule, recentlyResting: Bool) {
        let mode = (try? String(contentsOf: store.modeFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let active = mode != nil && mode != "" && mode != "off" && guardRunning()
        let session = sessionStatus()
        let asleep = displayAsleep()
        guard session != .unavailable else { return }
        if rule.action == .wake && rule.onlyWhileResting && !active && !asleep && session != .locked && !recentlyResting { return }
        let action = rule.action == .toggle
            ? ScreenButtonState.action(guardActive: active, session: session, displayAsleep: asleep) : .keepScreenOn
        logger.info("Button action=\(action.rawValue, privacy: .public) guard=\(active) asleep=\(asleep) session=\(String(describing: session), privacy: .public)")
        switch action {
        case .none:
            return
        case .startCountdown:
            cancelPendingTarget()
            opening = true
            openApplication("local.xy.turn-off-display", false) { [weak self] error in
                self?.finishedOpening(error)
            }
        case .keepScreenOn:
            cancelPendingTarget()
            // Cancel under the same mode-file lock as pmset before launching
            // anything. A nearly expired countdown cannot win a launch race.
            do {
                try store.write("off")
                DistributedNotificationCenter.default().postNotificationName(stopNotification, object: nil, userInfo: nil, deliverImmediately: true)
                try wakeDisplay()
            } catch {
                logger.error("Could not keep display on: \(error.localizedDescription, privacy: .public)")
                return
            }
            opening = true
            openApplication("local.xy.turn-on-display", false) { [weak self] error in
                guard let self else { return }
                if let error { self.logger.error("On app: \(error.localizedDescription, privacy: .public)") }
                if rule.target.applicationIdentifier != nil || rule.target.folderPath != nil {
                    self.pendingTarget = rule
                    self.needsDesktopSettling = session != .unlocked || asleep
                    // Poll only while an explicitly triggered target is pending.
                    // These state reads do not request display wake or unlock.
                    let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.checkPendingTarget() }
                    timer.tolerance = 0.04
                    self.targetTimer = timer
                    RunLoop.main.add(timer, forMode: .common)
                    self.logger.info("Target queued; waiting for an unlocked, awake desktop if necessary")
                }
                self.finishedOpening(nil)
            }
        }
    }

    func checkPendingTarget() {
        guard !opening, let rule = pendingTarget else { return }
        // A changed/deleted rule or a new screen-off mode revokes an old request.
        guard store.matches("off"), rules.load().contains(rule) else {
            logger.info("Pending target cancelled: rule or screen mode changed")
            cancelPendingTarget()
            return
        }
        guard sessionStatus() == .unlocked, !displayAsleep() else {
            needsDesktopSettling = true
            desktopReadySince = nil
            return
        }
        if needsDesktopSettling {
            guard let readySince = desktopReadySince else { desktopReadySince = now(); return }
            // Authentication can finish before the lock-screen transition does.
            // Require a stable desktop; relocking or switching sessions resets it.
            guard now() - readySince >= 0.6 else { return }
        }
        cancelPendingTarget()
        opening = true
        logger.info("Opening explicit rule target on the unlocked desktop")
        openTarget(rule.target) { [weak self] error in self?.finishedOpening(error) }
    }

    private func cancelPendingTarget() {
        targetTimer?.invalidate()
        targetTimer = nil
        pendingTarget = nil
        desktopReadySince = nil
        needsDesktopSettling = false
    }

    private func finishedOpening(_ error: Error?) {
        opening = false
        if let error { logger.error("Application launch: \(error.localizedDescription, privacy: .public)") }
        if let (rule, recentlyResting) = queued {
            queued = nil
            handle(rule, recentlyResting: recentlyResting)
        }
        checkPendingTarget()
    }

    private static func openTarget(_ target: ScreenRuleTarget, completion: @escaping (Error?) -> Void) {
        let folder = target.folderPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let folder {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                completion(NSError(domain: "LightWake.InputRules", code: 2, userInfo: [NSLocalizedDescriptionKey: "项目文件夹不存在，请在轻醒设置中重新选择。"])); return
            }
        }
        guard let identifier = target.applicationIdentifier else {
            if let folder { _ = NSWorkspace.shared.open(folder) }
            completion(nil); return
        }
        guard ScreenInputContract.validApplication(identifier),
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
            completion(NSError(domain: "LightWake.InputRules", code: 3, userInfo: [NSLocalizedDescriptionKey: "目标应用未安装，请在轻醒设置中重新选择。"])); return
        }
        if identifier == "com.openai.codex", let folder {
            // Codex publishes `codex app [PATH]` for workspace opening. Passing
            // a folder as an ordinary document does not reliably select it.
            let executable = app.appendingPathComponent("Contents/Resources/codex")
            guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                completion(NSError(domain: "LightWake.InputRules", code: 4, userInfo: [NSLocalizedDescriptionKey: "此 Codex 版本没有项目打开工具，请更新 Codex，或仅选择打开应用。"])); return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process(); process.executableURL = executable; process.arguments = ["app", folder.path]
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                do {
                    try process.run(); process.waitUntilExit()
                    let error: Error? = process.terminationStatus == 0 ? nil
                        : NSError(domain: "LightWake.InputRules", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "Codex 未能打开所选项目文件夹。"])
                    DispatchQueue.main.async { completion(error) }
                } catch { DispatchQueue.main.async { completion(error) } }
            }
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        let finished: (NSRunningApplication?, Error?) -> Void = { _, error in DispatchQueue.main.async { completion(error) } }
        if let folder {
            NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: configuration, completionHandler: finished)
        } else {
            NSWorkspace.shared.openApplication(at: app, configuration: configuration, completionHandler: finished)
        }
    }

    private static func wakeDisplay() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-u", "-t", "2"]
        try process.run()
    }

    private static func openApplication(identifier: String, activates: Bool, completion: @escaping (Error?) -> Void) {
        let siblingNames = ["local.xy.turn-off-display": "关闭屏幕.app", "local.xy.turn-on-display": "开启屏幕.app"]
        let sibling = siblingNames[identifier].map { Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent($0) }
        let url = sibling.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
        guard let url else {
            completion(NSError(domain: "ScreenGuard", code: 1, userInfo: [NSLocalizedDescriptionKey: "找不到应用：\(identifier)"]))
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activates
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            DispatchQueue.main.async { completion(error) }
        }
    }
}
