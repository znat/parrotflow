import AppKit
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
    case offer([OfferedCommand], Headline?, Confidence.Reading)
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

    var text: String {
        switch self {
        case .landing(let words), .selection(let words): return words
        }
    }

    /// Whether this is the three-row shape: the words, the chips, and the line
    /// about the key. Read by the metrics and by the view, so the two cannot
    /// disagree about which shape they are describing.
    var isSelection: Bool {
        if case .selection = self { return true }
        return false
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

final class PillModel: ObservableObject {
    @Published var state: PillState = .recording(nil)

    /// Whether the panel is on screen. False unmounts the surface.
    ///
    /// An ordered-out panel still commits its layers. The rim's angle animates
    /// a conic gradient, which is rasterised on the CPU every frame — so an
    /// offer left mounted under a hidden panel measured at 57% of a core with
    /// nothing on screen. The state does not stop it: nothing clears `state`
    /// on the way out, and `.offer` means a rim that turns.
    @Published var onScreen = true

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

    /// Which command the pointer is on, if any.
    ///
    /// Nil when it is on none, which is how the offer arrives. This is only
    /// ever the pointer's mark and it does not outlive the pointer — leaving
    /// the pill clears it. Nothing runs without a click, so a chip lit before
    /// you have touched anything is saying something about a command that is
    /// not about to happen.
    @Published var selected: Int?

    /// Clicking a command, and the pointer coming and going. Closures rather
    /// than published state: they are messages out of the view, and nothing
    /// about them should redraw it.
    var onPick: ((Int) -> Void)?
    var onHover: ((Bool) -> Void)?
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
    /// Thinning out on a deadline, rather than holding and then going. Only the
    /// offer does this — see `decay(over:)`.
    private var isDecaying = false
    /// How long the offer on screen was given, so the pointer can give it again.
    private var offerFor: TimeInterval?
    /// A decay standing still, as against one whose alpha is moving.
    ///
    /// True through the hold, and again once the pointer stops the fade. The
    /// two end differently. A still one sits at `offerAlpha`, which is a real
    /// strength, so it can fade out the way every other state does. A moving
    /// one has already told AppKit to finish at zero, so a fade laid over it
    /// has nothing left to move and it is cut instead.
    private var decayIsStill = false
    /// Which decay is the live one.
    ///
    /// Replacing an animation makes the one it replaced call its completion
    /// handler, straight away. A flag alone cannot tell those apart: the decay
    /// that replaces it sets `isDecaying` back to true before the old handler
    /// runs, so the old handler passes the guard and orders the panel out. That
    /// was the pointer dismissing the offer it was there to hold open. The
    /// handler checks this number as well, and a stale one does nothing.
    private var decayRun = 0
    /// The offer's fade, waiting out the hold. See `decay(over:)`.
    private var pendingDecayFade: DispatchWorkItem?

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
        PillMetrics.panelSize(for: model.state, hasIcon: model.appIcon != nil)
    }

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

    /// What you can do about the text that just landed, and for how long.
    ///
    /// The highlight is cleared first. It belonged to the last offer's pointer,
    /// and the pointer is not on this one yet.
    ///
    /// This is the one state that leaves by going quiet rather than by
    /// disappearing. Every other one holds full strength and then goes. This
    /// one stands at full strength for `PillHUD.offerHold` and then thins out
    /// over `PillHUD.offerFade`, because it is the only state with a deadline
    /// you might want to beat: a hard cut gives you the time and then nothing,
    /// while a fade says how long is left without a clock on screen, and stays
    /// usable to the last frame. The keys and the chips work the whole way
    /// down; the fading only says how long is left.
    func offer(
        _ commands: [OfferedCommand], headline: Headline? = nil,
        reading: Confidence.Reading = Confidence.Reading(), for duration: TimeInterval
    ) {
        model.selected = nil
        offerFor = duration
        set(.offer(commands, headline, reading))
        decay(over: duration)
    }

    /// Hold at `Self.offerAlpha` for what is left after the fade, then run
    /// out over `Self.offerFade`, then gone.
    ///
    /// The hold comes first because the offer is read before it is answered.
    /// A surface that starts thinning on the frame it appears is one you read
    /// against the clock; one that stands still first is one you read, and
    /// only then decide about.
    ///
    /// The fade is linear on purpose. An eased fade spends most of its time
    /// near the ends and crosses the middle quickly, which reads as the
    /// surface being yanked away at the halfway mark. A straight ramp is the
    /// one shape that says "this is running out" at a steady rate — a clock
    /// without a clock.
    private func decay(over duration: TimeInterval) {
        guard let panel else { return }
        pendingDismiss?.cancel(); pendingDismiss = nil
        pendingDecayFade?.cancel(); pendingDecayFade = nil
        isFading = false
        isDecaying = true
        decayIsStill = true
        decayRun += 1
        let run = decayRun

        // Land on the starting strength at once, cancelling whatever was
        // animating alpha. Usually nothing — the offer follows a pill already
        // on screen — but raised from cold, `set` has just put it at full, and
        // this is what takes it down to the offer's own strength.
        if !panel.isVisible {
            model.onScreen = true
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = Self.offerAlpha
        }

        let fade = min(Self.offerFade, duration)
        let hold = max(0, duration - fade)
        let start = DispatchWorkItem { [weak self] in
            self?.runOut(panel, over: fade, run: run)
        }
        pendingDecayFade = start
        DispatchQueue.main.asyncAfter(deadline: .now() + hold, execute: start)
    }

    /// The second half of the decay: the alpha finally moves.
    private func runOut(_ panel: NSPanel, over fade: TimeInterval, run: Int) {
        // `decayRun` and not `isDecaying` alone: see the property.
        guard isDecaying, decayRun == run else { return }
        pendingDecayFade = nil
        decayIsStill = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fade
            context.timingFunction = CAMediaTimingFunction(name: .linear)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, self.isDecaying, self.decayRun == run else { return }
            self.isDecaying = false
            self.decayIsStill = false
            // The aim belonged to the dictation that has just ended, the same
            // as in `fadeOut`.
            self.near = nil
            panel.orderOut(nil)
            self.model.onScreen = false
            // Back to full strength while off screen, or the next appearance
            // starts from a panel that is already invisible and stays that way.
            panel.alphaValue = 1
        }
    }

    /// Hold the offer at full strength, or let it start running out again.
    ///
    /// The pointer resting on the pill is the least ambiguous statement there
    /// is that you are still deciding, so the fade stops entirely rather than
    /// resetting — and starts again from the beginning when the pointer leaves.
    /// A surface that went on thinning while you were reaching for it would be
    /// arguing with you about whether you had finished.
    ///
    /// This is also why the offer can stand at full strength the way it does.
    /// Clutter that bright would be too much to put on screen after every
    /// dictation if reading it did not put the whole clock back.
    func hovering(_ inside: Bool) {
        // `isVisible` as well as the flag: a decay that finished a moment ago
        // has taken the panel out, and nothing about the pointer should bring
        // an offer that is over back onto the screen.
        guard let panel, panel.isVisible, let offerFor, isDecaying || inside else { return }
        if inside {
            // Stop the running decay without letting its completion fire: the
            // animation below replaces it, and a replaced animation calls its
            // handler at once.
            decayRun += 1
            pendingDecayFade?.cancel(); pendingDecayFade = nil
            isDecaying = true
            decayIsStill = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                panel.animator().alphaValue = Self.offerAlpha
            }
        } else {
            decay(over: offerFor)
        }
    }

    /// Where the offer starts, and stands through the hold: full strength.
    ///
    /// It was 0.92 — quieter than the other states, because it is the one
    /// surface that appears without being asked for. That made the chips on it
    /// hard to read at the moment they are meant to be read, and the fade
    /// already says the offer is optional.
    static let offerAlpha: CGFloat = 1

    /// How long the offer stands still before it starts running out.
    static let offerHold: TimeInterval = 4
    /// How long it takes to go, once it starts.
    static let offerFade: TimeInterval = 2
    /// The whole of the offer's life, hold and fade.
    static let offerLife: TimeInterval = offerHold + offerFade

    /// The pill's own visible capsule right now — what a click has to land
    /// inside of to count as a click on the pill rather than a click past it.
    /// Nil while there is no pill up, so a caller cannot mistake the frame it
    /// was last shown at for one it is still shown at.
    ///
    /// `panel.frame` inset by `bleed`, not `panel.frame` itself: the window is
    /// bigger than the capsule on every side, for the glow to spill into — see
    /// `PillMetrics.bleed`. That margin is fully transparent, and the pill
    /// often sits right beside the words you are about to click into, so a
    /// click meant to land past it can easily fall inside that invisible
    /// window without landing anywhere near the capsule you can see. Counting
    /// that as "on the pill" is why a click there used to look like it did
    /// nothing.
    var frame: NSRect? {
        guard let panel, panel.isVisible else { return nil }
        return panel.frame.insetBy(dx: PillMetrics.bleed, dy: PillMetrics.bleed)
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

        if panel == nil { build() }
        guard let panel else { return }

        // A fade that has not finished is a panel that is still on screen. Put
        // it back to full strength rather than morphing something half gone.
        // The same for a decay, which is a fade with a longer clock on it: a
        // pill part-way through running out that then has something to say
        // would otherwise say it at whatever strength it had got down to.
        if isFading || isDecaying {
            isFading = false
            isDecaying = false
            decayIsStill = false
            // The decay's handler is now a stale one. See `decayRun`.
            decayRun += 1
            pendingDecayFade?.cancel(); pendingDecayFade = nil
            // Zero-length rather than a plain assignment: that is what stops
            // the animation underneath, which would otherwise go on pulling
            // the alpha down under the state that has just replaced it.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                panel.animator().alphaValue = 1
            }
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
        if arriving {
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { model.state = state }
        } else {
            withAnimation(.easeInOut(duration: Self.motion)) {
                model.state = state
            }
        }

        // The pill ignores the mouse in every state but this one. It sits over
        // whatever you are working in, so a surface that swallowed clicks for
        // the length of a dictation would be a hole in your screen — but the
        // offer is made of buttons, and a button you cannot click is a picture
        // of a button.
        if case .offer = state {
            panel.ignoresMouseEvents = false
        } else {
            panel.ignoresMouseEvents = true
            // No offer, nothing for the pointer to hold: `hovering` reads this
            // and must not act on a duration left behind by the last one.
            offerFor = nil
        }

        let size = wantedSize

        if !arriving {
            morph(to: size)
        } else {
            panel.setContentSize(size)
            panel.setFrameOrigin(anchor(size))
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
        guard let panel, panel.isVisible, !isFading else { return }

        // A decision takes the offer at once rather than letting the rest of
        // its decay play out. Escape, Return and running a command all arrive
        // here, and a dismissal that took another few seconds to show would
        // read as the key not working.
        //
        // A moving decay is cut, because its alpha is already on its way to
        // zero and a fade laid over that has nothing left to move. A decay
        // standing still is not — in its hold, or stopped there by the pointer
        // — because it sits at `offerAlpha`, so it goes out the way every
        // other state does. Clicking a chip is the common
        // path and the pointer is on the pill by definition, so that is the
        // one that must not blink out. The stale handler is seen off the same
        // way as in `set`.
        if isDecaying, !decayIsStill {
            isDecaying = false
            decayRun += 1
            pendingDecayFade?.cancel(); pendingDecayFade = nil
            near = nil
            // A zero-length animation is how the running one is stopped, and
            // it leaves the panel at full strength for the next appearance.
            // Nothing is drawn at that strength: the panel goes out in the
            // same turn.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                panel.animator().alphaValue = 1
            }
            panel.orderOut(nil)
            model.onScreen = false
            return
        }
        // Nothing is decaying past this line. A held decay is standing at a
        // real alpha, so it leaves as an ordinary fade — and either way the
        // flags and the handler are seen off before that fade starts.
        isDecaying = false
        decayIsStill = false
        decayRun += 1
        pendingDecayFade?.cancel(); pendingDecayFade = nil

        isFading = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.motion
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
        let frame = NSRect(origin: anchor(size), size: size)
        guard frame != panel.frame else { return }
        defer { logFrame("moved") }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.motion
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    /// Builds the panel before anything is waiting on it.
    ///
    /// An NSPanel, an NSHostingView and the glass container, all on the main
    /// thread. Measured at 219 ms on the first press of a launch, between the
    /// key going down and the pill appearing. Every press after it cost 25 ms.
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
        let capsule = panel.frame.insetBy(dx: PillMetrics.bleed, dy: PillMetrics.bleed)
        let screen = NSScreen.screens.firstIndex { $0.frame.intersects(panel.frame) }
        Log.write(String(
            format: "pill: %@ at %.0f,%.0f %.0fx%.0f on screen %@%@",
            what, capsule.minX, capsule.minY, capsule.width, capsule.height,
            screen.map(String.init) ?? "none",
            model.onScreen ? "" : " — but the surface is unmounted"
        ))
    }

    private func build() {
        let hosting = NSHostingView(rootView: PillView().environmentObject(model))
        hosting.frame = NSRect(origin: .zero,
                               size: PillMetrics.panelSize(for: .recording(nil), hasIcon: false))
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

        // Real glass under the capsule. See `ParrotGlass` for why AppKit has to
        // do this and SwiftUI cannot — and why it is masked rather than left to
        // fill the window, which here would frost the margin the glow lives in.
        //
        // Still here under a near-black capsule, because the capsule is 95%
        // opaque and this is what the last 5% shows. A blurred hint of the
        // desktop is what makes the surface read as sitting over something; the
        // desktop itself, unblurred, would read as the surface being thin.
        let container = ParrotGlass.container(
            hosting, radius: PillMetrics.height / 2, inset: PillMetrics.bleed,
            // Barely tinted. The pill is glanced at over whatever you are
            // reading, and the less of that it takes away the better.
            tint: NSColor.black.withAlphaComponent(0.10)
        )

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
        panel.adoptParrotAppearance()
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
    private func anchor(_ size: NSSize) -> NSPoint {
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
            else { return panel?.frame.origin ?? .zero }
            return beside(near.rect, size: size, on: visible)
        }
        guard let visible = screenUnderPointer()?.visibleFrame
        else { return panel?.frame.origin ?? .zero }
        return NSPoint(x: visible.midX - size.width / 2,
                       y: visible.minY + 96 - PillMetrics.bleed)
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
    /// The row is the caret's; the column is not. Two versions of this chased
    /// the horizontal position — centred on the text, then aligned to where it
    /// starts — and both moved for reasons invisible from outside: what an app
    /// returns for a range is a line in one app and a cell in another, a
    /// wrapped sentence starts somewhere other than where it appears to, and a
    /// terminal's column width can only be guessed. Correct each time,
    /// arbitrary-looking every time. The left edge of the pane is not where the
    /// caret is and is the same place on every dictation, which is the property
    /// that matters for something on screen for two seconds.
    ///
    /// `bleed` is taken off because it is transparent: what has to line up with
    /// the pane is the capsule, not the window the glow spills into.
    private func beside(_ target: NSRect, size: NSSize, on visible: NSRect) -> NSPoint {
        let gap: CGFloat = 10

        var y = target.minY - gap - size.height + PillMetrics.bleed
        if y < visible.minY {
            y = target.maxY + gap - PillMetrics.bleed
        }
        let x = target.minX - PillMetrics.bleed

        return NSPoint(
            x: min(max(x, visible.minX), visible.maxX - size.width),
            y: min(max(y, visible.minY), visible.maxY - size.height)
        )
    }
}

// MARK: - Metrics

enum PillMetrics {
    static let height: CGFloat = 42

    /// Transparent margin between the capsule and the edge of the window.
    ///
    /// The glow is drawn by blurring the rim, and a blur has to have somewhere
    /// to go. The panel used to be exactly the size of the capsule, so anything
    /// spilling outward was cut off square at the window edge — which is the
    /// one artefact that gives a floating surface away as a window.
    ///
    /// It costs nothing: the margin is fully transparent and the panel ignores
    /// the mouse, so a wider window is not a bigger target for anything.
    /// `width(for:)` and `height` stay the size of the capsule you can see;
    /// `panelSize` is what the window is set to.
    /// Wide enough for the widest blur's tail to reach zero before the window
    /// ends.
    ///
    /// At 24 it did not: the outer layer was cut off while still bright, which
    /// reads as a second ring drawn on purpose. A Gaussian is visually gone by
    /// about twice its radius, and the widest here is 24.
    ///
    /// Kept as tight as that allows rather than as wide as possible. The window
    /// is transparent but not invisible — a faint rectangle can still be made
    /// out where its bounds are, so the less of it there is beyond the glow, the
    /// less there is to see.
    static let bleed: CGFloat = 52

    static func panelSize(for state: PillState, hasIcon: Bool) -> NSSize {
        let width = width(for: state, hasIcon: hasIcon)
        return NSSize(width: width + bleed * 2,
                      height: height(for: state, width: width) + bleed * 2)
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
    static let sentenceGap: CGFloat = 4

    /// Between the rows of an offer over a selection.
    ///
    /// Wider than `sentenceGap`, which sets the reading's lines — those are one
    /// block of text and belong together. These three are three different
    /// things: the words, what can be done to them, and the way out the chips
    /// do not cover. At 4pt they read as a paragraph rather than as a list of
    /// choices.
    static let selectionGap: CGFloat = 8

    /// What the two extra rows of a selection offer say.
    ///
    /// Here rather than in the view because the pill is measured before it is
    /// drawn, and a string measured in one place and set in another is how a
    /// chip ends up hanging over the end of a capsule. The view reads these.
    static let editLead = "Edit"
    static let holdLead = "or hold"
    static let holdTail = "and say what to change"
    /// The ⌥ keycap between the two halves of the hold line, and the gaps
    /// either side of it.
    static let holdKeycap: CGFloat = 20 + 12
    /// The highlight's own padding, either side of the words.
    static let selectionFit: CGFloat = 12

    /// Extra air above the sentence, on top of what centring the two rows
    /// already leaves. The chips sit in capsules of their own and carry their
    /// own margin with them; the sentence is bare text and read as crowded
    /// against the rim without this.
    static let sentenceTop: CGFloat = 4

    /// Past this the sentence wraps rather than the pill growing sideways. The
    /// pill sits under the line you dictated into, and one wider than the window
    /// is no longer pointing at anything.
    static let sentenceWidth: CGFloat = 640

    /// Three lines holds about 240 characters, which is the 99th percentile of
    /// the dictations in this machine's archive. Past that it truncates: the
    /// pill is on screen for seconds and a paragraph of it would cover the
    /// words it is about.
    static let sentenceLines = 3

    /// The utterance score, set under the words.
    static let readingFont: NSFont = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
    static let readingLine: CGFloat = ceil(
        NSLayoutManager().defaultLineHeight(for: readingFont)
    )

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
    static func height(for state: PillState, width: CGFloat) -> CGFloat {
        guard case .offer(_, let headline, let reading) = state else { return height }
        // A selection offer is three rows: the words, the chips, and the line
        // about the key. Two of them are extra, and they are added whatever the
        // reading says — the two can appear together, on a dictation you
        // selected part of after being warned about it.
        let extra = headline?.isSelection == true ? (sentenceLine + selectionGap) * 2 : 0
        let rows = readingRows(reading, width: width)
        guard !rows.isEmpty else { return height + extra }
        return height + extra + sentenceTop
            + rows.reduce(0, +) + sentenceGap * CGFloat(rows.count)
    }

    /// The height of each row the reading draws, top to bottom. The count is
    /// also the number of `sentenceGap`s: one between each pair, one more
    /// between the last row and the chips.
    private static func readingRows(
        _ reading: Confidence.Reading, width: CGFloat
    ) -> [CGFloat] {
        var rows: [CGFloat] = []
        if reading.warning != nil { rows.append(warningLine) }
        if !reading.words.isEmpty {
            rows.append(sentenceLine * CGFloat(lines(reading.words, width: width)))
            if reading.overall != nil { rows.append(readingLine) }
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
    /// The gap on the meter's right, 2pt tighter than the one on its left.
    ///
    /// Both were the same and did not look it. The dot is small, round and
    /// spills a little glow into its gap; the meter closes on its shortest,
    /// dimmest bar and the icon has a hard edge — so the eye measures from the
    /// last bar it can actually see to that edge, and reads that side as wider.
    /// Equal numbers, unequal gaps. These two are equal to look at.
    static let tuck: CGFloat = 8
    static let dot: CGFloat = 8
    static let icon: CGFloat = 22
    static let meter: CGFloat = 66

    static func width(for state: PillState, hasIcon: Bool) -> CGFloat {
        switch state {
        case .recording(let label): return recording(hasIcon: hasIcon, label: label)
        case .working(let message): return text(message)
        case .notice(let message, _): return text(message)
        case .offer(let commands, let headline, let reading):
            return offer(commands, headline: headline, reading: reading)
        }
    }

    /// 15 + 8 + 10 + 66 + 15, and the icon after the meter when there is one
    /// to show.
    static func recording(hasIcon: Bool, label: String? = nil) -> CGFloat {
        let base = padding * 2 + dot + gap + meter
        let width = hasIcon ? base + icon + tuck : base
        guard let label else { return width }
        return width + gap + title(label)
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
        reading: Confidence.Reading = Confidence.Reading()
    ) -> CGFloat {
        // A chip is its keycap, its words and 9pt of padding either side; then
        // 4pt between one chip and the next.
        let chips = commands.reduce(CGFloat(0)) { total, command in
            total + 18 + (command.key.isEmpty ? 0 : keycap) + title(command.title)
        }
        let lead: CGFloat
        if case .landing(let words) = headline { lead = title(words) + gap } else { lead = 0 }
        let row = padding * 2 + lead + chips
            + CGFloat(max(commands.count - 1, 0)) * 4 + rowFit
        var widest = row
        if case .selection(let words) = headline {
            widest = max(widest, min(
                sentenceWidth,
                padding * 2 + title(editLead) + gap + title(words) + selectionFit
            ))
            widest = max(widest, min(
                sentenceWidth,
                padding * 2 + title(holdLead) + holdKeycap + title(holdTail)
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

    /// The keycap on a chip: one character at 11pt bold, 4pt either side, and
    /// the 6pt between it and the words.
    static let keycap: CGFloat = 24

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
    static let chipFit: CGFloat = 2
    static let rowFit: CGFloat = 4
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

    var body: some View {
        // Nothing at all while the panel is out. See `PillModel.onScreen`.
        if model.onScreen { pill }
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
        // leaves the window. The clip is inside `parrotSurface` and the bloom,
        // which draw outside the shape on purpose.
        GeometryReader { geo in
            ZStack {
                switch model.state {
                case .recording(let label):
                    RecordingContent(level: model.level, icon: model.appIcon, label: label)
                        .transition(.opacity)
                case .working(let message):
                    MessageContent(message: message, tone: .thinking)
                        .transition(.opacity)
                case .notice(let message, let tone):
                    MessageContent(message: message, tone: tone)
                        .transition(.opacity)
                case .offer(let commands, let headline, let reading):
                    OfferContent(commands: commands, headline: headline, reading: reading)
                        .transition(.opacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipShape(Self.shape)
        }
        // The whole surface, not each chip: moving from one chip to the next
        // must not read as leaving the pill. What leaving costs is decided by
        // whoever raised the offer — see `PillModel.onHover`.
        .onHover { inside in model.onHover?(inside) }
        // Amber right through when the words may not be the words that were
        // said. The line says it, but the line is on a pill you have already
        // learned to ignore: the surface changing colour is what gets looked
        // at, and it is the same signal the caution notices use.
        // The offer turns its rim slowly, on its own: it is the one state with
        // a deadline, and the only one you are meant to answer. Slow, and with
        // the glow behind it left still, so it does not read as the busy rim.
        .parrotSurface(
            Self.shape, alive: isWorking, turning: isOffer, solid: true,
            wash: warning?.wash, wheel: warning?.wheel ?? Parrot.wheel
        )
        // Under the capsule, so it is the capsule's shape and not the glow's.
        .shadow(color: .black.opacity(0.22), radius: 7, y: 2)
        // Behind everything above it. `.background` applied last sits furthest
        // back, which is where the bloom has to be — over the fill it would be
        // a coloured film on the surface rather than light coming off the edge.
        .background {
            PlumageBloom(
                shape: Self.shape, alive: isWorking,
                wheel: warning?.wheel ?? Parrot.wheel
            )
        }
        // The transparent margin the bloom spills into. See `PillMetrics.bleed`.
        .padding(PillMetrics.bleed)
        // Bound to the state alone. The meter is fed about ten times a second
        // and must not drag a crossfade along behind it.
        .animation(.easeInOut(duration: PillHUD.motion), value: model.state)
    }

    private var isWorking: Bool {
        if case .working = model.state { return true }
        return false
    }

    private var isOffer: Bool {
        if case .offer = model.state { return true }
        return false
    }

    /// How loud this pill is, when it is an offer with something to warn
    /// about. Nil for every other state: a notice carries its tone in its dot,
    /// and this is the one surface whose meaning is not already written on it.
    ///
    /// Amber for a dictation the app is unsure of, scarlet once it has taken a
    /// Return over it — the same surface one step along, because the second
    /// state is the first one being ignored.
    private var warning: (wash: Color, wheel: [Color])? {
        guard case .offer(_, _, let reading) = model.state, reading.warning != nil else {
            return nil
        }
        return reading.stopped
            ? (Parrot.scarlet.opacity(0.26), Parrot.stopped)
            : (Parrot.amber.opacity(0.24), Parrot.warned)
    }

    /// A fixed radius, not a `Capsule`. At the pill's resting height the
    /// two are the same shape — but an offer carrying the dictated sentence is
    /// taller, and a capsule would round its ends to half of that. The glass
    /// behind it cannot follow: `ParrotGlass.backdrop` takes its corner radius
    /// once, when the panel is built. So the shape stops growing where the glass
    /// stops, and a tall pill is a rounded rectangle rather than a lozenge.
    static let shape = RoundedRectangle(cornerRadius: PillMetrics.height / 2, style: .circular)
}

private struct RecordingContent: View {
    let level: Float
    let icon: NSImage?
    /// What this recording is for, when it is not dictation.
    var label: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 0) {
            Circle()
                .fill(Parrot.scarlet)
                .frame(width: PillMetrics.dot, height: PillMetrics.dot)
                .shadow(color: Parrot.scarlet.opacity(0.7), radius: 4)
                .opacity(pulse ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)

            Meter(level: level)
                .frame(width: PillMetrics.meter, height: 14)
                .padding(.leading, PillMetrics.gap)

            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: PillMetrics.icon, height: PillMetrics.icon)
                    .padding(.leading, PillMetrics.tuck)
            }

            if let label {
                Text(label)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(white: 0.88))
                    .fixedSize()
                    .padding(.leading, PillMetrics.gap)
            }
        }
        .padding(.horizontal, PillMetrics.padding)
        // `initial: true` covers what `onAppear` did; the view stays alive
        // across recordings, so a Reduce Motion toggle mid-session needs the
        // same assignment again, not just on the first appearance.
        .onChange(of: reduceMotion, initial: true) { _, newValue in pulse = !newValue }
    }
}

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
    @EnvironmentObject private var model: PillModel
    let commands: [OfferedCommand]
    let headline: Headline?
    /// What the decoder made of the dictation. See `Confidence.Reading`.
    var reading = Confidence.Reading()

    /// The lit chip's lettering: leaf lightened almost to white, so the words
    /// stay readable over a fill of the same colour.
    private static let litText = Color(red: 0.89, green: 0.96, blue: 0.93)

    /// Every other chip's lettering.
    ///
    /// `.secondary` was what this used to be, and on a dark capsule that is
    /// grey: the commands read as unavailable, which is the one thing they are
    /// not. Not white either — white is where the lit chip goes, and there
    /// would be nothing left for the pointer to say.
    private static let restingText = Color(white: 0.88)

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: centred ? PillMetrics.selectionGap : PillMetrics.sentenceGap
        ) {
            if let warning = reading.warning { self.warning(warning) }
            if !reading.words.isEmpty {
                words
                if let overall = reading.overall { score(overall) }
            }
            selection
            chips
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
        Confidence.sentence(reading.words)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .multilineTextAlignment(.center)
            .lineLimit(PillMetrics.sentenceLines)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, PillMetrics.padding)
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
                .foregroundStyle(Color(white: 0.97))
                .lineLimit(1)
                .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, PillMetrics.padding)
    }

    /// The one number the decoder gives for the whole utterance, raw.
    ///
    /// Full strength and coloured on the utterance's own bands — see
    /// `Confidence.overallTint`. Larger than the sentence rather than smaller:
    /// it is the one thing on this pill you read at a glance instead of word
    /// by word.
    private func score(_ score: Float) -> some View {
        Text(verbatim: Confidence.overall(score))
            .font(.system(size: 14, weight: .semibold, design: .monospaced))
            .foregroundStyle(Confidence.overallTint(score))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, PillMetrics.padding)
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
                    .foregroundStyle(Color(white: 0.55))
                Text(words)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Self.quotedText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Parrot.action.opacity(0.42))
                    )
            }
            .padding(.horizontal, PillMetrics.padding)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    /// The other way out, under the chips.
    ///
    /// The chips are a short list; holding the key reaches every transform and
    /// the catch-all besides. Said on the pill because this is the one surface
    /// where the two are alternatives to each other — everywhere else the
    /// gesture is something you either know or do not.
    @ViewBuilder private var hold: some View {
        if case .selection = headline {
            HStack(spacing: 6) {
                Text(PillMetrics.holdLead)
                keycap("⌥")
                Text(PillMetrics.holdTail)
            }
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(Color(white: 0.5))
            .padding(.horizontal, PillMetrics.padding)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    /// The words on the highlight: the glass text, so they read the way the
    /// dictated sentence does two rows up rather than as white on blue.
    private static let quotedText = Color(red: 0.875, green: 0.941, blue: 0.906)

    private func keycap(_ glyph: String) -> some View {
        Text(glyph)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(Color(white: 0.72))
            .frame(width: 20, height: 17)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    )
            )
    }

    /// Whether this is the three-row shape, which is centred throughout.
    private var centred: Bool { headline?.isSelection == true }

    private var chips: some View {
        HStack(spacing: 4) {
            if case .landing(let words) = headline {
                Text(words)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(NoticeTone.caution.color)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.trailing, PillMetrics.gap - 4)
            }

            if centred { Spacer(minLength: 0) }

            ForEach(Array(commands.enumerated()), id: \.offset) { index, command in
                // A tap gesture rather than a `Button`. The pill is a
                // `nonactivatingPanel` and is never the key window, and SwiftUI
                // draws controls in an inactive window at reduced emphasis — so
                // a lit chip came up washed out until the pointer landed on it,
                // which read as nothing being lit at all. `contentShape` is what
                // makes the whole capsule the target and not just the glyphs.
                chip(command, lit: model.selected == index)
                    .contentShape(Capsule())
                    .onTapGesture { model.onPick?(index) }
                    // Light what the pointer is over, so the letter on the chip
                    // and the pointer say the same thing about the same command.
                    .onHover { over in if over { model.selected = index } }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, PillMetrics.padding)
        // Centred under the words it is about, left where it is the only row.
        // Three rows want one axis; one row is a thing you aim at, and a row of
        // chips that moves as the pill grows is a row you have to find again.
        .frame(maxWidth: .infinity, alignment: centred ? .center : .leading)
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
        .foregroundStyle(lit ? Self.litText : Self.restingText)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background {
            Capsule()
                .fill(lit ? Parrot.leaf.opacity(0.28) : Color.white.opacity(0.05))
                .overlay {
                    Capsule().strokeBorder(
                        lit ? Parrot.leaf.opacity(0.62) : .clear, lineWidth: 1
                    )
                }
        }
    }
}

/// The letter you can press, in a box with a light going round it.
///
/// The key is the only thing on the offer that is not obvious: the chips look
/// like things to click, and a click is what people did — the letters were
/// read as decoration and the offer timed out with the keyboard unused. A
/// still border did not fix that, because everything else on the pill is still
/// too. Movement is what the eye finds on a surface it is not looking at.
///
/// Slow and dim on purpose. One turn takes `turnSeconds`, so at a glance it is
/// a border and only a border; what it does is make you glance.
private struct OfferKeyCap: View {
    let key: String
    let lit: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var angle: Double = -90

    /// One trip round the border. Long enough that the light never reads as a
    /// spinner, short enough to be seen inside the offer's hold. It does not
    /// divide into the rim's `PlumageRim.slowTurn`, so the two never fall into
    /// step.
    private static let turnSeconds: TimeInterval = 3.4
    private static let radius: CGFloat = 4

    /// The border when the light is elsewhere.
    private var base: Double { lit ? 0.28 : 0.18 }

    var body: some View {
        Text(key)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            // A floor rather than a width: every letter draws in the same box,
            // so the chips do not step in and out by a point as the pointer
            // moves along them.
            .frame(minWidth: 8)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background {
                RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                    .fill(Color.white.opacity(lit ? 0.2 : 0.12))
            }
            .overlay { sheen }
    }


    /// A bright arc travelling round the box, over the resting border.
    ///
    /// The angle is animated, the same way `PlumageRim` turns the feathers —
    /// the gradient is the border rather than something masked into it. The
    /// arc is short and the rest of the ring is the resting white, so a still
    /// frame is a border and only the movement is new.
    private var sheen: some View {
        RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
            .strokeBorder(
                AngularGradient(
                    stops: [
                        .init(color: .white.opacity(base), location: 0),
                        .init(color: .white.opacity(lit ? 0.95 : 0.8), location: 0.1),
                        .init(color: .white.opacity(base), location: 0.26),
                        .init(color: .white.opacity(base), location: 1),
                    ],
                    center: .center, angle: .degrees(angle)
                ),
                lineWidth: 1
            )
            // `initial: true` covers what `onAppear` did; the view stays alive
            // across offers, so a Reduce Motion toggle mid-session needs the
            // same call again, not just on the first appearance.
            .onChange(of: reduceMotion, initial: true) { _, _ in spin() }
    }

    private func spin() {
        guard !reduceMotion else {
            withAnimation(.default) { angle = -90 }
            return
        }
        withAnimation(.linear(duration: Self.turnSeconds).repeatForever(autoreverses: false)) {
            angle = 270
        }
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

/// The bars walk the plumage as they light up, left to right, so a loud sound
/// fills the pill with the same four colours that ring every other surface.
///
/// Against the wheel's direction: sky at the quiet end, scarlet at the loud
/// one. The last bars are the ones a shout reaches, and the colour arriving
/// there should be the one that means loud.
struct Meter: View {
    let level: Float
    private let bars = 12

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<bars, id: \.self) { index in
                let threshold = Float(index + 1) / Float(bars)
                let active = level >= threshold * 0.85
                Capsule()
                    .fill(active ? feather(index) : Color.secondary.opacity(0.25))
                    .frame(width: 3, height: active ? height(for: index) : 4)
            }
        }
        .animation(.linear(duration: 0.08), value: level)
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private func feather(_ index: Int) -> Color {
        Parrot.wheel[3 - min(3, index * 4 / bars)]
    }

    private func height(for index: Int) -> CGFloat {
        // A triangle, not a diamond. The arc rose to the middle and fell away
        // again, which reads as a shape with a peak — something that has
        // already happened. Rising the whole way reads as something still
        // opening, which is what a microphone that is still listening is.
        5 + CGFloat(index) / CGFloat(bars - 1) * 12
    }
}
