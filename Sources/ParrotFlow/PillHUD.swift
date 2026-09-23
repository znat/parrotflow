import AppKit
import Combine
import SwiftUI

/// What a notice is telling you. Carried as a colour, because the notice is
/// read in half a second out of the corner of an eye, in the middle of typing
/// into something else — long enough for a colour, not for a sentence.
enum NoticeTone: Equatable {
    /// Something happened, and it worked.
    case done
    /// Nothing broke, but nothing happened either, and you may want to know why.
    case caution
    /// It failed.
    case failure
    /// Working, for as long as it takes.
    case thinking
    /// Plain news.
    case plain

    var color: Color {
        switch self {
        case .done: return Parrot.leaf
        case .caution: return Parrot.amber
        case .failure: return Parrot.scarlet
        case .thinking, .plain: return Parrot.sky
        }
    }
}

/// What the pill is saying right now.
///
/// One enum rather than one panel each, because these are the same object at
/// different moments of the same dictation. The recording pill used to be an
/// `NSPanel` and the notice another, both borderless, both 46pt tall, both
/// centred on the same point 96pt off the bottom of the screen — so releasing
/// the hotkey destroyed one window and built another in its place, at more
/// than twice the width, with a different entrance. That reads as two unrelated
/// things happening, which is exactly what it was.
///
/// The level and the app icon are deliberately *not* in here. The meter is fed
/// about ten times a second and the icon is decided once at the press; putting
/// either in the state would make every meter frame a state change, and every
/// state change animates.
enum PillState: Equatable {
    /// The mic is hot. Width depends on whether there is an app icon to show.
    ///
    /// The label is what this recording is *for*, and it is nil for the one
    /// that needs no explaining: dictation. Tap-then-hold sets it, because a
    /// hold that routes what you say instead of writing it down looks exactly
    /// like one that writes it down, and the difference has to be readable
    /// before you speak rather than after.
    case recording(String?)
    /// Work of no predictable length — decoding, a prompt, a download.
    case working(String)
    /// A sentence, for a few seconds.
    case notice(String, NoticeTone)
    /// Why something could not run, as markdown, with a bar draining over it.
    /// The one message state that takes the mouse.
    case alert(String, NoticeTone)
    /// What you can do about what just happened. One entry per command; which
    /// one the pointer is on lives in the model, not here, so moving the
    /// highlight is not a state change and does not crossfade the whole pill.
    ///
    /// The headline says either where the words went or which words they are —
    /// see `Headline`. Nil for an offer that needs neither.
    ///
    /// The reading is what the decoder made of the dictation — the sentence
    /// word by word, its score for the whole utterance, and a warning when it
    /// is worth a second look. An empty one is the whole difference: it is what
    /// decides the pill's height, so nothing about this state changes shape for
    /// a dictation that went fine.
    ///
    /// `open` is the whole of the two-stage offer. Closed, the surface is a
    /// Compact tab hanging off the line: the voice mark and key, and nothing else.
    /// Open, it is everything above. The payload is carried either way, so
    /// opening is a morph of a surface that is already there rather than a
    /// second one being built — and closing again loses nothing.
    ///
    /// One case rather than two, for that reason. A separate `.tab` state would
    /// have to carry the same three values to be able to open into this one,
    /// and every switch in the file would have to handle both.
    case offer([OfferedCommand], Headline?, Confidence.Reading, open: Bool)

}

/// What an offer says above its chips.
///
/// Two things, and they are opposite enough to be worth telling apart in the
/// type. A landing is about the *ending* — the words went somewhere you did not
/// ask for, and you have to know that before the chips mean anything. A
/// selection is about the *subject*, and it is drawn as the words themselves in
/// the highlight they wear in the field, because the one question an offer over
/// a selection has to answer is which words, and no description of them is as
/// exact as showing them.
///
/// They are also measured differently — a landing widens the chip row it sits
/// in front of, a selection is a row of its own — which is the other half of
/// why one `String?` could not carry both.
enum Headline: Equatable {
    /// "Nowhere to type · ⌘V", and the rest of the endings nobody asked for.
    case landing(String)
    /// The words this offer is about, shown as the field shows them.
    case selection(String)
    /// A word the app could learn, in the sentence you said it in.
    case learn(Learn)
    /// The places in what was just said that the vocabulary step could not
    /// settle, each with its two options.
    case choose(Choose)

    /// Whether this is the three-row shape: the words, the chips, and the line
    /// about the key. Read by the metrics and by the view, so the two cannot
    /// disagree about which shape they are describing.
    var isSelection: Bool {
        if case .selection = self { return true }
        return false
    }

    /// Whether the headline is a row of its own rather than something that
    /// widens the chip row. Two are, measured and ruled off alike.
    var ownsARow: Bool {
        switch self {
        case .landing: return false
        case .selection, .learn, .choose: return true
        }
    }
}

/// A correction the app could keep, as the pill asks about it.
///
/// The sentence and not the pair: a rule is kept with the sentence it was said
/// in, which later decides whether the term belongs elsewhere. Four pieces and
/// not a built string, because the pill dims everything that did not change.
struct Learn: Equatable {
    /// What it would be learned as, and what replaced `heard` in the sentence.
    let term: String
    /// What the decoder wrote there.
    let heard: String
    /// The sentence before and after the change, already trimmed.
    let before: String
    let after: String

    /// The lead and the space after it, which is nothing when the change is
    /// the first word of its sentence. Most changes are, now that the window
    /// stops at the sentence.
    var lead: String { before.isEmpty ? "" : before + " " }

    /// For the log only. The view draws the pieces; they are not one face.
    var line: String {
        "\(PillMetrics.learnLead) “\(lead)\(heard) \(term)\(after)”"
    }
}

/// One place the vocabulary step could not settle, in the sentence it is in.
///
/// The sentence is written once and only the choice is stacked: the two options
/// stand one above the other where the words go, and the prose runs through the
/// middle of the stack. One question, so nothing is marked — the click is the
/// answer.
///
/// One place per pill. A sentence with several open places is several
/// questions; `ChooseRun` puts them in order.
struct Choose: Equatable {
    /// The prose before the place. A leading "…" when the window cut it.
    let before: String
    /// Every reading of the place, what the stage left in the string first.
    ///
    /// Two of them almost always: what was heard and the one word that could
    /// not be ruled out. A place where several terms share the sound carries
    /// one row per member — see `SoundGroup`.
    let options: [String]
    /// The prose after the place. A trailing "…" when the window cut it.
    let after: String
    /// Which question this is, and how many there are.
    let step: Int
    let steps: Int

    /// Beside the lead, and only when the pill is coming back. Nothing else on
    /// the surface says an answer is not the end of it.
    var count: String? { steps > 1 ? "\(step) of \(steps)" : nil }

    /// What stands in the string, which is the row nobody has to click.
    var heard: String { options.first ?? "" }

    /// For the log only. The view draws the pieces.
    var line: String {
        "\(PillMetrics.chooseLead) “\(before) [\(options.joined(separator: "|"))] \(after)”"
    }

    /// The sentence cut to a window around the place.
    ///
    /// `at` and `span` are word indices into `words`. An ellipsis is written
    /// only where words were dropped.
    static func windowed(
        words: [String], at: Int, span: Int, others: [String],
        step: Int = 1, steps: Int = 1, window: Int = AppDelegate.learnWindow
    ) -> Choose {
        func run(_ range: Range<Int>) -> [String] {
            let low = max(0, min(words.count, range.lowerBound))
            let high = max(low, min(words.count, range.upperBound))
            return Array(words[low ..< high])
        }
        let head = run(0 ..< at)
        let tail = run((at + span) ..< words.count)
        return Choose(
            before: head.count > window
                ? "… " + head.suffix(window).joined(separator: " ")
                : head.joined(separator: " "),
            options: [run(at ..< (at + span)).joined(separator: " ")] + others
                + [PillMetrics.chooseElsewhere],
            after: tail.prefix(window).joined(separator: " ")
                + (tail.count > window ? " …" : ""),
            step: step, steps: steps
        )
    }

    /// The same, with the window narrowed until the row fits the pill.
    ///
    /// The row is drawn on one line at its natural width, so a window too wide
    /// hangs the end of the sentence over the end of the panel. Down to one word
    /// either side; past that the place itself is what is too wide, and
    /// `.lineLimit(1)` truncates.
    static func fitted(
        words: [String], at: Int, span: Int, others: [String],
        step: Int = 1, steps: Int = 1, window: Int = AppDelegate.learnWindow
    ) -> Choose {
        var size = window
        var kept = windowed(words: words, at: at, span: span, others: others,
                            step: step, steps: steps, window: size)
        while size > 1, !PillMetrics.chooseFits(kept) {
            size -= 1
            kept = windowed(words: words, at: at, span: span, others: others,
                            step: step, steps: steps, window: size)
        }
        return kept
    }
}

/// The open places of one sentence, asked one at a time.
///
/// One question per pill. The answer is written into the words before the next
/// is asked, so each question shows the sentence as it stands, and the last
/// answer leaves the sentence to type.
///
/// Escape is option 0: it keeps what was heard, for this place and every place
/// after it. Nothing taps keys for this yet.
struct ChooseRun {
    /// Where a place is, in words, and what it could be instead.
    struct Place: Equatable {
        /// Moves when an earlier answer writes a different number of words.
        var at: Int
        let span: Int
        /// The readings beside what was heard, in the order they are offered.
        let others: [String]
    }

    private(set) var words: [String]
    private(set) var places: [Place]
    private(set) var answered = 0

    init(sentence: String, places: [Place]) {
        self.words = sentence.split(separator: " ").map(String.init)
        self.places = places.sorted { $0.at < $1.at }
    }

    /// The question to put on the pill, or nil once every place is answered.
    var next: Choose? {
        guard answered < places.count else { return nil }
        let place = places[answered]
        return .fitted(
            words: words, at: place.at, span: place.span, others: place.others,
            step: answered + 1, steps: places.count
        )
    }

    /// The sentence as it stands, which after the last answer is what to type.
    var sentence: String { words.joined(separator: " ") }

    /// Take an answer: 0 keeps what was heard, anything else writes that
    /// reading.
    mutating func answer(_ option: Int) {
        guard answered < places.count else { return }
        let place = places[answered]
        answered += 1
        guard option > 0, option <= place.others.count,
              place.at >= 0, place.at + place.span <= words.count
        else { return }
        let written = place.others[option - 1].split(separator: " ").map(String.init)
        words.replaceSubrange(place.at ..< (place.at + place.span), with: written)
        let shift = written.count - place.span
        guard shift != 0 else { return }
        for index in answered ..< places.count { places[index].at += shift }
    }
}

/// A command on the offer, and the letter that runs it.
///
/// The letter is drawn as a key rather than as an icon. An icon says what a
/// command is about; a key says you can press it, which is the more useful
/// thing on a surface that is up for a few seconds.
struct OfferedCommand: Equatable {
    let title: String
    /// Empty when the config named none. The chip is still there and still
    /// clickable.
    let key: String
}

/// Which way a docked surface hangs off its line of text.
enum Dock {
    /// Under the line, which is where it goes when there is room.
    case below
    /// Over it, for the last line of a full window.
    case above
    /// Nowhere to attach to, so nothing to point at: an offer for an app that
    /// would not say where its caret is, sitting at the bottom of the screen.
    ///
    /// Still the offer's surface — tinted, rimless, the small margin — and
    /// rounded on all four corners, because a square edge is a claim about
    /// which line this is about and there is no line to claim.
    case free
}

final class PillModel: ObservableObject {
    @Published var state: PillState = .recording(nil)
    /// The effective `feedback.primary_color`, refreshed with config.yaml.
    @Published var primaryColor = ContextIdentity.defaultPrimary
    /// The effective `feedback.theme`, refreshed with config.yaml.
    @Published var theme: ContextAppearance = .system

    /// Whether the panel is on screen. False unmounts the surface.
    ///
    /// An ordered-out panel still commits its layers. The rim's angle animates
    /// a conic gradient, which is rasterised on the CPU every frame — so an
    /// offer left mounted under a hidden panel measured at 57% of a core with
    /// nothing on screen. The state does not stop it: nothing clears `state`
    /// on the way out, and `.offer` means a rim that turns.
    @Published var onScreen = true

    /// Which way the surface on screen is hanging.
    ///
    /// Published rather than worked out in the view, because only `beside` knows
    /// it: the choice is made from how much room is left under the line, which
    /// is a question about the screen and not about the state.
    /// `.free` until the first placement: the surface has one form, and the dock
    /// says which edge of it touches the line.
    @Published var docked: Dock = .free

    @Published var level: Float = 0
    @Published var elapsed: TimeInterval = 0
    /// The icon of the app the text is going to land in — the one an `app:`
    /// condition will be matched against.
    ///
    /// Nil when nothing was in front, when the app has no icon, and when there
    /// was nothing in it to type into: the icon is a promise about where the
    /// words are going, and a window with no caret in it is not somewhere they
    /// can go. See `Destination`.
    @Published var appIcon: NSImage?

    /// The hotkey as it is written on screen — "Right ⌘", "⌃⌥Space".
    ///
    /// The selection offer tells you to hold it, and the key is configurable,
    /// so the glyph cannot be a literal. It was `⌥` here while the shipped
    /// default is `right_command`, which told everyone but this machine to hold
    /// the wrong key.
    ///
    /// Here rather than in the state, for the reason the icon is: it changes
    /// when the config is read, not when the pill changes what it is saying,
    /// and a state change crossfades the whole surface.
    @Published var hotkey: String = ""

    /// The spelling on screen, which is never the long one and never absent.
    ///
    /// "Right ⌘" was drawn in full and collapsed to "R ⌘" after five
    /// seconds, and then to nothing after three. Both stages were answers to a
    /// width problem the initial had already solved: "R" and a glyph is about
    /// 24pt, which is not worth timing away — and a tab that shrinks while you
    /// are looking at it is the thing that made two sizes wrong to begin with.
    ///
    /// Read by the view and by the metrics, so the tab is never sized for one
    /// spelling and drawn with another.
    var shownHotkey: String { PillMetrics.shortHotkey(hotkey) }

    /// Which command the pointer is on, if any.
    ///
    /// Nil when it is on none, which is how the offer arrives. This is only
    /// ever the pointer's mark and it does not outlive the pointer — leaving
    /// the pill clears it. Nothing runs without a click, so a chip lit before
    /// you have touched anything is saying something about a command that is
    /// not about to happen.
    @Published var selected: Int?

    /// Clicking a command, clicking the tab, and the pointer coming and going.
    /// Closures rather than published state: they are messages out of the view,
    /// and nothing about them should redraw it.
    ///
    /// On a selector the index is the option: 0 keeps what was heard, and the
    /// rest are the readings under it, in the order they are drawn. There is
    /// one place on the pill, so a click is the whole answer — whoever raised
    /// it asks the next question, if there is one.
    var onPick: ((Int) -> Void)?
    var onHover: ((Bool) -> Void)?
    /// The pointer on an alert, and its close cross. Their own hooks, so an
    /// alert and an offer cannot take each other's closure.
    var onAlertHover: ((Bool) -> Void)?
    var onAlertClose: (() -> Void)?

    /// How much of the alert's clock is left, 1 down to 0. Published, because
    /// a `withAnimation` over 15s does not give the value back.
    @Published var alertRemaining: CGFloat = 1
    /// The open panel folded back to the tab on its own.
    ///
    /// The offer is still on screen and still live afterwards, so whoever armed
    /// it has to put the clock and the letters back the way they are for a tab.
    var onFold: (() -> Void)?

    /// A click on the collapsed tab.
    ///
    /// Its own way in rather than leaning on the hover that precedes it. A
    /// click is a deliberate answer and a hover is a maybe, so the click skips
    /// the dwell — and the two say different things about whether the pointer
    /// leaving should fold it back again.
    var onTab: (() -> Void)?
}

/// The one floating surface a dictation ever puts on screen.
///
/// It arrives once, changes shape as the dictation moves through its states,
/// and leaves once. Nothing in the middle is a new window: the panel keeps its
/// identity, animates its width, and crossfades what is written on it — so the
/// plumage rim never blinks, which is what made the old hand-off read as a
/// glitch on top of whatever you were reading.
final class PillHUD {

    let model = PillModel()

    private var panel: NSPanel?
    /// Armed by `hide()`, cancelled by the next `set()`. See `hide()`.
    private var pendingHide: DispatchWorkItem?
    /// Armed by a `set()` that carries a duration.
    private var pendingDismiss: DispatchWorkItem?
    private var isFading = false
    /// Waiting to fold on a deadline. Only the open offer does this — see
    /// `fold(after:)`.
    private var foldIsPending = false
    /// How long the offer on screen was given, so the pointer can give it again.
    private var offerFor: TimeInterval?
    /// Which deadline is the live one.
    ///
    /// A flag alone cannot distinguish a cancelled deadline from the new one
    /// that replaced it, so the handler checks this number as well. A stale
    /// deadline does nothing.
    private var foldRun = 0
    /// The open offer's pending fold. See `fold(after:)`.
    private var pendingFold: DispatchWorkItem?
    /// The alert's countdown: the clock, the whole of it, when it runs out,
    /// and what is left while the pointer holds it.
    private var alertClock: Timer?
    private var alertTotal: TimeInterval = 0
    private var alertEndsAt: Date?
    private var alertLeft: TimeInterval = 0

    /// The margin this surface wants, which is not the same in every state.
    /// See `PillMetrics.bleed(for:)`.
    private var currentBleed: CGFloat { PillMetrics.bleed(for: model.state) }

    /// Where this dictation's words are going, set at the press by `aim(at:)`.
    /// Every state reads it while the pill is up, and `fadeOut` clears it, so
    /// one dictation never inherits the aim of the last.
    private var near: CaretAnchor.Found?

    /// The window the state on screen asks for, bleed included.
    ///
    /// The one answer to "how big is this pill", so nothing has to ask the
    /// window — which in the middle of a morph is a width on its way somewhere
    /// rather than a width anything chose.
    private var wantedSize: NSSize {
        PillMetrics.panelSize(
            for: model.state, hasIcon: model.appIcon != nil, hotkey: model.shownHotkey,
            dock: wantedDock
        )
    }

    /// Which way the surface will hang, known before it is placed.
    ///
    /// The size is worked out first and `anchor` decides the dock after, so
    /// this has to answer the same question early. It can: the anchor is read
    /// at the press, and a dictation with none is the one that lands free.
    /// Below and above are the same width, so the two attached cases are one
    /// answer here.
    private var wantedDock: Dock { near == nil ? .free : .below }

    /// One number for the whole surface: the rise, the morph and the fade.
    ///
    /// The panel frame animates in AppKit and the words crossfade in SwiftUI,
    /// which are two animations that have to look like one. They are only ever
    /// going to agree if they read the same constant.
    static let motion: TimeInterval = 0.18

    // MARK: - The states

    func recording(icon: NSImage?, label: String? = nil) {
        model.elapsed = 0
        model.level = 0
        model.appIcon = icon
        set(.recording(label))
    }

    /// Stays up until something replaces it or `hide()` is called.
    ///
    /// A `duration` was tried here and lost: it is a bet on how long the work
    /// will take, and "Thinking…" dismissed itself while a cold Ollama was
    /// still loading the model — leaving the rest of a 10s wait looking like
    /// the app had gone back to doing nothing.
    func working(_ message: String) {
        set(.working(message))
    }

    /// A `duration` of nil leaves the message up until `hide()`.
    func notice(_ message: String, tone: NoticeTone = .plain, duration: TimeInterval? = 3.5) {
        set(.notice(message, tone), for: duration)
    }

    /// Several lines about something that could not run, as markdown. A
    /// `duration` of nil leaves it up until `hide()`, with no bar.
    func alert(_ markdown: String, tone: NoticeTone = .failure, for duration: TimeInterval?) {
        model.alertRemaining = 1
        set(.alert(markdown, tone), for: duration)
        guard let duration, duration > 0 else { return }
        alertTotal = duration
        startAlertClock(from: duration)
    }

    /// Hold the alert, or let it run out again. Pause, not reset: the
    /// dismissal is rearmed with what was left.
    private func alertHovering(_ inside: Bool) {
        guard let panel, panel.isVisible, case .alert = model.state, alertTotal > 0 else { return }
        if inside {
            guard let ends = alertEndsAt else { return }
            alertClock?.invalidate(); alertClock = nil
            pendingDismiss?.cancel(); pendingDismiss = nil
            alertLeft = max(0, ends.timeIntervalSinceNow)
            alertEndsAt = nil
            // SwiftUI's onHover can miss the exit. Ask the pointer instead.
            alertClock = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) {
                [weak self] timer in
                guard let self, self.alertEndsAt == nil, case .alert = self.model.state
                else { timer.invalidate(); return }
                if !self.pointerIsOver { self.alertHovering(false) }
            }
        } else {
            guard alertEndsAt == nil else { return }
            startAlertClock(from: alertLeft)
        }
    }

    /// Run the bar down over `seconds`, and take the pill away at the end.
    private func startAlertClock(from seconds: TimeInterval) {
        alertLeft = seconds
        alertEndsAt = Date().addingTimeInterval(seconds)
        model.alertRemaining = CGFloat(min(1, seconds / max(alertTotal, 0.001)))

        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        pendingDismiss?.cancel()
        pendingDismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)

        alertClock?.invalidate()
        alertClock = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) {
            [weak self] timer in
            guard let self, let ends = self.alertEndsAt, self.alertTotal > 0 else {
                timer.invalidate()
                return
            }
            self.model.alertRemaining =
                CGFloat(max(0, ends.timeIntervalSinceNow) / self.alertTotal)
        }
    }

    /// The close cross: take it away now rather than at the end of the clock.
    private func closeAlert() {
        guard case .alert = model.state else { return }
        Log.write("alert: closed by the cross")
        pendingDismiss?.cancel(); pendingDismiss = nil
        stopAlertClock()
        fadeOut()
    }

    /// Nothing is counting any more.
    private func stopAlertClock() {
        alertClock?.invalidate(); alertClock = nil
        alertEndsAt = nil
        alertTotal = 0
        alertLeft = 0
    }

    /// What you can do about the text that just landed, and for how long.
    ///
    /// The highlight is cleared first. It belonged to the last offer's pointer,
    /// and the pointer is not on this one yet.
    ///
    /// This is the one state that folds down instead of leaving. It stands at
    /// full strength for the whole deadline, then the same surface contracts
    /// into its compact tab. The tab stays live, so the commands remain one
    /// key or click away without leaving a faded ghost over the document.
    /// `open` is false for every ordinary dictation: the offer arrives as a tab
    /// and is opened by the pointer or by the key. It is true for the one that
    /// cannot wait to be asked for — see `AppDelegate.showCorrectOffer`.
    func offer(
        _ commands: [OfferedCommand], headline: Headline? = nil,
        reading: Confidence.Reading = Confidence.Reading(),
        open: Bool = false, for duration: TimeInterval
    ) {
        model.selected = nil
        offerFor = duration
        openedByPointer = false
        set(.offer(commands, headline, reading, open: open))
        // A tab does not run out. It is 33x23 of your document and it costs
        // nothing to leave there, unlike the panel it opens into — so it waits
        // for you to act rather than for a clock: a click, a keystroke, the
        // next dictation. Only the open panel has a fold deadline.
        if open { fold(after: duration) }
    }

    /// Unfold the tab, or fold it back.
    ///
    /// A state change and not a resize, so the words crossfade in over the same
    /// 180 ms the window takes to grow, and the corners square up with them.
    /// The payload rides through untouched: what opens is the surface already
    /// on screen, holding what it has held since the words landed.
    ///
    /// `set` clears the old deadline on its way through, so the clock is
    /// started again here unless the pointer is on it, which is the one thing
    /// that means you are still deciding.
    func open(_ wanted: Bool, byPointer: Bool = false) {
        guard case .offer(let commands, let headline, let reading, let was) = model.state,
              was != wanted else { return }
        if wanted { openedByPointer = byPointer } else { openedByPointer = false }
        Log.write("pill: the offer \(wanted ? "opened" : "folded")\(byPointer ? ", by the pointer" : "")")
        set(.offer(commands, headline, reading, open: wanted))
        if !wanted {
            // The pointer's mark belonged to a chip that is no longer drawn.
            model.selected = nil
            model.onFold?()
        }
        guard wanted, let offerFor, !pointerHolds else { return }
        fold(after: offerFor)
    }

    /// Whether what is on screen is an offer, and whether it is unfolded.
    var isOpen: Bool { offerIsOpen }
    private var offerIsOpen: Bool {
        if case .offer(_, _, _, let open) = model.state { return open }
        return false
    }
    private var isOfferState: Bool {
        if case .offer = model.state { return true }
        return false
    }

    /// True when the pointer is what unfolded it, so the pointer leaving folds
    /// it back. An offer that arrived open, or was opened by the key, stays
    /// open — you asked for it, and the pointer wandering off is not a retraction.
    private var openedByPointer = false
    /// Waiting out `PillMetrics.tabDwell`.
    private var pendingOpen: DispatchWorkItem?
    /// Whether the pointer is holding the offer open.
    ///
    /// Kept rather than read off `foldIsPending`, because unfolding the tab is a
    /// state change and `set` clears that flag — so the pointer leaving
    /// afterwards would find no fold deadline to restart and the offer would stand
    /// there for good.
    private var pointerHolds = false

    /// Keep the expanded offer readable for its whole lifetime, then contract
    /// it into the compact tab. `open(false)` performs the actual 180ms frame
    /// morph, so the surface, hard shadow and contents finish as the same live
    /// object the user can reopen.
    private func fold(after duration: TimeInterval) {
        guard let panel else { return }
        pendingDismiss?.cancel(); pendingDismiss = nil
        pendingFold?.cancel(); pendingFold = nil
        isFading = false
        foldIsPending = true
        foldRun += 1
        let run = foldRun

        if !panel.isVisible {
            model.onScreen = true
            panel.orderFrontRegardless()
        }
        panel.alphaValue = 1

        let deadline = DispatchWorkItem { [weak self] in
            guard let self, self.foldIsPending, self.foldRun == run else { return }
            self.pendingFold = nil
            self.foldIsPending = false
            if self.offerIsOpen { self.open(false) }
        }
        pendingFold = deadline
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0, duration), execute: deadline
        )
    }

    /// Hold the offer open, or give it a fresh fold deadline.
    ///
    /// The pointer resting on the pill is the least ambiguous statement there
    /// is that you are still deciding, so the deadline stops entirely and
    /// starts again from the beginning when the pointer leaves.
    func hovering(_ inside: Bool) {
        let held = pointerHolds
        pointerHolds = inside

        // The pointer no longer opens it, and used to after a dwell. A tab that
        // opens when the pointer crosses it cannot also stay on screen: it sits
        // under the line you were just typing on, which is the line you reach
        // across all day, so a tab that lives until you act would spend that
        // life springing open at a pointer on its way somewhere else.
        //
        // One or the other, and staying is worth more. The key is the way in
        // now, and the tab draws it.

        // `isVisible` as well as the flag: a panel taken down by another action
        // must not be brought back by a late pointer event.
        //
        // `held` as well as `foldIsPending`: see `pointerHolds`.
        guard let panel, panel.isVisible, let offerFor, foldIsPending || inside || held
        else { return }
        if inside {
            // Stop the deadline while the pointer is making a decision.
            foldRun += 1
            pendingFold?.cancel(); pendingFold = nil
            foldIsPending = true
            panel.alphaValue = 1
        } else {
            fold(after: offerFor)
        }
    }

    /// How long the expanded offer stays readable before folding to its tab.
    static let offerLife: TimeInterval = 6

    /// The pill's own visible capsule right now — what a click has to land
    /// inside of to count as a click on the pill rather than a click past it.
    /// Nil while there is no pill up, so a caller cannot mistake the frame it
    /// was last shown at for one it is still shown at.
    ///
    /// `panel.frame` inset by its small drawing margin, not `panel.frame`
    /// itself. That margin is transparent, and the pill often sits beside the
    /// words you are about to click into, so it must not count as part of the
    /// pill's hit target.
    var frame: NSRect? {
        guard let panel, panel.isVisible else { return nil }
        return panel.frame.insetBy(dx: currentBleed, dy: currentBleed)
    }

    /// Whether the pointer is over the pill at this instant.
    ///
    /// Asked, rather than remembered from the last `hovering(_:)`. A hover that
    /// arrives can be believed; a hover that never leaves cannot. A Space
    /// change, Mission Control or a window ordered out from underneath the
    /// pointer can all swallow the exit, and whoever is holding the offer open
    /// on the strength of that hover would hold it — and the keys it takes —
    /// until the next dictation.
    var pointerIsOver: Bool {
        guard let panel, panel.isVisible else { return false }
        return panel.frame.contains(NSEvent.mouseLocation)
    }

    /// Point the pill at where the words are going, for this dictation.
    ///
    /// Set at the press and read by every state until the pill goes away: the
    /// recording, the transcribing, and the offer all appear in the same place,
    /// so nothing moves while you are watching it. Nil puts it back at the
    /// bottom of the screen, which is where it opened before any of this.
    ///
    /// Set a second time only for an app that gave no caret to aim at. There
    /// the words are found after they land, so the pill is already up and this
    /// moves it. One move to somewhere right beats staying somewhere wrong.
    ///
    /// Never re-read on its own, deliberately. Scroll the window or move focus
    /// while you are talking and the anchor is stale — but you moved, and a
    /// pill that stayed where the dictation started is easier to explain than
    /// one that jumps halfway through. The caller aims it again only when it
    /// has a better answer than the one it opened with.
    func aim(at anchor: CaretAnchor.Found?) {
        near = anchor
        guard let anchor else { return }
        Log.write(String(
            format: "pill: %@ at %.0f,%.0f %.0fx%.0f",
            anchor.source.rawValue,
            anchor.rect.minX, anchor.rect.minY, anchor.rect.width, anchor.rect.height
        ))
        // Already up: move it there, with the animation it uses for everything
        // else. An app with no caret has no anchor at the press, so the only
        // one it will ever get arrives after the words land — which is after
        // the pill is on screen. Without this the answer would be found and
        // never used.
        //
        // The size comes from the state, not from `panel.frame`. That is the
        // same answer at rest and the wrong one in the middle of a morph: an
        // animating window reports the width it is passing through, so aiming a
        // pill that was still growing set the width it had reached as the width
        // to finish at. The offer stopped part way and stayed there, with the
        // chips it could not fit clipped off. That is the ordinary case, not a
        // rare one — an app with no caret at the press is aimed from a look
        // that lands a few milliseconds after the offer goes up.
        if let panel, panel.isVisible { morph(to: wantedSize) }
    }

    // MARK: - Coming and going

    /// Put a state on screen, and take the surface away again after `duration`.
    ///
    /// The first state fades in. Every state after it morphs, because by then
    /// there is already a pill there and the user is looking at it.
    func set(_ state: PillState, for duration: TimeInterval? = nil) {
        pendingHide?.cancel(); pendingHide = nil
        pendingDismiss?.cancel(); pendingDismiss = nil
        stopAlertClock()

        if panel == nil { build() }
        guard let panel else { return }

        // A fade that has not finished is a panel that is still on screen. Put
        // it back to full strength rather than morphing something half gone.
        if isFading {
            isFading = false
            // Zero-length rather than a plain assignment: that is what stops
            // the animation underneath, which would otherwise go on pulling
            // the alpha down under the state that has just replaced it.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                panel.animator().alphaValue = 1
            }
        }
        // A newly set state supersedes any pending automatic fold.
        if foldIsPending {
            foldIsPending = false
            foldRun += 1
            pendingFold?.cancel(); pendingFold = nil
        }

        let arriving = !panel.isVisible

        // The words change with the frame, not after it: SwiftUI is told inside
        // the same turn that starts the AppKit animation, and both read
        // `PillHUD.motion`.
        //
        // Except on arrival, where there is nothing to change *from*. The pill
        // is raised at the moment the microphone starts recording, so a
        // crossfade there is 180 ms of looking absent while it is already
        // listening — on top of the ~200 ms the microphone itself took. The
        // panel's own alpha is cut the same way in `fadeIn`; both halves of the
        // entrance have to go, or the surviving one still paces it.
        // Content is always installed synchronously at its final layout.  A
        // delayed/cross-faded tree can leave a native hosting view showing the
        // new frame with no contents when event tracking interrupts the
        // completion.  The AppKit surface still morphs below; only its bounds
        // animate, never the text or controls inside it.
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { model.state = state }

        // The pill ignores the mouse in every state but this one. It sits over
        // whatever you are working in, so a surface that swallowed clicks for
        // the length of a dictation would be a hole in your screen — but the
        // offer is made of buttons, and a button you cannot click is a picture
        // of a button.
        if case .offer = state {
            // Both stages. The tab is the smaller reason and the newer one: it
            // is opened by the pointer resting on it, and a window that ignores
            // the mouse is never rested on.
            panel.ignoresMouseEvents = false
        } else if case .alert = state {
            // The pointer holds the clock and a click copies a code block.
            panel.ignoresMouseEvents = false
            offerFor = nil
            pointerHolds = false
            openedByPointer = false
            pendingOpen?.cancel(); pendingOpen = nil
        } else {
            panel.ignoresMouseEvents = true
            // No offer, nothing for the pointer to hold: `hovering` reads these
            // and must not act on a duration left behind by the last one.
            offerFor = nil
            pointerHolds = false
            openedByPointer = false
            pendingOpen?.cancel(); pendingOpen = nil
        }

        let size = wantedSize

        if !arriving {
            morph(to: size)
        } else {
            let placed = anchor(size)
            model.docked = placed.dock
            panel.setContentSize(size)
            panel.setFrameOrigin(placed.origin)
            fadeIn(panel)
            logFrame("raised")
        }

        guard let duration else { return }
        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        pendingDismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// Take the pill away — unless something is about to put it back.
    ///
    /// Deferred by one pass of the run loop on purpose. Half the app's
    /// transitions are written as a hide followed by a show a few lines later,
    /// in the same turn: the recording ends and transcription starts, Escape
    /// stops a run and says so, a prompt finishes and a notice replaces it.
    /// Faded immediately, every one of those would blink out and back in.
    /// Deferred, the `set()` that follows cancels this and the pill simply
    /// changes shape — so those seams became morphs without a single call site
    /// having to know about it.
    func hide() {
        pendingDismiss?.cancel(); pendingDismiss = nil
        pendingHide?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        pendingHide = work
        DispatchQueue.main.async(execute: work)
    }

    /// In without moving.
    ///
    /// The other floating surfaces rise 8pt as they appear — `riseIntoView`,
    /// which the correction and preview panels still use. This one must not.
    /// It is on screen for the whole of a dictation and changes state three or
    /// four times inside it, so it is the one surface whose position you learn
    /// and then read without looking at. Anything that moves it vertically is a
    /// thing to re-find.
    ///
    /// It was tried with the rise and the rise is what put it 8pt low: the
    /// entrance animation did not run, so the pill sat at its start position
    /// through the whole recording and only climbed to where it belonged when
    /// the next state morphed it there. Nothing to animate is nothing to get
    /// wrong.
    ///
    /// And in without fading. It was a 180 ms ease-out, and it was the last
    /// 180 ms of a wait that measured ~700 ms from the key going down: 183 ms
    /// of `press_delay_seconds`, ~200 ms of the microphone opening, and then
    /// this. The other two buy something — the delay keeps ⌘C out, and the pill
    /// may not appear before the microphone is actually recording or people
    /// talk into a promise. This one bought a nicety, and paid for it in the
    /// only part of the wait where the app is already listening and not saying
    /// so. `fadeOut` keeps its fade: an exit has no one waiting on it.
    private func fadeIn(_ panel: NSPanel) {
        model.onScreen = true
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    /// Out the same way: alpha only.
    ///
    /// Every dismissal in the app used to be a bare `orderOut` — the surface
    /// was simply not there on the next frame. An arrival worth animating is an
    /// exit worth animating: an instant cut is read as something having gone
    /// wrong, which for the failure notices is the one wrong thing to say.
    private func fadeOut() {
        pendingHide = nil
        pendingDismiss = nil
        stopAlertClock()
        pointerHolds = false
        openedByPointer = false
        pendingOpen?.cancel(); pendingOpen = nil
        guard let panel, panel.isVisible, !isFading else { return }

        // A decision cancels the automatic fold at once. Escape, Return and
        // running a command all arrive here, and the ordinary short dismissal
        // fade begins from a fully opaque surface.
        foldIsPending = false
        foldRun += 1
        pendingFold?.cancel(); pendingFold = nil

        isFading = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                ? 0 : Self.motion
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, self.isFading else { return }
            self.isFading = false
            // The aim belonged to the dictation that has just ended. A notice
            // raised later — a config reloaded, an update ready — is about the
            // app rather than about a place in somebody's document, and would
            // otherwise inherit a caret that has long since moved.
            self.near = nil
            panel.orderOut(nil)
            self.model.onScreen = false
            // Back to full strength while off screen, or the next appearance
            // starts from a panel that is already invisible and stays that way.
            panel.alphaValue = 1
        }
    }

    /// Grow or shrink in place, from the middle.
    ///
    /// The origin moves in the same animation group as the size. The pill is
    /// centred on the screen, so a width applied without a matching origin
    /// would leave it growing out of its left edge — which is the one direction
    /// it must not grow, because the dot on that edge is the thing the eye is
    /// resting on.
    private func morph(to size: NSSize) {
        guard let panel else { return }
        let placed = anchor(size)
        let frame = NSRect(origin: placed.origin, size: size)
        // Outside the early return: a state can change what the surface *is*
        // without moving it by a point — an offer arriving at the width the
        // notice before it happened to have — and the corners still have to
        // square up.
        model.docked = placed.dock
        guard frame != panel.frame else { return }
        defer { logFrame("moved") }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                ? 0 : Self.motion
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    /// Builds the panel before anything is waiting on it.
    ///
    /// An NSPanel and an NSHostingView, both on the main thread. Measured at
    /// 219 ms on the first press of a launch, between the key going down and
    /// the pill appearing. Every press after it cost 25 ms.
    ///
    /// `onScreen` goes false here because the default is true: a panel built
    /// and not shown would otherwise draw the pill into a window nobody can
    /// see. `fadeIn` sets it back when the pill is actually raised.
    func warm() {
        guard panel == nil else { return }
        model.onScreen = false
        build()
    }

    /// Where the window actually ended up.
    ///
    /// Every other line in this file is about what was *asked for* — the
    /// anchor, the state, the keys — and a pill nobody can see has usually been
    /// asked for perfectly and put somewhere off the screen it belongs on. That
    /// is what this exists to tell apart, and it is how a pill that was raised,
    /// keyed and invisible was tracked down once already.
    private func logFrame(_ what: String) {
        guard let panel else { return }
        let capsule = panel.frame.insetBy(dx: currentBleed, dy: currentBleed)
        let screen = NSScreen.screens.firstIndex { $0.frame.intersects(panel.frame) }
        // The window and the size it was asked for, as well as the capsule
        // inside it. Three claims rather than one, because the capsule is
        // worked out from the window by taking off a margin that depends on the
        // state — so a capsule of the wrong size is a window of the wrong size,
        // a margin taken off twice, or a window that would not shrink, and only
        // the raw numbers side by side tell those apart. The last of the three
        // is what this line was added to find.
        Log.write(String(
            format: "pill: %@ at %.0f,%.0f %.0fx%.0f (window %.0fx%.0f wanted %.0fx%.0f, %@) on screen %@%@",
            what, capsule.minX, capsule.minY, capsule.width, capsule.height,
            panel.frame.width, panel.frame.height,
            wantedSize.width, wantedSize.height,
            "\(model.docked)",
            screen.map(String.init) ?? "none",
            model.onScreen ? "" : " — but the surface is unmounted"
        ))
    }

    private func build() {
        // A click on the tab opens it now rather than after the dwell, and
        // without marking it as the pointer's — so the pointer wandering off
        // does not fold up something you asked for.
        model.onTab = { [weak self] in self?.open(true) }
        model.onAlertHover = { [weak self] inside in self?.alertHovering(inside) }
        model.onAlertClose = { [weak self] in self?.closeAlert() }

        let hosting = NSHostingView(rootView: PillView().environmentObject(model))
        hosting.frame = NSRect(origin: .zero,
                               size: PillMetrics.panelSize(
                                   for: .recording(nil), hasIcon: false, dock: .free
                               ))
        // The panel is what resizes; the view follows it. Done this way round
        // because a SwiftUI frame inside a fixed panel centres a narrow pill in
        // a wide transparent box and takes the shadow with it.
        hosting.autoresizingMask = [.width, .height]
        // Say the backing is transparent, out loud.
        //
        // The glow is a blur, and a blur makes SwiftUI rasterize the view into
        // an offscreen layer — which it then composites opaque, painting the
        // panel's whole rectangle behind the capsule. On a floating surface
        // that is the one artefact you cannot have: it is a visible box around
        // the pill, in the shape of the window nobody is supposed to know is
        // there.
        //
        // The panel is already `isOpaque = false` with a clear background. That
        // governs the window; this governs the layer the blur is drawn into,
        // and they are two different claims.
        hosting.wantsLayer = true
        hosting.layer?.isOpaque = false
        hosting.layer?.backgroundColor = NSColor.clear.cgColor

        // A plain view between the hosting view and the window.
        //
        // With the hosting view as the panel's own content view, the window
        // collapsed to 104x104 while recording — the bleed with a capsule of
        // 0x0 inside it — and nothing was drawn until the next state set the
        // frame again. The glass container this replaced was doing the same
        // job.
        let container = NSView(frame: hosting.frame)
        container.autoresizesSubviews = true
        container.addSubview(hosting)

        let panel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = container
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // Drawn in SwiftUI instead. The window shadow is traced from the
        // window's alpha, so with a glow bleeding into the margin it would
        // outline the blur rather than the capsule — a soft grey halo around a
        // coloured one. A shadow under the capsule is the shape it should be.
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Unlike the other HUDs, this surface has an intentional platinum
        // light appearance as well as its charcoal dark appearance.
        panel.appearance = nil
        self.panel = panel
    }

    /// Where a pill of this window size sits: next to the words when this
    /// dictation has an anchor, on the screen those words are on. With no
    /// anchor, the capsule centred 96pt off the bottom of the screen the
    /// pointer is on — which is the screen you are typing into.
    ///
    /// `size` is the window's, bleed included, so the margin is taken back off
    /// both axes: what has to land at 96pt is the capsule you can see, not the
    /// transparent border the glow spills into.
    ///
    /// Recomputed at every state rather than once at the first show, so a pill
    /// that grows stays centred and one that arrives after you have moved to
    /// the other monitor arrives on that one.
    private func anchor(_ size: NSSize) -> (origin: NSPoint, dock: Dock) {
        // Every state of a dictation that has an anchor, not just the last one.
        // The point of aiming the pill is that it says where the words are
        // going *before* they go there, and a pill that pointed at the caret
        // only once the words had landed would be reporting rather than
        // telling you.
        //
        // The caret decides the screen too, not the pointer. They are the same
        // screen in the ordinary case and the pointer is only a stand-in for
        // "where you are working" — but with the caret in a window on one
        // monitor and the pointer parked on another, clamping to the pointer's
        // screen would put the pill on a display the words are not on. Worse,
        // the frame is recomputed on every state change, so the pill would
        // change monitors mid-dictation because the mouse was nudged.
        //
        // Chosen from `text` rather than from `rect`, because `rect` is as wide
        // as the pane and a pane can straddle two monitors — most of it can be
        // on the display the caret is not on. `beside` then clamps the pane's
        // left edge into the screen that does hold the caret.
        if let near {
            guard let visible = screen(showing: near.text)?.visibleFrame
            else { return (panel?.frame.origin ?? .zero, model.docked) }
            // The row comes from `rect`, which `CaretAnchor.across` has already
            // put at the bottom of whatever it found. The column comes from
            // `text`, which is the caret or the span itself.
            return beside(near.rect, column: near.text.minX, size: size, on: visible)
        }
        guard let visible = screenUnderPointer()?.visibleFrame
        else { return (panel?.frame.origin ?? .zero, .free) }
        return (NSPoint(x: visible.midX - size.width / 2,
                        y: visible.minY + 96 - currentBleed),
                .free)
    }

    /// The screen the caret is on: the one it overlaps most.
    ///
    /// Most, rather than the first that contains a corner, because a window
    /// straddling two monitors has a line of text on both and only one of them
    /// has most of it. A caret rectangle that lands on none of them — a window
    /// dragged off the edge, a display unplugged between the press and the
    /// pill — falls back to the pointer, which is the old behaviour.
    private func screen(showing rect: NSRect) -> NSScreen? {
        // At least a point across before anything is measured. An app is free
        // to report a caret with no width, and `intersection` calls an empty
        // rectangle a miss however far inside a screen it sits — so a caret
        // that is plainly on a display would match none of them.
        let probe = NSRect(
            x: rect.minX, y: rect.minY,
            width: max(rect.width, 1), height: max(rect.height, 1)
        )
        var best: NSScreen?
        var bestArea: CGFloat = 0
        for candidate in NSScreen.screens {
            let shared = candidate.frame.intersection(probe)
            guard !shared.isNull else { continue }
            let area = shared.width * shared.height
            if area > bestArea {
                bestArea = area
                best = candidate
            }
        }
        return best ?? screenUnderPointer()
    }

    /// The screen the pointer is on, which is the screen you are typing into.
    private func screenUnderPointer() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    /// Under the line the words are going to land on, at the left edge of the
    /// pane.
    ///
    /// Under rather than over because that is where you are looking and a
    /// surface above it covers what you just wrote. When there is no room below
    /// — the last line of a full-height window — it goes above instead, which
    /// is the one case where covering something is better than being cut off.
    ///
    /// The column is the words', now, and it used to be the pane's.
    ///
    /// Two versions of this chased the horizontal position — centred on the
    /// text, then aligned to where it starts — and both moved for reasons
    /// invisible from outside: what an app returns for a range is a line in one
    /// app and a cell in another, a wrapped sentence starts somewhere other than
    /// where it appears to, and a terminal's column width can only be guessed.
    /// The pane's left edge was the answer to that: not where the caret is, but
    /// the same place on every dictation.
    ///
    /// It stopped being the right trade when the surface started hanging off the
    /// line rather than floating near it. A dropdown pinned to a margin is about
    /// the field; one pinned to a character is about those words, and that is
    /// the whole claim this surface makes. The wobble the pane edge was hiding
    /// is still there and is now the price of saying something exact.
    ///
    /// Everything here is worked out for the capsule you can see, and the
    /// margin is taken off once at the end. The margin is transparent and it
    /// changes with the state — 52 while listening, 12 after — so a position
    /// clamped as a window would move the capsule 40pt sideways at the offer
    /// for no reason the user can see.
    private func beside(
        _ target: NSRect, column: CGFloat, size: NSSize, on visible: NSRect
    ) -> (origin: NSPoint, dock: Dock) {
        let gap = PillMetrics.dockGap
        let margin = currentBleed
        let capsule = NSSize(
            width: size.width - margin * 2, height: size.height - margin * 2
        )
        // The room the capsule keeps to, which is the screen less the smallest
        // margin any state takes. The wider one is allowed off the screen: it
        // is transparent, a borderless panel keeps an origin outside the
        // display, and pulling it back in would move the capsule.
        let room = visible.insetBy(dx: PillMetrics.dockBleed, dy: PillMetrics.dockBleed)

        var dock = Dock.below
        var y = target.minY - gap - capsule.height
        if y < room.minY {
            y = target.maxY + gap
            dock = .above
        }

        // Clamped into the screen, which is also what folds the panel back from
        // the right edge: a surface wider than the room left beside the words
        // has its origin pushed left, so it grows toward the middle instead of
        // off the display. The row is untouched by that, so it still names the
        // line it belongs to.
        return (NSPoint(
            x: min(max(column, room.minX), room.maxX - capsule.width) - margin,
            y: min(max(y, room.minY), room.maxY - capsule.height) - margin
        ), dock)
    }
}

// MARK: - Metrics

enum PillMetrics {
    static let height: CGFloat = 42

    /// How far under the line the surface sits.
    ///
    /// At 10pt the gap is wide enough to read as a separate object parked
    /// nearby, which is the one thing it must not read as. 3pt clears the
    /// descenders and nothing more.
    static let dockGap: CGFloat = 3

    /// Radius used by the tutorial's caret highlight around a docked pill.
    static let dockRadius: CGFloat = 4

    // MARK: The tab

    /// What the offer is before you ask for it.
    ///
    /// Small enough to sit under a line of body text without being part of it,
    /// and no smaller: below this the voice mark stops being recognisable.
    ///
    /// A third larger than it was drawn. 46x20 was sized on a design board, at
    /// a comfortable zoom, on a ground chosen to show it off. On a real screen
    /// beside real body text it was a smudge you had to already know about —
    /// which is the one thing a surface that replaces a panel cannot be. Every
    /// number here is the old one times four thirds, so the proportions are the
    /// ones that were agreed and only the scale moved.
    /// The margin is the second thing that was too tight. At 9pt of padding
    /// round a 20pt mark in a 27pt box the two marks sat against the edges, so
    /// the tab read as a crop of something rather than as a small whole thing.
    /// The contents did not change; the box grew round them.
    /// One size, and it was two.
    ///
    /// The dictation wore 31 and the offer wore 23, on the argument that a
    /// microphone being open is worth more of the screen than a mark waiting to
    /// be asked. That is true and it is not worth what it cost: the surface
    /// changes between those two states while you are watching it, so the
    /// object you learned to find grew and shrank under your eye, and a thing
    /// that changes size while it is doing nothing else reads as two things.
    ///
    /// 27 is between them. The mark is smaller than it was while you speak and
    /// larger than it was afterwards, and it never moves.
    static let tabHeight: CGFloat = 34
    static let tabPadding: CGFloat = 10
    static let tabGap: CGFloat = 6
    static let tabMark: CGFloat = 18
    static let listeningWidth: CGFloat = 112
    static let listeningGap: CGFloat = 9

    /// The tab, sized from what it holds.
    ///
    /// The key is drawn with its side on it — "Right ⌥" and not "⌥" — because
    /// a Mac has two of most modifiers and a glyph on its own tells you to
    /// press either. It was the bare symbol first and that is the confusion it
    /// caused. So the width follows the name, using the same measurement the
    /// panel's own hold row uses.
    ///
    /// No key while the microphone is open: you are holding it.
    static func tabWidth(hotkey: String) -> CGFloat {
        let mark = tabPadding * 2 + tabMark
        guard !hotkey.isEmpty else { return mark }
        return mark + tabGap + holdKeycapWidth(hotkey)
    }

    /// "Right ⌘" said twice is "R ⌘".
    ///
    /// The side matters and a glyph on its own tells you to press either, so
    /// the tab opens saying it in full. It does not have to go on saying it:
    /// the tab stays until you act, and a name that is read once and then sat
    /// there is 30pt of somebody's document. So after
    /// `PillHUD.hotkeyShortensAfter` the word collapses to its initial, which
    /// is enough to tell the two apart once you know there are two.
    ///
    /// A name with no word in front of its symbols — "⌃⌥Space", "fn" — has
    /// nothing to shorten and comes back as it was.
    static func shortHotkey(_ hotkey: String) -> String {
        let parts = hotkey.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].count > 1, let initial = parts[0].first else {
            return hotkey
        }
        return "\(initial) \(parts[1])"
    }

    /// The app icon on a tab that hangs off nothing. See `tabWidth`.
    static let tabIcon: CGFloat = 20

    /// The tab while the microphone is open: the voice mark, the icon when there is
    /// no line to say where the words are going, and whatever the hold is for
    /// when it is not dictation.
    static func tabWidth(label: String?, icon: Bool = false) -> CGFloat {
        var width = tabPadding * 2 + tabMark
        if icon { width += tabGap + tabIcon }
        guard let label else { return width }
        return width + tabGap + min(title(label), editWidth) + selectionFit
    }

    /// The mic meter and its persistent state label. A command-specific label
    /// may add context, but silence and speech never change this width.
    static func recordingWidth(label: String?) -> CGFloat {
        guard let label else { return listeningWidth }
        let listening = title("Listening")
        return max(
            listeningWidth,
            tabPadding * 2 + tabMark + listeningGap + listening
                + tabGap + min(title(label), editWidth) + selectionFit
        )
    }

    /// Past this the words being edited are truncated rather than the tab
    /// growing. A selection can be a paragraph, and a surface as wide as one is
    /// a surface that covers the thing it is pointing at.
    static let editWidth: CGFloat = 220
    /// The key on it, which grows with the rest. It is the tab's only text and
    /// a cap left at the chips' size would read as a chip that had wandered in.
    static let tabKeyHeight: CGFloat = 14
    static let tabKeyText: CGFloat = 10

    /// How long the pointer has to rest on the tab before it opens.
    ///
    /// The tab sits under the line you were typing on, and the pointer crosses
    /// that line all day. Without a dwell, reaching for a word two lines down
    /// opens a panel over the one you were reaching for.
    static let tabDwell: TimeInterval = 0.12

    /// Transparent drawing margin between the surface and the window edge.
    /// Seven points contains the three-point hard shadow and outline without
    /// creating a broad invisible region that could swallow document clicks.
    static let bleed: CGFloat = 7
    static let dockBleed = bleed

    /// Every state uses the same tight margin; state changes only resize the
    /// visible surface.
    static func bleed(for state: PillState) -> CGFloat { dockBleed }

    static func panelSize(
        for state: PillState, hasIcon: Bool, hotkey: String = "", dock: Dock
    ) -> NSSize {
        let width = width(for: state, hasIcon: hasIcon, hotkey: hotkey, dock: dock)
        let margin = bleed(for: state)
        return NSSize(
            width: width + margin * 2,
            height: height(for: state, width: width, hotkey: hotkey, dock: dock) + margin * 2
        )
    }

    /// The face the dictated sentence is set in — the same one the chips use.
    ///
    /// Kept as an `NSFont` because the pill is sized before it is drawn, and
    /// this sentence is the one thing on the surface long enough to wrap. The
    /// chips are measured at a flat rate per character; a line count off by one
    /// would clip the words instead of costing a few points of capsule.
    static let sentenceFont: NSFont = {
        let plain = NSFont.systemFont(ofSize: 12, weight: .medium)
        guard let rounded = plain.fontDescriptor.withDesign(.rounded) else { return plain }
        return NSFont(descriptor: rounded, size: 12) ?? plain
    }()

    /// One line of it, and the air above.
    static let sentenceLine: CGFloat = ceil(
        NSLayoutManager().defaultLineHeight(for: sentenceFont)
    )
    /// Between one block of the panel and the next.
    ///
    /// One number for all of them, and it used to be two: 4pt between the
    /// reading's lines and 8pt between the rows of a selection offer, on the
    /// argument that the reading is one block of text and the other three are
    /// different things. The panel is a list of blocks either way, and 4pt read
    /// as a paragraph rather than as a set of choices — which is what the wider
    /// number was already saying about the same problem.
    static let blockGap: CGFloat = 8
    /// The old name, kept because `selectionRow` is described against it.
    static let selectionGap: CGFloat = blockGap

    /// The line between two blocks.
    ///
    /// A rule and not more air. The panel's blocks are a sentence, a row of
    /// things you can do to it, and a way out — three different kinds of thing,
    /// and spacing alone says "these are apart" where a rule says "these are
    /// different". It is also what makes the chip row read as the middle of a
    /// menu rather than as a caption under the words.
    static let rule: CGFloat = 1
    static let ruleTint = Color.white.opacity(0.07)

    /// How many rules the panel draws: one over the chips when anything is
    /// above them, one over the way out when there is a key to name.
    ///
    /// Here rather than counted in the view, for the reason the rest of this
    /// enum exists: the surface is measured before it is drawn, and
    /// `OfferContent` draws on exactly these two conditions.
    /// Whether the panel names the hold gesture under its chips. Never under a
    /// learn question: that row is about transforms, and being a fixed run of
    /// text it would hold the panel wider than its sentence.
    static func showsHold(_ headline: Headline?, hotkey: String) -> Bool {
        if case .learn = headline { return false }
        if case .choose = headline { return false }
        return !hotkey.isEmpty
    }

    static func rules(
        headline: Headline?, reading: Confidence.Reading, hotkey: String,
        commands: [OfferedCommand] = []
    ) -> Int {
        var count = 0
        // Over the chips, so only when there are chips to rule off. The
        // selector draws none and `OfferContent` skips the line there too.
        if headline?.ownsARow == true || !reading.isEmpty {
            if !commands.isEmpty { count += 1 }
        }
        if showsHold(headline, hotkey: hotkey) { count += 1 }
        return count
    }

    /// What the two extra rows of a selection offer say.
    ///
    /// Here rather than in the view because the pill is measured before it is
    /// drawn, and a string measured in one place and set in another is how a
    /// chip ends up hanging over the end of a capsule. The view reads these.
    static let editLead = "Edit"

    /// In front of the answers. On the sentence row it made the sentence the
    /// second thing on its own line.
    static let learnLead = "Learn?"
    /// Asked about what was said, not about what is on screen — nothing is.
    static let chooseLead = "Did you mean?"
    static let holdLead = "or hold"
    static let holdTail = "and say what to change"
    /// Air above and below an expanded offer. The old 8pt was hidden inside
    /// the 42pt collapsed height and came out closer to four at the top once
    /// AppKit and SwiftUI rounded the stacked rows differently.
    static let offerVerticalPadding: CGFloat = 11
    /// The keycap between the two halves of the hold line, and the gaps either
    /// side of it.
    ///
    /// Measured from the name it will hold, because the hotkey is configurable
    /// and "Right ⌘" is not the width of "⌥". A fixed box is what let the glyph
    /// be a literal in the first place.
    static func holdKeycapWidth(_ hotkey: String) -> CGFloat {
        max(20, title(hotkey) + 4) + 12
    }
    /// Its box, which is taller than a line of the text beside it.
    static let holdKeycapHeight: CGFloat = 17
    /// The highlight's own padding, either side of the words.
    static let selectionFit: CGFloat = 12
    /// The vertical padding inside the highlight, top and bottom.
    static let selectionPadding: CGFloat = 1

    /// How tall each of the two extra rows is.
    ///
    /// Not `sentenceLine`. The words row is that plus its highlight's padding,
    /// and the hold row is as tall as the keycap in it — both 17 against a
    /// 15pt line. Budgeting a bare line made the pill 4pt shorter than its own
    /// contents, which the capsule's slack around a 26pt chip row hid: it
    /// looked right and was wrong, and a longer selection or a different system
    /// font would have shown it.
    static let selectionRow: CGFloat = max(
        sentenceLine + selectionPadding * 2, holdKeycapHeight
    )

    /// Extra air above the sentence, on top of what centring the two rows
    /// already leaves. The chips sit in capsules of their own and carry their
    /// own margin with them; the sentence is bare text and read as crowded
    /// against the rim without this.
    static let sentenceTop: CGFloat = 4

    /// Past this the sentence wraps rather than the pill growing sideways. The
    /// pill sits under the line you dictated into, and one wider than the window
    /// is no longer pointing at anything.
    static let sentenceWidth: CGFloat = 640

    /// How wide an alert is, whatever it says. Not `sentenceWidth`: at 640 a
    /// three-line message comes out one line long, which reads as a banner.
    static let alertWidth: CGFloat = 420

    /// The air above and below an alert's blocks, the gap between them, and
    /// the countdown bar along the top edge.
    static let alertPad: CGFloat = 12
    static let alertGap: CGFloat = 8
    static let alertBar: CGFloat = 3

    /// Three lines holds about 240 characters, which is the 99th percentile of
    /// the dictations in this machine's archive. Past that it truncates: the
    /// pill is on screen for seconds and a paragraph of it would cover the
    /// words it is about.
    static let sentenceLines = 3

    /// The warning, above everything. One line, never wrapped: it names one
    /// word and one number, and a warning that wraps is a paragraph.
    static let warningFont: NSFont = {
        let plain = NSFont.systemFont(ofSize: 12, weight: .bold)
        guard let rounded = plain.fontDescriptor.withDesign(.rounded) else { return plain }
        return NSFont(descriptor: rounded, size: 12) ?? plain
    }()
    static let warningLine: CGFloat = ceil(
        NSLayoutManager().defaultLineHeight(for: warningFont)
    )

    /// The capsule, plus whatever rows the reading puts above the chips.
    ///
    /// An offer with nothing to say about the decode is the height the pill has
    /// always been, so a dictation that went fine changes nothing.
    static func height(
        for state: PillState, width: CGFloat, hotkey: String = "", dock: Dock
    ) -> CGFloat {
        guard case .offer(let commands, let headline, let reading, let open) = state else {
            // The one state with no fixed height: it takes what its blocks
            // ask for at this width.
            if case .alert(let markdown, let tone) = state {
                return AlertContent.height(markdown: markdown, tone: tone, width: width)
            }
            // Recording and transcribing share the voice mark's tab — see
            // `RecordingContent`. A notice is not: it is a sentence, and a
            // sentence needs the height it has always had.
            if case .notice = state { return height }
            return tabHeight
        }
        guard open else { return tabHeight }
        // A selection offer is three rows: the words, the chips, and the line
        // about the key. Two of them are extra, and they are added whatever the
        // reading says — the two can appear together, on a dictation you
        // selected part of after being warned about it.
        // The words row always, and the hold row only when there is a key to
        // name — `OfferContent.hold` draws it on the same condition.
        var extra: CGFloat = 0
        // A rule costs its own point and one more gap, because the block
        // spacing falls on both sides of it.
        extra += CGFloat(rules(
            headline: headline, reading: reading, hotkey: hotkey, commands: commands
        ))
            * (rule + blockGap)
        if case .learn(let it) = headline {
            // Heading at a 5pt top inset, 16pt to the correction, and the
            // quiet explanatory footer below the actions.
            extra += learnRows(it) + blockGap + 39 + 12 + blockGap
        } else if case .choose(let it) = headline {
            // The pill's own 42 is one chip row and the 16 of air that centres
            // it. The selector draws no chips — each option carries its own key
            // — so give the row back and keep the air. `OfferContent` skips the
            // chip block on the same condition, so nothing is left in its place.
            extra += chooseRows(it.options.count)
            if commands.isEmpty { extra -= chipRowHeight }
        } else if headline?.ownsARow == true {
            extra += selectionRow + blockGap
        }
        // The way out the chips do not cover, on every panel that has a key to
        // name. It used to be drawn only over a selection, where it was the one
        // way to reach a transform that had no chip — but that is true of every
        // offer, and the panel is the surface with room to say it.
        // `OfferContent.hold` draws it on this same condition.
        if showsHold(headline, hotkey: hotkey) { extra += selectionRow + blockGap }
        // Every chip row past the first. The pill's own 42 already holds one,
        // with the slack that centres it.
        let lead: CGFloat
        switch headline {
        case .landing(let words): lead = title(words) + gap
        case .learn: lead = 0
        default: lead = 0
        }
        let wrapped = max(0, chipRows(commands, lead: lead).count - 1)
        extra += CGFloat(wrapped) * (chipRowHeight + chipRowGap)

        let base = chipRowHeight + offerVerticalPadding * 2
        let rows = readingRows(reading, width: width)
        guard !rows.isEmpty else { return base + extra }
        return base + extra + sentenceTop
            + rows.reduce(0, +) + blockGap * CGFloat(rows.count)
    }

    /// The height of each row the reading draws, top to bottom. The count is
    /// also the number of `blockGap`s: one between each pair, one more
    /// between the last row and the chips.
    private static func readingRows(
        _ reading: Confidence.Reading, width: CGFloat
    ) -> [CGFloat] {
        var rows: [CGFloat] = []
        if reading.warning != nil { rows.append(warningLine) }
        if !reading.words.isEmpty {
            rows.append(sentenceLine * CGFloat(lines(reading.words, width: width)))
        }
        return rows
    }

    /// Where the sentence wraps at this width, counted ahead of time.
    static func lines(_ sentence: [Confidence.Word], width: CGFloat) -> Int {
        let available = width - padding * 2
        guard available > 0 else { return 1 }
        let box = run(sentence).boundingRect(
            with: NSSize(width: available, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            attributes: [.font: sentenceFont]
        )
        return max(1, min(sentenceLines, Int((box.height / sentenceLine).rounded(.up))))
    }

    /// The sentence set on one line.
    static func sentenceRun(_ sentence: [Confidence.Word]) -> CGFloat {
        ceil(run(sentence).size(withAttributes: [.font: sentenceFont]).width)
    }

    /// The words with the spaces the pill draws between them — what is measured
    /// has to be what is set. See `Confidence.sentence`.
    private static func run(_ sentence: [Confidence.Word]) -> NSString {
        sentence.map(\.text).joined(separator: " ") as NSString
    }

    static let padding: CGFloat = 15
    static let gap: CGFloat = 10
    static let dot: CGFloat = 8

    static func width(
        for state: PillState, hasIcon: Bool, hotkey: String = "", dock: Dock
    ) -> CGFloat {
        // The icon says where the words are going, and a tab hanging off a line
        // has already said it by hanging there. Free, nothing else says it.
        let icon = hasIcon && dock == .free
        switch state {
        case .recording(let label):
            // A stable 112pt Listening surface whether the room is silent or
            // speech is driving the bars. A command label can widen it, but an
            // app icon cannot: the persistent state label is the information
            // that must survive in peripheral vision.
            return recordingWidth(label: label)
        case .working(let message):
            return tabWidth(label: message, icon: icon)
        case .notice(let message, _): return text(message)
        case .alert: return alertWidth
        case .offer(let commands, let headline, let reading, let open):
            guard open else { return tabWidth(hotkey: hotkey) }
            return offer(commands, headline: headline, reading: reading, hotkey: hotkey)
        }
    }

    /// Wide enough for the message, the dot in front of it and the padding —
    /// the text is one line and truncating it would lose the half that says
    /// what to do about it.
    static func text(_ message: String) -> CGFloat {
        min(540, max(270, CGFloat(message.count) * 7.5 + 78))
    }

    /// A row of chips, and no minimum.
    ///
    /// Unlike a message, which is a sentence you have to be able to read to the
    /// end, this is a shape you learn after seeing it twice. Held to the 270pt
    /// floor it would be a mostly empty pill, and an offer that looks like a
    /// notice reads as something having gone wrong.
    ///
    /// Much narrower than it was. It used to ask a whole question — "Wrong?
    /// Right ⌘ to fix it" — because it appeared at the bottom of the screen
    /// with no connection to the words it was about. Under the words, that
    /// sentence is answering a question nobody has to be asked any more.
    ///
    /// Generous rather than tight: the chips are laid out by SwiftUI and
    /// measured here, and the two numbers only ever agree approximately. The
    /// title is `.fixedSize()`, so a capsule a few points too narrow lets a
    /// chip hang over the end rather than shortening it.
    ///
    /// A landing headline widens it and is meant to: then the sentence is on
    /// the clipboard and looking like a notice is the point.
    /// A sentence widens it too, up to `sentenceWidth`, and then wraps. So
    /// does a warning, which never wraps.
    ///
    /// A selection headline does neither. It is a row of its own, so it
    /// competes with the chip row for the pill's width rather than adding to
    /// it — and it is capped like the sentence, because a selection can be a
    /// paragraph and a pill as wide as one is a pill nobody can place.
    static func offer(
        _ commands: [OfferedCommand], headline: Headline? = nil,
        reading: Confidence.Reading = Confidence.Reading(), hotkey: String = ""
    ) -> CGFloat {
        let lead: CGFloat
        switch headline {
        case .landing(let words): lead = title(words) + gap
        case .learn: lead = 0
        default: lead = 0
        }
        // The widest row the chips fall into, which past `chipsWidth` is no
        // longer all of them. See `chipRows`.
        let rows = chipRows(commands, lead: lead)
        var widest = rows.enumerated().map { index, row in
            padding * 2 + (index == 0 ? lead : 0)
                + row.reduce(CGFloat(0)) { $0 + chipWidth(commands[$1]) }
                + CGFloat(max(row.count - 1, 0)) * 4 + rowFit
        }.max() ?? padding * 2 + rowFit
        if case .selection(let words) = headline {
            widest = max(widest, min(
                sentenceWidth,
                padding * 2 + title(editLead) + gap + title(words) + selectionFit
            ))
        }
        // No wider than its sentence: a short correction gets a short pill.
        if case .learn(let learn) = headline {
            widest = max(widest, min(
                sentenceWidth, padding * 2 + learnWidth(learn) + selectionFit
            ))
        }
        // One row, measured in the faces it is drawn in. `Choose.fitted` has
        // already narrowed the window to this cap, so the cap only bites when
        // one place is wider than the pill may be.
        if case .choose(let it) = headline {
            widest = max(widest, min(
                sentenceWidth, padding * 2 + chooseWidth(it) + selectionFit
            ))
        }
        // Only when there is a key to name. `OfferContent.hold` draws the row
        // on the same condition, so the two agree about whether it is there to
        // be measured.
        if showsHold(headline, hotkey: hotkey) {
            widest = max(widest, min(
                sentenceWidth,
                padding * 2 + title(holdLead) + holdKeycapWidth(hotkey) + title(holdTail)
                    + holdGap * 2 + rowFit
            ))
        }
        if !reading.words.isEmpty {
            widest = max(widest, min(sentenceWidth, padding * 2 + sentenceRun(reading.words)))
        }
        if let warning = reading.warning {
            let text = ceil((warning as NSString).size(withAttributes: [.font: warningFont]).width)
            widest = max(widest, min(sentenceWidth, padding * 2 + dot + gap + text))
        }
        return widest
    }

    /// Past this the chip row wraps rather than the panel growing sideways.
    ///
    /// A floating pill was centred on the screen and had width to spare, so a
    /// row of six transforms simply made a wider lozenge. A docked panel has
    /// its left edge pinned to a character, so every point of width pushes it
    /// toward the far side of the window and eventually off it. Downward it is
    /// free. So the row stops somewhere and the rest goes on the next one.
    ///
    /// `sentenceWidth`, and not a smaller number of its own. It was 420 and
    /// that was too tight: four ordinary transform names come to about 430, so
    /// the fourth chip wrapped on a panel with most of a screen beside it —
    /// wrapping to save width nobody needed. This file already decided how wide
    /// a surface pinned to a line may be, for the sentence, and the answer is
    /// the same one: past it the surface is no longer pointing at anything.
    /// One cap for the whole panel rather than two disagreeing about it.
    static let chipsWidth: CGFloat = sentenceWidth

    /// A chip row and the gap to the one under it.
    static let chipRowHeight: CGFloat = 26
    static let chipRowGap: CGFloat = 4

    /// One chip: its keycap, its words, and 9pt of padding either side.
    static func chipWidth(_ command: OfferedCommand) -> CGFloat {
        18 + (command.key.isEmpty ? 0 : keycap) + title(command.title)
    }

    /// The chips laid into rows, greedily, none wider than `chipsWidth` allows.
    ///
    /// Here rather than in the view, for the reason every other measurement in
    /// this file is here: the surface is sized before it is drawn, and a row
    /// count off by one is a chip hanging over the end of it. The view reads
    /// this and draws exactly the rows it names, so the two cannot disagree.
    ///
    /// `lead` is the landing headline, which sits in front of the first chip
    /// and only on the first row.
    static func chipRows(_ commands: [OfferedCommand], lead: CGFloat = 0) -> [[Int]] {
        let room = chipsWidth - padding * 2 - rowFit
        var rows: [[Int]] = []
        var row: [Int] = []
        var used = lead
        for (index, command) in commands.enumerated() {
            let chip = chipWidth(command)
            if !row.isEmpty, used + 4 + chip > room {
                rows.append(row)
                row = [index]
                used = chip
            } else {
                used += row.isEmpty ? chip : 4 + chip
                row.append(index)
            }
        }
        if !row.isEmpty { rows.append(row) }
        return rows
    }

    /// The keycap on a chip: one character at 11pt bold, 4pt either side, and
    /// the 6pt between it and the words.
    static let keycap: CGFloat = 24
    /// The two spaces around the hotkey in the spoken-command footer.
    static let holdGap: CGFloat = 6

    /// A chip's words at 12pt rounded.
    ///
    /// Measured in the font they are set in, not counted at a flat rate per
    /// character. A flat rate is generous for ordinary lowercase words and
    /// short by a couple of points for capitals and digits, and the error is
    /// per chip: a row of transform names that all run wide is a row that does
    /// not fit the capsule counted for it. The chip titles come from the
    /// config, so what they are made of is not this file's to assume.
    ///
    /// `chipFit` is the gap between what AppKit measures here and what SwiftUI
    /// draws over there.
    static let learnMonoFont: NSFont =
        .monospacedSystemFont(ofSize: 14, weight: .semibold)

    /// Two points up on everything else the pill sets: at 12 this row read as
    /// the caption to its own chip row rather than the thing being decided.
    static let learnFont: NSFont = {
        let plain = NSFont.systemFont(ofSize: 14, weight: .medium)
        guard let rounded = plain.fontDescriptor.withDesign(.rounded) else { return plain }
        return NSFont(descriptor: rounded, size: 14) ?? plain
    }()

    static let learnRow: CGFloat = ceil(
        NSLayoutManager().defaultLineHeight(for: learnFont)
    ) + 2

    /// The row, as tall as the lines it will actually take.
    ///
    /// `learnRow` alone measured one line and the view allows two, so a
    /// windowed sentence that still wrapped was drawn into a box built for
    /// half of it. Capped at the two the view will draw.
    static func learnRows(_ it: Learn) -> CGFloat {
        let room = sentenceWidth - padding * 2
        let lines = room > 0 ? min(2.0, ceil(learnWidth(it) / room)) : 1
        return learnRow * max(1, lines)
    }

    /// One option: a shimmering key and the word, in a capsule padded the way
    /// a chip is. The mono word is the taller of the two things in it.
    ///
    /// The view frames each option to exactly this, so the stack cannot come
    /// out taller than the panel measured for it.
    static let chooseChipHeight: CGFloat = max(
        ceil(NSLayoutManager().defaultLineHeight(for: chooseWordFont)),
        holdKeycapHeight
    ) + 8
    /// The option's word: the prose's size and weight, in the monospaced face.
    static let chooseWordFont: NSFont =
        .monospacedSystemFont(ofSize: 14, weight: .medium)
    /// The last row of every question: none of these.
    ///
    /// It writes what was heard and records nothing, so the correction you
    /// make afterwards is an ordinary one — the panel offers a rule for it the
    /// way it always has.
    static let chooseElsewhere = "something else"

    /// Between the two options of one place.
    static let chooseChipGap: CGFloat = 7
    /// Between the lead and the sentence.
    static let chooseGap: CGFloat = 17
    /// About a space in `learnFont`, between a run of prose and the stack
    /// beside it. The view lays the row out at this spacing.
    static let chooseWordGap: CGFloat = 5

    /// The lead, then the sentence with the stack standing in it. One row per
    /// reading, and the row itself is never allowed to wrap.
    static func chooseRows(_ options: Int) -> CGFloat {
        let rows = CGFloat(max(2, options))
        return learnRow + chooseGap + chooseChipHeight * rows + chooseChipGap * (rows - 1)
    }

    /// One option's capsule, measured in the face the word is set in.
    static func chooseChipWidth(_ word: String) -> CGFloat {
        18 + keycap + ceil((word as NSString)
            .size(withAttributes: [.font: chooseWordFont]).width) + chipFit
    }

    /// The sentence on one line: the two runs of prose, the wider of the two
    /// options, and a space either side of the stack. The lead row when a
    /// short sentence leaves it the wider of the two.
    static func chooseWidth(_ it: Choose) -> CGFloat {
        var width = it.options.map(chooseChipWidth).max() ?? 0
        var pieces = 1
        func prose(_ run: String) {
            guard !run.isEmpty else { return }
            width += ceil((run as NSString)
                .size(withAttributes: [.font: learnFont]).width)
            pieces += 1
        }
        prose(it.before)
        prose(it.after)
        width += CGFloat(pieces - 1) * chooseWordGap
        let lead = chooseLeadWidth + (it.count.map { gap + title($0) } ?? 0)
        return max(width, lead) + learnFit
    }

    /// The question above the sentence, in the face it is set in.
    static let chooseLeadWidth: CGFloat = ceil(
        (chooseLead as NSString).size(withAttributes: [.font: learnLeadFont]).width
    ) + chipFit

    /// Whether the row fits the panel at its natural width.
    ///
    /// The same sum `width(for:)` caps at `sentenceWidth`, asked before the cap
    /// bites: this row cannot wrap, so a row over the cap is a row with its end
    /// cut off. `Choose.fitted` drops a word either side until this is true.
    static func chooseFits(_ it: Choose) -> Bool {
        padding * 2 + chooseWidth(it) + selectionFit <= sentenceWidth
    }

    /// At 13 beside a 14pt sentence it read as the smaller of the two.
    static let learnLeadFont: NSFont = {
        let plain = NSFont.systemFont(ofSize: 14, weight: .semibold)
        guard let rounded = plain.fontDescriptor.withDesign(.rounded) else { return plain }
        return NSFont(descriptor: rounded, size: 14) ?? plain
    }()

    /// `title` uses `sentenceFont`, comes up short, and the chips then sit
    /// on the question.
    static let learnLeadWidth: CGFloat = ceil(
        (learnLead as NSString).size(withAttributes: [.font: learnLeadFont]).width
    ) + chipFit

    /// Measured in both faces it is drawn in. `title` uses `sentenceFont`
    /// alone, and the two monospaced runs are wider, so a panel sized from it
    /// wrapped a line built to hold one. These are the view's runs exactly.
    static func learnWidth(_ it: Learn) -> CGFloat {
        let rounded = it.before + "  " + it.after
        let mono = it.heard + it.term
        return ceil((rounded as NSString).size(withAttributes: [.font: learnFont]).width)
            + ceil((mono as NSString).size(withAttributes: [.font: learnMonoFont]).width)
            + learnFit
    }

    static func title(_ words: String) -> CGFloat {
        ceil((words as NSString).size(withAttributes: [.font: sentenceFont]).width) + chipFit
    }

    /// What SwiftUI lays the chip row out at, over what the numbers above add
    /// up to. Two text engines: AppKit measures a title here, SwiftUI draws it
    /// there, and they disagree by up to 2pt per chip; the row comes out 4pt
    /// wider than its parts whatever it holds. Both measured against the drawn
    /// row over one to six chips, and titles of capitals, digits, accents and
    /// the narrowest and widest letters there are.
    ///
    /// Generous rather than tight, because the chip title is `.fixedSize()`: a
    /// capsule a point short does not shorten a chip, it hangs one over the
    /// end of the pill.
    /// Slack on the learn row, so a line measured to the pixel does not sit
    /// flush against the padding and read as clipped.
    static let learnFit: CGFloat = 8
    static let chipFit: CGFloat = 2
    static let rowFit: CGFloat = 4
}

private struct PillHeading: View {
    let title: String
    var detail: String?
    let theme: ContextTheme

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold)).fixedSize()
            Spacer(minLength: 8)
            if let detail {
                Text(detail).font(.system(size: 10)).foregroundStyle(theme.muted)
            }
        }
        .frame(height: 18)
        .foregroundStyle(theme.foreground)
    }
}

// MARK: - View

/// A red light, a live meter, and where the words are going — and then whatever
/// the same pill has to say next.
///
/// Left to right the recording state is a sentence: recording, hearing this,
/// into this. The destination sits at the end because it is the one part you
/// read once and stop watching — the meter is what moves, and it wants the
/// middle. The elapsed time was here once to prove the recorder was running,
/// which is the meter's job — it moves when you speak, which a clock does not.
/// A clock next to a hot mic only ever reads as pressure to hurry up.
///
/// The icon carries no mark of its own. It was tried with a scarlet ring around
/// it, which read as a red border painted on someone else's artwork and put a
/// second saturated shape next to the dot for no gain — the dot already says
/// the mic is hot, and saying it twice is what made the left half heavy.
///
/// **With no icon the pill is simply narrower**, back to the dot and the meter
/// it has always been. An empty slot held open is a hole you have to explain.
///
/// The narrow pill is also the warning. The icon appears when there is a field
/// with keyboard focus to write into — not merely when an app is in front — so
/// its absence says the words have nowhere to go and will be copied instead.
/// That is a thing worth knowing while you are still talking, and it is told by
/// the shape of the pill rather than by a second word on it: the pill is read in
/// peripheral vision, and something being missing is the one difference that
/// registers there.
struct PillView: View {
    @EnvironmentObject private var model: PillModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Nothing at all while the panel is out. See `PillModel.onScreen`.
        if model.onScreen {
            pill.environment(\.colorScheme, effectiveColorScheme)
        }
    }

    private var pill: some View {
        // The capsule is the window, whatever the contents would rather be.
        //
        // The window's width is animated by AppKit and the contents are laid
        // out by SwiftUI, and for the length of a morph the two disagree: the
        // new state's contents are at full size on the first frame while the
        // window is still on its way there from the last state's width. A
        // `maxWidth: .infinity` frame grows to whichever is larger, so the
        // whole surface — capsule, rim and chips — was drawn wider than the
        // window and cut off square by its edge. An offer with four chips
        // arriving after a notice spilled onto the desktop for those 180ms,
        // which is what an offer with a row of transforms on it does every
        // time.
        //
        // `geo.size` is the window less its bleed, and a fixed frame at that
        // size is the one thing that cannot grow past it. What does not fit is
        // clipped to the capsule instead — so a morph reads as the pill opening
        // with the chips arriving from under its rim, and the surface never
            // leaves the window. The clip stays inside the surface decoration,
            // whose hard shadow draws outside the shape.
        GeometryReader { geo in
            ZStack {
                switch model.state {
                case .recording(let label):
                    RecordingContent(
                        level: model.level, label: label
                    )
                    .transition(.opacity)
                case .working(let message):
                    WorkingContent(message: message, dock: model.docked, icon: model.appIcon)
                        .transition(.opacity)
                case .notice(let message, let tone):
                    MessageContent(message: message, tone: tone)
                        .transition(.opacity)
                case .alert(let markdown, let tone):
                    AlertContent(
                        markdown: markdown, tone: tone, fraction: model.alertRemaining,
                        onClose: model.onAlertClose
                    )
                    .transition(.opacity)
                case .offer(let commands, let headline, let reading, let open):
                    if open {
                        OfferContent(commands: commands, headline: headline, reading: reading)
                            .transition(.opacity)
                    } else {
                        TabContent(warned: reading.warning != nil)
                            .transition(.opacity)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipShape(shape)
        }
        // The whole surface, not each chip: moving from one chip to the next
        // must not read as leaving the pill. What leaving costs is decided by
        // whoever raised the offer — see `PillModel.onHover`.
        .onHover { inside in
            // `onHover` belongs to whoever raised the offer.
            if case .alert = model.state {
                model.onAlertHover?(inside)
            } else {
                model.onHover?(inside)
            }
        }
        // One quiet platinum/charcoal surface in every state. Warning offers
        // retain amber/scarlet in their outline and text.
        .foregroundStyle(theme.foreground)
        .contextSurface(shape, border: border, theme: theme)
        // The tight margin needed by the hard-offset shadow. See
        // `PillMetrics.dockBleed`.
        //
        // The same number `PillMetrics.panelSize` added to the window, and it
        // has to be: the window is sized from there and the surface is inset
        // from here, so a disagreement is a surface drawn at the wrong size
        // inside a window of the right one.
        .padding(PillMetrics.bleed(for: model.state))
        .environment(\.contextPrimaryColor, model.primaryColor)
    }

    private var theme: ContextTheme {
        ContextTheme(scheme: effectiveColorScheme, primaryHex: model.primaryColor)
    }

    private var effectiveColorScheme: ColorScheme {
        model.theme.resolved(against: colorScheme)
    }

    private var border: Color {
        guard case .offer(_, _, let reading, _) = model.state,
              reading.warning != nil else { return theme.edge }
        return reading.stopped ? theme.failure : theme.caution
    }

    /// Revision 08 uses one silhouette in every state so the visible surface,
    /// outline and hard shadow resize as one object.
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: ContextIdentity.radius, style: .continuous)
    }
}

/// The compact five-bar voice mark used by recording, processing, and the
/// collapsed offer. Recording bars are driven only by the recorder's smoothed
/// RMS level; the timeline exists solely for the distinct processing state.
private struct ContextMeter: View {
    var level: Double
    var working = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var scale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.contextPrimaryColor) private var primaryColor

    var body: some View {
        TimelineView(.animation(
            minimumInterval: 1.0 / 30,
            paused: !working || reduceMotion
        )) { timeline in
            Canvas { context, size in
                let time = working && !reduceMotion
                    ? timeline.date.timeIntervalSinceReferenceDate : 0
                for index in 0 ..< 5 {
                    let amplitude: Double
                    if working && !reduceMotion {
                        amplitude = 0.28 + 0.72 * (0.5 + 0.5 * sin(time * 4 - Double(index) * 0.7))
                    } else {
                        let profile = [0.42, 0.72, 1.0, 0.72, 0.42][index]
                        amplitude = min(1, max(0, level)) * profile
                    }
                    let height = ((2 + 14 * amplitude) * scale).rounded() / scale
                    let y = (((size.height - height) / 2) * scale).rounded() / scale
                    let bar = CGRect(x: CGFloat(index) * 4, y: y, width: 2, height: height)
                    context.fill(
                        Path(roundedRect: bar, cornerRadius: 1),
                        with: .color(theme.accent)
                    )
                }
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityLabel(working ? "Processing" : "Listening, voice level")
    }

    private var theme: ContextTheme {
        ContextTheme(scheme: colorScheme, primaryHex: primaryColor)
    }
}

/// The offer before you ask for it: the meter, and the key that opens it.
///
/// Two things and no third. A tab is read in the corner of an eye while you go
/// on typing, and the two questions it has to answer are whose it is and how to
/// get at it — anything else on a 46pt surface is a thing to decode rather than
/// recognise.
///
/// The key is the modifier's glyph alone. The hotkey is configurable and reads
/// "Right ⌘" in the settings, which does not fit; which side it is is written
/// on the panel, where there is room for a sentence about it.
private struct TabContent: View {
    /// Whether the decode is worth a second look. The panel washes amber for
    /// this; a tab has no room for a wash, so it takes the edge and a pip.
    let warned: Bool

    @EnvironmentObject private var model: PillModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: PillMetrics.tabGap) {
            ContextMeter(level: 0.55)
            if warned {
                Circle()
                    .fill(theme.caution)
                    .frame(width: 7, height: 7)
            }
            if !model.hotkey.isEmpty {
                Text(model.shownHotkey)
                    .font(.system(size: PillMetrics.tabKeyText, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.foreground)
                    .fixedSize()
                    .frame(
                        minWidth: PillMetrics.holdKeycapWidth(model.shownHotkey) - 12,
                        minHeight: PillMetrics.tabKeyHeight
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(theme.controlFill)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .strokeBorder(theme.controlEdge, lineWidth: 0.5)
                            )
                    )
            }
        }
        .padding(.horizontal, PillMetrics.tabPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The whole tab, not just the mark and keycap. `contentShape` is what makes
        // the gaps between them part of the target — the same reason the chips
        // carry one.
        .contentShape(Rectangle())
        .onTapGesture { model.onTab?() }
    }

    private var theme: ContextTheme {
        ContextTheme(scheme: colorScheme, primaryHex: model.primaryColor)
    }

}

private struct RecordingContent: View {
    let level: Float
    /// What this recording is for, when it is not dictation.
    var label: String?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.contextPrimaryColor) private var primaryColor

    /// The whole recording state, in the shape it ends in.
    ///
    /// The label stays put while the real microphone level moves only the five
    /// bars. Silence therefore still reads as an active listening state, and
    /// speech is visible as a change from its near-flat two-point baseline.
    var body: some View {
        HStack(spacing: PillMetrics.listeningGap) {
            ContextMeter(level: Double(level))
            Text("Listening")
                .font(.system(size: 12))
                .foregroundStyle(theme.foreground)
                .fixedSize()
            if let label {
                // In the highlight the offer uses for the same job, because it
                // is the same claim: these words, the ones sitting in that
                // colour in your document, are what is about to change.
                Text(label)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.foreground)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 5)
                    .padding(.vertical, PillMetrics.selectionPadding)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(theme.accent.opacity(0.16))
                    )
                    .frame(maxWidth: PillMetrics.editWidth, alignment: .leading)
            }
        }
        .padding(.horizontal, PillMetrics.tabPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var theme: ContextTheme {
        ContextTheme(scheme: colorScheme, primaryHex: primaryColor)
    }
}

/// Where the words are going, on a tab with no line under it.
///
/// Smaller than the 22 the pill used to draw it at: this sits in a 27pt tab
/// beside an 18pt voice mark, and 22 filled it edge to edge.
private struct AppIconMark: View {
    let icon: NSImage

    var body: some View {
        Image(nsImage: icon)
            .resizable()
            .interpolation(.high)
            .frame(width: PillMetrics.tabIcon, height: PillMetrics.tabIcon)
    }
}

/// The voice mark standing full while the app works on what it heard.
///
/// No sentence, because there is no room for one and none needed: a full mark
/// says the words are in and something is being done with them, which is the
/// whole of what "Thinking…" said.
private struct WorkingContent: View {
    let message: String
    /// Which way the surface hangs. `.free` is the tab with no line under it.
    let dock: Dock
    /// Where the words are going, shown only on a tab that hangs off nothing.
    /// See `RecordingContent.body`.
    var icon: NSImage?

    var body: some View {
        HStack(spacing: PillMetrics.tabGap) {
            ContextMeter(level: 1, working: true)
            if dock == .free, let icon {
                AppIconMark(icon: icon)
            }
            Text(message)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: PillMetrics.editWidth, alignment: .leading)
        }
        .padding(.horizontal, PillMetrics.tabPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// A notice: one sentence, and the dot that says how it went.
private struct MessageContent: View {
    let message: String
    let tone: NoticeTone

    var body: some View {
        HStack(spacing: PillMetrics.gap) {
            ToneDot(tone: tone)

            Text(message)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, PillMetrics.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An alert's markdown, in the two shapes the pill draws.
///
/// Its own splitter rather than `Markup` or `ReleaseNotes`: both hand back one
/// rendered thing, and this needs the code block apart, as a click target.
enum AlertBlock: Equatable {
    case text(String)
    case code(String)

    static func split(_ markdown: String) -> [AlertBlock] {
        var blocks: [AlertBlock] = []
        var paragraph: [String] = []
        var code: [String] = []
        var fenced = false

        func endParagraph() {
            let joined = paragraph.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            paragraph = []
            if !joined.isEmpty { blocks.append(.text(joined)) }
        }

        for line in markdown.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if fenced {
                    blocks.append(.code(code.joined(separator: "\n")))
                    code = []
                } else {
                    endParagraph()
                }
                fenced.toggle()
                continue
            }
            if fenced {
                code.append(line)
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                endParagraph()
            } else {
                paragraph.append(line)
            }
        }
        if fenced, !code.isEmpty { blocks.append(.code(code.joined(separator: "\n"))) }
        endParagraph()
        return blocks
    }

    /// Inline-only: the block parser takes a paragraph's own newlines out.
    static func inline(_ source: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        guard var parsed = try? AttributedString(markdown: source, options: options) else {
            return AttributedString(source)
        }
        let spans = parsed.runs.filter {
            $0.inlinePresentationIntent?.contains(.code) == true
        }.map(\.range)
        for span in spans {
            parsed[span].font = .system(size: 11, design: .monospaced)
        }
        return parsed
    }
}

/// Why something could not run, at length.
private struct AlertContent: View {
    let markdown: String
    let tone: NoticeTone
    /// A value, not the model: `height` hosts this with no environment object.
    var fraction: CGFloat = 1
    var onClose: (() -> Void)?

    private var blocks: [AlertBlock] { AlertBlock.split(markdown) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            bar

            HStack(alignment: .top, spacing: PillMetrics.gap) {
                ToneDot(tone: tone)
                    .padding(.top, 3)
                VStack(alignment: .leading, spacing: PillMetrics.alertGap) {
                    ForEach(blocks.indices, id: \.self) { index in
                        switch blocks[index] {
                        case .text(let source): paragraph(source)
                        case .code(let code): AlertCode(code: code)
                        }
                    }
                }
                AlertClose { onClose?() }
            }
            .padding(.horizontal, PillMetrics.padding)
            .padding(.vertical, PillMetrics.alertPad)
        }
    }

    private func paragraph(_ source: String) -> some View {
        Text(AlertBlock.inline(source))
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var bar: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(tone.color.opacity(0.75))
                .frame(width: max(0, geo.size.width * fraction))
                // The empty part grows from the left edge. Flip this to
                // `.leading` for the usual direction.
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: PillMetrics.alertBar)
        .background(Color.white.opacity(0.08))
    }

    /// What this surface asks for at `width`. Laid out rather than added up
    /// from font metrics, so the panel is sized with what the content takes.
    static func height(markdown: String, tone: NoticeTone, width: CGFloat) -> CGFloat {
        // No `onClose`: nothing is clicked while this is being measured.
        let view = AlertContent(markdown: markdown, tone: tone).frame(width: width)
        let fitting = NSHostingView(rootView: view).fittingSize.height
        return max(PillMetrics.height, ceil(fitting))
    }
}

/// The way out before the clock runs out.
private struct AlertClose: View {
    let close: () -> Void

    @State private var hot = false

    var body: some View {
        Image(systemName: "xmark")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(hot ? Color.primary : Color.secondary)
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
            .onHover { hot = $0 }
            .onTapGesture(perform: close)
    }
}

/// A fenced code block. One click copies it.
private struct AlertCode: View {
    let code: String

    @State private var copied = false

    private static let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)

    var body: some View {
        HStack(alignment: .top, spacing: PillMetrics.gap) {
            Text(code)
                .font(.system(size: 11, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Text(copied ? "Copied" : "Copy")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(copied ? Parrot.leaf : Color.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Self.shape.fill(Color.primary.opacity(0.09)))
        .contentShape(Self.shape)
        .onTapGesture { copy() }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        Log.write("alert: copied a code block")
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}

/// What can be done to the words that just landed, one chip per command.
///
/// Chips rather than a sentence, because the pill now sits under those words:
/// they are the subject, so this only has to name what can be done to them.
/// The old wording — "Wrong? Right ⌘ to fix it" — was a whole question because
/// it appeared at the bottom of the screen with no connection to anything.
///
/// Each chip carries a letter. This is the one pill state that is not news
/// about something that already happened — it is a thing you can still do — and
/// that difference has to be visible before the words are read.
private struct OfferContent: View {
    @Environment(\.tourHighlightedCommand) private var tourHighlightedCommand
    @EnvironmentObject private var model: PillModel
    @Environment(\.colorScheme) private var colorScheme
    let commands: [OfferedCommand]
    let headline: Headline?
    /// What the decoder made of the dictation. See `Confidence.Reading`.
    var reading = Confidence.Reading()

    /// Every other chip's lettering.
    ///
    /// `.secondary` was what this used to be, and on a dark capsule that is
    /// grey: the commands read as unavailable, which is the one thing they are
    /// not. Not white either — white is where the lit chip goes, and there
    /// would be nothing left for the pointer to say.
    private var restingText: Color { theme.foreground }

    private var theme: ContextTheme {
        ContextTheme(scheme: colorScheme, primaryHex: model.primaryColor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PillMetrics.blockGap) {
            if let warning = reading.warning { self.warning(warning) }
            if !reading.words.isEmpty { words }
            selection
            learn
            choose
            // Over the chips when there is anything above them, and over the
            // way out whenever it is drawn. `PillMetrics.rules` counts these
            // two conditions so the surface is measured for what it draws.
            if headline?.ownsARow == true || !reading.isEmpty, !commands.isEmpty { rule }
            // An empty chip block still takes a `blockGap` from the stack above
            // it, which nothing budgets for. The selector is the one offer with
            // no chips, and it is measured for the rows it draws.
            if !commands.isEmpty { chips }
            learnFooter
            if showsHold { rule }
            hold
        }
        // The whole block is centred in the pill's height, so this lands as air
        // above the sentence rather than being split between the two rows.
        // `PillMetrics.height(for:width:)` adds the same number.
        .padding(.top, reading.isEmpty ? 0 : PillMetrics.sentenceTop)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// What was dictated, each word in the colour of how sure the decoder was.
    ///
    /// Above the chips rather than beside them: it is the thing the chips are
    /// about, and it is the one part of this surface you read rather than aim
    /// at. Truncated rather than scrolled — the pill takes no keyboard focus and
    /// there is nothing to scroll it with.
    ///
    /// Centred, unlike everything else on the pill. The chips are a row you aim
    /// at and they start where every other pill's contents start; this is the
    /// sentence the pill is about, and it sits in the middle of the surface it
    /// gave its width to.
    private var words: some View {
        confidenceSentence(reading.words)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .multilineTextAlignment(.center)
            .lineLimit(PillMetrics.sentenceLines)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, PillMetrics.padding)
    }

    /// Confidence keeps its amber/scarlet signal in both appearances, while
    /// words the decoder is sure of use this surface's actual foreground.
    /// `Confidence.sentence` predates an adaptive pill and deliberately ends
    /// its ramp in off-white, which disappears on the platinum surface.
    private func confidenceSentence(_ words: [Confidence.Word]) -> Text {
        words.enumerated().reduce(Text(verbatim: "")) { line, item in
            let gap = item.offset > 0 ? Text(verbatim: " ") : Text(verbatim: "")
            let tint: Color
            if let score = item.element.score {
                tint = score >= Confidence.sure ? theme.foreground : Confidence.tint(score)
            } else {
                tint = theme.muted.opacity(0.72)
            }
            return line + gap + Text(verbatim: item.element.text).foregroundStyle(tint)
        }
    }

    /// Why this dictation is worth a second look, above everything else on the
    /// pill.
    ///
    /// With the caution dot the notices use, and centred like the sentence:
    /// the chips are a row you aim at, and both of these are things you read.
    /// A warning off to one side of a pill that is mostly empty reads as a
    /// label on the surface rather than as what the surface is about.
    private func warning(_ text: String) -> some View {
        HStack(spacing: PillMetrics.gap) {
            ToneDot(tone: reading.stopped ? .failure : .caution)
            Text(text)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(reading.stopped ? theme.failure : theme.caution)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, PillMetrics.padding)
    }

    /// Edge to edge, unlike everything else on the panel, which carries
    /// `PillMetrics.padding` either side. A rule inset from the sides reads as
    /// an underline belonging to the block above it; one that runs the full
    /// width reads as a seam between two blocks, which is what it is.
    private var rule: some View {
        Rectangle()
            .fill(PillMetrics.ruleTint)
            .frame(maxWidth: .infinity)
            .frame(height: PillMetrics.rule)
    }

    /// The words the offer is about, wearing the highlight they wear in the
    /// field.
    ///
    /// Shown rather than described. "the selection" answered a question nobody
    /// was asking — the doubt is never *whether* there is a selection, it is
    /// which words are about to change, and the only exact answer to that is
    /// the words. It also asks the accessibility layer for nothing, which is
    /// why it survives where pointing at the span did not: web content will not
    /// say where a span is, only where the box holding it is.
    ///
    /// The app's own blue, not a neutral fill. Those words are sitting in that
    /// colour two lines above, so the pill says "these ones" by matching. This
    /// is the one place colour goes inside a surface here — `parrotSurface`
    /// keeps it on the rim, because "a surface washed in a feather is a surface
    /// you have to read text off" — and it earns the exception by being a
    /// quotation mark rather than decoration.
    @ViewBuilder private var selection: some View {
        if case .selection(let words) = headline {
            HStack(spacing: PillMetrics.gap - 4) {
                Text(PillMetrics.editLead)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.muted)
                Text(words)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.foreground)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 5)
                    .padding(.vertical, PillMetrics.selectionPadding)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(theme.accent.opacity(0.16))
                    )
            }
            .padding(.horizontal, PillMetrics.padding)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    /// The sentence, written once, with the two options stacked where the
    /// unsettled words go.
    ///
    /// The prose is centred on the stack, not sat on its first row: the sentence
    /// has to read as one line with the choice standing in it. The prose is dim
    /// and the options are bright, so the line reads as context around the words
    /// being asked about.
    ///
    /// Nothing is marked. Nothing has been typed yet, so neither option has a
    /// claim the other lacks, and the click is the answer.
    @ViewBuilder private var choose: some View {
        if case .choose(let it) = headline {
            VStack(alignment: .leading, spacing: PillMetrics.chooseGap) {
                PillHeading(title: PillMetrics.chooseLead, detail: it.count, theme: theme)
                // At the width `PillMetrics.chooseWidth` measured, which the
                // builder already shrank the window to fit. The line limit is
                // the net under it.
                HStack(spacing: PillMetrics.chooseWordGap) {
                    if !it.before.isEmpty { prose(it.before) }
                    VStack(alignment: .leading, spacing: PillMetrics.chooseChipGap) {
                        ForEach(Array(it.options.enumerated()), id: \.offset) { row in
                            option(row.element, index: row.offset)
                        }
                    }
                    if !it.after.isEmpty { prose(it.after) }
                }
                .lineLimit(1)
                .fixedSize()
            }
            .padding(.horizontal, PillMetrics.padding)
            .padding(.top, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A run of the sentence either side of the stack. Dim: it is what places
    /// the words, not what is being asked.
    private func prose(_ run: String) -> some View {
        Text(run)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(theme.muted)
    }

    /// One option, drawn as a chip is: a shimmering key, the word, a capsule.
    ///
    /// A tap gesture rather than a `Button`, and `contentShape` over the whole
    /// capsule, for the reason the chip row gives: the pill is never the key
    /// window and SwiftUI draws controls in one at reduced emphasis.
    private func option(_ word: String, index: Int) -> some View {
        let lit = model.selected == index
        return HStack(spacing: 6) {
            OfferKeyCap(key: "\(index + 1)", lit: lit)
            Text(word)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .fixedSize()
        }
        .foregroundStyle(theme.foreground)
        .padding(.horizontal, 7)
        .frame(height: PillMetrics.chooseChipHeight)
        .background {
            RoundedRectangle(cornerRadius: 4)
                .fill(lit ? theme.accent.opacity(0.17) : theme.controlFill)
                .overlay {
                    RoundedRectangle(cornerRadius: 4).strokeBorder(
                        lit ? theme.accent : theme.controlEdge, lineWidth: 1
                    )
                }
        }
        .contentShape(RoundedRectangle(cornerRadius: 4))
        .onTapGesture { model.onPick?(index) }
        .onHover { over in if over { model.selected = index } }
    }

    /// The correction, with everything that did not change pushed back.
    ///
    /// One `Text` and not an `HStack`, so it wraps as a sentence rather than
    /// as boxes that each keep their width.
    @ViewBuilder private var learn: some View {
        if case .learn(let it) = headline {
            let face = Font.system(size: 14, weight: .medium)
            let mono = Font.system(size: 14, weight: .semibold, design: .monospaced)
            VStack(alignment: .leading, spacing: 16) {
                PillHeading(title: "Learn this spelling?", theme: theme)
                (
                    Text(it.lead).font(face).foregroundColor(theme.muted)
                    + Text(it.heard).font(mono.weight(.medium)).foregroundColor(theme.muted)
                        .strikethrough(true, color: Self.struck)
                    + Text(" ").font(face)
                    + Text(it.term).font(mono).foregroundColor(theme.foreground)
                    + Text(it.after).font(face).foregroundColor(theme.muted)
                )
                .lineLimit(2)
                .truncationMode(.tail)
            }
            .padding(.horizontal, PillMetrics.padding)
            .padding(.top, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var learnFooter: some View {
        if case .learn = headline {
            Text("Remember it for the next dictation.")
                .font(.system(size: 10))
                .foregroundStyle(theme.muted)
                .padding(.horizontal, PillMetrics.padding)
        }
    }

    /// The only warm thing on the surface: the one mark that says "not this".
    private static let struck = Color(red: 0.64, green: 0.39, blue: 0.35)

    /// The other way out, under the chips.
    ///
    /// The chips are a short list; holding the key reaches every transform and
    /// the catch-all besides. Said on the pill because this is the one surface
    /// where the two are alternatives to each other — everywhere else the
    /// gesture is something you either know or do not.
    /// Only when a hotkey is bound. `register` unregisters before it tries, so
    /// a reload that fails leaves nothing to hold — and a fallback glyph there
    /// would name Option, which is not bound either. A row that is absent says
    /// nothing; a row naming a dead key sends somebody pressing it.
    ///
    /// `PillMetrics.offer` and `height(for:)` ask the same question before they
    /// budget for this row, so the surface is never sized for a line it does
    /// not draw.
    @ViewBuilder private var hold: some View {
        if showsHold {
            HStack(spacing: PillMetrics.holdGap) {
                Text(PillMetrics.holdLead)
                keycap(model.hotkey)
                Text(PillMetrics.holdTail)
            }
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(theme.muted)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, PillMetrics.padding)
            // Under the chips and lined up with them: on a panel pinned to a
            // character everything reads down one left edge, and a centred
            // footer under a left-aligned row reads as belonging to something
            // else.
            .frame(maxWidth: .infinity, alignment: centred ? .center : .leading)
        }
    }

    /// Sized to what it holds, with a floor. The hotkey is configurable and
    /// its name is anything from "fn" to "⌃⌥Space", so a fixed width either
    /// clips the long ones or leaves the short ones swimming. The floor and the
    /// padding are the same numbers `PillMetrics.holdKeycapWidth` measures, or
    /// the capsule is sized for a cap it does not draw.
    private func keycap(_ glyph: String) -> some View {
        Text(glyph)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(theme.foreground)
            .fixedSize()
            .padding(.horizontal, 2)
            .frame(minWidth: 20, minHeight: PillMetrics.holdKeycapHeight)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(theme.controlFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(theme.foreground.opacity(0.25), lineWidth: 0.5)
                    )
            )
    }

    /// Whether this is the three-row shape, which is centred throughout.
    private var centred: Bool { headline?.isSelection == true }

    private var isLearn: Bool {
        if case .learn = headline { return true }
        return false
    }

    /// The same question `PillMetrics` asked when it sized the surface.
    private var showsHold: Bool {
        PillMetrics.showsHold(headline, hotkey: model.hotkey)
    }

    /// Answers belong at the end of the question, not under its first word.
    private var chipAlignment: Alignment {
        if case .learn = headline { return .leading }
        return centred ? .center : .leading
    }

    private var chipStack: HorizontalAlignment {
        if case .learn = headline { return .leading }
        return centred ? .center : .leading
    }

    /// The chips, in the rows `PillMetrics.chipRows` laid them into.
    ///
    /// Drawn from that answer rather than laid out again here, because the
    /// surface was sized from it: a view that wrapped on its own would wrap at
    /// a width the panel was not built for, and the last chip would hang over
    /// the end.
    private var chips: some View {
        let lead: CGFloat
        switch headline {
        case .landing(let words): lead = PillMetrics.title(words) + PillMetrics.gap
        case .learn: lead = 0
        default: lead = 0
        }
        let rows = PillMetrics.chipRows(commands, lead: lead)
        return VStack(alignment: chipStack, spacing: PillMetrics.chipRowGap) {
            ForEach(Array(rows.enumerated()), id: \.offset) { number, row in
                HStack(spacing: 4) {
                    if number == 0, case .landing(let words) = headline {
                        Text(words)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(NoticeTone.caution.color)
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.trailing, PillMetrics.gap - 4)
                    }
                    if centred { Spacer(minLength: 0) }

                    ForEach(row, id: \.self) { index in
                        // A tap gesture rather than a `Button`. The pill is a
                        // `nonactivatingPanel` and is never the key window, and
                        // SwiftUI draws controls in an inactive window at
                        // reduced emphasis — so a lit chip came up washed out
                        // until the pointer landed on it, which read as nothing
                        // being lit at all. `contentShape` is what makes the
                        // whole capsule the target and not just the glyphs.
                        chip(commands[index], lit: model.selected == index)
                            .tourFocus(tourHighlightedCommand == index)
                            .contentShape(Capsule())
                            .onTapGesture { model.onPick?(index) }
                            // Light what the pointer is over, so the letter on
                            // the chip and the pointer say the same thing about
                            // the same command.
                            .onHover { over in if over { model.selected = index } }
                    }

                    if !isLearn { Spacer(minLength: 0) }
                }
            }
        }
        .padding(.horizontal, PillMetrics.padding)
        // Centred under the words it is about, left where it is the only row.
        // Three rows want one axis; one row is a thing you aim at, and a row of
        // chips that moves as the pill grows is a row you have to find again.
        .frame(maxWidth: .infinity, alignment: chipAlignment)
    }

    /// Lit carries the same leaf as a changed word and as the confirm button:
    /// they are the same claim — this is the one that will happen — so the eye
    /// learns the colour once.
    private func chip(_ command: OfferedCommand, lit: Bool) -> some View {
        HStack(spacing: 6) {
            if !command.key.isEmpty {
                OfferKeyCap(key: command.key, lit: lit)
            }
            Text(command.title)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                // One line whatever the capsule thinks. The width is measured
                // in `PillMetrics.offer`, and without this the capsule would
                // win the argument and wrap a name to two lines.
                .lineLimit(1)
                .fixedSize()
        }
        .foregroundStyle(restingText)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 4)
                .fill(lit ? theme.accent.opacity(0.17) : theme.controlFill)
                .overlay {
                    RoundedRectangle(cornerRadius: 4).strokeBorder(
                        lit ? theme.accent : theme.controlEdge, lineWidth: 1
                    )
                }
        }
    }
}

/// The keyboard equivalent inside an action. Static, outlined, and subordinate
/// to the action label.
private struct OfferKeyCap: View {
    let key: String
    let lit: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.contextPrimaryColor) private var primaryColor
    private static let radius: CGFloat = 4

    var body: some View {
        Text(key)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            // A floor rather than a width: every letter draws in the same box,
            // so the chips do not step in and out by a point as the pointer
            // moves along them.
            .frame(minWidth: 8)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background {
                RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                    .fill(lit ? theme.accent.opacity(0.12) : theme.controlFill)
                    .overlay {
                        RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                            .strokeBorder(
                                lit ? theme.accent.opacity(0.65) : theme.controlEdge,
                                lineWidth: 0.5
                            )
                    }
            }
    }

    private var theme: ContextTheme {
        ContextTheme(scheme: colorScheme, primaryHex: primaryColor)
    }
}

/// The whole of the notice's colour, in nine points.
///
/// It carries the tone alone, now that the surface behind it stays dark — so it
/// is lit rather than filled: the glow is what makes green and amber tell each
/// other apart at the edge of vision.
///
/// While thinking it walks the plumage rather than pulsing one colour: pulsing
/// is what the recording state's red dot does, and the two are now the same
/// surface seconds apart, so they must not be mistakable for each other.
struct ToneDot: View {
    let tone: NoticeTone

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The clock belongs to `WalkingDot`, which exists only while the dot is
        // walking. Held here it was a stored property, so it ticked 1.67 times
        // a second on every tone for the life of the view and `onReceive` threw
        // the ticks away.
        if tone == .thinking, !reduceMotion {
            WalkingDot()
        } else {
            Self.dot(resting)
        }
    }

    /// Thinking with the motion turned off is the first feather, held. Every
    /// other tone is its own colour.
    private var resting: Color {
        tone == .thinking ? Parrot.wheel[0] : tone.color
    }

    static func dot(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: PillMetrics.dot, height: PillMetrics.dot)
            .shadow(color: color, radius: 4)
            .shadow(color: color.opacity(0.6), radius: 9)
    }
}

/// The dot walking the plumage: the one tone that needs a clock.
private struct WalkingDot: View {
    @State private var step = 0

    private let clock = Timer.publish(every: 0.6, on: .main, in: .common).autoconnect()

    var body: some View {
        ToneDot.dot(Parrot.wheel[step % 4])
            .animation(.easeInOut(duration: 0.5), value: step)
            .onReceive(clock) { _ in step += 1 }
    }
}
