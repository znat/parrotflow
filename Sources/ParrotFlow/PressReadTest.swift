import ApplicationServices
import Foundation

/// `--tree-test`, last part: the press read's deadline and the stage's wait,
/// on a fake clock.
enum PressReadTest {

    /// Time passes only when someone sleeps or walks. Events run when their time comes.
    final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        /// In microseconds, so steps add up exactly.
        private var time = 0
        private var events: [(at: Int, run: () -> Void)] = []

        var clock: PressRead.Clock {
            PressRead.Clock(now: { self.now }, sleep: { self.advance($0) })
        }

        private static func micro(_ seconds: Double) -> Int { Int((seconds * 1_000_000).rounded()) }

        func at(_ when: Double, _ run: @escaping () -> Void) {
            lock.withLock { events.append((Self.micro(when), run)) }
        }

        func advance(_ seconds: Double) {
            let due: [() -> Void] = lock.withLock {
                time += Self.micro(seconds)
                let due = events.filter { $0.at <= time }.map(\.run)
                events.removeAll { $0.at <= time }
                return due
            }
            due.forEach { $0() }
        }

        var now: Double { Double(lock.withLock { time }) / 1_000_000 }
    }

    /// A walk of 10 ms per element that asks `mustStop` between elements, as
    /// `Read.walk` does. The key comes up at 1 s.
    static func walkStops(afterRelease: Double) -> String {
        let fake = FakeClock()
        let reading = PressRead(run: 1, afterRelease: afterRelease, clock: fake.clock)
        fake.at(1.0) { reading.release() }
        var elements = 0
        while !reading.mustStop, elements < 100_000 {
            fake.advance(0.01)
            elements += 1
        }
        return String(format: "%.2f", fake.now)
    }

    private static let element = AXUIElementCreateSystemWide()

    private static func press(_ run: Int, chars: Int) -> Context.Press {
        Context.Press(element: element,
                      outcome: .success(Context.Capture(text: String(repeating: "a", count: chars), truncated: false)),
                      ms: 1, run: run)
    }

    private static func described(_ settled: (press: Context.Press?, late: Bool)) -> String {
        if settled.late { return "late" }
        guard let press = settled.press else { return "noPress" }
        switch press.outcome {
        case .success(let capture): return "\(capture.chars) chars"
        case .failure(let why): return why.rawValue
        }
    }

    /// The stage asks at 0.1 s after the release; the read ends at `endsAt`.
    static func stage(endsAt: Double?, afterRelease: Double = 0.5) -> String {
        let fake = FakeClock()
        let reading = PressRead(run: 7, afterRelease: afterRelease, clock: fake.clock)
        let generation = Context.begin(reading)
        reading.release()
        var stored = "not stored"
        if let endsAt {
            fake.at(endsAt) {
                stored = Context.store(press(7, chars: 42), reading: reading, generation: generation, logs: false)
                    ? "stored" : "dropped"
            }
        }
        fake.advance(0.1)
        let got = blocking { await Context.settledPress(run: 7) }
        // A read that ends after the stage gave up must not be kept.
        if let endsAt, endsAt > fake.now { fake.advance(endsAt - fake.now) }
        let after = Context.pressCapture == nil ? "empty" : "kept"
        _ = Context.begin(nil)
        return "\(described(got)) at \(String(format: "%.2f", fake.now)), \(stored), slot \(after)"
    }

    /// The key comes up before the read has started: the reservation made at
    /// the press still takes the release.
    static func earlyRelease() -> String {
        let fake = FakeClock()
        let reading = PressRead(run: 9, afterRelease: 0.5, clock: fake.clock)
        _ = Context.begin(reading)
        Context.released()
        fake.advance(0.49)
        let before = reading.mustStop
        fake.advance(0.01)
        _ = Context.begin(nil)
        return "\(before) then \(reading.mustStop)"
    }

    /// Dictation 4's stage settles after press 5 stored its screen.
    static func newerPressHoldsTheSlot() -> String {
        let fake = FakeClock()
        let reading = PressRead(run: 5, afterRelease: 0.5, clock: fake.clock)
        let generation = Context.begin(reading)
        Context.store(press(5, chars: 42), reading: reading, generation: generation, logs: false)
        let older = described(blocking { await Context.settledPress(run: 4) })
        let newer = described(blocking { await Context.settledPress(run: 5) })
        _ = Context.begin(nil)
        return "\(older), \(newer)"
    }

    /// A waiter that sees the read done must also see what it published. The
    /// publication takes 50 ms here, real time; the waiter polls every 5 ms.
    static func doneMeansPublished() -> String {
        let reading = PressRead(run: 11, afterRelease: 5)
        reading.release()
        let published = Box<Bool>()
        published.value = false
        let started = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let seen = Box<String>()
        Task.detached {
            started.signal()
            let finished = await reading.wait()
            seen.value = "\(finished ? "done" : "late"), published \(published.value == true)"
            done.signal()
        }
        started.wait()
        Thread.sleep(forTimeInterval: 0.02)
        reading.finish { _ in
            Thread.sleep(forTimeInterval: 0.05)
            published.value = true
        }
        done.wait()
        return seen.value ?? "nothing"
    }

    /// No read at all: `--pipeline`, or a press with nothing focused.
    static func noRead() -> String {
        _ = Context.begin(nil)
        return described(blocking { await Context.settledPress(run: 3) })
    }

    private static func blocking<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
        let done = DispatchSemaphore(value: 0)
        let box = Box<T>()
        Task.detached {
            box.value = await body()
            done.signal()
        }
        done.wait()
        guard let value = box.value else { preconditionFailure("the task signalled without a value") }
        return value
    }

    private final class Box<T>: @unchecked Sendable { var value: T? }

    static func run() -> Int32 {
        let checks: [(what: String, got: String, want: String)] = [
            ("the walk stops 500 ms after the release", walkStops(afterRelease: 0.5), "1.50"),
            ("0 stops it at the release", walkStops(afterRelease: 0), "1.00"),
            ("the stage waits for a read still running", stage(endsAt: 0.3),
             "42 chars at 0.30, stored, slot kept"),
            ("a read done before the stage asks", stage(endsAt: 0.05), "42 chars at 0.10, stored, slot kept"),
            ("the stage stops waiting at the deadline and a grace of 0.25 s", stage(endsAt: nil),
             "late at 0.75, not stored, slot empty"),
            ("a read that ends after that is dropped", stage(endsAt: 2.0), "late at 2.00, dropped, slot empty"),
            ("no read running: noPress at once", noRead(), "noPress"),
            ("a release before the read starts still counts", earlyRelease(), "false then true"),
            ("a newer press's screen is not an older dictation's", newerPressHoldsTheSlot(), "noPress, 42 chars"),
            ("a waiter that sees the read done finds it published", doneMeansPublished(), "done, published true"),
        ]
        let failed = checks.filter { $0.got != $0.want }
        print(failed.isEmpty ? "✓ press read: \(checks.count) of \(checks.count)"
                             : "✗ press read: \(failed.count) of \(checks.count)")
        for check in failed { print("  \(check.what): want \(check.want), got \(check.got)") }
        return failed.isEmpty ? 0 : 1
    }
}
