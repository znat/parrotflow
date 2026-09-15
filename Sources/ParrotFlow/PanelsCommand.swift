import AppKit
import SwiftUI

/// Puts one floating surface on screen and leaves it there, so it can be looked
/// at — or screenshotted — without dictating anything.
///
/// The panels only ever appear in the middle of doing something else: a hotkey
/// held down, a model that has just answered. Checking that a border or a
/// button still looks right otherwise meant staging a whole correction, which
/// is slow enough that the surfaces drifted apart from each other unnoticed.
enum PanelsCommand {

    /// The learn headline the app would build, short or long.
    ///
    /// Through `learnPayload` rather than a hand-written `Learn`, so the sheet
    /// shows the window the app applies. Written out, the long one wrapped a
    /// row measured for one line and nothing on the sheet said so.
    private static func learnPreview(long: Bool) -> Learn {
        let sentence = long
            ? "So what I wanted to say is that we should probably move the whole"
                + " ingest job over to disfluency before the end of the quarter"
                + " because the current one keeps falling over."
            : "I wanna work on disfluency."
        let words = sentence.split(separator: " ").map(String.init)
        let at = words.firstIndex(of: "disfluency") ?? 0
        return AppDelegate.learnPayload(for: EditWatch.Change(
            was: "this fluency", now: "disfluency", sentence: sentence,
            at: at, nowAt: at, written: sentence, span: 1
        ))
    }

    /// Point the live pill at the caret, the way `AppDelegate` does at the
    /// press. Placement belongs to the pill and not to the state, so a preview
    /// that never aims draws the panel at the bottom of the screen and says
    /// nothing about where the real one opens.
    ///
    /// The stand-in matters: with no aim the pill falls back to the bottom
    /// centre, which is the one placement this preview is not about.
    private static func aimAtCaret(_ pill: PillHUD) {
        let element = SelectionReader.focusedElement()
        if let element, case .found(let anchor) = CaretAnchor.read(at: element) {
            Log.write("panels: aimed at the caret (\(anchor.source.rawValue))")
            pill.aim(at: anchor)
            return
        }
        if element == nil {
            Log.write("panels: no focused element (trusted: \(AXIsProcessTrusted()))")
        } else {
            Log.write("panels: focused element gave no caret")
        }
        // The rung the app falls to for an app that answers nothing. Without it
        // a click into Slack would draw a line in the middle of nowhere, when
        // the real pill would sit on that window's bottom edge.
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           let anchor = CaretAnchor.window(of: pid) {
            Log.write("panels: aimed at the front window's bottom edge")
            pill.aim(at: anchor)
            return
        }
        guard let screen = NSScreen.main?.visibleFrame else { return }
        let line = NSRect(x: screen.midX - 240, y: screen.midY, width: 480, height: 18)
        pill.aim(at: CaretAnchor.Found(rect: line, text: line, source: .caret))
    }

    /// The three selectors the sheet and `--panels` draw.
    ///
    /// One place and short, one place in a sentence the window has to cut at
    /// both ends, and two places in one sentence — which is two questions.
    private static func selectorRun(_ shape: String) -> ChooseRun {
        switch shape {
        case "long":
            return selector(
                "so after the standup tomorrow morning when the ingest job has"
                    + " finished running on the new cluster can you ask mixed bend"
                    + " to review the pull request before the end of the week so we"
                    + " can ship it on Monday.",
                [("mixed bend", ["Mick"])]
            )
        case "two":
            return selector(
                "so after the standup tomorrow morning can you ask mixed bend to"
                    + " review it and then tell the team that we moved everything"
                    + " off BetterStack in June before the export runs again",
                [("mixed bend", ["Mick"]), ("BetterStack", ["better stack"])]
            )
        default:
            return selector(
                "can you ask mixed bend to review it.", [("mixed bend", ["Mick"])]
            )
        }
    }

    /// One step of a run, with the earlier answers already taken.
    ///
    /// Through `ChooseRun` rather than a hand-written `Choose`, so the sheet
    /// shows the window, the shrink and the substitution the app would apply.
    private static func selectorStep(_ shape: String, answered: [Int] = []) -> Choose {
        var run = selectorRun(shape)
        for option in answered { run.answer(option) }
        guard let step = run.next else {
            // Unreachable: every run here has more places than answers.
            return Choose(before: "", options: [run.sentence], after: "",
                          step: 1, steps: 1)
        }
        return step
    }

    /// The places named by the words they cover, which is how they read here.
    private static func selector(
        _ sentence: String, _ pairs: [(heard: String, others: [String])]
    ) -> ChooseRun {
        let words = sentence.split(separator: " ").map(String.init)
        var places: [ChooseRun.Place] = []
        var from = 0
        for pair in pairs {
            let phrase = pair.heard.split(separator: " ").map(String.init)
            guard let at = firstIndex(of: phrase, in: words, from: from) else { continue }
            places.append(
                ChooseRun.Place(at: at, span: phrase.count, others: pair.others)
            )
            from = at + phrase.count
        }
        return ChooseRun(sentence: sentence, places: places)
    }

    /// Where a phrase starts, counted in words.
    private static func firstIndex(
        of phrase: [String], in words: [String], from: Int
    ) -> Int? {
        guard !phrase.isEmpty, from <= words.count - phrase.count else { return nil }
        for start in from ... (words.count - phrase.count)
        where Array(words[start ..< start + phrase.count]) == phrase {
            return start
        }
        return nil
    }

    /// What the offer is drawn with here: the two transforms the shipped
    /// config puts on the pill. A row of chips is the shape worth looking at,
    /// not one chip on its own.
    private static let offerChips = [
        OfferedCommand(title: "grammar", key: "G"),
        OfferedCommand(title: "slack_mentions", key: "S")
    ]

    /// Enough transforms to wrap, which two are not.
    ///
    /// The wrap is counted in `PillMetrics.chipRows` before it is drawn, and a
    /// row count off by one hangs the last chip over the end of the panel. Two
    /// chips can never show that; six can, and six is an ordinary config.
    private static let offerManyChips = offerChips + [
        OfferedCommand(title: "punctuation", key: "P"),
        OfferedCommand(title: "disfluency", key: "D"),
        OfferedCommand(title: "bullets", key: "B")
    ]

    /// A Bluetooth headset with a long name, because the notice puts the name
    /// in its first sentence and a short one would not say whether it fits.
    private static let sampleMicName = "Tasmin's AirPods Pro Max"
    /// A real app that really does this, and a long enough name to show what a
    /// long one costs the box.
    private static let sampleKeyboardApp = "Notion Helper (Renderer)"

    /// A release body longer than the panel is tall — a heading, two sections,
    /// and two links on every line. Longer on purpose: the pane only scrolls
    /// when the notes outgrow it, so a sample that fits proves nothing.
    private static let sampleRelease = Updates.Release(
        version: "0.7.0",
        publishedAt: Date(timeIntervalSince1970: 1_755_561_600),
        notes: """
            ## [0.7.0](https://github.com/znat/parrotflow/compare/v0.6.0...v0.7.0) (2026-08-19)

            ### Features

            * a spelling lesson keeps the word it is teaching ([#143](https://github.com/znat/parrotflow/issues/143)) ([7e19a7e](https://github.com/znat/parrotflow/commit/7e19a7e74d6e56c153912b3f53890b2501854d49))
            * a table says what it wrote, and `join` fits a clip to the box ([#148](https://github.com/znat/parrotflow/issues/148)) ([461ea43](https://github.com/znat/parrotflow/commit/461ea4332725a905f294cfb358b0657b8268fed8))
            * **code_identifiers** publishes the identifiers it wrote ([#146](https://github.com/znat/parrotflow/issues/146)) ([649b08c](https://github.com/znat/parrotflow/commit/649b08c7962f405f72aeaec25c9bf96e514cb8d6))
            * name the word lists once, and let dotted hear dash and slash ([#149](https://github.com/znat/parrotflow/issues/149)) ([aadf036](https://github.com/znat/parrotflow/commit/aadf036a1bc8451132159a9566313caabc391f64))
            * punctuation gains brackets, semicolon, ellipsis and French ([#150](https://github.com/znat/parrotflow/issues/150)) ([dbf028c](https://github.com/znat/parrotflow/commit/dbf028c951d88f914f4cd910af668848b7526e6b))
            * read the input box, tag the words, and hand a transform the whole run ([#147](https://github.com/znat/parrotflow/issues/147)) ([f079683](https://github.com/znat/parrotflow/commit/f0796833ac8569b2d31350a4fc9bf4db28e3bafb))
            * the offer says when the words may not be your words ([#151](https://github.com/znat/parrotflow/issues/151)) ([e9c8578](https://github.com/znat/parrotflow/commit/e9c857869ef38665f7479cec27a6233f18d080ae))

            ### Fixes

            * a repeat holding "I" is no longer kept as a spelled letter ([#145](https://github.com/znat/parrotflow/issues/145)) ([0dc8153](https://github.com/znat/parrotflow/commit/0dc81535c04b2e55856ac5dfff51259b6db36e1b))
            * get past the version-manager shim, and stop trimming what a stage added ([#144](https://github.com/znat/parrotflow/issues/144)) ([a0c5d17](https://github.com/znat/parrotflow/commit/a0c5d17e66056d90dc32a76a841bef7ec9239dda))
            * the pill no longer keeps the icon of an app that has quit ([#141](https://github.com/znat/parrotflow/issues/141)) ([b31c0a2](https://github.com/znat/parrotflow/commit/b31c0a2f5d1e4c8a9b7e6f3d2c1a0b9e8d7c6f5a))
            * a dictation that lands nowhere says so before it copies ([#140](https://github.com/znat/parrotflow/issues/140)) ([c42d1b3](https://github.com/znat/parrotflow/commit/c42d1b3a6e2f5d9c8b7a6e5f4d3c2b1a0f9e8d7c))
            * the vocabulary judge stops asking Ollama about an empty match ([#138](https://github.com/znat/parrotflow/issues/138)) ([d53e2c4](https://github.com/znat/parrotflow/commit/d53e2c4b7f3a6e0d9c8b7a6f5e4d3c2b1a0f9e8d))
            * two builds no longer fight over the same recording directory ([#137](https://github.com/znat/parrotflow/issues/137)) ([e64f3d5](https://github.com/znat/parrotflow/commit/e64f3d5c8a4b7f1e0d9c8b7a6f5e4d3c2b1a0f9e))
            * a hotkey held through a screen lock releases on the way back ([#136](https://github.com/znat/parrotflow/issues/136)) ([f75a4e6](https://github.com/znat/parrotflow/commit/f75a4e6d9b5c8a2f1e0d9c8b7a6f5e4d3c2b1a0f))
            * the log stops growing without bound on a machine left running ([#135](https://github.com/znat/parrotflow/issues/135)) ([a86b5f7](https://github.com/znat/parrotflow/commit/a86b5f7e0c6d9b3a2f1e0d9c8b7a6f5e4d3c2b1a))
            * a spelled word ending in a full stop keeps the full stop ([#134](https://github.com/znat/parrotflow/issues/134)) ([b97c6a8](https://github.com/znat/parrotflow/commit/b97c6a8f1d7e0c4b3a2f1e0d9c8b7a6f5e4d3c2b))
            * the preview panel stops reopening on the screen you left ([#133](https://github.com/znat/parrotflow/issues/133)) ([ca8d7b9](https://github.com/znat/parrotflow/commit/ca8d7b9a2e8f1d5c4b3a2f1e0d9c8b7a6f5e4d3c))
            * numbers said as digits survive the grammar stage ([#132](https://github.com/znat/parrotflow/issues/132)) ([db9e8ca](https://github.com/znat/parrotflow/commit/db9e8ca3f9a2e6d5c4b3a2f1e0d9c8b7a6f5e4d3))
            * a transform that writes nothing no longer clears the line ([#131](https://github.com/znat/parrotflow/issues/131)) ([ecaf9db](https://github.com/znat/parrotflow/commit/ecaf9db4a0b3f7e6d5c4b3a2f1e0d9c8b7a6f5e4))
            * the menu bar icon returns after a display is unplugged ([#130](https://github.com/znat/parrotflow/issues/130)) ([fdb0aec](https://github.com/znat/parrotflow/commit/fdb0aec5b1c4a8f7e6d5c4b3a2f1e0d9c8b7a6f5))
            * a second hotkey press during the release tail is ignored ([#129](https://github.com/znat/parrotflow/issues/129)) ([aec1bfd](https://github.com/znat/parrotflow/commit/aec1bfd6c2d5b9a8f7e6d5c4b3a2f1e0d9c8b7a6))
            """,
        zip: URL(string: "https://example.invalid/ParrotFlow.zip")!,
        checksum: URL(string: "https://example.invalid/ParrotFlow.zip.sha256")!
    )

    /// What `feedback.confidence` draws. The scores walk the whole ramp — sure,
    /// p25, p10, p1, and a word with no reading at all — because the question
    /// this surface answers is whether the colours are told apart, and a
    /// sentence the decoder was sure of would show one of them.
    private static let sampleSentence = [
        Confidence.Word(text: "We", score: 1.0),
        Confidence.Word(text: "deployed", score: 0.97),
        Confidence.Word(text: "Redcrawl", score: 0.74),
        Confidence.Word(text: "on", score: 0.99),
        Confidence.Word(text: "Vercel", score: 0.52),
        Confidence.Word(text: "with", score: 0.91),
        Confidence.Word(text: "Tasmin", score: 0.28),
        Confidence.Word(text: "yesterday", score: nil)
    ]

    /// The warning the same dictation raises. It names the word rather than a
    /// number: the number is for the person tuning the thresholds, and this
    /// line is for the person who has just dictated.
    private static let sampleWarning = "This may not be what you said · Vercel"

    /// The words and the warning together.
    private static let sampleReading = Confidence.Reading(
        words: sampleSentence, warning: sampleWarning
    )

    /// The beats of the vocabulary tour, in the order the story tells them:
    /// two dictations that are corrected by hand, and then two that are asked
    /// about instead.
    static let tutorialBeats: [(name: String, at: TimeInterval)] = [
        ("listening", Tutorial.leadIn + 1.2),
        ("transcribing", Tutorial.leadIn + Tutorial.held + 0.25),
        ("landed 1", Tutorial.firstLands + 0.2),
        ("placed 1", Tutorial.firstLands + Tutorial.Beat.placed.rawValue + 0.4),
        ("inserted 1", Tutorial.firstLands + Tutorial.Beat.inserted.rawValue + 0.4),
        ("offer 1", Tutorial.firstLands + Tutorial.Beat.offering.rawValue + 0.5),
        ("clicked 1", Tutorial.firstLands + Tutorial.Beat.clicking.rawValue + 0.4),
        ("saved 1", Tutorial.firstLands + Tutorial.Beat.saved.rawValue + 0.4),
        ("landed 2", Tutorial.secondLands + 0.2),
        ("inserted 2", Tutorial.secondLands + Tutorial.Beat.inserted.rawValue + 0.4),
        ("offer 2", Tutorial.secondLands + Tutorial.Beat.offering.rawValue + 0.5),
        ("saved 2", Tutorial.secondLands + Tutorial.Beat.saved.rawValue + 0.4),
        ("written 1", Tutorial.thirdLands + 0.25),
        ("listening 2", Tutorial.fourthAt + Tutorial.leadIn + 0.5),
        ("transcribing 2",
         Tutorial.fourthAt + Tutorial.dictated(4) - Tutorial.settling + 0.25),
        ("written 2", Tutorial.fourthLands + Tutorial.beforeNames + 0.25),
    ]

    /// The beats of the slack tour. *clicking* is taken while the chip is lit,
    /// because which of the two the pointer takes is the lesson.
    static let slackBeats: [(name: String, at: TimeInterval)] = [
        ("listening", Tutorial.leadIn + 0.6),
        ("transcribing", Tutorial.leadIn + Tutorial.held + 0.25),
        ("landed", TutorialSlack.landsAt + 0.2),
        (
            "link callout",
            TutorialSlack.landsAt + TutorialSlack.Beat.captioned.rawValue + 0.8
        ),
        ("tab", TutorialSlack.landsAt + 0.2),
        (
            "key shimmer",
            TutorialSlack.landsAt + TutorialSlack.Beat.shimmering.rawValue + 0.3
        ),
        ("panel", TutorialSlack.landsAt + TutorialSlack.Beat.opening.rawValue + 0.4),
        ("clicked", TutorialSlack.landsAt + TutorialSlack.Beat.clicking.rawValue + 0.4),
        ("handled", TutorialSlack.landsAt + TutorialSlack.Beat.handled.rawValue + 0.3),
        ("sent", TutorialSlack.landsAt + TutorialSlack.Beat.sending.rawValue + 0.2),
        ("posted", TutorialSlack.landsAt + TutorialSlack.Beat.posted.rawValue + 0.4),
    ]

    /// The beats of the Extensible screen: each card arriving, and the
    /// panel on the last one.
    static let hackBeats: [(name: String, at: TimeInterval)] = [
        ("replacements", TutorialHack.arrives(.replacements) + 0.5),
        (
            "its mark",
            TutorialHack.arrives(.replacements) + TutorialHack.after + 0.45
        ),
        ("scripts", TutorialHack.arrives(.scripts) + 0.5),
        ("panel", TutorialHack.arrives(.scripts) + TutorialHack.step + 0.3),
        (
            "listening",
            TutorialHack.arrives(.scripts) + TutorialHack.step
                + TutorialHack.saying + TutorialHack.handover + 0.1
        ),
        (
            "said",
            TutorialHack.arrives(.scripts) + TutorialHack.step
                + TutorialHack.saying + TutorialHack.beforeSpeaking
                + TutorialHack.perWord
                * Double(TutorialHack.spokenWords.count) + 0.2
        ),
        ("prompts", TutorialHack.arrives(.prompts) + 0.5),
        (
            "its mark",
            TutorialHack.arrives(.prompts) + TutorialHack.after + 0.45
        ),
        ("coding agent", TutorialHack.arrives(.agent) + 0.6),
        (
            "its answer",
            TutorialHack.arrives(.agent) + TutorialHack.answer
                + TutorialHack.answerFade + 0.2
        ),
    ]

    /// The downloads screen, at the two moments that differ: the bar in the
    /// middle of it, and the bar gone up to the corner.
    static let downloadBeats: [(name: String, at: TimeInterval)] = [
        ("downloading", 0.8),
        ("lifted", TutorialDownloadsPane.lifts + TutorialDownloadsPane.lifting + 0.2),
    ]

    /// The last screen is one still life: there is no clock in it.
    static let readyBeats: [(name: String, at: TimeInterval)] = [("ready", 0)]

    static func beats(of screen: TourScreen) -> [(name: String, at: TimeInterval)] {
        switch screen {
        case .downloads: return downloadBeats
        case .names: return tutorialBeats
        case .slack: return slackBeats
        case .hack: return hackBeats
        case .ready: return readyBeats
        }
    }

    /// Which beat of a screen the walk sheet draws: the one it has the most to
    /// say on, and never one with the pill up — `cacheDisplay` hands a blur
    /// back in a black box. Every screen's last beat, except the opening's,
    /// whose last beat is the bar already gone to the corner.
    private static func walkBeat(_ screen: TourScreen) -> TimeInterval {
        switch screen {
        case .downloads: return downloadBeats.first?.at ?? 0
        default: return beats(of: screen).last?.at ?? 0
        }
    }

    /// One screen of the tour, inside the frame the setup window puts round it.
    private static func walkFrame(_ screen: TourScreen) -> AnyView {
        // On the walk's own clock, not the screen's, so each frame carries the
        // foot the window would draw on it: no Back on the first screen.
        let before = TourWalk.screens
            .prefix(while: { $0 != screen })
            .reduce(0) { $0 + $1.length }
        // Through the setup window's own view, and not the tour on its own:
        // this sheet is for the frame the window puts around it — the width,
        // the height it keeps for every screen, and the bar fed by a real
        // registry.
        let downloads = sampleDownloads(speech: .downloading(percent: 40))
        return AnyView(
            PermissionsView()
                .environmentObject(
                    PermissionsModel.showingTour(
                        downloads, at: before + walkBeat(screen)
                    )
                )
                .environmentObject(downloads)
        )
    }

    /// One screen of the tour at one moment, with no download chrome on it.
    ///
    /// `progress: nil` is what takes the bar, the rule and the kicker off:
    /// outside the setup window there is nothing downloading, and a screen that
    /// says WHILE YOU WAIT in a README is waiting for nothing.
    private static func filmFrame(_ screen: TourScreen, at t: TimeInterval) -> AnyView {
        switch screen {
        case .names: return AnyView(TutorialPane(run: TutorialRun(t)))
        case .slack: return AnyView(TutorialSlackPane(run: TutorialSlackRun(t)))
        case .hack: return AnyView(TutorialHackPane(elapsed: t))
        case .downloads: return AnyView(TutorialDownloadsPane(elapsed: t, progress: 0.42))
        case .ready: return AnyView(TutorialReadyPane())
        }
    }

    /// How fast the clock runs at one moment: `speed`, except where the screen
    /// is asking to be read rather than watched, which runs at 1x.
    ///
    /// Two of those. A screen dims over the thing it is about, which is the
    /// same as saying those are the beats worth watching; the rest of a chat
    /// screen is a sentence arriving. And the config screen is a config file —
    /// eight seconds of it at 3x is under three seconds to read six lines of
    /// YAML, which is not reading, it is a glimpse.
    ///
    /// Playing all of it at one rate either makes the film long or takes a
    /// keystroke and an answered offer past in under a second.
    private static func pace(
        _ screen: TourScreen, at t: TimeInterval, top: Double
    ) -> Double {
        switch screen {
        case .names:
            return TutorialRun.lighting.contains { t >= $0.from && t < $0.to }
                ? 1 : top
        case .slack:
            return TutorialSlackRun.lighting.contains { t >= $0.from && t < $0.to }
                ? 1 : top
        case .hack:
            return 1
        default:
            return top
        }
    }

    /// One screen of a film, and how much of it to play.
    ///
    /// A screen turns its own pages — the last one is four config examples one
    /// after another — and a film does not always want all of them. `hack:2`
    /// plays the first two and cuts to the next screen where the third would
    /// have started.
    struct Reel {
        let screen: TourScreen
        /// How many of the screen's pages to play, or nil for all of them.
        let pages: Int?

        /// `names`, or `hack:2`.
        init?(_ spec: String) {
            let parts = spec.split(separator: ":", maxSplits: 1)
            guard let screen = TourScreen(rawValue: String(parts[0])) else {
                return nil
            }
            self.screen = screen
            guard parts.count == 2 else { pages = nil; return }
            guard let count = Int(parts[1]), count > 0 else { return nil }
            pages = count >= screen.pages.count ? nil : count
        }

        /// Where this reel stops, on the screen's own clock.
        var end: TimeInterval {
            guard let pages, screen.pages.indices.contains(pages) else {
                return screen.length
            }
            return screen.pages[pages]
        }

        var name: String {
            guard let pages else { return screen.rawValue }
            return "\(screen.rawValue) (\(pages) of \(screen.pages.count) pages)"
        }
    }

    /// `--tour-film <dir> <screens> [fps] [speed]` — every frame of a tour
    /// screen as a numbered PNG, for ffmpeg to make a film out of.
    ///
    /// The screens are pure functions of elapsed time, so a film of one is a
    /// walk up its clock: no recording, no screen, no timing to get right, and
    /// the same frames every run. `speed` multiplies the step, so 2 asks the
    /// clock for twice the time per frame and the film plays at twice the pace.
    /// The two corrections on the vocabulary screen are held at 1x whatever
    /// `speed` says — see `pace`.
    ///
    /// One thing on the walk is not a function of that clock: the highlight
    /// sweeping the download bar runs on a clock of its own, deliberately, so
    /// `downloads` is the one screen whose frames differ between runs. Every
    /// other screen draws the bar only when there is a download, and a film has
    /// none.
    ///
    /// One canvas for the whole film, as tall as the tallest screen, because a
    /// video cannot change size partway. The panes are top-aligned in it.
    static func tourFilm(
        to dir: String, screens: [Reel], fps: Double, speed: Double
    ) -> Int32 {
        // `isFinite` and not just `> 0`: an infinite rate makes the step zero
        // and the loop below never ends.
        guard !screens.isEmpty, fps.isFinite, speed.isFinite, fps > 0, speed > 0
        else { return 2 }

        // Every moment the film will draw, worked out before anything is drawn:
        // the canvas has to hold the tallest of them, and a screen grows while
        // it plays. Strictly under the end — a run wraps with a remainder at its
        // total, so the frame at exactly the length is frame 0 again.
        var moments: [(reel: Int, screen: TourScreen, at: TimeInterval)] = []
        for (index, reel) in screens.enumerated() {
            var t: TimeInterval = 0
            while t < reel.end {
                // A step that cannot move the clock, which `isFinite` does not
                // catch: `1e-100 / 1e308` is exactly zero, and the loop then
                // fills memory with one moment over and over.
                let next = t + pace(reel.screen, at: t, top: speed) / fps
                guard next > t else { return 2 }
                moments.append((index, reel.screen, t))
                t = next
            }
        }

        // Measured on every frame and not on a sample of them: the tallest beat
        // of a screen is the one with the pill up, which lasts about a second,
        // and a canvas that misses it clips the pill's bloom.
        let sizes = moments.map { natural($0.screen, at: $0.at) }
        let width = ceil(sizes.map(\.width).max() ?? 0)
        // Never under the height the setup window keeps for a screen. A pane
        // given less lays itself out differently: the Slack stage gives up the
        // room it holds above its composer, and the composer then moves down
        // the frame as the channel fills.
        let tall = ceil(
            max(
                sizes.map(\.height).max() ?? 0,
                screens.map(\.screen.height).max() ?? 0
            )
        )
        guard width > 0, tall > 0 else { return 1 }
        // Even, both axes: H.264 in yuv420p halves the chroma plane and refuses
        // an odd side.
        let canvas = NSSize(
            width: width + width.truncatingRemainder(dividingBy: 2),
            height: tall + tall.truncatingRemainder(dividingBy: 2)
        )

        do {
            try FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true
            )
            // A shorter film into a directory that held a longer one leaves the
            // tail of the old one behind, and ffmpeg reads `frame-%04d.png` to
            // the end of the run: the film would finish with somebody else's
            // frames.
            let old = try FileManager.default.contentsOfDirectory(atPath: dir)
                .filter { $0.hasPrefix("frame-") && $0.hasSuffix(".png") }
            for name in old {
                try FileManager.default.removeItem(atPath: "\(dir)/\(name)")
            }
        } catch {
            print("✗ \(error.localizedDescription)")
            return 1
        }

        for (frame, moment) in moments.enumerated() {
            let ok = autoreleasepool { () -> Bool in
                write(
                    filmFrame(moment.screen, at: moment.at), on: canvas,
                    to: "\(dir)/frame-\(String(format: "%04d", frame)).png"
                )
            }
            guard ok else { return 1 }
        }

        // Counted by reel and not by screen: `names,names` is two reels of one
        // screen, and counting the screen gives each line the other's frames
        // as well.
        for (index, reel) in screens.enumerated() {
            let count = moments.filter { $0.reel == index }.count
            print(
                "\(reel.name): \(count) frames"
                    + " · \(String(format: "%.1f", reel.end))s of tour"
                    + " in \(String(format: "%.1f", Double(count) / fps))s of film"
            )
        }
        print(
            "\(moments.count) frames of \(Int(canvas.width))x\(Int(canvas.height))"
                + " in \(dir), \(String(format: "%.0f", fps))fps"
        )
        return 0
    }

    /// The size a screen's own content wants at one moment.
    ///
    /// `NSHostingView.fittingSize` is not that size: it measures the title on
    /// one line, comes back about 30pt short, and a pane forced into it answers
    /// by truncating the title. This asks the renderer instead, with the height
    /// proposal refused.
    private static func natural(_ screen: TourScreen, at t: TimeInterval) -> NSSize {
        MainActor.assumeIsolated {
            let renderer = ImageRenderer(
                content: filmFrame(screen, at: t)
                    .fixedSize(horizontal: false, vertical: true)
                    .environment(\.colorScheme, .dark)
            )
            renderer.scale = 1
            return renderer.nsImage?.size ?? .zero
        }
    }

    /// One frame, top-aligned on the canvas.
    ///
    /// The ground is the pane's own window colour, put behind the whole canvas
    /// rather than filled in AppKit first: a dynamic `NSColor` resolves through
    /// SwiftUI's colour scheme, so the band under a short screen is the same
    /// grey as the screen instead of a number written here that nearly matches.
    private static func write(
        _ view: AnyView, on canvas: NSSize, to path: String
    ) -> Bool {
        // Every screen given the same height, and not each its own: a pane's
        // last spacer takes what is left over, so the parts that are laid out
        // from the bottom — a Slack channel filling upward to its composer —
        // sit where they were designed to instead of collapsing onto their
        // own content and moving between screens.
        let rendered = MainActor.assumeIsolated { () -> CGImage? in
            let renderer = ImageRenderer(
                content: view
                    .frame(width: canvas.width, height: canvas.height, alignment: .top)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, .dark)
            )
            renderer.scale = 2
            renderer.isOpaque = true
            return renderer.cgImage
        }
        guard let rendered else { return false }
        guard let png = NSBitmapImageRep(cgImage: rendered)
            .representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            return true
        } catch {
            print("✗ \(error.localizedDescription)")
            return false
        }
    }

    /// `--tutorial-sheet <out.png> [slack]` — one screen of the tour, one frame
    /// per beat, stacked.
    ///
    /// The tour is a moving thing and this is the only way to look at one beat
    /// of it without waiting twenty seconds for the loop to come round. It is
    /// the same argument as `--panel-sheet`, for the one surface whose states
    /// are a sequence rather than a set.
    ///
    /// `walk` is the other question: every screen as the setup window frames
    /// it, with the foot on. It is drawn the other way — see below — so the
    /// buttons are the real ones.
    static func tutorialSheet(to path: String, stage: String) -> Int32 {
        let walk = stage == "walk"
        guard walk || TourScreen(rawValue: stage) != nil else { return 2 }
        let screen = TourScreen(rawValue: stage) ?? .names
        // No foot on a screen's own beats: `ImageRenderer` cannot draw an
        // AppKit-backed button and puts a yellow placeholder where one is,
        // which would be sixteen of them down the sheet. The buttons do not
        // change beat to beat, and `walk` is where they are looked at.
        let beats = walk ? [] : beats(of: screen)
        let views: [AnyView] = walk
            ? TourWalk.screens.map(walkFrame)
            : beats.map { beat in
                switch screen {
                case .slack:
                    return AnyView(
                        TutorialSlackPane(
                            run: TutorialSlackRun(beat.at),                            progress: 0.42
                        )
                    )
                case .hack:
                    return AnyView(
                        TutorialHackPane(
                            elapsed: beat.at, progress: 0.42
                        )
                    )
                case .ready:
                    return AnyView(TutorialReadyPane())
                case .downloads:
                    return AnyView(
                        TutorialDownloadsPane(
                            elapsed: beat.at, progress: 0.42,                        )
                    )
                case .names:
                    return AnyView(
                        TutorialPane(
                            run: TutorialRun(beat.at), progress: 0.42
                        )
                    )
                }
            }
        let natural = views.map { NSHostingView(rootView: $0).fittingSize }

        let margin: CGFloat = 24
        let gap: CGFloat = 16
        let width = (natural.map(\.width).max() ?? 0) + margin * 2
        let height = natural.reduce(0) { $0 + $1.height }
            + gap * CGFloat(max(0, natural.count - 1)) + margin * 2

        guard let canvas = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(width * 2), pixelsHigh: Int(height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return 1 }
        canvas.size = NSSize(width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)

        // On the dark column, because that is the window the tour plays in.
        NSColor(white: 0.13, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        var top = height - margin
        for (index, view) in views.enumerated() {
            let size = natural[index]
            let box = NSRect(
                x: margin, y: top - size.height, width: size.width, height: size.height
            )
            if walk {
                // The other way round from the beats: `cacheDisplay` is the
                // only one that draws a real button, and the foot is what this
                // sheet is for. The cost is the pill, which comes back in a
                // black box — its bloom is a blur, and a blur makes SwiftUI
                // rasterise the layer. See `sheet`.
                let hosting = NSHostingView(rootView: view)
                hosting.appearance = NSAppearance(named: .darkAqua)
                hosting.frame = NSRect(origin: .zero, size: size)
                hosting.layoutSubtreeIfNeeded()
                if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                    hosting.cacheDisplay(in: hosting.bounds, to: rep)
                    rep.draw(in: box)
                }
            } else {
                // `ImageRenderer` and not `cacheDisplay`: the pill's bloom is a
                // blur, a blur makes SwiftUI rasterise the layer, and
                // `cacheDisplay` hands that back opaque. See `sheet`.
                let rendered = MainActor.assumeIsolated { () -> NSImage? in
                    let renderer = ImageRenderer(
                        content: view
                            .environment(\.colorScheme, .dark)
                            .frame(width: size.width, height: size.height)
                    )
                    renderer.scale = 2
                    renderer.isOpaque = false
                    return renderer.nsImage
                }
                rendered?.draw(in: box)
            }
            top -= size.height + gap
        }

        NSGraphicsContext.restoreGraphicsState()

        guard let png = canvas.representation(using: .png, properties: [:]) else { return 1 }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
            return 0
        } catch {
            print("✗ \(error.localizedDescription)")
            return 1
        }
    }

    /// Draws every surface into one PNG, light beside dark.
    ///
    /// The panels are the one part of the app with no test: they are looked at,
    /// not asserted on. A sheet of all of them at once is the closest thing to
    /// a regression test there is — drift between two of them is obvious side
    /// by side and invisible when they are minutes apart on a real screen.
    ///
    /// The translucency does not survive being drawn outside a window server
    /// composite, so the material comes out as flat grey here. Everything else
    /// — colour, type, spacing, the rim — is what you will see.
    static func sheet(to path: String) -> Int32 {
        // One model per state, because they are one surface now: the sheet is
        // the only place all of them are visible at once, which is where drift
        // between them shows.
        func pill(
            _ state: PillState, icon: NSImage? = nil, level: Float = 0,
            docked: Dock? = nil
        ) -> PillModel {
            let model = PillModel()
            model.state = state
            model.appIcon = icon
            model.level = level
            // Every offer is drawn hanging, because that is the only way it is
            // ever seen: square along the edge that meets the line, rounded
            // below, no rim. A lozenge here would be a picture of a state the
            // app does not have.
            model.docked = docked
            // No hotkey is registered behind the sheet, so the selection offer
            // is drawn against the shipped default — which is the one a reader
            // should be checking that row against, and is not this machine's.
            model.hotkey = "Right ⌘"
            return model
        }

        let notice = pill(.notice("Grammar applied", .done), docked: .below)
        let caution = pill(.notice("Grammar copied — this app won't let me edit it", .caution), docked: .below)
        let thinking = pill(.working("Thinking…"))
        // The offer before it is asked for: the bird and the key, and nothing
        // else. First because it is what every dictation now ends as — the ones
        // below are what it becomes when you rest on it.
        let tab = pill(.offer(offerChips, nil, Confidence.Reading(), open: false), docked: .below)
        // And the tab with something to warn about, which never appears in the
        // app — a doubtful decode opens by itself. On the sheet because the
        // amber pip has to be findable at 46pt, and that is only checkable
        // beside the plain one.
        let tabWarned = pill(.offer(
            offerChips, nil, Confidence.Reading(warning: sampleWarning), open: false
        ), docked: .below)
        let offer = pill(.offer(offerChips, nil, Confidence.Reading(), open: true), docked: .below)
        // The offer over a selection: three rows, and the words themselves
        // rather than a word for them. On the sheet because the difference from
        // the plain one is the whole design — a pill that says which words is a
        // different surface from one that says there are some, and a row that
        // is only sometimes there gets looked at nowhere else.
        let offerSelection = pill(.offer(
            offerChips, .selection("things that turned out not to matter"),
            Confidence.Reading(), open: true
        ), docked: .below)
        // Two: the pill is as wide as its sentence, and the short one says so.
        let learnChips = [
            OfferedCommand(title: "Yes", key: "Y"),
            OfferedCommand(title: "No", key: "N"),
            OfferedCommand(title: "Edit", key: "E"),
        ]
        let offerLearn = pill(.offer(
            learnChips,
            .learn(Learn(term: "disfluency", heard: "this fluency",
                         before: "I wanna work on", after: ".")),
            Confidence.Reading(), open: true
        ), docked: .below)
        let offerLearnShort = pill(.offer(
            learnChips,
            .learn(Learn(term: "Databricks", heard: "data breaks",
                         before: "we moved it to", after: ".")),
            Confidence.Reading(), open: true
        ), docked: .below)
        // The long one, through `learnPayload` rather than written out. The
        // two above are short enough to look right whatever the window does;
        // this is the case that wrapped a row measured for one line, and
        // nothing on the sheet showed it.
        let offerLearnLong = pill(.offer(
            learnChips, .learn(learnPreview(long: true)),
            Confidence.Reading(), open: true
        ), docked: .below)
        // The pre-write selector, beside the learn pills it is easy to
        // confuse it with: that one asks about a correction already made,
        // this one asks before anything is typed.
        let offerSelector = pill(.offer(
            [], .choose(selectorStep("")), Confidence.Reading(), open: true
        ), docked: .below)
        // The two cases the short one cannot show: a sentence the window has to
        // cut at both ends, and the second question of a run — the first answer
        // is already in the words, and the count says one more was asked.
        let offerSelectorLong = pill(.offer(
            [], .choose(selectorStep("long")), Confidence.Reading(), open: true
        ), docked: .below)
        let offerSelectorTwo = pill(.offer(
            [], .choose(selectorStep("two", answered: [1])),
            Confidence.Reading(), open: true
        ), docked: .below)
        // Beside the plain one: the two endings must not look the same.
        let offerCopied = pill(.offer(
            offerChips, .landing("Nowhere to type · ⌘V"), Confidence.Reading(),
            open: true
        ), docked: .below)
        // The warning on its own, which is what most people will ever see of
        // this: `feedback.confidence` is off by default and the thresholds are
        // not, so a shaky dictation raises one line and nothing else.
        let offerWarned = pill(.offer(
            offerChips, nil, Confidence.Reading(warning: sampleWarning), open: true
        ), docked: .below)
        // And the same pill after it has taken a Return: one step further
        // along the same ramp, which is the thing to check side by side —
        // amber and scarlet have to read as an escalation, not as two moods.
        let offerStopped = pill(.offer(
            offerChips, nil,
            Confidence.Reading(warning: Confidence.stopped, stopped: true), open: true
        ), docked: .below)
        // The same offer with `feedback.confidence` on.
        let offerHeard = pill(.offer(offerChips, nil, sampleReading, open: true), docked: .below)
        // Six transforms, which is one row too many for a panel pinned to a
        // character. See `PillMetrics.chipsWidth`.
        let offerWrapped = pill(
            .offer(offerManyChips, nil, Confidence.Reading(), open: true), docked: .below
        )
        // And a dictation long enough to wrap. On the sheet because the wrap is
        // the one thing here that is counted before it is drawn — a line count
        // off by one clips the words rather than costing a few points of pill.
        let offerHeardLong = pill(.offer(
            offerChips, nil,
            Confidence.Reading(
                words: sampleSentence + sampleSentence, warning: sampleWarning
            ),
            open: true
        ), docked: .below)

        // The dictation, hanging off a line: the bird half full, then standing
        // while it thinks. On the sheet because the whole recording state is
        // one mark now, and whether it reads at 20pt is the question.
        let listening = pill(.recording(nil), icon: sampleIcon(), level: 0.55, docked: .below)
        let listeningQuiet = pill(.recording(nil), icon: sampleIcon(), level: 0.06, docked: .below)
        let listeningBlind = pill(.recording(nil), level: 0.55, docked: .below)
        // Tap-then-hold: the words about to be edited, shown rather than
        // described. On the sheet because the highlight has to read at 12pt on
        // a 27pt tab, and because a long selection has to truncate rather than
        // widen the surface past the words it is pointing at.
        let editing = pill(
            .recording("things that turned out not to matter"),
            icon: sampleIcon(), level: 0.4, docked: .below
        )
        let thinkingDocked = pill(.working("Thinking…"), docked: .below)
        // Free: no anchor, so no line under it to say where the words are
        // going. The icon says it instead, which is the one difference between
        // this and the tab above it.
        let listeningFree = pill(.recording(nil), icon: sampleIcon(), level: 0.55, docked: .free)
        let thinkingFree = pill(.working("Thinking…"), icon: sampleIcon(), docked: .free)

        let overlay = pill(.recording(nil), icon: sampleIcon(), level: 0.75)

        // The pill has two states now and the difference is the whole point of
        // the slot: with somewhere to type it holds that app's icon, with
        // nowhere it holds nothing and is simply narrower — which is how you
        // are told the words are going to the clipboard instead. Both are on
        // the sheet because "it looks wrong with no icon" is the kind of thing
        // that is obvious side by side and invisible a week apart.
        let overlayBlind = pill(.recording(nil), level: 0.75)

        // And the third, which is not dictation at all: tap-then-hold, where
        // what you say is routed instead of written down. The label is the only
        // thing that says so, which is exactly why it belongs on this sheet.
        let overlayCommand = pill(
            .recording("editing the selection"), icon: sampleIcon(), level: 0.75
        )

        // A row the spell check proposed, half filled in, and a row typed by
        // hand — the two shapes the panel exists for, side by side.
        let correction = CorrectionModel()
        correction.load(sentence: "I work with Tasmin and Mick")
        correction.rows[0].corrected = "Tasmeen"

        // A name the decoder split in two. It arrives as no row at all — both
        // halves are ordinary words — so the left field is typed over. This is
        // the case the table has to be able to hold.
        let rule = CorrectionModel()
        rule.load(sentence: "we deployed on Ver Sal")
        rule.rows = [CorrectionRow(heard: "Ver Sal", corrected: "Vercel")]
        // The rows were replaced wholesale, so the focus `load` left points at
        // a row that no longer exists.
        rule.focus = CorrectionModel.Cell(row: rule.rows[0].id, column: .corrected)

        // Two rows. The sheet cannot show a focus ring on any of them: it
        // renders offscreen, in no key window, and SwiftUI grants focus to
        // neither.
        let several = CorrectionModel()
        several.load(sentence: "Olama runs polyma for Tasmine")

        // The panel the app opens by itself, which asks rather than collects:
        // a proposal, the sentence it would be kept in, and yes or no. The
        // three above are the summoned form and are not asking anything.
        let asked = CorrectionModel()
        asked.load(
            rules: [(heard: "this fluency", corrected: "disfluency")],
            over: "I wanna work on disfluency."
        )

        // Both states of the microphone notice, because the disclosure is the
        // shape of it: collapsed is what you read, open is the argument. A
        // device name long enough to outgrow the box shows here and nowhere
        // else — see `MicNoticeMetrics`.
        let micNotice = MicNoticeModel()
        micNotice.mic = sampleMicName
        let micNoticeOpen = MicNoticeModel()
        micNoticeOpen.mic = sampleMicName
        micNoticeOpen.expanded = true

        // Both states again, and the same argument: the collapsed one is what
        // you read, the open one is the three questions under it. The app name
        // is somebody else's and can be any length.
        let keyboardNotice = KeyboardNoticeModel()
        keyboardNotice.app = sampleKeyboardApp
        let keyboardNoticeOpen = KeyboardNoticeModel()
        keyboardNoticeOpen.app = sampleKeyboardApp
        keyboardNoticeOpen.expanded = true

        let preview = PreviewModel()
        preview.load(
            prompt: "Grammar",
            before: "i think we should of asked them first, their going to be annoyed",
            after: "I think we should have asked them first — they're going to be annoyed."
        )

        // The four states of the one screen, in the order they happen.
        let almostReady = sampleDownloads(speech: .downloading(percent: 62))
        let didNotArrive = sampleDownloads(speech: .failed(.unreachable))
        let ready = sampleDownloads(speech: .installed)
        ready.update(NeuralPhonemes.soundDownload.id, to: .installed)
        ready.update(SlotModel.download.id, to: .installed)
        ready.update(SentenceReadings.download.id, to: .installed)
        // The other blocking row. Its failure costs the speech gate rather than
        // the whole feature, and the sentence has to say which row it is about.
        let vadDidNotArrive = sampleDownloads(speech: .installed)
        vadDidNotArrive.update(Transcriber.voiceDownload.id, to: .failed(.stopped))

        // Screen one, which is a list and nothing else: the same registry the
        // screen after it reports on, before any of it has started.
        let listing = sampleDownloads(speech: .waiting)
        let modelsPane = AnyView(PermissionsView()
            .environmentObject(PermissionsModel.showingModels(listing))
            .environmentObject(listing))

        let almostReadyPane = AnyView(PermissionsView()
            .environmentObject(PermissionsModel.showingSetup(almostReady))
            .environmentObject(almostReady))
        // eSpeak NG settled and the models still coming: the one state where
        // the title is the state and there is still a bar under it.
        let almostThere = sampleDownloads(speech: .downloading(percent: 62))
        let almostTherePane = AnyView(PermissionsView()
            .environmentObject(PermissionsModel.showingSetup(almostThere, espeak: .found))
            .environmentObject(almostThere))

        let readyPane = AnyView(PermissionsView()
            .environmentObject(PermissionsModel.showingSetup(
                ready, context: .revisiting, espeak: .found))
            .environmentObject(ready))
        // The same screen with eSpeak NG never installed. Drawn to show that it
        // is the same screen: nothing on Ready reports what was installed.
        // Setting up, not revisiting — a revisit is the one context where
        // eSpeak NG takes the screen back.
        let readyWithoutEspeakPane = AnyView(PermissionsView()
            .environmentObject(PermissionsModel.showingSetup(ready))
            .environmentObject(ready))

        // Opened from the menu bar with eSpeak NG still missing. Everything is
        // downloaded, so nothing is greyed — the screen exists to offer the one
        // thing that is left.
        let revisitPane = AnyView(PermissionsView()
            .environmentObject(PermissionsModel.showingSetup(ready, context: .revisiting))
            .environmentObject(ready))

        let switchedOffPane = AnyView(PermissionsView()
            .environmentObject(PermissionsModel.showingSetup(
                ready, axStatus: .notGranted, espeak: .found))
            .environmentObject(ready))
        let didNotArrivePane = AnyView(PermissionsView()
            .environmentObject(PermissionsModel.showingSetup(didNotArrive))
            .environmentObject(didNotArrive))
        let vadPane = AnyView(PermissionsView()
            .environmentObject(PermissionsModel.showingSetup(vadDidNotArrive, espeak: .found))
            .environmentObject(vadDidNotArrive))
        // The middle of the eSpeak NG install: Terminal has the command and
        // this screen is waiting for the binary to turn up.
        let openingPane = AnyView(PermissionsView()
            .environmentObject(PermissionsModel.showingSetup(almostReady, espeak: .opening))
            .environmentObject(almostReady))

        // The third element is the appearance to draw in. Every floating
        // surface is dark whatever the system is set to — that is decided in
        // `adoptParrotAppearance` and is not a preference. The permissions
        // window is the exception and the reason this is a column at all: it is
        // an ordinary titled window, it follows the system, and it has to be
        // legible both ways. So it appears twice, once each.
        let surfaces: [(view: AnyView, size: NSSize, scheme: ColorScheme, drawn: Bool)] = [
            (AnyView(PillView().environmentObject(overlay)),
             pillSize(overlay), .dark, true),
            (AnyView(PillView().environmentObject(overlayBlind)),
             pillSize(overlayBlind), .dark, true),
            (AnyView(PillView().environmentObject(overlayCommand)),
             pillSize(overlayCommand), .dark, true),
            // The one real window the app has, and the first thing anyone sees.
            // On the sheet for the same reason as the rest: it is looked at,
            // not asserted on, and two screens that drift apart are obvious
            // side by side and invisible a week apart.
            //
            // One of each context, because the second button is the difference
            // between them and it is the part worth being able to see: setting
            // up says "Cancel installation", revisiting says "Not now".
            (AnyView(PermissionsView()
                .environmentObject(PermissionsModel.showing(.microphone))
                .environmentObject(ModelDownloads())),
             NSSize(width: PermissionMetrics.width, height: PermissionMetrics.height), .light, false),
            (AnyView(PermissionsView()
                .environmentObject(PermissionsModel.showing(
                    .accessibility, asked: true, context: .revisiting))
                .environmentObject(ModelDownloads())),
             NSSize(width: PermissionMetrics.width, height: PermissionMetrics.height), .dark, false),
            // The screen that lists what is coming, then the screen the walk
            // ends on in each of its states. The title is the state, so this is
            // the only place those sentences can be read against each other.
            (modelsPane, setupSize(modelsPane), .dark, false),
            (almostReadyPane, setupSize(almostReadyPane), .light, false),
            (almostTherePane, setupSize(almostTherePane), .dark, false),
            (readyPane, setupSize(readyPane), .dark, false),
            (readyWithoutEspeakPane, setupSize(readyWithoutEspeakPane), .dark, false),
            (revisitPane, setupSize(revisitPane), .dark, false),
            (switchedOffPane, setupSize(switchedOffPane), .dark, false),
            (didNotArrivePane, setupSize(didNotArrivePane), .light, false),
            (vadPane, setupSize(vadPane), .dark, false),
            (openingPane, setupSize(openingPane), .light, false),
            (AnyView(PillView().environmentObject(notice)),
             pillSize(notice), .dark, true),
            (AnyView(PillView().environmentObject(thinking)),
             pillSize(thinking), .dark, true),
            (AnyView(PillView().environmentObject(caution)),
             pillSize(caution), .dark, true),
            // What every dictation now ends as, and what the rest of this
            // block is that surface opened. Next to the notices because that is
            // the comparison that matters: it has to not look like one, and at
            // 46pt it has to be findable at all.
            (AnyView(PillView().environmentObject(listeningQuiet)),
             pillSize(listeningQuiet), .dark, true),
            (AnyView(PillView().environmentObject(listening)),
             pillSize(listening), .dark, true),
            (AnyView(PillView().environmentObject(listeningBlind)),
             pillSize(listeningBlind), .dark, true),
            (AnyView(PillView().environmentObject(editing)),
             pillSize(editing), .dark, true),
            (AnyView(PillView().environmentObject(thinkingDocked)),
             pillSize(thinkingDocked), .dark, true),
            (AnyView(PillView().environmentObject(listeningFree)),
             pillSize(listeningFree), .dark, true),
            (AnyView(PillView().environmentObject(thinkingFree)),
             pillSize(thinkingFree), .dark, true),
            (AnyView(PillView().environmentObject(tab)),
             pillSize(tab), .dark, true),
            (AnyView(PillView().environmentObject(tabWarned)),
             pillSize(tabWarned), .dark, true),
            (AnyView(PillView().environmentObject(offer)),
             pillSize(offer), .dark, true),
            (AnyView(PillView().environmentObject(offerSelection)),
             pillSize(offerSelection), .dark, true),
            (AnyView(PillView().environmentObject(offerLearn)),
             pillSize(offerLearn), .dark, true),
            (AnyView(PillView().environmentObject(offerLearnShort)),
             pillSize(offerLearnShort), .dark, true),
            (AnyView(PillView().environmentObject(offerLearnLong)),
             pillSize(offerLearnLong), .dark, true),
            (AnyView(PillView().environmentObject(offerSelector)),
             pillSize(offerSelector), .dark, true),
            (AnyView(PillView().environmentObject(offerSelectorLong)),
             pillSize(offerSelectorLong), .dark, true),
            (AnyView(PillView().environmentObject(offerSelectorTwo)),
             pillSize(offerSelectorTwo), .dark, true),
            (AnyView(PillView().environmentObject(offerCopied)),
             pillSize(offerCopied), .dark, true),
            // The same offer with `feedback.confidence` on: two rows instead of
            // one, and the only pill on the sheet that is not a lozenge.
            (AnyView(PillView().environmentObject(offerWarned)),
             pillSize(offerWarned), .dark, true),
            (AnyView(PillView().environmentObject(offerStopped)),
             pillSize(offerStopped), .dark, true),
            (AnyView(PillView().environmentObject(offerHeard)),
             pillSize(offerHeard), .dark, true),
            (AnyView(PillView().environmentObject(offerWrapped)),
             pillSize(offerWrapped), .dark, true),
            (AnyView(PillView().environmentObject(offerHeardLong)),
             pillSize(offerHeardLong), .dark, true),
            // Not a pill state at all, and the only surface here that is
            // about the hardware rather than about the words. Next to the pill
            // because that is what it appears beside.
            (AnyView(MicNoticeView().environmentObject(micNotice)),
             NSSize(width: MicNoticeMetrics.width,
                    height: MicNoticeMetrics.height(expanded: false)), .dark, true),
            (AnyView(MicNoticeView().environmentObject(micNoticeOpen)),
             NSSize(width: MicNoticeMetrics.width,
                    height: MicNoticeMetrics.height(expanded: true)), .dark, true),
            // Beside it, because it is the same object about the other half of
            // a dictation: the keyboard rather than the microphone.
            (AnyView(KeyboardNoticeView().environmentObject(keyboardNotice)),
             NSSize(width: KeyboardNoticeMetrics.width,
                    height: KeyboardNoticeMetrics.height(expanded: false)), .dark, true),
            (AnyView(KeyboardNoticeView().environmentObject(keyboardNoticeOpen)),
             NSSize(width: KeyboardNoticeMetrics.width,
                    height: KeyboardNoticeMetrics.height(expanded: true)), .dark, true),
            (AnyView(CorrectionView().environmentObject(correction)),
             NSSize(width: CorrectionMetrics.width, height: CorrectionMetrics.height(forRows: correction.rows.count)), .dark, false),
            (AnyView(CorrectionView().environmentObject(rule)),
             NSSize(width: CorrectionMetrics.width, height: CorrectionMetrics.height(forRows: rule.rows.count)), .dark, false),
            (AnyView(CorrectionView().environmentObject(several)),
             NSSize(width: CorrectionMetrics.width, height: CorrectionMetrics.height(forRows: several.rows.count)), .dark, false),
            (AnyView(CorrectionView().environmentObject(asked)),
             NSSize(width: CorrectionMetrics.width, height: CorrectionMetrics.height(forRows: asked.rows.count) + 44), .dark, false),
            // The dictation panel is deliberately not here. Its field is an
            // `NSTextField` and its background is real Liquid Glass, and this
            // sheet can draw neither — it came out as a white block inside an
            // untinted rectangle, which is worse than an omission. Look at it
            // with `--panels dictation`, on a screen, where both are real.
            (AnyView(PreviewView().environmentObject(preview)),
             NSSize(width: PreviewMetrics.sampleWidth + PreviewMetrics.bleed * 2,
                    height: PreviewMetrics.height(for: preview.after, singleLine: false)), .dark, true),
        ]

        let margin: CGFloat = 36
        let gap: CGFloat = 24
        let column = surfaces.map(\.size.width).max()! + margin * 2
        let tall = surfaces.map(\.size.height).reduce(0, +) + gap * CGFloat(surfaces.count - 1) + margin * 2
        let size = NSSize(width: column * 2, height: tall)

        guard let canvas = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return 1 }
        canvas.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)

        // The surfaces are dark either way; the columns are the two kinds of app
        // they land on top of.
        for index in 0..<2 {
            let left = CGFloat(index) * column
            (index == 0 ? NSColor.white : NSColor(white: 0.13, alpha: 1)).setFill()
            NSRect(x: left, y: 0, width: column, height: size.height).fill()

            var top = size.height - margin
            for (view, natural, scheme, drawn) in surfaces {
                let box = NSRect(
                    x: left + (column - natural.width) / 2,
                    y: top - natural.height,
                    width: natural.width,
                    height: natural.height
                )

                // Two ways to snapshot, and each is wrong for the other half.
                //
                // `ImageRenderer` draws the SwiftUI view itself, which is the
                // only way to keep the pill's glow: the glow is a blur, a blur
                // makes SwiftUI rasterize the layer, and `cacheDisplay` hands
                // that back opaque — every pill came out in a black rectangle.
                //
                // But `ImageRenderer` cannot draw an AppKit-backed control, so
                // the correction and preview panels come out with every text
                // field empty. Those keep `cacheDisplay`, which has no blur to
                // lose.
                if drawn {
                    // `assumeIsolated` because `ImageRenderer` is main-actor
                    // bound and this is a plain synchronous function — called
                    // from `main.swift` on the main thread and nowhere else.
                    let rendered = MainActor.assumeIsolated { () -> NSImage? in
                        let renderer = ImageRenderer(
                            content: view
                                .environment(\.colorScheme, scheme)
                                .frame(width: natural.width, height: natural.height)
                        )
                        renderer.scale = 2
                        renderer.isOpaque = false
                        return renderer.nsImage
                    }
                    rendered?.draw(in: box)
                } else {
                    let hosting = NSHostingView(rootView: view)
                    hosting.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                    hosting.frame = NSRect(origin: .zero, size: natural)
                    hosting.layoutSubtreeIfNeeded()
                    if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                        hosting.cacheDisplay(in: hosting.bounds, to: rep)
                        rep.draw(in: box)
                    }
                }
                top -= natural.height + gap
            }
        }

        NSGraphicsContext.restoreGraphicsState()

        guard let png = canvas.representation(using: .png, properties: [:]) else { return 1 }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
            return 0
        } catch {
            print("✗ \(error.localizedDescription)")
            return 1
        }
    }

    /// The window's size, not the capsule's — the glow needs the bleed around
    /// it or the sheet cuts the halo off square.
    private static func pillSize(_ model: PillModel) -> NSSize {
        PillMetrics.panelSize(
            for: model.state, hasIcon: model.appIcon != nil, hotkey: model.hotkey,
            dock: model.docked
        )
    }

    /// Something recognisable to sit in the pill's slot. Mail because that is
    /// the window the `email` transform was written for, and any Mac has it.
    private static func sampleIcon() -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.mail"
        ) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// A registry with one row in each state it can be in. The real one is
    /// filled in by the code that fetches — see `AppDelegate.warmModels`.
    static func sampleDownloads(speech: ModelDownload.State) -> ModelDownloads {
        let downloads = ModelDownloads()
        downloads.expect(Transcriber.speechDownload)
        downloads.update(Transcriber.speechDownload.id, to: speech)
        downloads.expect(Transcriber.voiceDownload)
        downloads.update(Transcriber.voiceDownload.id, to: .installed)
        downloads.expect(NeuralPhonemes.soundDownload)
        downloads.update(NeuralPhonemes.soundDownload.id, to: .failed(.unreachable))
        downloads.expect(SlotModel.download)
        downloads.expect(SentenceReadings.download)
        // Live, not `off`. It was switched off here to draw the "gate is off"
        // row, and that row went with the old screen — all it did after that
        // was keep the sixth model off the list.
        downloads.expect(WordVectors.download)
        return downloads
    }

    /// The setup screen has no fixed height: it takes the one its content asks
    /// for, the same way the window does.
    private static func setupSize(_ view: AnyView) -> NSSize {
        let fitting = NSHostingView(rootView: view).fittingSize
        return NSSize(
            width: PermissionMetrics.setupWidth,
            height: fitting.height > 0 ? fitting.height : PermissionMetrics.setupHeight
        )
    }

    /// An ordinary titled window. The setup screen is the one surface that is
    /// a window rather than a panel over somebody's words.
    private static func window(for view: AnyView, size: NSSize) -> NSWindow {
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "\(AppVariant.displayName) Setup"
        window.styleMask = [.titled, .closable]
        window.setContentSize(size)
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return window
    }

    static func run(surface: String, seconds: Double) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        // Held for the lifetime of the process: these own their NSPanels, and a
        // panel whose owner has been collected goes with it.
        let pill = PillHUD()
        let correction = CorrectionPanel()
        let preview = PreviewPanel()
        let micNotice = MicNotice()
        let keyboardNotice = KeyboardNotice()
        let updatePanel = UpdatePanel()
        var ticker: Timer?
        // How long the process stays up. A surface that outlasts the argument
        // says so here.
        var hold = seconds
        var setupWindow: NSWindow?
        var launchPanel: LaunchPanel?
        var calloutPanel: MenuBarCallout?
        var calloutItem: NSStatusItem?

        switch surface {
        case "notice":
            pill.notice("Grammar applied", tone: .done, duration: nil)
        case "caution":
            pill.notice("Grammar copied — this app won't let me edit it", tone: .caution, duration: nil)
        case "failure":
            pill.notice("Ollama is not running on localhost:11434", tone: .failure, duration: nil)
        case "alert":
            hold = max(seconds, AppDelegate.alertSeconds)
            // The grammar transform's shipped `failed:`, word for word.
            pill.alert(
                """
                Requires a language model.

                ```sh
                brew install ollama
                ollama run gemma4:e4b-mlx
                ```
                """,
                tone: .failure, for: hold
            )
        case "thinking":
            pill.working("Thinking…")
        case "learn":
            // Open and held: this offer outlives the others in the app too, so
            // a preview that faded would be a picture of something else.
            pill.offer(
                [
                    OfferedCommand(title: "Yes", key: "Y"),
                    OfferedCommand(title: "No", key: "N"),
                    OfferedCommand(title: "Edit", key: "E"),
                ],
                headline: .learn(Self.learnPreview(long: false)),
                open: true, for: seconds
            )
            pill.model.onHover = { inside in
                if !inside { pill.model.selected = nil }
                pill.hovering(inside)
            }
            // Held as though the pointer were on it: an open panel decays, and
            // this one is here to be looked at.
            pill.hovering(true)
        case "learn-long":
            // The case that wrapped a box measured for one line. Built through
            // `learnPayload`, so the preview shows the window the app applies
            // rather than a string typed to look right.
            pill.offer(
                [
                    OfferedCommand(title: "Yes", key: "Y"),
                    OfferedCommand(title: "No", key: "N"),
                    OfferedCommand(title: "Edit", key: "E"),
                ],
                headline: .learn(Self.learnPreview(long: true)),
                open: true, for: seconds
            )
            pill.model.onHover = { inside in
                if !inside { pill.model.selected = nil }
                pill.hovering(inside)
            }
            pill.hovering(true)
        case "selector", "selector-long", "selector-two":
            // The surface for a place the vocabulary step could not settle. One
            // question per pill; `selector-two` asks two, one after the other.
            // Held open: it is here to be looked at.
            let shape = surface == "selector-long" ? "long"
                : surface == "selector-two" ? "two" : ""
            var run = Self.selectorRun(shape)
            // Nothing is wired behind the surface yet, so a click has to say so
            // itself or there is no way to tell the target from the paint.
            func ask() {
                guard let step = run.next else { return }
                pill.offer([], headline: .choose(step), open: true, for: seconds)
                pill.model.onHover = { inside in
                    if !inside { pill.model.selected = nil }
                    pill.hovering(inside)
                }
                pill.model.onPick = { index in
                    Log.write("selector: picked option \(index + 1)")
                    print("picked option \(index + 1)")
                    run.answer(index)
                    guard run.next != nil else {
                        print("would type: \(run.sentence)")
                        exit(0)
                    }
                    ask()
                }
                pill.hovering(true)
            }
            // Aimed once, after a pause: the caret at launch is in the terminal
            // that started this. Aiming again between questions would be a jump
            // the app never makes — `PillHUD.aim` is set at the press and read
            // by every state after it.
            print("click where the words would go — the pill comes up in 6s")
            Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { _ in
                aimAtCaret(pill)
                ask()
            }
        case "offer":
            // The real call rather than a bare `set`. The offer is the one
            // state that holds and then thins out, so a preview that only held
            // would be a picture of a pill that never leaves. It gets the
            // duration the app gives it.
            pill.offer(offerChips, for: AppDelegate.offerSeconds)
            // The one state that takes the mouse, so the one worth being able
            // to hover. Nothing runs — this is the surface, not the app — but
            // the highlight and the hold behave the way they do there: park the
            // pointer on the pill and it stops fading, which is also how you
            // keep it on screen for as long as you want to look at it.
            pill.model.onHover = { inside in
                if !inside { pill.model.selected = nil }
                pill.hovering(inside)
            }
            pill.model.onPick = { index in
                print("offer: chip \(index) — \(offerChips[index].title)")
            }
        // The same offer with `feedback.confidence` on — the only pill that is
        // two rows, and the only one that is not a lozenge.
        case "confidence":
            pill.offer(offerChips, reading: sampleReading, for: AppDelegate.offerSeconds)
            pill.model.onHover = { inside in
                if !inside { pill.model.selected = nil }
                pill.hovering(inside)
            }
        case "vocabulary":
            correction.show(selection: "I work with Tasmin and Mick on Versal")
        // A sentence where the spell check finds nothing, so the panel opens
        // with one blank row. That is 33 of the 56 sentences measured.
        case "punctuation":
            correction.show(selection: "Trois, quatre, cinq.")
        // One of the two rules heard two words. No proposal can produce that
        // row, so it is what the editable left field is for.
        case "rule":
            correction.show(rules: [(heard: "Ver Sal", corrected: "Vercel"),
                                    (heard: "Mick", corrected: "Mik")])
        // The panel the pill's offer opens: one line, editable, over what was
        // just dictated. A different shape from the transform preview below —
        // short enough for a field rather than an area — and the one that is
        // seen most, so it is worth being able to look at on its own.
        case "dictation":
            preview.show(transcript: "Let's ship the vocabulary harness on Tuesday.")
        case "preview":
            preview.show(
                prompt: "Grammar",
                before: "i think we should of asked them first, their going to be annoyed",
                after: "I think we should have asked them first — they're going to be annoyed."
            )
        // The one surface that has to be clicked to be seen whole: it opens
        // where it opens in the app, and the disclosure and "Got it" both work
        // here. `show(mic:)` rather than `showIfNeeded`, so it appears on a
        // machine whose microphone is wired.
        case "microphone":
            micNotice.show(mic: sampleMicName)
        // Raised for a named app rather than for whatever is really holding
        // the keyboard, which on a healthy machine is nothing at all.
        case "keyboard":
            keyboardNotice.show(app: sampleKeyboardApp)
        // The one surface that is a window rather than a floating panel over
        // the words. Sized from the notes it is given, so a long release is
        // what shows whether it scrolls.
        case "update":
            updatePanel.show(
                release: sampleRelease,
                current: "0.6.0",
                blocker: UpdateInstaller.blocker,
                answers: UpdatePanel.Answers(
                    install: UpdateInstaller.blocker == nil ? { print("update: install") } : nil,
                    copyCommand: { print("update: copy the command") },
                    skip: { print("update: skip") },
                    later: { print("update: later") }
                )
            )
        // The screen that lists what is about to be fetched. A still, like the
        // screen itself: nothing on it has started.
        // The callout the install leaves under the menu bar icon.
        //
        // With a real status item, not a guess at where one would be. It was a
        // guess — `maxX - 140` — and that is where the clock is, so the preview
        // put the callout under the clock and the one thing it exists to show
        // was the one thing it got wrong.
        case "callout":
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.image = NSImage(named: "MenuBarParrotTemplate")
            item.button?.image?.isTemplate = true
            calloutItem = item
            calloutPanel = MenuBarCallout()
            // After the menu bar has laid the item out. Asked on this turn of
            // the run loop, the button has no window yet and no frame to point
            // at.
            DispatchQueue.main.async { [calloutPanel] in
                calloutPanel?.show(
                    under: item.button, hotkey: Tutorial.hotkey
                )
            }
        case "models":
            let listing = sampleDownloads(speech: .waiting)
            let pane = AnyView(
                PermissionsView()
                    .environmentObject(PermissionsModel.showingModels(listing))
                    .environmentObject(listing)
            )
            setupWindow = window(for: pane, size: setupSize(pane))

        // The setup window, on the step that reports the downloads. A real
        // registry is empty in this process — nothing here fetches anything —
        // so it runs on a sample whose percentage climbs, which is the part
        // that cannot be checked from a still.
        case "setup":
            let downloads = sampleDownloads(speech: .downloading(percent: 8))
            let model = PermissionsModel.showingSetup(downloads)
            let pane = AnyView(
                PermissionsView()
                    .environmentObject(model)
                    .environmentObject(downloads)
            )
            setupWindow = window(for: pane, size: setupSize(pane))
            var percent = 8
            ticker = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { _ in
                percent += 1
                if percent > 100 {
                    // Parakeet lands first and Silero VAD follows it, which is
                    // the moment the title has to name the second row rather
                    // than the first.
                    downloads.update(Transcriber.speechDownload.id, to: .installed)
                    downloads.update(
                        Transcriber.voiceDownload.id, to: .downloading(percent: nil)
                    )
                    downloads.update(SlotModel.download.id, to: .downloading(percent: nil))
                    return
                }
                downloads.update(
                    Transcriber.speechDownload.id, to: .downloading(percent: percent)
                )
            }
        // The launch panel, walked through the three things it says: a
        // download with a number on it, the load after it, and the end. It has
        // no still worth looking at — the whole point of it is that it moves —
        // so the preview runs the sequence on a loop rather than parking on one
        // state. Same reasoning as `sequence` below.
        case "launch":
            // All six, which is what a first install declares. Three of them
            // are drawn — see `LaunchModel.shown` — and the panel has to be
            // right at the number it will really be handed, not at the number
            // that fits.
            let downloads = ModelDownloads()
            for row in [
                Transcriber.speechDownload, Transcriber.voiceDownload,
                NeuralPhonemes.soundDownload, SlotModel.download,
                SentenceReadings.download, WordVectors.download
            ] {
                downloads.expect(row)
            }
            let coming = downloads.rows.map(\.id)
            let panel = LaunchPanel(downloads: downloads)
            launchPanel = panel
            panel.showIfNeeded(hotkey: "Right ⌥")
            var percent = 0
            ticker = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { _ in
                percent += 1
                if percent > 190 {
                    percent = 0
                    for id in coming { downloads.update(id, to: .waiting) }
                    panel.showIfNeeded(hotkey: "Right ⌥")
                    return
                }
                // Staggered, the way they really arrive: they start together
                // and the smallest lands first.
                for (index, id) in coming.enumerated() {
                    let share = Double(percent) * (1.0 - Double(index) * 0.11)
                    if share >= 100 {
                        // Downloaded is not loaded. Every one of them spends a
                        // moment here, which is the state this panel was built
                        // to have a word for.
                        downloads.update(id, to: share >= 118 ? .installed : .loading)
                    } else {
                        downloads.update(id, to: .downloading(percent: Int(share)))
                    }
                }
            }
        case "pill":
            pill.recording(icon: sampleIcon())
            // A meter frozen at zero says nothing about how the meter looks.
            var phase = 0.0
            ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                phase += 0.05
                pill.model.level = Float(0.5 + 0.45 * sin(phase * 2))
            }

        // The one surface whose point is the motion between its states, so it
        // is the one that cannot be checked from a still. Runs the whole
        // dictation — hot mic, decoding, applied, the offer, gone — on a loop,
        // which is the only way to see whether the pill morphs or jumps.
        case "sequence":
            var phase = 0.0
            let meter = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                phase += 0.05
                pill.model.level = Float(0.5 + 0.45 * sin(phase * 2))
            }
            ticker = meter

            let script: [(TimeInterval, () -> Void)] = [
                (0.0, { pill.recording(icon: sampleIcon()) }),
                (2.6, { pill.working("Transcribing…") }),
                (4.0, { pill.working("Grammar…") }),
                (5.4, { pill.notice("Grammar applied", tone: .done, duration: nil) }),
                (7.4, { pill.offer(offerChips, for: 3) }),
                (11.4, { pill.recording(icon: nil) }),
                (14.0, { pill.working("Transcribing…") }),
                (15.4, { pill.notice("Nowhere to type — the transcription is on your clipboard",
                                     tone: .caution, duration: 3) }),
            ]
            let loop = script.last!.0 + 5
            for turn in stride(from: 0.0, to: seconds, by: loop) {
                for (at, step) in script {
                    DispatchQueue.main.asyncAfter(deadline: .now() + turn + at, execute: step)
                }
            }
        // The tour the setup window plays, on its own clock. `tutorial` plays
        // every screen of it one after the other; a name plays one on its own,
        // which is what you want while editing one.
        case "tutorial", "names", "slack", "hack", "downloads", "ready":
            // `TourWalk.screens` and not every case: the dots count what is
            // playing, so a list with `ready` in it — which the setup window
            // never plays — shows five dots for a four-screen walk.
            let screens: [TourScreen] = surface == "tutorial"
                ? TourWalk.screens
                : TourScreen.allCases.filter { $0.rawValue == surface }
            // The window follows the screen, which is what the setup window
            // does: each screen keeps the height of its own tallest beat, so
            // none of them ends in a band of nothing above the foot.
            let sizer = TourWindowSizer()
            let preview = window(
                for: AnyView(
                    TourPreview(screens: screens, onHeight: sizer.fit)
                ),
                size: NSSize(
                    width: PermissionMetrics.setupWidth,
                    height: screens.first?.height ?? 0
                )
            )
            sizer.window = preview
            setupWindow = preview
        default:
            print("usage: ParrotFlow --panels <notice|caution|failure|alert|thinking|offer"
                + "|confidence|vocabulary|punctuation|rule|dictation|preview|microphone"
                + "|keyboard|pill|learn|learn-long|selector|selector-long|selector-two"
                + "|update|models|setup|launch|sequence|tutorial|names|slack|hack"
                + "|downloads|ready|callout> [seconds]")
            return 2
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + hold) {
            ticker?.invalidate()
            setupWindow?.close()
            launchPanel?.dismiss()
            exit(0)
        }
        app.run()
        return 0
    }
}

/// The window `--panels` put a tour in, so the tour can resize it the way the
/// setup window resizes itself.
private final class TourWindowSizer {
    weak var window: NSWindow?

    /// The top edge is put back afterwards: `setContentSize` keeps the
    /// bottom-left corner, and a window that grows upward moves its own title
    /// bar out from under the pointer. Same as `resizeToContent`.
    func fit(_ height: CGFloat) {
        guard let window else { return }
        let top = window.frame.maxY
        window.setContentSize(
            NSSize(width: PermissionMetrics.setupWidth, height: height)
        )
        var frame = window.frame
        frame.origin.y = top - frame.height
        window.setFrame(frame, display: true)
    }
}

/// The tour, on its own clock, for `--panels`.
///
/// A dot at the bottom moves the clock, the way it does in the setup window.
private struct TourPreview: View {
    let screens: [TourScreen]
    /// The tour wants another height, once a frame while a cut is easing.
    var onHeight: (CGFloat) -> Void = { _ in }

    @State private var started = Date()
    /// What a dot has moved the clock by.
    @State private var skew: TimeInterval = 0

    var body: some View {
        TimelineView(.periodic(from: started, by: 1.0 / 60)) { context in
            let ran = context.date.timeIntervalSince(started)
            let elapsed = ran + skew
            let height = TourWalk.height(at: elapsed, in: screens)
            SetupTour(
                elapsed: elapsed,
                // Nothing here downloads anything, so the bar is the clock: a
                // slow climb, capped short of full, which from the outside is
                // what a real one looks like. The app passes the downloader's
                // own number, and that one arrives.
                progress: min(0.9, 0.05 + elapsed / 180),
                // A name the app would have put here, so the strip is the one
                // the setup window draws rather than its fallback.
                fetching: "1 of 6 · Parakeet TDT 0.6B v3",
                screens: screens,
                seek: { skew = $0 - ran }
            )
            .onChange(of: height) { _, _ in onHeight(height) }
        }
    }
}
