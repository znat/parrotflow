import AXKit
import AppKit
import ApplicationServices

/// `--tree-read <bundle-id>` — what the `context` stage would publish for an
/// app's front window, without that app being in front.
///
/// `--peek` reads whatever is frontmost, which is the right question when the
/// dictation is about to land there. It is the wrong tool for measuring an
/// app's tree: bringing the app forward to look at it is a race against
/// anything else that wants focus, and an overlay window wins it.
///
/// This reads by process id instead, through the same `Context.read` the press
/// uses, with every app on. It starts from the app's focused element, so it
/// answers for the pane that app is showing rather than for the one you are
/// dictating into.
enum TreeReadCommand {

    /// `runs` reads the same start again; the words are printed on the first run only.
    /// `titled` picks the window whose title contains it, read from the window
    /// down: a scratch window beside the ones in use.
    static func run(bundleID: String, runs: Int = 1, titled: String? = nil) -> Int32 {
        guard Permissions.accessibility == .granted else {
            print("✗ accessibility is not granted")
            return 1
        }
        guard let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID).first else {
            print("✗ not running: \(bundleID)")
            return 1
        }
        let named = Pipeline.App(name: running.localizedName ?? "", bundleID: bundleID)
        let reader: ContextReader
        switch ContextReader.choose(for: named, everyApp: true) {
        case .failure(let why):
            print("✗ \(why.rawValue)")
            return 1
        case .success(let chosen): reader = chosen
        }
        ChromiumAccessibility.askIfNeeded(running)

        let app = App(pid: running.processIdentifier)
        let picked = titled.flatMap { text in app.windows.first { $0.title?.contains(text) == true } }
        if titled != nil, picked == nil {
            print("✗ no window titled like that")
            return 1
        }
        let focused = picked == nil ? app.focusedElement : nil
        // `kAXWindowsAttribute` has no guaranteed order, so its first entry can
        // be a different window from the one holding the pane.
        guard let window = picked ?? focused?.window ?? app.focusedWindow ?? app.windows.first else {
            print("✗ no window")
            return 1
        }
        // An app in the background reports nothing focused. In Slack each
        // composer is then read as if the caret were in it; elsewhere the window.
        let composers = reader == .slack ? self.composers(in: window) : []
        let starts = focused.map { [$0] } ?? (composers.isEmpty ? [window] : composers)

        var settings = Context.Settings()
        settings.everyApp = true
        var read = false
        for (run, start) in (1...runs).flatMap({ run in starts.map { (run, $0) } }) {
            let started = Date()
            let outcome = Context.read(app: named, from: start.ref, settings: settings)
            let ms = Date().timeIntervalSince(started) * 1000
            print(String(format: "%@ — %.0fms", running.localizedName ?? bundleID, ms)
                + " (\(reader.rawValue))")
            // The description, not the value: a composer's value is the draft.
            if focused == nil, run == 1 { print("from    \(start.accessibilityDescription ?? start.role ?? "?")") }
            switch outcome {
            case .failure(let why):
                print("✗ \(why.rawValue)")
            case .success(let got):
                read = true
                // Counts only, so a run can be quoted without what was on screen.
                let lines = got.text.isEmpty ? 0 : got.text.components(separatedBy: "\n").count
                print("shape   source \(got.source), text \(lines) lines \(got.chars) chars,"
                    + " place \(got.place.count) chars, code \(got.code.count)"
                    + (got.walked.map { ", \($0.records) records, pane \($0.branch)"
                        + ($0.chromium ? " (chromium)" : "")
                        + ($0.stopped.map { ", stopped: \($0)" } ?? "") } ?? ""))
                guard run == 1 else { continue }
                print("place   \(got.place)")
                print("people  \(got.people.joined(separator: "; "))")
                print("code    \(got.code.joined(separator: "; "))")
                print("roster  \(got.roster.joined(separator: "; "))")
                print("text    \(got.chars) chars"
                    + (got.truncated ? " (the last \(Context.maxChars))" : ""))
                for row in got.text.components(separatedBy: "\n").prefix(40) where !got.text.isEmpty {
                    print("  | \(row)")
                }
            }
        }
        return read ? 0 : 1
    }

    /// The boxes a message is typed into, depth first, at most 26 levels down.
    private static func composers(in element: Element, depth: Int = 0) -> [Element] {
        guard depth < 26 else { return [] }
        if element.role == kAXTextAreaRole { return [element] }
        return element.children.flatMap { composers(in: $0, depth: depth + 1) }
    }
}
