import AXKit
import ApplicationServices
import Foundation

/// `--tree-read <bundle-id> --compare [--runs N]` — `TreeContext` and the
/// reader `Context.read` picks for Slack, on the same element, N times. It
/// prints counts only, never message text or names: it runs on somebody's real
/// Slack.
extension TreeReadCommand {

    /// One reader's output, cut into the keys the `context` stage publishes.
    struct Published {
        var place = ""
        var people: [String] = []
        var code: [String] = []
        var roster: [String] = []
        var text = ""
        var chars = 0
        var lines = 0
        var truncated = false
        var declined = "none"

        init(_ outcome: Result<Context.Capture, Context.Declined>) {
            switch outcome {
            case .failure(let why):
                declined = why.rawValue
            case .success(let got):
                (place, people, code, roster) = (got.place, got.people, got.code, got.roster)
                (text, chars, lines, truncated) = (got.text, got.chars, got.lines, got.truncated)
            }
        }
    }

    static let keys = ["place", "people", "code", "roster", "text", "chars", "lines", "truncated", "declined"]

    static func compare(_ name: String, starts: [AXUIElement], runs: Int) -> Int32 {
        let slack = Pipeline.App(name: name, bundleID: ContextReader.slackBundleID)
        var anyDiffers = false
        for (number, start) in starts.enumerated() {
            print("\(name) — start \(number + 1) of \(starts.count), \(runs) runs")
            var notes: [String: [String]] = [:]
            var times: [(old: Double, new: Double)] = []
            var last: Published?
            for run in 1...runs {
                var old: (Published, Double)?
                var new: (Published, Double, ReadResult?, Bool)?
                let readOld = { old = timed { Published(TreeContext.read(from: start)) } }
                let readNew = {
                    let (got, ms) = timed { Published(Context.read(app: slack, from: start, settings: Context.Settings())) }
                    let (screen, walk) = SlackReader.screen(from: Element(start))
                    new = (got, ms, walk, SlackReader.locate(screen.path, in: screen.window) != nil)
                }
                // Alternated, so neither reader always gets the tree the other warmed.
                if run % 2 == 1 { readOld(); readNew() } else { readNew(); readOld() }
                guard let (before, oldMs) = old, let (after, newMs, walk, located) = new else { continue }
                times.append((oldMs, newMs))
                last = before
                let walked = walk.map {
                    "\($0.records.count) records, \($0.calls) calls, \($0.failed) failed"
                        + ($0.stopped.map { ", stopped by \($0.rawValue)" } ?? "")
                } ?? "no window"
                print(String(format: "run %d  old %.0fms  new %.0fms  ", run, oldMs, newMs)
                    + "(\(walked), focus \(located ? "located" : "not located"))")
                for (key, note) in differences(before, after) {
                    notes[key, default: []].append("run \(run): \(note)")
                }
            }
            for key in keys {
                let label = key.padding(toLength: 10, withPad: " ", startingAt: 0)
                if let found = notes[key] {
                    print("\(label) differs  \(found.joined(separator: "; "))")
                } else if let last {
                    print("\(label) same  (\(summary(of: key, in: last)))")
                }
            }
            let olds = times.map { String(format: "%.0f", $0.old) }.joined(separator: ", ")
            let news = times.map { String(format: "%.0f", $0.new) }.joined(separator: ", ")
            if notes.isEmpty {
                print("✓ same on every key in \(times.count) runs; old \(olds) ms, new \(news) ms")
            } else {
                anyDiffers = true
                print("✗ differs: \(keys.filter { notes[$0] != nil }.joined(separator: ", "));"
                    + " old \(olds) ms, new \(news) ms")
            }
        }
        return anyDiffers ? 1 : 0
    }

    private static func timed<T>(_ body: () -> T) -> (T, Double) {
        let started = Date()
        let value = body()
        return (value, Date().timeIntervalSince(started) * 1000)
    }

    /// Sizes only. The values are someone's messages and colleagues.
    static func summary(of key: String, in got: Published) -> String {
        switch key {
        case "place": return "\(got.place.count) chars"
        case "people": return "\(got.people.count)"
        case "code": return "\(got.code.count)"
        case "roster": return "\(got.roster.count)"
        case "text": return "\(got.text.isEmpty ? 0 : got.text.components(separatedBy: "\n").count) lines"
        case "chars": return "\(got.chars)"
        case "lines": return "\(got.lines)"
        case "truncated": return got.truncated ? "yes" : "no"
        default: return got.declined
        }
    }

    static func differences(_ old: Published, _ new: Published) -> [(key: String, note: String)] {
        var found: [(String, String)] = []
        if old.place != new.place { found.append(("place", "\(old.place.count) vs \(new.place.count) chars")) }
        for (key, a, b) in [("people", old.people, new.people), ("code", old.code, new.code),
                            ("roster", old.roster, new.roster)] where a != b {
            found.append((key, "\(a.count) vs \(b.count), first differing item \(firstDifference(a, b))"))
        }
        if old.text != new.text {
            let a = old.text.components(separatedBy: "\n"), b = new.text.components(separatedBy: "\n")
            found.append(("text", "\(a.count) vs \(b.count) lines, first differing line \(firstDifference(a, b))"))
        }
        if old.chars != new.chars { found.append(("chars", "\(old.chars) vs \(new.chars)")) }
        if old.lines != new.lines { found.append(("lines", "\(old.lines) vs \(new.lines)")) }
        if old.truncated != new.truncated { found.append(("truncated", "\(old.truncated) vs \(new.truncated)")) }
        if old.declined != new.declined { found.append(("declined", "\(old.declined) vs \(new.declined)")) }
        return found
    }

    /// Zero-based. Equal up to the shorter one means the first extra item.
    private static func firstDifference(_ a: [String], _ b: [String]) -> Int {
        zip(a, b).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(a.count, b.count)
    }
}
