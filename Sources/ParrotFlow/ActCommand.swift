import AppKit

/// `--act "<what you'd say>"` — the whole on-screen action path without a
/// microphone.
///
/// The decision is otherwise only observable by speaking at a screen and
/// watching what happens, which conflates four different failures: the gaze
/// was wrong, the window was wrong, the model chose wrong, or the click
/// landed wrong. Each of those is separable here.
///
/// ```sh
/// --act "click on Antonio" --app Slack --save /tmp/slack.json   # decide, save what it saw
/// --act "clique sur Antonio" --snapshot /tmp/slack.json         # decide again, no screen
/// --act "open the thread with Ian" --gaze --execute             # the live path, with the click
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
/// `open -na ParrotFlowDev --args --act "…"`, and read the log.
enum ActCommand {

    static func run(
        utterance: String, at point: CGPoint?, app: String?, snapshotPath: String?,
        save: String?, useGaze: Bool, execute: Bool, decide: Bool = true
    ) -> Int32 {
        defer { Log.flush() }
        NSApplication.shared.setActivationPolicy(.accessory)

        let config: Config
        do { config = try ConfigStore.load() } catch {
            print("✗ config: \(CheckConfigCommand.describe(error))")
            return 1
        }
        let actions = config.actions

        // Where it is looking, and where the snapshot came from. Every
        // measurement starts with these two lines, because a decision over the
        // wrong window is not a decision the model got wrong.
        let snapshot: ScreenTargets.Snapshot
        if let snapshotPath {
            do { snapshot = try ScreenTargets.Snapshot.read(fromFile: snapshotPath) } catch {
                print("✗ \(snapshotPath): \(error.localizedDescription)")
                return 1
            }
            print("snapshot   \(snapshotPath) — \(snapshot.app), \(snapshot.items.count) items")
        } else {
            var where_ = point ?? Gaze.mouse()
            if useGaze || point == nil {
                let gaze = Gaze.now(file: useGaze ? actions.gazeFile : "")
                where_ = point ?? gaze.location
                let age = gaze.age.map { String(format: "%.1f s old", $0) } ?? "the mouse"
                print("gaze       \(Int(where_.x)),\(Int(where_.y)) — \(gaze.source.rawValue), \(age)")
            }
            do {
                if let app {
                    snapshot = try ScreenTargets.snapshot(ofApp: app, at: where_)
                } else {
                    snapshot = try ScreenTargets.snapshot(
                        at: where_, ignoring: Set(actions.ignoreApps)
                    )
                }
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

        // What the model is shown, before it is asked. A target missing from
        // this list is a target the answer could never have been.
        let offers = ActionDecider.candidates(in: snapshot, for: utterance)
        guard decide else {
            // `--look`: which window, and what is in it. No call, so a case
            // set can be built without spending one per snapshot.
            for (index, item) in offers.prefix(12).enumerated() {
                print("             t\(index) \(ActionDecider.describe(item, in: snapshot))")
            }
            return 0
        }
        print("offered    \(offers.count) targets, nearest:")
        for (index, item) in offers.prefix(3).enumerated() {
            print("             t\(index) \(ActionDecider.describe(item, in: snapshot))")
        }

        // A command is a straight line and the decider is async, so it is
        // waited on here rather than making every caller above it async — the
        // same shape as `EvalCommand`.
        var decided: Result<ActionDecider.Decision, Error>!
        let answered = DispatchSemaphore(value: 0)
        Task {
            do {
                decided = .success(
                    try await ActionDecider.decide(
                        utterance: utterance, snapshot: snapshot, config: actions.decider
                    )
                )
            } catch {
                decided = .failure(error)
            }
            answered.signal()
        }
        answered.wait()

        let decision: ActionDecider.Decision
        do { decision = try decided.get() } catch {
            print("✗ \(error.localizedDescription)")
            return 1
        }

        print("decided    \(decision.line) · \(decision.ms) ms, \(decision.inputTokens) tokens in")
        if let target = decision.target {
            print("target     \(ActionDecider.describe(target, in: snapshot)) at \(target.x),\(target.y)")
        }
        if let text = decision.text {
            print("text       “\(text)”")
        }

        guard execute else {
            print("(nothing done — add --execute)")
            return 0
        }
        var outcome = ScreenAction.Outcome.nothing("nothing ran")
        let acted = DispatchSemaphore(value: 0)
        Task {
            outcome = await ScreenAction.perform(
                decision, in: snapshot, utterance: utterance, send: actions.send
            )
            acted.signal()
        }
        acted.wait()
        print("did        \(outcome.said)")
        // The paste puts the clipboard back on the main queue, 0.4 s later,
        // and a command that exits first takes the clipboard with it.
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        return outcome.isAction ? 0 : 1
    }

}
