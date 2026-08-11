import AppKit
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var config = Config()
    private var configWatcher: FileWatcher?
    private var vocabularyWatcher: FileWatcher?
    private var transformWatchers: [FileWatcher] = []

    private let hotKeys = HotKeyManager()
    private let recorder = Recorder()
    private let pill = PillHUD()
    private let permissions = PermissionsWindowController()

    private var statusItem: NSStatusItem!
    private var statusInfoItem: NSMenuItem!
    private var inputDeviceItem: NSMenuItem!
    private var permissionsItem: NSMenuItem!

    /// The recording state the menu bar parrot was last tinted for.
    private var shownRecording: Bool?

    /// Shown only while `config.problems()` has something in it.
    private var configProblemsItem: NSMenuItem!

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
    /// `problems()` re-resolves and re-validates every pipeline for every
    /// configured language, and `updateUI` runs on a 0.1s timer for as long as
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
    /// Which microphone the engine opened for this recording, and whether it
    /// is on Bluetooth. Read when recording starts and frozen onto the `Press`
    /// when the clip is handed to the decoder, so the microphone notice names
    /// the device that recorded the words rather than whatever is default a
    /// second later. One slot is enough: only one recording runs at a time,
    /// and it is taken the moment that recording stops.
    private var micAtPress: (name: String, isBluetooth: Bool)?
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
        /// The microphone this dictation was recorded on, and whether it was on
        /// Bluetooth. Frozen for the same reason as everything above it: the
        /// default input can change while the decoder runs — a headset
        /// disconnects, somebody picks another device in System Settings — and
        /// the notice is about the microphone that recorded these words. See
        /// `micAtPress`.
        let mic: String?
        let micIsBluetooth: Bool
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
    /// The keyboard, for as long as the offer is up. See `OfferKeys`.
    private let offerKeys = OfferKeys()
    /// The chips the offer on screen is showing, and so the letters it claims.
    ///
    /// Held rather than read from the config when the keys are armed, because
    /// the keys can be armed after the chips were drawn — see
    /// `watchTheOfferKeys`. A config reloaded in between must not leave a
    /// letter claimed for a chip that is not on screen.
    private var offerOnScreen: [OfferedCommand]?
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
    /// True while the pointer is resting on the offer.
    ///
    /// The clock is stopped then, and `offerUntil` becomes a date that never
    /// arrives — which is also why the deadline above is not armed with it:
    /// `asyncAfter` at that distance is an overflow rather than a long wait.
    /// See `holdTheOffer`.
    private var offerHeld = false

    /// How long the offer stays up.
    ///
    /// Long enough to read the sentence, decide it is wrong and reach for a
    /// key, which three seconds was not. It can afford to be this long because
    /// it does not sit there at full strength: it thins out the whole way — see
    /// `PillHUD.offer` — and the pointer stops that clock and gives the nine
    /// seconds back in full. A fade this generous would be clutter after every
    /// dictation if reading it did not put it back.
    ///
    /// Not private: `--panels offer` previews the offer for as long as the app
    /// gives it, and a preview with a number of its own is a preview of
    /// something else.
    static let offerSeconds: TimeInterval = 9

    /// What the offer offers: Correct, then every transform that asked for a
    /// place on it with `offer: true`.
    ///
    /// Correct is first and is not a transform. It is the one command that is
    /// about the words rather than about rewriting them, it needs no model, and
    /// it cannot fail.
    ///
    /// Read fresh each time rather than stored, so a config reloaded between
    /// two dictations changes what the next offer says.
    private var offerCommands: [OfferedCommand] {
        [OfferedCommand(title: "Correct", key: "C")]
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

        recorder.warmUp()
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
                presentAlert(
                    title: "Could not read config.yaml",
                    message: "\(error.localizedDescription)\n\nFalling back to the previous settings."
                )
            }
            return
        }
        applyConfig()
        // After the load, not with the other watchers: a transform can be
        // renamed, removed or pointed at a different file, so which files are
        // worth watching is only known once the config has been read.
        watchTransformFiles()
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

        hotkeyError = nil
        hotKeys.onPress = { [weak self] in self?.handleHotKeyPress() }
        hotKeys.onRelease = { [weak self] in self?.handleHotKeyRelease() }
        do {
            try hotKeys.register(key: config.hotkey.key, modifiers: config.hotkey.modifiers)
        } catch {
            hotkeyError = error.localizedDescription
            Log.write("hotkey registration FAILED: \(error.localizedDescription)")
        }

        startKeepWarm()
        startUpdateChecks()
        updateUI()
    }

    // MARK: - Updates

    /// Once shortly after launch, then daily.
    ///
    /// Restarted on every config load, since `after_days` can turn the whole
    /// thing off — and a setting that only takes effect after a restart is one
    /// that will be reported as not working.
    private func startUpdateChecks() {
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
        let timer = Timer(timeInterval: 86_400, repeats: true) { [weak self] _ in
            self?.checkForUpdate()
        }
        RunLoop.main.add(timer, forMode: .common)
        updatesTimer = timer
    }

    private func checkForUpdate() {
        let afterDays = config.updates.afterDays
        guard afterDays >= 0 else { return }

        Task<Void, Never> {
            let latest = try? await Updates.latest()
            await MainActor.run { [weak self] in
                guard let self else { return }
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
                case .waiting(let release, let days):
                    self.updateAvailable = nil
                    Log.write("updates: holding \(release.version) for \(days) more day(s)")
                default:
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
        beginProgress("Downloading ParrotFlow \(release.version)…")
        Task<Void, Never> {
            do {
                let app = try await UpdateInstaller.prepare(release)
                try await MainActor.run {
                    self.endProgress()
                    try UpdateInstaller.swapAndRelaunch(newApp: app)
                    NSApp.terminate(nil)
                }
            } catch {
                await MainActor.run {
                    self.endProgress()
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

    /// The release notes, and the three answers to them.
    ///
    /// No download button yet: taking the update in place means replacing a
    /// running bundle, which is a separate piece of work and a worse thing to
    /// get wrong than a missing button. Until then the command is the same one
    /// that installed the app, and it is put on the clipboard rather than
    /// printed for retyping.
    @objc private func showUpdate() {
        guard let release = updateAvailable else { return }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "ParrotFlow \(release.version) is available"
        alert.informativeText = (release.notes.isEmpty ? "No release notes." : release.notes)
            + "\n\nYou are running \(Updates.current ?? "an unknown version")."
        alert.alertStyle = .informational
        // Installing in place is only offered when it can actually be done.
        // An app in a read-only location, or one someone put somewhere odd,
        // still gets the command it was installed with rather than a button
        // that fails after downloading 3 MB.
        let canInstall = UpdateInstaller.canInstallInPlace
        if canInstall { alert.addButton(withTitle: "Update and restart") }
        alert.addButton(withTitle: "Copy the upgrade command")
        alert.addButton(withTitle: "Skip this version")
        alert.addButton(withTitle: "Later")

        var answer = alert.runModal()
        if canInstall, answer == .alertFirstButtonReturn {
            install(release)
            return
        }
        // With the install button present every other answer sits one place
        // further along, so it is shifted back rather than each case being
        // written twice.
        if canInstall { answer = NSApplication.ModalResponse(rawValue: answer.rawValue - 1) }

        switch answer {
        case .alertFirstButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(Updates.installCommand, forType: .string)
            flash("Upgrade command copied — paste it into a terminal", tone: .done)
        case .alertSecondButtonReturn:
            Updates.skip(release.version)
            updateAvailable = nil
            updateUI()
        default:
            Updates.remindLater()
            updateAvailable = nil
            updateUI()
        }
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

    private func handleHotKeyPress() {
        // Grab the selection now: by the time a transcript exists, a terminal
        // will very likely have dropped it. Timed out hard inside snapshot(),
        // because this is the main thread and recording must start regardless.
        let snapshotStart = Date()
        selectionAtPress = SelectionReader.snapshot()
        focusAtPress = selectionAtPress ?? SelectionReader.focusSnapshot()
        let front = Self.appInFront()
        appAtPress = front?.app
        // The icon is a promise that the words are going to land in that app,
        // so it is only made when they will. Off the element the snapshot above
        // already fetched — the answer costs two more attribute reads on a
        // reference we are holding, not another walk of the tree.
        destinationAtPress = Destination.at(app: front?.app, focus: focusAtPress?.element)
        appIconAtPress = destinationAtPress.acceptsText ? front?.icon : nil
        Log.write("destination: \(destinationAtPress.described)")
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
        if !recorder.isRecording {
            anchorAtPress = nil
            pressRun += 1
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
        if Context.isConfigured(in: config) {
            let app = front?.app
            let element = focusAtPress?.element
            DispatchQueue.global(qos: .userInitiated).async {
                Context.capturePress(app: app, element: element)
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
        switch CaretAnchor.read(at: focusAtPress?.element) {
        case .found(let found):
            anchorAtPress = found
        case .missed(let why):
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
            // Asked here, where the engine has just opened the device, and not
            // when the transcript comes back. One lookup, so the name and the
            // transport are the same device's — see `Recorder.inputDevice`.
            micAtPress = Recorder.inputDevice
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

        if config.feedback.sound { NSSound(named: "Tink")?.play() }
        if config.feedback.overlay {
            pill.aim(at: anchorAtPress)
            pill.recording(icon: appIconAtPress)
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
    private func cancelDictation() {
        let recording = recorder.isRecording
        // A run is in flight when one has been started and nothing has retired
        // it yet. `transcriptionRun` is bumped per dictation and already carries
        // through the whole chain, so it is the identity to cancel against.
        let transcribing = transcriptionLabel != nil
        guard recording || transcribing else { return }

        if recording {
            // The clip on disk is left alone. It cost nothing to write, the
            // recordings folder is where you go to find out what the app heard,
            // and deleting the evidence of the thing you just cancelled is the
            // opposite of useful when the reason you cancelled it was that
            // something sounded wrong.
            _ = recorder.stop(config: config)
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
            endProgress()
        }

        stopWatchingForEscape()
        if config.feedback.sound { NSSound(named: "Pop")?.play() }
        Log.write("escape: cancelled while \(recording ? "recording" : "transcribing")")
        flash(recording ? "Recording cancelled" : "Transcription cancelled", tone: .caution)
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
        if config.feedback.sound { NSSound(named: "Pop")?.play() }

        // Transcription takes the watch over from here — it is the other half
        // of the dictation Escape can still stop. With transcription off there
        // is nothing left to cancel, so it ends now.
        if !config.transcription.enabled { stopWatchingForEscapeIfIdle() }

        if let recording {
            lastRecording = recording
            Log.write(String(format: "wrote %@ (%.2fs)", recording.url.lastPathComponent, recording.duration))
            if config.transcription.enabled {
                transcribe(recording)
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
    private static func appInFront() -> (app: Pipeline.App, icon: NSImage?)? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        let app = Pipeline.App(
            name: front.localizedName ?? "", bundleID: front.bundleIdentifier ?? ""
        )
        // Both empty is not an app you could write a condition against, and
        // saying so is what makes `app:` fail closed instead of matching "  ".
        guard !app.searchable.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return (app, front.icon)
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
        beginProgress("Transcribing…")

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
            run: pressRun, element: focus?.element, owner: focus?.owner,
            mic: micAtPress?.name, micIsBluetooth: micAtPress?.isBluetooth ?? false
        )
        Task { [weak self] in
            do {
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
                        url: recording.url, config: config, app: app,
                        progress: { label in
                            Task { @MainActor [weak self] in
                                // Still this dictation, and still one that has
                                // something on screen to replace.
                                guard let self, self.transcriptionRun == run,
                                      self.transcriptionLabel != nil else { return }
                                self.beginProgress(label)
                            }
                        }
                    ) ?? ""
                    Trace.current?.recordFinal(text)
                    return text
                }
                await MainActor.run {
                    guard let self else { return }
                    // Only if the screen is still ours. Push-to-talk does not
                    // wait, so a second press while this one was in flight has
                    // already put its own "Transcribing…" up, and clearing it
                    // here would leave that dictation running behind a blank
                    // screen — the bug this is meant to fix, one press later.
                    // The text is delivered either way: `destination` was
                    // captured at the press for exactly that reason.
                    if self.transcriptionRun == run { self.endProgress() }
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
                    if self.transcriptionRun == run { self.endProgress() }
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

    private func llmConfig() -> LocalLLM.Config {
        LocalLLM.Config(
            endpoint: config.llm.endpoint,
            model: config.llm.model,
            timeout: config.llm.timeoutSeconds,
            keepLoaded: config.llm.keepLoaded
        )
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
        guard config.llm.enabled, config.llm.keepLoaded else { return }

        let llm = llmConfig()
        Task.detached(priority: .background) {
            let started = Date()
            let loaded = await LocalLLM.warmUp(config: llm)
            let elapsed = Date().timeIntervalSince(started)
            Log.write(
                loaded
                    ? String(format: "llm: %@ loaded and pinned in %.1fs", llm.model, elapsed)
                    : "llm: could not preload \(llm.model) — is Ollama running?"
            )
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
        guard config.llm.enabled, config.llm.keepLoaded else { return }

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

        let llm = llmConfig()
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

    private func handleVoiceCommand(_ command: String) {
        let catalogue = Catalogue(transforms: config.transforms)

        // Deterministic phrases first: no model needed, and they work when
        // Ollama is not running. This also covers the wake phrase said on its
        // own, which means the panel rather than anything the router could pick.
        if let local = VoiceCommand.local(from: command) {
            apply(local, command: command)
            return
        }
        if let capability = Router.local(instruction: command, catalogue: catalogue) {
            Log.write("router: \"\(command)\" named \(capability.name) outright")
            run(capability, instruction: command)
            return
        }

        guard config.llm.enabled else {
            flash("Didn't understand \"\(command)\" — enable llm in config for free-form commands", tone: .caution)
            return
        }

        beginProgress("Thinking…")
        let llmConfig = llmConfig()
        let freeForm = config.freeForm

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
                        self.run(capability, instruction: command)
                    case .anything:
                        // An edit with no prompt behind it. The instruction is
                        // the whole specification, so it goes through unsplit,
                        // exactly as it would to a prompt of your own.
                        Log.write("router: \"\(command)\" → \(FreeForm.name)")
                        self.runTransform(FreeForm.prompt(for: command).asTransform, instruction: command)
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
                        self.endProgress()
                        Log.write("router: nothing matched \"\(command)\"")
                        self.flash(freeForm
                            ? "Not something to change in the text: \"\(command)\""
                            : "No prompt for \"\(command)\"", tone: .caution)
                    }
                }
            } catch {
                await MainActor.run {
                    Log.write("routing failed: \(error.localizedDescription)")
                    self?.endProgress()
                    self?.flash(error.localizedDescription, tone: .failure)
                }
            }
        }
    }

    /// Runs whatever the router picked.
    private func run(_ capability: Capability, instruction: String) {
        switch capability {
        case .action(.vocabulary):
            endProgress()
            beginCorrection()
        case .action(.spelling):
            interpretSpelling(instruction)
        case .transform(let transform):
            runTransform(transform, instruction: instruction)
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
                prompt: prompt, instruction: instruction, text: text, config: llmConfig()
            )
        case .replace:
            return Replacements.applyExact(to: text, rules: transform.rules)
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
    private func interpretSpelling(_ command: String) {
        guard config.llm.enabled else {
            endProgress()
            flash("Didn't understand \"\(command)\" — enable llm in config for free-form commands", tone: .caution)
            return
        }

        beginProgress("Thinking…")
        let llmConfig = llmConfig()
        let context = lastTranscript
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
                await MainActor.run { self?.apply(result, command: command) }
            } catch {
                await MainActor.run {
                    Log.write("command interpretation failed: \(error.localizedDescription)")
                    self?.endProgress()
                    self?.flash(error.localizedDescription, tone: .failure)
                }
            }
        }
    }

    // MARK: - Transforms

    /// Runs a prompt over the selection, or over the last dictation.
    ///
    /// The selection is taken from the snapshot made when the hotkey went down,
    /// not read now — by the time this runs, our own panel may hold focus, and
    /// reading then returns nothing or something of ours.
    private func runTransform(_ transform: Config.Transform, instruction: String) {
        // Never the clipboard. `read()` falls back to it for the correction
        // panel, where you see the words before anything happens and can
        // cancel; a transform gets no such look. The clipboard holds whatever
        // was last copied — from another app, or an hour ago — and taking it
        // as the target means rewriting text the speaker never pointed at.
        // That is exactly what happened: "convert numbers to digits" ran over
        // a comment line copied minutes earlier, while the sentence the
        // speaker meant sat in the last transcript, unused.
        let selection = selectionAtPress ?? (
            Permissions.accessibility == .granted
                ? SelectionReader.read(fallbackTo: false)
                : nil
        )
        selectionAtPress = nil

        // Falling back to the last dictation is what makes "hey parrot, fix the
        // grammar" work immediately after speaking, with nothing selected.
        let target = selection?.text ?? lastTranscript ?? ""
        guard !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            endProgress()
            Log.write("transform: nothing selected and nothing dictated yet")
            flash("Select some text first, or dictate something", tone: .caution)
            return
        }

        // The text itself, not just its length: a transform that worked on the
        // wrong thing is otherwise indistinguishable in the log from one that
        // worked on the right thing badly.
        Log.write("transform: \(transform.name) over \(selection == nil ? "the last dictation" : "the selection") — \"\(target.prefix(80))\"")
        beginProgress(transform.progressLabel)

        Task { [weak self] in
            do {
                guard let result = try await self?.perform(
                    transform, instruction: instruction, on: target
                ) else { return }
                await MainActor.run {
                    self?.finishTransform(
                        transform: transform, selection: selection,
                        before: target, after: result
                    )
                }
            } catch {
                await MainActor.run {
                    Log.write("transform failed: \(error.localizedDescription)")
                    self?.endProgress()
                    self?.flash(error.localizedDescription, tone: .failure)
                }
            }
        }
    }

    private func finishTransform(
        transform: Config.Transform,
        selection: SelectionReader.Selection?,
        before: String,
        after: String
    ) {
        endProgress()

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

        guard transform.confirm else {
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

        guard applied > 0, let change = Surface.minimalSpan(from: surface.content, to: updated) else {
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

    /// The toast after a substitution, and the phrase that takes it back.
    ///
    /// Said every time rather than only when something looks wrong, because the
    /// moment you can tell it went wrong is the moment you are looking at the
    /// text and not at the menu bar. It has to already be on screen.
    private func applied(_ what: String) {
        if config.feedback.sound { NSSound(named: "Glass")?.play() }
        flash("\(what) applied\(undoHint)", tone: .done)
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
            if config.feedback.sound { NSSound(named: "Glass")?.play() }
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

            switch TextInserter.insert(text, mode: config.transcription.insertMode) {
            case .pasted, .copied:
                if config.feedback.sound { NSSound(named: "Glass")?.play() }
                flash("\(transform.name) applied", tone: .done)
            case .clipboardOnly:
                flash("\(transform.name) copied — grant Accessibility to paste", tone: .caution)
            }
        }
        lastTranscript = text
    }

    private func apply(_ command: VoiceCommand, command spoken: String) {
        // Whatever happens next replaces it: a panel, or a flash of its own.
        endProgress()

        switch command {
        case .openCorrectionPanel:
            beginCorrection()
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
    private func showCorrectOffer(for press: Press, landing: Correction.Landing) {
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
        micNotice.showIfNeeded(mic: press.mic, isBluetooth: press.micIsBluetooth)

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

        offerUntil = Date().addingTimeInterval(Self.offerSeconds)
        // A new offer is never born held, whatever the last one ended as.
        offerHeld = false
        offerPressRun = press.run
        // This dictation's own words and its own field, frozen with the offer.
        offeredCorrection = (press.run, Correction(
            original: text, element: press.element, owner: press.owner, landing: landing
        ))
        let commands = offerCommands
        pill.offer(commands, for: Self.offerSeconds)
        // The list is captured, not read again in the closure: a config
        // reloaded while the offer is up would otherwise renumber the chips
        // under the pointer, and the click would run whatever took the slot.
        pill.model.onPick = { [weak self] index in
            guard let self, self.offerIsUp, commands.indices.contains(index) else { return }
            // Index 0 is Correct, which is not a transform and cannot be one:
            // a config free to name a transform "Correct" must not be able to
            // take that slot over.
            self.runOfferedCommand(index == 0 ? nil : commands[index].title)
        }
        // The highlight is the pointer's mark and does not outlive it. Leaving
        // the pill gives it up, so a chip is never lit for a command that is
        // not about to happen. Cleared here rather than in the view because
        // this is where the rest of the leaving behaviour hangs.
        pill.model.onHover = { [weak self] inside in
            guard let self else { return }
            if !inside { self.pill.model.selected = nil }
            self.holdTheOffer(inside)
        }

        offerOnScreen = commands
        watchTheOfferKeys()

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
        if case .field = landing, let pane, let element = press.element {
            findWhereTheWordsLanded(comparedWith: pane, in: element, for: press.run)
        }
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
        // for whatever is left of its nine seconds.
        guard !recorder.isRecording, runsInFlight <= 0 else {
            Log.write("offer keys: a dictation is still running; the keys wait for it")
            return
        }
        let letters = Set(commands.map(\.key).filter { !$0.isEmpty })
        offerKeys.start(until: until, letters: letters) { [weak self] key in
            guard let self, self.offerIsUp else { return }
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
            case .dismiss:
                Log.write("offer: dismissed")
                self.endTheOffer()
                self.pill.hide()
            }
        }
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
    /// said so: the offer gets its nine seconds and runs out normally.
    private func offerDeadlinePassed() {
        guard offerHeld else { endTheOffer(); return }
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
    /// whole new nine seconds.
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
        offeredCorrection = nil
        offerOnScreen = nil
        offerKeysExpiry?.cancel()
        offerKeysExpiry = nil
        offerKeys.stop()
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
        beginProgress(transform.progressLabel)

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
                    clipboardWhenChosen: clipboardWhenChosen
                )
            } catch {
                // Fail open: the words are untouched, wherever they are. Losing
                // a rewrite costs a second attempt; losing the sentence costs
                // the sentence.
                Log.write("offer: \(transform.name) failed: \(error.localizedDescription)")
                self?.endProgress()
                self?.setLabel(error.localizedDescription, clearAfter: 7)
            }
        }
    }

    /// The model has answered. Write it back, or say why there is nothing to
    /// write.
    ///
    /// Every refusal here leaves the sentence exactly as it is — in the field or
    /// on the clipboard — and says so in the menu bar. The pill is not used: it
    /// sits over the words, and a notice there would cover the thing the message
    /// is about.
    private func finishOfferedTransform(
        _ transform: Config.Transform, over target: Correction, before: String, after: String,
        clipboardWhenChosen: Int
    ) {
        endProgress()

        let cleaned = after.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            Log.write("offer: \(transform.name) returned nothing")
            setLabel("\(transform.name) returned nothing", clearAfter: 7)
            return
        }
        // Saying so beats replacing text with itself and calling it done, which
        // looks identical to the prompt having silently failed.
        guard cleaned != before else {
            Log.write("offer: \(transform.name) changed nothing")
            setLabel("\(transform.name): nothing to change", clearAfter: 7)
            return
        }

        Log.write("offer: \(transform.name) rewrote the dictation")
        Log.write("    before: \(before)")
        Log.write("    after:  \(cleaned)")
        replace(
            target, with: cleaned, describedAs: transform.name,
            clipboardWhenChosen: clipboardWhenChosen
        )
    }

    /// This press's dictation is over, however it ended. Drops the pane it
    /// started with — nothing can want it again — and lets the sweep above
    /// reach anything that is somehow left.
    private func dictationEnded(_ run: Int) {
        screenAtPress.removeValue(forKey: run)
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
            noteRewritten(original, as: corrected)
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

        if config.transcription.insertMode == .paste, let aimed = target.element {
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
                    noteRewritten(original, as: corrected)
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
    /// The look and the write sit next to each other with nothing between them
    /// — no logging, no message — because there is nothing stronger to have.
    /// `NSPasteboard` offers no compare-and-write: `declareTypes(owner:)` names
    /// an owner for callbacks and stops no other process from writing. Any check
    /// is a look followed by a write, and the gap can only be made small. It is
    /// two calls here, and the messages are left to the caller so they cannot
    /// get in between.
    ///
    /// Returns false when it did not write.
    private func copyOverOurOwn(_ text: String, unlessChangedFrom change: Int) -> Bool {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == change else { return false }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return true
    }

    /// The last dictation now reads differently, so a command that works on it
    /// works on the new text rather than on the sentence it replaced.
    ///
    /// Only if this is still the sentence the app thinks it wrote last. A newer
    /// dictation has its own, and it is one slot.
    private func noteRewritten(_ original: String, as corrected: String) {
        guard lastTranscript?.trimmingCharacters(in: .whitespacesAndNewlines) == original
        else { return }
        lastTranscript = corrected
    }

    private func beginCorrection() {
        // Reading the selection needs Accessibility; the panel does not. Open
        // it either way — typing both sides still beats editing YAML by hand,
        // and a panel that silently refuses to appear reads as a broken app.
        let selection = selectionAtPress ?? (
            Permissions.accessibility == .granted ? SelectionReader.read() : nil
        )
        selectionAtPress = nil

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
    private func learn(_ rules: [(heard: String, corrected: String)]) -> Bool {
        for rule in rules {
            do {
                try ConfigWriter.addReplacement(heard: rule.heard, corrected: rule.corrected)
                Log.write("learned replacement: \(rule.heard) -> \(rule.corrected)")
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
        _ rules: [(heard: String, corrected: String)],
        correctedText: String,
        into target: Correction,
        clipboardWhenChosen: Int
    ) {
        guard learn(rules) else { return }
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
        _ rules: [(heard: String, corrected: String)],
        correctedText: String
    ) {
        guard learn(rules) else {
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

        if config.feedback.sound { NSSound(named: "Glass")?.play() }
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

    /// Show a message on screen, and in the menu bar for as long as it lasts.
    private func flash(_ message: String, tone: NoticeTone = .plain) {
        pill.notice(message, tone: tone)
        setLabel(message, clearAfter: 4)
    }

    /// A message that stays up until `endProgress()`, for work of no
    /// predictable length. "Thinking…" was a `flash`, so it timed out after
    /// 3.5s while a cold Ollama was still loading — leaving the rest of a 10s
    /// wait with nothing on screen at all.
    private func beginProgress(_ message: String) {
        pill.working(message)
        setLabel(message)
    }

    private func endProgress() {
        pill.hide()
        setLabel(nil)
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

        // Heard as a command, or nothing at all: no words are going to land,
        // so there is nothing to compare a pane against.
        if let command = commandAfterWakePhrase(trimmed) {
            Log.write("command heard: \"\(command)\"")
            dictationEnded(press.run)
            handleVoiceCommand(command)
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
        insertDictation(trimmed, to: destination, for: press)
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
        func giveUp(_ why: String, tone: NoticeTone = .caution) {
            endProgress()
            Log.write("inline: \(why); wrote the text as dictated")
            insertDictation(text, to: destination, for: press)
            pill.notice(why, tone: tone, duration: 7)
            setLabel(why, clearAfter: 7)
        }

        func run(_ transform: Config.Transform) {
            beginProgress(transform.progressLabel)
            Task { [weak self] in
                do {
                    guard let result = try await self?.perform(
                        transform, instruction: instruction, on: text
                    ) else { return }
                    await MainActor.run {
                        guard let self else { return }
                        self.endProgress()
                        let cleaned = result.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !cleaned.isEmpty else {
                            giveUp("\(transform.name) returned nothing", tone: .failure)
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
                        giveUp(error.localizedDescription, tone: .failure)
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
                    destination: destination, focus: focus, for: press
                )
            }
            return
        }

        guard config.llm.enabled else {
            giveUp("\"\(instruction)\" needs the local model — llm.enabled is false")
            return
        }

        beginProgress("Thinking…")
        let llm = llmConfig()
        let freeForm = config.freeForm
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
                            destination: destination, focus: focus, for: press
                        )
                    case .anything:
                        Log.write("inline router: \"\(instruction)\" → \(FreeForm.name)")
                        run(FreeForm.prompt(for: instruction).asTransform)
                    case .none:
                        giveUp("Not something to change in the text: \"\(instruction)\"")
                    }
                }
            } catch {
                await MainActor.run { giveUp(error.localizedDescription, tone: .failure) }
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
        destination: Destination, focus: SelectionReader.Selection?, for press: Press
    ) {
        switch action {
        case .vocabulary:
            // "…by the way parrot, fix vocabulary" — nothing to extract, the
            // panel opens on the sentence itself and you correct it by hand.
            endProgress()
            Log.write("inline: correction panel over \"\(text)\"")
            showInlineCorrection(
                over: text, rules: nil, destination: destination, focus: focus, for: press
            )

        case .spelling:
            // "…by the way parrot, Tasmin spells T A S M E E N" — the rule has
            // to be read out of the instruction first, which is a model call of
            // its own and not part of routing.
            guard config.llm.enabled else {
                giveUpInline(
                    text,
                    why: "\"\(instruction)\" needs the local model to read the spelling",
                    destination: destination, focus: focus, for: press
                )
                return
            }
            beginProgress("Thinking…")
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
                        self.endProgress()
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
                                destination: destination, focus: focus, for: press
                            )
                        }
                    }
                } catch {
                    await MainActor.run {
                        guard let self else { return }
                        self.endProgress()
                        self.giveUpInline(
                            text, why: error.localizedDescription, tone: .failure,
                            destination: destination, focus: focus, for: press
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
                    try ConfigWriter.addReplacement(heard: rule.heard, corrected: rule.corrected)
                    Log.write("learned replacement: \(rule.heard) -> \(rule.corrected)")
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
        destination: Destination, focus: SelectionReader.Selection?, for press: Press
    ) {
        endProgress()
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
                TextInserter.insert(text, mode: .clipboard)
                if config.feedback.sound { NSSound(named: "Glass")?.play() }
                Log.write(now == nil
                    ? "could not read what is focused; copied instead of pasting"
                    : "focus moved since the press; copied instead of pasting")
                // The menu bar, not the pill. The pill is about to carry the
                // offer, and a notice on it would be the offer's own surface
                // saying something else.
                setLabel("Focus moved — the transcription is on your clipboard", clearAfter: 4)
                showCorrectOffer(for: press, landing: .clipboardNow())
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
            TextInserter.insert(text, mode: .clipboard)
            if config.feedback.sound { NSSound(named: "Glass")?.play() }
            Log.write("nothing to type into (\(reason.described)); copied instead")
            // In the menu bar, for the same reason as above: the pill is the
            // offer's.
            setLabel("Nowhere to type — the transcription is on your clipboard", clearAfter: 4)
            showCorrectOffer(for: press, landing: .clipboardNow())
            updateUI()
            return
        }

        switch TextInserter.insert(text, mode: config.transcription.insertMode) {
        case .pasted:
            if config.feedback.sound { NSSound(named: "Glass")?.play() }
            // The words are in the field and you are looking at them. This is
            // the only second in which correcting one is free.
            showCorrectOffer(for: press, landing: .field)
        case .copied:
            // Deliberate clipboard mode — confirm it landed.
            if config.feedback.sound { NSSound(named: "Glass")?.play() }
            setLabel("Copied — ⌘V to paste", clearAfter: 4)
            showCorrectOffer(for: press, landing: .clipboardNow())
        case .clipboardOnly:
            if config.feedback.sound { NSSound(named: "Glass")?.play() }
            // Don't nag on every dictation — the text is safe on the clipboard.
            Log.write("Accessibility not granted; left transcript on the clipboard")
            setLabel("Copied — grant Accessibility to auto-paste", clearAfter: 4)
            showCorrectOffer(for: press, landing: .clipboardNow())
        }
        updateUI()
    }

    private func handleTranscriberStatus(_ status: Transcriber.Status) {
        switch status {
        case .downloading(let what):
            transcriptionLabel = "Downloading \(what)"
        case .loading:
            transcriptionLabel = "Loading speech model…"
        case .ready, .idle:
            break
        case .failed(let message):
            transcriptionLabel = "Model error: \(message)"
        }
        updateUI()
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

        updateItem = NSMenuItem(title: "", action: #selector(showUpdate), keyEquivalent: "")
        updateItem.target = self
        updateItem.isHidden = true
        menu.addItem(updateItem)

        menu.addItem(.separator())

        let correctItem = NSMenuItem(
            title: "Correct a Word…",
            action: #selector(correctWord),
            keyEquivalent: ""
        )
        correctItem.target = self
        menu.addItem(correctItem)

        let revealItem = NSMenuItem(
            title: "Open Recordings Folder",
            action: #selector(openRecordingsFolder),
            keyEquivalent: ""
        )
        revealItem.target = self
        menu.addItem(revealItem)

        menu.addItem(.separator())

        // One row for the two files you configure this app by: the config, and
        // the folder of transforms beside it. A submenu rather than two lines
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

        let transformsItem = NSMenuItem(
            title: "View Transforms",
            action: #selector(openTransformsFolder),
            keyEquivalent: ""
        )
        transformsItem.target = self
        settingsMenu.addItem(transformsItem)

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

        configProblemsItem.isHidden = configProblems.isEmpty
        configProblemsItem.title = configProblems.count == 1
            ? "⚠︎ 1 setting in config.yaml does nothing"
            : "⚠︎ \(configProblems.count) settings in config.yaml do nothing"

        updateItem.isHidden = updateAvailable == nil
        if let release = updateAvailable {
            updateItem.title = "↑ ParrotFlow \(release.version) is available"
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

    @objc private func correctWord() {
        beginCorrection()
    }

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

    /// The transforms folder — the layout is the documentation, so opening the
    /// directory says more than a list of names would.
    ///
    /// Created if it is not there, because an empty folder is an answer ("this
    /// is where they go") and a window that never opened is not.
    @objc private func openTransformsFolder() {
        let dir = ConfigStore.transformsDirectory
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
