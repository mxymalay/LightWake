import Foundation

@main
struct StopRunningGuard {
    static func main() throws {
        try ScreenControlStore().write("off")
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("local.xy.screen-guard.turn-on"),
            object: nil, userInfo: nil, deliverImmediately: true
        )
        print("Cancelled previous screen guard before updating.")
    }
}
