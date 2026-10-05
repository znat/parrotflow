import Foundation

/// Time left on something that can be held: running, paused, or run out.
struct Countdown: Equatable {

    enum State: Equatable {
        case running(remaining: TimeInterval, since: Date)
        case paused(remaining: TimeInterval)
        case expired
    }

    let duration: TimeInterval
    private(set) var state: State

    init(duration: TimeInterval, start: Date) {
        self.duration = duration
        state = .running(remaining: duration, since: start)
    }

    func remaining(at now: Date) -> TimeInterval {
        switch state {
        case .running(let remaining, let since):
            return max(0, remaining - now.timeIntervalSince(since))
        case .paused(let remaining):
            return remaining
        case .expired:
            return 0
        }
    }

    func fraction(at now: Date) -> Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, remaining(at: now) / duration))
    }

    var deadline: Date? {
        guard case .running(let remaining, let since) = state else { return nil }
        return since.addingTimeInterval(remaining)
    }

    var isPaused: Bool {
        if case .paused = state { return true }
        return false
    }

    mutating func pause(at now: Date) {
        guard case .running = state else { return }
        let left = remaining(at: now)
        state = left > 0 ? .paused(remaining: left) : .expired
    }

    mutating func resume(at now: Date) {
        guard case .paused(let remaining) = state else { return }
        state = .running(remaining: remaining, since: now)
    }
}
