import AppKit

@main
struct NoticeAnimationTests {
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let notice = ScreenNotice()
        defer { notice.hide() }
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }
        func advance(_ seconds: TimeInterval) {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
        }
        func save(_ view: NSView, name: String) throws {
            view.layoutSubtreeIfNeeded()
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
        }

        notice.show(title: "屏幕将临时亮起 20 秒", subtitle: "双击桌面上的「开启屏幕」可取消")
        check(!notice.panels.isEmpty, "The banner must appear on an attached screen")
        let expanded = notice.panels.map(\.frame)
        check(notice.panels.allSatisfy { $0.isVisible && !$0.isKeyWindow && $0.ignoresMouseEvents },
              "Notice stays visible without capturing keyboard or mouse input")
        try save(notice.panels[0].contentView!, name: "banner-preview.png")
        notice.showCountdown(seconds: 17)
        advance(0.12)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            for (panel, start) in zip(notice.panels, expanded) {
                check(panel.frame.minX < start.minX && panel.frame.width < start.width && panel.frame.width > 100,
                      "The banner moves left and shrinks through intermediate positions")
            }
        }
        advance(0.5)
        for (panel, screen) in zip(notice.panels, NSScreen.screens) {
            let gap = screen.visibleFrame.maxY - panel.frame.maxY
            check(panel.frame.width < 100 && panel.frame.height < 100,
                  "The countdown becomes a compact card")
            check((0...40).contains(panel.frame.minX - screen.visibleFrame.minX) && (0...40).contains(gap),
                  "The card sits inside the desktop upper-left corner below the menu bar")
        }
        check(notice.shownTitle == nil && notice.shownSeconds == 17, "Compact view presents only the remaining number")
        try save(notice.panels[0].contentView!, name: "corner-countdown-preview.png")
        let compactFrames = notice.panels.map(\.frame)
        for seconds in [16, 5, 4, 1] {
            notice.showCountdown(seconds: seconds)
            check(notice.panels.map(\.frame) == compactFrames && notice.shownTitle == nil,
                  "Later seconds, including the last five, stay at the corner without a new banner")
        }

        notice.show(title: "屏幕将在 5 秒后关闭", subtitle: "双击「开启屏幕」可取消")
        notice.showCountdown(seconds: 2)
        advance(0.08)
        notice.hide()
        advance(0.5)
        check(notice.panels.allSatisfy { !$0.isVisible } && notice.shownSeconds == nil,
              "Cancelling during motion cannot bring the countdown back")

        notice.show(title: "屏幕将在 5 秒后关闭", subtitle: "双击「开启屏幕」可取消")
        notice.showCountdown(seconds: 2)
        advance(0.08)
        notice.show(title: "屏幕将在 5 秒后关闭", subtitle: "双击「开启屏幕」可取消")
        let restarted = notice.panels.map(\.frame)
        advance(0.5)
        check(notice.panels.map(\.frame) == restarted && notice.shownSeconds == nil && notice.shownTitle != nil,
              "Reopening during motion cancels the old flight and restores the full reminder")
        print("PASS: \(checks) native animation, positioning, and cancellation checks; previews saved.")
    }
}
