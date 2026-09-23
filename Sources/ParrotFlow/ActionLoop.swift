import AppKit

/// One request, as many steps as it takes.
///
/// "Send a message to Antonio and Peter" is not one step, and neither is
/// "open the Demo App conversation" when that conversation is below the fold:
/// the accessibility tree holds what is rendered, so a row nobody has
/// scrolled to does not exist to be chosen. It has to be revealed and looked
/// at again.
///
/// So the loop is: read the window, ask what to do next, do it, read the
/// window again. The model is never asked for a plan. It is asked for one
/// step, with what has already been done and what changed when it was done —
/// which is the only way it can tell a step that worked from a step that did
/// nothing.
///
/// Three ways out, in the order they are checked:
///
/// | Stop | Because |
/// | --- | --- |
/// | `finished` | the model says the request is carried out |
/// | nothing changed twice | the real failure — a click posted into the void |
/// | `maxSteps` | a loop making progress in the wrong direction |
///
/// The counter is the backstop, not the guard. A click that changes nothing
/// is the failure that actually happens — measured on the first real use,
/// where a press was posted, reported, and closed a menu instead of opening
/// a conversation.
enum ActionLoop {

    struct Report {
        /// The steps as the model is told them, in order — plain past tense,
        /// one line each. This is what goes back in `done`.
        var steps: [String] = []
        /// The same steps as a person reads them.
        var shown: [String] = []
        var stopped: String = ""
        var acted = false

        /// What the pill says. The last thing that happened, and how many
        /// things happened before it.
        var said: String {
            guard let last = shown.last else { return stopped }
            return shown.count == 1 ? last : "\(last) (\(shown.count) steps)"
        }
    }

    /// One step, in the past tense, for the history the next step reads.
    static func canonical(_ decision: ActionDecider.Decision) -> String {
        let name = decision.target.map { $0.name.isEmpty ? $0.role : $0.name } ?? ""
        switch decision.action {
        case .newMessage: return "opened a new message, and it is now on screen"
        case .search: return "opened the search field"
        case .scroll: return "scrolled the view"
        case .type: return "typed the words into \"\(name.prefix(40))\""
        case .sendMessage: return "wrote the message in \"\(name.prefix(40))\""
        case .click: return "clicked \"\(name.prefix(40))\""
        case .none: return "did nothing"
        }
    }

    static func run(
        utterance: String, from point: CGPoint, config: Config.Actions
    ) async -> Report {
        var report = Report()
        var previous: ScreenTargets.Snapshot?
        var quiet = 0
        var last = ""
        var repeats = 0

        for step in 1...max(1, config.maxSteps) {
            let snapshot: ScreenTargets.Snapshot
            do {
                // The first look is where they were looking. After that the
                // window is whatever the last step opened, so it is found by
                // app rather than by point — the gaze belongs to the moment
                // they spoke, and distances stay measured from it.
                if let previous {
                    snapshot = try ScreenTargets.snapshot(ofApp: previous.app, at: point)
                } else {
                    snapshot = try ScreenTargets.snapshot(
                        at: point, ignoring: Set(config.ignoreApps)
                    )
                }
            } catch {
                report.stopped = error.localizedDescription
                return report
            }

            var changed = previous.map { difference(from: $0, to: snapshot) }
            if let seen = changed, seen.isEmpty {
                // An empty diff told the model nothing at all. Said out loud
                // it is the most useful sentence in the state: the last step
                // was posted, was reported as done, and moved nothing. That
                // is the moment to try something else rather than the same
                // thing again.
                changed = "the last step changed nothing on screen — it did not work, try another way"
            }
            if let changed { Log.write("action loop: changed — \(changed.prefix(160))") }
            if let changed, changed.isEmpty {
                quiet += 1
                if quiet >= 2 {
                    report.stopped = "Nothing changed twice over — stopping"
                    Log.write("action loop: \(report.stopped)")
                    return report
                }
            } else {
                quiet = 0
            }

            let decision: ActionDecider.Decision
            do {
                decision = try await ActionDecider.decide(
                    utterance: utterance, snapshot: snapshot, config: config.decider,
                    done: report.steps, changed: changed,
                    // There is a step after this one, so looking further is
                    // worth something. Measured: without this, "open the Demo
                    // App conversation" answered click with no target and
                    // stopped, because the row was below the fold and the
                    // accessibility tree holds only what is drawn.
                    canScroll: step < max(1, config.maxSteps)
                )
            } catch {
                report.stopped = error.localizedDescription
                return report
            }
            Log.write(
                "action loop: step \(step) · \(decision.line) · finished "
                + String(format: "%.2f", decision.finished) + " · \(decision.ms) ms"
            )

            // The same step twice is not a step, it is a stutter.
            //
            // Measured: "open a new message to Antonio and Peter" pressed ⌘N
            // five times. The quiet breaker cannot catch it — every ⌘N
            // redraws the window, so something always changed — and `done`
            // did not stop it either. A rule here does.
            let signature = decision.action.rawValue + "\u{1}" + (decision.target?.name ?? "")
            if signature == last {
                repeats += 1
                // Twice is a stutter worth interrupting; the loop is told so
                // and gets one more go at a different step. Three times is a
                // loop, and no amount of telling has helped.
                if repeats >= 2 {
                    report.stopped = "Asked for the same step three times — stopping"
                    Log.write("action loop: repeated \(decision.action.rawValue) again; stopping")
                    return report
                }
                Log.write("action loop: repeated \(decision.action.rawValue); skipping it")
                previous = snapshot
                continue
            }
            repeats = 0
            last = signature

            if decision.finished > 0.5 {
                report.stopped = report.steps.isEmpty ? "Nothing to do" : "Done"
                return report
            }
            if decision.action == .none {
                report.stopped = report.steps.isEmpty
                    ? "Nothing to do on screen" : "Done"
                return report
            }

            let outcome = await ScreenAction.perform(
                decision, in: snapshot, utterance: utterance,
                send: config.send, never: config.neverPress, at: point
            )
            guard outcome.isAction else {
                // A refusal, or nothing to act on. Either way this is not a
                // step to try again with the same window in front of it.
                report.stopped = outcome.said
                return report
            }
            report.acted = true
            // What goes in `done` is the step, not the sentence the pill
            // shows. "Opened a new message — say who it is to" reads to the
            // model like an instruction it has yet to carry out, which is
            // half of why it kept carrying it out.
            report.steps.append(canonical(decision))
            report.shown.append(outcome.said)
            previous = snapshot

            // Let the app draw what the step did before reading it again.
            // Shorter than the waits inside a step, which are about a click
            // landing; this one is only about the window settling.
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        report.stopped = "Stopped after \(config.maxSteps) steps"
        Log.write("action loop: \(report.stopped)")
        return report
    }

    /// What the last step did, in a sentence the model can read.
    ///
    /// Names rather than counts wherever it fits: "the window is now Demo App
    /// (DM)" is the fact that decides whether the step worked, and a diff of
    /// 37 added and 41 removed items is not.
    static func difference(
        from before: ScreenTargets.Snapshot, to after: ScreenTargets.Snapshot
    ) -> String {
        var said: [String] = []
        if before.window != after.window {
            said.append("the window is now \"\(after.window)\"")
        }
        let was = Set(before.items.map { $0.kind + "\u{1}" + $0.name })
        let now = Set(after.items.map { $0.kind + "\u{1}" + $0.name })
        let appeared = now.subtracting(was).compactMap { $0.split(separator: "\u{1}").last }
            .map(String.init).filter { !$0.isEmpty }
        let gone = was.subtracting(now).count
        if !appeared.isEmpty {
            let names = appeared.prefix(6).map { "\"\($0.prefix(40))\"" }.joined(separator: ", ")
            said.append("\(appeared.count) new: \(names)")
        }
        if gone > 0 { said.append("\(gone) gone") }
        return said.joined(separator: "; ")
    }
}
