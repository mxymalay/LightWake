import Foundation

enum ScreenButtonAction: String {
    case startCountdown, keepScreenOn, none
}

enum ScreenButtonState {
    static func action(guardActive: Bool, session: GuardSession, displayAsleep: Bool) -> ScreenButtonAction {
        guard session != .unavailable else { return .none }
        return guardActive || displayAsleep || session == .locked ? .keepScreenOn : .startCountdown
    }
}
