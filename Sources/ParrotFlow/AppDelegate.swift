import AppKit
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var config = Config()
    private var configWatcher: FileWatcher?

    private let hotKeys = HotKeyManager()
    private let recorder = Recorder()
    private let overlay = RecordingOverlay()
    private let settings = SettingsWindowController()

    private var statusItem: NSStatusItem!
    private var statusInfoItem: NSMenuItem!
    private var toggleItem: NSMenuItem!

    /// The recording state the menu bar icon was last drawn for.
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

    private var tickTimer: Timer?
    private var pushToTalkPoll: Timer?
    private var keepWarmTimer: Timer?
    private var keepWarmInFlight = false
    private var hotkeyError: String?
    private var lastRecording: Recorder.Recording?

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
            + "accessibility=\(Permissions.accessibility.label)"
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

        // First run: get the microphone prompt out of the way immediately,
        // rather than at the moment the user first tries to dictate.
        if Permissions.microphone == .notDetermined {
            settings.show()
            Permissions.requestMicrophone { [weak self] _ in
                self?.settings.model.refreshPermissions()
            }
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
        configProblems = config.problems()
        for problem in configProblems { Log.write("config: \(problem)") }
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

        settings.model.hotkeyDisplay = hotKeys.binding?.displayName
            ?? KeyCodes.displayString(key: config.hotkey.key, modifiers: config.hotkey.modifiers)
        settings.model.hotkeyMode = config.hotkey.mode == .toggle
            ? "Tap to start, tap again to stop"
            : "Hold to record"
        settings.model.hotkeyError = hotkeyError
        settings.model.outputDir = config.audio.outputDir

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
        appAtPress = Self.appInFront()
        let elapsed = Date().timeIntervalSince(snapshotStart)
        if elapsed > 0.15 {
            Log.write(String(format: "selection snapshot was slow: %.2fs", elapsed))
        }

        switch config.hotkey.mode {
        case .toggle:
            toggleRecording()
        case .pushToTalk:
            guard !recorder.isRecording else { return }
            startRecording()
            startPushToTalkPoll()
        }
    }

    private func handleHotKeyRelease() {
        guard config.hotkey.mode == .pushToTalk else { return }
        stopRecording()
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
            if !held.isSuperset(of: required) {
                self.stopRecording()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pushToTalkPoll = timer
    }

    // MARK: - Recording

    @objc private func toggleRecording() {
        recorder.isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        guard !recorder.isRecording else { return }

        guard Permissions.microphone == .granted else {
            Permissions.requestMicrophone { [weak self] granted in
                guard let self else { return }
                self.settings.model.refreshPermissions()
                if granted {
                    self.startRecording()
                } else {
                    self.settings.show()
                }
            }
            return
        }

        do {
            try recorder.start(config: config)
        } catch {
            presentAlert(title: "Could not start recording", message: error.localizedDescription)
            return
        }

        if config.feedback.sound { NSSound(named: "Tink")?.play() }
        if config.feedback.overlay {
            overlay.model.elapsed = 0
            overlay.model.level = 0
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

    private func stopRecording(reason: String? = nil) {
        guard recorder.isRecording else { return }

        let recording = recorder.stop(config: config)

        tickTimer?.invalidate(); tickTimer = nil
        pushToTalkPoll?.invalidate(); pushToTalkPoll = nil
        overlay.hide()
        if config.feedback.sound { NSSound(named: "Pop")?.play() }

        if let recording {
            lastRecording = recording
            settings.model.lastRecording = String(
                format: "%@ (%.1fs)",
                recording.url.lastPathComponent,
                recording.duration
            )
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
    private static func appInFront() -> Pipeline.App? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        let app = Pipeline.App(
            name: front.localizedName ?? "", bundleID: front.bundleIdentifier ?? ""
        )
        // Both empty is not an app you could write a condition against, and
        // saying so is what makes `app:` fail closed instead of matching "  ".
        return app.searchable.trimmingCharacters(in: .whitespaces).isEmpty ? nil : app
    }

    private func transcribe(_ recording: Recorder.Recording) {
        transcriptionLabel = "Transcribing…"
        updateUI()

        let config = self.config
        // Taken at the press, not here: a transcript arrives seconds later and
        // the window you dictated into may not be the one in front by then.
        let app = appAtPress
        Task { [weak self] in
            do {
                let text = try await self?.transcriber.transcribe(
                    url: recording.url, config: config, app: app
                ) ?? ""
                await MainActor.run {
                    guard let self else { return }
                    self.transcriptionLabel = nil
                    self.finishTranscription(text: text)
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.transcriptionLabel = nil
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
            for: Catalogue(prompts: config.prompts), freeForm: config.freeForm
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
        let catalogue = Catalogue(prompts: config.prompts)

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
                        self.runTransform(FreeForm.prompt, instruction: command)
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
        case .transform(let prompt):
            runTransform(prompt, instruction: instruction)
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
        let context = settings.model.lastTranscript
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
    private func runTransform(_ prompt: Config.Prompt, instruction: String) {
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
        let target = selection?.text ?? settings.model.lastTranscript ?? ""
        guard !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            endProgress()
            Log.write("transform: nothing selected and nothing dictated yet")
            flash("Select some text first, or dictate something", tone: .caution)
            return
        }

        // The text itself, not just its length: a transform that worked on the
        // wrong thing is otherwise indistinguishable in the log from one that
        // worked on the right thing badly.
        Log.write("transform: \(prompt.name) over \(selection == nil ? "the last dictation" : "the selection") — \"\(target.prefix(80))\"")
        beginProgress("\(prompt.name)…")

        let llmConfig = llmConfig()
        Task { [weak self] in
            do {
                let result = try await PromptRunner.run(
                    prompt: prompt, instruction: instruction,
                    text: target, config: llmConfig
                )
                await MainActor.run {
                    self?.finishTransform(
                        prompt: prompt, selection: selection,
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
        prompt: Config.Prompt,
        selection: SelectionReader.Selection?,
        before: String,
        after: String
    ) {
        endProgress()

        let cleaned = after.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            Log.write("transform: \(prompt.name) returned nothing")
            flash("\(prompt.name) returned nothing from \(quoted(before))", tone: .caution)
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
            Log.write("transform: \(prompt.name) changed nothing")
            flash("\(prompt.name): nothing to change in \(quoted(before))", tone: .plain)
            return
        }

        guard prompt.confirm else {
            applyTransform(cleaned, to: selection, replacing: before, prompt: prompt)
            return
        }

        previewPanel.onApply = { [weak self] edited in
            self?.applyTransform(edited, to: selection, replacing: before, prompt: prompt)
        }
        previewPanel.onCancel = {
            Log.write("transform: \(prompt.name) discarded")
        }
        previewPanel.show(prompt: prompt.name, before: before, after: cleaned)
    }

    /// Puts a transformed phrase where the phrase it replaces is sitting.
    ///
    /// The accessibility write first, because it disturbs nothing. A terminal
    /// refuses it — its value is a picture of a screen — and there the only
    /// thing that writes is keystrokes, which stays behind `rewrite_line`
    /// because it clears the line to do it.
    /// Three outcomes, not two.
    ///
    /// "It did not happen" and "it was tried and rolled back" call for opposite
    /// things afterwards. Treating them alike is what produced
    /// "Fifty cents.50 cents.": the retype had already put text on the line and
    /// taken it off again, and the caller, seeing only false, pasted on top of
    /// the result.
    private enum InPlace { case replaced, notAttempted, failed }

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

    /// Makes edits to text where it already sits, by whichever means the app
    /// in front will accept.
    ///
    /// The one ladder for both callers. Corrections and transforms want the
    /// same thing — the field says X, make it say Y — and having each keep its
    /// own version of this meant a fix for one silently left the other behind.
    ///
    /// The accessibility write first, per edit, because it disturbs nothing. A
    /// terminal refuses it, and there the only thing that writes is keystrokes,
    /// which stays behind `rewrite_line` because it clears the line to do it —
    /// and which is done once for all the edits rather than once each, since
    /// every retype is a chance to lose the line.
    private func applyInPlace(
        _ edits: [Edit], dictated: String?, in element: AXUIElement
    ) -> InPlace {
        guard !edits.isEmpty else { return .notAttempted }

        var written = 0
        for edit in edits {
            if SelectionReader.replaceLastOccurrence(
                of: edit.find, with: edit.replace, in: element
            ) {
                written += 1
                continue
            }
            guard edit.fuzzy,
                  let text = SelectionReader.visibleText(of: element),
                  let nearest = VoiceCommand.closestWord(to: edit.replace, in: text),
                  nearest.lowercased() != edit.replace.lowercased(),
                  SelectionReader.replaceLastOccurrence(
                      of: nearest, with: edit.replace, in: element
                  )
            else { continue }
            written += 1
        }
        if written > 0 {
            Log.write("rewrote \(written) occurrence(s) in the focused field")
            return .replaced
        }

        guard config.transcription.rewriteLine else {
            Log.write("rewrite: rewrite_line is off; not retyping")
            return .notAttempted
        }
        Log.write("rewrite: retyping the line via keystrokes")
        let retyped = SelectionReader.rewriteCurrentLine(dictated: dictated, in: element) { line in
            // Fuzzy edits go through the rule machinery, which matches on word
            // boundaries and falls back to the closest spelling. Literal ones
            // cannot: a phrase may end in a full stop, and \b will not match
            // past it, so "Sixty Euros." found nothing and was pasted alongside.
            var output = SelectionReader.applying(
                edits.filter(\.fuzzy).map { (heard: $0.find, corrected: $0.replace) },
                to: line
            )
            for edit in edits where !edit.fuzzy {
                guard let found = output.range(
                    of: edit.find, options: [.caseInsensitive, .backwards]
                ) else { continue }
                output = output.replacingCharacters(in: found, with: edit.replace)
            }
            return output
        }
        // The retype found its line and acted on it either way; if it came back
        // false it has already put the line back, and the text belongs on the
        // clipboard rather than on top of what it restored.
        return retyped ? .replaced : .failed
    }

    private func applyTransform(
        _ text: String,
        to selection: SelectionReader.Selection?,
        replacing replaced: String,
        prompt: Config.Prompt
    ) {
        // Replacing the selection puts it back exactly where it came from.
        // Without one there is nowhere to aim, so it goes in at the cursor the
        // same way a dictation would.
        if let selection {
            switch SelectionReader.replaceSelection(with: text, in: selection) {
            case .written, .pasted:
                if config.feedback.sound { NSSound(named: "Glass")?.play() }
                flash("\(prompt.name) applied", tone: .done)
            case .clipboardOnly:
                Log.write("transform: this app would not accept the rewrite; left on the clipboard")
                flash("\(prompt.name) copied — this app won't let me edit it", tone: .caution)
            }
        } else {
            // Hand focus back first. Showing the preview called NSApp.activate
            // to put the panel in front, so by the time Apply is pressed we are
            // the frontmost app and Cmd-V lands in our own window — which is
            // how "digits applied" appeared over a TUI that never changed. The
            // other branch never had this problem because replaceSelection
            // activates the owner itself.
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
                switch applyInPlace([edit], dictated: original, in: element) {
                case .replaced:
                    if config.feedback.sound { NSSound(named: "Glass")?.play() }
                    flash("\(prompt.name) applied", tone: .done)
                    settings.model.lastTranscript = text
                    return
                case .failed:
                    Log.write("transform: the line would not take the rewrite; left on the clipboard")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    flash("\(prompt.name) copied — this app won't let me edit it", tone: .caution)
                    settings.model.lastTranscript = text
                    return
                case .notAttempted:
                    break
                }
            }

            switch TextInserter.insert(text, mode: config.transcription.insertMode) {
            case .pasted, .copied:
                if config.feedback.sound { NSSound(named: "Glass")?.play() }
                flash("\(prompt.name) applied", tone: .done)
            case .clipboardOnly:
                flash("\(prompt.name) copied — grant Accessibility to paste", tone: .caution)
            }
        }
        settings.model.lastTranscript = text
    }

    private func apply(_ command: VoiceCommand, command spoken: String) {
        // Whatever happens next replaces it: a panel, or a flash of its own.
        endProgress()

        switch command {
        case .openCorrectionPanel:
            beginCorrection()
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
            } catch {
                presentAlert(title: "Could not save the rule", message: error.localizedDescription)
                pendingSelection = nil
                return
            }
        }

        // Put the corrected phrase back where it came from, whether or not any
        // rules were saved — the user may just be fixing this one instance.
        let trimmed = correctedText.trimmingCharacters(in: .whitespacesAndNewlines)
        var outcome: SelectionReader.ReplaceOutcome?
        if let selection = pendingSelection, !trimmed.isEmpty {
            outcome = SelectionReader.replaceSelection(with: correctedText, in: selection)
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
                dictated: settings.model.lastTranscript,
                in: element
            ) {
            case .replaced:
                outcome = .written
            case .notAttempted, .failed:
                Log.write("field would not accept the rewrite; correction is on the clipboard")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(rules[0].corrected, forType: .string)
                outcome = .clipboardOnly
            }
        } else if !trimmed.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(correctedText, forType: .string)
        }
        pendingSelection = nil
        focusAtPress = nil

        if config.feedback.sound { NSSound(named: "Glass")?.play() }
        if outcome == .clipboardOnly {
            flash("Rule saved · \"\(rules.first?.corrected ?? "")\" copied — this app won't let me edit it", tone: .caution)
            return
        }
        switch rules.count {
        case 0: flash("Text replaced", tone: .done)
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

    private func finishTranscription(text: String) {
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
            settings.model.lastTranscript = split.text
            runInline(text: split.text, instruction: split.instruction)
            return
        }

        Log.write("transcribed: \(trimmed)")
        settings.model.lastTranscript = trimmed
        insertDictation(trimmed)
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
    private func runInline(text: String, instruction: String) {
        let catalogue = Catalogue(prompts: config.prompts)

        /// Write what was said, and say why it is not what was asked for.
        func giveUp(_ why: String, tone: NoticeTone = .caution) {
            endProgress()
            Log.write("inline: \(why); wrote the text as dictated")
            insertDictation(text)
            notice.show(why, tone: tone, duration: 7)
            setLabel(why, clearAfter: 7)
        }

        func run(_ prompt: Config.Prompt) {
            beginProgress("\(prompt.name)…")
            let llm = llmConfig()
            Task { [weak self] in
                do {
                    let result = try await PromptRunner.run(
                        prompt: prompt, instruction: instruction, text: text, config: llm
                    )
                    await MainActor.run {
                        guard let self else { return }
                        self.endProgress()
                        let cleaned = result.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !cleaned.isEmpty else {
                            giveUp("\(prompt.name) returned nothing", tone: .failure)
                            return
                        }
                        if cleaned != text {
                            Log.write("inline: \(prompt.name) rewrote the transcript")
                            Log.write("    before: \(text)")
                            Log.write("    after:  \(cleaned)")
                        }
                        self.settings.model.lastTranscript = cleaned
                        self.insertDictation(cleaned)
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
            case .transform(let prompt): run(prompt)
            case .action(let action): runInlineAction(action, text: text, instruction: instruction)
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
                    case .matched(.transform(let prompt)):
                        Log.write("inline router: \"\(instruction)\" → \(prompt.name)")
                        run(prompt)
                    case .matched(.action(let action)):
                        self.runInlineAction(action, text: text, instruction: instruction)
                    case .anything:
                        Log.write("inline router: \"\(instruction)\" → \(FreeForm.name)")
                        run(FreeForm.prompt)
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
        _ action: Capability.Action, text: String, instruction: String
    ) {
        switch action {
        case .vocabulary:
            // "…by the way parrot, fix vocabulary" — nothing to extract, the
            // panel opens on the sentence itself and you correct it by hand.
            endProgress()
            Log.write("inline: correction panel over \"\(text)\"")
            showInlineCorrection(over: text, rules: nil)

        case .spelling:
            // "…by the way parrot, Tasmin spells T A S M E E N" — the rule has
            // to be read out of the instruction first, which is a model call of
            // its own and not part of routing.
            guard config.llm.enabled else {
                giveUpInline(text, why: "\"\(instruction)\" needs the local model to read the spelling")
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
                            self.showInlineCorrection(over: text, rules: rules)
                        case .openCorrectionPanel:
                            self.showInlineCorrection(over: text, rules: nil)
                        case .unrecognised:
                            self.giveUpInline(text, why: "Didn't understand \"\(instruction)\"")
                        }
                    }
                } catch {
                    await MainActor.run {
                        guard let self else { return }
                        self.endProgress()
                        self.giveUpInline(text, why: error.localizedDescription, tone: .failure)
                    }
                }
            }
        }
    }

    /// The correction panel, with the dictated text waiting behind it.
    ///
    /// `pendingSelection` and `focusAtPress` are deliberately cleared: they are
    /// how `saveCorrections` decides to write into a field somewhere else, and
    /// here the only place the text should land is where a dictation would put
    /// it. Leaving them set would rewrite whatever happened to be selected when
    /// the hotkey went down.
    private func showInlineCorrection(
        over text: String, rules: [(heard: String, corrected: String)]?
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
            guard let owner = focusAtPress?.owner, !owner.isActive else { return }
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
            let final = rules == nil && !correctedText.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty ? correctedText : corrected
            self.settings.model.lastTranscript = final
            handBack()
            Log.write("inline: writing into \(self.focusAtPress?.owner?.localizedName ?? "the frontmost app")")
            self.insertDictation(final)
        }
        correctionPanel.onCancel = { [weak self] in
            guard let self else { return }
            Log.write("inline: correction dismissed; wrote the text as dictated")
            handBack()
            self.insertDictation(text)
        }

        if let rules {
            correctionPanel.show(rules: rules)
        } else {
            correctionPanel.show(selection: text)
        }
    }

    /// Write what was said, and say why it is not what was asked for.
    private func giveUpInline(_ text: String, why: String, tone: NoticeTone = .caution) {
        endProgress()
        Log.write("inline: \(why); wrote the text as dictated")
        insertDictation(text)
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
    private func insertDictation(_ text: String) {
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
        statusItem.button?.image = NSImage(
            systemSymbolName: AppVariant.menuBarSymbol,
            accessibilityDescription: AppVariant.displayName
        )
        statusItem.button?.image?.isTemplate = true

        let menu = NSMenu()

        statusInfoItem = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
        statusInfoItem.isEnabled = false
        menu.addItem(statusInfoItem)

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

        toggleItem = NSMenuItem(
            title: "Start Dictation",
            action: #selector(toggleRecording),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

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

        let editItem = NSMenuItem(title: "Edit Config…", action: #selector(editConfig), keyEquivalent: "")
        editItem.target = self
        menu.addItem(editItem)

        let settingsItem = NSMenuItem(
            title: "Settings & Permissions…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit ParrotFlow", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func updateUI() {
        let recording = recorder.isRecording

        // Only when it actually changes. updateUI runs on a 0.1s timer while
        // recording, to redraw the elapsed clock, and the icon is the one thing
        // in here that cannot change between two ticks of the same state —
        // rebuilding the symbol regardless was ten identical NSImages a second.
        if shownRecording != recording {
            shownRecording = recording
            statusItem.button?.image = NSImage(
                systemSymbolName: recording
                    ? AppVariant.menuBarSymbolRecording
                    : AppVariant.menuBarSymbol,
                accessibilityDescription: AppVariant.displayName
            )
            // Stays a template image so `contentTintColor` applies — a
            // non-template symbol ignores the tint and renders black in a dark
            // menu bar.
            statusItem.button?.image?.isTemplate = true
            statusItem.button?.contentTintColor = recording ? .systemRed : nil
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

        toggleItem.title = recording ? "Stop Dictation" : "Start Dictation"

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

    @objc private func editConfig() {
        try? ConfigStore.createIfMissing()
        NSWorkspace.shared.open(ConfigStore.fileURL)
    }

    @objc private func openSettings() {
        settings.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

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
