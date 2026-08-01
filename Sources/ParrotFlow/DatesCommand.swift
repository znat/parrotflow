import Foundation

/// `--dates "<instruction>" "<text>"` — runs the deterministic date and time
/// rewriter and prints the result, applying nothing.
///
/// The same shape as `--prompt`, deliberately, so the two can be scored against
/// each other on one set: scripts/check-dates.sh runs this, and
/// scripts/validate-generic.py runs the model over the same cases.
enum DatesCommand {

    static func run(
        instruction: String, text: String, quiet: Bool = false, languages: [String]? = nil
    ) -> Int32 {
        // Only for the language a spelled month is written in. `--lang` lets a
        // case file say which languages it assumes rather than inheriting
        // whatever this machine configured — the French cases scored 24/27 on a
        // config listing only English, and nothing about the dates was wrong.
        let languages = languages
            ?? (try? ConfigStore.load())?.transcription.languages ?? ["en"]

        let started = Date()
        let result = DateRewriter.apply(
            instruction: instruction, to: text, languages: languages
        )
        let elapsed = Date().timeIntervalSince(started)

        if quiet {
            print(result)
        } else {
            let request = DateRewriter.request(for: instruction)
            print("instruction: \"\(instruction)\"")
            print("read as:     \(request)")
            print("in:          \(text)")
            print("out:         \(result)")
            print(String(format: "             no model, %.1fms", elapsed * 1000))
        }
        return 0
    }
}
