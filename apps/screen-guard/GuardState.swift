import Foundation

enum GuardSession: Equatable {
    case unlocked
    case locked
    /// This user does not own the console, or its state cannot be established.
    case unavailable
}

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
    private var session: GuardSession = .unlocked

    /// Authentication belongs to macOS and has no LightWake timeout. Returning
    /// to the desktop grants a fresh visible window, discarding old deadlines.
    @discardableResult
    mutating func updateSession(_ newSession: GuardSession, now: TimeInterval) -> Bool {
        guard newSession != session else { return false }
        session = newSession
        if newSession == .unlocked && isEnabled {
            mode = .awake(since: now)
        }
        return true
    }

    var isEnabled: Bool {
        if case .inactive = mode { return false }
        return true
    }

    mutating func enable(now: TimeInterval) -> GuardPhase {
        requestSleep(now: now)
    }

    mutating func startCountdown(now: TimeInterval) -> GuardPhase {
        mode = .starting(deadline: now + 5)
        return visible(.initialReminder)
    }

    mutating func disable() -> GuardPhase {
        mode = .inactive
        return .inactive
    }

    /// A real display-sleep notification arms the next display-wake window.
    /// A confirmed desktop-session return may also start a fresh window.
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
        guard session == .unlocked else {
            return isEnabled ? .waitingForWake : .inactive
        }
        switch mode {
        case .inactive:
            return .inactive
        case .sleeping:
            return .waitingForWake
        case .starting(let deadline):
            if now >= deadline { return requestSleep(now: now) }
            if now < deadline - 2 { return visible(.initialReminder) }
            return visible(.countdown(Int(ceil(deadline - now))))
        case .waitingForSleep(let retryAt):
            return now >= retryAt ? requestSleep(now: now) : .waitingForWake
        case .awake(let startedAt):
            let elapsed = max(0, now - startedAt)
            if elapsed >= 20 { return requestSleep(now: now) }
            if elapsed < 3 { return visible(.reminder) }
            return visible(.countdown(Int(ceil(20 - elapsed))))
        }
    }

    private func visible(_ phase: GuardPhase) -> GuardPhase {
        session == .unlocked ? phase : .waitingForWake
    }

    private mutating func requestSleep(now: TimeInterval) -> GuardPhase {
        // An unconfirmed sleep command never unlocks a fresh wake window.
        // Retry from the actual request time so a delayed timer cannot burst.
        mode = .waitingForSleep(retryAt: now + 20)
        // A queued request is never permission to interrupt authentication.
        return session == .unlocked ? .sleepNow : .waitingForWake
    }
}
