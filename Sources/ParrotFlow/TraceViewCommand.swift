import AppKit
import Foundation

/// `--trace-view [wav]` — turns a dictation's timeline into something a trace
/// viewer will draw, and prints where it went.
///
/// The corpus stays ours. Chrome's Trace Event format is what every viewer
/// reads, but it is a poor thing to keep: `args` is untyped, and a file written
/// for a flamegraph answers none of the questions `docs/cli.md` asks. So
/// `spans.jsonl` holds the shape we designed and this converts a line of it on
/// demand.
///
/// The output opens at https://ui.perfetto.dev — "Open trace file", or drag it
/// on. Perfetto parses in the browser and uploads nothing, which matters
/// because a trace carries what you said.
///
/// `--redacted` is what makes one safe to send to somebody else. **Timings
/// survive redaction perfectly and text does not**, so dropping every field
/// that holds words leaves the shape, the durations and the model calls
/// intact: a timeline with nothing said in it still shows that the phoneme
/// pass took 817 ms.
enum TraceViewCommand {

    /// Nesting in Trace Event format is inferred from time containment on a
    /// track, not from a parent id — so the arms, which overlap, need tracks of
    /// their own or the viewer draws them as one impossible stack.
    private static let mainTrack = 1

    /// Says something to whoever is watching, never to whatever is reading.
    ///
    /// stdout belongs to the transcript. A `command:` transform is handed the
    /// text on stdin and whatever it prints becomes the new text — so a path
    /// printed here would replace the dictation with a path. Everything a
    /// person reads goes to stderr, which the runner logs and the terminal
    /// shows.
    private static func say(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// Gives the transcript back untouched, when this was run as a transform.
    ///
    /// The chip's whole point is to act and leave the sentence alone —
    /// `finishOfferedTransform` writes nothing back when the text is unchanged,
    /// so returning exactly what arrived is what makes it safe. A terminal has
    /// a tty on stdin and nothing to pass through, and reading there would hang
    /// waiting for a sentence nobody is going to type.
    private static func passThrough() {
        guard isatty(FileHandle.standardInput.fileDescriptor) == 0 else { return }
        guard let text = try? FileHandle.standardInput.readToEnd() else { return }
        FileHandle.standardOutput.write(text)
    }

    static func run(_ arguments: [String]) -> Int32 {
        defer { passThrough() }
        guard let directory = (try? ConfigStore.load())?.resolvedOutputDir else {
            say("✗ no output directory; check `--check-config`")
            return 1
        }
        let url = directory.appendingPathComponent(Trace.spansFile)
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            say("✗ no \(url.path)")
            say("  Set `logging.spans: true` and dictate once.")
            return 1
        }

        let redacted = arguments.contains("--redacted")
        // The other output. Perfetto zooms, which text cannot, and a long
        // dictation with a reading on every boundary is where that earns its
        // keep. Everything else is easier to read as a page of text.
        let perfetto = arguments.contains("--perfetto")
        let wanted = value(of: "--trace-view", in: arguments)
        guard let line = pick(wanted, from: contents) else {
            say("✗ no timeline for \(wanted ?? "the last live dictation") in \(url.path)")
            return 1
        }

        guard perfetto else {
            guard let text = TraceText.render(line, notes: !redacted) else {
                say("✗ that line carries no spans")
                return 1
            }
            // A terminal gets it on stdout, where it can be piped, diffed
            // against yesterday's, or read where you already are. Anything
            // else — the chip — is not attached to a terminal and gets a file
            // opened in front of it.
            guard isatty(FileHandle.standardInput.fileDescriptor) == 0 else {
                print(text)
                return 0
            }
            let out = view(for: line, redacted: redacted, extension: "txt")
            guard (try? Data((text + "\n").utf8).write(to: out)) != nil else {
                say("✗ could not write \(out.path)")
                return 1
            }
            if !arguments.contains("--no-open") { NSWorkspace.shared.open(out) }
            say(out.path)
            return 0
        }

        guard let events = try? convert(line, redacted: redacted) else {
            say("✗ that line is not a timeline this build understands")
            return 1
        }
        let out = view(for: line, redacted: redacted, extension: "json")
        guard (try? events.write(to: out)) != nil else {
            say("✗ could not write \(out.path)")
            return 1
        }
        say(out.path)
        if redacted {
            say("  No transcript, no app name, no notes — timings only. Safe to attach.")
        } else {
            say("  Holds what you said. `--redacted` for a copy that does not.")
        }
        // Dragged, not linked. `?url=` is HTTPS-only — measured: an https page
        // will not fetch http://127.0.0.1, whatever the localhost exemption
        // does elsewhere — and the alternative is putting your dictations on a
        // public host to look at a chart.
        say("  Drag it onto https://ui.perfetto.dev — it parses in the browser.")
        return 0
    }

    /// `--trace-edits` — proves that what a stage recorded replays.
    ///
    /// `v: 3` keeps what a stage changed instead of both versions of the
    /// sentence, so the corpus is only as good as this: apply the edits in
    /// order to the text a stage was handed, and you must get what it produced.
    /// Nothing at run time reads an edit, so a bug here cannot damage a
    /// transcript — it can quietly make the whole corpus wrong, which nothing
    /// else would say.
    ///
    /// Cases and fuzz. The cases are the shapes that actually turn up — a
    /// repeated word, a spoken number, a lowercased name, accents, emoji — and
    /// the fuzz is there because the ones that break a diff are never the ones
    /// anybody thinks to write down.
    static func checkEdits() -> Int32 {
        let cases: [(String, String)] = [
            ("the 98.3 percent is is about", "the 98.3 percent is about"),
            ("nothing changes", "nothing changes"),
            ("", "everything appeared"),
            ("everything vanished", ""),
            ("parrot. At the start", "parrot at the start"),
            ("ninety-eight point three", "98.3"),
            ("naïve café über", "naive cafe uber"),
            ("👋 hello 🌍", "👋 goodbye 🌍"),
            ("Sarah went to Versailles", "sarah went to versailles"),
            ("a b c d e", "a X c Y e"),
            ("repeated repeated repeated", "repeated"),
        ]

        var failed = 0
        for (before, after) in cases {
            let edits = Trace.edits(from: before, to: after)
            guard let replayed = Trace.replay(edits, over: before), replayed == after else {
                print("✗ \(before.debugDescription) -> \(after.debugDescription)")
                failed += 1
                continue
            }
        }

        // The same property over shapes nobody chose. Punctuation and spaces
        // are in the alphabet because those are what the marks stages move.
        let alphabet = Array("abcde .,")
        var generator = SystemRandomNumberGenerator()
        // By index rather than `randomElement()!`: the array is a literal and
        // cannot be empty, but a check that says so beats one the compiler has
        // to be told to skip.
        func letter() -> Character {
            alphabet[Int.random(in: 0..<alphabet.count, using: &generator)]
        }
        var fuzzed = 0
        for _ in 0..<5000 {
            let length = Int.random(in: 0...40, using: &generator)
            let before = String((0..<length).map { _ in letter() })
            var mutated = Array(before)
            for _ in 0..<Int.random(in: 0...5, using: &generator) where !mutated.isEmpty {
                let at = Int.random(in: 0..<mutated.count, using: &generator)
                switch Int.random(in: 0...2, using: &generator) {
                case 0: mutated.remove(at: at)
                case 1: mutated.insert(letter(), at: at)
                default: mutated[at] = letter()
                }
            }
            let after = String(mutated)
            fuzzed += 1
            let edits = Trace.edits(from: before, to: after)
            if Trace.replay(edits, over: before) != after {
                print("✗ fuzz: \(before.debugDescription) -> \(after.debugDescription)")
                failed += 1
                break
            }
        }

        // The note a stage's span carries. A different question from replay:
        // this one is read by a person, so what it says is the whole of it.
        let summaries: [(String, String, String?)] = [
            ("there is a lot of borderplay in this file",
             "there is a lot of boilerplate in this file",
             "borderplay -> boilerplate"),
            ("ask Gwen about sarah", "ask Qwen about Sarah",
             "Gwen -> Qwen, sarah -> Sarah"),
            ("um I think so", "I think so", "um -> \"\""),
            ("I think so", "I really think so", "\"\" -> really"),
            ("nothing changes", "nothing changes", nil),
            ("spacing   only", "spacing only", "spacing"),
            ("one two three four five six seven eight",
             "eight seven six five four three two one",
             "7 words -> \"\", \"\" -> 7 words"),
        ]
        for (before, after, want) in summaries {
            let got = Trace.changeSummary(from: before, to: after)
            guard got == want else {
                print("✗ summary \(before.debugDescription): got"
                    + " \(got.debugDescription), wanted \(want.debugDescription)")
                failed += 1
                continue
            }
        }
        // Never wider than the row it sits on, whatever a stage did.
        for (before, after) in cases + summaries.map({ ($0.0, $0.1) }) {
            let note = Trace.changeSummary(from: before, to: after) ?? ""
            guard note.count <= 60 else {
                print("✗ note is \(note.count) characters: \(note)")
                failed += 1
                continue
            }
        }

        print(failed == 0
            ? "✓ \(cases.count) cases, \(summaries.count) summaries"
                + " and \(fuzzed) fuzzed pairs replay exactly"
            : "✗ \(failed) failed")
        return failed == 0 ? 0 : 1
    }

    /// `--trace-spans` — hammers the collector from many tasks at once.
    ///
    /// The decode arms run as sibling tasks and each closes its own span, so
    /// several threads append to one array. That is the one failure in this
    /// whole feature that could take the app down rather than write a wrong
    /// number: an unlocked array append from two threads is memory corruption,
    /// not a bad reading.
    ///
    /// Run it under the thread sanitizer to prove the locking, and without to
    /// prove the arithmetic:
    ///
    ///     swift build -c debug --sanitize=thread && .build/debug/ParrotFlow --trace-spans
    static func checkSpans() -> Int32 {
        var status: Int32 = 0
        let done = DispatchSemaphore(value: 0)
        Task {
            status = await hammerSpans()
            done.signal()
        }
        done.wait()
        return status
    }

    private static func hammerSpans() async -> Int32 {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrotflow-spans-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }

        // Under `Trace.spanLimit`, so this measures the locking rather than
        // the cap. The cap gets its own assertion below.
        let wanted = 200
        let was = Trace.spansEnabled
        Trace.spansEnabled = true
        defer { Trace.spansEnabled = was }

        await Trace.record(wav: "check.wav", source: .cli, beside: scratch) {
            // A stage span open over the whole of it, so the concurrent ones
            // are reading `openParent` while others are writing it.
            let stage = Trace.current?.open("stage", kind: .stage, nests: true)
            await withTaskGroup(of: Void.self) { group in
                for index in 0..<wanted {
                    group.addTask {
                        let span = Trace.current?.open("arm \(index)", kind: .decode)
                        span?.close("reached 1.00s")
                    }
                }
            }
            stage?.close()
        }
        Trace.flush()

        let url = scratch.appendingPathComponent(Trace.spansFile)
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let line = text.split(separator: "\n").first,
              let data = line.data(using: .utf8),
              let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let spans = record["spans"] as? [[String: Any]]
        else {
            print("✗ no timeline written to \(url.path)")
            return 1
        }

        // Every span, and every id distinct. A lost append and a reused id are
        // the two shapes a race takes here.
        let ids = Set(spans.compactMap { $0["id"] as? Int })
        let arms = spans.filter { $0["kind"] as? String == "decode" }
        var failed = 0
        if arms.count != wanted {
            print("✗ \(arms.count) of \(wanted) concurrent spans survived")
            failed += 1
        }
        if ids.count != spans.count {
            print("✗ \(spans.count - ids.count) duplicate span id(s)")
            failed += 1
        }
        // Each one filed under the stage that was open while it ran.
        let orphans = arms.filter { $0["parent"] as? Int == nil }
        if !orphans.isEmpty {
            print("✗ \(orphans.count) concurrent span(s) lost their parent")
            failed += 1
        }
        // And the cap holds, which is the other half: a runaway dictation must
        // stop growing the array rather than grow it without end.
        if spans.count > Trace.spanLimit {
            print("✗ \(spans.count) spans got past the \(Trace.spanLimit) limit")
            failed += 1
        }
        if failed == 0 {
            print("✓ \(wanted) spans closed from \(wanted) tasks at once, "
                + "all present, parented and under the limit")
        }
        return failed == 0 ? 0 : 1
    }

    /// Where a rendered trace goes: the temporary directory, named after the
    /// clip it describes.
    ///
    /// Named, because one fixed name means the second press rewrites a file an
    /// editor already has open — and an editor shows you the buffer it loaded,
    /// so you read the previous dictation and believe it is this one. That
    /// happened.
    ///
    /// Temporary, because this is a view and not a record. `spans.jsonl` is
    /// what keeps the timeline; these are one rendering of one line of it, and
    /// leaving a file in the recordings folder every time somebody looks at a
    /// dictation would bury the clips. The system clears them out, which is the
    /// right owner for something regenerated by one command.
    private static func view(
        for record: [String: Any], redacted: Bool, extension suffix: String
    ) -> URL {
        let stem = (record["wav"] as? String).map {
            URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "parrotflow-", with: "")
        } ?? "last"
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("trace-\(stem)\(redacted ? "-redacted" : "").\(suffix)")
    }

    /// The last **live** dictation, not the last line. The file also holds
    /// replays from `--transcribe`, and a replay is not what you just said.
    /// The newest matching timeline, found from the end of the file.
    ///
    /// Backwards because the answer is almost always the last line, and this
    /// file is capped at 64 MB: parsing all of it forward to keep the final
    /// hit is work for a file that is written far more often than it is read.
    private static func pick(_ wav: String?, from contents: String) -> [String: Any]? {
        for line in contents.split(separator: "\n").reversed() {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let record = object as? [String: Any],
                  record["spans"] != nil
            else { continue }
            if let wav {
                if (record["wav"] as? String)?.contains(wav) == true { return record }
            } else if record["source"] as? String == "live" {
                return record
            }
        }
        return nil
    }

    private static func convert(_ record: [String: Any], redacted: Bool) throws -> Data {
        guard let spans = record["spans"] as? [[String: Any]] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // One track per overlapping arm. Everything else shares the main one,
        // where the viewer's own nesting rules do the work.
        var track = mainTrack
        var tracks: [String: Int] = [:]
        var events: [[String: Any]] = []

        for span in spans.sorted(by: { ($0["at"] as? Double ?? 0) < ($1["at"] as? Double ?? 0) }) {
            let name = span["name"] as? String ?? "?"
            let kind = span["kind"] as? String ?? "part"
            let at = span["at"] as? Double ?? 0
            let dur = span["dur"] as? Double ?? 0

            if kind == "decode" {
                track += 1
                tracks[name] = track
            }
            var args: [String: Any] = ["kind": kind]
            // A note can quote a word — "0 of 12 over the floor" cannot, but
            // "sarah -> Sarah" can, and nothing here can tell them apart. So a
            // redacted trace drops all of them.
            if !redacted, let note = span["note"] as? String { args["note"] = note }

            events.append([
                "ph": "X", "name": name, "cat": kind,
                "pid": 1, "tid": tracks[name] ?? mainTrack,
                // Trace Event time is microseconds.
                "ts": (at * 1_000_000).rounded(),
                "dur": max(1, (dur * 1_000_000).rounded()),
                "args": args,
            ])
        }
        // Names the lanes, so a decode arm reads as itself rather than as
        // "thread 2".
        for (name, id) in tracks {
            events.append([
                "ph": "M", "name": "thread_name", "pid": 1, "tid": id,
                "args": ["name": name],
            ])
        }
        events.append([
            "ph": "M", "name": "thread_name", "pid": 1, "tid": mainTrack,
            "args": ["name": redacted
                ? "dictation"
                : record["app"].flatMap { ($0 as? [String: Any])?["name"] as? String }
                    ?? "dictation"],
        ])

        var payload: [String: Any] = ["traceEvents": events]
        guard !redacted else {
            // The span names stay: `first pass`, `vocabulary`, `sound` are the
            // app's own vocabulary and hold nothing anybody said.
            return try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
        }
        // What was said, on the trace itself, so a timeline and its transcript
        // cannot be separated by the time someone is looking at both.
        if let final = record["final"] as? String { payload["parrotflow.final"] = final }
        if let wav = record["wav"] as? String { payload["parrotflow.wav"] = wav }
        return try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
    }

    private static func value(of flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1),
              !arguments[index + 1].hasPrefix("--")
        else { return nil }
        return arguments[index + 1]
    }
}
