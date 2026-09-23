import AppKit
import SwiftUI

/// The vocabulary tour — the demonstration the setup window plays while the
/// models download.
///
/// Four dictations into one field. The first two are corrected by hand, and the
/// app offers to keep each correction: one teaches a spelling the decoder does
/// not know, the other teaches the spelling the first one's own rule then wrote
/// by mistake. The last two are dictated into a field that already holds the
/// first of them and need no correction at all: two names are one sound by
/// then, so the app asks which of them was said, and the answer writes the
/// sentence.
///
/// Nothing here is a picture of the app: the pill is the real `PillView`,
/// driven through the states a dictation passes through. The field is the one
/// stand-in, because a tutorial cannot type into somebody else's window.
///
/// Everything is a function of how long the tour has been running. A tour built
/// out of timers cannot be paused, seeked or replayed, and one dropped frame
/// leaves the pill a beat behind the words for the rest of the run.
enum Tutorial {

    /// Before the key goes down, so the empty line is seen first.
    static let leadIn: TimeInterval = 0.6
    /// The key is held. Long enough to have read as a state rather than as a
    /// flicker, and no longer: the meter has nothing new to say after the first
    /// second, and both tours then wait on it before the words arrive.
    static let held: TimeInterval = 1.5
    /// The words being worked out. The same tab, with the plumage sweeping
    /// through the bird and the rim turning instead of pulsing — which is what
    /// the app shows, and half a second is enough to read as a state rather
    /// than as a flicker.
    static let settling: TimeInterval = 0.5

    /// Where the sentence lands, whole and all at once.
    ///
    /// The app pastes what it decoded; it does not type it, and a tour that
    /// types it is showing a feature the app does not have.
    static var landsAt: TimeInterval { leadIn + held + settling }

    /// One correction: landed, one keystroke, offered, answered, and the notice
    /// left on screen for a beat before the story moves on.
    static let example: TimeInterval = 6.3

    /// How long a surface takes to settle once it arrives.
    static let landing: TimeInterval = 0.28

    /// Where each step of one correction begins, in seconds from the words
    /// landing.
    enum Beat: TimeInterval, CaseIterable {
        /// The sentence, whole, all at once, and no pill: the offer arrives on
        /// its own once the word has been changed.
        case landed = 0.0
        /// The caret moves into the word, where the letter goes.
        case placed = 0.7
        /// One keystroke: the letter is in, or out.
        case inserted = 1.5
        case offering = 2.3
        /// The pointer goes down on *Yes*, earlier than the offer's own pace
        /// would put it and held for a beat longer: the click is the thing the
        /// screen is asking for, and at a glance it was the easiest beat to
        /// miss.
        case clicking = 4.0
        case saved = 5.0

        /// Which step a time inside the example falls in.
        static func at(_ local: TimeInterval) -> Beat {
            allCases.last { local >= $0.rawValue } ?? .landed
        }
    }

    // MARK: - The story

    /// How long the last two dictations are held for, which is less than the
    /// first two. The gesture has been seen twice by the time they are said,
    /// and both of them land right, so there is nothing in either to wait for.
    static let heldAgain: TimeInterval = 0.9

    /// How long one dictation takes, from the key going down to the words
    /// landing.
    static func dictated(_ number: Int) -> TimeInterval {
        number <= 2 ? landsAt : leadIn + heldAgain + settling
    }

    /// When each of the four dictations begins.
    ///
    /// A correction runs on from the words landing, so the movement after it
    /// starts one `example` later, on a field that has been emptied again.
    static let firstAt: TimeInterval = 0
    static var firstLands: TimeInterval { firstAt + dictated(1) }
    static var secondAt: TimeInterval { firstLands + example }
    static var secondLands: TimeInterval { secondAt + dictated(2) }
    static var thirdAt: TimeInterval { secondLands + example }
    static var thirdLands: TimeInterval { thirdAt + dictated(3) }

    /// Between the last two, long enough for the first to be read and no
    /// longer. They are two dictations into one line of one field.
    static let pause: TimeInterval = 0.5
    static var fourthAt: TimeInterval { thirdLands + pause }
    static var fourthLands: TimeInterval { fourthAt + dictated(4) }

    /// The last two dictations, and neither needs anything done to it.
    ///
    /// They are one line: the second is dictated where the caret was left,
    /// which is on the end of the first. Two names are one sound by then, so
    /// the app no longer writes the first one's rule over the second: `Mik`
    /// belongs in the first sentence and `Mick` in the second, and the
    /// sentences each name was already confirmed in are what decides which is
    /// which. That is the whole point of the two corrections above, and why
    /// these two are dictated into a field nothing is done to.
    static let writes: [String] = [
        "Mik is writing code.",
        "Mick is a musician.",
    ]

    /// The name each of those two is about: the two words left lit when the
    /// line holds both of them.
    static let names: [String] = ["Mik", "Mick"]

    /// Which words of the field say where they are, so the screen can dim
    /// round them. See `TourSpot`.
    enum Lit: Equatable {
        case none
        /// The word carrying the caret, which during a correction is the one
        /// being corrected.
        case caret
        /// Words by what they say.
        case words([String])
    }

    /// The key the tour tells everyone to hold, in one place: the pill writes
    /// it on the offer, the last screen names it, and every box reserved for a
    /// surface is measured with it, because a different key is a different
    /// width.
    ///
    /// Written from what this Mac bound, by `applyConfig`, before any of those
    /// boxes is measured. They are measured once, so a hotkey changed while
    /// the tour is on screen keeps the old key's width; the tour only plays
    /// during an install, where nobody is editing config.yaml.
    ///
    /// The literal is the fallback for `--panels` and the sheets, where
    /// nothing is bound. It used to be the only value, and the shipped default
    /// is `right_command`, so the tour told everyone but this machine to hold
    /// the wrong key.
    static var hotkey = "Right ⌥"

    /// How long the two names are held lit before the walk moves on. Two
    /// seconds, which is the second and a half the finished line was left up
    /// for plus the half second the light used to take to cross it — the pass
    /// is the length it was.
    static let settled: TimeInterval = 2.0
    /// The rest of the pass, held on the finished line before the next screen
    /// is cut to.
    ///
    /// This was a cross-fade, over exactly this long, and it is not one any
    /// more: it wrapped a whole screen in an `opacity` for the length of the
    /// hand-off, and a screen behind an `opacity` is one SwiftUI renders into a
    /// layer of its own — the window stopped drawing new frames from that
    /// moment on and held the first frame of the next screen. The length is
    /// kept, so the timing of the walk is what it was.
    static let handoff: TimeInterval = 0.4

    /// How long one blink of the caret takes. A caret in a field blinks, and a
    /// caret that stands still reads as part of the words.
    static let blink: TimeInterval = 1.06
    /// The dimmest the caret gets. It never goes out: a caret nobody can see is
    /// a caret that is not there, and every still of this screen is read at
    /// whatever moment its beat falls on.
    static let caretDim: Double = 0.15
    /// How far down the rest of the screen goes while something on it is being
    /// pointed at, and how long the dimming takes to arrive and leave.
    static let dimmed = 0.66
    static let dimming: TimeInterval = 0.3

    /// How long after the last sentence lands the two names are lit. A second
    /// first, so the line is read as what the app wrote before anything is
    /// said about it.
    ///
    /// This was a band of light crossing both names. The screen dims round
    /// them instead — the same thing the corrections do, and the one gesture
    /// this screen makes twice already.
    static let beforeNames: TimeInterval = 1.0

    /// One pass: the four dictations, the names lit, the wait, and the
    /// hand-off.
    static var total: TimeInterval {
        fourthLands + beforeNames + settled + handoff
    }

    /// The largest the pill gets, and the box the stage reserves for it in
    /// every state.
    ///
    /// The real pill is sized by its state — the bird's own tab while it
    /// listens, a sentence and three chips when it offers, the sentence with
    /// its readings stacked when it asks — so a stage that gave it only what it
    /// asked for moved the field underneath it every time it changed. The panel
    /// is reserved at its widest and the surface is aligned to the top of it,
    /// which is where it hangs off the caret.
    static let reservedPanel: NSSize = {
        let sizes = states.map {
            PillMetrics.panelSize(
                for: $0, hasIcon: true, hotkey: Tutorial.hotkey, dock: .below
            )
        }
        return NSSize(
            width: sizes.map(\.width).max() ?? 0,
            height: sizes.map(\.height).max() ?? 0
        )
    }()

    /// Every state the pill is shown in on this screen, which is what the space
    /// reserved for it is measured over.
    static var states: [PillState] {
        let example = TutorialExample.first
        return [
            .recording(nil),
            .offer(
                TutorialExample.chips, .learn(example.learn),
                Confidence.Reading(), open: true
            ),
            .notice(example.saved, .done),
        ]
    }

    /// The tallest the *drawn* surface gets, with the transparent margin around
    /// it taken off.
    ///
    /// A recording tab carries 52 points of that margin and an offer carries 12,
    /// so the panels are not the surfaces. This is what hangs past the bottom of
    /// the composer, and the room reserved under it is measured from here.
    static let tallestSurface: CGFloat = states.map {
        PillMetrics.panelSize(
            for: $0, hasIcon: true, hotkey: Tutorial.hotkey, dock: .below
        ).height - PillMetrics.bleed(for: $0) * 2
    }.max() ?? 0
}

/// One correction: the sentence as the app wrote it, the word it got wrong, and
/// what the person put there instead.
///
/// A name, and the pair is the one the vocabulary's own sound groups are built
/// from: two people whose names are one sound. The first teaches the spelling;
/// the second teaches the spelling the first one's rule then wrote by mistake,
/// which is what makes the two of them a group.
struct TutorialExample: Equatable {
    /// The sentence, word by word, as the app first wrote it.
    let written: [String]
    /// Which word of it is the one being fixed.
    let wrong: Int
    /// What the app wrote there.
    let heard: String
    /// What the correction puts there.
    let term: String
    /// Where the caret stands inside `heard` for the one keystroke, and where
    /// it is left inside `term` once the keystroke has been made.
    ///
    /// Both count characters from the start of the word. A letter taken out
    /// starts with the caret to its right — a letter typed in the wrong place
    /// is deleted with the caret after it — and leaves the caret closed onto
    /// the letter before the hole. A letter put in starts where it goes and
    /// leaves the caret on its right.
    ///
    /// One letter, taken out or put in. A spelling the decoder got almost right
    /// is the case worth showing: it is the one where the person would not
    /// bother, and the one the offer exists to catch.
    let at: Int
    let lands: Int

    /// The first name. The decoder spells it the common way and the person
    /// spells it their own way, so the `c` comes out: the caret goes in between
    /// the `c` and the `k`, and deletes the `c`.
    static let first = TutorialExample(
        written: ["My", "teammate", "Mick", "is", "a", "software", "engineer."],
        wrong: 2, heard: "Mick", term: "Mik", at: 3, lands: 2
    )

    /// The second. The rule the first one saved has already turned this "Mick"
    /// into "Mik", and the `c` goes back in: the caret sits between the `i` and
    /// the `k`, types the `c`, and is left between the `c` and the `k`.
    static let second = TutorialExample(
        written: ["My", "friend", "Mik", "plays", "the", "guitar."],
        wrong: 2, heard: "Mik", term: "Mick", at: 2, lands: 3
    )

    /// The three the app offers on a correction it could keep.
    static let chips = [
        OfferedCommand(title: "Yes", key: "Y"),
        OfferedCommand(title: "No", key: "N"),
        OfferedCommand(title: "Edit", key: "E"),
    ]

    var corrected: [String] {
        var out = written
        out.replaceSubrange(wrong...wrong, with: [term])
        return out
    }

    var before: [String] { Array(written[..<wrong]) }
    var after: [String] { Array(written[(wrong + 1)...]) }

    var learn: Learn {
        Learn(
            term: term, heard: heard,
            before: before.joined(separator: " "),
            after: after.isEmpty ? "" : " " + after.joined(separator: " ")
        )
    }

    /// The notice the app leaves once the rule is kept.
    var saved: String { "Saved  \(heard) → \(term)" }
}

/// What the tour is doing at one moment.
struct TutorialRun: Equatable {
    /// Seconds into one pass.
    let t: TimeInterval
    /// Seconds since this screen's demonstration started, which is what the way
    /// on waits for. `t` wraps, so it cannot answer that.
    let elapsed: TimeInterval

    init(_ elapsed: TimeInterval) {
        self.elapsed = elapsed
        let total = Tutorial.total
        guard total > 0 else { t = 0; return }
        let wrapped = elapsed.truncatingRemainder(dividingBy: total)
        t = wrapped < 0 ? wrapped + total : wrapped
    }

    /// Whether the demonstration has played once through.
    ///
    /// The way on is held back until it has. The screen exists to show this,
    /// and a *Next* that is there from the first frame is a *Next* people press
    /// from the first frame.
    var finished: Bool { elapsed >= Tutorial.total }

    enum Phase: Equatable {
        /// Before a key goes down, on a field that is empty again.
        case idle(Int)
        case listening(Int)
        case settling(Int)
        case correcting(TutorialExample, Tutorial.Beat)
        /// The words are in the field. Nothing is asked about them.
        case written(Int)
    }

    /// Where one of the four dictations began, and where its words landed.
    private static func began(_ number: Int) -> TimeInterval {
        switch number {
        case 1: return Tutorial.firstAt
        case 2: return Tutorial.secondAt
        case 3: return Tutorial.thirdAt
        default: return Tutorial.fourthAt
        }
    }

    private static func landed(_ number: Int) -> TimeInterval {
        switch number {
        case 1: return Tutorial.firstLands
        case 2: return Tutorial.secondLands
        case 3: return Tutorial.thirdLands
        default: return Tutorial.fourthLands
        }
    }

    var phase: Phase {
        if t < Tutorial.firstLands { return dictation(1) }
        if t < Tutorial.secondAt {
            return .correcting(
                TutorialExample.first, Tutorial.Beat.at(t - Tutorial.firstLands)
            )
        }
        if t < Tutorial.secondLands { return dictation(2) }
        if t < Tutorial.thirdAt {
            return .correcting(
                TutorialExample.second, Tutorial.Beat.at(t - Tutorial.secondLands)
            )
        }
        if t < Tutorial.thirdLands { return dictation(3) }
        // The third sentence stays in the field: the fourth is dictated a line
        // under it, in the same field, and it is left up on its own for a beat
        // first, because it is the first one nothing had to be done to.
        if t < Tutorial.fourthAt { return .written(3) }
        if t < Tutorial.fourthLands { return dictation(4) }
        return .written(4)
    }

    /// The key, the hold, and the words being worked out, off that dictation's
    /// own clock.
    private func dictation(_ number: Int) -> Phase {
        let local = t - TutorialRun.began(number)
        if local < Tutorial.leadIn { return .idle(number) }
        if local < Tutorial.dictated(number) - Tutorial.settling {
            return .listening(number)
        }
        return .settling(number)
    }

    /// Which of the four dictations the moment belongs to.
    private var movement: Int {
        if t < Tutorial.secondAt { return 1 }
        if t < Tutorial.thirdAt { return 2 }
        if t < Tutorial.fourthAt { return 3 }
        return 4
    }

    /// Seconds since the movement that is playing began, which is the clock the
    /// caret blinks on: it starts again in each field, the way a caret does.
    private var local: TimeInterval { t - TutorialRun.began(movement) }

    /// How visible the caret is.
    ///
    /// A square wave with a short edge, so it is a blink rather than a flicker
    /// at the frame rate, and never fully out. See `Tutorial.caretDim`.
    var caret: Double {
        let phase = local.truncatingRemainder(dividingBy: Tutorial.blink)
            / Tutorial.blink
        let edge = 0.08
        let up: Double
        if phase < 0.5 - edge { up = 1 }
        else if phase < 0.5 + edge { up = 1 - (phase - 0.5 + edge) / (2 * edge) }
        else if phase < 1 - edge { up = 0 }
        else { up = (phase - 1 + edge) / (2 * edge) }
        return Tutorial.caretDim + (1 - Tutorial.caretDim) * up
    }

    /// Which dictation the meter is on, or nil when no key is down.
    private var listening: Int? {
        guard case .listening(let number) = phase else { return nil }
        return number
    }

    /// The level the meter is fed.
    ///
    /// A curve, not a microphone: the tour is silent, because a setup window
    /// that makes noise before anyone asked it to is a window people close.
    var level: Double {
        guard let number = listening else { return 0.18 }
        let u = t - TutorialRun.began(number) - Tutorial.leadIn
        let wave = abs(sin(u * 3.1)) * (0.65 + 0.35 * sin(u * 7.7))
        return min(1, max(0.18, 0.22 + 0.78 * wave))
    }

    /// How far a surface has settled, from the moment it arrived.
    private func settled(since: TimeInterval) -> Double {
        min(1, max(0, (t - since) / Tutorial.landing))
    }

    /// How far the pill has settled: 0 as it arrives, 1 once it is placed.
    ///
    /// Derived from the clock like everything else, so the landing is a frame of
    /// the tour rather than a side effect fired at a moment — it can be seeked
    /// to, and a dropped frame does not skip it.
    var landing: Double {
        switch phase {
        case .correcting(_, .offering):
            let at = (t < Tutorial.secondAt ? Tutorial.firstLands : Tutorial.secondLands)
                + Tutorial.Beat.offering.rawValue
            return settled(since: at)
        default:
            return 1
        }
    }

    /// What the pill is doing, or nil while it is off screen.
    var pill: PillState? {
        switch phase {
        case .idle, .written:
            return nil
        case .listening:
            return .recording(nil)
        case .settling:
            return .working("Transcribing…")
        case .correcting(let example, let beat):
            switch beat {
            case .landed, .placed, .inserted:
                // Nothing on the surface. The words are there and nothing is
                // being asked about them yet.
                return nil
            case .offering, .clicking:
                return .offer(
                    TutorialExample.chips, .learn(example.learn),
                    Confidence.Reading(), open: true
                )
            case .saved:
                return .notice(example.saved, .done)
            }
        }
    }

    /// One stretch of the pass the screen dims over, and what stays lit.
    struct Lighting: Equatable {
        let from: TimeInterval
        let to: TimeInterval
        /// When the offer's surface joins the word, or nil for a stretch with
        /// no surface in it.
        let opens: TimeInterval?
        let lit: Tutorial.Lit
    }

    /// Every stretch of the pass the screen dims over.
    ///
    /// The two corrections: from the caret moving into the word, a beat before
    /// the keystroke, to the offer being answered. Then the end of the pass,
    /// where the line holds both names and nobody was asked about either —
    /// which is the point of the screen, so it is said the same way.
    ///
    /// `--tour-film` reads these too, to hold the film at 1x over them.
    static var lighting: [Lighting] {
        [Tutorial.firstLands, Tutorial.secondLands].map { lands in
            Lighting(
                from: lands + Tutorial.Beat.placed.rawValue,
                to: lands + Tutorial.Beat.saved.rawValue,
                opens: lands + Tutorial.Beat.offering.rawValue,
                lit: .caret
            )
        } + [
            Lighting(
                from: Tutorial.fourthLands + Tutorial.beforeNames,
                to: Tutorial.total - Tutorial.handoff,
                opens: nil,
                lit: .words(Tutorial.names)
            ),
        ]
    }

    private var lighting: Lighting? {
        TutorialRun.lighting.first { t >= $0.from && t < $0.to }
    }

    /// How far the rest of the screen is down, nought to one.
    var spotlight: Double {
        guard let lighting else { return 0 }
        let up = (t - lighting.from) / Tutorial.dimming
        let down = (lighting.to - t) / Tutorial.dimming
        return min(1, max(0, min(up, down)))
    }

    /// Which words of the field stay lit: the name being corrected for the
    /// whole of a correction, or both names at the end of the pass.
    var lit: Tutorial.Lit { lighting?.lit ?? .none }

    /// The surface joins the word once it starts to land. They are the same
    /// word twice — the one that was changed and the offer to keep the change
    /// — and a correction is about the pair of them.
    var litSurface: Bool {
        guard let lighting, let opens = lighting.opens else { return false }
        return t >= opens
    }

    /// Which chip the pointer is on, or nil. Zero is *Yes*, and it is only lit
    /// once the offer has been up long enough to have been read.
    var clicked: Int? {
        switch phase {
        case .correcting(_, .clicking):
            return 0
        default:
            return nil
        }
    }

    /// The field, one entry per line, with the caret as a piece of the line it
    /// stands in.
    var lines: [[Piece]] {
        switch phase {
        case .idle(let number), .listening(let number), .settling(let number):
            // The fourth is dictated where the caret was left, which is on the
            // end of the third: one line, two dictations.
            return number == 4
                ? [line(Tutorial.writes[0]) + [.caret]]
                : [[.caret]]
        case .correcting(let example, let beat):
            return [correction(example, beat)]
        case .written(let number):
            // Both of the last two, on the one line: the second was dictated
            // into the end of the first.
            let written = number == 3 ? [Tutorial.writes[0]] : Tutorial.writes
            return [line(written.joined(separator: " ")) + [.caret]]
        }
    }

    /// One line of a correction: the sentence, with the caret where the
    /// keystroke happens.
    private func correction(_ example: TutorialExample, _ beat: Tutorial.Beat) -> [Piece] {
        switch beat {
        case .landed:
            // All of it, at once. Not typed: the app pastes a decode. The caret
            // is at the end of it, which is not where the correction will be.
            return words(example.written) + [.caret]
        case .placed:
            // The caret has moved into the word, to the letter it is about to
            // take out or the gap it is about to fill. This is the whole of the
            // correction being shown.
            return words(example.before)
                + [.word(example.heard, caret: example.at)]
                + words(example.after)
        case .inserted, .offering, .clicking, .saved:
            // One keystroke, and the caret is left where the person left it:
            // closed onto the letter before the hole, or past the one just
            // typed.
            return words(example.before)
                + [.word(example.term, caret: example.lands)]
                + words(example.after)
        }
    }

    /// One word, or the caret standing between two of them.
    /// One word, or the caret on a line that has no words on it.
    ///
    /// A word carries the caret itself when it has one, rather than the caret
    /// standing between two pieces: a caret given a place in the row would push
    /// the two halves of the word apart, and `Mi k` is not a word.
    enum Piece: Equatable {
        case word(String, caret: Int?)
        case caret
    }

    private func words(_ list: [String]) -> [Piece] {
        list.map { .word($0, caret: nil) }
    }

    /// A whole sentence as one line of pieces.
    private func line(_ sentence: String) -> [Piece] {
        words(sentence.split(separator: " ").map(String.init))
    }
}

/// The shimmer's own clock, one for the app.
///
/// The first screen draws this bar twice while it lifts into the corner, and a
/// clock per copy would put the highlight in a different place in each. A fixed
/// date and not `Date()`: a global set on first draw is set at whatever moment
/// the first bar appeared, so every still render caught the sweep at nought.
private let trackStarted = Date(timeIntervalSinceReferenceDate: 0)

/// How long the highlight takes to cross, and how wide it is.
private let trackSweep: TimeInterval = 2.4
private let trackBand: CGFloat = 110

/// The downloads bar: dim, and it fills.
///
/// The number is the registry's own, so the bar arrives when the models do. It
/// used to stop at nine tenths, from when the number was a fiction and arriving
/// would have been a lie. `--panels` still feeds it one and caps that itself.
///
/// It shimmers on its own clock and not the tour's. The tour's screens are
/// functions of one clock so that a dropped frame cannot leave them out of step
/// with each other; a highlight travelling over a bar has nothing to be in step
/// with.
private func progressTrack(_ progress: Double) -> some View {
    let filled = min(1, max(0, progress))
    return GeometryReader { proxy in
        TimelineView(.periodic(from: trackStarted, by: 1.0 / 30)) { context in
            let phase = context.date.timeIntervalSince(trackStarted)
                .truncatingRemainder(dividingBy: trackSweep) / trackSweep
            let width = proxy.size.width * filled
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10))
                Capsule()
                    .fill(Parrot.action.opacity(0.8))
                    .frame(width: width)
                    .overlay(alignment: .leading) {
                        LinearGradient(
                            colors: [
                                .clear, Color.white.opacity(0.45), .clear,
                            ],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: trackBand)
                        .offset(x: -trackBand + (width + trackBand) * phase)
                    }
                    .clipShape(Capsule())
            }
        }
    }
    .frame(height: 5)
}

/// How far along, in words rather than in the length of a bar.
///
/// Never a hundred. A hundred is what ends the tour, so a screen still up
/// saying it has arrived is a screen contradicting itself. Rounded down, and
/// then held one short.
private func progressPercent(_ progress: Double) -> String {
    "\(min(99, Int(min(1, max(0, progress)) * 100)))%"
}

/// The pane's own geometry, in the points the screens scale from.
///
/// Named rather than repeated, because the field inside a pane measures the room
/// its pill may move in and the two numbers have to be the same one.
private enum Pane {
    /// What one point of the design is worth on screen.
    static let scale: CGFloat = 1.25
    static let width: CGFloat = 460 * scale
    static let margin: CGFloat = 28 * scale
    /// The width a stage inside a pane is given, which is the width the pill
    /// moves in when it hangs off the caret.
    static var stage: CGFloat { width - margin * 2 }
}

/// The chrome both tour screens are built on: a title, one line saying what
/// the demonstration is about, the demonstration, and the way on.
///
/// Shared rather than copied. The two screens play one after the other, and a
/// title that sits a point lower on the second is the kind of drift that only
/// shows up when the frames are side by side.
struct TutorialScreen<Stage: View>: View {
    let title: String
    let lead: String
    /// The lead's own size and weight of colour. A caption under a title is
    /// set small and dimmed; a sentence that opens a screen is the thing being
    /// read, and is set a step larger and in the text colour.
    var leadSize: CGFloat = 13
    var leadDim = true
    /// Off for a screen that says what it has to say somewhere else — a callout
    /// over the words it is about, rather than a line under the title.
    var showsLead = true
    /// True for a screen with one thing on it, which is then centred instead
    /// of sitting under the header.
    var centresStage = false
    /// How much of the corner's own bar is drawn. 0 while the first screen has
    /// the bar in the middle of itself; 1 from the next screen on.
    var progressFade: Double = 1
    /// How far the model downloads have come, for a screen that plays while
    /// they are still coming. Nil for a screen that draws no bar at all, which
    /// is also what takes the kicker off the header.
    var progress: Double?
    /// What is being fetched right now, for the strip's own label. Nil falls
    /// back to naming the job rather than the file.
    ///
    /// It is there because the bar is not enough to watch: the speech model is
    /// a third of the download and its progress arrives a file at a time, so
    /// the number sits still for a minute. A name that changes six times is
    /// six things happening on a bar that looks stopped.
    var fetching: String?
    /// The wipe a screen opens with, or nil for a lead that is simply there.
    /// See `LeadIntro`.
    var leadIntro: LeadIntro?
    @ViewBuilder var stage: Stage

    private func at(_ points: CGFloat) -> CGFloat { points * Pane.scale }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let progress {
                bar(progress).opacity(progressFade)
                rule.opacity(progressFade)
            }

            // Nothing telling anyone how to hold the key — that instruction
            // belongs on the screen that asks them to do it — and nothing
            // explaining the lesson, because the lesson is the demonstration
            // underneath.
            Text(title)
                .font(.system(size: at(19), weight: .semibold, design: .rounded))
                .padding(.bottom, at(7))

            if showsLead { leadText }

            if centresStage { Spacer(minLength: 0) }
            stage.padding(.top, at(14))

            Spacer(minLength: at(20))
        }
        .padding(Pane.margin)
        .frame(width: Pane.width, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// The app's own mark and name: the row the setup window draws above
    /// whichever screen is under it.
    ///
    /// Drawn by the screen and not by the window because these screens are
    /// played on their own as well — `--panels names`, `--tutorial-sheet` — and
    /// a screen of this app's setup that does not say which app it is reads as
    /// somebody else's window.
    private var header: some View {
        HStack(spacing: at(8)) {
            PlumageMark(size: at(13))
            Text(AppVariant.displayName.uppercased())
                .foregroundStyle(Parrot.action)
            Spacer(minLength: 0)
            // On every frame rather than said once at the start: the tour loops
            // for as long as the fetch takes, so somebody who looks away and
            // back lands in the middle of a screen.
            if progress != nil {
                Text("WHILE YOU WAIT")
                    .foregroundStyle(Color.white.opacity(0.34))
            }
        }
        .font(.system(size: at(9), weight: .semibold, design: .rounded))
        .kerning(at(0.9))
        .padding(.bottom, at(11))
    }

    /// The downloads, under the header: a label, a track and the figure. The
    /// strip the first screen gives them is gone by here — the screens need the
    /// room — and what is left says the same thing in the corner.
    private func bar(_ progress: Double) -> some View {
        HStack(spacing: at(9)) {
            Text(fetching ?? "Downloading models")
                .font(.system(size: at(9), weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.52))
                .fixedSize()
            track(progress)
            Text(progressPercent(progress))
                .font(.system(size: at(9), weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.52))
                .monospacedDigit()
                .fixedSize()
        }
        .padding(.bottom, at(10))
    }

    /// The line between the download and the tour. What is above it is this
    /// install; what is below it is the app.
    private var rule: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 1)
            .padding(.bottom, at(14))
    }

    private func track(_ progress: Double) -> some View { progressTrack(progress) }

    /// The one line saying what the screen is about.
    @ViewBuilder private var leadText: some View {
        let text = Text(lead)
            .font(.system(size: at(leadSize)))
            .padding(.bottom, at(7))
        if let intro = leadIntro {
            // The sentence is given only its own width, and the pane's is taken
            // by the spacer. The wipe is a gradient over that width, and a
            // `Text` left free to fill the pane spreads it over the pane
            // instead: the sentence would arrive all at once and the wipe would
            // then travel across the empty space beside it.
            HStack(spacing: 0) {
                text
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(leadColour)
                    .mask(intro.wipe)
                Spacer(minLength: 0)
            }
        } else {
            text
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(leadColour)
        }
    }

    /// What the lead is set in. A caption under a title is dimmed; a sentence
    /// that opens a screen is not.
    private var leadColour: Color {
        leadDim ? Color.secondary : Color(white: 0.88)
    }
}

/// The screen the vocabulary tour plays on.
struct TutorialPane: View {
    let run: TutorialRun
    /// The downloads, for the bar under the header. See `TutorialScreen`.
    var progress: Double?
    var fetching: String?

    var body: some View {
        TutorialScreen(
            title: "ParrotFlow understands what and who you are talking about",
            lead: "",
            showsLead: false,
            progress: progress,
            fetching: fetching
        ) {
            // The same room above the composer the Slack screen keeps for its
            // channel: two screens of one walk, and a composer that sat at a
            // different height on each of them reads as two composers.
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: Chat.channel)
                TourField(
                    lines: run.lines, pill: run.pill, level: run.level,
                    clicked: run.clicked, landing: run.landing,
                    blink: run.caret,
                    lit: run.lit, litSurface: run.litSurface
                )
            }
        }
        .tourSpotlight(run.spotlight)
    }
}

/// Everything but what the screen is pointing at, taken down.
///
/// A whole sentence at full brightness reads before the one word in it that
/// changed does, and that word is what the screen is about. Both chat screens
/// use it: the vocabulary screen over each correction and over the two names it
/// ends on, the Slack screen over the link and over the mention.
///
/// The lit boxes are the views' own, reported up by the words, the surface and
/// the callout. They were numbers written down once, measured off a render, and
/// taking one line off a screen moved every one of them.
struct TourSpotlight: ViewModifier {
    /// How far the rest is down, nought to one.
    let amount: Double

    func body(content: Content) -> some View {
        content.overlayPreferenceValue(TourSpot.self) { spots in
            if amount > 0, !spots.isEmpty {
                GeometryReader { space in
                    let boxes = TourSpotlight.boxes(spots, in: space)
                    Color.black.opacity(Tutorial.dimmed * amount)
                        .mask {
                            // The dim, with the lit boxes taken out of its own
                            // alpha. A mask rather than one even-odd path: the
                            // two kinds of box want different edges, and a blur
                            // applies to a whole path at once.
                            Rectangle()
                                .fill(Color.white)
                                .overlay {
                                    ZStack {
                                        ForEach(boxes.indices, id: \.self) { at in
                                            TourSpotlight.hole(boxes[at].box, soft: boxes[at].soft)
                                                // Only the YAML focus expands between
                                                // related states. A new pop-up changes
                                                // spot ordering; animating the whole
                                                // collection moves a speech hole there.
                                                .animation(boxes[at].group == "yaml-block"
                                                    ? .easeInOut(duration: 0.5) : nil,
                                                    value: boxes[at].box)
                                        }
                                    }
                                    .compositingGroup()
                                    .blendMode(.destinationOut)
                                }
                                .compositingGroup()
                        }
                }
                .allowsHitTesting(false)
            }
        }
    }

    /// One box taken out of the dim.
    ///
    /// A word gets a soft edge and a few points of room: a rectangle round one
    /// word of a sentence reads as a box drawn on the words, and soft it reads
    /// as light. A surface gets a hard edge on its own rim, a point and a half
    /// out so a corner radius that does not match cannot dim one of its
    /// corners. Blurred, that edge only smears the edge the surface already
    /// has.
    private struct Box: Equatable {
        var box: CGRect
        let soft: Bool
        let group: String?
    }

    /// Join adjacent terms on the same line, but never bridge wrapped lines
    /// or unrelated highlighted phrases. Legacy tour spots remain unchanged.
    private static func boxes(_ spots: [TourSpot.Lit], in space: GeometryProxy) -> [Box] {
        var result: [Box] = []
        for spot in spots {
            let box = space[spot.box]
            if let group = spot.group, let index = result.lastIndex(where: {
                $0.group == group && (group == "yaml-block" || (abs($0.box.midY - box.midY) < 2
                    && box.minX >= $0.box.minX && box.minX - $0.box.maxX <= 8))
            }) {
                result[index].box = result[index].box.union(box)
            } else {
                result.append(Box(box: box, soft: spot.soft, group: spot.group))
            }
        }
        return result
    }

    static func hole(_ box: CGRect, soft: Bool) -> some View {
        let out: CGFloat = soft ? 5 : 1.5
        let down: CGFloat = soft ? 3 : 1.5
        let radius: CGFloat = soft ? 7 : PillMetrics.dockRadius + 1.5
        let lit = box.insetBy(dx: -out, dy: -down)
        return RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.black)
            .frame(width: lit.width, height: lit.height)
            .position(x: lit.midX, y: lit.midY)
            .blur(radius: soft ? 7 : 0)
    }
}

extension View {
    func tourSpotlight(_ amount: Double) -> some View {
        modifier(TourSpotlight(amount: amount))
    }
}

/// Where what is being pointed at is, reported by the views drawing it: a word
/// of the line, the surface asking about it, or the callout saying what it did.
struct TourSpot: PreferenceKey {
    /// One lit box, and how its edge is cut.
    ///
    /// A word has nothing but words around it, and a rectangle round one reads
    /// as a box drawn on the sentence; soft, it reads as light. A surface has
    /// its own drawn edge, and light spilling past that edge only blurs the
    /// edge the surface already has.
    struct Lit: Equatable {
        let box: Anchor<CGRect>
        let soft: Bool
        var group: String? = nil
    }

    static let defaultValue: [Lit] = []

    static func reduce(value: inout [Lit], nextValue: () -> [Lit]) {
        value.append(contentsOf: nextValue())
    }
}

/// The first screen of the walk: the models coming down, and nothing else.
///
/// The bar is the whole screen here rather than a strip in the corner of one,
/// because there is one thing happening and this is it. From the next screen on
/// it is small and at the top, and these screens have the room it gave up.
struct TutorialDownloadsPane: View {
    /// Seconds since the walk began.
    let elapsed: TimeInterval
    let progress: Double
    var fetching: String?

    /// Long enough to have said it and to have moved, and no longer: three
    /// seconds of a bar in the middle of the screen, and then it is out of the
    /// way and the screens have the room.
    static let length: TimeInterval = 4.6

    /// When it goes up, and how long the going takes.
    static let lifts: TimeInterval = 3.0
    static let lifting: TimeInterval = 0.7

    /// How far it has gone: 0 in the middle of the screen, 1 in the corner.
    private var lifted: Double {
        min(1, max(0, (elapsed - TutorialDownloadsPane.lifts)
            / TutorialDownloadsPane.lifting))
    }

    var body: some View {
        TutorialScreen(
            title: "",
            lead: "",
            showsLead: false,
            centresStage: true,
            progressFade: lifted,
            progress: progress,
            fetching: fetching
        ) {
            // The same bar, rising and fading as the corner's copy arrives. One
            // of them is always whole, so what the eye follows is the bar going
            // up rather than two bars swapping places.
            VStack(spacing: 16) {
                HStack(spacing: 10) {
                    Text("Downloading models")
                    Text(progressPercent(progress))
                        .monospacedDigit()
                        .foregroundStyle(Parrot.action.opacity(1 - lifted))
                }
                .font(.system(size: 21 - 6 * lifted, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(white: 0.92).opacity(1 - lifted))
                progressTrack(progress)
                    .frame(width: 300 - 60 * lifted)
                // The one place the walk says in words what it is.
                Text("This takes a few minutes. Here is what ParrotFlow does.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.secondary)
                    .opacity(1 - lifted)
            }
            .frame(maxWidth: .infinity)
            .offset(y: -26 * lifted)
            .opacity(1 - lifted)
        }
    }
}

/// The last screen of the walk: the app itself, ready.
///
/// The same thing the launch panel says once the models have landed — the key to
/// hold, and nothing else — drawn in the tour's chrome so that the walk ends
/// where the work starts. No bar: there is nothing left to wait for, which is
/// the whole of what this screen says.
struct TutorialReadyPane: View {
    /// How long the walk holds it. Long: it is the end of the walk and the
    /// start of the app, and the first thing anybody does with a finished setup
    /// window is read it and then try the key.
    static let length: TimeInterval = 45

    var body: some View {
        TutorialScreen(
            title: "Ready",
            lead: "Hold the dictation key to start dictating.",
        ) {
            hold
        }
    }

    /// The key, in the chip the launch panel draws it in.
    private var hold: some View {
        Text(Tutorial.hotkey)
            .font(.system(size: 15, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.96))
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .background(
                .white.opacity(0.14),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Parrot.action.opacity(0.6), lineWidth: 1.5)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 8)
    }
}

/// How far the screen's own lead sentence has wiped in.
///
/// Read off the pass's clock like everything else on a tour, so the intro can be
/// seeked to and a dropped frame does not skip it.
struct LeadIntro: Equatable {
    /// 0 as the text starts to arrive, 1 once all of it is there.
    var reveal: Double

    /// How wide the wipe's soft edge is, as a fraction of the sentence. A hard
    /// edge reads as a letter being revealed a pixel at a time, which is a
    /// glitch rather than writing.
    private static let edge = 0.18

    /// Nothing, then the sentence, left to right.
    ///
    /// The reveal runs past the end by its own edge, so the last letter is fully
    /// on before the wipe is done rather than half faded.
    var wipe: LinearGradient {
        let reach = reveal * (1 + LeadIntro.edge)
        return LinearGradient(
            stops: LeadIntro.stops([
                (0, .black),
                (reach - LeadIntro.edge, .black),
                (reach, .clear),
            ]),
            startPoint: .leading, endPoint: .trailing
        )
    }

    /// Clamped, and in order. Two stops at the same place is how the wipe has a
    /// hard edge at either end of its travel, which is what it wants there; out
    /// of order is not a gradient at all.
    private static func stops(_ list: [(Double, Color)]) -> [Gradient.Stop] {
        list
            .map { (min(1, max(0, $0.0)), $0.1) }
            .sorted { $0.0 < $1.0 }
            .map { Gradient.Stop(color: $0.1, location: $0.0) }
    }
}

/// The field the story is dictated into: as many lines as it holds, the caret
/// standing in one of them, and the pill hanging under it.
///
/// The pill is placed from the caret and not from the box. Both of the places
/// that matters are here: a correction happens in the middle of a line, and the
/// second of the last two dictations lands a line under the first.
private struct TourField: View {
    let lines: [[TutorialRun.Piece]]
    let pill: PillState?
    let level: Double
    let clicked: Int?
    let landing: Double
    /// How visible the caret is. See `TutorialRun.caret`.
    let blink: Double
    /// Which words say where they are, and whether the surface does. See
    /// `TourSpot`.
    var lit: Tutorial.Lit = .none
    var litSurface = false

    /// How far under the words the surface starts. A few points, so that the two
    /// are not touching, and no more than that.
    private static let margin: CGFloat = 6

    var body: some View {
        composer
            .overlay(alignment: .topLeading) {
                if let pill {
                    TourPill(
                        state: pill, level: level, clicked: clicked,
                        landing: landing,
                        // The whole stage: the surface is positioned from the
                        // caret, and the caret stands anywhere the words do.
                        reserved: NSSize(
                            width: Pane.stage, height: Tutorial.reservedPanel.height
                        ),
                        hangsAt: hang,
                        lit: litSurface
                    )
                    .offset(y: top(of: pill))
                }
            }
            // The room the surface needs past the box's own bottom edge. A
            // composer is the height a composer is and does not grow for a pill:
            // the surface floats over it, covering the actions row the way the
            // app's pill covers the document under it. This is what is left over
            // once it has, reserved at the tallest state so that nothing under
            // the box moves when the surface changes.
            .padding(.bottom, room)
    }

    /// The same composer the Slack screen is dictated into, with this screen's
    /// line in it. Its words are set a tenth smaller, so the whole chrome is
    /// built at that size rather than a Slack one with small words in it.
    private var composer: some View {
        ChatComposerFrame(size: Line.size) {
            Line(pieces: lines.first ?? [], blink: blink, lit: lit)
        }
    }

    /// Where the surface's box starts, from the top of the composer: a few
    /// points under the words, less the transparent margin the surface carries,
    /// which is taken off so that what lands there is its drawn edge.
    private func top(of state: PillState) -> CGFloat {
        Chat.firstLine(at: Line.size) + Line.height + TourField.margin
            - PillMetrics.bleed(for: state)
    }

    /// Where the caret stands in the composer, or nil when the field has none.
    private var hang: CGFloat? {
        for line in lines {
            if let x = Line.caretX(of: line) { return Chat.inset + x }
        }
        return nil
    }

    /// How much of the surface hangs past the composer's bottom edge.
    private var room: CGFloat {
        let under = (11 + 22 + 9) * Line.size / Chat.lifeSize
        return max(0, TourField.margin + Tutorial.tallestSurface - under)
    }
}

/// One line of somebody's document. Not a text field: nothing here can be typed
/// into, and pretending otherwise would only invite it.
private struct Line: View {
    let pieces: [TutorialRun.Piece]
    /// How visible the caret is.
    var blink: Double = 1
    /// Which of its words report where they are. See `TourSpot`.
    var lit: Tutorial.Lit = .none

    /// The face the words are set in, and everything measured off it.
    ///
    /// Half again the thirteen points a document is set in, and a tenth off
    /// that again. The caret and the letter beside it are the whole of what
    /// this screen shows, and at the size a document is set in neither could be
    /// read at a glance.
    ///
    /// Numbers rather than styles because the pill is positioned by measuring
    /// the line the `HStack` lays out, and the two have to agree about all of
    /// them.
    static let size: CGFloat = 19.5 * 0.9
    static let font = NSFont.systemFont(ofSize: size)
    static let gap: CGFloat = size * 5 / 13
    static let caretWidth: CGFloat = size * 1.5 / 13
    static let caretHeight: CGFloat = size * 14 / 13
    /// One line of it, which is what the caret is centred on.
    static let height: CGFloat = ceil(NSLayoutManager().defaultLineHeight(for: font))

    var body: some View {
        HStack(spacing: Line.gap) {
            ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                switch piece {
                case .word(let text, let caret):
                    word(text, caret: caret)
                        .anchorPreference(key: TourSpot.self, value: .bounds) {
                            says(text, caret: caret) ? [.init(box: $0, soft: true)] : []
                        }
                case .caret:
                    mark(at: 0)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Whether this word is one of the ones the screen is dimming round.
    ///
    /// A word is named either by carrying the caret — during a correction that
    /// is the word being corrected — or by what it says, which is how the two
    /// names are picked out of the finished line.
    private func says(_ text: String, caret: Int?) -> Bool {
        switch lit {
        case .none: return false
        case .caret: return caret != nil
        case .words(let names): return names.contains(text)
        }
    }

    /// One word, with the insertion point inside it if it carries one.
    private func word(_ text: String, caret at: Int?) -> some View {
        Text(text)
            .font(.system(size: Line.size))
            .foregroundStyle(Color(white: 0.88))
            .overlay(alignment: .topLeading) {
                if let at { mark(at: Line.caretX(in: text, at: at)) }
            }
    }

    /// The insertion point, `x` from the left of whatever it stands in.
    private func mark(at x: CGFloat) -> some View {
        Rectangle()
            .fill(Parrot.action)
            .frame(width: Line.caretWidth, height: Line.caretHeight)
            .offset(x: x, y: (Line.height - Line.caretHeight) / 2)
            .opacity(blink)
    }

    /// How far into a word the caret `index` characters in is drawn.
    static func caretX(in word: String, at index: Int) -> CGFloat {
        (String(word.prefix(index)) as NSString)
            .size(withAttributes: [.font: font]).width
    }

    /// Where the caret stands in a line, or nil when that line has none.
    static func caretX(of pieces: [TutorialRun.Piece]) -> CGFloat? {
        var x: CGFloat = 0
        for piece in pieces {
            switch piece {
            case .caret:
                return x
            case .word(let text, let caret):
                if let caret { return x + caretX(in: text, at: caret) }
                x += (text as NSString).size(withAttributes: [.font: font]).width + gap
            }
        }
        return nil
    }
}

/// The real pill, driven by the tour.
///
/// `PillView` reads a `PillModel` and the tour is a function of time with
/// nowhere to keep one, so the state is pushed in as the run changes. Pushing
/// the same state twice is not a change, which is what keeps this idempotent.
struct TourPill: View {
    let state: PillState
    let level: Double
    let clicked: Int?
    /// The state this one is growing or shrinking from, when the tour is
    /// showing the same frame morph as the live HUD.
    var morphFrom: PillState?
    /// The other end of the frame morph when the visible contents deliberately
    /// remain the source until it has finished contracting.
    var morphTo: PillState?
    /// How far that morph has travelled. One is the ordinary resting state.
    var morphProgress: Double = 1
    /// A fold contracts the whole expanded surface before replacing its
    /// contents with the compact tab. Opening uses the HUD's clipped reveal.
    var scalesMorphSource = false
    /// 0 as the tab arrives, 1 once it has settled. See `TutorialRun.landing`.
    var landing: Double = 1
    /// The box the surface is laid out in whatever state it is in, so that a
    /// state change cannot move what is above it. The vocabulary tour reserves
    /// the width of its widest surface; the slack tour reserves its own.
    var reserved: NSSize = Tutorial.reservedPanel
    /// How much light is crossing the key on the surface, or 0 for none.
    ///
    /// Hung off the pill and not placed by the tour. The surface is the one
    /// thing here whose geometry the tour does not own — it is sized by its own
    /// state and laid out in a box wider than itself — and two attempts to work
    /// out where its key was from outside put the light beside the tab.
    var sheen: Double = 0
    /// Where the caret the surface hangs off stands, in the box the surface is
    /// laid out in, or nil to leave it centred.
    var hangsAt: CGFloat?
    /// Whether the surface reports where it is drawn. See `TourSpot`.
    var lit = false

    @StateObject private var model: PillModel

    /// The state is set here rather than in `onAppear`, because an offscreen
    /// render — `--tutorial-sheet` — never runs `onAppear`, and a contact sheet
    /// of six recording pills would say nothing about any of them.
    init(
        state: PillState, level: Double, clicked: Int?, landing: Double = 1,
        morphFrom: PillState? = nil, morphTo: PillState? = nil,
        morphProgress: Double = 1,
        scalesMorphSource: Bool = false,
        reserved: NSSize = Tutorial.reservedPanel, sheen: Double = 0,
        hangsAt: CGFloat? = nil, lit: Bool = false
    ) {
        self.state = state
        self.level = level
        self.clicked = clicked
        self.landing = landing
        self.morphFrom = morphFrom
        self.morphTo = morphTo
        self.morphProgress = morphProgress
        self.scalesMorphSource = scalesMorphSource
        self.reserved = reserved
        self.sheen = sheen
        self.hangsAt = hangsAt
        self.lit = lit
        _model = StateObject(wrappedValue: {
            let model = PillModel()
            // The key is written on the offer, and the shipped default is
            // `right_command`, so the tour would otherwise tell everyone but
            // this machine to hold the wrong key.
            model.hotkey = Tutorial.hotkey
            // Attached to the line, which is where this pill is: the bird's own
            // tab while it listens, square along the top where it meets the
            // words. Free, it hangs off nothing and shows the icon instead,
            // which is a different surface.
            model.docked = .below
            // The icon is set and not drawn. `docked` is what decides whether it
            // appears — an attached pill says where the words are going by being
            // attached — but the meter asks a different question: an empty icon
            // slot is what makes it draw `blind`, the grey bird it uses when the
            // words have nowhere to land, and the tour is showing words landing.
            model.appIcon = TourPill.destinationIcon
            model.state = state
            model.level = Float(level)
            model.selected = clicked
            return model
        }())
    }

    var body: some View {
        PillView()
            .environmentObject(model)
            .frame(width: drawnSize.width, height: drawnSize.height)
            // Where the drawn surface is: this frame, less the transparent
            // margin the bloom is carried in. On the surface's own frame and
            // not on the reserved box below — the box is the whole stage, and
            // reported from there this said the composer was the surface.
            .overlay {
                if lit {
                    // Reported before the padding, not after: the bounds of a
                    // padded view are the padded ones, so the other way round
                    // this named the frame and left a bleed of undimmed screen
                    // round the surface.
                    Color.clear
                        .anchorPreference(key: TourSpot.self, value: .bounds) {
                            [.init(box: $0, soft: false)]
                        }
                        .padding(PillMetrics.bleed(for: state))
                }
            }
            // The live HUD folds its AppKit window around the same surface.
            // Here there is no window, so scale that source surface into the
            // interpolated frame before replacing it with the compact tab.
            .scaleEffect(
                x: size.width / max(1, drawnSize.width),
                y: size.height / max(1, drawnSize.height),
                anchor: .topLeading
            )
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            // The reserved box, top-aligned so the surface keeps hanging off the
            // line where it did when it was smaller.
            .frame(
                width: reserved.width,
                height: reserved.height,
                alignment: .top
            )
            // The landing: down from the line, growing into its box. Anchored
            // at the top because that is the edge touching the words, and the
            // one that must not appear to move.
            .scaleEffect(0.9 + 0.1 * landing, anchor: .top)
            .offset(y: -8 * (1 - landing))
            .offset(x: hang)
            .opacity(landing)
            .overlay(alignment: .topLeading) { keySheen }
            .onChange(of: state) { _, _ in apply() }
            .onChange(of: morphProgress) { _, _ in apply() }
            .onChange(of: level) { _, _ in apply() }
            .onChange(of: clicked) { _, _ in apply() }
    }

    /// How far the surface is moved to hang off the caret.
    ///
    /// The surface is laid out centred in a box wider than itself, so the
    /// offset is the caret the tour measured, less the surface's own
    /// transparent margin, less the half of the box the surface would otherwise
    /// sit in. Clamped so the *drawn* surface stays inside the box, which is
    /// what the app does with the screen when the words being corrected are
    /// near its edge. A caret at the start of a line therefore puts the surface
    /// at the box's left edge, and not half a box further in.
    private var hang: CGFloat {
        guard let hangsAt else { return 0 }
        let margin = PillMetrics.bleed(for: state)
        let boxed = (reserved.width - size.width) / 2
        let wanted = hangsAt - margin - boxed
        let low = -boxed - margin
        let high = reserved.width - size.width + margin - boxed
        return min(max(low, wanted), max(low, high))
    }

    /// A band of light crossing the key, inside the surface's own margins.
    ///
    /// The key is drawn in the right third of the tab, and the tab is about
    /// three times as wide as it is tall — measured off the render at 0.66 and
    /// 0.26 of the surface.
    ///
    /// The surface is measured from its own frame but laid out in the reserved
    /// box, which is wider than it and centres it: a band placed from the
    /// surface's numbers alone lands left of the tab by half the difference,
    /// which is where it was for three attempts.
    @ViewBuilder private var keySheen: some View {
        if sheen > 0 {
            let inset = PillMetrics.bleed(for: state)
            let across = size.width - inset * 2
            let down = size.height - inset * 2
            let boxed = (reserved.width - size.width) / 2
            let wide = across * 0.4
            let tall = down * 0.46
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .clear, location: max(0, sheen - 0.5)),
                            .init(
                                color: Color.white.opacity(0.68),
                                location: sheen
                            ),
                            .init(color: .clear, location: min(1, sheen + 0.5)),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .frame(width: wide, height: tall)
                .offset(
                    x: boxed + inset + across * 0.66 - wide / 2,
                    y: inset + (down - tall) / 2
                )
        }
    }

    private var size: NSSize {
        let target = PillMetrics.panelSize(
            for: morphTo ?? state, hasIcon: model.appIcon != nil, hotkey: model.hotkey,
            dock: model.docked
        )
        guard let morphFrom else { return target }
        let source = PillMetrics.panelSize(
            for: morphFrom, hasIcon: model.appIcon != nil, hotkey: model.hotkey,
            dock: model.docked
        )
        let progress = CGFloat(min(1, max(0, morphProgress)))
        return NSSize(
            width: source.width + (target.width - source.width) * progress,
            height: source.height + (target.height - source.height) * progress
        )
    }

    private var drawnSize: NSSize {
        guard scalesMorphSource else { return size }
        return PillMetrics.panelSize(
            for: state, hasIcon: model.appIcon != nil, hotkey: model.hotkey,
            dock: model.docked
        )
    }

    private func apply() {
        model.level = Float(level)
        model.selected = clicked
        if model.state != state { model.state = state }
    }

    /// Something recognisable for the icon slot, and deliberately not this app.
    ///
    /// Mail, because that is the window the `email` transform was written for
    /// and every Mac has it. `NSImage(contentsOf:)` on an `.app` URL does not
    /// load its icon — it returns nil — and the fallback used to be
    /// `NSImage.applicationIconName`, which is *this* app's icon: the pill drew
    /// the meter's parrot with ParrotFlow's parrot beside it.
    private static let destinationIcon: NSImage? = {
        for bundle in ["com.apple.mail", "com.apple.finder"] {
            guard let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundle
            ) else { continue }
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }()
}
