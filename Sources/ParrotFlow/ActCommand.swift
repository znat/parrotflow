import AppKit

/// `--act "<what you'd say>"` — the whole on-screen action path without a
/// microphone.
///
/// The decision is otherwise only observable by speaking at a screen and
/// watching what happens, which conflates three different failures: the
/// window was wrong, the model chose wrong, or the click landed wrong. Each
/// of those is separable here.
///
/// ```sh
/// --act "click on Antonio" --app Slack --save /tmp/slack.json   # decide, save what it saw
/// --act "clique sur Antonio" --snapshot /tmp/slack.json         # decide again, no screen
/// --act "open the thread with Ian" --app Slack --execute        # the live path, with the click
/// ```
///
/// `--snapshot` is what makes this a measurement rather than a demonstration.
/// A snapshot is a window frozen: the same file and the same utterance have to
/// produce the same decision, today and after the next change. The prototype's
/// 12 measured utterances live in one — see `docs/actions.md`.
///
/// **Run from a terminal, this reads the screen with the terminal's
/// Accessibility grant, not ParrotFlow's.** TCC credits the responsible
/// process, so `--save` from a shell that has the grant works, and from one
/// that does not it reports nothing at all while the app itself is fine. Same
/// wrinkle as `--peek`, same way round it:
/// `open -na ParrotFlowDev --args --act "…"`, and read the log. Without
/// `--app` it reads the app in front, which from a shell is the terminal.
enum ActCommand {

    static func run(
        utterance: String, app: String?, snapshotPath: String?,
        save: String?, execute: Bool, decide: Bool = true,
        done: [String] = [], loop: Bool = false, request: String? = nil,
        show: Double? = nil, parts: Bool = false
    ) -> Int32 {
        defer { Log.flush() }
        NSApplication.shared.setActivationPolicy(.accessory)

        let config: Config
        do { config = try ConfigStore.load() } catch {
            print("✗ config: \(CheckConfigCommand.describe(error))")
            return 1
        }
        let actions = config.actions

        // Acting goes through the runner's loop, which reads the screen again
        // after each step. `--execute` alone is the loop held to one step.
        if loop || execute {
            // The next window is the result of the last step, so there is no
            // looking without doing.
            guard execute else {
                print("--loop acts on the screen to see what each step did. Add --execute.")
                return 2
            }
            guard snapshotPath == nil else {
                print("--execute needs a live screen; --snapshot is one frozen window.")
                return 2
            }
            let run = pumped {
                await Recipes.run(
                    utterance: utterance, app: app ?? "", config: actions, execute: true,
                    recipes: false, readApp: app, maxSteps: loop ? nil : 1
                )
            }
            guard let report = run.loop else {
                for line in run.lines { print(line) }
                return 1
            }
            if loop {
                for (index, step) in report.steps.enumerated() {
                    print("  \(index + 1). \(step)")
                }
                print("stopped    \(report.stopped)")
            } else {
                print("did        \(report.said)")
            }
            // The paste puts the clipboard back on the main queue, 0.4 s later,
            // and a command that exits first takes the clipboard with it.
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            return report.acted ? 0 : 1
        }

        // Where the snapshot came from. Every measurement starts with this
        // line, because a decision over the wrong window is not a decision the
        // model got wrong.
        let snapshot: ScreenTargets.Snapshot
        if let snapshotPath {
            do { snapshot = try ScreenTargets.Snapshot.read(fromFile: snapshotPath) } catch {
                print("✗ \(snapshotPath): \(error.localizedDescription)")
                return 1
            }
            print("snapshot   \(snapshotPath) — \(snapshot.app), \(snapshot.items.count) items")
        } else {
            guard let app = app ?? ScreenTargets.frontmostApp() else {
                print("✗ no app is in front — name one with --app")
                return 1
            }
            do {
                // `--parts`: every other window and pop-up is read as if it
                // had just opened, the way a run reads a new one.
                var known = NSWorkspace.shared.runningApplications
                    .first { $0.localizedName == app || $0.bundleIdentifier == app }
                    .flatMap { parts ? ScreenTargets.Parts(pid: $0.processIdentifier, elements: []) : nil }
                snapshot = try ScreenTargets.snapshot(ofApp: app, since: &known)
            } catch {
                print("✗ \(error.localizedDescription)")
                return 1
            }
            print("window     \(snapshot.app) “\(snapshot.window)” — \(snapshot.items.count) items")
        }

        if let save {
            let path = (save as NSString).expandingTildeInPath
            do {
                try snapshot.json.write(toFile: path, atomically: true, encoding: .utf8)
                print("saved      \(path)")
            } catch {
                print("✗ could not save: \(error.localizedDescription)")
                return 1
            }
        }

        // The runner decides, on the window read here.
        func ask(_ mode: String) -> [String: Any]? {
            let answer = pumped {
                await Recipes.decide(utterance, on: snapshot, done: done, mode: mode, config: actions)
            }
            guard answer["end"] as? String == "decided" else {
                print("✗ \(answer["error"] as? String ?? "the runner did not answer")")
                return nil
            }
            return answer
        }
        func offers(_ answer: [String: Any]) -> [(item: ScreenTargets.Item, described: String)] {
            (answer["offers"] as? [[String: Any]] ?? []).compactMap { offer in
                guard let index = offer["index"] as? Int, snapshot.items.indices.contains(index)
                else { return nil }
                return (snapshot.items[index], offer["described"] as? String ?? "")
            }
        }

        // `--show`: what the model is offered, outlined on screen.
        if let show {
            guard let look = ask("look") else { return 1 }
            let shown = offers(look).map(\.item)
            // A command never finished launching, and a window ordered in
            // before that can fail to appear at all.
            NSApplication.shared.finishLaunching()
            let frame = ActionSpotlight.flash(
                offers: shown, aim: nil, in: snapshot, seconds: show
            )
            print("shown      \(shown.count) targets over \(Int(frame.width))x\(Int(frame.height))"
                + " for \(show) s")
            RunLoop.main.run(until: Date().addingTimeInterval(show + 0.2))
        }
        // `--request <file>`: exactly what would be sent, and nothing sent.
        if let request {
            guard let answer = ask("request") else { return 1 }
            let body = answer["body"] as? String ?? ""
            let path = (request as NSString).expandingTildeInPath
            do {
                try body.write(toFile: path, atomically: true, encoding: .utf8)
                print("request    \(path) — \(body.count) characters, about \(body.count / 4) tokens")
            } catch {
                print("✗ could not write: \(error.localizedDescription)")
                return 1
            }
            return 0
        }

        guard decide else {
            // `--look`: which window, and what is in it. No call, so a case
            // set can be built without spending one per snapshot.
            guard let look = ask("look") else { return 1 }
            for (index, offer) in offers(look).prefix(12).enumerated() {
                print("             t\(index) \(offer.described)")
            }
            return 0
        }
        guard let answer = ask("decide") else { return 1 }
        let offered = offers(answer)
        print("offered    \(offered.count) targets, first:")
        for (index, offer) in offered.prefix(3).enumerated() {
            print("             t\(index) \(offer.described)")
        }
        let decision = answer["decision"] as? [String: Any] ?? [:]
        print("decided    \(decision["line"] as? String ?? "") · \(decision["ms"] as? Int ?? 0) ms,"
            + " \(decision["input_tokens"] as? Int ?? 0) tokens in")
        if let target = decision["target"] as? [String: Any] {
            print("target     \(target["described"] as? String ?? "")"
                + " at \(target["x"] as? Int ?? 0),\(target["y"] as? Int ?? 0)")
        }
        if let text = decision["text"] as? String {
            print("text       “\(text)”")
        }
        print("(nothing done — add --execute)")
        return 0
    }

    /// Waits for async work while keeping the main run loop turning: the
    /// runner's steps hop to the main actor (Escape, the spotlight), and a
    /// semaphore held on the main thread would block them.
    private static func pumped<T>(_ work: @escaping () async -> T) -> T {
        let box = Box<T>()
        Task { box.value = await work() }
        while box.value == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return box.value!
    }

    private final class Box<T>: @unchecked Sendable {
        var value: T?
    }
}
