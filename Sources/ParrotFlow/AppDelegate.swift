import AppKit
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var config = Config()
    private var configWatcher: FileWatcher?
    private var vocabularyWatcher: FileWatcher?
    private var transformWatchers: [FileWatcher] = []

    /// Set while a live-reload failure is waiting out its grace period —
    /// see `loadConfig(announceErrors:)`.
    private var configReloadNotice: DispatchWorkItem?

    /// How long a bad config.yaml is given to be fixed before the failure is
    /// shown. Round number, long enough to finish an edit and save again.
    static let configReloadGraceSeconds: TimeInterval = 10

    private let hotKeys = HotKeyManager()
    private let recorder = Recorder()
    private let pill = PillHUD()
    private let permissions = PermissionsWindowController()
    private let bugReport = BugReportWindow()

    private var statusItem: NSStatusItem!
    private var statusInfoItem: NSMenuItem!
    private var inputDeviceItem: NSMenuItem!
    private var permissionsItem: NSMenuItem!

    /// The recording state the menu bar parrot was last tinted for.
    private var shownRecording: Bool?

    /// Shown only while `config.problems()` has something in it.
    private var configProblemsItem: NSMenuItem!
    private var addKeyItem: NSMenuItem!

    /// What was last said out loud, so a problem is announced when it appears
    /// and not on every save of an unrelated setting.
    private var announcedProblems: [String] = []

    /// What went wrong with the last recording, held until one goes right.
    ///
    /// A notice fades after four seconds, and the failure this exists for is
    /// one you find out about by looking up from what you were dictating into.
    /// AirPods connect and disconnect on their own all day, so the state that
    /// matters is "the last thing you said was not recorded" — and it has to
    /// still be on screen when you go looking for it. Shown in the menu bar
    /// beside the other standing problems.
    private var standingCaptureProblem: String?

    /// Resolved once per config load, never in `updateUI`.
    ///
    /// `problems()` re-validates the whole pipeline and every transform, and
    /// `updateUI` runs on a 0.1s timer for as long as
    /// someone is talking. That is not work to repeat ten times a second to
    /// draw a menu item whose answer cannot have changed.
    private var configProblems: [String] = []

    /// Shown only once a release has been found, waited out, and not refused.
    private var updateItem: NSMenuItem!
    private var updateAvailable: Updates.Release?
    private var updatesTimer: Timer?
    /// So the notice fires when a version first becomes available, and not
    /// again every day for as long as the user leaves it alone.
    private var announcedUpdate: String?
    /// So the modal is offered once per version while idle, and not again on
    /// every hourly check while the user is busy or has not answered it yet.
    private var alertedUpdate: String?
    /// True between a manual "Check for Updates" click and its answer, so the
    /// menu item can say so and a second click cannot start a second request.
    private var updateCheckInFlight = false
    /// Bumped when a manual check finishes, not when it starts — so a
    /// background check that began during that manual check, and answers
    /// after it, can tell its answer is now stale and skip overwriting it.
    private var manualCheckGeneration = 0
    /// Bumped by `startUpdateChecks`, so a check already in flight when
    /// config.yaml reloads — and so working from a stale `afterDays` — is
    /// discarded on arrival rather than reviving state the reload just
    /// changed.
    private var updateSchedulingGeneration = 0
    /// Bumped by every manual check, so an older manual request's completion
    /// — canceled, failed, or just slow — cannot overwrite the feedback for
    /// a newer manual request the user is actually waiting on.
    private var manualRequestID = 0

    private lazy var transcriber = Transcriber { [weak self] status in
        DispatchQueue.main.async { self?.handleTranscriberStatus(status) }
    }
    private var transcriptionLabel: String?
    /// Bumped by every transcription, so a stage label arriving late from one
    /// cannot describe the next. Push-to-talk does not wait for the previous
    /// transcript: hold the key again while a prompt stage is still running and
    /// two are in flight, with the older one still holding a progress callback.
    private var transcriptionRun = 0
    /// Bumped by every `setLabel`, so a self-clear armed for one message cannot
    /// wipe a newer one that is still current.
    private var labelToken = 0
    private let correctionPanel = CorrectionPanel()
    private let previewPanel = PreviewPanel()
    /// Says once per microphone that this one will cost you words.
    private let micNotice = MicNotice()
    /// The release notes, and the three answers to them.
    private let updatePanel = UpdatePanel()
    private var pendingSelection: SelectionReader.Selection?
    /// Captured the moment the hotkey goes down — see SelectionReader.snapshot.
    private var selectionAtPress: SelectionReader.Selection?
    /// Where the text was being typed when the hotkey went down, so a rule
    /// learned by voice can fix the word already in the field.
    private var focusAtPress: SelectionReader.Selection?
    /// Which app you were dictating into, for pipeline `app:` conditions.
    ///
    /// Read from NSWorkspace rather than off `focusAtPress`, which is nil
    /// without Accessibility — an app condition has no business needing a
    /// permission that gating a stage by app does not otherwise require.
    private var appAtPress: Pipeline.App?
    /// The same app as a pid, for the window anchor. Kept from the press so the
    /// pill is measured against the app the words are aimed at.
    private var pidAtPress: pid_t?
    /// Which microphone the engine is recording through. Read when recording
    /// starts and frozen onto the `Press` when the clip is handed to the
    /// decoder, so the microphone notice names the device that recorded the
    /// words rather than whatever is default a second later. One slot is
    /// enough: only one recording runs at a time, and it is taken the moment
    /// that recording stops.
    private var micAtPress: Recorder.InputDevice?
    /// That same app's icon, for the pill. Held apart from `appAtPress` because
    /// `Pipeline.App` is what the pipeline matches on and has no business
    /// carrying an image around.
    private var appIconAtPress: NSImage?

    /// Where the caret was when the key went down, so the pill can open next to
    /// it. Nil when the app would not say, which is when the pill opens where
    /// it always has. See `CaretAnchor`.
    private var anchorAtPress: CaretAnchor.Found?

    /// Everything one press knows about where its words are going, frozen when
    /// the recording starts and carried down the whole delivery chain.
    ///
    /// Carried rather than read off `self` at the end, for the reason
    /// `destination` and `focus` already are: push-to-talk does not wait for
    /// the previous transcript, so two dictations are ordinarily in flight and
    /// anything read at the end belongs to the newer press. This is what lets
    /// the offer be certain that the pane it is diffing, and the pill it is
    /// moving, are its own.
    private struct Press {
        /// `pressRun` at the time. Identifies this dictation among the ones in
        /// flight; nothing else is unique, since two presses in a row are
        /// ordinarily into the same field.
        let run: Int
        /// What was focused when the key went down. The same element `focus`
        /// carries, held here as well so the offer needs nothing but the press.
        let element: AXUIElement?
        /// And the app it belonged to, for the same reason: an offer taken
        /// later has to write back into the window that was dictated into.
        let owner: NSRunningApplication?
        /// The microphone this dictation was recorded on. Frozen for the same
        /// reason as everything above it: the default input can change while
        /// the decoder runs — a headset disconnects, somebody picks another
        /// device in System Settings — and the notice is about the microphone
        /// that recorded these words. See `micAtPress`.
        let mic: Recorder.InputDevice?
        /// Which pasteboard flavour the app this was aimed at takes, over and
        /// above the plain text every paste carries.
        ///
        /// Frozen here rather than read from `appAtPress` at the end, for the
        /// reason that field is read once: it only ever holds the newest press.
        /// A Slack dictation still decoding while you press again in a terminal
        /// would be delivered with the terminal's answer, and the reverse puts
        /// markup in front of an app that shows the tags.
        let paste: AppProfile.Paste
        /// Tap-then-hold: a key said this would be an instruction, not text.
        ///
        /// Decided at the press because that is where the gesture is known, and
        /// carried here for the same reason everything else is — a second press
        /// landing mid-transcription must not be able to change what this one
        /// was for. See `handleVoiceCommand(_:keyed:)` for what it buys.
        var keyed = false
        /// What was selected when this recording began.
        ///
        /// Frozen for the reason every other field here is. `selectionAtPress`
        /// is one slot that the next press overwrites, and a spoken command
        /// reads its target *after* the decoder has run — so starting a second
        /// dictation while a command is still decoding pointed that command at
        /// the newer press's selection. "Make it bold" then applied to whatever
        /// happened to be highlighted by the time it finished, which on a
        /// gesture whose pill reads "editing the selection" is the one thing it
        /// must not do.
        var selection: SelectionReader.Selection?
        /// The dictation this command would fall back to, frozen with it.
        ///
        /// "Make it terse" with nothing selected means the sentence that was
        /// there when you said it. `lastTranscript` is one slot like the
        /// selection is, and a dictation finishing while the router thinks
        /// replaces it — so the command rewrote a sentence that arrived after
        /// the instruction for it. Freezing the selection alone left this half
        /// of the same crossing open.
        var transcript: String?
    }

    /// The words the offer on screen is about, and the field they went into.
    ///
    /// Stored when the offer is raised because `lastTranscript` and
    /// `focusAtPress` are one slot each and dictations overlap: an older one
    /// finishing while the offer is up overwrites the transcript, and the press
    /// that taps to accept overwrites the focus. Taking the offer then edits
    /// one dictation's words against another's field. This is the same
    /// ownership `offerPressRun` already asserts, carrying what it is about.
    private var offeredCorrection: (run: Int, target: Correction)?

    /// The current press was tap-then-hold, so its words are an instruction.
    private var keyedAtPress = false

    /// Watches for the last dictation being selected again — see
    /// `SelectionWatch`. Running from the moment there is something to select
    /// until the next dictation replaces it.
    private let reselect = SelectionWatch()

    /// Watches for one word of the last dictation being changed by hand — see
    /// `EditWatch`. A correction is the only thing that says what the right
    /// answer was in a particular sentence, and it is thrown away today.
    private let edits = EditWatch()

    /// The last dictation a tap can summon an offer over: its words, and where
    /// they went.
    ///
    /// `offeredCorrection` is cleared by every ending, because it asserts that
    /// an offer is up and about these words. This asserts nothing of the sort —
    /// one slot, replaced by the next dictation and never cleared.
    ///
    /// The words are held here rather than read from `lastTranscript` at the
    /// tap, because the two are written at different moments and a superseded
    /// run can separate them. `lastTranscript` is set for every transcription
    /// that finishes; this is set below the guard that refuses an offer to a
    /// run a newer one has already overtaken. Dictate twice with the first
    /// still decoding, and the older finish overwrites the transcript while the
    /// landing stays with the newer run — so a tap would have offered one
    /// dictation's words at another's field, and taking it would have rewritten
    /// there. One record, written once, cannot come apart that way.
    private var lastDictated: (
        run: Int, text: String, element: AXUIElement?,
        owner: NSRunningApplication?, landing: Correction.Landing
    )?

    /// The focused element's text as it was at the press, for an app that gave
    /// no caret. What changed in it afterwards is where the words went.
    ///
    /// Empty whenever there was a caret to aim at, so the search below only
    /// ever runs for the apps that need it.
    ///
    /// Kept per press, and read by that press alone. Not frozen onto the
    /// `Press` the way the element is: the copy runs on a background queue and
    /// a short dictation can be transcribed before it lands, so frozen early it
    /// would be frozen empty. And not one slot, because dictations overlap and
    /// an older one still needs the pane it started with.
    ///
    /// A press's pane lives until its dictation ends, and every way one ends
    /// takes it out. Never evicted to make room: however many dictations are in
    /// flight, each one still needs the pane it started with.
    ///
    /// The age is the backstop, for a dictation that ends a way nobody thought
    /// of. A value here has been seen at 395,489 characters, so nothing is kept
    /// on the chance that a transcript from five minutes ago is still coming.
    private var screenAtPress: [Int: (text: String, at: Date)] = [:]

    /// The decoder's own words for a press, before any stage rewrote them, and
    /// the one confidence it gave the whole utterance.
    ///
    /// Kept per press for the same reason the pane is: dictations overlap, and
    /// the offer that goes up belongs to one of them. Read once, by
    /// `showCorrectOffer`, and dropped by `dictationEnded` however the dictation
    /// finished. Only filled when something is going to read it — the colours
    /// or the warning — so switching both off costs nothing but the word
    /// timings the decoder already produced.
    private var heardAtPress: [Int: Transcriber.Decode] = [:]

    /// How many UTF-16 units this dictation actually put into the field.
    ///
    /// Not `lastTranscript.utf16.count`, which is the same words with their
    /// outer whitespace taken off. What is written is `delivered`, which trims
    /// newlines and keeps spaces, and a decoder routinely returns a leading
    /// one — so measuring the span from the trimmed string starts it a
    /// character or two inside itself, and `CaretAnchor.span` then asks for the
    /// bounds of the wrong first character.
    ///
    /// Only the length, because only the length is what `utterance` needs, and
    /// keeping the string twice is keeping somebody's sentence twice.
    private var wroteAtPress: [Int: Int] = [:]

    /// How long a pane is worth keeping, for a press that is no longer in
    /// flight. Nothing waits this long: the whole chain is a decoder and at
    /// most a prompt stage.
    private static let paneLifetime: TimeInterval = 300

    /// The presses whose dictation was thrown away rather than delivered.
    ///
    /// "Not in flight" is two different things, and only one of them should
    /// cost a press its pane. A dictation that finished and pasted is retired
    /// and still wants its pane: the offer is on screen and the words are what
    /// the pane is about. One that was cancelled wants nothing ever again.
    /// Guarding the snapshot store on the first meaning threw the offer's own
    /// baseline away; not guarding it at all kept a cancelled press's pane for
    /// the length of the sweep. This is the difference, written down.
    ///
    /// Bounded by construction: only a press that dispatched a snapshot is ever
    /// put here, and that snapshot's own callback takes it out again.
    private var cancelledPresses: Set<Int> = []

    /// The presses that took a pane and whose dictation has not ended yet.
    ///
    /// The age above is a backstop and this is what stops it hitting a live
    /// dictation: a prompt stage can outlast any number written here, and its
    /// pane is the one thing that cannot be fetched again. Every way a
    /// dictation ends goes through `dictationEnded(_:)`, which is what keeps
    /// this from growing.
    private var pressesInFlight: Set<Int> = []

    /// Bumped by every press that starts a dictation. It is what a `Press`
    /// carries, and what a snapshot that took a moment to copy is stamped with
    /// so it cannot be mistaken for a later one's.
    private var pressRun = 0

    /// `transcriptionRun` as it stood when the current press arrived. It says
    /// whether a transcription now in flight was started by this press or was
    /// already running behind it, which is the difference between an abort
    /// dropping its own dictation and an abort eating somebody else's words.
    private var transcriptionRunAtPress = 0

    /// The newest press that has had the pill for an offer.
    ///
    /// Two things read it: the landing search, which only moves the pill while
    /// its own press still owns it, and `showCorrectOffer`, which refuses a
    /// press older than this one. A watermark, so it is never cleared — a later
    /// press always has a higher run and passes on its own.
    private var offerPressRun: Int?

    /// Where the last dictation into a given element ended up.
    ///
    /// The only thing worth knowing at the press about an app that keeps no
    /// caret: you dictate into the same box several times running, and the box
    /// does not move between them. So the pill opens where the last one landed
    /// instead of at the bottom of the screen, and the real answer replaces it
    /// a few seconds later when the words arrive.
    ///
    /// Held per element, briefly, and against what the pane was showing when
    /// the words landed — all three are what make it a fair guess rather than
    /// a stale one. See `readTheAnchor` for what invalidates it, and
    /// `CaretAnchor.paneDigest` for why the digest is of the text.
    private var lastLanding: (element: AXUIElement, found: CaretAnchor.Found, at: Date, digest: Int)?

    /// Whether there was anywhere to type when the hotkey went down — see
    /// `Destination`. Decides whether the pill shows the icon, and is handed to
    /// the transcription it belongs to so that the same press decides, a few
    /// seconds later, whether the words are typed or copied.
    ///
    /// Read exactly once after the press, in `transcribe`, for the same reason
    /// `appAtPress` is: two dictations can be in flight at once, and this field
    /// only ever holds the newest.
    ///
    /// Starts at nothing, which is only read if a transcript ever arrives
    /// without a press behind it — and one that did not come from a press has
    /// no window it was aimed at either, so the clipboard is the honest answer.
    private var destinationAtPress: Destination = .nowhere(.nothingFocused)

    private var tickTimer: Timer?
    private var pushToTalkPoll: Timer?
    /// Running between the hotkey coming up and the recording actually stopping
    /// — see `stopRecordingAfterTail`.
    private var releaseTail: Timer?
    /// Every transcription run at or below this was cancelled with Escape and
    /// must not be written anywhere. A high-water mark rather than a set: runs
    /// only ever increase, so "this one and everything still in flight behind
    /// it" is the whole of what cancelling means.
    private var cancelledThroughRun = 0
    private var escapeMonitors: [Any] = []
    /// How many transcriptions have been started and not yet landed.
    ///
    /// Push-to-talk does not wait for the previous transcript, so two dictations
    /// are ordinarily in flight at once — the same overlap `transcriptionRun`
    /// exists to survive. The Escape monitors are one shared pair, so the older
    /// run finishing must not take them away from the newer one still recording
    /// behind it. Nothing tears them down until this is zero and the recorder is
    /// idle.
    private var runsInFlight = 0
    private var keepWarmTimer: Timer?
    private var keepWarmInFlight = false
    private var hotkeyError: String?
    private var lastRecording: Recorder.Recording?
    /// What was last dictated — the context a correction or a free-form command
    /// works against when there is no selection to work against instead.
    private var lastTranscript: String?

    /// When the offer to correct the last dictation stops being on screen.
    ///
    /// Held here as well as in the pill because the pill only knows how to draw
    /// it. It is also the deadline the key tap is given, so the keys can never
    /// be held for longer than the offer is worth.
    private var offerUntil: Date?
    /// The tab on its way back after a message. See `offerAgainAfter`.
    private var offerReturn: DispatchWorkItem?
    /// The keyboard, for as long as the offer is up. See `OfferKeys`.
    private let offerKeys = OfferKeys()
    /// The chips the offer on screen is showing, and so the letters it claims.
    ///
    /// Held rather than read from the config when the keys are armed, because
    /// the keys can be armed after the chips were drawn — see
    /// `watchTheOfferKeys`. A config reloaded in between must not leave a
    /// letter claimed for a chip that is not on screen.
    private var offerOnScreen: [OfferedCommand]?
    /// The headline and the reading the offer went up with, so the pill can be
    /// drawn again without rebuilding what it is about. See `holdTheReturn`.
    private var offerHeadline: Headline?
    private var offerReading = Confidence.Reading()
    /// Until when this offer's Return is held. Set when the offer goes up, so
    /// an offer whose keys arrive late — a second dictation was still running —
    /// gets whatever is left of the moment rather than a fresh one.
    private var offerHoldsReturnUntil: Date?
    /// Gives the keys back when the offer simply runs out.
    ///
    /// The pill fades itself off screen after `offerSeconds` and tells nobody,
    /// so an offer that nobody answers ends with no call back into here. This
    /// is that call. Without it the tap's own expiry would be the only thing
    /// left to end it, and that is the backstop, not the way out.
    ///
    /// It has a second job while the pointer is holding the offer open. See
    /// `offerDeadlinePassed`.
    private var offerKeysExpiry: DispatchWorkItem?
    /// Watches for a click outside the offer, for as long as it is up. See
    /// `watchForOfferOutsideClick`.
    private var offerClickMonitors: [Any] = []
    /// True while the pointer is resting on the offer.
    ///
    /// The clock is stopped then, and `offerUntil` becomes a date that never
    /// arrives — which is also why the deadline above is not armed with it:
    /// `asyncAfter` at that distance is an overflow rather than a long wait.
    /// See `holdTheOffer`.
    private var offerHeld = false

    /// How long the offer stays up: the pill's own hold plus its fade.
    ///
    /// Read from `PillHUD` rather than chosen here, because the keys and the
    /// pill have to end together. A number of its own would mean letters still
    /// being taken from the app you are typing in after the surface offering
    /// them has gone — or the other way round, a chip on screen whose key does
    /// nothing.
    ///
    /// The pointer stops that clock and gives all of it back — see
    /// `holdTheOffer`.
    ///
    /// Not private: `--panels offer` previews the offer for as long as the app
    /// gives it, and a preview with a number of its own is a preview of
    /// something else.
    static let offerSeconds: TimeInterval = PillHUD.offerLife

    /// What the offer offers: Correct, then every transform that asked for a
    /// place on it with `offer: true`.
    ///
    /// Vocabulary is first and is not a transform. It is the one command that
    /// is about the words rather than about rewriting them, it needs no model,
    /// and it cannot fail.
    ///
    /// Read fresh each time rather than stored, so a config reloaded between
    /// two dictations changes what the next offer says.
    /// `teaching` puts `Vocabulary` in front, and it is left out for words
    /// nothing here dictated.
    ///
    /// The panel behind that chip maps what was HEARD to what it should be, and
    /// over a selection in somebody else's email there is no hearing — nothing
    /// listened to it. A rule taught from a typo somebody else typed would fire
    /// on *your* future dictations, correcting a mistake the decoder never made.
    ///
    /// Before the hotkey could summon an offer over an arbitrary selection this
    /// could not arise: the panel only ever opened over a dictation. Leaving the
    /// chip off is the whole of the fix, and it is what the `add a word` panel
    /// mode was going to be for.
    private func offerCommands(teaching: Bool) -> [OfferedCommand] {
        (teaching ? [OfferedCommand(title: "Vocabulary", key: "V")] : [])
            + config.transforms.filter(\.offer).map {
                OfferedCommand(title: $0.name, key: $0.offerKey)
            }
    }

    /// The last substitution made in somebody else's window, and enough to put
    /// it back.
    ///
    /// One deep on purpose. This is not an edit history — it is the answer to
    /// "that went somewhere I did not expect", which is only ever asked about
    /// the thing that just happened. A stack would invite walking backwards
    /// through edits the app cannot see the consequences of.
    ///
    /// It survives until the next substitution rather than expiring on a timer:
    /// what makes an undo unsafe is the text having moved on, and `Surface.undo`
    /// checks that directly by comparing what is on screen against what it
    /// wrote. A clock cannot answer that question and would only refuse a valid
    /// undo for having been asked slowly.
    private var lastSubstitution: Surface.Undo?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildStatusItem()
        loadConfig(announceErrors: false)
        watchConfig()

        watchActivation()

        // Touching the engine's inputNode is what warmUp does, and it is also
        // what makes AVFoundation put up the native microphone dialog on its
        // own — before the window below has had a chance to explain why.
        // Skipped here when the answer isn't in yet; the first recording
        // after permission is granted pays the warm-up cost instead.
        if Permissions.microphone == .granted {
            recorder.warmUp()
        }
        // The other half of the first press. The engine warms above; this is
        // the pill's own window, which costs as much again.
        pill.warm()
        recorder.onLevel = { [weak self] level in
            self?.pill.model.level = level
        }
        recorder.onUnexpectedStop = { [weak self] _ in
            self?.stopRecording(reason: "The microphone changed — that take stopped early.")
        }
        recorder.onCaptureProblem = { [weak self] problem in
            self?.captureProblem(problem)
        }

        Log.write(
            "launched — hotkey=\(hotKeys.binding?.displayName ?? "NONE (\(hotkeyError ?? "?"))") "
            + "mode=\(config.hotkey.mode == .toggle ? "toggle" : "push-to-talk") "
            + "mic=\(Permissions.microphone.label) "
            + "accessibility=\(Permissions.accessibility.label) "
            + "input=\(Recorder.inputDeviceName ?? "none")"
        )

        if CommandLine.arguments.contains("--preview-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.previewCorrectionPanel()
            }
            return
        }

        if CommandLine.arguments.contains("--preview-transform") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.previewPanel.onApply = { _ in NSApp.terminate(nil) }
                self?.previewPanel.onCancel = { NSApp.terminate(nil) }
                self?.previewPanel.show(
                    prompt: "grammar",
                    before: "he dont know what the config does, and their going to ship it on friday anyway",
                    after: "He doesn't know what the config does, and they're going to ship it on Friday anyway."
                )
            }
            return
        }
        // After the preview flags return. Those launches draw a panel and
        // quit; nothing there transcribes, and fetching 1.16 GB for them
        // is what `warmUpTranscriber` avoided by sitting below this point.
        warmModels()


        warmUpLLM()

        // Anything still missing opens the walk, and nothing is asked for yet.
        // The prompt used to fire here, the moment the window appeared — a
        // system dialog on top of the window explaining it, before either had
        // been read. The window asks when its button is pressed and not before.
        //
        // Both permissions, not just the microphone: a launch with the
        // microphone already answered and accessibility still missing is
        // exactly the install that fails later, at the moment someone holds the
        // key and nothing is written.
        //
        // Which walk it is turns on whether the microphone has ever been
        // answered. An unanswered one is a first run and the install is still
        // happening, so the way out is to cancel it. Once there is an answer on
        // record the app has been opened before, and offering to cancel an
        // installation that finished is a threat about something that already
        // happened — same reasoning as the hotkey path below.
        if Permissions.microphone != .granted || Permissions.accessibility != .granted {
            permissions.show(Permissions.microphone == .notDetermined ? .installing : .revisiting)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if recorder.isRecording { _ = recorder.stop(config: config) }
        keepWarmTimer?.invalidate()
        hotKeys.unregister()
    }

    // MARK: - Config

    private func loadConfig(announceErrors: Bool) {
        do {
            config = try ConfigStore.load()
        } catch {
            if announceErrors {
                Log.write("config: could not reload — \(error.localizedDescription)")
                armConfigReloadNotice()
            }
            return
        }
        configReloadNotice?.cancel()
        configReloadNotice = nil
        applyConfig()
        // After the load, not with the other watchers: a transform can be
        // renamed, removed or pointed at a different file, so which files are
        // worth watching is only known once the config has been read.
        watchTransformFiles()
    }

    /// Holds a live-reload failure for `configReloadGraceSeconds` before saying
    /// anything, and re-arms rather than stacks on every write in that window.
    ///
    /// An editor can leave config.yaml briefly invalid mid-save — several
    /// syscalls, or an atomic replace caught between the delete and the
    /// rewrite. The grace period gives the next save a chance to be the real
    /// one before the user is interrupted over a file they are still editing.
    private func armConfigReloadNotice() {
        configReloadNotice?.cancel()
        let notice = DispatchWorkItem { [weak self] in
            self?.flash("Could not reload config.yaml — using the previous settings", tone: .failure)
        }
        configReloadNotice = notice
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.configReloadGraceSeconds, execute: notice)
    }

    /// Says a config problem once, at the moment it appears.
    ///
    /// The log has carried these since the pipelines landed, and the log is not
    /// where anyone looks. The case this exists for is an upgrade: `numbers`
    /// and `fuzzy_matching` became pipeline stages, so a config written for an
    /// earlier version still holds a line that reads as though it works and
    /// does nothing. Nothing looks broken — dictation simply stops writing
    /// digits, which is the kind of loss a person blames on the model.
    ///
    /// On change rather than on every load: the file is watched, so saving an
    /// unrelated line runs this again, and a notice that fires every time you
    /// edit your own config is one you learn to ignore.
    private func announceIfNew(_ problems: [String]) {
        defer { announcedProblems = problems }
        guard problems != announcedProblems, let first = problems.first else { return }
        let others = problems.count - 1
        flash(others > 0 ? "\(first)  (+\(others) more)" : first, tone: .caution)
    }

    /// Models already asked about this run, so saving config.yaml — which
    /// reloads it — does not ask again for one that was declined.
    ///
    /// The config-load path's alone. Nothing clears it, and commenting a model
    /// out and back in does not either: that reloads the config but leaves the
    /// name in here. Two things get past it, both of them something you did on
    /// purpose — the menu row (`addKeyItem`), and using the model, which asks
    /// through `askForKeyThenRetry` without reading this at all.
    private var askedForKey: Set<String> = []

    /// A key prompt a running dictation pushed back, waiting for idle.
    private var keyPromptDeferred = false

    /// Cloud models with no key in the keychain yet, for the menu row that
    /// offers to add one.
    ///
    /// Held rather than worked out in `updateUI`, which runs on every change of
    /// state: each name costs a keychain lookup, and an unsigned build is asked
    /// about by macOS on every one of them. Refreshed where the answer can
    /// change — a config load, and a key being stored.
    private var keylessModels: [String] = []

    private func refreshKeylessModels() {
        keylessModels = config.modelsByName.values
            .filter { $0.key.kind == .keychain && $0.key.resolve() == nil }
            .map(\.name)
            .sorted()
    }

    /// The menu's way in, for a key that was declined or never offered.
    ///
    /// Declining is remembered for the run, so the dialog does not come back on
    /// its own — and commenting the model out and back in does not bring it
    /// back either, because the name stays in `askedForKey`. This is the way
    /// back, and it is a menu row rather than a terminal command.
    @objc private func addMissingKeys() {
        for name in keylessModels { askedForKey.remove(name) }
        askForMissingKeys()
    }

    /// Ask for the key of any keychain-backed model that has none.
    ///
    /// Modal, and this is the one place that is allowed to be. It runs on a
    /// config load — launch, or a save of config.yaml — and not on the hotkey
    /// path, which is what `runModal` may never block; see `startRecording`'s
    /// catch and #95. Idle is checked anyway, because a save can land while a
    /// dictation is in flight. One that does is held and asked the moment the
    /// dictation ends — waiting for the next load means a model configured
    /// mid-dictation stays keyless until a restart.
    ///
    /// Declining is a normal answer. The model stays unusable, a transform
    /// naming it declines with the transcript untouched, and the menu keeps
    /// saying so.
    private func askForMissingKeys() {
        let wanted = config.modelsByName.values
            .filter { $0.key.kind == .keychain && $0.key.resolve() == nil }
            .filter { !askedForKey.contains($0.name) }
            .sorted { $0.name < $1.name }
        guard !wanted.isEmpty else { return }
        guard !recorder.isRecording, runsInFlight <= 0 else {
            keyPromptDeferred = true
            return
        }
        keyPromptDeferred = false

        var stored = false
        for spec in wanted {
            askedForKey.insert(spec.name)
            if askForKey(spec) { stored = true }
        }
        if stored { keyWasStored() }
    }

    /// The key dialog for one model. True when a key was stored.
    ///
    /// `rejected` is the model answering 401 with a key already stored, which
    /// wants different words: the reason it is on screen is not that a key is
    /// missing, and "Save" reads wrong for something that overwrites.
    ///
    /// Modal, so every caller owes the same check `askForMissingKeys` makes:
    /// nothing recording, nothing in flight.
    @discardableResult
    private func askForKey(_ spec: ModelSpec, rejected: Bool = false) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        // One line either way, and it is the one worth reading: naming the host
        // is how somebody sees where their words are about to go.
        if rejected {
            alert.messageText = "\(spec.name) rejected its API key"
            alert.informativeText =
                "\(spec.host) turned down the key stored for it."
                + " A new one is kept safely in your keychain."
        } else {
            alert.messageText = "API key for \(spec.name)"
            alert.informativeText = "Sent to \(spec.host). Kept safely in your keychain."
        }
        let field = KeyField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = rejected ? "Paste the new key" : "Paste the key"
        alert.accessoryView = field
        alert.addButton(withTitle: rejected ? "Replace" : "Save")
        alert.addButton(withTitle: "Not now")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        let typed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return false }
        do {
            try Keychain.write(typed, account: spec.key.value)
            Log.write("stored a keychain key for \(spec.name)")
            return true
        } catch {
            Log.write("could not store a key for \(spec.name): \(error.localizedDescription)")
            flash(error.localizedDescription, tone: .failure)
            return false
        }
    }

    /// The menu still carries the old "no key" line otherwise, and the problem
    /// it names is the one just fixed.
    private func keyWasStored() {
        configProblems = config.problems()
        refreshKeylessModels()
        updateUI()
    }

    /// A run that stopped because its model has no key: ask for one, and run it
    /// again if it arrives. True when `retry` was called.
    ///
    /// Asked on every deliberate use, and `askedForKey` is deliberately not
    /// consulted. That set is the config-load path's alone, where a decline
    /// must survive the reload every save of config.yaml causes. Here the
    /// dialog is the answer to something just asked for by name, so declining
    /// means "not this time" and nothing is remembered.
    ///
    /// Only for what somebody asked for out loud. A `prompt:` stage and the
    /// vocabulary judge reach the same models on every dictation with nobody
    /// asking — see `Pipeline.runPrompt` — and they keep declining in silence.
    private func askForKeyThenRetry(_ error: Error, retry: () -> Void) -> Bool {
        let spec: ModelSpec
        let rejected: Bool
        switch error {
        case LLM.Failure.noKey(let model):
            spec = model
            rejected = false
        // A key that is present and refused is the worse half of this. The
        // model has one, so it leaves `keylessModels` and takes the menu row
        // that would fix it with it — a mistyped paste used to leave no way
        // back but `--set-key` in a terminal. 403 comes too: it is as much a
        // dead end, and a dialog nobody wanted is dismissed in one press.
        case LLM.Failure.badStatus(let model, let code, _) where code == 401 || code == 403:
            spec = model
            rejected = true
        default:
            return false
        }
        guard spec.key.kind == .keychain else { return false }
        // A second dictation started while this run was in flight. The modal
        // would land on top of it, so this one goes the way it always did: the
        // flash names it, and the menu row is still there.
        guard !recorder.isRecording, runsInFlight <= 0 else { return false }
        guard askForKey(spec, rejected: rejected) else { return false }
        keyWasStored()
        // Written but still not readable. An unsigned build whose keychain
        // prompt was denied reads back nil — see `Keychain.read` — so the retry
        // would throw `noKey` again and ask again, for as long as somebody kept
        // pasting. Stop here and let the flash say it, which is still true.
        guard spec.key.resolve() != nil else { return false }
        // Asked again, because the guard above is as old as the modal and the
        // modal was on screen for as long as it took to paste a key. A press
        // cannot arrive during one — `runModal` holds the run loop the hotkey
        // is delivered on, which is the whole of #95 — but this run has no
        // business resuming into a dictation whatever let one start.
        guard !recorder.isRecording, runsInFlight <= 0 else {
            flash("Key saved for \(spec.name) — ask again", tone: .done)
            return true
        }
        retry()
        return true
    }

    private func applyConfig() {
        // Said out loud on the app's own path, not only by --check-config,
        // which the app never runs. A mistyped stage name used to vanish at
        // decode time with no trace anywhere: replacements simply stopped
        // happening, and nothing distinguished that from an empty table.
        // Beside the recordings, and re-read here because `output_dir` can move
        // on any save of config.yaml.
        Trace.directory = config.resolvedOutputDir

        configProblems = config.problems()
        for problem in configProblems { Log.write("config: \(problem)") }
        // Logged and not flashed. A `command:` transform is announced on every
        // load — see `Config.notices()` — and it went through `problems()` for
        // a while, which put "⚠︎ 1 setting in config.yaml does nothing" in the
        // menu of every config that had one. The log is where a standing fact
        // about your config belongs; the notice is for what changed.
        for notice in config.notices() { Log.write("config: \(notice)") }
        announceIfNew(configProblems)
        refreshKeylessModels()
        // Async so a launch is not held behind a modal, and so the menu bar is
        // up before anything sits in front of it.
        DispatchQueue.main.async { [weak self] in self?.askForMissingKeys() }

        hotkeyError = nil
        hotKeys.onPress = { [weak self] afterTap in self?.handleHotKeyPress(afterTap: afterTap) }
        hotKeys.onRelease = { [weak self] in self?.handleHotKeyRelease() }
        hotKeys.onAbort = { [weak self] in self?.cancelDictation(.notTheHotkey) }
        hotKeys.onTap = { [weak self] in self?.summonOffer() }
        do {
            let binding = try hotKeys.register(
                key: config.hotkey.key,
                modifiers: config.hotkey.modifiers,
                pressDelay: config.hotkey.pressDelaySeconds
            )
            // The offer's "or hold …" row names this key, so it is read from
            // what actually registered rather than from the config: a key the
            // config asked for and macOS refused is not the key to tell
            // somebody to hold. Set on every reload, because the hotkey is one
            // of the things a reload can change.
            pill.model.hotkey = binding.displayName
        } catch {
            hotkeyError = error.localizedDescription
            Log.write("hotkey registration FAILED: \(error.localizedDescription)")
            // `register` unregisters before it tries, so a reload that fails
            // leaves nothing bound. Cleared rather than left saying the old
            // key: the row would be naming a key with no handler behind it,
            // which is worse than the row being absent. Empty takes it off the
            // pill — see `OfferContent.hold`.
            pill.model.hotkey = ""
        }

        startKeepWarm()
        startUpdateChecks()
        updateUI()
    }

    // MARK: - Updates

    /// Once shortly after launch, then hourly.
    ///
    /// Restarted on every config load, since `after_days` can turn the whole
    /// thing off — and a setting that only takes effect after a restart is one
    /// that will be reported as not working.
    private func startUpdateChecks() {
        // Discards any check already in flight: it captured the old
        // afterDays and would otherwise revive state this reload just
        // changed. Clearing updateCheckInFlight here, rather than waiting
        // for that stale check's own completion, keeps the menu correct
        // right away even if the completion never discards cleanly.
        updateSchedulingGeneration += 1
        updateCheckInFlight = false

        updatesTimer?.invalidate()
        updatesTimer = nil

        guard config.updates.afterDays >= 0 else {
            updateAvailable = nil
            return
        }

        // Not at launch: the first seconds belong to the hotkey, the mic and
        // the model. Nothing here is urgent enough to compete with them.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            self?.checkForUpdate()
        }
        let timer = Timer(timeInterval: 3_600, repeats: true) { [weak self] _ in
            self?.checkForUpdate()
        }
        RunLoop.main.add(timer, forMode: .common)
        updatesTimer = timer
    }

    /// - Parameter manual: True for a menu click, false for the timer.
    ///   A manual check reports its result even when there is nothing new —
    ///   a click with no visible answer reads as broken — and shows the
    ///   update alert straight away rather than waiting for the app to go
    ///   idle, since the user just asked for it.
    private func checkForUpdate(manual: Bool = false) {
        let afterDays = config.updates.afterDays
        guard afterDays >= 0 else {
            if manual { flash("Update checks are disabled") }
            return
        }

        let generationAtStart = manualCheckGeneration
        let schedulingGenerationAtStart = updateSchedulingGeneration
        let myRequestID: Int
        if manual {
            updateCheckInFlight = true
            manualRequestID += 1
            myRequestID = manualRequestID
            updateUI()
        } else {
            myRequestID = 0
        }

        Task<Void, Never> {
            var latest: Updates.Release?
            do {
                latest = try await Updates.latest()
            } catch {
                if manual {
                    await MainActor.run { [weak self] in
                        // A newer manual request has since started — its own
                        // completion owns the feedback now, not this one.
                        guard let self, myRequestID == self.manualRequestID else { return }
                        guard self.updateSchedulingGeneration == schedulingGenerationAtStart else {
                            self.flash("Update check canceled — settings changed")
                            return
                        }
                        self.updateCheckInFlight = false
                        self.manualCheckGeneration += 1
                        Log.write("updates: check failed — \(error.localizedDescription)")
                        self.flash("Could not check for updates: \(error.localizedDescription)")
                        self.updateUI()
                    }
                } else {
                    // A failed poll leaves everything as it was — a known
                    // update stays known, and a version already alerted for
                    // is not asked about again just because this fetch
                    // failed. The next successful poll picks up from here.
                    await MainActor.run { [weak self] in
                        guard let self,
                            self.updateSchedulingGeneration == schedulingGenerationAtStart
                        else { return }
                        Log.write("updates: check failed — \(error.localizedDescription)")
                    }
                }
                return
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                // A newer manual request has since started — its own
                // completion owns the feedback now, not this one.
                if manual, myRequestID != self.manualRequestID { return }
                guard self.updateSchedulingGeneration == schedulingGenerationAtStart else {
                    if manual { self.flash("Update check canceled — settings changed") }
                    return
                }
                // A manual answer always applies. A background one only does
                // if a manual check has not started, or finished, meanwhile.
                if !manual {
                    guard !self.updateCheckInFlight,
                        self.manualCheckGeneration == generationAtStart
                    else { return }
                }
                self.updateCheckInFlight = false
                if manual { self.manualCheckGeneration += 1 }
                let decision = Updates.decide(
                    current: Updates.current, latest: latest, afterDays: afterDays
                )
                switch decision {
                case .available(let release):
                    self.updateAvailable = release
                    if self.announcedUpdate != release.version {
                        self.announcedUpdate = release.version
                        Log.write("updates: \(release.version) is available")
                        self.flash("ParrotFlow \(release.version) is available")
                    }
                    // The modal steals focus, so a background check waits for
                    // a moment with nothing running. A manual check was asked
                    // for, so it shows right away.
                    let idle = !self.recorder.isRecording && self.runsInFlight <= 0
                    if self.alertedUpdate != release.version, manual || idle {
                        self.alertedUpdate = release.version
                        self.showUpdate()
                    }
                case .waiting(let release, let daysToGo):
                    self.updateAvailable = nil
                    // A longer after_days can drop an already-alerted release
                    // back into waiting. Forget the alert so it can fire
                    // again once the release re-qualifies.
                    if self.alertedUpdate == release.version { self.alertedUpdate = nil }
                    Log.write("updates: holding \(release.version) for \(daysToGo) more day(s)")
                    if manual {
                        self.flash(
                            "ParrotFlow \(release.version) is out, offered in "
                                + "\(daysToGo) day\(daysToGo == 1 ? "" : "s")"
                        )
                    }
                case .upToDate:
                    self.updateAvailable = nil
                    if manual { self.flash("ParrotFlow is up to date") }
                case .skipped(let release):
                    self.updateAvailable = nil
                    if manual { self.flash("You skipped \(release.version)") }
                case .snoozed(let release, _):
                    self.updateAvailable = nil
                    if manual { self.flash("ParrotFlow \(release.version) is snoozed for now") }
                case .disabled:
                    self.updateAvailable = nil
                }
                self.updateUI()
            }
        }
    }

    /// Downloads, checks, and hands over to the swap.
    ///
    /// Nothing is replaced until the archive has matched its published
    /// checksum, verified as signed, and been signed by our certificate —
    /// the same three the curl installer applies, for the same reason.
    ///
    /// Quitting is part of the update rather than a side effect: the swap
    /// waits for this process to exit before it moves anything, so an update
    /// that could not close the app would simply hang.
    private func install(_ release: Updates.Release) {
        let token = beginProgress("Downloading ParrotFlow \(release.version)…")
        Task<Void, Never> {
            do {
                let app = try await UpdateInstaller.prepare(release)
                try await MainActor.run {
                    self.endProgress(token: token)
                    try UpdateInstaller.swapAndRelaunch(newApp: app)
                    NSApp.terminate(nil)
                }
            } catch {
                await MainActor.run {
                    self.endProgress(token: token)
                    Log.write("updates: install failed — \(error.localizedDescription)")
                    self.presentAlert(
                        title: "Could not install the update",
                        message: error.localizedDescription
                            + "\n\nNothing on this Mac has been changed. You can still upgrade with:\n\n"
                            + Updates.installCommand
                    )
                }
            }
        }
    }

    @objc private func checkForUpdateNow() {
        checkForUpdate(manual: true)
    }

    /// The release notes, and the three answers to them.
    ///
    /// The notes are drawn as Markdown in a panel of their own — see
    /// `ReleaseNotes` and `UpdatePanel`.
    @objc private func showUpdate() {
        guard let release = updateAvailable else { return }

        // Installing in place is only offered when it can actually be done: a
        // dev build, or an app in a read-only location, gets the reason and the
        // command it was installed with rather than a button that fails after
        // downloading 3 MB.
        let blocker = UpdateInstaller.blocker
        updatePanel.show(
            release: release,
            current: Updates.current,
            blocker: blocker,
            answers: UpdatePanel.Answers(
                install: blocker == nil ? { [weak self] in self?.install(release) } : nil,
                copyCommand: { [weak self] in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Updates.installCommand, forType: .string)
                    self?.flash("Upgrade command copied — paste it into a terminal", tone: .done)
                },
                skip: { [weak self] in
                    Updates.skip(release.version)
                    self?.updateAvailable = nil
                    self?.updateUI()
                },
                later: { [weak self] in
                    Updates.remindLater()
                    self?.updateAvailable = nil
                    self?.updateUI()
                }
            )
        )
    }

    private func watchConfig() {
        try? ConfigStore.createIfMissing()
        configWatcher = FileWatcher(url: ConfigStore.fileURL) { [weak self] in
            self?.loadConfig(announceErrors: true)
        }
        // The vocabulary is a second file and needs its own watch. It is the
        // one the app writes to itself — a term learnt from a correction, a
        // floor measured from a recording — so "takes effect on the next
        // restart" is the wrong behaviour for the file most likely to change
        // while the app is running.
        vocabularyWatcher = FileWatcher(url: ConfigStore.vocabularyURL) { [weak self] in
            self?.loadConfig(announceErrors: true)
        }
    }

    /// Every file a transform reads its body from — `prompt: { path: slack.md }`
    /// and `replace: { path: … }`.
    ///
    /// Those are read once, when the config is decoded, so without this a
    /// prompt edit does nothing until `config.yaml` happens to be saved. That
    /// is the wrong way round: a prompt is the file somebody iterates on,
    /// twenty times in a row, and `config.yaml` is the one they touch monthly.
    ///
    /// Rebuilt on every load rather than added to, because a transform can be
    /// renamed, removed, or pointed at a different file, and a watcher left
    /// behind would reload on a file nothing reads.
    private func watchTransformFiles() {
        transformWatchers = config.transforms.compactMap { transform in
            guard let source = transform.source else { return nil }
            return FileWatcher(url: source.url) { [weak self] in
                self?.loadConfig(announceErrors: true)
            }
        }
    }

    // MARK: - Hotkey handling

    private func handleHotKeyPress(afterTap: Bool = false) {
        // The gesture, kept for the `Press` built when the recording stops.
        // Only for a press that starts a dictation: the second press of a
        // toggle belongs to the one already running, and it did not ask for
        // anything different.
        //
        // A plain hold counts as keyed while the offer is *open*, and only
        // then. Open, the pill is pointing at words and asking what to do about
        // them, so a hold cannot mean "start a new dictation" — and you opened
        // it, so asking for it again would be asking twice for the same thing.
        // It is also what the last row of that panel promises, and a promise
        // nothing honoured would be worse than no row.
        //
        // A tab is not that. Every dictation leaves one, nothing on it offers
        // the gesture, and holding after a sentence lands is how the next one
        // gets said — so a tab must never turn the next hold into an edit.
        //
        // This used to read `offerHeadline?.isSelection`, because the row was
        // drawn over a selection and nowhere else. The row is on every panel
        // now, and the rule has to be the one the pill is drawing or the two
        // drift apart — which they did: every offer promised the hold and only
        // a selection honoured it, so holding after an ordinary dictation
        // started another dictation instead of taking an instruction.
        //
        // `pill.isOpen` is that rule exactly. The row lives inside the panel,
        // so it is visible precisely when the panel is open, and the promise
        // and the behaviour cannot come apart again.
        if !recorder.isRecording {
            keyedAtPress = afterTap || (offerIsUp && pill.isOpen)
        }
        // Read before anything this press does, so an abort later can tell the
        // transcription this press started from one that was already running.
        transcriptionRunAtPress = transcriptionRun
        // Grab the selection now: by the time a transcript exists, a terminal
        // will very likely have dropped it. Timed out hard inside snapshot(),
        // because this is the main thread and recording must start regardless.
        let snapshotStart = Date()
        selectionAtPress = SelectionReader.snapshot()
        focusAtPress = selectionAtPress ?? SelectionReader.focusSnapshot()
        let front = Self.appInFront()
        appAtPress = front?.app
        pidAtPress = front?.pid
        // The icon is a promise that the words are going to land in that app,
        // so it is only made when they will. Off the element the snapshot above
        // already fetched — the answer costs two more attribute reads on a
        // reference we are holding, not another walk of the tree.
        destinationAtPress = Destination.at(app: front?.app, focus: focusAtPress?.element)
        appIconAtPress = destinationAtPress.acceptsText ? front?.icon : nil
        // The app by name: `field (AXTextArea)` alone cannot be acted on.
        let inWhichApp = destinationAtPress.namesTheApp
            ? "" : " in \(front?.app.described ?? "nothing")"
        Log.write("destination: \(destinationAtPress.described)\(inWhichApp)")
        let elapsed = Date().timeIntervalSince(snapshotStart)
        if elapsed > 0.15 {
            Log.write(String(format: "selection snapshot was slow: %.2fs", elapsed))
        }

        // Where the words are about to go, so the pill can open there and say
        // so before a single one of them has been said.
        //
        // Here rather than after the insertion, and the difference is the whole
        // reason it works: at this moment the target app is idle and its caret
        // is sitting exactly where the sentence will start. Asked at the other
        // end it is a race against a redraw, which is what it was, and it
        // answered about half the time. See `CaretAnchor`.
        //
        // On this thread rather than the background one below, because the pill
        // is raised a few lines from here and an anchor that arrives after it
        // is an anchor that makes it jump. The read is capped at 80ms and this
        // element has just been read from twice by the snapshot above.
        //
        // Only for a press that is going to start a dictation. A press that
        // ends one — the second press of a toggle, a stutter inside the release
        // tail — is not aiming a new pill, and taking a fresh snapshot there
        // would throw away the one the running dictation is going to need.
        let startsDictation = !recorder.isRecording
        if startsDictation {
            anchorAtPress = nil
            pressRun += 1
            // The words it is watching for are about to be replaced. Stopped
            // here rather than when the new ones land, so the gap in between
            // cannot offer over a sentence that is already history.
            reselect.stop()
            edits.stop()
            readTheAnchor()
        }

        // The screen as it was when you started talking — which is the screen
        // the sentence is about. Taken here rather than in the pipeline because
        // this is the last moment the pane is *known*: by the time the stage
        // runs there has been a transcription and possibly a model call, and
        // focus may be in another pane entirely.
        //
        // After the snapshot and off the main thread, because this reads an
        // accessibility value that has been observed at 237k characters and the
        // one thing this handler may not do is delay recording. Gated on the
        // stage being configured, so a config that never asked for context pays
        // nothing for the question.
        //
        // And on the press starting one, for the reason the anchor above is.
        // The second press of a toggle, and a stutter inside the release tail,
        // belong to the dictation already running. Capturing there replaces
        // what that dictation is going to read with the screen as it stands
        // when it ends. There is one capture, not one per press.
        if startsDictation, Context.isConfigured(in: config) {
            let app = front?.app
            let element = focusAtPress?.element
            DispatchQueue.global(qos: .userInitiated).async {
                Context.capturePress(app: app, element: element)
            }
        }

        // The same press, the other half of the window. Gated separately
        // because it is a separate disclosure: `context` reads the terminal
        // around the box, this reads what you have typed into it, in every app.
        if startsDictation, InputBox.isConfigured(in: config) {
            let app = front?.app
            let element = focusAtPress?.element
            // By run, not into one slot. `pressRun` was bumped above, so this
            // is the run the dictation about to start will carry, and the one
            // its pipeline asks for. Dictations overlap.
            //
            // The slot is reserved here, on this thread, before the read is
            // dispatched. It is what `dictationEnded` removes, and what a read
            // that finishes late checks itself against.
            let run = pressRun
            InputBox.beginPress(run)
            DispatchQueue.global(qos: .userInitiated).async {
                InputBox.capturePress(run: run, app: app, element: element)
            }
        }

        // Before the recording starts, because starting it is what takes the
        // offer off the screen. A new dictation is one of the ways the offer
        // ends, so it is one of the ways the keys go back.
        endTheOffer()

        switch config.hotkey.mode {
        case .toggle:
            toggleRecording()
        case .pushToTalk:
            // Pressed again inside the tail: one dictation with a stutter in the
            // key, not two. Keep the recording that is already running — and put
            // the modifier poll back, since starting the tail took it down.
            if releaseTail != nil {
                releaseTail?.invalidate(); releaseTail = nil
                startPushToTalkPoll()
                return
            }
            guard !recorder.isRecording else { return }
            startRecording()
            startPushToTalkPoll()
        }
    }

    /// Climb the ladder in `CaretAnchor`, at the press. Called only from
    /// `handleHotKeyPress`, and only for a press that starts a dictation.
    private func readTheAnchor() {
        guard destinationAtPress.acceptsText else { return }

        // `focusAtPress` is not empty for a blind app — it holds whatever app
        // was focused before — so every rung below would measure the wrong
        // window. Measured on Codex: the pill anchored to a 712x44 box while
        // accessibility reported nothing focused in the app in front.
        if appAtPress.map({ AppProfile.of($0).anchor }) == .window {
            if let pid = pidAtPress, let found = CaretAnchor.window(of: pid) {
                anchorAtPress = found
                Log.write("pill: no caret — the app answers nothing; using its window")
            } else {
                Log.write("pill: no caret — the app answers nothing, and it has no window")
            }
            return
        }

        switch CaretAnchor.read(at: focusAtPress?.element) {
        case .found(let found):
            anchorAtPress = found
        case .missed(let why):
            // Rung 2.5, terminals only. There is no caret to read — Ghostty
            // answers `0+0` always — but the input line is on screen, and that
            // is where the words are about to go.
            //
            // Before rung 3, which a terminal cannot satisfy: it repaints
            // between dictations, so the digest never matches.
            if appAtPress.map({ AppProfile.of($0).readsPane }) == true,
               case .found(let box) = CaretAnchor.inputBox(at: focusAtPress?.element) {
                anchorAtPress = box
                Log.write(String(
                    format: "pill: no caret, so the input line it is — %.0f,%.0f %.0fx%.0f",
                    box.rect.minX, box.rect.minY, box.rect.width, box.rect.height
                ))
            }

            // Rung 3: open where the last dictation into this same element
            // landed. Two things have to hold, and both exist because a
            // remembered anchor looks confident while it is stale.
            //
            // The pane must still be showing what it showed when the words
            // landed. A terminal scrolls between dictations, so last time's
            // row then belongs to somebody else's line — which is how the pill
            // ends up sitting over the input box you are about to type into.
            //
            // Checked against the text and not against `AXNumberOfCharacters`,
            // which was the first answer and does not describe the screen at
            // all. See `CaretAnchor.paneDigest` for the measurement, and for
            // why a read that does not finish in time refuses.
            //
            // And the landing must be under a minute old. Refused, the pill
            // opens at the bottom of the screen and rung 4 moves it a moment
            // later: starting nowhere in particular beats starting somewhere
            // wrong.
            if anchorAtPress == nil {
                if let last = lastLanding, let now = focusAtPress?.element,
                   CFEqual(last.element, now),
                   Date().timeIntervalSince(last.at) < 60,
                   CaretAnchor.paneDigest(of: now) == last.digest {
                    anchorAtPress = CaretAnchor.Found(
                        rect: last.found.rect, text: last.found.text, source: .remembered
                    )
                } else {
                    Log.write("pill: no caret — \(why); will look for the words afterwards")
                }
            }

            // Rung 4: no caret to aim at, so take the pane as it is now and
            // find the words by what changed once they have landed. Off the
            // main thread, because this reads a value that has been observed
            // at 237k characters — and there are seconds of dictation before
            // anything needs it.
            let element = focusAtPress?.element
            let run = pressRun
            pressesInFlight.insert(run)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let before = CaretAnchor.snapshot(of: element)
                DispatchQueue.main.async {
                    // Kept for the press it was taken for, however many
                    // presses have started since and whether or not that press
                    // has already been retired: a short dictation can be
                    // written before this copy finishes, and refusing the pane
                    // then would leave the offer with nothing to compare
                    // against — which is the whole thing this exists to do.
                    // A pane nobody comes back for is a lifetime, not a leak,
                    // and the sweep below is what bounds it.
                    //
                    // Cancelled is the one exception, and the only one: that
                    // press is never going to write a word, so its pane is
                    // dropped here rather than waiting out the sweep. Taken out
                    // of the set as it is read, which is what keeps the set
                    // from growing. See `cancelledPresses`.
                    guard let self else { return }
                    guard self.cancelledPresses.remove(run) == nil else { return }
                    guard let before else { return }
                    let now = Date()
                    self.screenAtPress[run] = (before, now)
                    self.screenAtPress = self.screenAtPress.filter { run, pane in
                        self.pressesInFlight.contains(run)
                            || now.timeIntervalSince(pane.at) < Self.paneLifetime
                    }

                    // A short dictation can be transcribed and written while
                    // this copy is still running, so the offer can already be
                    // up and this press already retired. Retired is not
                    // cancelled: this is the one other moment the search can
                    // start, and it starts here — for this press alone, and
                    // only while the offer on screen is still the one it
                    // raised, which is a run-owned thing now and not a slot a
                    // later dictation can move. See `offeredCorrection`.
                    //
                    // Whether this snapshot is a *before* is left to the diff.
                    // Nothing here can know: the paste is a posted ⌘V and the
                    // app reads the pasteboard when it gets round to it, so the
                    // moment the words appear is not a moment this process can
                    // observe. A snapshot taken too late simply looks like an
                    // app that has not redrawn, which is the case the poll
                    // exists for — it times out and the pill stays where it
                    // opened. Rejecting on a clock instead would throw away the
                    // baselines that were in time as well.
                    guard self.offerIsUp, self.offerPressRun == run, let element
                    else { return }
                    self.findWhereTheWordsLanded(comparedWith: before, in: element, for: run)
                }
            }
        }
    }

    private func handleHotKeyRelease() {
        guard config.hotkey.mode == .pushToTalk else { return }
        // The character key is actually up now, so there is nothing left for
        // the modifier poll to catch — unlike the poll's own call below, where
        // the character key is still down and a flicked-back modifier means
        // the chord never really broke.
        pushToTalkPoll?.invalidate(); pushToTalkPoll = nil
        stopRecordingAfterTail()
    }

    /// The hand is faster than the mouth: the key comes up while the last
    /// syllable is still being said, and the clip ends "...max retri". So hold
    /// the mic open a moment longer — `hotkey.release_tail_seconds`, 0 to stop
    /// on the release as before.
    private func stopRecordingAfterTail() {
        guard recorder.isRecording else { return }

        let tail = config.hotkey.releaseTailSeconds
        guard tail > 0 else {
            stopRecording()
            return
        }
        guard releaseTail == nil else { return }

        let timer = Timer(timeInterval: tail, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.releaseTail = nil
            self.stopRecording()
        }
        RunLoop.main.add(timer, forMode: .common)
        releaseTail = timer
    }

    /// Carbon only reports the release of the *character* key. If the user lets
    /// go of ⌃ or ⌥ first, no release event arrives — so poll the live modifier
    /// state too. `NSEvent.modifierFlags` is a plain read and needs no permission.
    ///
    /// Not needed for a bare-modifier hotkey: `ModifierKeyMonitor` is already
    /// edge-detecting that exact key and will deliver its own release.
    private func startPushToTalkPoll() {
        pushToTalkPoll?.invalidate()
        pushToTalkPoll = nil

        guard hotKeys.binding?.isModifierOnly == false else { return }
        let required = KeyCodes.cocoaModifiers(config.hotkey.modifiers)
        guard !required.isEmpty else { return }

        let timer = Timer(timeInterval: 0.06, repeats: true) { [weak self] _ in
            guard let self, self.recorder.isRecording else { return }
            let held = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if held.isSuperset(of: required) {
                // The modifier is back and the character key never came up —
                // Carbon has no press event for that, since it only edge-
                // detects the character key, so the poll is what has to
                // notice the chord is whole again and call off the tail it
                // started.
                if self.releaseTail != nil {
                    self.releaseTail?.invalidate(); self.releaseTail = nil
                }
            } else if self.releaseTail == nil {
                // The same event as a release, found a different way, so it
                // ends the recording the same way — through the tail. Keep
                // polling through the tail itself: this is the one path where
                // the modifier can still come back before the character key
                // does.
                self.stopRecordingAfterTail()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pushToTalkPoll = timer
    }

    // MARK: - Recording

    private func toggleRecording() {
        guard recorder.isRecording else {
            startRecording()
            return
        }
        stopRecording()
    }

    private func startRecording() {
        guard !recorder.isRecording else { return }

        guard Permissions.microphone == .granted else {
            Permissions.requestMicrophone { [weak self] granted in
                guard let self else { return }
                self.permissions.model.refresh()
                if granted {
                    self.startRecording()
                } else {
                    // Not `.installing`: the app has been running for a while
                    // by the time someone presses the hotkey, and a refusal
                    // here should not offer to cancel an install that finished
                    // days ago.
                    self.dictationCancelled(self.pressRun)
                    self.permissions.show(.revisiting)
                }
            }
            return
        }

        do {
            try recorder.start(config: config)
            // The engine's own device, asked here rather than when the
            // transcript comes back. Not the system default: that is a
            // different question the moment a headset connects, and the notice
            // is about the microphone these words went through. See
            // `Recorder.boundDevice`.
            micAtPress = recorder.boundDevice
        } catch {
            // A notice, not an alert. `runModal` holds the main run loop, and
            // the hotkey is delivered on it: one failed press behind a modal
            // and every press after it does nothing, which is indistinguishable
            // from the app having died — and is what happened whenever the
            // microphone changed underneath it. Logged as well, because this
            // path used to leave the log showing a press and then silence.
            Log.write("could not start recording: \(error.localizedDescription)")
            // Standing, not only flashed. A press that starts nothing is the
            // failure people describe as "the app stopped working", and a
            // notice that fades in four seconds is gone by the time they look.
            captureProblem(error.localizedDescription)
            dictationCancelled(pressRun)
            return
        }

        watchForEscape()

        playFeedback("Tink")
        if config.feedback.overlay {
            // Under the selection when there is one and this is a command: the
            // words are about those words, and the pill belongs with them.
            if keyedAtPress, let selection = selectionAtPress {
                aim(at: selection)
            } else {
                pill.aim(at: anchorAtPress)
            }
            pill.recording(icon: appIconAtPress, label: recordingLabel)
        }

        let tick = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let started = self.recorder.startedAt else { return }
            self.pill.model.elapsed = Date().timeIntervalSince(started)
            self.updateUI()
        }
        RunLoop.main.add(tick, forMode: .common)
        tickTimer = tick

        updateUI()
    }

    // MARK: - Escape

    private enum CancelReason {
        case escape
        /// The hotkey was the front half of a shortcut, and the dictation
        /// started on its down edge has to go — see `ModifierKeyMonitor`.
        case notTheHotkey
    }

    /// Stop a dictation that is already under way.
    ///
    /// Escape is the one key everybody already presses to mean "not that". You
    /// say the wrong sentence, or you realise mid-sentence that the model is
    /// about to rewrite it into the wrong window, and the only way out was to
    /// let it finish and undo it afterwards.
    ///
    /// It works with the hotkey still held. In push-to-talk the key is down for
    /// the whole dictation, so a cancel that needed you to let go first would be
    /// no cancel at all — the release is what commits the recording. Stopping
    /// the recorder here means the later release finds nothing recording and
    /// does nothing, which is exactly right.
    ///
    /// Two states, and both are cancellable because both are waits you can
    /// regret. A recording ends without being transcribed. A transcription in
    /// flight is marked so its result is dropped when it lands: the model call
    /// is not interruptible, so this cannot make it stop sooner — it only makes
    /// sure nothing is written when it does.
    private func cancelDictation(_ reason: CancelReason = .escape) {
        let recording = recorder.isRecording
        // A run is in flight when one has been started and nothing has retired
        // it yet. `transcriptionRun` is bumped per dictation and already carries
        // through the whole chain, so it is the identity to cancel against.
        // An abort takes the dictation its own press started and nothing else.
        // Push-to-talk does not wait for the previous transcript, so a
        // transcription is routinely in flight from an earlier press while this
        // one records — and those words were said on purpose. You pressed ⌘S;
        // you are not asking for the sentence you finished a second ago to be
        // thrown away. Escape still means the lot, which is what Escape is for.
        let startedItsOwn = transcriptionRun > transcriptionRunAtPress
        let transcribing = transcriptionLabel != nil
            && (reason == .escape || startedItsOwn)
        guard recording || transcribing else { return }

        if recording {
            // The clip on disk is left alone, unless `logging.audio` says
            // recordings do not accumulate at all. Kept, it cost nothing to
            // write, the recordings folder is where you go to find out what
            // the app heard, and deleting the evidence of the thing you just
            // cancelled is the opposite of useful when the reason you
            // cancelled it was that something sounded wrong.
            if let clip = recorder.stop(config: config) {
                Recorder.discardIfNotKept(clip, config: config)
            }
            // No words are coming, so this press's dictation is over here. The
            // recorder is stopped directly rather than through
            // `stopRecording`, so nothing else would retire it — and the pane
            // it took is the largest thing the app holds. A snapshot still
            // being copied lands on a run that has already gone and is dropped.
            dictationCancelled(pressRun)
            tickTimer?.invalidate(); tickTimer = nil
            pushToTalkPoll?.invalidate(); pushToTalkPoll = nil
            releaseTail?.invalidate(); releaseTail = nil
            pill.hide()
        }
        if transcribing {
            cancelledThroughRun = transcriptionRun
            endProgress(token: dictationProgressToken, for: transcriptionRun)
        }

        stopWatchingForEscape()
        // Unconditional above, because a cancel takes the monitors whether or
        // not a newer press is still running. This is the other half: cancelling
        // can also be the moment the app goes idle, and what waits on idle —
        // an offer's keys, a held key prompt — is the helper's to hand over. It
        // guards on idle itself, so a cancelled transcription that is still in
        // flight hands over nothing until it lands.
        stopWatchingForEscapeIfIdle()
        switch reason {
        case .escape:
            playFeedback("Pop")
            Log.write("escape: cancelled while \(recording ? "recording" : "transcribing")")
            flash(recording ? "Recording cancelled" : "Transcription cancelled", tone: .caution)
        case .notTheHotkey:
            // Silent, and deliberately so. The user pressed ⌘S and is owed a
            // save. A notice about a dictation they never started would be an
            // apology for something they are not supposed to have seen.
            Log.write("hotkey: dropped — the modifier was part of a shortcut")
        }
        updateUI()
    }

    /// Whether this run was cancelled and must not be delivered.
    private func wasCancelled(_ run: Int) -> Bool { run <= cancelledThroughRun }

    /// Listen for Escape while there is something to cancel, and only then.
    ///
    /// Two monitors because they cover different halves. The global one sees
    /// keys while another app is in front, which is every ordinary dictation.
    /// The local one sees them while a panel of ours is up.
    ///
    /// A global monitor observes and does not consume, so Escape still reaches
    /// the app you are typing into. That is deliberate rather than a limitation:
    /// swallowing it would need an event tap over every keystroke on the
    /// machine, and pressing Escape to stop a dictation into a TUI usually means
    /// you want the TUI to see it too.
    ///
    /// Installed when recording starts and removed when the dictation is over,
    /// so an idle app is not watching the keyboard at all.
    private func watchForEscape() {
        guard escapeMonitors.isEmpty else { return }
        // Through `KeyCodes` rather than Carbon directly. That table is already
        // the one place in the app that knows what a key is called, and it is
        // what a `hotkey:` of "escape" would resolve through.
        guard let escape = KeyCodes.code(for: "escape") else { return }
        let cancel: (NSEvent) -> Void = { [weak self] event in
            guard event.keyCode == UInt16(escape) else { return }
            DispatchQueue.main.async { self?.cancelDictation() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: cancel) {
            escapeMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: {
            cancel($0)
            return $0
        }) {
            escapeMonitors.append(local)
        }
    }

    /// Take the monitors down only when there is nothing left to cancel.
    ///
    /// One dictation finishing is not the end of dictation. Hold the key again
    /// while a prompt stage is still running and the newer recording shares this
    /// pair, having found them already installed — so an unconditional teardown
    /// on the older run's completion would leave the newer one uncancellable,
    /// and the bug would only show up on the second press.
    private func stopWatchingForEscapeIfIdle() {
        guard !recorder.isRecording, runsInFlight <= 0 else { return }
        stopWatchingForEscape()
        // The same moment, read the other way round: Escape has nothing left to
        // cancel, so an offer that was raised while a dictation was still
        // running can have its keys now. See `watchTheOfferKeys`.
        if offerIsUp, !offerKeys.isRunning { watchTheOfferKeys() }
        // And a key prompt the same dictation pushed back. Async so this run's
        // completion unwinds before a modal blocks the main queue.
        if keyPromptDeferred {
            keyPromptDeferred = false
            DispatchQueue.main.async { [weak self] in self?.askForMissingKeys() }
        }
    }

    private func stopWatchingForEscape() {
        escapeMonitors.forEach(NSEvent.removeMonitor)
        escapeMonitors.removeAll()
    }

    private func stopRecording(reason: String? = nil) {
        guard recorder.isRecording else { return }

        let recording = recorder.stop(config: config)

        tickTimer?.invalidate(); tickTimer = nil
        pushToTalkPoll?.invalidate(); pushToTalkPoll = nil
        releaseTail?.invalidate(); releaseTail = nil
        pill.hide()
        playFeedback("Pop")

        // Transcription takes the watch over from here — it is the other half
        // of the dictation Escape can still stop. With transcription off there
        // is nothing left to cancel, so it ends now.
        if !config.transcription.enabled { stopWatchingForEscapeIfIdle() }

        if let recording {
            lastRecording = recording
            Log.write(String(format: "wrote %@ (%.2fs)", recording.url.lastPathComponent, recording.duration))
            if config.transcription.enabled {
                transcribe(recording)
            } else {
                // Nothing is going to read the file — `transcribe` is what
                // would otherwise discard it once it is done.
                Recorder.discardIfNotKept(recording, config: config)
            }
        }

        // A clip too short to keep, or transcription switched off: no words are
        // coming, so this press's dictation ends here. Everything that does
        // reach a transcript ends on one of `transcribe`'s own paths.
        if recording == nil || !config.transcription.enabled {
            dictationCancelled(pressRun)
        }

        if let reason {
            // A notice, not an alert, for the reason already written above
            // `startRecording`'s catch: `runModal` holds the main run loop, the
            // hotkey is delivered on it, and one modal behind a device change
            // makes every press after it do nothing — which is exactly the
            // sequence in #95, an alert saying the device changed followed by a
            // hotkey that answers nothing. The message outlives the notice in
            // the menu bar, so nothing is lost by not blocking for it.
            Log.write("recording stopped: \(reason)")
            captureProblem(reason)
        }

        updateUI()
    }

    /// A capture that went wrong, said twice: once on screen now, and once in
    /// the menu bar until a recording goes right.
    ///
    /// Nil is the recording that went right, which is what clears it. The
    /// recorder reports every stop, so a device change that ended a take which
    /// nonetheless captured real audio clears itself — nothing was lost, and a
    /// standing warning about a dictation that arrived is a warning people
    /// learn to ignore.
    private func captureProblem(_ problem: String?) {
        standingCaptureProblem = problem
        if let problem {
            flash(problem, tone: .failure)
        }
        updateUI()
    }

    // MARK: - Transcription

    /// The app in front right now, or nil if there isn't one to name.
    ///
    /// The icon rides along rather than being fetched when the pill is built,
    /// because those are two different questions asked a moment apart: this one
    /// is "who was in front when the key went down", and the pill has to show
    /// the same answer the pipeline will be conditioned on. Reading NSWorkspace
    /// twice would let them disagree, and the one time they disagree is exactly
    /// the time the pill is worth having.
    private static func appInFront() -> (app: Pipeline.App, icon: NSImage?, pid: pid_t)? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        let app = Pipeline.App(
            name: front.localizedName ?? "", bundleID: front.bundleIdentifier ?? ""
        )
        // Both empty is not an app you could write a condition against, and
        // saying so is what makes `app:` fail closed instead of matching "  ".
        guard !app.searchable.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return (app, front.icon, front.processIdentifier)
    }

    private func transcribe(_ recording: Recorder.Recording) {
        transcriptionRun += 1
        runsInFlight += 1
        let run = transcriptionRun
        // On the HUD and not just in the menu. Releasing the key hides the
        // recording pill, and everything after it — the decoder, then any
        // prompt stage the pipeline runs — used to report itself only into
        // `statusInfoItem.title`, a row you have to open the menu bar to read.
        // A dictation into a mail window spends a second in the `email` prompt
        // with nothing on screen at all, which reads as the app having dropped
        // it. Same pair the spoken-command path has used all along.
        // "Transcribing…" is a lie while the model is still arriving, and the
        // first dictation after an install is exactly when that happens: the
        // download is about 470 MB and the pill would sit on one word for all
        // of it. Say what is actually happening, with the figure.
        var starting = "Transcribing…"
        // Only a download this dictation is waiting on. A background fetch is
        // running while the words are being decoded, and the pill would tell
        // the user to wait for something that is not in their way.
        if case .downloading(let what, blocking: true) = transcriberStatus {
            pillDownloadRun = run
            starting = "Downloading \(what)"
        }
        let token = beginProgress(starting)
        dictationProgressToken = token

        let config = self.config
        // Taken at the press, not here: a transcript arrives seconds later and
        // the window you dictated into may not be the one in front by then.
        let app = appAtPress
        // Carried down the chain from here for the same reason, plus one of its
        // own. Push-to-talk does not wait for the previous transcript — hold the
        // key again while a prompt stage is still running and two are in flight,
        // which is what `transcriptionRun` exists to survive. Read off `self` at
        // the end instead, the older dictation would be delivered by the newer
        // press's verdict: copied when it had a field to go in, or pasted into a
        // window that has nothing to put it in.
        let destination = destinationAtPress
        // And where it was being typed, for the same reason. The inline
        // correction panel hands focus back to this app before writing, and it
        // can be left open for as long as it takes to think about a spelling —
        // longer than any other wait in the app, and long enough to start
        // another dictation somewhere else while it sits there.
        let focus = focusAtPress
        // And the press itself, frozen the same way and for the same reason.
        // `pressRun` is still this dictation's here: a press that ends a
        // recording does not bump it — see `handleHotKeyPress`.
        // And the microphone that recorded it, read when the engine opened the
        // device. Taken here rather than read at the end for the same reason as
        // the rest: the default input can change while the decoder runs.
        let press = Press(
            run: pressRun, element: focus?.element, owner: focus?.owner, mic: micAtPress,
            // Plain when nobody was in front, which is the answer that cannot
            // lose a sentence.
            paste: appAtPress.map { AppProfile.of($0).paste } ?? .plain,
            keyed: keyedAtPress,
            // Still this press's: the recording has only just stopped and no
            // newer press can have landed. The gap this closes is the decode
            // that follows, not this moment.
            selection: selectionAtPress,
            // The dictation before this one, which is what a command with
            // nothing selected is about.
            transcript: lastTranscript
        )
        Task { [weak self] in
            // Whatever happens below — decoded, cancelled, or thrown — nothing
            // needs the clip on disk once this dictation is over.
            defer { Recorder.discardIfNotKept(recording, config: config) }
            do {
                // The decoder's own words, kept for the offer to colour. Only
                // when something is going to draw them: the decoder produces
                // the timings either way, and this is the one line that keeps a
                // copy of them. Written out rather than left as a ternary in
                // the call below, where the `nil` has no type to take.
                var heard: (@Sendable (Transcriber.Decode) -> Void)?
                if config.feedback.confidence || config.feedback.warnsOnLowConfidence {
                    heard = { decode in
                        Task { @MainActor [weak self] in
                            self?.heardAtPress[press.run] = decode
                        }
                    }
                }
                // "Transcribing…" is the truth until the decoder is done, and
                // a lie for the second a prompt or a script spends after it.
                // A stage that wrote a `display:` says so itself.
                // The trace is opened around the whole chain, not just the
                // decoder: the stages that follow write into the same record,
                // and the line is appended even if one of them throws.
                let text = try await Trace.record(
                    wav: recording.url.lastPathComponent, source: .live,
                    app: app.map { Trace.App(name: $0.name, bundleID: $0.bundleID) },
                    beside: recording.url.deletingLastPathComponent()
                ) {
                    let text = try await self?.transcriber.transcribe(
                        url: recording.url, config: config, app: app, press: press.run,
                        progress: { label in
                            Task { @MainActor [weak self] in
                                // Only over this dictation's own message. A
                                // second press, or a command, and the pill is
                                // no longer ours to write on.
                                self?.updateProgress(label, token: token)
                            }
                        },
                        heard: heard
                    ) ?? ""
                    Trace.current?.recordFinal(text)
                    return text
                }
                await MainActor.run {
                    guard let self else { return }
                    // The token is what makes this only take down our own
                    // message. Push-to-talk does not wait, so a second press
                    // while this one was in flight has already put its own
                    // "Transcribing…" up, and clearing that would leave the
                    // newer dictation running behind a blank pill. Same for a
                    // spoken command or an update that took the pill.
                    // The text is delivered either way: `destination` was
                    // captured at the press for exactly that reason.
                    self.endProgress(token: token, for: run)
                    // Escape, while this was decoding. The decoder cannot be
                    // stopped part-way, so the text exists — it simply goes
                    // nowhere. Logged, because a dictation that vanishes with
                    // no line in the log is indistinguishable from one that
                    // failed silently.
                    self.runsInFlight -= 1
                    guard !self.wasCancelled(run) else {
                        Log.write("escape: dropped the transcript of a cancelled run")
                        self.dictationCancelled(press.run)
                        self.stopWatchingForEscapeIfIdle()
                        self.updateUI()
                        return
                    }
                    self.stopWatchingForEscapeIfIdle()
                    self.finishTranscription(
                        text: text, destination: destination, focus: focus, for: press
                    )
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.endProgress(token: token, for: run)
                    self.runsInFlight -= 1
                    self.stopWatchingForEscapeIfIdle()
                    // Cancelled or failed, nothing is going to be written.
                    self.dictationCancelled(press.run)
                    guard !self.wasCancelled(run) else { return }
                    Log.write("transcription failed: \(error.localizedDescription)")
                    self.presentAlert(title: "Transcription failed", message: error.localizedDescription)
                    self.updateUI()
                }
            }
        }
    }

    /// The model a job runs on — see `Config.model(for:)`.
    private func llmConfig(for job: Config.ModelJob = .general) -> ModelSpec {
        config.model(for: job)
    }

    /// Loads the Ollama model now, so the first correction doesn't pay for it.
    ///
    /// A correction costs 6.7s cold and 1.5s warm, and Ollama drops the model
    /// after five minutes idle — so in a day of real use nearly every one was
    /// cold. Launch is the one moment when nobody is waiting on it.
    ///
    /// Only at launch, deliberately: `applyConfig` runs on every save of
    /// config.yaml, and re-warming there would fire a multi-GB load each time
    /// the file is touched.
    private func warmUpLLM() {
        // Whatever the router runs on: it is the call anybody waits on. Nothing
        // to warm up when that is not a local model — `LocalLLM.warmUp` says so
        // too, and this saves the task.
        let llm = llmConfig(for: .router)
        guard config.llmEnabled, llm.keepLoaded, llm.api == .ollama else { return }
        let system = Router.prompt(
            for: Catalogue(transforms: config.transforms), freeForm: config.freeForm
        )
        Task.detached(priority: .background) {
            let started = Date()
            let loaded = await LocalLLM.warmUp(config: llm)
            let elapsed = Date().timeIntervalSince(started)
            Log.write(
                loaded
                    ? String(format: "llm: %@ loaded and pinned in %.1fs", llm.model, elapsed)
                    : "llm: could not preload \(llm.model) — is Ollama running?"
            )
            guard loaded else { return }

            // A pinned model can be resident and still cold — see
            // `LocalLLM.keepWarm` — so this closes the gap before
            // `startKeepWarm`'s first 15s tick instead of waiting for it.
            let warmed = await LocalLLM.keepWarm(system: system, config: llm)
            Log.write(warmed ? "llm: warmed with one generate call" : "llm: warm-up generate ping failed")
        }
    }

    /// Every model the app will use, fetched at launch rather than on the
    /// dictation that first wants one. About 1.16 GB on a default install:
    /// Parakeet 461 MB, ModernBERT 288 MB, the word vectors 335 MB, the sound
    /// model 81 MB.
    ///
    /// Each of these used to arrive on first use, and each of them therefore
    /// had a window where the thing it powers was switched on and silently
    /// doing nothing. `SentenceGate` will not make a dictation wait on a load,
    /// so it skipped; `SentenceJoin` did the same. "Versailles is a fantastic
    /// castle" shipped as "Vercel is a fantastic castle" inside one of those
    /// windows, and nothing on screen said why.
    ///
    /// The dictation path still calls both. A fetch that fails clears itself,
    /// and the next English dictation is the next chance.
    private func warmModels() {
        guard config.transcription.enabled else { return }
        let transcriber = transcriber
        let config = config
        Task.detached(priority: .background) {
            // Speech first, on its own. Nothing can be transcribed until it
            // lands, and it is the only one somebody is waiting for. Started
            // together, four fetches share the connection and the one that
            // gates the app finishes last.
            //
            // `transcriber.prepare` is safe to call again from `transcribe(...)`
            // once this is in flight: overlapping callers converge on the same
            // download rather than racing two.
            let started = Date()
            do {
                try await transcriber.prepare(config: config)
                Log.write(String(
                    format: "transcriber: warmed up in %.1fs", Date().timeIntervalSince(started)
                ))
            } catch {
                // Nothing else is worth fetching. Without speech the app
                // cannot transcribe at all, so 700 MB more buys nothing, and
                // whatever stopped this will most likely stop those too. Each
                // has its own retry on the dictation that first needs it.
                Log.write("transcriber: warm-up failed — \(error.localizedDescription);"
                    + " the other models are left for first use")
                return
            }

            // The rest together, once speech is in. None of them blocks a
            // dictation: the stages that read them stand aside until they are
            // in memory.
            await transcriber.warmSentenceModel()
            // 81 MB, and the sound pass is on by default.
            Task.detached(priority: .background) {
                guard await !NeuralPhonemes.isReady() else { return }
                do { try await NeuralPhonemes.download() } catch {
                    Log.write("sound model: \(error.localizedDescription); the next"
                        + " dictation that needs it tries again")
                }
            }
            // 335 MB, and only the sentence gate reads them. Someone who turns
            // the gate off should not pay for it.
            if #available(macOS 14, *), config.vocabulary.gateSentence {
                Task.detached(priority: .background) { await WordVectors.shared.warm() }
            }
        }
    }

    /// Keeps the model warm by running one token a minute through it.
    ///
    /// See `LocalLLM.keepWarm` for why loading it once at launch is not enough.
    /// A minute is under Ollama's own five, and well under the gaps that were
    /// producing 4–11s routes in the log.
    ///
    /// Ticking every 15s rather than every 60s is what makes "a minute since
    /// the last call" mean it: a timer that only fires on the minute is in
    /// whatever phase launch left it in, so a real command landing just before
    /// a tick pushes the next ping most of a second minute away — which is the
    /// gap being closed. The tick itself is a date comparison, and only reaches
    /// the network on the one in four that has earned it.
    ///
    /// Unlike `warmUpLLM` this is safe to restart from `applyConfig`, because
    /// it costs a timer rather than a multi-GB load.
    private func startKeepWarm() {
        keepWarmTimer?.invalidate()
        keepWarmTimer = nil
        let router = llmConfig(for: .router)
        guard config.llmEnabled, router.keepLoaded, router.api == .ollama else { return }

        let timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.keepWarmTick()
        }
        // Nothing waits on this, so let the OS coalesce it with other wakeups.
        timer.tolerance = 5
        keepWarmTimer = timer
    }

    private func keepWarmTick() {
        // A ping that is still in flight is a cold model being fetched — the
        // slow case this exists for. Without the guard every tick through it
        // would queue another, and the pile would land together.
        guard !keepWarmInFlight else { return }
        guard Date().timeIntervalSince(LocalLLM.lastCallAt) >= 60 else { return }

        let llm = llmConfig(for: .router)
        guard llm.api == .ollama else { return }
        // The same string the router will send, `free_form` included: what is
        // being kept warm is Ollama's prompt cache, and a system prompt that
        // differs by one line is a cache miss and the 3.5s this exists to avoid.
        let system = Router.prompt(
            for: Catalogue(transforms: config.transforms), freeForm: config.freeForm
        )
        keepWarmInFlight = true
        Task.detached(priority: .background) { [weak self] in
            await LocalLLM.keepWarm(system: system, config: llm)
            await MainActor.run { self?.keepWarmInFlight = false }
        }
    }

    /// Everything said after the wake phrase, or nil when this is plain
    /// dictation. Empty string means the phrase was said on its own.
    ///
    /// Matched word by word on a normalised copy but returned from the
    /// original, so "Tasmin spells T A S M E E N" keeps its capitals — the
    /// spelling is the whole point of the command.
    private func commandAfterWakePhrase(_ text: String) -> String? {
        VoiceCommand.commandAfterWakePhrase(
            text, phrases: config.transcription.activationPhrases
        )
    }

    /// `keyed` — a keystroke said this was an instruction, before a word of it
    /// was spoken.
    ///
    /// The alternative is *heard*: the phrase was found inside a sentence by a
    /// fuzzy matcher, which fires at 0.55 a word against a 0.7 floor because
    /// "hey parrot" arrives clipped. It can be wrong, and `tests/wake-cases.txt`
    /// holds the sentences about parrots it must not fire on. Everything the
    /// two paths do differently follows from that one difference.
    ///
    /// Keyed skips two things, and both are insurance against that doubt:
    ///
    /// - **The router.** It answers two questions, and the first is "was this
    ///   an edit at all". A key has already answered it. What is left is
    ///   "which tool", which the name match answers for free or the catch-all
    ///   answers by taking the whole instruction as its specification.
    /// - **The preview.** Tap-then-hold has already named its target on the
    ///   pill and offered ⎋ for the whole time you were speaking, and "hey
    ///   parrot, undo" puts the substitution back afterwards — so a preview is
    ///   a question that was answered twice before it was asked. It reaches
    ///   `finishTransform` as `confirm: !keyed`, because that leaf's job is
    ///   previewing and it should stay honest about it.
    ///
    /// The saving is a model call in series. Heard costs a router round trip
    /// and then the transform's own; keyed costs one, or none.
    private func handleVoiceCommand(
        _ command: String, keyed: Bool = false,
        over target: Target = .whateverIsSelected
    ) {
        let catalogue = Catalogue(transforms: config.transforms)

        // Deterministic phrases first: no model needed, and they work when
        // Ollama is not running. This also covers the wake phrase said on its
        // own, which means the panel rather than anything the router could pick.
        if let local = VoiceCommand.local(from: command) {
            // Nothing on the pill is ours: no model was asked, so no
            // "Thinking…" went up. The target still travels: this path opens
            // the correction panel, which reads the selection slot, and a
            // command that was decoded while a newer press filled that slot
            // would open over the newer selection.
            apply(local, command: command, progress: nil, over: target)
            return
        }
        if let capability = Router.local(
            instruction: command, catalogue: catalogue, anywhere: keyed
        ) {
            Log.write("router: \"\(command)\" named \(capability.name) outright")
            run(
                capability, instruction: command,
                progress: nil, confirm: !keyed, over: target
            )
            return
        }

        // Keyed and named nothing: the catch-all, with no router in between.
        //
        // This is the change that makes the gesture worth using. Asking a model
        // which tool you meant, and then asking a model to do the work, is two
        // waits where the first one usually reports what the second was going
        // to do anyway. The name match above is what keeps the other bodies
        // reachable — a script and a table are not prompts, and the catch-all
        // is, so it can stand in for a prompt and for nothing else.
        if keyed {
            guard let catchAll = config.commands.catchAll, config.freeForm else {
                Log.write("keyed: \"\(command)\" named nothing and the catch-all is off")
                flash("No transform called \"\(command)\"", tone: .caution)
                return
            }
            Log.write("keyed: \"\(command)\" → \(FreeForm.name), no router")
            runTransform(
                FreeForm.prompt(for: command).asTransform(model: catchAll),
                instruction: command, progress: nil, confirm: false, over: target
            )
            return
        }

        guard config.llmEnabled else {
            flash("Didn't understand \"\(command)\" — enable llm in config for free-form commands", tone: .caution)
            return
        }

        let token = beginProgress("Thinking…")
        let llmConfig = llmConfig(for: .router)
        let freeForm = config.freeForm
        let catchAll = config.commands.catchAll

        Task { [weak self] in
            do {
                let decision = try await Router.route(
                    instruction: command,
                    catalogue: catalogue,
                    freeForm: freeForm,
                    config: llmConfig
                )
                await MainActor.run {
                    guard let self else { return }
                    switch decision {
                    case .matched(let capability):
                        Log.write("router: \"\(command)\" → \(capability.name)")
                        self.run(
                            capability, instruction: command,
                            progress: token, over: target
                        )
                    case .anything:
                        // An edit with no prompt behind it. The instruction is
                        // the whole specification, so it goes through unsplit,
                        // exactly as it would to a prompt of your own.
                        Log.write("router: \"\(command)\" → \(FreeForm.name)")
                        self.runTransform(
                            FreeForm.prompt(for: command).asTransform(model: catchAll),
                            instruction: command, progress: token, over: target
                        )
                    case .none:
                        // Nothing fits. Deliberately not falling through to
                        // dictation: the wake phrase means you were not
                        // dictating, and typing the instruction into the
                        // document is the one failure that writes nonsense
                        // without saying so.
                        //
                        // With free_form on this is the narrower verdict "that
                        // was not an edit at all", so it says so — the two
                        // reasons want different fixes, and "no prompt for it"
                        // would send you writing one that would never be used.
                        self.endProgress(token: token)
                        Log.write("router: nothing matched \"\(command)\"")
                        self.flash(freeForm
                            ? "Not something to change in the text: \"\(command)\""
                            : "No prompt for \"\(command)\"", tone: .caution)
                    }
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    Log.write("routing failed: \(error.localizedDescription)")
                    self.endProgress(token: token)
                    let asked = self.askForKeyThenRetry(error) {
                        self.handleVoiceCommand(command, keyed: keyed, over: target)
                    }
                    if !asked { self.flash(error.localizedDescription, tone: .failure) }
                }
            }
        }
    }

    /// Runs whatever the router picked.
    ///
    /// `progress` is the "Thinking…" the router put up, where a router ran, so
    /// whichever branch ends without putting its own message up takes that one
    /// down and nothing else.
    private func run(
        _ capability: Capability, instruction: String,
        progress token: Int?, confirm: Bool = true,
        over target: Target = .whateverIsSelected
    ) {
        switch capability {
        case .action(.vocabulary):
            endProgress(token: token)
            beginCorrection(over: target)
        case .action(.spelling):
            interpretSpelling(instruction, progress: token, over: target)
        case .transform(let transform):
            runTransform(
                transform, instruction: instruction,
                progress: token, confirm: confirm, over: target
            )
        }
    }

    /// Runs any of the three bodies over text and gives back the result.
    ///
    /// The one place that knows how a transform is made, so the two paths that
    /// reach one by voice — over your selection, and inline in a dictation —
    /// cannot disagree about what running it means. It mirrors
    /// `Pipeline.runTransform`, which does the same job for a stage.
    ///
    /// The spoken instruction reaches a `prompt:` and nothing else. A script
    /// and a table take text on one side and give text on the other; there is
    /// nowhere to put "in French" and no honest way to invent one. Saying it
    /// anyway is harmless — the words are consumed by the routing and the
    /// transform runs — and is the reason `--check-config` names what each
    /// capability is made of.
    private func perform(
        _ transform: Config.Transform, instruction: String, on text: String
    ) async throws -> String {
        switch transform.body {
        case .prompt:
            guard let prompt = transform.asPrompt else { return text }
            return try await PromptRunner.run(
                prompt: prompt, instruction: instruction, text: text,
                config: config.model(for: transform)
            )
        case .replace:
            // `expand:`, or a table reached by voice compiles `{{determiners}}`
            // to nothing while the same table in a pipeline works.
            return Replacements.exact(
                to: text, rules: transform.rules, expand: config.expanded
            ).text
        case .command(let command):
            // Nil is every way a program can fail, and in a pipeline it means
            // keep the text — a stage that fails must not cost you a sentence.
            //
            // Asked for by name it means something else. You said "use slack
            // handles", the script did not run, and returning the text
            // unchanged makes that indistinguishable from a script that ran
            // and found nothing to do: the selection path then says "nothing
            // to change" and the inline path says nothing at all. Both are
            // describing a transform that worked. So this throws, and the
            // failure paths both callers already have get to do their job.
            guard let result = CommandRunner.run(
                command, on: text, in: transform.folder, seconds: transform.timeout
            ) else { throw CommandDidNotRun(name: transform.name) }
            return result
        }
    }

    /// A `command:` transform that produced no rewrite, asked for by name.
    ///
    /// The log already carries which of the ways it went wrong — could not
    /// start, exited non-zero, took too long, said nothing — and that is more
    /// than fits on screen. What belongs on screen is that it did not run.
    private struct CommandDidNotRun: LocalizedError {
        let name: String
        var errorDescription: String? {
            "\(name) did not run — the log says what it said"
        }
    }

    /// The spelling extractor, which is a second model call rather than part of
    /// routing — it reads the last transcript and returns a rule, not a name.
    private func interpretSpelling(
        _ command: String, progress inherited: Int?,
        over target: Target = .whateverIsSelected
    ) {
        guard config.llmEnabled else {
            endProgress(token: inherited)
            flash("Didn't understand \"\(command)\" — enable llm in config for free-form commands", tone: .caution)
            return
        }

        let token = beginProgress("Thinking…")
        let llmConfig = llmConfig()
        // The dictation the spelling is about, frozen with the command that
        // asked. This one reads the transcript for its whole job — "Tasmin
        // spells T A S M E E N" finds the word in what you said before — so a
        // newer dictation replacing it while the router thought would have sent
        // the model looking in the wrong sentence.
        let context: String?
        switch target {
        case .frozen(_, let fallback): context = fallback
        case .whateverIsSelected: context = lastTranscript
        }
        // From the transcript, never the command: the command is short and its
        // trigger word plus a run of loose capitals reads as English whatever
        // was actually said.
        let language = DictationLanguage.forCorrection(
            transcript: context, allowed: config.transcription.languages
        )
        if config.transcription.languages.count > 1 {
            Log.write("command: prompting in \(language)")
        }

        Task { [weak self] in
            do {
                let result = try await VoiceCommand.interpret(
                    command: command, lastTranscript: context,
                    language: language, config: llmConfig
                )
                await MainActor.run {
                    self?.apply(result, command: command, progress: token, over: target)
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    Log.write("command interpretation failed: \(error.localizedDescription)")
                    self.endProgress(token: token)
                    let asked = self.askForKeyThenRetry(error) {
                        // The message above is already down, so the retry
                        // inherits nothing. The target is not nothing: a retry
                        // happens after a key dialog, which is all the time a
                        // newer dictation needs to land, and reading the slot
                        // then would correct that one instead.
                        self.interpretSpelling(command, progress: nil, over: target)
                    }
                    if !asked { self.flash(error.localizedDescription, tone: .failure) }
                }
            }
        }
    }

    // MARK: - Transforms

    /// Where a transform's target comes from.
    ///
    /// Two cases rather than an optional selection, because the answer
    /// "nothing was selected" and the answer "nobody said" are different and an
    /// optional cannot hold both. Flattened into one, a command that began with
    /// nothing selected fell through to the shared slot and picked up whatever
    /// a newer press had put there — the same crossing `Press.selection` exists
    /// to stop, surviving in the nil case.
    private enum Target {
        /// Read the selection now. The menu and the offer run while the slot is
        /// still the press's own.
        case whateverIsSelected
        /// What a spoken command froze when its recording began: the
        /// selection, which may be nothing, and the dictation to fall back to,
        /// which may also be nothing. A command reads neither slot and clears
        /// neither: by the time a decoder has answered, a newer press can own
        /// what is in them.
        case frozen(selection: SelectionReader.Selection?, fallback: String?)
    }

    /// Runs a prompt over the selection, or over the last dictation.
    ///
    /// The selection is taken from the snapshot made when the hotkey went down,
    /// not read now — by the time this runs, our own panel may hold focus, and
    /// reading then returns nothing or something of ours.
    private func runTransform(
        _ transform: Config.Transform, instruction: String,
        progress inherited: Int?, confirm: Bool = true,
        over target: Target = .whateverIsSelected
    ) {
        // Never the clipboard. `read()` falls back to it for the correction
        // panel, where you see the words before anything happens and can
        // cancel; a transform gets no such look. The clipboard holds whatever
        // was last copied — from another app, or an hour ago — and taking it
        // as the target means rewriting text the speaker never pointed at.
        // That is exactly what happened: "convert numbers to digits" ran over
        // a comment line copied minutes earlier, while the sentence the
        // speaker meant sat in the last transcript, unused.
        //
        // A spoken command brings its own, frozen when its recording began —
        // see `Press.selection` and `Target`. It neither reads the slot nor
        // clears it: by the time a decoder has answered, a newer press can own
        // what is in there.
        let selection: SelectionReader.Selection?
        let dictated: String?
        switch target {
        case .frozen(let held, let fallback):
            selection = held
            dictated = fallback
        case .whateverIsSelected:
            selection = selectionAtPress ?? (
                Permissions.accessibility == .granted
                    ? SelectionReader.read(fallbackTo: false)
                    : nil
            )
            selectionAtPress = nil
            dictated = lastTranscript
        }

        // Falling back to the last dictation is what makes "hey parrot, fix the
        // grammar" work immediately after speaking, with nothing selected.
        let target = selection?.text ?? dictated ?? ""
        guard !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            endProgress(token: inherited)
            Log.write("transform: nothing selected and nothing dictated yet")
            flash("Select some text first, or dictate something", tone: .caution)
            return
        }

        // The text itself, not just its length: a transform that worked on the
        // wrong thing is otherwise indistinguishable in the log from one that
        // worked on the right thing badly.
        Log.write("transform: \(transform.name) over \(selection == nil ? "the last dictation" : "the selection") — \"\(target.prefix(80))\"")
        runTransform(
            transform, instruction: instruction, selection: selection, on: target,
            confirm: confirm
        )
    }

    /// The run itself, over text already decided.
    ///
    /// Split from `runTransform` so a retry cannot go looking for the target
    /// again. `selectionAtPress` is consumed there, so a second call through
    /// the front door would read the selection now — by which time our own
    /// panel may hold focus — or fall back to the last dictation, and rewrite
    /// something other than what the first call was pointed at.
    private func runTransform(
        _ transform: Config.Transform,
        instruction: String,
        selection: SelectionReader.Selection?,
        on target: String,
        confirm: Bool = true
    ) {
        let token = beginProgress(transform.progressLabel)

        Task { [weak self] in
            do {
                guard let result = try await self?.perform(
                    transform, instruction: instruction, on: target
                ) else { return }
                await MainActor.run {
                    self?.finishTransform(
                        transform: transform, selection: selection,
                        before: target, after: result,
                        progress: token, confirm: confirm
                    )
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    Log.write("transform failed: \(error.localizedDescription)")
                    self.endProgress(token: token)
                    let asked = self.askForKeyThenRetry(error) {
                        self.runTransform(
                            transform, instruction: instruction,
                            selection: selection, on: target, confirm: confirm
                        )
                    }
                    if !asked { self.flash(error.localizedDescription, tone: .failure) }
                }
            }
        }
    }

    private func finishTransform(
        transform: Config.Transform,
        selection: SelectionReader.Selection?,
        before: String,
        after: String,
        progress token: Int?,
        confirm: Bool = true
    ) {
        endProgress(token: token)

        let cleaned = after.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            Log.write("transform: \(transform.name) returned nothing")
            flash("\(transform.name) returned nothing from \(quoted(before))", tone: .caution)
            return
        }
        // Saying so beats replacing text with itself and calling it done, which
        // looks identical to the prompt having silently failed.
        //
        // Naming the text is most of the message. "nothing to change" on its
        // own is indistinguishable from three different problems — the wrong
        // target, an instruction that named something absent, a prompt that
        // failed — and telling them apart took reading the log. Showing what it
        // looked at answers the first two at a glance.
        guard cleaned != before.trimmingCharacters(in: .whitespacesAndNewlines) else {
            Log.write("transform: \(transform.name) changed nothing")
            flash("\(transform.name): nothing to change in \(quoted(before))", tone: .plain)
            return
        }

        // `confirm: false` overrides the transform's own setting, the way the
        // offer's chips already do. A preview is for a command whose target you
        // could have got wrong; tap-then-hold has already shown you the target
        // on the pill and given you ⎋ to take it back, and the undo phrase
        // survives the rewrite. Asking again after all that is a second answer
        // to a question already answered.
        guard transform.confirm, confirm else {
            applyTransform(cleaned, to: selection, replacing: before, transform: transform)
            return
        }

        previewPanel.onApply = { [weak self] edited in
            self?.applyTransform(edited, to: selection, replacing: before, transform: transform)
        }
        previewPanel.onCancel = {
            Log.write("transform: \(transform.name) discarded")
        }
        previewPanel.show(prompt: transform.name, before: before, after: cleaned)
    }

    /// One edit to make to text that is already in the field.
    struct Edit {
        let find: String
        let replace: String
        /// Whether to settle for the nearest thing when `find` is not there.
        ///
        /// Right for a rule learned by ear, where the word on screen and the
        /// word in the rule are two hearings of one name — a field reading "I
        /// love versall" against a rule for "Versailles" matched nothing.
        /// Wrong for a transform, whose `find` is a whole sentence: the
        /// nearest word to it is not a worse spelling of it, it is some other
        /// part of the line.
        let fuzzy: Bool
    }

    /// Three outcomes, not two.
    ///
    /// "It did not happen" and "it was tried and rolled back" call for opposite
    /// things afterwards. Treating them alike is what produced
    /// "Fifty cents.50 cents.": the retype had already put text on the line and
    /// taken it off again, and the caller, seeing only false, pasted on top of
    /// the result.
    private enum InPlace { case replaced, notAttempted, failed }

    /// Turns edits into a span and hands it to `Surface`.
    ///
    /// The two halves of an in-place edit are *where* and *how*, and only the
    /// first one belongs here. Locating is this app's problem — a rule learned
    /// by ear names a word that may be spelled differently on screen, and
    /// resolving that needs the fuzzy match below. Writing is the surface's
    /// problem, and it is the same problem in every app, which is why there is
    /// one ladder rather than one per caller.
    ///
    /// All the edits are applied to the content first and the result handed over
    /// as a single substitution. Done one at a time, the second edit would be
    /// located against a string that the first had already changed — and in a
    /// terminal each one costs a whole line retype, which is a fresh chance to
    /// lose the line.
    private func applyInPlace(
        _ edits: [Edit], dictated: String?, in element: AXUIElement,
        describedAs label: String
    ) -> InPlace {
        guard !edits.isEmpty else { return .notAttempted }
        guard let surface = Surface.read(element: element, dictated: dictated) else {
            return .notAttempted
        }

        var updated = surface.content
        var applied = 0
        for edit in edits {
            let before = updated
            if edit.fuzzy {
                // A rule, so every occurrence on the line: a name you have just
                // taught the app to spell is misspelled everywhere it appears,
                // not only the last time you said it. `applying` also falls back
                // to the closest word, because the word on screen and the word
                // in the rule are two hearings of one name.
                updated = SelectionReader.applying(
                    [(heard: edit.find, corrected: edit.replace)], to: updated
                )
            } else if let found = updated.range(
                of: edit.find, options: [.caseInsensitive, .backwards]
            ) {
                // A phrase, so the last occurrence only: this is the sentence
                // dictated a moment ago being replaced by its rewritten form,
                // and there is exactly one of it.
                updated = updated.replacingCharacters(in: found, with: edit.replace)
            }
            if updated != before { applied += 1 }
        }

        guard applied > 0, let change = Surface.writableSpan(from: surface.content, to: updated) else {
            Log.write("in-place: nothing on the line matches \(edits.map(\.find))")
            return .notAttempted
        }
        if applied < edits.count {
            Log.write("in-place: \(applied) of \(edits.count) edits found their text")
        }

        switch surface.replace(change.range, with: change.replacement, describedAs: label) {
        case .replaced(let undo):
            lastSubstitution = undo
            return .replaced
        case .refused(let why):
            Log.write("in-place: refused — \(why)")
            return .failed
        }
    }

    /// Substitutes the text that was selected when the hotkey went down.
    ///
    /// The recorded range is a hint, not an address. It was read before the
    /// panel opened and before focus moved, and a field that has scrolled or
    /// been typed into since will happily hand back a range that now covers
    /// something else — so it is used only when the characters sitting there are
    /// still the ones that were selected. Otherwise the text is found again by
    /// its content, which is the thing that was actually pointed at.
    ///
    /// Finding it again is where this can go wrong, and the recorded range earns
    /// its keep a second time. A field reading "Jerry and Jerry" gives two
    /// answers to "where is Jerry", and taking either one on its own merits
    /// rewrites a word the speaker was not pointing at — selecting the first and
    /// having the last one changed is worse than nothing happening. So a
    /// repeated selection is resolved by *where* it was: the occurrence nearest
    /// the offset originally recorded, which survives text being inserted or
    /// removed around it. With no offset to go on there is nothing to choose
    /// between them, and this refuses.
    private func replaceSelected(
        with text: String, in selection: SelectionReader.Selection, describedAs label: String
    ) -> InPlace {
        // Re-query rather than reuse: apps generally only honour writes to
        // whatever currently has focus, and by now our own panel has held it.
        let element = SelectionReader.refocusedElement(in: selection.owner)
            ?? selection.element.flatMap { SelectionReader.isOurs($0) ? nil : $0 }
        guard let element,
              let surface = Surface.read(
                  element: element, app: selection.owner, dictated: selection.text
              )
        else { return .notAttempted }

        var target: Range<String.Index>?
        if let recorded = selection.range,
           recorded.location >= 0, recorded.length > 0,
           let range = Range(
               NSRange(location: recorded.location, length: recorded.length),
               in: surface.content
           ), surface.content[range] == selection.text {
            target = range
        } else {
            let matches = surface.ranges(of: selection.text)
            if matches.count == 1 {
                Log.write("transform: the recorded range moved; found the selection by its text")
                target = matches[0]
            } else if matches.count > 1, let recorded = selection.range, recorded.location >= 0 {
                // Nearest the offset it was read at, not nearest the end.
                target = matches.min {
                    abs(offset(of: $0, in: surface.content) - recorded.location)
                        < abs(offset(of: $1, in: surface.content) - recorded.location)
                }
                Log.write("transform: \(matches.count) copies of the selection;"
                    + " taking the one nearest where it was read")
            } else if matches.count > 1 {
                Log.write("transform: \(matches.count) copies of the selection and nothing"
                    + " says which was meant; not guessing")
                return .notAttempted
            }
        }

        guard let target else {
            Log.write("transform: \"\(selection.text.prefix(40))\" is no longer in the field")
            return .notAttempted
        }
        switch surface.replace(target, with: text, describedAs: label) {
        case .replaced(let undo):
            lastSubstitution = undo
            return .replaced
        case .refused(let why):
            Log.write("transform: refused — \(why)")
            return .failed
        }
    }

    private func offset(of range: Range<String.Index>, in text: String) -> Int {
        NSRange(range, in: text).location
    }

    /// The chime after a substitution, and nothing on screen.
    ///
    /// It used to say "<name> applied" with the undo phrase after it. Two
    /// things retired that. The text is the confirmation — a rewrite lands
    /// where you are already looking, and the pill sits under it — so the
    /// notice was telling you what you had just watched happen. And the
    /// catch-all is called `anything`, a name written for the log and for
    /// `--check-config`, which made the message read "anything applied".
    ///
    /// The failures still speak. Nothing changed, the app refused the edit,
    /// the words went to the clipboard instead: those are the cases you cannot
    /// see, and every one of them still puts a line on the pill.
    private func applied(_ what: String) {
        Log.write("applied: \(what)\(undoHint)")
        playFeedback("Morse")
    }

    /// `· "Hey parrot, undo"` — empty when there is no phrase to say it with.
    ///
    /// The configured phrase rather than a fixed one: it is spelled however the
    /// person set it, and offering words that do not work is worse than saying
    /// nothing.
    private var undoHint: String {
        guard let phrase = config.transcription.activationPhrases.first?
            .trimmingCharacters(in: .whitespacesAndNewlines), !phrase.isEmpty,
              lastSubstitution != nil
        else { return "" }
        return " · \"\(phrase.prefix(1).uppercased() + phrase.dropFirst()), undo\""
    }

    /// Puts the last substitution back.
    ///
    /// Deliberately reachable without the model — it is matched as a literal
    /// phrase — because the moment you need it is the moment something has gone
    /// wrong, and "Ollama is not running" is not an acceptable answer then.
    private func performUndo() {
        guard let record = lastSubstitution else {
            Log.write("undo: nothing has been substituted yet")
            flash("Nothing to undo", tone: .caution)
            return
        }

        // Back to the window the substitution went into — recorded at the time,
        // not read now. Saying the phrase went through our own hotkey, and by
        // then you may well be looking at something else entirely; activating
        // *that* is how an undo arrives in the wrong app.
        if let owner = record.owner, !owner.isActive {
            owner.activate()
            Thread.sleep(forTimeInterval: 0.15)
        }

        switch Surface.undo(record) {
        case .replaced:
            Log.write("undo: put back \(quoted(record.before))")
            lastSubstitution = nil
            playFeedback("Morse")
            flash("Undone", tone: .done)
        case .refused(let why):
            Log.write("undo: refused — \(why)")
            flash("Can't undo — \(why)", tone: .caution)
        }
    }

    private func applyTransform(
        _ text: String,
        to selection: SelectionReader.Selection?,
        replacing replaced: String,
        transform: Config.Transform
    ) {
        // Replacing the selection puts it back exactly where it came from.
        // Without one there is nowhere to aim, so it goes in at the cursor the
        // same way a dictation would.
        if let selection {
            switch replaceSelected(with: text, in: selection, describedAs: transform.name) {
            case .replaced:
                applied(transform.name)
            case .failed, .notAttempted:
                Log.write("transform: this app would not accept the rewrite; left on the clipboard")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                flash("\(transform.name) copied — this app won't let me edit it", tone: .caution)
            }
        } else {
            // Hand focus back first. Showing the preview called NSApp.activate
            // to put the panel in front, so by the time Apply is pressed we are
            // the frontmost app and Cmd-V lands in our own window — which is
            // how "digits applied" appeared over a TUI that never changed.
            if let owner = focusAtPress?.owner, !owner.isActive {
                owner.activate()
                // Let it come forward before the keystroke is posted.
                Thread.sleep(forTimeInterval: 0.15)
            }

            // The text this ran over is still in the field — we dictated it
            // there a moment ago and nothing has taken it away. Pasting the
            // result leaves both versions side by side: "Sixty Euros.60 Euros."
            // So replace what we typed, with the machinery a correction uses,
            // and only fall back to inserting when there is nothing to replace.
            let original = replaced.trimmingCharacters(in: .whitespacesAndNewlines)
            if !original.isEmpty, config.transcription.insertMode == .paste,
               let element = SelectionReader.focusedElement(),
               !SelectionReader.isOurs(element) {
                let edit = Edit(find: original, replace: text, fuzzy: false)
                switch applyInPlace(
                    [edit], dictated: original, in: element, describedAs: transform.name
                ) {
                case .replaced:
                    applied(transform.name)
                    lastTranscript = text
                    return
                case .failed:
                    Log.write("transform: the line would not take the rewrite; left on the clipboard")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    flash("\(transform.name) copied — this app won't let me edit it", tone: .caution)
                    lastTranscript = text
                    return
                case .notAttempted:
                    break
                }
            }

            // From the selection this transform was aimed at, not from
            // `appAtPress`: this runs after a model call, and that field holds
            // the newest press by then. Without a selection there is nothing
            // saying where the text is going, and plain is the answer that
            // cannot lose it.
            let paste = selection?.owner.map {
                AppProfile.of(
                    Pipeline.App(name: $0.localizedName ?? "", bundleID: $0.bundleIdentifier ?? "")
                ).paste
            } ?? .plain
            switch TextInserter.insert(
                text, mode: config.transcription.insertMode, paste: paste
            ) {
            case .pasted, .copied:
                playFeedback("Morse")
                flash("\(transform.name) applied", tone: .done)
            case .clipboardOnly:
                flash("\(transform.name) copied — grant Accessibility to paste", tone: .caution)
            }
        }
        lastTranscript = text
    }

    private func apply(
        _ command: VoiceCommand, command spoken: String, progress token: Int?,
        over target: Target = .whateverIsSelected
    ) {
        // Whatever happens next replaces it: a panel, or a flash of its own.
        endProgress(token: token)

        switch command {
        case .openCorrectionPanel:
            beginCorrection(over: target)
        case .undo:
            performUndo()
        case .addRules(let rules):
            // Prefilled, not saved: the model proposed them, you confirm them.
            // One utterance can carry more than one, so the panel opens with a
            // row per rule and each is confirmed or edited on its own.
            for rule in rules {
                Log.write("command proposed rule: \(rule.heard) -> \(rule.corrected)")
            }
            pendingSelection = nil
            correctionPanel.onSave = { [weak self] rules, text in
                self?.saveCorrections(rules, correctedText: text)
            }
            correctionPanel.onCancel = { [weak self] in self?.pendingSelection = nil }
            correctionPanel.show(rules: rules)
        case .unrecognised(let text):
            Log.write("command not understood: \(text)")
            flash("Didn't understand \"\(spoken)\"", tone: .caution)
        }
    }

    // MARK: - The offer

    private var offerIsUp: Bool {
        guard let offerUntil else { return false }
        return offerUntil > Date()
    }

    /// Say what can be done about the words just dictated, and for how long.
    ///
    /// After every ending, not only a paste that worked. A word the recogniser
    /// got wrong is worth teaching whether or not the sentence reached a text
    /// field, and the offer cannot wait: it is about the words you are looking
    /// at now. The messages the clipboard endings used to put on the pill —
    /// "on your clipboard", "grant Accessibility" — are worth keeping and worth
    /// less than the offer, so they moved to the menu bar, where messages that
    /// are not urgent live. See `insertDictation`.
    ///
    /// `landing` is where those words actually went. It is frozen into the
    /// correction, and it is what keeps a correction out of a field the
    /// dictation never wrote into.
    ///
    /// The commands are read from the config, so what is on the pill is what
    /// that machine can actually do. It no longer waits on the hotkey being
    /// registered: it used to print that key's name, and now it prints its own
    /// letters and is worked with the mouse.
    ///
    /// `press` is the dictation this offer is about, carried down from its own
    /// key-down — see `insertDictation`. Nothing below reads press-time state
    /// off `self`, so an offer can never be moved by another dictation's press.
    /// `headline` is only passed for an ending nobody chose.
    private func showCorrectOffer(
        for press: Press, landing: Correction.Landing, headline: Headline? = nil
    ) {
        // Beside the offer, not on it: its own window, so advice about the
        // microphone never costs you the chance to fix the sentence. Here
        // because this is the end of a dictation and every ending comes
        // through — a Bluetooth mic is worth saying something about the moment
        // you have watched a transcript come back short, and worth nothing at
        // launch, when you were not dictating.
        //
        // Above the guards below, which are all about the offer rather than
        // about the microphone: `correct_offer: false` is a choice about
        // commands on the pill, an empty transcript is the symptom itself, and
        // a dictation that lost the pill to a newer one was still recorded on
        // the same microphone. `MicNotice` decides for itself whether there is
        // anything to say, so none of them can make it say it twice either.
        //
        // The microphone comes off the press, not off CoreAudio. This runs when
        // the decoder is done, and by then the default input can be another
        // device — see `micAtPress`.
        micNotice.showIfNeeded(press.mic)

        guard config.feedback.correctOffer else { return }
        guard let text = lastTranscript?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return }

        // Two dictations can finish out of order — a long prompt stage on the
        // first, none on the second. The newer one's offer is the one about the
        // words you are looking at, so an older one arriving after it never
        // gets the pill: not while that offer is up, and not once it has
        // expired either, because reappearing to talk about older text is the
        // same mistake made a few seconds later.
        if let owner = offerPressRun, owner > press.run {
            Log.write("offer: a newer dictation has already had the pill")
            return
        }

        // Kept past the offer this is about to raise, so a tap can build another
        // one out of it once this has faded. Below the newer-run guard above,
        // and carrying the words as well as the field — see `lastDictated`.
        lastDictated = (press.run, text, press.element, press.owner, landing)
        watchForReselection()

        // The decoder's words matched back onto the sentence that came out of
        // the pipeline — see `Confidence.read`. Taken rather than copied: this
        // press's dictation is over and nothing else can want them.
        let decoded = heardAtPress.removeValue(forKey: press.run)
        let words = decoded.map { Confidence.read($0.words, into: text) } ?? []
        // The words are matched whenever anything wants them, and shown only
        // when the colours were asked for. The warning reads the same list: a
        // threshold is about the word you are looking at, so it is the written
        // word that is measured and the written word that gets named.
        let low = config.feedback.lowConfidence
        let reading = Confidence.Reading(
            words: config.feedback.confidence ? words : [],
            warning: Confidence.warning(
                words, utterance: decoded?.confidence,
                vocabulary: decoded?.vocabulary ?? [],
                sentenceBelow: Float(low.sentence), wordBelow: Float(low.word)
            )
        )
        if let warning = reading.warning { Log.write("offer: \(warning)") }

        raiseOffer(
            over: Correction(
                original: text, element: press.element, owner: press.owner,
                landing: landing, dictation: press.run
            ),
            run: press.run, headline: headline, reading: reading,
            // Nobody asked for this one. It arrives as a tab unless the decode
            // is worth a second look, which `raiseOffer` decides for itself.
            open: false
        )

        // Taken at the press, and only when that press found no caret. Matched
        // by run, so it is this dictation's own pane and nobody else's. A
        // remembered anchor is still a guess, and this is what replaces it with
        // the answer.
        //
        // Dropped on every ending, not only the one that uses it. A pane
        // belongs to one run and no later dictation can want it, so it is
        // retired here as `dictationEnded` would retire it — leaving it for the
        // sweep would be keeping a copy of somebody's screen for no reason.
        let pane = screenAtPress.removeValue(forKey: press.run)?.text
        // Nothing landed in a field on the clipboard endings, so the diff has
        // nothing to find. Whatever it did find would be something else moving
        // on screen.
        if case .field = landing, let element = press.element {
            if let pane {
                findWhereTheWordsLanded(comparedWith: pane, in: element, for: press.run)
            } else {
                // A pane is only kept for a press that found no caret, so this
                // is the other half of the same job: the apps that *did* answer
                // at the press, and answered about the line the dictation was
                // about to start on rather than the one it ended on.
                dropBelowTheWords(
                    wroteAtPress[press.run] ?? text.utf16.count, in: element, for: press.run
                )
            }
        }
    }

    /// Move the surface below the whole of what was just said, if it wrapped.
    ///
    /// The pill is already up and already in the right column — the caret it
    /// was aimed at is the first character of the utterance. What it cannot
    /// know at the press is how many lines the words were going to take. This
    /// asks once they are down.
    ///
    /// Off the main thread and unhurried, for the reason `findWhereTheWordsLanded`
    /// gives: measuring text means the app copying its value out, and a mail
    /// composer's value is hundreds of thousands of characters.
    ///
    /// Not retried. The diff has to wait for a redraw it cannot see coming, so
    /// it loops; this asks the app where its own text is, and an app that will
    /// not answer that now will not answer it in 80ms either. A miss leaves the
    /// pill where it opened, which for every dictation that fits on one line is
    /// already the right place.
    private func dropBelowTheWords(_ length: Int, in element: AXUIElement, for run: Int) {
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = CaretAnchor.utterance(of: length, in: element)
            DispatchQueue.main.async { [weak self] in
                // Only while this press still owns what is on screen, the same
                // as the diff: a newer dictation's offer is not this one's to
                // move.
                guard let self, self.offerIsUp, self.offerPressRun == run else { return }
                switch outcome {
                case .found(let found): self.pill.aim(at: found)
                case .missed(let why): Log.write("pill: the words did not measure — \(why)")
                }
            }
        }
    }

    /// Put the offer on screen over one target, however it got there.
    ///
    /// Split out of `showCorrectOffer` so `summonOffer` can reach it. What
    /// stayed behind there is everything a *dictation's* ending owes and
    /// nothing else does: the microphone notice, the decoder's reading, and the
    /// search for where the words landed.
    /// `open` says whether this offer was asked for.
    ///
    /// No default, deliberately: every caller has to say, because the answer is
    /// the difference between a surface that appears because you reached for it
    /// and one that appears because you finished a sentence. The second kind is
    /// what a tab is for.
    private func raiseOffer(
        over target: Correction, run: Int, headline: Headline?,
        reading: Confidence.Reading, open: Bool
    ) {
        // A tab has no deadline. It waits for you to act — a click, a
        // keystroke, the next dictation — because 33x23 of your document costs
        // nothing to leave there. The panel it opens into is a different
        // matter, and gets the clock at the moment it opens.
        offerUntil = open ? Date().addingTimeInterval(Self.offerSeconds) : .distantFuture
        // A new offer is never born held, whatever the last one ended as.
        offerHeld = false
        offerPressRun = run
        offeredCorrection = (run, target)
        // Frozen with the offer rather than asked again when a chip is pressed.
        // `lastDictated` is one slot and push-to-talk does not wait, so the same
        // question a few seconds later can be about a different sentence.
        let teaching = target.dictation != nil
        let commands = offerCommands(teaching: teaching)
        offerHeadline = headline
        offerReading = reading
        let hold = config.feedback.lowConfidence.holdReturn
        offerHoldsReturnUntil = reading.warning != nil && hold > 0
            ? Date().addingTimeInterval(hold)
            : nil
        // Closed. The tab is the quiet default and that is the whole point of
        // it: after a dictation that went fine there is nothing to say, and a
        // panel that says it anyway is clutter you learn to look past — which
        // is how the one that did have something to say got looked past too.
        //
        // A warning still cannot wait to be asked for, and it used to open the
        // whole panel to deliver itself — a sentence about the decode with a
        // row of transforms under it, as if the warning were a menu. It is not.
        // It is the same kind of thing as "Grammar applied": news about the
        // dictation that just happened. So it is said the way those are said,
        // and the tab is left on the words afterwards for whoever wants to act
        // on it. See `sayTheTabAfterTheMessage`.
        if let warning = reading.warning, !open {
            flash(warning, tone: reading.stopped ? .failure : .caution)
            // The surface, not the offer. Everything below this still runs —
            // the keys, the click watcher, and above all the held Return, which
            // exists only for a decode like this one. An early return here
            // would have taken the warning's own feature away with it.
            sayTheTabAfterTheMessage(commands, headline: headline, reading: reading, run: run)
        } else {
            pill.offer(
                commands, headline: headline, reading: reading, open: open,
                for: Self.offerSeconds
            )
        }
        // The list is captured, not read again in the closure: a config
        // reloaded while the offer is up would otherwise renumber the chips
        // under the pointer, and the click would run whatever took the slot.
        pill.model.onPick = { [weak self] index in
            guard let self else { return }
            guard self.offerIsUp, commands.indices.contains(index) else {
                Log.write(
                    "offer: chip \(index) picked, but "
                        + (self.offerIsUp ? "there is no such chip" : "the offer was over")
                )
                return
            }
            // Index 0 is Vocabulary *when it is there* — it is not a transform
            // and cannot be one, so a config free to name a transform
            // "Vocabulary" must not be able to take that slot over. Matched by
            // position rather than by title for exactly that reason, which means
            // an offer without it has to say so or the first transform would be
            // run as the panel.
            self.runOfferedCommand(teaching && index == 0 ? nil : commands[index].title)
        }
        // The highlight is the pointer's mark and does not outlive it. Leaving
        // the pill gives it up, so a chip is never lit for a command that is
        // not about to happen. Cleared here rather than in the view because
        // this is where the rest of the leaving behaviour hangs.
        // The panel's clock folds it back to the tab instead of taking the
        // surface away, so the clock and the letters have to go back to what a
        // tab has: no deadline, and nothing claimed from your keyboard.
        pill.model.onFold = { [weak self] in
            guard let self, self.offerIsUp else { return }
            Log.write("offer: the panel folded back to the tab")
            self.offerUntil = .distantFuture
            self.offerHeld = false
            self.watchTheOfferKeys()
        }

        pill.model.onHover = { [weak self] inside in
            guard let self else { return }
            if !inside { self.pill.model.selected = nil }
            self.holdTheOffer(inside)
        }

        offerOnScreen = commands
        watchTheOfferKeys()
        watchForOfferOutsideClick()
    }

    /// Unfold the tab, and give it everything an open panel has.
    ///
    /// Three things move together here for the reason `holdTheOffer` gives:
    /// the panel, the deadline it did not have while it was a tab, and the
    /// letters, which are only claimed while they are on screen to be pressed.
    private func openTheOffer() {
        Log.write("summon: opened the tab")
        pill.open(true)
        offerUntil = Date().addingTimeInterval(Self.offerSeconds)
        offerHeld = pill.pointerIsOver
        watchTheOfferKeys()
    }

    /// Put the tab up once the warning has been read.
    ///
    /// The offer is already alive by the time this is called — this only moves
    /// the pill from the message to the tab, which is why it checks that the
    /// offer is still this one's rather than raising anything.
    private func sayTheTabAfterTheMessage(
        _ commands: [OfferedCommand], headline: Headline?,
        reading: Confidence.Reading, run: Int
    ) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.offerIsUp, self.offerPressRun == run else { return }
            self.pill.offer(
                commands, headline: headline, reading: reading, open: false,
                for: Self.offerSeconds
            )
        }
        offerReturn?.cancel()
        offerReturn = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.noticeSeconds, execute: work)
    }

    /// Leave the tab on the words once a message has been read.
    ///
    /// Running a transform ended the offer, and the surface went with it — so
    /// after "Grammar applied" there was nothing on screen saying you could run
    /// another one, and nothing naming the key that would. You had to remember
    /// both. The tab is what says them.
    ///
    /// After the message rather than instead of it: the message is about what
    /// just happened and the tab is about what you can do next, and a tab that
    /// replaced the message would answer a question nobody had asked yet.
    ///
    /// Refused if anything has taken the pill in the meantime. A newer
    /// dictation's offer is not this one's to talk over, and one already on
    /// screen does not want replacing with a copy of itself.
    private func offerAgainAfter(_ delay: TimeInterval) {
        guard config.feedback.correctOffer, let owner = lastDictated?.run else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.offerIsUp,
                  !self.recorder.isRecording, self.runsInFlight <= 0,
                  let last = self.lastDictated, last.run == owner,
                  !last.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            Log.write("offer: the tab comes back over the words as they are now")
            self.raiseOffer(
                over: Correction(
                    original: last.text, element: last.element, owner: last.owner,
                    landing: last.landing, dictation: last.run
                ),
                run: owner, headline: nil, reading: Confidence.Reading(), open: false
            )
        }
        offerReturn?.cancel()
        offerReturn = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Say something about the dictation, then leave the tab on it.
    private func flashThenOffer(_ message: String, tone: NoticeTone = .plain) {
        flash(message, tone: tone)
        offerAgainAfter(Self.noticeSeconds)
    }

    /// How long a notice stands before the tab takes the surface back. The
    /// pill's own default for a message with a duration.
    static let noticeSeconds: TimeInterval = 3.5

    /// The offer asked for rather than offered: the hotkey tapped, not held.
    ///
    /// Over the last dictation, in the field it landed in. This is what stops
    /// `offerSeconds` being a deadline — an offer you can call back does not
    /// have to be kept on screen against the chance that you want it, so
    /// nothing here lengthens it.
    ///
    /// No reading. The colours and the low-confidence warning are what the
    /// decoder said about a sentence as it arrived, and a tap minutes later is
    /// not that moment. Showing them again would also re-arm `holdReturn`,
    /// which exists for the Return already on its way down.
    private func summonOffer() {
        // Nothing while a dictation is in the air. On `toggle` the key is what
        // stops a recording, and a stop that came out short is a stop — the
        // press was simply never delivered. Summoning there would answer a key
        // meant for the microphone, and do it over the *previous* sentence.
        guard !recorder.isRecording, runsInFlight <= 0 else { return }
        // A tap while the offer is already open is a tap at nothing. Raising a
        // second one over the first would take the letters again and restart a
        // clock the pointer may be deliberately holding.
        //
        // Closed, it is the opposite gesture rather than none: the tab is on
        // screen so that a tap can open it, and the key it draws is this one.
        if offerIsUp {
            if !pill.isOpen { openTheOffer() }
            return
        }
        guard config.feedback.correctOffer else { return }

        // The selection wins, and it never goes stale: it is what you are
        // pointing at now. It is also the only target this can have in an app
        // ParrotFlow has never written a word into, which is the whole of why
        // the tap reaches further than the last dictation.
        if let selection = SelectionReader.snapshot(),
           !selection.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // The length, not the words. Every other line that logs a selection
            // is reached by saying a command; this one is reached by tapping a
            // key once, over text nothing here dictated. A count still answers
            // what the log is for here — whether the tap found the selection
            // you meant, or an empty one.
            Log.write("summon: the offer, over a selection of \(selection.text.count) characters")
            aim(at: selection)
            raiseOffer(
                over: Correction(
                    original: selection.text, element: selection.element,
                    owner: selection.owner, landing: .field,
                    // Selecting part of what you just dictated and tapping is
                    // still your dictation, so it still gets the panel — see
                    // `dictationBehind`. Text nobody here wrote answers nil.
                    dictation: dictationBehind(selection.text, in: selection.element),
                    selection: selection
                ),
                run: pressRun, headline: .selection(selection.text),
                reading: Confidence.Reading(),
                // You pressed a key to get here.
                open: true
            )
            return
        }

        guard let last = lastDictated,
              !last.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Log.write("summon: nothing selected and nothing dictated yet")
            return
        }
        Log.write("summon: the offer, over the last dictation")
        // `pressRun` rather than a number of its own: this offer is about that
        // dictation, and saying so is what lets a newer one take the pill off
        // it through the guard in `showCorrectOffer`.
        //
        // Re-aimed, and it did not used to be. The argument for leaving it was
        // that the pill was already pointed where the words landed, and a fresh
        // read answers where the caret is *now*, which is a different question.
        //
        // That held while the pill floated. It stopped holding when it started
        // hanging off a line of text: the anchor is dropped when the last offer
        // faded, so an offer summoned after that had nothing to hang from and
        // came back as the old lozenge with the plumage rim on it, in the
        // middle of the screen. A surface with two forms cannot pick the one it
        // wears by accident.
        //
        // The fresh read is the better answer here anyway. You tapped the key
        // while looking at something; where the caret is now is where you are.
        if let element = last.element, case .found(let anchor) = CaretAnchor.read(at: element) {
            pill.aim(at: anchor)
        }
        raiseOffer(
            over: Correction(
                original: last.text, element: last.element, owner: last.owner,
                landing: last.landing, dictation: last.run
            ),
            run: pressRun, headline: nil, reading: Confidence.Reading(),
            open: true
        )
    }

    /// Offer again when the words are selected again.
    ///
    /// The other half of `summonOffer`. A tap is how you ask for the offer;
    /// this is how it arrives without being asked, and it is bounded to the one
    /// case where appearing uninvited is right — you selected text ParrotFlow
    /// wrote, which is a deliberate act aimed at words it already knows about.
    ///
    /// Re-armed after every rewrite, so a sentence corrected and then selected
    /// again still answers with the words that are on screen rather than the
    /// ones that were.
    ///
    /// The field is what the watch judges by, so no field means no watch. A
    /// dictation that ended on the clipboard left nothing on screen to select,
    /// and one whose element was never captured cannot be told from any other
    /// window.
    private func watchForReselection() {
        guard config.feedback.correctOffer else { reselect.stop(); edits.stop(); return }
        guard let last = lastDictated,
              !last.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              case .field = last.landing, let element = last.element else {
            // Said out loud, because the two watches below are the only way the
            // app ever learns what a name should have been, and a dictation
            // that lands anywhere else silently teaches nothing.
            let why: String
            if lastDictated == nil {
                why = "nothing was dictated"
            } else if lastDictated?.element == nil {
                why = "the field it went into was never captured"
            } else {
                why = "it landed as \(String(describing: lastDictated?.landing))"
            }
            Log.write("edit watch: not watching — \(why)")
            reselect.stop()
            edits.stop()
            return
        }
        reselect.onSelection = { [weak self] selection in
            self?.offerOverReselected(selection)
        }
        reselect.start(over: last.text, in: element)
        watchForEdits(in: element)
    }

    /// Watch the field the dictation landed in for one word being changed.
    ///
    /// The snapshot is the whole field and not the dictation, because both
    /// sides of the comparison have to be the same thing — see
    /// `EditWatch.change`. Reading it costs one accessibility call, here rather
    /// than at the first keystroke so that what is captured is the field before
    /// anybody touched it.
    private func watchForEdits(in element: AXUIElement) {
        guard let last = lastDictated else { edits.stop(); return }
        edits.onCorrections = { [weak self] changes in
            self?.offerToLearn(changes)
        }
        edits.start(dictated: last.text, in: element)
    }

    /// Put what was corrected by hand in front of you, as rules to keep or not.
    ///
    /// The panel rather than a notice, because a correction read off a screen is
    /// a guess about what somebody meant: the words are right, what they are a
    /// rule *for* is not always. Reviewing it is a second, and a rule saved
    /// wrongly decides other sentences for as long as it stands.
    ///
    /// Only names. A correction into a word both word lists know — `remain` to
    /// `remaining` — is English being fixed, not a term being taught, and a
    /// panel about it would be noise on every dictation.
    private func offerToLearn(_ changes: [EditWatch.Change]) {
        // No filter, for now. Deciding what a term is from the two word lists
        // is a bet on what dictionaries do not know yet, and it ages badly: the
        // day `Vercel` enters them, every correction toward it stops being
        // offered — and the shipped auto-apply rule stops firing too, since it
        // asks the same question. The panel is a better filter than any guess
        // while this is being tried out: the rows are removed there.
        let worth = changes
        guard !worth.isEmpty else { return }
        Log.write("correction: offering \(worth.count) rule(s) to keep")
        let sentence = worth.first?.sentence ?? ""
        correctionPanel.onSave = { [weak self] rules, _ in
            // The field is already right — the person fixed it themselves. Only
            // the rules are new, so `learn` and nothing after it.
            _ = self?.learn(rules, in: sentence)
        }
        correctionPanel.onCancel = { Log.write("correction: the rules were declined") }
        correctionPanel.show(
            rules: worth.map { (heard: $0.was, corrected: $0.now) }, over: sentence
        )
    }

    /// The offer, over words that were dictated and have been selected again.
    ///
    /// The selection is the target, not the whole dictation: select three words
    /// out of a sentence and those three words are what you meant. Everything
    /// downstream is `summonOffer`'s, because there is no difference between an
    /// offer you asked for and one that noticed — only in how it arrived.
    private func offerOverReselected(_ selection: SelectionReader.Selection) {
        // Never over a recording, never over an offer already up, and never
        // while a decode this could be about is still in flight.
        //
        // Refusing while one is up does not cost you a second selection, and
        // the reason is an ordering worth keeping: an outside click dismisses
        // the offer on mouse *down* — see `watchForOfferOutsideClick` — and this
        // looks on mouse *up*. So selecting different words takes the old offer
        // down before the new one is asked for. Move either monitor to the other
        // edge and reselecting while an offer is up stops answering.
        guard !recorder.isRecording, runsInFlight <= 0, !offerIsUp else { return }
        guard config.feedback.correctOffer else { return }
        aim(at: selection)
        raiseOffer(
            over: Correction(
                original: selection.text, element: selection.element,
                owner: selection.owner, landing: .field,
                dictation: dictationBehind(selection.text, in: selection.element),
                selection: selection
            ),
            run: pressRun, headline: .selection(selection.text),
            reading: Confidence.Reading(),
            // Not asked for: this one fires because you selected the words
            // again, and you may well have selected them to do something else
            // entirely. A tab beside them says it is here without taking the
            // screen, which is the whole argument for the tab.
            open: false
        )
    }

    /// The dictation these words came from, or nil when nothing here wrote them.
    ///
    /// Asked at the moment an offer is raised and frozen onto it, never read
    /// later: `lastDictated` is one slot and push-to-talk does not wait, so the
    /// answer a second from now can belong to a different sentence.
    ///
    /// `contains` rather than equality — select three words out of something you
    /// dictated and it is still your dictation, and the part you selected is the
    /// part you meant. What keeps that from being true of everything is the
    /// field, not the length, which is the same judgement `SelectionWatch`
    /// makes. "know" is four characters and sits inside half of everything
    /// anybody says; "know" in the box those words were written into is the word
    /// you just dictated, and it is exactly the kind of word somebody selects
    /// because they want it fixed.
    private func dictationBehind(_ text: String, in element: AXUIElement?) -> Int? {
        let target = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard target.count >= SelectionWatch.floor,
              let last = lastDictated,
              let element, let field = last.element, CFEqual(element, field),
              last.text.contains(target) else { return nil }
        return last.run
    }

    /// What the pill says the hold is for, or nil for the one that needs no
    /// saying.
    ///
    /// A command hold looks exactly like a dictation from outside — same key,
    /// same mic, same meter — and the difference is that the words are routed
    /// instead of written down. That has to be readable *before* you speak, not
    /// worked out afterwards from a sentence that never landed. Escape is live
    /// the whole time, so a wrong answer here costs one keystroke.
    private var recordingLabel: String? {
        guard keyedAtPress else { return nil }
        // The words, not a word for them.
        //
        // It said "say an edit" and "editing the selection", which named the
        // gesture you had just made and left out the only thing you could not
        // already know: which text is about to change. That question has one
        // exact answer and it is the text itself — the same argument the
        // offer's selection headline makes, and the same highlight draws it.
        //
        // A selection first, because it is what you are pointing at now. Then
        // the last dictation, which is what a tap-then-hold with nothing
        // selected is about. The old phrase survives as the fallback for
        // neither, where there is nothing to show and the gesture still needs
        // saying.
        let words = { (text: String?) -> String? in
            let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed?.isEmpty == false) ? trimmed : nil
        }
        if let text = words(selectionAtPress?.text) { return text }
        if let text = words(lastDictated?.text) { return text }
        return "say an edit"
    }

    /// Put the pill under the selection instead of where the last dictation
    /// left it.
    ///
    /// `CaretAnchor.read` already answers this and needed no new call: what it
    /// asks the element for is the selected *range*, which is the caret only
    /// when nothing is selected. A selection over several lines comes back as
    /// one box around the whole of it, so the pill lands under its last line,
    /// which is where it belongs.
    ///
    /// Left where it is when the read misses. `aim(at: nil)` means the bottom
    /// of the screen, and a pill still near the words it is about beats one
    /// parked away from them — Outlook answers `0+0` for a pane holding
    /// hundreds of thousands of characters, and `trust` is what catches it.
    private func aim(at selection: SelectionReader.Selection) {
        guard let element = selection.element else {
            Log.write("pill: no element for the selection; it stays where it was")
            return
        }
        // The range first, which puts the surface under where the selection
        // *starts* and below where it ends — see `CaretAnchor.span`. `read`
        // answers with one box around the whole thing, so a selection over
        // three lines put the surface under the leftmost of them, which for an
        // indented block is the margin and not the words.
        if let range = selection.range, range.length > 0,
           case .found(let anchor) = CaretAnchor.span(range, in: element) {
            pill.aim(at: anchor)
            return
        }
        guard case .found(let anchor) = CaretAnchor.read(at: element) else {
            Log.write("pill: no geometry for the selection; it stays where it was")
            return
        }
        pill.aim(at: anchor)
    }

    /// Take the offer's letters and Escape for as long as the offer is up.
    ///
    /// Consumed rather than only heard — see `OfferKeys` for why that needs a
    /// system-wide tap, and for the fences on it. The keys go back the moment
    /// the offer does, by every path that ends it and by the timer below.
    ///
    /// The commands are `offerOnScreen` — the same list the chips were drawn
    /// from and the same list `onPick` closed over. Read fresh from the config
    /// here it could disagree with both: a config reloaded while the offer is
    /// up would leave a letter claimed for a chip that is not on screen.
    ///
    /// Called when the offer is raised, and again from
    /// `stopWatchingForEscapeIfIdle` for the offer that could not have the keys
    /// the first time.
    private func watchTheOfferKeys() {
        // Whatever the last call left running goes first, deadline included.
        offerKeysExpiry?.cancel()
        offerKeysExpiry = nil
        offerKeys.stop()

        guard let until = offerUntil, let commands = offerOnScreen else { return }

        // The offer can also end by nobody answering it. The pill takes itself
        // down and says nothing, so this is what hands the keyboard back.
        // Armed before the tap is, so the offer is cleaned up at its deadline
        // even on the path below that installs no tap at all.
        armTheOfferDeadline()

        // Not while another dictation is running. Push-to-talk does not wait
        // for the previous transcript, so an offer can go up while a newer
        // press is still recording or decoding — and Escape belongs to that
        // press, to cancel it. A tap consumes before any monitor is reached, so
        // arming here would take Escape away from the dictation and spend it
        // dismissing the offer. The chips stay clickable meanwhile, and
        // `stopWatchingForEscapeIfIdle` calls back here the moment that
        // dictation is over — so an offer still on screen then gets its keys
        // for whatever is left of its `offerSeconds`.
        guard !recorder.isRecording, runsInFlight <= 0 else {
            Log.write("offer keys: a dictation is still running; the keys wait for it")
            return
        }
        // Nothing is claimed while it is only a tab.
        //
        // The tab stays until you act, and a surface that stays cannot also
        // hold four letters hostage: the first thing you type after dictating
        // would run a transform instead of typing. So closed, the tap takes
        // Escape and nothing else — every other key goes through untouched and
        // ends the offer, which is the "you have moved on" signal it was
        // already sending. The letters arm when the panel opens, which is the
        // only time they are drawn on screen to be pressed.
        let letters = pill.isOpen
            ? Set(commands.map(\.key).filter { !$0.isEmpty })
            : Set<String>()
        // The hold is armed only for a dictation that raised the warning, and
        // only until it has been spent. Re-armed from here on every call, so an
        // offer that got its keys late — a dictation was still running — is
        // still covered, and one that has already eaten a Return is not.
        let holds = offerReading.stopped ? nil : offerHoldsReturnUntil
        offerKeys.start(
            until: until, letters: letters, holdingReturnUntil: holds
        ) { [weak self] key in
            guard let self else { return }
            guard self.offerIsUp else {
                Log.write("offer keys: \(key) arrived after the offer was over")
                return
            }
            switch key {
            case .letter(let typed):
                guard let index = commands.firstIndex(where: { $0.key == typed }) else { return }
                // The highlight moves first, so what runs is what the pill was
                // showing when it ran.
                self.pill.model.selected = index
                // The same door the pointer uses. A key and a click must not be
                // two ways of running a command, or only one of them gets the
                // guards the other one has.
                self.pill.model.onPick?(index)
            case .firstReturn:
                self.holdTheReturn()
            case .dismiss:
                self.dismissOffer(reason: "the keyboard")
            }
        }
    }

    /// A Return was taken rather than typed. Say so, and give the offer back
    /// the time it takes to read that.
    ///
    /// The pill is raised again rather than edited in place: it is the same
    /// offer with the same chips, and raising it restarts the fade, which is
    /// the whole point — a warning that arrives with two seconds left on a
    /// surface that is already half gone is a warning nobody reads.
    ///
    /// The keys are re-armed from the same call the offer normally uses, which
    /// reads `offerReading` and finds the hold already spent. So the second
    /// Return is not this app's business at all.
    private func holdTheReturn() {
        guard offerIsUp, offerReading.warning != nil, !offerReading.stopped else { return }
        Log.write("offer: held the first Return; \(offerReading.warning ?? "")")
        offerReading.warning = Confidence.stopped
        offerReading.stopped = true
        offerUntil = Date().addingTimeInterval(Self.offerSeconds)
        // Open: this is the warning one step further along, and the key that
        // triggered it was pressed at a surface the user was already reading.
        pill.offer(
            offerOnScreen ?? [], headline: offerHeadline, reading: offerReading,
            open: true, for: Self.offerSeconds
        )
        watchTheOfferKeys()
    }

    /// A click anywhere but on the offer ends it, the same way Escape or
    /// Return does. Clicking outside the offer is already how you leave a menu
    /// or close a popover on the Mac; this is one more surface answering to
    /// the same habit rather than needing its own.
    ///
    /// Two monitors, the same pair `watchForEscape` uses and for the same
    /// reason: the global one sees a click in whatever app you clicked into,
    /// while it is in front; the local one sees a click on one of this app's
    /// own windows before AppKit routes it anywhere. Neither consumes the
    /// click — it still lands wherever it was headed, on the words you clicked
    /// into or the panel you clicked in. A click on the pill itself is not
    /// "outside" and does nothing here; the pill's own tap gesture is what
    /// runs a chip.
    ///
    /// Installed with the offer and torn down by `endTheOffer`, so an idle app
    /// is not watching the mouse at all — the same shape as `watchForEscape`.
    private func watchForOfferOutsideClick() {
        guard offerClickMonitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        let dismissIfOutside: () -> Void = { [weak self] in
            guard let self, self.offerIsUp, let frame = self.pill.frame else { return }
            let at = NSEvent.mouseLocation
            guard !frame.contains(at) else { return }
            Log.write(String(
                format: "offer: click at %.0f,%.0f is outside %.0f,%.0f %.0fx%.0f",
                at.x, at.y, frame.minX, frame.minY, frame.width, frame.height
            ))
            self.dismissOffer(reason: "a click outside it")
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { _ in
            dismissIfOutside()
        }) {
            offerClickMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            dismissIfOutside()
            return event
        }) {
            offerClickMonitors.append(local)
        }
    }

    private func stopWatchingForOfferOutsideClick() {
        offerClickMonitors.forEach(NSEvent.removeMonitor)
        offerClickMonitors.removeAll()
    }

    /// Take the offer down without running anything on it — Escape, Return, or
    /// a click outside it. `reason` is only for the log.
    ///
    /// Not called by the deadline passing unanswered: the pill has already
    /// faded itself out by then, on its own clock, and this would fade it a
    /// second time. `offerDeadlinePassed` calls `endTheOffer` directly.
    private func dismissOffer(reason: String) {
        Log.write("offer: dismissed by \(reason)")
        endTheOffer()
        pill.hide()
    }

    /// Arm the call that ends the offer when nobody answers it.
    ///
    /// One work item, replaced rather than added to, so the deadline can move
    /// without the tap being torn down and built again.
    private func armTheOfferDeadline() {
        offerKeysExpiry?.cancel()
        offerKeysExpiry = nil
        guard let until = offerUntil else { return }
        // Held, this is not a deadline but a look. The offer has no deadline
        // while the pointer is on it, so what is armed instead is the question
        // "is the pointer still there" — see `offerDeadlinePassed`.
        let after = offerHeld ? Self.offerSeconds : max(0, until.timeIntervalSinceNow)
        let expire = DispatchWorkItem { [weak self] in self?.offerDeadlinePassed() }
        offerKeysExpiry = expire
        DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: expire)
    }

    /// Nobody answered the offer, or nobody has moved the pointer off it.
    ///
    /// Held, the pointer is asked for rather than waited on. `onHover` is the
    /// only thing saying the pill is still under the pointer, and an exit that
    /// never arrives — a Space change, Mission Control, a window ordered out —
    /// would hold the offer open until the next dictation, with the letters it
    /// takes from every app. So the hold is checked once every `offerSeconds`,
    /// and a pointer that has gone without saying so is treated as one that
    /// said so: the offer gets its `offerSeconds` back and runs out normally.
    private func offerDeadlinePassed() {
        guard offerHeld else {
            // Open, this is the panel's deadline and not the offer's: it folds
            // and the tab stays. `pill.open(false)` calls back through `onFold`
            // to put the clock and the letters back, and the pill's own fade
            // usually gets here first — both are idempotent.
            if pill.isOpen { pill.open(false) } else { endTheOffer() }
            return
        }
        if pill.pointerIsOver {
            armTheOfferDeadline()
            return
        }
        Log.write("offer: the pointer left without saying so; the clock starts again")
        holdTheOffer(false)
    }

    /// The pointer stops the offer's clock, and gives it back in full when it
    /// leaves.
    ///
    /// Stopped rather than reset. A surface that went on thinning while you
    /// were reaching for it would be arguing about whether you had finished,
    /// and a pointer can rest for longer than any number chosen here. So while
    /// it is inside the offer has no deadline at all, and leaving starts a
    /// whole new `offerSeconds`.
    ///
    /// Three clocks have to move together, or the pill and the keys disagree:
    /// the pill's own fade, this deadline, and the tap's expiry. The tap's is
    /// a backstop against a tap that outlived its offer, and a pointer resting
    /// on the pill is the opposite of that — the offer is on screen, by
    /// definition. Every path that ends the offer still calls
    /// `OfferKeys.stop`, so the tap does not depend on that expiry to go.
    private func holdTheOffer(_ inside: Bool) {
        // Nothing to hold once the offer is over. The pointer can leave a pill
        // that a key has already dismissed, and that must not give it a
        // deadline back.
        guard offerUntil != nil else { return }
        let until = inside ? Date.distantFuture : Date().addingTimeInterval(Self.offerSeconds)
        offerHeld = inside
        offerUntil = until
        armTheOfferDeadline()
        offerKeys.extend(until: until)
        pill.hovering(inside)
    }

    /// The offer is over, however it ended: nothing left to run, and the keys
    /// go back.
    ///
    /// Called by every ending — a letter, a click, Escape, Return, the offer
    /// running out, and a new dictation starting. Safe to call when there is no
    /// offer, which is most of the time. A caller that still needs the words
    /// the offer was about reads `offeredCorrection` before calling this.
    private func endTheOffer() {
        offerUntil = nil
        offerHeld = false
        // Including one on its way back after a message. Escape, a click
        // outside or a keystroke means you have moved on, and a tab arriving
        // three seconds later would be the surface arguing about that.
        offerReturn?.cancel()
        offerReturn = nil
        offeredCorrection = nil
        offerOnScreen = nil
        // With the rest of what the offer was about. It decides whether a hold
        // is an edit — see `handleHotKeyPress` — and a headline outliving its
        // offer is one more slot that says something true about a surface that
        // is no longer there.
        offerHeadline = nil
        offerKeysExpiry?.cancel()
        offerKeysExpiry = nil
        offerKeys.stop()
        stopWatchingForOfferOutsideClick()
    }

    /// Run the command a chip was clicked on or lettered, and take the offer
    /// down.
    ///
    /// `transform` is the name on the chip, or nil for Correct. The pill goes
    /// first, before anything opens: whatever the command puts on screen
    /// belongs over the words, which is where the pill is sitting.
    private func runOfferedCommand(_ transform: String?) {
        // Read before the offer is ended, which is what clears it.
        let offered = offeredCorrection
        endTheOffer()
        pill.hide()

        // The sentence and where it went, frozen when the offer went up. Both
        // commands need it, and neither has anything to work on without it.
        guard let target = offered?.target else { return }

        // The clipboard as it is at the moment you choose. Everything below
        // takes time — a model call, or a panel left open while you think —
        // and the write-backs that copy check this before they do. What you
        // copied while the model was thinking is not this app's to drop.
        let clipboardWhenChosen = NSPasteboard.general.changeCount

        // Looked up again rather than carried on the chip, so a transform
        // deleted from a config reloaded while the offer was up is not run
        // from a chip that outlived it.
        if let name = transform {
            guard let found = config.transforms.first(where: { $0.name == name }) else {
                Log.write("offer: \"\(name)\" is no longer in the config")
                return
            }
            Log.write("offer: taken; running \"\(name)\"")
            runOfferedTransform(found, over: target, clipboardWhenChosen: clipboardWhenChosen)
            return
        }

        // Correct, which is not a transform: it is about the words rather than
        // about rewriting them.
        //
        // The correction panel rather than the preview panel — the offer names
        // one thing and that is the surface that does it. Over the sentence
        // frozen when the offer went up, and back into the field frozen with
        // it: the panel can be open for a while, and `focusAtPress` by then can
        // belong to a dictation that finished in the meantime. Teaching a rule
        // is the panel's own and is unchanged.
        Log.write("offer: taken; opening the correction panel")
        // Nothing here is a selection, and the offer's own target is what says
        // where the words go. Cleared so no later save can read one left behind
        // by an earlier flow.
        pendingSelection = nil
        correctionPanel.onSave = { [weak self] rules, correctedText in
            self?.saveOfferedCorrection(
                rules, correctedText: correctedText, into: target,
                clipboardWhenChosen: clipboardWhenChosen
            )
        }
        correctionPanel.onCancel = { Log.write("offer: correction dismissed") }
        correctionPanel.show(selection: target.original)
    }

    /// Run a transform over the sentence the offer is about, and put the result
    /// where that sentence went.
    ///
    /// Not `runTransform`, which is the selection path: that one looks for text
    /// to work on in whatever is frontmost, and falls back to `lastTranscript`.
    /// Both readings are wrong here. The offer already knows what it is about —
    /// it froze the sentence and its landing when it went up — and a dictation
    /// that ended on the clipboard left nothing in front to find, so the
    /// selection path would rewrite text nobody dictated.
    ///
    /// No preview panel, whatever the transform's `confirm:` says. `runInline`
    /// makes the same argument and for the same reason.
    ///
    /// The target is `target`, captured when the chip was pressed rather than
    /// read when the model answers. A grammar pass takes seconds and focus can
    /// move in them; the sentence this rewrites has to be the one that was on
    /// screen when the key went down.
    private func runOfferedTransform(
        _ transform: Config.Transform, over target: Correction, clipboardWhenChosen: Int
    ) {
        let before = target.original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !before.isEmpty else { return }

        Log.write("offer: \(transform.name) over \"\(before.prefix(80))\"")
        let token = beginProgress(transform.progressLabel)

        // On the main actor for the whole of it, so the answer is handled where
        // every other caller hands it back with `MainActor.run`. `perform` is
        // not isolated and does its waiting off here.
        Task { @MainActor [weak self] in
            do {
                // No instruction: the chip is the whole of what was asked for.
                guard let result = try await self?.perform(
                    transform, instruction: "", on: before
                ) else { return }
                self?.finishOfferedTransform(
                    transform, over: target, before: before, after: result,
                    clipboardWhenChosen: clipboardWhenChosen, progress: token
                )
            } catch {
                // Fail open: the words are untouched, wherever they are. Losing
                // a rewrite costs a second attempt; losing the sentence costs
                // the sentence.
                guard let self else { return }
                Log.write("offer: \(transform.name) failed: \(error.localizedDescription)")
                self.endProgress(token: token)
                // `clipboardWhenChosen` goes through the retry unchanged. It
                // still means what it meant — the clipboard as it was when the
                // chip was pressed — and pasting a key into the dialog moves
                // it, which is exactly when `copyOverOurOwn` should refuse.
                let asked = self.askForKeyThenRetry(error) {
                    self.runOfferedTransform(
                        transform, over: target, clipboardWhenChosen: clipboardWhenChosen
                    )
                }
                if !asked { self.flash(error.localizedDescription, tone: .failure) }
            }
        }
    }

    /// The model has answered. Write it back, or say why there is nothing to
    /// write.
    ///
    /// Every refusal here leaves the sentence exactly as it is — in the field or
    /// on the clipboard — and says so on screen.
    ///
    /// On screen, not only in the menu bar. The menu bar was the whole of it,
    /// on the argument that the pill sits over the words and a notice there
    /// would cover the thing the message is about. True, and beside the point:
    /// you are looking at the sentence, not at the menu bar, so an outcome
    /// reported there alone is an outcome nobody sees. "Fix grammar: nothing to
    /// change" arrived twice on 2026-08-20 and read both times as the app
    /// having quietly died. Every *failure* in this flow already used the pill,
    /// so the one shape that looked like nothing happening was the one that
    /// said nothing.
    ///
    /// Covering the sentence for a moment costs a moment. Not saying anything
    /// costs a retry, and the belief that the feature is broken.
    private func finishOfferedTransform(
        _ transform: Config.Transform, over target: Correction, before: String, after: String,
        clipboardWhenChosen: Int, progress token: Int?
    ) {
        endProgress(token: token)

        let cleaned = after.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            Log.write("offer: \(transform.name) returned nothing")
            flashThenOffer("\(transform.name) returned nothing", tone: .caution)
            return
        }
        // Saying so beats replacing text with itself and calling it done, which
        // looks identical to the prompt having silently failed.
        guard cleaned != before else {
            Log.write("offer: \(transform.name) changed nothing")
            flashThenOffer("\(transform.name): nothing to change", tone: .plain)
            return
        }

        Log.write("offer: \(transform.name) rewrote the dictation")
        Log.write("    before: \(before)")
        Log.write("    after:  \(cleaned)")
        replace(
            target, with: cleaned, describedAs: transform.name,
            clipboardWhenChosen: clipboardWhenChosen
        )
        // Over the words as they are now, not as they were: `replace` has
        // already put the rewrite into `lastDictated`, so a second transform
        // runs on the first one's output.
        offerAgainAfter(Self.noticeSeconds)
    }

    /// This press's dictation is over, however it ended. Drops the pane it
    /// started with — nothing can want it again — and lets the sweep above
    /// reach anything that is somehow left.
    private func dictationEnded(_ run: Int) {
        screenAtPress.removeValue(forKey: run)
        wroteAtPress.removeValue(forKey: run)
        heardAtPress.removeValue(forKey: run)
        InputBox.forget(run)
        pressesInFlight.remove(run)
        cancelledPresses.remove(run)
    }

    /// Over, and with nothing written. The pane goes as it does for any other
    /// ending, and the press is marked so a snapshot still being copied is
    /// dropped when it lands instead of sitting out the sweep.
    private func dictationCancelled(_ run: Int) {
        dictationEnded(run)
        cancelledPresses.insert(run)
    }

    /// For an app with no caret: keep asking what changed until the words show
    /// up, then move the pill there.
    ///
    /// Asked repeatedly rather than once, and that is the whole of what made
    /// the first version unreliable. The offer is raised the instant the
    /// insertion call returns; an app redraws when it gets round to it. A
    /// single read caught it about half the time, and a single retry a fixed
    /// 120ms later was the same bet with a different number on it. Six looks
    /// over half a second cost nothing and do not care how slow the app was.
    ///
    /// Nothing waits for this. The offer is already on screen at the position
    /// the pill opened with, and it moves if and when there is somewhere better
    /// to be — so a miss is not a delay, it is simply the old behaviour.
    ///
    /// Everything it needs comes from its own press, so a second dictation
    /// started while this one is still looking cannot redirect it — and the
    /// offer it moves has to still be the one that press raised.
    private func findWhereTheWordsLanded(
        comparedWith before: String, in element: AXUIElement, for run: Int
    ) {
        let deadline = Date().addingTimeInterval(0.5)
        // Off the main thread, because the thing being read can be enormous:
        // Outlook's message pane reported 395,489 characters, and every look
        // copies all of them out of a busy process. Six of those on the main
        // thread is a stutter in whatever the user is actually doing.
        let queue = DispatchQueue.global(qos: .userInitiated)

        func look() {
            let outcome = CaretAnchor.landed(after: before, at: element)
            // The screen the words landed on, for the next dictation into this
            // element to check `remembered` against. Read here rather than at
            // the press, where the same string would be a delay: this queue is
            // reading the pane anyway and nothing is waiting on it. Only for a
            // look that found something, so a search that misses costs nothing.
            var digest: Int?
            if case .found = outcome { digest = CaretAnchor.snapshot(of: element)?.hashValue }
            DispatchQueue.main.async { [weak self] in
                // Only while this press still owns what is on screen. The
                // offer may have expired, or another dictation may have raised
                // its own — and then the pill this would move is not the one
                // these words are under.
                guard let self, self.offerIsUp, self.offerPressRun == run
                else { return }
                switch outcome {
                case .found(let found):
                    self.pill.aim(at: found)
                    // Remembered for the next dictation into this same element,
                    // against the screen the words landed on. Without that
                    // there is nothing to tell the guess it has gone stale, so
                    // a pane that would not be read is a landing not worth
                    // keeping.
                    if let digest {
                        self.lastLanding = (element, found, Date(), digest)
                    }
                case .missed(let why):
                    guard Date() < deadline else {
                        Log.write("pill: never found the words — \(why)")
                        return
                    }
                    queue.asyncAfter(deadline: .now() + 0.08) { look() }
                }
            }
        }
        queue.asyncAfter(deadline: .now() + 0.04) { look() }
    }

    /// What an offer is about: the sentence, and the field it was written into.
    ///
    /// Captured when the offer is taken rather than read off `self` when
    /// Replace is pressed. The panel can be left open for as long as it takes
    /// to think about a spelling, and push-to-talk does not wait for the
    /// previous transcript — so by then `lastTranscript` and `focusAtPress` can
    /// both belong to a newer dictation, and the correction would be applied to
    /// a sentence nobody asked about. Every other path in this file carries its
    /// destination down the chain for the same reason.
    private struct Correction {
        let original: String
        let element: AXUIElement?
        let owner: NSRunningApplication?
        /// Where the words went, so the correction can follow them.
        let landing: Landing
        /// The dictation these words came from, or nil when they came from a
        /// selection instead.
        ///
        /// Only `noteRewritten` reads it, and only to decide whether a rewrite
        /// belongs to the record a tap would summon. Matching text is not proof
        /// of that: say the same short sentence twice, take the first one's
        /// offer after the second has landed, and the text matches while the
        /// dictation is somebody else's.
        var dictation: Int?
        /// The selection this offer was summoned over, when it was summoned
        /// over one rather than raised after a dictation.
        ///
        /// It is here for the range. `replace` otherwise finds the words by
        /// their text and takes the last copy, which is the right answer for a
        /// dictation — the newest thing written is the thing the offer is
        /// about. A selection is not: the copy that matters is the one you
        /// highlighted, and only the range says which that is. Carrying the
        /// whole `Selection` rather than the range alone is what lets this hand
        /// straight to `replaceSelected`, which already recovers a range that
        /// has moved.
        var selection: SelectionReader.Selection?

        /// The two places a dictation can end up.
        ///
        /// The offer is raised after every ending, and only one of them wrote
        /// anything into a field. The rest left the sentence on the clipboard,
        /// and `element` there is either nil or a field the words never
        /// reached — so this is what stops a correction being written into it.
        enum Landing {
            /// Pasted into `element`, which was confirmed focused at the paste.
            case field
            /// Left on the clipboard, with `NSPasteboard.changeCount` as it was
            /// straight after. Anything copied since — by the user or by
            /// anything else on the machine — moves that count, and then the
            /// clipboard is not this dictation's any more. See `replace`.
            case clipboard(change: Int)

            /// The clipboard as it is right now.
            ///
            /// Called immediately after the words were put there, so the count
            /// it takes is the one our own write produced. Read any later and
            /// it would be agreeing with whatever had happened in between.
            static func clipboardNow() -> Landing {
                .clipboard(change: NSPasteboard.general.changeCount)
            }
        }
    }

    /// Put the rewritten sentence where the dictation went.
    ///
    /// One mechanism, two destinations, and `target.landing` decides. Both
    /// commands on the offer end here: `what` is the name to put on screen —
    /// "Correction", or the transform's own name.
    ///
    /// **Into the field**, when that is where the words landed. The same ladder
    /// a transform without a selection climbs: hand focus back first — showing
    /// the panel activated us, so ⌘V here would land in our own window — then
    /// replace what we typed rather than pasting after it, which is what leaves
    /// both versions side by side.
    ///
    /// It refuses to write unless the field is the one that was dictated into.
    /// `insertDictation` makes the same check for the same reason: the words
    /// are found by matching the sentence, and a sentence can match in more
    /// than one place. Not knowing is not the same as knowing it is fine, so a
    /// lookup that fails counts as moved and the text goes to the clipboard.
    ///
    /// **Onto the clipboard**, when that is where the dictation went. Nothing
    /// was written into any field then, so there is nothing to rewrite — and
    /// `target.element` is either nil or a field these words never reached.
    /// Writing into it is exactly the "a sentence in somebody else's window"
    /// failure the focus check exists to prevent. What comes next after a
    /// clipboard ending is ⌘V, so the rewrite has to be what that pastes.
    ///
    /// No rules are saved. This is the sentence, not the vocabulary: teaching
    /// a word is what "Hey parrot, correct" and the correction panel are for,
    /// and quietly writing a rule out of every fixed sentence would fill
    /// config.yaml with pairs that will never recur.
    ///
    /// **Never over a clipboard that has moved on.** Both write-backs that copy
    /// check first, and both leave it alone when something else has been copied
    /// since. `clipboardWhenChosen` is `NSPasteboard.changeCount` as it was when
    /// the command was taken, which is the start of the wait that makes this
    /// possible — a model call, or a panel open while somebody thinks about a
    /// spelling. A rewrite that is refused costs a second attempt; a clipboard
    /// this app never filled and then emptied costs whatever was in it.
    ///
    /// Returns false when the sentence is on the clipboard — said on screen
    /// either way, and a caller with more to report should stop rather than
    /// talk over the one thing there is to act on. True means the field has it,
    /// or there was nothing to change.
    @discardableResult
    private func replace(
        _ target: Correction, with edited: String, describedAs what: String,
        clipboardWhenChosen: Int
    ) -> Bool {
        let corrected = edited.trimmingCharacters(in: .whitespacesAndNewlines)
        let original = target.original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty, !corrected.isEmpty, corrected != original else { return true }

        if case .clipboard(let change) = target.landing {
            // Only over our own words. A correction panel can be open for as
            // long as it takes to think about a spelling, and a transform takes
            // seconds — copy anything in that time and the clipboard is yours
            // rather than this dictation's. Writing over it would take
            // something away that this app never put there, and losing a
            // rewrite costs a second attempt.
            guard copyOverOurOwn(corrected, unlessChangedFrom: change) else {
                Log.write("offer: the clipboard has been used since the dictation;"
                    + " \(what) was not written over it")
                flash("Clipboard has changed — \(what) not copied", tone: .caution)
                return false
            }
            Log.write("offer: the dictation went to the clipboard; \(what) went there too")
            noteRewritten(original, as: corrected, from: target.dictation)
            flash("\(what) copied — ⌘V to paste", tone: .done)
            return false
        }

        // Only for a landing in a field. Nothing is posted at the app on the
        // clipboard path, and after a dictation that ended because focus moved,
        // pulling the app the user has left back in front would be the second
        // surprise in a row.
        if let owner = target.owner, !owner.isActive {
            owner.activate()
            // Let it come forward before the keystroke is posted.
            Thread.sleep(forTimeInterval: 0.15)
        }

        // Summoned over a selection: the path that already knows how to write
        // one back, range and all. The text search below would take the last
        // copy of the words in the field, and for a selection the last copy is
        // not the one you highlighted.
        //
        // A miss falls through to the clipboard rather than returning, the same
        // as every other way of not reaching the field: the rewrite is done and
        // it has to go somewhere.
        if let selection = target.selection {
            switch replaceSelected(with: corrected, in: selection, describedAs: what) {
            case .replaced:
                noteRewritten(original, as: corrected, from: target.dictation)
                applied(what)
                return true
            case .failed, .notAttempted:
                break
            }
        }

        // Only when this offer was not about a selection. `replaceSelected`
        // returns `.notAttempted` precisely when the field holds several copies
        // of the words and nothing says which was meant — and the search below
        // takes the last copy, which is the guess it just declined to make. A
        // highlighted earlier copy would be left alone while a later one was
        // rewritten. So a selection that could not be written falls to the
        // clipboard, which is what the comment above always claimed.
        if target.selection == nil,
           config.transcription.insertMode == .paste, let aimed = target.element {
            let now = SelectionReader.focusedElement()
            if let now, CFEqual(now, aimed), !SelectionReader.isOurs(now) {
                // `fuzzy: false`: the words on screen are the ones we typed
                // there, so there is nothing to settle for — and settling for
                // the nearest thing over a whole sentence is how a rewrite
                // lands on the wrong line.
                //
                // The sentence is found by its text, and the last copy of it
                // wins — `Surface.range(of:)`. That is the right answer for
                // what this is: the offer is about the newest dictation, and
                // the newest dictation is the last thing written. Say the same
                // short sentence twice and the second one is the one corrected.
                //
                // It cannot tell that copy from one *you* typed after it, and
                // nothing here can. Where the paste landed is not knowable:
                // `TextInserter` posts ⌘V and the app takes the pasteboard when
                // it gets round to it, so no range comes back. Refusing when
                // there is more than one copy would be worse than being wrong
                // rarely — a terminal echoes what you send it, so a second copy
                // appears there for reasons that have nothing to do with you.
                switch applyInPlace(
                    [Edit(find: original, replace: corrected, fuzzy: false)],
                    dictated: original, in: now, describedAs: what
                ) {
                case .replaced:
                    noteRewritten(original, as: corrected, from: target.dictation)
                    applied(what)
                    return true
                case .failed, .notAttempted:
                    break
                }
            } else {
                Log.write(now == nil
                    ? "offer: could not read what is focused; copied instead of rewriting"
                    : "offer: focus moved since the dictation; copied instead of rewriting")
            }
        }

        // The field would not take it, so the clipboard is the last place left
        // — and only if it is still the one you had when you chose the command.
        // The sentence is untouched in the field either way, so a refusal here
        // costs the rewrite and nothing else. What it protects is what you
        // copied while the model was thinking.
        guard copyOverOurOwn(corrected, unlessChangedFrom: clipboardWhenChosen) else {
            Log.write("offer: the field refused \(what) and the clipboard has been used"
                + " since; left both alone")
            flash("\(what) not applied — the clipboard has changed", tone: .caution)
            return false
        }

        Log.write("offer: left \(what) on the clipboard")
        flash("\(what) copied — this app won't let me edit it", tone: .caution)
        return false
    }

    /// Put text on the clipboard, unless somebody else has been there since.
    ///
    /// `change` is `NSPasteboard.changeCount` from the moment this app last knew
    /// what was on the clipboard. Anything copied since moves it, and then the
    /// clipboard is somebody's work rather than ours to overwrite.
    ///
    /// Or the clipboard this app itself last wrote, which a refused in-place
    /// edit reaches here having moved — see `TextInserter.clipboardIsOurs`.
    ///
    /// On the writing path the look and the write sit next to each other with
    /// nothing between them — no message — because there is nothing stronger to
    /// have. `NSPasteboard` offers no compare-and-write: `declareTypes(owner:)`
    /// names an owner for callbacks and stops no other process from writing. Any
    /// check is a look followed by a write, and the gap can only be made small.
    /// It is two calls here, and the messages are left to the caller so they
    /// cannot get in between. Only the refusal logs, and by then nothing is
    /// going to be written.
    ///
    /// Returns false when it did not write.
    private func copyOverOurOwn(_ text: String, unlessChangedFrom change: Int) -> Bool {
        let pasteboard = NSPasteboard.general
        guard TextInserter.clipboardIsOurs(unchangedFrom: change) else {
            Log.write("clipboard: at \(pasteboard.changeCount), not \(change) and not"
                + " our own \(TextInserter.ownChange); left alone")
            return false
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return true
    }

    /// The last dictation now reads differently, so a command that works on it
    /// works on the new text rather than on the sentence it replaced.
    ///
    /// Only if this is still the sentence the app thinks it wrote last. A newer
    /// dictation has its own, and it is one slot.
    private func noteRewritten(_ original: String, as corrected: String, from dictation: Int?) {
        guard lastTranscript?.trimmingCharacters(in: .whitespacesAndNewlines) == original
        else { return }
        lastTranscript = corrected
        // And the words a tap would summon over, which are the same words in
        // the same field. Left behind, a summon after a rewrite would offer the
        // sentence that is no longer on screen.
        //
        // By run, not by text. The panel can be open for as long as it takes to
        // think about a spelling and push-to-talk does not wait, so an older
        // correction can finish after a newer dictation — and if the two said
        // the same thing, the text matches while the record belongs to the
        // newer one. Relabelling it there would leave the older correction's
        // words pointing at the newer dictation's field.
        guard let dictation, dictation == lastDictated?.run else { return }
        lastDictated?.text = corrected
        // And the watch follows them. Selecting a sentence you have just had
        // rewritten has to offer again — the words on screen are the new ones,
        // and the old ones are not in the field to be selected any more.
        watchForReselection()
    }

    private func beginCorrection(over target: Target = .whateverIsSelected) {
        // Reading the selection needs Accessibility; the panel does not. Open
        // it either way — typing both sides still beats editing YAML by hand,
        // and a panel that silently refuses to appear reads as a broken app.
        //
        // A spoken command brings its own, frozen when its recording began. It
        // does not read the slot: "hey parrot" is decoded like any other
        // dictation, and a newer press can have filled that slot by the time it
        // is understood — the panel would then open over the newer selection.
        let selection: SelectionReader.Selection?
        switch target {
        case .frozen(let held, _):
            selection = held
        case .whateverIsSelected:
            selection = selectionAtPress ?? (
                Permissions.accessibility == .granted ? SelectionReader.read() : nil
            )
            selectionAtPress = nil
        }

        Log.write("correction: selection = \(selection.map { "\"\($0.text)\"" } ?? "none")")
        pendingSelection = selection
        correctionPanel.onSave = { [weak self] rules, correctedText in
            self?.saveCorrections(rules, correctedText: correctedText)
        }
        correctionPanel.onCancel = { [weak self] in
            self?.pendingSelection = nil
        }
        correctionPanel.show(selection: selection?.text ?? "")
    }

    /// Write out what the panel taught, one rule at a time.
    ///
    /// False means one could not be written and the user has already been shown
    /// why. Nothing after it should run: a correction that half-saved and then
    /// went on to rewrite the field would leave the two disagreeing.
    private func learn(_ rules: [TaughtRule], in corrected: String) -> Bool {
        for rule in rules {
            do {
                try ConfigWriter.addVocabularyPronunciation(
                    term: rule.corrected, heard: rule.heard, kind: rule.kind
                )
                // The sentence too, not only the mapping. It is what a term's
                // portrait is built from, and this is the only moment the app
                // knows a sentence is right.
                do {
                    try TermUses.record(
                        term: rule.corrected, said: corrected, span: rule.corrected
                    )
                } catch {
                    // A portrait that missed one sentence is worth less than a
                    // correction that refused to save over it.
                    Log.write("could not record the use: \(error.localizedDescription)")
                }
                Log.write("learned pronunciation: \(rule.heard) -> \(rule.corrected)")
                Trace.correction(heard: rule.heard, corrected: rule.corrected, via: "command")
            } catch {
                presentAlert(title: "Could not save the rule", message: error.localizedDescription)
                return false
            }
        }
        return true
    }

    /// Save what the panel taught, then write the sentence back into the field
    /// the offer was about.
    ///
    /// Separate from `saveCorrections` for one reason: the destination. That
    /// one has to work out where the words go, and falls back to `focusAtPress`
    /// and then to the clipboard. This one already knows — the offer froze the
    /// element, its app and the landing when it went up. The panel can be open
    /// for as long as it takes to think about a spelling, and push-to-talk does
    /// not wait for the previous transcript, so anything read at this moment can
    /// belong to a newer dictation. `replace` carries the same care the tapped
    /// offer takes: focus handed back first, a refusal to write unless the field
    /// is still the one that was dictated into, and the clipboard when the
    /// dictation itself went there.
    private func saveOfferedCorrection(
        _ rules: [TaughtRule],
        correctedText: String,
        into target: Correction,
        clipboardWhenChosen: Int
    ) {
        guard learn(rules, in: correctedText) else { return }
        // On the clipboard, or not written at all, and `replace` has said which.
        // A rule notice on top of that would bury the one thing you need to act
        // on.
        guard replace(
            target, with: correctedText, describedAs: "Correction",
            clipboardWhenChosen: clipboardWhenChosen
        ) else { return }
        switch rules.count {
        // Nothing taught, so `replace` has already said the only thing there
        // is to say.
        case 0: break
        case 1: flash("Saved  \(rules[0].heard) → \(rules[0].corrected)", tone: .done)
        default: flash("Saved \(rules.count) rules", tone: .done)
        }
    }

    private func saveCorrections(
        _ rules: [TaughtRule],
        correctedText: String
    ) {
        guard learn(rules, in: correctedText) else {
            pendingSelection = nil
            return
        }

        // Put the corrected phrase back where it came from, whether or not any
        // rules were saved — the user may just be fixing this one instance.
        let trimmed = correctedText.trimmingCharacters(in: .whitespacesAndNewlines)
        var landedOnClipboard = false
        if let selection = pendingSelection, !trimmed.isEmpty {
            switch replaceSelected(
                with: correctedText, in: selection, describedAs: "correction"
            ) {
            case .replaced:
                break
            case .failed, .notAttempted:
                Log.write("field would not accept the correction; it is on the clipboard")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(correctedText, forType: .string)
                landedOnClipboard = true
            }
        } else if !rules.isEmpty, let focus = focusAtPress,
                  let element = SelectionReader.refocusedElement(in: focus.owner)
                      ?? focus.element.flatMap({ SelectionReader.isOurs($0) ? nil : $0 }) {
            // Learned by voice: nothing was selected, but the misspelling is
            // still sitting in the field where it was dictated. Fix it there,
            // by the same ladder a transform uses. The transcript is what we
            // typed into that line, so it is the one description of the line
            // that was not read off a screen.
            switch applyInPlace(
                rules.map { Edit(find: $0.heard, replace: $0.corrected, fuzzy: true) },
                dictated: lastTranscript,
                in: element,
                describedAs: "correction"
            ) {
            case .replaced:
                break
            case .notAttempted, .failed:
                Log.write("field would not accept the rewrite; correction is on the clipboard")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(rules[0].corrected, forType: .string)
                landedOnClipboard = true
            }
        } else if !trimmed.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(correctedText, forType: .string)
        }
        pendingSelection = nil
        focusAtPress = nil

        playFeedback("Morse")
        if landedOnClipboard {
            flash("Rule saved · \"\(rules.first?.corrected ?? "")\" copied — this app won't let me edit it", tone: .caution)
            return
        }
        switch rules.count {
        case 0: flash("Text replaced\(undoHint)", tone: .done)
        case 1: flash("Saved  \(rules[0].heard) → \(rules[0].corrected)", tone: .done)
        default: flash("Saved \(rules.count) rules", tone: .done)
        }
    }

    /// Text quoted for a one-line notice, shortened from the middle.
    ///
    /// The middle rather than the tail: what tells you whether the transform
    /// looked at the right thing is how it starts and how it ends, and a tail
    /// ellipsis throws away half of that.
    private func quoted(_ text: String, limit: Int = 44) -> String {
        let flat = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard flat.count > limit else { return "\"\(flat)\"" }
        let head = flat.prefix(limit / 2).trimmingCharacters(in: .whitespaces)
        let tail = flat.suffix(limit / 2 - 1).trimmingCharacters(in: .whitespaces)
        return "\"\(head)…\(tail)\""
    }

    /// Play one of the system sounds, if sounds are on, at the configured volume.
    private func playFeedback(_ name: String) {
        guard config.feedback.sound, let sound = NSSound(named: name) else { return }
        sound.volume = config.feedback.soundVolume
        sound.play()
    }

    /// Show a message on screen, and in the menu bar for as long as it lasts.
    private func flash(_ message: String, tone: NoticeTone = .plain) {
        pill.notice(message, tone: tone)
        setLabel(message, clearAfter: 4)
    }

    /// Who the message on the pill belongs to. Bumped for every message put
    /// up, so only the last one handed out is live.
    ///
    /// There is one pill and every job shares it. Push-to-talk does not wait
    /// for the previous transcript, so two dictations are routinely in flight,
    /// and a spoken command or an update can put a message up over either. A
    /// caller that hides the pill without saying which message it meant takes
    /// down whatever is on screen — including one a newer job put there, which
    /// leaves that job running behind a blank pill and reads as a dropped
    /// dictation.
    private var progressToken = 0

    /// A message that stays up until `endProgress`, for work of no
    /// predictable length. "Thinking…" was a `flash`, so it timed out after
    /// 3.5s while a cold Ollama was still loading — leaving the rest of a 10s
    /// wait with nothing on screen at all.
    ///
    /// The token it returns is what takes this message down again. Hold it
    /// until the work ends, and hand it back to whatever ends on your behalf.
    /// Not discardable: a message put up with the token thrown away is one
    /// nothing can take down.
    private func beginProgress(_ message: String) -> Int {
        progressToken += 1
        pill.working(message)
        setLabel(message)
        return progressToken
    }

    /// The same caller's next message — a pipeline stage label, a download
    /// percentage climbing — over the one it already has up. The token is kept,
    /// so the token the caller holds still ends it.
    ///
    /// Nothing is drawn once something else owns the pill. Redrawing there
    /// would take the screen from a job that is still working, and the token
    /// held by this caller could no longer take the message down.
    private func updateProgress(_ message: String, token: Int?) {
        guard let token, token == progressToken else { return }
        pill.working(message)
        setLabel(message)
    }

    /// `token` is what `beginProgress` returned. A stale one — someone else's
    /// message is on the pill now — takes nothing down, and neither does `nil`,
    /// which is what a path that inherited no message of its own passes.
    ///
    /// `run` is the dictation this ends, where there is one. Only that run may
    /// give up its claim on the download pill. Push-to-talk leaves an older
    /// dictation running a transform while a newer one waits on a model — the
    /// vocabulary model is fetched mid-dictation at `Transcriber.swift:356` —
    /// and clearing the claim from the older one would cost the newer one the
    /// pill it gets back at `.ready`. Keyed on the run and not on what is
    /// drawn, so the claim is given up whether or not this hides anything.
    private func endProgress(token: Int?, for run: Int? = nil) {
        if pillDownloadRun == run { pillDownloadRun = nil }
        guard let token, token == progressToken else { return }
        // An empty pill has no owner: no token still out there can put a
        // message back on it, or take a newer one down.
        progressToken += 1
        pill.hide()
        setLabel(nil)
    }

    /// Activation and not the press: the tree is not built by the time the
    /// call returns. The app already in front at launch never sends one.
    private func watchActivation() {
        let centre = NSWorkspace.shared.notificationCenter
        centre.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            ChromiumAccessibility.askIfNeeded(
                note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            )
        }
        centre.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { note in
            ChromiumAccessibility.forget(
                note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            )
        }
        ChromiumAccessibility.askIfNeeded(NSWorkspace.shared.frontmostApplication)
    }

    /// Sets the menu bar title, optionally clearing it again after a delay.
    ///
    /// The token matters: these clears are fire-and-forget, so without it a
    /// timer armed for "Copied — ⌘V to paste" wipes whatever newer message has
    /// replaced it in the meantime.
    private func setLabel(_ message: String?, clearAfter: TimeInterval? = nil) {
        labelToken += 1
        let token = labelToken
        transcriptionLabel = message
        updateUI()

        guard let clearAfter else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + clearAfter) { [weak self] in
            guard let self, self.labelToken == token else { return }
            self.transcriptionLabel = nil
            self.updateUI()
        }
    }

    /// `destination` is where this dictation was aimed when its hotkey went
    /// down — passed along rather than looked up, so a second press landing
    /// mid-transcription cannot redirect this one. See `transcribe`.
    private func finishTranscription(
        text: String, destination: Destination, focus: SelectionReader.Selection?,
        for press: Press
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // What lands, which is not the same string. `trimmed` answers the
        // questions — wake phrase, empty clip, inline instruction — and none of
        // them care about the spaces at the ends. Delivery does: a stage that
        // continues a sentence already in the box puts a space in front of its
        // output, and trimming here is why that space never arrived.
        //
        // Newlines are still cut. A newline in a composer sends the message,
        // and no stage has a reason to ask for one at either end.
        let delivered = text.trimmingCharacters(in: .newlines)

        // The gesture already said this is an instruction, so nothing is
        // looked for in the words. That is the whole point of it: the phrase
        // exists to mark a command inside an ordinary dictation, and there is
        // nothing to mark when the key said so first.
        if press.keyed {
            dictationEnded(press.run)
            guard !trimmed.isEmpty else {
                Log.write("command: nothing was said")
                flash("Didn't catch that", tone: .caution)
                updateUI()
                return
            }
            Log.write("command keyed: \"\(trimmed)\"")
            handleVoiceCommand(
                trimmed, keyed: true,
                over: .frozen(selection: press.selection, fallback: press.transcript)
            )
            return
        }

        // Heard as a command, or nothing at all: no words are going to land,
        // so there is nothing to compare a pane against.
        if let command = commandAfterWakePhrase(trimmed) {
            Log.write("command heard: \"\(command)\"")
            dictationEnded(press.run)
            handleVoiceCommand(command, over: .frozen(selection: press.selection, fallback: press.transcript))
            return
        }

        guard !trimmed.isEmpty else {
            Log.write("transcription produced no text")
            dictationEnded(press.run)
            updateUI()
            return
        }

        // An instruction said inside the dictation, about the words in front of
        // it. Checked after the command case above, which is the same phrase in
        // the first position and means something else entirely.
        if let split = VoiceCommand.inlineInstruction(
            trimmed, phrases: config.transcription.activationPhrases
        ) {
            Log.write("inline: \"\(split.instruction)\" over \"\(split.text)\"")
            lastTranscript = split.text
            runInline(
                text: split.text, instruction: split.instruction,
                destination: destination, focus: focus, for: press
            )
            return
        }

        Log.write("transcribed: \(trimmed)")
        lastTranscript = trimmed
        insertDictation(delivered, to: destination, for: press)
    }

    /// An instruction found inside a dictation: route it, run it over the words
    /// that came before it, and write the result.
    ///
    /// Every way this can fail writes the dictated text instead, and says what
    /// went wrong for long enough to read. That is the opposite of the rule
    /// elsewhere in the app, where a transform that fails leaves the text
    /// alone — there the words are already on screen, and here they exist
    /// nowhere but in this function. Losing the instruction costs you a second
    /// attempt; losing the sentence costs you the sentence.
    ///
    /// No preview panel, whatever the transform's `confirm` says. That setting
    /// guards text you selected and are about to have overwritten; nothing is
    /// being overwritten here, and a dialog in the middle would give back the
    /// second round trip this exists to remove. The rewrite goes to the log
    /// with its before and after, as pipeline transforms do.
    private func runInline(
        text: String, instruction: String, destination: Destination,
        focus: SelectionReader.Selection?, for press: Press
    ) {
        let catalogue = Catalogue(transforms: config.transforms)

        /// Write what was said, and say why it is not what was asked for.
        ///
        /// `progress` is the message this path still has up, if any: the
        /// router's "Thinking…", or the transform's own label.
        func giveUp(_ why: String, tone: NoticeTone = .caution, progress token: Int?) {
            endProgress(token: token)
            Log.write("inline: \(why); wrote the text as dictated")
            insertDictation(text, to: destination, for: press)
            pill.notice(why, tone: tone, duration: 7)
            setLabel(why, clearAfter: 7)
        }

        func run(_ transform: Config.Transform) {
            let token = beginProgress(transform.progressLabel)
            Task { [weak self] in
                do {
                    guard let result = try await self?.perform(
                        transform, instruction: instruction, on: text
                    ) else { return }
                    await MainActor.run {
                        guard let self else { return }
                        self.endProgress(token: token)
                        let cleaned = result.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !cleaned.isEmpty else {
                            giveUp(
                                "\(transform.name) returned nothing", tone: .failure,
                                progress: nil
                            )
                            return
                        }
                        if cleaned != text {
                            Log.write("inline: \(transform.name) rewrote the transcript")
                            Log.write("    before: \(text)")
                            Log.write("    after:  \(cleaned)")
                        }
                        self.lastTranscript = cleaned
                        self.insertDictation(cleaned, to: destination, for: press)
                    }
                } catch {
                    await MainActor.run {
                        giveUp(error.localizedDescription, tone: .failure, progress: token)
                    }
                }
            }
        }

        if let capability = Router.local(instruction: instruction, catalogue: catalogue) {
            Log.write("inline router: \"\(instruction)\" named \(capability.name) outright")
            switch capability {
            case .transform(let transform): run(transform)
            case .action(let action):
                runInlineAction(
                    action, text: text, instruction: instruction,
                    destination: destination, focus: focus, for: press, progress: nil
                )
            }
            return
        }

        guard config.llmEnabled else {
            giveUp(
                "\"\(instruction)\" needs a model — `models:` defines none", progress: nil
            )
            return
        }

        let token = beginProgress("Thinking…")
        let llm = llmConfig(for: .router)
        let freeForm = config.freeForm
        let catchAll = config.commands.catchAll
        Task { [weak self] in
            do {
                let decision = try await Router.route(
                    instruction: instruction, catalogue: catalogue,
                    freeForm: freeForm, config: llm
                )
                await MainActor.run {
                    guard let self else { return }
                    switch decision {
                    case .matched(.transform(let transform)):
                        Log.write("inline router: \"\(instruction)\" → \(transform.name)")
                        run(transform)
                    case .matched(.action(let action)):
                        self.runInlineAction(
                            action, text: text, instruction: instruction,
                            destination: destination, focus: focus, for: press,
                            progress: token
                        )
                    case .anything:
                        Log.write("inline router: \"\(instruction)\" → \(FreeForm.name)")
                        run(FreeForm.prompt(for: instruction).asTransform(model: catchAll))
                    case .none:
                        giveUp(
                            "Not something to change in the text: \"\(instruction)\"",
                            progress: token
                        )
                    }
                }
            } catch {
                await MainActor.run {
                    giveUp(error.localizedDescription, tone: .failure, progress: token)
                }
            }
        }
    }

    /// A built-in action asked for inside a dictation.
    ///
    /// The command path has to find what the action applies to — a selection,
    /// or the last thing dictated — and then write into it where it sits, which
    /// is the ladder in `saveCorrections` and where the risk of this app lives.
    /// Inline there is nothing to find: the text is the words in front of the
    /// phrase, and it has not been written yet. The panel opens first, and what
    /// goes in afterwards is already corrected.
    ///
    /// Cancelling writes what was dictated. Refusing the whole utterance
    /// because a panel was dismissed would lose the sentence over a change of
    /// mind about a rule.
    private func runInlineAction(
        _ action: Capability.Action, text: String, instruction: String,
        destination: Destination, focus: SelectionReader.Selection?, for press: Press,
        progress inherited: Int?
    ) {
        switch action {
        case .vocabulary:
            // "…by the way parrot, fix vocabulary" — nothing to extract, the
            // panel opens on the sentence itself and you correct it by hand.
            endProgress(token: inherited)
            Log.write("inline: correction panel over \"\(text)\"")
            showInlineCorrection(
                over: text, rules: nil, destination: destination, focus: focus, for: press
            )

        case .spelling:
            // "…by the way parrot, Tasmin spells T A S M E E N" — the rule has
            // to be read out of the instruction first, which is a model call of
            // its own and not part of routing.
            guard config.llmEnabled else {
                giveUpInline(
                    text,
                    why: "\"\(instruction)\" needs the local model to read the spelling",
                    destination: destination, focus: focus, for: press, progress: inherited
                )
                return
            }
            let token = beginProgress("Thinking…")
            let llm = llmConfig()
            // From the dictated text, not the instruction: the instruction is a
            // name plus a run of loose capitals, which reads as English
            // whatever was actually said.
            let language = DictationLanguage.forCorrection(
                transcript: text, allowed: config.transcription.languages
            )
            Task { [weak self] in
                do {
                    let result = try await VoiceCommand.interpret(
                        command: instruction, lastTranscript: text,
                        language: language, config: llm
                    )
                    await MainActor.run {
                        guard let self else { return }
                        self.endProgress(token: token)
                        switch result {
                        case .addRules(let rules):
                            for rule in rules {
                                Log.write("inline: proposed rule \(rule.heard) -> \(rule.corrected)")
                            }
                            self.showInlineCorrection(
                                over: text, rules: rules,
                                destination: destination, focus: focus, for: press
                            )
                        case .openCorrectionPanel:
                            self.showInlineCorrection(
                                over: text, rules: nil,
                                destination: destination, focus: focus, for: press
                            )
                        case .undo, .unrecognised:
                            // Undo cannot be reached from here: this path is
                            // the spelling extractor, and it is only asked
                            // about an instruction that already routed to
                            // `spelling`. Said mid-dictation it would mean
                            // undoing a substitution that has not happened yet
                            // — the text is still in this function.
                            self.giveUpInline(
                                text, why: "Didn't understand \"\(instruction)\"",
                                destination: destination, focus: focus, for: press,
                                progress: nil
                            )
                        }
                    }
                } catch {
                    await MainActor.run {
                        guard let self else { return }
                        self.giveUpInline(
                            text, why: error.localizedDescription, tone: .failure,
                            destination: destination, focus: focus, for: press, progress: token
                        )
                    }
                }
            }
        }
    }

    /// The correction panel, with the dictated text waiting behind it.
    ///
    /// `pendingSelection` is deliberately cleared: it is how `saveCorrections`
    /// decides to write into a field somewhere else, and here the only place
    /// the text should land is where a dictation would put it. Leaving it set
    /// would rewrite whatever happened to be selected when the hotkey went down.
    ///
    /// `focus` is passed in rather than read off `focusAtPress` when the panel
    /// closes. This panel is the longest wait in the app — it is open for as
    /// long as someone takes to think about a spelling — and a dictation
    /// started somewhere else in the meantime moves that field. Reading it late
    /// would hand focus to the newer app and paste this sentence into it.
    ///
    /// `proposed` is named apart from the panel's own `rules` on purpose. Both
    /// used to be called `rules`, and the closure's parameter shadowed this one
    /// — so the test for "was the panel opened on the sentence rather than on
    /// proposed rules" compared a non-optional array against nil, was always
    /// false, and silently threw away text the speaker had typed into the panel
    /// by hand. The two are genuinely different questions: what the model
    /// proposed on the way in, and what was confirmed on the way out.
    private func showInlineCorrection(
        over text: String, rules proposed: [(heard: String, corrected: String)]?,
        destination: Destination, focus: SelectionReader.Selection?, for press: Press
    ) {
        pendingSelection = nil

        /// Hand focus back before writing anything.
        ///
        /// `CorrectionPanel.show` calls `NSApp.activate(ignoringOtherApps:)` to
        /// put itself in front, so by the time you press Save we are the
        /// frontmost app and the paste lands in our own window. It leaves no
        /// trace: the insert reports `.pasted`, which is silent, so the log
        /// showed a rule proposed and then nothing at all. `applyTransform`
        /// learned this the same way and does the same thing.
        func handBack() {
            guard let owner = focus?.owner, !owner.isActive else { return }
            owner.activate()
            // Let it come forward before the keystroke is posted.
            Thread.sleep(forTimeInterval: 0.15)
        }
        correctionPanel.onSave = { [weak self] rules, correctedText in
            guard let self else { return }
            for rule in rules {
                do {
                    try ConfigWriter.addVocabularyPronunciation(
                        term: rule.corrected, heard: rule.heard, kind: rule.kind
                    )
                    Log.write("learned pronunciation: \(rule.heard) -> \(rule.corrected)")
                    Trace.correction(
                        heard: rule.heard, corrected: rule.corrected, via: "panel"
                    )
                } catch {
                    self.presentAlert(
                        title: "Could not save the rule", message: error.localizedDescription
                    )
                }
            }
            // A rule taught about the sentence you just said should be true of
            // that sentence. Applied here rather than by re-running the
            // pipeline: the config on disk has only just changed, and the copy
            // in memory is reloaded by a file watcher that has not fired yet.
            let corrected = rules.isEmpty ? text : Replacements.applyExact(
                to: text,
                rules: rules.map {
                    Config.Transcription.Rule(source: $0.heard, replacement: $0.corrected)
                }
            )
            if corrected != text {
                Log.write("inline: applied the new rule(s) to the transcript")
                Log.write("    before: \(text)")
                Log.write("    after:  \(corrected)")
            }
            // The panel edits words, not the sentence, when it was opened on
            // proposed rules — so its text is only the target when it was
            // opened on the sentence itself.
            let final = proposed == nil && !correctedText.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty ? correctedText : corrected
            self.lastTranscript = final
            handBack()
            Log.write("inline: writing into \(focus?.owner?.localizedName ?? "the frontmost app")")
            self.insertDictation(final, to: destination, for: press)
        }
        correctionPanel.onCancel = { [weak self] in
            guard let self else { return }
            Log.write("inline: correction dismissed; wrote the text as dictated")
            handBack()
            self.insertDictation(text, to: destination, for: press)
        }

        if let proposed {
            correctionPanel.show(rules: proposed)
        } else {
            correctionPanel.show(selection: text)
        }
    }

    /// Write what was said, and say why it is not what was asked for.
    private func giveUpInline(
        _ text: String, why: String, tone: NoticeTone = .caution,
        destination: Destination, focus: SelectionReader.Selection?, for press: Press,
        progress token: Int?
    ) {
        endProgress(token: token)
        Log.write("inline: \(why); wrote the text as dictated")
        insertDictation(text, to: destination, for: press)
        pill.notice(why, tone: tone, duration: 7)
        setLabel(why, clearAfter: 7)
    }

    /// The text, exactly as dictation puts it in.
    ///
    /// Its own function because the inline path needs it too: every way that
    /// path fails has to still write what you said. A transform over a
    /// selection can fail with nothing but a message, because the words are
    /// already on screen — here they have never been written, and a toast is
    /// not somewhere you can copy them back out of.
    ///
    /// `destination` is where *this* text was aimed when its hotkey went down,
    /// carried in rather than read off `self` — by the time an inline prompt
    /// and a correction panel have both had their turn, the field may be
    /// holding a newer press's answer.
    /// Write the transcript where it was aimed, or put it on the clipboard and
    /// say so.
    ///
    /// `press.element` is the element that had focus when the hotkey went down.
    /// A transcript arrives seconds later — a decoder, then any prompt stage —
    /// and `TextInserter` posts ⌘V into whatever is frontmost by then. Dictate
    /// an instruction into one terminal pane, switch to the next while it works,
    /// and the sentence lands in the wrong session. Nothing in this app has ever
    /// pinned a pane: every `owner.activate()` here activates an application.
    ///
    /// So this does not try to steer the paste back. It refuses to paste at all
    /// when the field is not the one that was dictated into, and copies instead.
    /// Putting focus back would mean setting `kAXFocused` and trusting an app to
    /// honour it, which is a guess; the clipboard is not.
    ///
    /// A nil `press.element` means there was nothing to compare against — no
    /// focus was resolved at the press at all — and the paste goes ahead as it
    /// always did. That is different from failing to read focus *now*, which
    /// counts as moved: not knowing is not the same as knowing it is fine. The
    /// press is passed explicitly at every call rather than defaulted, so a new
    /// path has to say which dictation it is writing for.
    ///
    /// False positives would make this unusable: guard too eagerly and every
    /// dictation ends up on the clipboard. The comparison was measured before it
    /// was relied on — the press-time experiment behind the `context` stage ran
    /// this same `CFEqual` across 17 real dictations and the element was equal
    /// every time.
    private func insertDictation(
        _ text: String, to destination: Destination, for press: Press
    ) {
        // Before anything can fail: `showCorrectOffer` measures the span from
        // this and every ending below reaches it. See `wroteAtPress`.
        wroteAtPress[press.run] = text.utf16.count
        let element = press.element
        // However this ends, this dictation is over and nothing wants the pane
        // it started with. Every path here makes the offer now, and the offer
        // takes the pane before this runs — so this is the backstop for the
        // three ways `showCorrectOffer` returns without getting that far: the
        // offer switched off in the config, an empty transcript, and a newer
        // dictation that already had the pill.
        defer { dictationEnded(press.run) }
        // Confirmed the same field, or nothing to confirm against. Anything
        // else copies.
        //
        // A lookup that fails counts as moved rather than as unchanged. It
        // returns nil on a 0.25s timeout against a busy app, and "I could not
        // tell" is not "it is fine" — pasting on it would be the guess this
        // whole check exists to avoid. The cost of being wrong that way is a
        // transcript on the clipboard with a notice, which is recoverable; the
        // cost the other way is a sentence in somebody else's window.
        //
        // Accessibility is checked first so a machine without the grant keeps
        // the message it has always had. `TextInserter` returns `.clipboardOnly`
        // there and says so below, and "Focus moved" would be both wrong and
        // less useful than "grant Accessibility".
        if config.transcription.insertMode == .paste, let element,
           Permissions.accessibility == .granted {
            let now = SelectionReader.focusedElement()
            if now == nil || !CFEqual(now!, element) {
                TextInserter.insert(text, mode: .clipboard, paste: press.paste)
                // Not the paste sound — see the nowhere-to-type ending below.
                playFeedback("Tink")
                Log.write(now == nil
                    ? "could not read what is focused; copied instead of pasting"
                    : "focus moved since the press; copied instead of pasting")
                setLabel("Focus moved — the transcription is on your clipboard", clearAfter: 4)
                showCorrectOffer(
                    for: press, landing: .clipboardNow(), headline: .landing("Focus moved · ⌘V")
                )
                updateUI()
                return
            }
        }

        // Nowhere to type: the pill said so by leaving its icon out, and this is
        // the other half of that. Pasting anyway is the bad outcome — a ⌘V into
        // a Finder window or a video player does whatever that window makes of
        // it, and the sentence is gone, because a dictation exists nowhere but
        // here until it is written down.
        //
        // The clipboard is the one destination that always exists, so this one
        // is said out loud rather than logged. "It went to the clipboard" is
        // only true if you know it: unsaid, it is indistinguishable from the
        // dictation having failed, and you say the whole thing again.
        //
        // Two cases are deliberately not this one. `insert_mode: clipboard` is
        // someone who has already decided every transcript is copied, and a
        // notice each time would be telling them what they configured. A
        // missing Accessibility grant lands on the clipboard too, but it is a
        // permission to grant rather than a window to click into, and it has
        // been saying so in the menu bar for as long as it has existed — see the
        // `.clipboardOnly` branch below.
        if config.transcription.insertMode == .paste,
           case .nowhere(let reason) = destination, reason != .noAccessibility {
            TextInserter.insert(text, mode: .clipboard, paste: press.paste)
            // Not Morse: a sound that cannot be told from success is no sound.
            playFeedback("Tink")
            Log.write("nothing to type into (\(reason.described)); copied instead")
            setLabel("Nowhere to type — the transcription is on your clipboard", clearAfter: 4)
            // And on the pill: the menu bar row is inside a menu you must open.
            showCorrectOffer(
                for: press, landing: .clipboardNow(), headline: .landing("Nowhere to type · ⌘V")
            )
            updateUI()
            return
        }

        switch TextInserter.insert(
            text, mode: config.transcription.insertMode, paste: press.paste
        ) {
        case .pasted:
            playFeedback("Morse")
            // The words are in the field and you are looking at them. This is
            // the only second in which correcting one is free.
            showCorrectOffer(for: press, landing: .field)
        case .copied:
            // Deliberate clipboard mode — confirm it landed.
            playFeedback("Morse")
            setLabel("Copied — ⌘V to paste", clearAfter: 4)
            showCorrectOffer(for: press, landing: .clipboardNow())
        case .clipboardOnly:
            playFeedback("Morse")
            // Don't nag on every dictation — the text is safe on the clipboard.
            Log.write("Accessibility not granted; left transcript on the clipboard")
            setLabel("Copied — grant Accessibility to auto-paste", clearAfter: 4)
            showCorrectOffer(for: press, landing: .clipboardNow())
        }
        updateUI()
    }

    /// The token `setLabel` held while a load owned the label, so `.ready`
    /// clears only its own message — not "Transcribing…", which a live
    /// dictation may have put up in the meantime.
    private var transcriberLabelToken: Int?

    /// The transcriber's last reported status, mirrored here because the
    /// actor's own copy cannot be read without an await, and a key release has
    /// no time for one. Both sides are the main queue — `onStatusChange` hops
    /// there before it lands — so it needs no lock.
    private var transcriberStatus: Transcriber.Status = .idle

    /// The `transcriptionRun` whose pill is showing the model download instead
    /// of the dictation, if any.
    ///
    /// A run and not a flag, for the reason every other late arrival in this
    /// file carries one. Push-to-talk does not wait, so two dictations sit on
    /// the same download, and the older one's `.ready` would otherwise take the
    /// pill from the newer one that has since put its own message up.
    private var pillDownloadRun: Int?

    /// The `progressToken` of the newest dictation's message, for the two
    /// places that write to that message without holding the token: the
    /// transcriber's own status, which replaces the download percentage as it
    /// climbs, and Escape, which takes the message down.
    private var dictationProgressToken: Int?

    /// The `transcriptionRun == run` test the rest of the chain makes, asked of
    /// the pill: the run that put the download up is still the newest one.
    private var ownsDownloadPill: Bool { pillDownloadRun == transcriptionRun }

    private func handleTranscriberStatus(_ status: Transcriber.Status) {
        transcriberStatus = status
        switch status {
        case .downloading(let what, let blocking):
            setLabel("Downloading \(what)")
            // `what` already carries the percentage, so replacing the text in
            // place is what makes the number climb. Only for the dictation that
            // put the download up: it is waiting on exactly this, and
            // "Transcribing…" over a 470 MB fetch reads as a hang.
            if blocking, ownsDownloadPill {
                updateProgress("Downloading \(what)", token: dictationProgressToken)
            }
            // After the pill, which writes the label too: this has to hold the
            // token of the last write, or `.ready` never clears the menu bar.
            transcriberLabelToken = labelToken
            // `what` reads like "speech model 43%" — the number, if this is
            // the one download that carries one, is the only part worth a
            // second field for; the rest is already the sentence above.
            let percent = what.split(separator: " ").last.flatMap { token -> Int? in
                token.hasSuffix("%") ? Int(token.dropLast()) : nil
            }
            // Only for a download that holds dictation up. This row says
            // whether you can speak yet, and a background fetch does not
            // change that answer.
            if blocking { permissions.model.speechModel = .preparing(percent: percent) }
        case .loading:
            setLabel("Loading speech model…")
            if ownsDownloadPill {
                updateProgress("Loading speech model…", token: dictationProgressToken)
            }
            transcriberLabelToken = labelToken
            permissions.model.speechModel = .preparing(percent: nil)
        case .failed(let message):
            setLabel("Model error: \(message)")
            transcriberLabelToken = labelToken
            // The pill is left to the dictation. `.loading` is the same wait
            // continuing, so it says so; a failure is the wait ending, and the
            // run waiting on the model gets it as a thrown error whose catch
            // already hides the pill and puts up the alert. Two endings on
            // screen for one failure is worse than one.
            // Not surfaced as "preparing" forever: the permissions window
            // isn't the place a transcription failure gets diagnosed, and a
            // stuck "downloading" badge there would outlive the one place
            // that does explain it — this label, and the log.
            permissions.model.speechModel = .ready
        case .ready, .idle:
            if transcriberLabelToken == labelToken { setLabel(nil) }
            transcriberLabelToken = nil
            // The dictation that was waiting on the model gets its pill back,
            // unless something else has taken it in the meantime — that job is
            // still working, and it is the one holding the live token.
            if ownsDownloadPill {
                updateProgress("Transcribing…", token: dictationProgressToken)
            }
            pillDownloadRun = nil
            permissions.model.speechModel = .ready
        }
    }

    // MARK: - Menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Self.idleParrot

        let menu = NSMenu()

        statusInfoItem = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
        statusInfoItem.isEnabled = false
        menu.addItem(statusInfoItem)

        // Under the state it qualifies: which microphone the next press will
        // listen through. Worth a row because the answer is chosen elsewhere —
        // a headset connects and silently becomes the input for everything.
        inputDeviceItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        inputDeviceItem.isEnabled = false
        menu.addItem(inputDeviceItem)

        // Above the separator, so it reads as part of the app's state rather
        // than as one more thing you can do. Hidden until there is something
        // to say — a notice at launch is missed, and a setting that quietly
        // stopped working stays wrong until someone is told.
        configProblemsItem = NSMenuItem(
            title: "",
            action: #selector(showConfigProblems),
            keyEquivalent: ""
        )
        configProblemsItem.target = self
        configProblemsItem.isHidden = true
        menu.addItem(configProblemsItem)

        // Beside the problem it answers. A model with no key is reported by the
        // row above and fixed by this one, so the reading and the remedy are
        // one line apart.
        addKeyItem = NSMenuItem(title: "", action: #selector(addMissingKeys), keyEquivalent: "")
        addKeyItem.target = self
        addKeyItem.isHidden = true
        menu.addItem(addKeyItem)

        updateItem = NSMenuItem(title: "", action: #selector(showUpdate), keyEquivalent: "")
        updateItem.target = self
        updateItem.isHidden = true
        menu.addItem(updateItem)

        menu.addItem(.separator())

        let revealItem = NSMenuItem(
            title: "Open Recordings Folder",
            action: #selector(openRecordingsFolder),
            keyEquivalent: ""
        )
        revealItem.target = self
        menu.addItem(revealItem)

        menu.addItem(.separator())

        // One row for the two doors you configure this app by: the config file,
        // and the folder it sits in. A submenu rather than two lines
        // because they are the same errand, and this menu is mostly state —
        // every row spent on a door is a row not spent saying what is happening.
        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let settingsMenu = NSMenu()

        // Keeps ⌘, — the shortcut belongs to the thing it opens, not to the
        // row that only unfolds.
        let editConfigItem = NSMenuItem(
            title: "Edit Config…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        editConfigItem.target = self
        settingsMenu.addItem(editConfigItem)

        let folderItem = NSMenuItem(
            title: "Open Config Folder",
            action: #selector(openConfigFolder),
            keyEquivalent: ""
        )
        folderItem.target = self
        settingsMenu.addItem(folderItem)

        settingsItem.submenu = settingsMenu
        menu.addItem(settingsItem)

        permissionsItem = NSMenuItem(
            title: "Permissions…",
            action: #selector(openPermissions),
            keyEquivalent: ""
        )
        permissionsItem.target = self
        menu.addItem(permissionsItem)

        menu.addItem(.separator())

        let bugReportItem = NSMenuItem(
            title: "Report a Bug…",
            action: #selector(reportBug),
            keyEquivalent: ""
        )
        bugReportItem.target = self
        menu.addItem(bugReportItem)

        let aboutItem = NSMenuItem(
            title: "About \(AppVariant.displayName)",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(
            title: "Quit \(AppVariant.displayName)",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        // Submenus too: "Edit Config…" is a settings row by any name the system
        // recognises, and it earns the same gear if nobody says otherwise.
        for item in menu.items {
            Self.hideAutomaticImage(item)
            for child in item.submenu?.items ?? [] { Self.hideAutomaticImage(child) }
        }

        menu.delegate = self
        statusItem.menu = menu
    }

    private func updateUI() {
        let recording = recorder.isRecording

        // Only when it actually changes. updateUI runs on a 0.1s timer while
        // recording, to redraw the elapsed clock, and the bird is the one thing
        // in here that cannot change between two ticks of the same state.
        //
        // Swapping the whole image rather than tinting one. `contentTintColor`
        // is the obvious way to turn a menu bar glyph red and it does not work:
        // set it on a status button and AppKit stops treating the image as a
        // template at all and draws its own pixels, which for a template is
        // solid black. So the colour is baked into a second file and the button
        // is handed whichever bird the state calls for.
        if shownRecording != recording {
            shownRecording = recording
            statusItem.button?.image = recording ? Self.recordingParrot : Self.idleParrot
        }

        let shortcut = hotKeys.binding?.displayName
            ?? KeyCodes.displayString(key: config.hotkey.key, modifiers: config.hotkey.modifiers)
        permissions.model.hotkeyRegistered = hotKeys.binding != nil
        if let bound = hotKeys.binding?.displayName {
            permissions.model.hotkeyDisplay = bound
        }

        if let transcriptionLabel {
            statusInfoItem.title = transcriptionLabel
        } else if let hotkeyError {
            statusInfoItem.title = "⚠︎ \(hotkeyError)"
        } else if recording {
            let elapsed = Int(pill.model.elapsed)
            statusInfoItem.title = String(format: "Recording  %d:%02d", elapsed / 60, elapsed % 60)
        } else if let standingCaptureProblem {
            // Under the live clock, so it never covers a recording in progress,
            // and over "Idle", which is the row it contradicts: a hotkey that
            // captures nothing looks idle from here.
            statusInfoItem.title = "⚠︎ \(standingCaptureProblem)"
        } else {
            statusInfoItem.title = "Idle  ·  \(shortcut)"
        }

        addKeyItem.isHidden = keylessModels.isEmpty
        addKeyItem.title = keylessModels.count == 1
            ? "Add API Key for \(keylessModels[0])…"
            : "Add API Keys…"

        configProblemsItem.isHidden = configProblems.isEmpty
        configProblemsItem.title = configProblems.count == 1
            ? "⚠︎ 1 setting in config.yaml does nothing"
            : "⚠︎ \(configProblems.count) settings in config.yaml do nothing"

        if updateCheckInFlight {
            updateItem.isHidden = false
            updateItem.title = "Checking for Updates…"
            updateItem.isEnabled = false
        } else if let release = updateAvailable {
            updateItem.isHidden = false
            updateItem.title = "↑ ParrotFlow \(release.version) is available"
            updateItem.action = #selector(showUpdate)
            updateItem.isEnabled = true
        } else if config.updates.afterDays >= 0 {
            updateItem.isHidden = false
            updateItem.title = "Check for Updates"
            updateItem.action = #selector(checkForUpdateNow)
            updateItem.isEnabled = true
        } else {
            updateItem.isHidden = true
        }
    }

    /// Names them, and offers the file they are in.
    ///
    /// An alert rather than a notice: these outlive a notice by definition —
    /// they are still true after a restart — and each one already carries the
    /// replacement to write, which is more text than a notice can hold.
    @objc private func showConfigProblems() {
        let problems = configProblems
        guard !problems.isEmpty else { return }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = problems.count == 1
            ? "A setting in your config no longer does anything"
            : "\(problems.count) settings in your config no longer do anything"
        alert.informativeText = problems.map { "• \($0)" }.joined(separator: "\n\n")
            + "\n\nThis usually follows an upgrade: a setting was replaced by "
            + "another way of writing the same thing. Until you change it, that "
            + "part of your config is ignored."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Edit config.yaml")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            try? ConfigStore.createIfMissing()
            NSWorkspace.shared.open(ConfigStore.fileURL)
        }
    }

    // MARK: - Menu actions

    /// `--preview-panel` shows the correction panel with sample text, so its
    /// layout can be iterated on without dictating into it every time.
    func previewCorrectionPanel() {
        correctionPanel.onSave = { rules, text in
            Log.write("preview: \(rules.map { "\($0.heard)->\($0.corrected)" }.joined(separator: ", ")) | \(text)")
            NSApp.terminate(nil)
        }
        correctionPanel.onCancel = { NSApp.terminate(nil) }
        correctionPanel.show(
            selection: CommandLine.arguments.contains("--empty")
                ? ""
                : "I work with Tasmine and Meek on Versal and Subabase."
        )
    }

    @objc private func openRecordingsFolder() {
        let dir = config.resolvedOutputDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let last = lastRecording?.url, FileManager.default.fileExists(atPath: last.path) {
            NSWorkspace.shared.activateFileViewerSelecting([last])
        } else {
            NSWorkspace.shared.open(dir)
        }
    }

    /// Settings are the config file — there is no second copy of them in a
    /// window to drift out of sync with it.
    @objc private func openSettings() {
        try? ConfigStore.createIfMissing()
        Self.openInEditor(ConfigStore.fileURL)
    }

    /// The config folder, not the transforms folder inside it.
    ///
    /// Everything you own lives here: `config.yaml`, `vocabulary.yaml`, the
    /// `transforms/` folder and the `voice/` recordings. One door reaches all
    /// of them, where the old row reached one subfolder and left the rest with
    /// no way in from the menu.
    ///
    /// Created if it is not there, because an empty folder is an answer ("this
    /// is where they go") and a window that never opened is not.
    @objc private func openConfigFolder() {
        let dir = ConfigStore.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Self.openInEditor(dir)
    }

    /// VS Code if it is here, and whatever the system would have used if it is
    /// not — a config file and a folder of scripts are both things you came to
    /// edit, and an editor that opens the folder as a project is a better
    /// answer than TextEdit and a Finder window.
    ///
    /// Two chances to fall back, because there are two ways to not have it.
    /// Launch Services can name no application at all — VS Code was never
    /// installed — and it can name one that no longer launches, which is what
    /// a bundle moved to the Trash looks like from here. The second is why the
    /// fallback is in the completion handler rather than only in the `guard`:
    /// the error arrives after the call succeeds.
    ///
    /// What the fallback must not do is hand the file back to the application
    /// that just failed, which is exactly what the system would say to do on a
    /// machine where the trashed VS Code is still the handler for YAML. See
    /// `openWithSystem`.
    private static func openInEditor(_ url: URL) {
        guard let editor = visualStudioCode else {
            openWithSystem(url)
            return
        }
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: editor,
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, error in
            guard let error else { return }
            Log.write("menu: VS Code did not open \(url.path) (\(error.localizedDescription));"
                + " using the default application")
            DispatchQueue.main.async { openWithSystem(url, avoiding: editor) }
        }
    }

    /// Hand the file to whatever the system would have opened it with, with
    /// two ways of not disappearing quietly.
    ///
    /// `avoiding` is the application that just failed. Someone who has VS Code
    /// installed has very likely also made it the handler for YAML, so the
    /// system's answer to "who opens config.yaml" can be the same bundle that
    /// could not launch a moment ago — and asking it twice fails twice. When
    /// that is what the system says, stop asking and show the file in Finder,
    /// which needs nobody's help to work.
    ///
    /// The second way is the ordinary one: the handler exists, is not the
    /// failed editor, and still does not open. `open` says so by returning
    /// false, and a menu item that does nothing at all is worth a line in the
    /// log — otherwise the only report of the failure is a window that never
    /// appeared.
    private static func openWithSystem(_ url: URL, avoiding failed: URL? = nil) {
        let handler = NSWorkspace.shared.urlForApplication(toOpen: url)
        if let failed, handler?.standardizedFileURL == failed.standardizedFileURL {
            Log.write("menu: the default application for \(url.lastPathComponent) is the one that"
                + " just failed; showing it in Finder instead")
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        if !NSWorkspace.shared.open(url) {
            Log.write("menu: nothing would open \(url.path); showing it in Finder instead")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// Where VS Code is, asked of Launch Services rather than assumed to be in
    /// /Applications — it is also a valid install in ~/Applications, and on a
    /// machine that has both, this is the copy the person actually uses.
    ///
    /// Looked up each time so that installing VS Code does not require
    /// restarting this app to be noticed.
    private static var visualStudioCode: URL? {
        for identifier in ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"] {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
                return url
            }
        }
        return nil
    }

    @objc private func openPermissions() {
        permissions.show(.revisiting)
    }

    /// The app in front is read before the window opens, because opening it
    /// makes ParrotFlow the app in front.
    @objc private func reportBug() {
        let front = NSWorkspace.shared.frontmostApplication
        let name = front?.bundleIdentifier == Bundle.main.bundleIdentifier
            ? nil : front?.localizedName
        bugReport.show(app: name)
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: AppVariant.displayName,
            .applicationVersion: AppVariant.version,
            .credits: AppVariant.repositoryLink,
        ])
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    /// Stops the system from decorating a menu item it recognises — the gear it
    /// puts beside "Settings…" — with a glyph this menu never asked for. One
    /// icon among plain rows reads as a mistake rather than as emphasis.
    ///
    /// Set by name because `preferredImageVisibility` arrived in the macOS 27
    /// SDK and this builds against 26. `2` is `.hidden`; the check makes it a
    /// no-op on any system that predates the property.
    /// The bird, flat, at the size the menu bar draws glyphs.
    ///
    /// A bird for the menu bar, by name.
    ///
    /// Built by scripts/make-icons.py from the same Resources/parrot.svg the app
    /// icon comes from, at @1x/@2x/@3x — `NSImage(named:)` picks the rung that
    /// matches the display, and reads the `Template` suffix to decide whether
    /// the file is a mask to paint the menu bar's own colour through or an image
    /// to draw as-drawn. That is why nothing here touches `isTemplate`: the file
    /// name is the single place it is decided, and code that also sets it is one
    /// more place for the two to disagree.
    ///
    /// Falls back to a microphone if a file is missing, which happens exactly
    /// once — running the binary outside its bundle. A status item with no image
    /// is a status item you cannot click, and losing the menu is a worse way to
    /// find out than an unfamiliar glyph.
    private static func menuBarParrot(_ name: String) -> NSImage? {
        guard let image = NSImage(named: name) else {
            let fallback = NSImage(systemSymbolName: "mic", accessibilityDescription: nil)
            fallback?.isTemplate = true
            return fallback
        }
        image.accessibilityDescription = AppVariant.displayName
        return image
    }

    private static let idleParrot = menuBarParrot(AppVariant.menuBarIdleImage)
    private static let recordingParrot = menuBarParrot(AppVariant.menuBarRecordingImage)

    private static func hideAutomaticImage(_ item: NSMenuItem) {
        guard item.responds(to: Selector(("setPreferredImageVisibility:"))) else { return }
        item.setValue(2, forKey: "preferredImageVisibility")
    }

    private func presentAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - Menu delegate

extension AppDelegate: NSMenuDelegate {

    /// Granting permissions is a chore, not a feature. The item is there while
    /// one of them still needs doing and gone once they are done — checked as
    /// the menu opens, because the answer changes in System Settings rather
    /// than in this app.
    func menuNeedsUpdate(_ menu: NSMenu) {
        permissionsItem.isHidden = !hasPermissionProblem

        // Here rather than in `updateUI`, which runs on a 0.1s timer while
        // recording: the device is picked in System Settings, so the moment the
        // menu opens is both the first time the answer can have changed and the
        // only time anyone can read it.
        let device = Recorder.inputDeviceName
        inputDeviceItem.isHidden = device == nil
        inputDeviceItem.title = device.map { "Microphone  ·  \($0)" } ?? ""
    }

    private var hasPermissionProblem: Bool {
        if Permissions.microphone != .granted { return true }
        // Accessibility is only a problem when the transcript is meant to be
        // typed. In clipboard mode nothing needs it, and an item nagging about
        // a permission the configuration never uses is noise.
        return config.transcription.insertMode == .paste && Permissions.accessibility != .granted
    }
}
