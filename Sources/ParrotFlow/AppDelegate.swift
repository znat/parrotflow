import AppKit
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var config = Config()
    private var configWatcher: FileWatcher?

    private let hotKeys = HotKeyManager()
    private let recorder = Recorder()
    private let overlay = RecordingOverlay()
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
    private let notice = NoticeHUD()
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
    /// That same app's icon, for the pill. Held apart from `appAtPress` because
    /// `Pipeline.App` is what the pipeline matches on and has no business
    /// carrying an image around.
    private var appIconAtPress: NSImage?
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
    private var keepWarmTimer: Timer?
    private var keepWarmInFlight = false
    private var hotkeyError: String?
    private var lastRecording: Recorder.Recording?
    /// What was last dictated — the context a correction or a free-form command
    /// works against when there is no selection to work against instead.
    private var lastTranscript: String?

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
            self?.overlay.model.level = level
        }
        recorder.onUnexpectedStop = { [weak self] _ in
            self?.stopRecording(reason: "The audio device changed.")
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
        recorder.isRecording ? stopRecording() : startRecording()
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
                    self.permissions.show(.revisiting)
                }
            }
            return
        }

        do {
            try recorder.start(config: config)
        } catch {
            // A notice, not an alert. `runModal` holds the main run loop, and
            // the hotkey is delivered on it: one failed press behind a modal
            // and every press after it does nothing, which is indistinguishable
            // from the app having died — and is what happened whenever the
            // microphone changed underneath it. Logged as well, because this
            // path used to leave the log showing a press and then silence.
            Log.write("could not start recording: \(error.localizedDescription)")
            flash(error.localizedDescription, tone: .failure)
            return
        }

        watchForEscape()

        if config.feedback.sound { NSSound(named: "Tink")?.play() }
        if config.feedback.overlay {
            overlay.model.elapsed = 0
            overlay.model.level = 0
            overlay.model.appIcon = appIconAtPress
            overlay.show()
        }

        let tick = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let started = self.recorder.startedAt else { return }
            self.overlay.model.elapsed = Date().timeIntervalSince(started)
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
            tickTimer?.invalidate(); tickTimer = nil
            pushToTalkPoll?.invalidate(); pushToTalkPoll = nil
            releaseTail?.invalidate(); releaseTail = nil
            overlay.hide()
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
        overlay.hide()
        if config.feedback.sound { NSSound(named: "Pop")?.play() }

        // Transcription takes the watch over from here — it is the other half
        // of the dictation Escape can still stop. With transcription off there
        // is nothing left to cancel, so it ends now.
        if !config.transcription.enabled { stopWatchingForEscape() }

        if let recording {
            lastRecording = recording
            Log.write(String(format: "wrote %@ (%.2fs)", recording.url.lastPathComponent, recording.duration))
            if config.transcription.enabled {
                transcribe(recording)
            }
        }

        if let reason {
            presentAlert(title: "Recording stopped", message: reason)
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
                    guard !self.wasCancelled(run) else {
                        Log.write("escape: dropped the transcript of a cancelled run")
                        self.updateUI()
                        return
                    }
                    self.stopWatchingForEscape()
                    self.finishTranscription(
                        text: text, destination: destination, focus: focus
                    )
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    if self.transcriptionRun == run { self.endProgress() }
                    self.stopWatchingForEscape()
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

    private func saveCorrections(
        _ rules: [(heard: String, corrected: String)],
        correctedText: String
    ) {
        for rule in rules {
            do {
                try ConfigWriter.addReplacement(heard: rule.heard, corrected: rule.corrected)
                Log.write("learned replacement: \(rule.heard) -> \(rule.corrected)")
                Trace.correction(heard: rule.heard, corrected: rule.corrected, via: "command")
            } catch {
                presentAlert(title: "Could not save the rule", message: error.localizedDescription)
                pendingSelection = nil
                return
            }
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
        notice.show(message, tone: tone)
        setLabel(message, clearAfter: 4)
    }

    /// A message that stays up until `endProgress()`, for work of no
    /// predictable length. "Thinking…" was a `flash`, so it timed out after
    /// 3.5s while a cold Ollama was still loading — leaving the rest of a 10s
    /// wait with nothing on screen at all.
    private func beginProgress(_ message: String) {
        notice.show(message, tone: .thinking, duration: nil)
        setLabel(message)
    }

    private func endProgress() {
        notice.hide()
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
        text: String, destination: Destination, focus: SelectionReader.Selection?
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if let command = commandAfterWakePhrase(trimmed) {
            Log.write("command heard: \"\(command)\"")
            handleVoiceCommand(command)
            return
        }

        guard !trimmed.isEmpty else {
            Log.write("transcription produced no text")
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
                destination: destination, focus: focus
            )
            return
        }

        Log.write("transcribed: \(trimmed)")
        lastTranscript = trimmed
        insertDictation(trimmed, to: destination, aimedAt: focus?.element)
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
        focus: SelectionReader.Selection?
    ) {
        let catalogue = Catalogue(transforms: config.transforms)

        /// Write what was said, and say why it is not what was asked for.
        func giveUp(_ why: String, tone: NoticeTone = .caution) {
            endProgress()
            Log.write("inline: \(why); wrote the text as dictated")
            insertDictation(text, to: destination, aimedAt: focus?.element)
            notice.show(why, tone: tone, duration: 7)
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
                        self.insertDictation(cleaned, to: destination, aimedAt: focus?.element)
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
                    destination: destination, focus: focus
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
                            destination: destination, focus: focus
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
        destination: Destination, focus: SelectionReader.Selection?
    ) {
        switch action {
        case .vocabulary:
            // "…by the way parrot, fix vocabulary" — nothing to extract, the
            // panel opens on the sentence itself and you correct it by hand.
            endProgress()
            Log.write("inline: correction panel over \"\(text)\"")
            showInlineCorrection(
                over: text, rules: nil, destination: destination, focus: focus
            )

        case .spelling:
            // "…by the way parrot, Tasmin spells T A S M E E N" — the rule has
            // to be read out of the instruction first, which is a model call of
            // its own and not part of routing.
            guard config.llm.enabled else {
                giveUpInline(
                    text,
                    why: "\"\(instruction)\" needs the local model to read the spelling",
                    destination: destination, focus: focus
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
                                destination: destination, focus: focus
                            )
                        case .openCorrectionPanel:
                            self.showInlineCorrection(
                                over: text, rules: nil,
                                destination: destination, focus: focus
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
                                destination: destination, focus: focus
                            )
                        }
                    }
                } catch {
                    await MainActor.run {
                        guard let self else { return }
                        self.endProgress()
                        self.giveUpInline(
                            text, why: error.localizedDescription, tone: .failure,
                            destination: destination, focus: focus
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
        destination: Destination, focus: SelectionReader.Selection?
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
            self.insertDictation(final, to: destination, aimedAt: focus?.element)
        }
        correctionPanel.onCancel = { [weak self] in
            guard let self else { return }
            Log.write("inline: correction dismissed; wrote the text as dictated")
            handBack()
            self.insertDictation(text, to: destination, aimedAt: focus?.element)
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
        destination: Destination, focus: SelectionReader.Selection?
    ) {
        endProgress()
        Log.write("inline: \(why); wrote the text as dictated")
        insertDictation(text, to: destination, aimedAt: focus?.element)
        notice.show(why, tone: tone, duration: 7)
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
    /// `aimedAt` is the element that had focus when the hotkey went down. A
    /// transcript arrives seconds later — a decoder, then any prompt stage —
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
    /// nil means there is nothing to compare against — no focus was resolved at
    /// the press — and the paste goes ahead as it always did. Passed explicitly
    /// at every call rather than defaulted, so a new path has to say which it is.
    ///
    /// False positives would make this unusable: guard too eagerly and every
    /// dictation ends up on the clipboard. The comparison was measured before it
    /// was relied on — the press-time experiment behind the `context` stage ran
    /// this same `CFEqual` across 17 real dictations and the element was equal
    /// every time.
    private func insertDictation(
        _ text: String, to destination: Destination, aimedAt element: AXUIElement?
    ) {
        if config.transcription.insertMode == .paste, let element,
           let now = SelectionReader.focusedElement(), !CFEqual(now, element) {
            TextInserter.insert(text, mode: .clipboard)
            if config.feedback.sound { NSSound(named: "Glass")?.play() }
            Log.write("focus moved since the press; copied instead of pasting")
            flash("Focus moved — the transcription is on your clipboard", tone: .caution)
            updateUI()
            return
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
            flash("Nowhere to type — the transcription is on your clipboard", tone: .done)
            updateUI()
            return
        }

        switch TextInserter.insert(text, mode: config.transcription.insertMode) {
        case .pasted:
            if config.feedback.sound { NSSound(named: "Glass")?.play() }
        case .copied:
            // Deliberate clipboard mode — confirm it landed.
            if config.feedback.sound { NSSound(named: "Glass")?.play() }
            setLabel("Copied — ⌘V to paste", clearAfter: 4)
        case .clipboardOnly:
            if config.feedback.sound { NSSound(named: "Glass")?.play() }
            // Don't nag on every dictation — the text is safe on the clipboard.
            Log.write("Accessibility not granted; left transcript on the clipboard")
            setLabel("Copied — grant Accessibility to auto-paste", clearAfter: 4)
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
            let elapsed = Int(overlay.model.elapsed)
            statusInfoItem.title = String(format: "Recording  %d:%02d", elapsed / 60, elapsed % 60)
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
