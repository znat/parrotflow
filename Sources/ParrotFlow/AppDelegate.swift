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

    private func finishTranscription(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
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
            transcriptionLabel = "Copied — ⌘V to paste"
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                self?.transcriptionLabel = nil
                self?.updateUI()
            }
        case .clipboardOnly:
            if config.feedback.sound { NSSound(named: "Glass")?.play() }
            // Don't nag on every dictation — the text is safe on the clipboard.
            Log.write("Accessibility not granted; left transcript on the clipboard")
            transcriptionLabel = "Copied — grant Accessibility to auto-paste"
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                self?.transcriptionLabel = nil
                self?.updateUI()
            }
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
            systemSymbolName: "mic",
            accessibilityDescription: "ParrotFlow"
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
            systemSymbolName: recording ? "mic.fill" : "mic",
            accessibilityDescription: "ParrotFlow"
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
