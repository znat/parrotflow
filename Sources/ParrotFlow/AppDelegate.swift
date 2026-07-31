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

    private lazy var transcriber = Transcriber { [weak self] status in
        DispatchQueue.main.async { self?.handleTranscriberStatus(status) }
    }
    private var transcriptionLabel: String?
    /// Bumped by every `setLabel`, so a self-clear armed for one message cannot
    /// wipe a newer one that is still current.
    private var labelToken = 0
    private let correctionPanel = CorrectionPanel()
    private let notice = NoticeHUD()
    private var pendingSelection: SelectionReader.Selection?
    /// Captured the moment the hotkey goes down — see SelectionReader.snapshot.
    private var selectionAtPress: SelectionReader.Selection?
    /// Where the text was being typed when the hotkey went down, so a rule
    /// learned by voice can fix the word already in the field.
    private var focusAtPress: SelectionReader.Selection?

    private var tickTimer: Timer?
    private var pushToTalkPoll: Timer?
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

    private func applyConfig() {
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

        updateUI()
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

    private func transcribe(_ recording: Recorder.Recording) {
        transcriptionLabel = "Transcribing…"
        updateUI()

        let config = self.config
        Task { [weak self] in
            do {
                let text = try await self?.transcriber.transcribe(url: recording.url, config: config) ?? ""
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

    /// Everything said after the wake phrase, or nil when this is plain
    /// dictation. Empty string means the phrase was said on its own.
    ///
    /// Matched word by word on a normalised copy but returned from the
    /// original, so "Tasmin spells T A S M E E N" keeps its capitals — the
    /// spelling is the whole point of the command.
    private func commandAfterWakePhrase(_ text: String) -> String? {
        VoiceCommand.commandAfterWakePhrase(
            text, phrase: config.transcription.activationPhrase
        )
    }

    private func handleVoiceCommand(_ command: String) {
        // Deterministic phrases first: no model needed, and they work when
        // Ollama is not running.
        if let local = VoiceCommand.local(from: command) {
            apply(local, command: command)
            return
        }

        guard config.llm.enabled else {
            flash("Didn't understand \"\(command)\" — enable llm in config for free-form commands")
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
                    self?.flash(error.localizedDescription)
                }
            }
        }
    }

    private func apply(_ command: VoiceCommand, command spoken: String) {
        // Whatever happens next replaces it: a panel, or a flash of its own.
        endProgress()

        switch command {
        case .openCorrectionPanel:
            beginCorrection()
        case .addRule(let heard, let corrected):
            // Prefilled, not saved: the model proposed it, you confirm it.
            Log.write("command proposed rule: \(heard) -> \(corrected)")
            pendingSelection = nil
            correctionPanel.onSave = { [weak self] rules, text in
                self?.saveCorrections(rules, correctedText: text)
            }
            correctionPanel.onCancel = { [weak self] in self?.pendingSelection = nil }
            correctionPanel.show(rule: (heard: heard, corrected: corrected))
        case .unrecognised(let text):
            Log.write("command not understood: \(text)")
            flash("Didn't understand \"\(spoken)\"")
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
            // still sitting in the field where it was dictated. Fix it there.
            //
            // Try the word as learned, then whatever in the field resembles
            // the correct spelling — two hearings of a name rarely match.
            var fixed = 0
            for rule in rules {
                if SelectionReader.replaceLastOccurrence(
                    of: rule.heard, with: rule.corrected, in: element
                ) {
                    fixed += 1
                    continue
                }
                if let text = SelectionReader.visibleText(of: element),
                   let nearest = VoiceCommand.closestWord(to: rule.corrected, in: text),
                   nearest.lowercased() != rule.corrected.lowercased(),
                   SelectionReader.replaceLastOccurrence(
                       of: nearest, with: rule.corrected, in: element
                   ) {
                    fixed += 1
                }
            }
            if fixed > 0 {
                Log.write("rewrote \(fixed) occurrence(s) in the focused field")
                outcome = .written
            } else if config.transcription.rewriteLine {
                // The accessibility API would not write. Clear the line and
                // rebuild it from what the kill removed — the terminal tells
                // us what was there rather than us having to guess.
                Log.write("rewrite: retyping the line via keystrokes")
                if SelectionReader.rewriteCurrentLine(applying: rules, in: element) {
                    outcome = .written
                } else {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(rules[0].corrected, forType: .string)
                    outcome = .clipboardOnly
                }
            } else {
                if !config.transcription.rewriteLine {
                    Log.write("rewrite: rewrite_line is off; not retyping")
                }
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
            flash("Rule saved · \"\(rules.first?.corrected ?? "")\" copied — this app won't let me edit it")
            return
        }
        switch rules.count {
        case 0: flash("Text replaced")
        case 1: flash("Saved  \(rules[0].heard) → \(rules[0].corrected)")
        default: flash("Saved \(rules.count) rules")
        }
    }

    /// Show a message on screen, and in the menu bar for as long as it lasts.
    private func flash(_ message: String) {
        notice.show(message)
        setLabel(message, clearAfter: 4)
    }

    /// A message that stays up until `endProgress()`, for work of no
    /// predictable length. "Thinking…" was a `flash`, so it timed out after
    /// 3.5s while a cold Ollama was still loading — leaving the rest of a 10s
    /// wait with nothing on screen at all.
    private func beginProgress(_ message: String) {
        notice.show(message, duration: nil)
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

        Log.write("transcribed: \(trimmed)")
        settings.model.lastTranscript = trimmed

        switch TextInserter.insert(trimmed, mode: config.transcription.insertMode) {
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

        statusItem.button?.image = NSImage(
            systemSymbolName: recording
                ? AppVariant.menuBarSymbolRecording
                : AppVariant.menuBarSymbol,
            accessibilityDescription: AppVariant.displayName
        )
        // Stays a template image so `contentTintColor` applies — a non-template
        // symbol ignores the tint and renders black in a dark menu bar.
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.contentTintColor = recording ? .systemRed : nil

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
