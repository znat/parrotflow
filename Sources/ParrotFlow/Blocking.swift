import Foundation

/// Runs one async call from a synchronous command and waits for it.
///
/// The commands are `main.swift` top level, which is synchronous.
enum Blocking {
    static func run<T>(_ body: @escaping @Sendable () async -> T) -> T {
        let box = Box<T>()
        let done = DispatchSemaphore(value: 0)
        Task { box.value = await body(); done.signal() }
        done.wait()
        guard let value = box.value else {
            // `done` is only signalled after `value` is set, so this cannot
            // happen; a crash here would be better than a wrong answer.
            fatalError("the async call signalled without a result")
        }
        return value
    }

    private final class Box<T>: @unchecked Sendable {
        var value: T?
    }
}
