import Foundation

/// UI phases, plus a one-shot request to put the display to sleep.
/// Execute `sleepNow` immediately; do not store it as a pending action.
enum GuardPhase: Equatable {
    case inactive
    case waitingForWake
    case initialReminder
    case reminder
    case countdown(Int)
    case sleepNow
}

/// Pure timing logic. Supply monotonic time (for example, systemUptime),
/// and call all methods on the same serial executor as the sleep/UI actions.
struct GuardState {
    private enum Mode {
        case inactive
        case starting(deadline: TimeInterval)
        case waitingForSleep(retryAt: TimeInterval)
        case sleeping
        case awake(since: TimeInterval)
    }

    private var mode: Mode = .inactive

    var isEnabled: Bool {
        if case .inactive = mode { return false }
        return true
    }

    mutating func enable(now: TimeInterval) -> GuardPhase {
        requestSleep(now: now)
    }

    mutating func startCountdown(now: TimeInterval) -> GuardPhase {
        mode = .starting(deadline: now + 5)
        return .initialReminder
    }

    mutating func disable() -> GuardPhase {
        mode = .inactive
        return .inactive
    }

    /// Only a real display-sleep notification arms the next wake window.
    mutating func screenDidSleep(now: TimeInterval) -> GuardPhase {
        guard isEnabled else { return .inactive }
        mode = .sleeping
        return .waitingForWake
    }

    mutating func screenDidWake(now: TimeInterval) -> GuardPhase {
        if case .sleeping = mode {
            mode = .awake(since: now)
        }
        return tick(now: now)
    }

    /// Poll freely. Refreshes and duplicate wake notifications never reset time.
    mutating func tick(now: TimeInterval) -> GuardPhase {
        switch mode {
        case .inactive:
            return .inactive
        case .sleeping:
            return .waitingForWake
        case .starting(let deadline):
            if now >= deadline { return requestSleep(now: now) }
            if now < deadline - 2 { return .initialReminder }
            return .countdown(Int(ceil(deadline - now)))
        case .waitingForSleep(let retryAt):
            return now >= retryAt ? requestSleep(now: now) : .waitingForWake
        case .awake(let startedAt):
            let elapsed = max(0, now - startedAt)
            if elapsed >= 20 { return requestSleep(now: now) }
            if elapsed < 3 { return .reminder }
            return .countdown(Int(ceil(20 - elapsed)))
        }
    }

    private mutating func requestSleep(now: TimeInterval) -> GuardPhase {
        // An unconfirmed sleep command never unlocks a fresh wake window.
        // Retry from the actual request time so a delayed timer cannot burst.
        mode = .waitingForSleep(retryAt: now + 20)
        return .sleepNow
    }
}
