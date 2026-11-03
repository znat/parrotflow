import Foundation

/// `--word-vector "<sentence>" <word> [--around]` — the vector, as numbers.
///
///     ParrotFlow --word-vector "I deploy my app on Vercel." Vercel
///     tokens 3   norm 1.0000
///     +0.0212 -0.0147 +0.0331 ...
///
/// Exists so the Swift path can be checked against the Python one that measured
/// the thresholds. The two must agree to about four decimals; if they drift,
/// every number in the plan was measured on a different function from the one
/// that ships.
///
/// `--around` gives the other vector — every token except the word's — which is
/// what a term's stored portrait is made of.
@available(macOS 14, *)
enum WordVectorCommand {

    static func run(sentence: String, word: String, around: Bool) -> Int32 {
        let side: WordVectors.Side = around ? .around : .word
        let result = Blocking.run { () async -> Result<[Float], Error> in
            do {
                return .success(try await WordVectors.shared.vector(side, of: word, in: sentence))
            } catch {
                return .failure(error)
            }
        }
        switch result {
        case .failure(let error):
            print("✗ \(error.localizedDescription)")
            return 1
        case .success(let vector):
            let norm = (vector.reduce(0.0) { $0 + Double($1) * Double($1) }).squareRoot()
            let picked = Blocking.run { await WordVectors.shared.lastPicked }
            let count = Blocking.run { await WordVectors.shared.lastCount }
            print("tokens \(count)   taken \(picked)")
            print("dimensions \(vector.count)   norm \(String(format: "%.4f", norm))")
            print(vector.prefix(8).map { String(format: "%+.4f", $0) }.joined(separator: " "))
            return 0
        }
    }
}

/// Runs one async call from a synchronous command and waits for it.
///
/// The commands in this file are `main.swift` top level, which is synchronous.
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
