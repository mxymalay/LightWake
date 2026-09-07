import AppKit
import UniformTypeIdentifiers

final class InputRulesSettingsView: NSView {
    private let store: ScreenInputRuleStore
    private let service: ScreenInputServiceManager
    private var draft = ScreenInputRule()
    private var recorder: Any?
    private let selector = NSPopUpButton()
    private let name = NSTextField()
    private let enabled = NSButton(checkboxWithTitle: "启用这条规则", target: nil, action: nil)
    private let kind = NSPopUpButton()
    private let action = NSPopUpButton()
    private let record = NSButton(title: "录制按键…", target: nil, action: nil)
    private let key = NSTextField(wrappingLabelWithString: "")
    private let onlyResting = NSButton(checkboxWithTitle: "仅在熄屏、锁屏或自动熄屏模式时执行", target: nil, action: nil)
    private let application = NSTextField(wrappingLabelWithString: "仅控制屏幕")
    private let folder = NSTextField(wrappingLabelWithString: "未指定项目文件夹")
    private let mapping = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let copy = NSButton(title: "复制此规则的映射命令", target: nil, action: nil)

    init(store: ScreenInputRuleStore = ScreenInputRuleStore(), service: ScreenInputServiceManager = ScreenInputServiceManager()) {
        self.store = store; self.service = service
        super.init(frame: .zero)
        selector.target = self; selector.action = #selector(selectRule)
        kind.addItems(withTitles: ["键盘快捷键", "鼠标按键", "外部映射按键（如手柄）"])
        kind.target = self; kind.action = #selector(changeKind)
        action.addItems(withTitles: ["亮屏并打开目标", "切换屏幕；恢复亮屏时打开目标"])
        action.target = self; action.action = #selector(changeAction)
        record.target = self; record.action = #selector(beginRecording)
        copy.target = self; copy.action = #selector(copyMapping)
        let title = NSTextField(labelWithString: "一个按键，一条规则")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: "选择具体按键和对应的应用或项目文件夹。只有这条规则被触发时才执行；普通亮屏不打开目标。")
        let effects = NSTextField(wrappingLabelWithString: "键盘和鼠标规则启用后会在登录时监听指定按键，需要系统的输入监控授权；原按键仍会传给其他应用。不会记录输入内容，也不会自动解锁。")
        effects.textColor = .secondaryLabelColor
        effects.font = .systemFont(ofSize: 11)
        for field in [key, application, folder, mapping, status] { field.font = .systemFont(ofSize: 12); field.textColor = .secondaryLabelColor }
        let save = button("保存规则", #selector(saveRule))
        let remove = button("删除规则", #selector(deleteRule))
        let permission = button("授权输入监控…", #selector(requestPermission))
        let stack = NSStackView(views: [title, detail, selector, row("规则名称", name),
            row("通过哪种按键", kind), horizontal([record, key]), row("触发后的动作", action), onlyResting,
            horizontal([button("选择应用…", #selector(chooseApplication)), button("清除应用", #selector(clearApplication)), application]),
            horizontal([button("选择项目文件夹…", #selector(chooseFolder)), button("清除文件夹", #selector(clearFolder)), folder]),
            mapping, copy, enabled, effects, horizontal([save, remove, permission]), status])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20), stack.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -16)])
        for field in [detail, mapping, effects, status] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        selector.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        reloadSelector(select: store.load().first?.id)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    private func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }
    private func horizontal(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .horizontal; stack.spacing = 8; stack.alignment = .centerY
        return stack
    }
    private func row(_ title: String, _ view: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: 108).isActive = true
        view.widthAnchor.constraint(equalToConstant: 370).isActive = true
        return horizontal([label, view])
    }
    private func reloadSelector(select id: String? = nil) {
        selector.removeAllItems(); selector.addItem(withTitle: "＋ 新建规则")
        for rule in store.load() {
            selector.addItem(withTitle: (rule.enabled ? "" : "已停用 · ") + rule.name)
            selector.lastItem?.representedObject = rule.id
        }
        if let id, let item = selector.itemArray.first(where: { $0.representedObject as? String == id }) { selector.select(item) }
        selectRule()
    }
    @objc private func selectRule() {
        endRecording()
        let id = selector.selectedItem?.representedObject as? String
        draft = store.load().first(where: { $0.id == id }) ?? ScreenInputRule()
        if id == nil { draft.enabled = false }
        name.stringValue = draft.name
        enabled.state = draft.enabled ? .on : .off
        kind.selectItem(at: ScreenInputKind.allCases.firstIndex(of: draft.kind)!)
        action.selectItem(at: draft.action == .wake ? 0 : 1)
        onlyResting.state = draft.onlyWhileResting ? .on : .off
        refresh()
    }
    private func refresh() {
        key.stringValue = draft.kind == .mapped ? "由映射工具指定具体按键" : draft.keyLabel
        record.isEnabled = draft.kind != .mapped
        copy.isEnabled = draft.kind == .mapped
        onlyResting.isEnabled = action.indexOfSelectedItem == 0
        application.stringValue = draft.target.applicationName ?? draft.target.applicationIdentifier ?? "仅控制屏幕"
        folder.stringValue = draft.target.folderPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "未指定项目文件夹"
        folder.toolTip = draft.target.folderPath
        mapping.stringValue = draft.kind == .mapped
            ? (draft.id == ScreenInputContract.legacyRuleID ? KarabinerBindingReader.legacySummary() : "在手柄或映射工具中，把所选按键绑定到此规则的命令。每条规则使用独立入口。")
            : "点击“录制按键”，然后在此窗口按下需要的按键或鼠标按钮；Esc 取消。"
    }
    @objc private func changeKind() { endRecording(); draft.kind = ScreenInputKind.allCases[kind.indexOfSelectedItem]; draft.code = nil; draft.keyLabel = "尚未录制"; refresh() }
    @objc private func changeAction() { draft.action = action.indexOfSelectedItem == 0 ? .wake : .toggle; refresh() }
    @objc private func beginRecording() {
        endRecording(); key.stringValue = "请按下指定按键（Esc 取消）…"
        recorder = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown && event.keyCode == 53 { self.endRecording(); self.refresh(); return nil }
            if (self.draft.kind == .keyboard && event.type != .keyDown) || (self.draft.kind == .mouse && event.type == .keyDown) { return event }
            self.draft.code = self.draft.kind == .keyboard ? Int(event.keyCode) : event.buttonNumber
            self.draft.modifiers = ScreenInputModifiers.bits(event.modifierFlags)
            let functions = [122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"]
            let mouseNames = [0: "鼠标左键", 1: "鼠标右键", 2: "鼠标中键", 3: "鼠标侧键 1", 4: "鼠标侧键 2"]
            let label = self.draft.kind == .mouse ? (mouseNames[event.buttonNumber] ?? "鼠标按钮 \(event.buttonNumber + 1)")
                : functions[Int(event.keyCode)] ?? event.charactersIgnoringModifiers?.uppercased() ?? "键码 \(event.keyCode)"
            self.draft.keyLabel = ScreenInputModifiers.label(self.draft.modifiers) + label
            self.endRecording(); self.refresh(); return nil
        }
    }
    private func endRecording() { if let recorder { NSEvent.removeMonitor(recorder) }; recorder = nil }
    @objc private func chooseApplication() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]; panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications"); panel.prompt = "选择应用"
        guard panel.runModal() == .OK, let url = panel.url, let identifier = Bundle(url: url)?.bundleIdentifier else { return }
        guard ScreenInputContract.validApplication(identifier) else { showError("请选择其他应用，避免轻醒递归调用自身。"); return }
        draft.target.applicationIdentifier = identifier
        draft.target.applicationName = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        refresh()
    }
    @objc private func clearApplication() { draft.target.applicationIdentifier = nil; draft.target.applicationName = nil; refresh() }
    @objc private func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "选择项目文件夹"
        if panel.runModal() == .OK { draft.target.folderPath = panel.url?.path; refresh() }
    }
    @objc private func clearFolder() { draft.target.folderPath = nil; refresh() }
    @objc private func copyMapping() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("open -g '\(draft.triggerURL)'", forType: .string)
        status.stringValue = "已复制这条规则的命令；保存并启用后，绑定到对应按键即可。"
    }
    @objc private func saveRule() {
        endRecording()
        draft.name = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.enabled = enabled.state == .on
        draft.action = action.indexOfSelectedItem == 0 ? .wake : .toggle
        draft.onlyWhileResting = draft.action == .wake && onlyResting.state == .on
        let previous = store.load()
        var rules = previous.filter { $0.id != draft.id }; rules.append(draft)
        do {
            try store.save(rules)
            do { try service.apply(rules) } catch { try store.save(previous); throw error }
            let id = draft.id; reloadSelector(select: id)
            status.stringValue = draft.enabled && draft.kind != .mapped
                ? "规则已保存。若尚未授权，请点击“授权输入监控”，在系统设置中允许轻醒按键，然后再次保存规则。"
                : "规则已保存。只有对应按键触发时才执行。"
        } catch { showError(error.localizedDescription) }
    }
    @objc private func deleteRule() {
        guard selector.selectedItem?.representedObject != nil else { return }
        let previous = store.load(); let rules = previous.filter { $0.id != draft.id }
        do {
            try store.save(rules)
            do { try service.apply(rules) } catch { try store.save(previous); throw error }
            reloadSelector(); status.stringValue = "规则已删除。"
        } catch { showError(error.localizedDescription) }
    }
    @objc private func requestPermission() {
        do { try service.requestInputPermission(); status.stringValue = "请在系统设置中允许“轻醒按键”监听输入，再回到这里保存规则。" }
        catch { showError(error.localizedDescription) }
    }
    private func showError(_ message: String) { let alert = NSAlert(); alert.messageText = "未能保存按键规则"; alert.informativeText = message; alert.runModal() }
    deinit { endRecording() }
}
