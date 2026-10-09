import Foundation

/// One press read: it may run from the press until `afterRelease` seconds
/// after the key comes up. A reader stops at that deadline and publishes what
/// it found. A stage that needs the read waits for it, up to the same deadline.
final class PressRead: @unchecked Sendable {

    /// The time, and a way to pass it. Tests pass a fake one.
    struct Clock: Sendable {
        var now: @Sendable () -> Double
        var sleep: @Sendable (Double) async -> Void

        static let system = Clock(
            now: { CFAbsoluteTimeGetCurrent() },
            sleep: { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) })
    }

    /// A walk checks its deadline between elements, so one in flight can
    /// overrun it by two call timeouts of 0.1 s (`Read.walk`).
    static let grace = 0.25
    static let poll = 0.005

    let run: Int
    let afterRelease: Double
    let clock: Clock
    private let lock = NSLock()
    private var releasedAt: Double?
    private var done = false
    private var abandoned = false

    init(run: Int, afterRelease: Double, clock: Clock = .system) {
        (self.run, self.afterRelease, self.clock) = (run, afterRelease, clock)
    }

    /// Pure. No deadline before the release.
    static func isPast(releasedAt: Double?, afterRelease: Double, now: Double) -> Bool {
        releasedAt.map { now >= $0 + afterRelease } ?? false
    }

    /// The first call counts: the key-up, before the release tail ends the recording.
    func release() {
        lock.withLock { if releasedAt == nil { releasedAt = clock.now() } }
    }

    /// For the reader, between elements.
    var mustStop: Bool {
        Self.isPast(releasedAt: lock.withLock { releasedAt }, afterRelease: afterRelease, now: clock.now())
    }

    /// The reader is done. `publish` is told whether the result is kept, and
    /// runs before a waiter can see the read done, so a waiter never finds an
    /// empty slot. Not kept when a waiter gave up first: the stage and
    /// `context_spelling` then never see two answers.
    @discardableResult
    func finish(publish: (Bool) -> Void = { _ in }) -> Bool {
        lock.withLock {
            let kept = !abandoned
            publish(kept)
            done = true
            return kept
        }
    }

    /// Until the read is done or its deadline has passed. True when it is
    /// done. The stage runs after the recording ended, so a read not yet
    /// released is released here.
    func wait() async -> Bool {
        release()
        let end = (lock.withLock { releasedAt } ?? clock.now()) + afterRelease + Self.grace
        while true {
            let settled: Bool? = lock.withLock {
                guard done || clock.now() >= end else { return nil }
                if !done { abandoned = true }
                return done
            }
            if let settled { return settled }
            await clock.sleep(Self.poll)
        }
    }
}
