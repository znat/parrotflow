import AVFoundation
import Foundation
import Yams

enum CheckConfigCommand {

    /// Returns the process exit code: 0 if the config is usable, 1 otherwise.
    static func run() -> Int32 {
        let checked = report()
        print(checked.text)
        return checked.ok ? 0 : 1
    }

    /// The same lines, returned instead of printed, so `--bug-report` carries
    /// this output without a second copy of it.
    static func report() -> (text: String, ok: Bool) {
        var lines: [String] = []
        func emit(_ line: String) { lines.append(line) }
        func finished(_ ok: Bool) -> (text: String, ok: Bool) {
            (lines.joined(separator: "\n"), ok)
        }

        emit("config: \(ConfigStore.fileURL.path)")

        let config: Config
        do {
            config = try ConfigStore.load()
        } catch {
            emit("  ✗ \(describe(error))")
            return finished(false)
        }

        var ok = true

        // Hotkey
        let mode = config.hotkey.mode == .toggle ? "toggle" : "push-to-talk"
        if let modifierKey = ModifierKey(name: config.hotkey.key) {
            emit("  ✓ hotkey            \(modifierKey.displayName)  (\(mode), polled)")
            if !config.hotkey.modifiers.isEmpty {
                emit("  · note              hotkey.modifiers is ignored for a bare modifier key")
            }
        } else if KeyCodes.code(for: config.hotkey.key) == nil {
            emit("  ✗ hotkey.key: \"\(config.hotkey.key)\" is not a known key name")
            ok = false
        } else if KeyCodes.carbonModifiers(config.hotkey.modifiers) == 0 {
            emit("  ✗ hotkey.modifiers: need at least one of command, control, option, shift")
            ok = false
        } else {
            let shortcut = KeyCodes.displayString(key: config.hotkey.key, modifiers: config.hotkey.modifiers)
            emit("  ✓ hotkey            \(shortcut)  (\(mode), Carbon)")
        }
        if ModifierKey(name: config.hotkey.key) != nil {
            let delay = config.hotkey.pressDelaySeconds
            let held = delay > 0
                ? "held alone for \(delay)s, or it is a shortcut"
                : "off — starts on the down edge"
            print("  · press delay       \(held)")
            if delay > 0, Permissions.accessibility != .granted {
                print("  · note              without Accessibility, only a second modifier is caught")
            }
        }
        if config.hotkey.mode == .pushToTalk {
            let tail = config.hotkey.releaseTailSeconds
            emit("  · release tail      \(tail > 0 ? "\(tail)s after the key comes up" : "off — stops on the release")")
        }

        // Audio
        emit("  ✓ sample rate       \(Int(config.audio.sampleRate)) Hz mono")
        emit("  ✓ output dir        \(config.resolvedOutputDir.path)")
        emit("  ✓ min duration      \(config.audio.minDurationSeconds)s")
        emit("  · speech gate       \(config.audio.speechGate ? "on" : "off")")
        if config.audio.secondOpinion, !config.audio.speechGate {
            emit("  ! second opinion    on, but it needs speech_gate — no padded decode will run")
        } else {
            emit("  · second opinion    \(config.audio.secondOpinion ? "on" : "off")")
        }
        emit("  · feedback          sound=\(config.feedback.sound)"
              + " volume=\(config.feedback.soundVolume) overlay=\(config.feedback.overlay)"
              + " correct_offer=\(config.feedback.correctOffer)"
              + " confidence=\(config.feedback.confidence)")
        emit("  · low confidence    sentence<\(config.feedback.lowConfidence.sentence)"
              + " AND word<\(config.feedback.lowConfidence.word)"
              + " hold_return=\(config.feedback.lowConfidence.holdReturn)"
              + (config.feedback.warnsOnLowConfidence ? "" : " (off)"))
        emit("  · logging           text=\(config.logging.text ? "on" : "off")"
              + " audio=\(config.logging.audio ? "on" : "off")")

        // Transcription — printed so a mis-decoded config is visible rather
        // than silently falling back to "no vocabulary".
        let transcription = config.transcription
        emit("  · transcription     \(transcription.enabled ? "enabled" : "disabled")")
        if transcription.enabled {
            let mode = transcription.insertMode == .paste
                ? "paste into frontmost app (needs Accessibility)"
                : "copy to clipboard"
            emit("  · insert mode       \(mode)")
            let listed = transcription.activationPhrases
                .map { "\"\($0)\"" }.joined(separator: ", ")
            emit("  · wake phrase       \(listed.isEmpty ? "none — spoken commands are off" : listed)")
            emit("  · rewrite line      \(transcription.rewriteLine ? "on" : "off (terminals can't be edited without it)")")
            // The pipeline, because "why was this not converted" is a question
            // about the order and not about a setting any more.
            let pipeline = Pipeline.resolved(config: config)
            let vocabulary = pipeline.steps.first { $0.stage == .vocabulary }
            // The floor is not the same in two languages, so it is printed per
            // language rather than once. The marks are not: they belong to the
            // `interpret` step, which is English only, and they are printed
            // with it below.
            emit("  · languages         \(transcription.languages.joined(separator: ", "))")
            for language in transcription.languages {
                let floor = transcription.slotFloor(for: language, on: vocabulary)
                emit("      \(language)  slot floor \(String(format: "%.2f", floor))")
            }
            // Which of the two tests that read the sentence will run, and the
            // same predicates that decide whether their models are fetched — so
            // a line saying a half is off is also saying nothing is downloaded
            // for it. Silent when the pipeline holds no `vocabulary` step.
            if vocabulary != nil {
                emit("  · vocabulary gates  slot \(config.readsSlots ? "on" : "off"),"
                    + " portrait \(config.readsPortraits ? "on" : "off")"
                    + (config.vocabulary.gateSentence
                        ? "" : "  (the sentence tests are off —"
                            + " `vocabulary.gate_sentence: false`)"))
            }
            // The set the step actually runs with, whichever of its three homes
            // it came from. Silent when the pipeline holds no step at all.
            //
            // `readsBoundaries` is the same predicate that decides whether the
            // 320 MB model is fetched, so a line saying the step is off is
            // also saying nothing will be downloaded for it.
            if let step = pipeline.steps.first(where: { $0.stage == .interpret }) {
                let marks = step.marks ?? transcription.marks(for: "en")
                emit("  · sentence marks    \(marks.joined(separator: " "))"
                    + (step.capitals == false ? "  (bare capitals off)" : "")
                    + (config.readsBoundaries
                        ? "" : "  (off — `transcription.sentences: false`)"))
            }
            // An empty pipeline is a choice, not a blank: printing nothing
            // there reads as a display fault rather than as the answer to "why
            // did none of this run".
            // Conditions are printed with the stage they gate. A pipeline that
            // reads as three stages when one of them almost never runs is a
            // pipeline that explains nothing.
            let stages = pipeline.steps.isEmpty
                ? "nothing — the list is empty"
                : pipeline.steps.map { step -> String in
                    var described = step.stage.name
                    if let transform = step.transform { described += " \(transform)" }
                    if let when = step.when { described += " when \(when)" }
                    if let unless = step.unless { described += " unless \(unless)" }
                    if let app = step.app { described += " in \(app)" }
                    return described
                }.joined(separator: " → ")
            let source = transcription.pipeline == nil
                ? "  (nothing configured, so every stage)" : ""
            emit("  · pipeline          \(stages)\(source)")
        }

        // A key that no longer does anything is worse than a key that is
        // wrong: nothing fails, and two passes quietly stop running. So it is
        // an error, with the replacement spelled out.
        for problem in config.problems() {
            emit("  ✗ \(problem)")
            ok = false
        }
        // Said, not complained about. These are true of a config that works —
        // a ✗ here used to fail the whole command over a `command:` transform
        // doing exactly what it was written to do.
        for notice in config.notices() {
            emit("  · \(notice)")
        }
        if !transcription.retired.isEmpty {
            emit("      pipeline: [\(Pipeline.everything.stages.map(\.name).joined(separator: ", "))]")
        }

        // What `voice/` has piled up, per term. Printed because it is the one
        // part of the configuration that grows on its own: nobody chose these
        // numbers and nobody sees them until something goes wrong. Silent when
        // the directory does not exist, which is every install that has not
        // learnt anything yet.
        let recorded = VoiceStore.counts()
        if !recorded.isEmpty {
            emit("  · voice             \(recorded.count) term(s) in"
                + " \(VoiceStore.directory.path)")
            let width = recorded.map(\.term.count).max() ?? 0
            for entry in recorded {
                emit("      \(entry.term.padding(toLength: width, withPad: " ", startingAt: 0))"
                    + "  \(entry.observations) observation(s), \(entry.samples) sample(s)"
                    + "  — `--forget \(entry.term)` drops both")
            }
        }
        // A closed band is the one measurement that argues with the config: it
        // says no threshold will ever separate that term for this speaker,
        // whatever `offer_below` is set to.
        if let bands = VoiceStore.calibration() {
            emit("  · calibration       measured \(bands.measured), \(bands.terms) term(s)"
                + (bands.closed > 0
                    ? ", \(bands.closed) with no band — those want `floor: off`"
                        + " and pronunciations, not a number"
                    : ""))
        }

        // Where each body actually came from.
        //
        // A file present both in the folder and at the old location beside
        // config.yaml is otherwise invisible, and "which one is running" is the
        // first question when a change you made had no effect. Printed as the
        // resolved absolute path for that reason: what the config says is
        // `slack_mentions.py`, and that is exactly the string that cannot
        // answer it.
        // Which model each job and each prompt ends up on.
        //
        // Not the same question as what `models:` says: a name resolves through
        // `llm.default`, a transform's own `model:`, and whatever that overrides
        // — and "was that the model I think it was" is the first question when a
        // prompt starts answering differently. The key is described, never
        // printed.
        let models = config.modelsByName
        emit("  · models            \(models.count) reachable")
        let modelWidth = models.keys.map(\.count).max() ?? 0
        for name in models.keys.sorted() {
            guard let spec = models[name] else { continue }
            let padded = name.padding(toLength: max(modelWidth, 1), withPad: " ", startingAt: 0)
            let key = spec.api.isLocal ? "" : "  \(spec.key.described)"
            emit("      \(padded)  \(spec.api.rawValue)  \(spec.model)  \(spec.url)"
                + "  reasoning \(spec.reasoning.rawValue)\(key)")
        }
        emit("  · runs on           default=\(config.modelName(for: .general))"
            + "  router=\(config.modelName(for: .router))"
            + "  spelling=\(config.modelName(for: .spelling))")
        let moved = config.transforms.filter { transform in
            transform.isPrompt && config.model(for: transform) != config.model()
        }
        for transform in moved {
            emit("      \(transform.name) → \(config.model(for: transform).described)")
        }

        if !config.transforms.isEmpty {
            emit("  · transforms        \(config.transforms.count) defined")
            let width = config.transforms.map(\.name.count).max() ?? 0
            for transform in config.transforms {
                let name = transform.name.padding(
                    toLength: max(width, 1), withPad: " ", startingAt: 0
                )
                emit("      \(name)  \(kind(of: transform))  \(bodyPath(transform))")
            }
        }

        // What "hey parrot" can reach. Printed even when `prompts:` is empty,
        // because the built-ins are the answer to "why did it do that" as
        // often as a prompt of your own is.
        let catalogue = Catalogue(transforms: config.transforms)
        emit("  ✓ capabilities      \(catalogue.capabilities.count) reachable by \"\(transcription.activationPhrase)\"")
        // What each one is made of, because the three cost wildly different
        // things — a model call, a process start, nothing at all — and because
        // a program reachable by voice is a program run by saying a sentence,
        // which this file says out loud everywhere else it happens.
        for capability in catalogue.capabilities {
            emit("      \(capability.kind)  \(capability.name) — \(capability.describedAs)")
        }
        // A transform with no description cannot be routed to, so it is not in
        // the list above. It still runs from a pipeline, where the name is
        // written down rather than said — which is the difference worth naming,
        // since "I wrote it and it does not answer" is otherwise a mystery.
        let unroutable = config.transforms.filter { $0.description.isEmpty }
        if !unroutable.isEmpty {
            emit("  · not by voice      \(unroutable.map(\.name).joined(separator: ", "))"
                + " — no description to match spoken words against")
        }
        // Not one of the capabilities above — the router reaches it by
        // answering ANY, not by picking it off the list — so it is printed
        // apart from them rather than pretending to be a catalogue entry.
        if config.freeForm {
            emit("      free-form  \(FreeForm.name) — \(FreeForm.prompt.description)")
        } else {
            emit("  · catch_all         off — an instruction no prompt covers is refused")
        }

        // How many rules each table holds, which nothing else says. The
        // catalogue above now lists tables like everything else — the router
        // reaches all three bodies — so this is no longer where you find out
        // that a `replace:` transform exists at all; it is where you find out
        // whether it has anything in it. A table that reads "0 rule(s)" is a
        // table whose pattern did not survive parsing.
        //
        // Tables only. A `command:` has no rules to count, and counting them
        // said "0 rule(s)" about a program — a line that read as a broken
        // table rather than as a script.
        let tables = config.transforms.filter(\.isTable)
        if !tables.isEmpty {
            emit("  · replace           \(tables.count) transform(s)")
            for table in tables {
                let rules = table.rules.count
                emit("      table     \(table.name) — \(rules) rule(s)"
                    + (table.description.isEmpty ? "" : ", \(table.description)"))
            }
        }

        // A `display:` is the one part of a transform that is neither matched
        // against nor run: it is what the menu bar says while the stage takes
        // its second. Nothing else can show you that you wrote it, and a
        // second of silence is exactly the symptom of having forgotten to.
        let announced = config.transforms.compactMap { transform in
            transform.displayLabel.map { (transform.name, $0) }
        }
        if !announced.isEmpty {
            emit("  · display           \(announced.count) transform(s) say what they are doing")
            for (name, label) in announced {
                emit("      \(name) — \"\(label)\"")
            }
        }

        // And `offer:` is the other part nothing else can show you. The pill is
        // up for a few seconds after a dictation, so a chip that failed to
        // appear — or a `key:` that was dropped for being two characters — is
        // read as the offer simply being short.
        let offered = config.transforms.filter(\.offer)
        if !offered.isEmpty {
            emit("  · offer             \(offered.count) transform(s) on the pill, after Vocabulary")
            // Correct's letter is not a transform's to lose, and the first chip
            // with a letter is the one that key runs. So a second chip asking
            // for the same letter is drawn with a keycap that never fires, and
            // that is invisible on a pill that fades out in a few seconds.
            var taken: Set<String> = ["C"]
            for transform in offered {
                let key = transform.offerKey
                let note: String
                if key.isEmpty {
                    note = " — no key, click only"
                } else if taken.contains(key) {
                    note = " — \(key), already taken; this chip is click only"
                } else {
                    note = " — \(key)"
                    taken.insert(key)
                }
                emit("      \(transform.name)\(note)")
            }
        }

        for prompt in config.prompts where prompt.description.isEmpty {
            emit("  ✗ prompt \"\(prompt.name)\" has no description; the router cannot pick it")
            ok = false
        }

        // LLM — what is where is in the models table above; this is the switch
        // that turns all of it off, and the pinning that only Ollama has.
        if config.llmEnabled {
            let router = config.model(for: .router)
            emit("  · models            \(config.modelsByName.count), default"
                + " \(config.defaultModelName)")
            if router.api == .ollama {
                emit("  · keep loaded       \(router.keepLoaded ? "on (\(router.model) pinned in RAM)" : "off (Ollama unloads after 5 min; +7-10s on a cold call)")")
            }
        } else {
            emit("  · models            none — nothing calls a model")
        }

        switch config.updates.afterDays {
        case ..<0:
            emit("  · updates           never checked")
        case 0:
            emit("  · updates           checked hourly, offered as soon as published")
        case let days:
            emit("  · updates           checked hourly, offered after \(days) day\(days == 1 ? "" : "s")")
        }

        // Environment
        let mic = Permissions.microphone
        emit("  \(mic == .granted ? "✓" : "✗") microphone        \(mic.label)")
        if mic != .granted { ok = false }

        if let device = AVCaptureDevice.default(for: .audio) {
            emit("  ✓ input device      \(device.localizedName)")
        } else {
            emit("  ✗ input device      none found")
            ok = false
        }

        // Accessibility deliberately isn't tested here.
        //
        // Asking `AXIsProcessTrustedWithOptions` from this command answers a
        // different question than it appears to. TCC attributes the check to the
        // *responsible* process, and for a binary exec'd from a shell that is the
        // terminal, not ParrotFlow. Measured on a Mac where the app had the grant
        // and was using it: launched by macOS it reported Granted, the same
        // bundle run from a terminal reported Not granted. A check that says no
        // when the answer is yes is worse than no check, so it reports where the
        // real answer lives instead — the app tests it at launch and logs it.
        if transcription.insertMode == .paste || !transcription.activationPhrases.isEmpty {
            emit("  · accessibility     needed, but not checkable from a terminal")
            emit("      macOS credits this check to the shell, not to ParrotFlow.")
            emit("      The app records the true value each time it starts:")
            emit("      grep 'launched —' \(Log.fileURL.path) | tail -1")
        }

        return finished(ok)
    }

    /// Which of the three bodies this is, in one column.
    private static func kind(of transform: Config.Transform) -> String {
        switch transform.body {
        case .prompt: return "prompt "
        case .replace: return "replace"
        case .command: return "command"
        }
    }

    /// The resolved absolute path of a body, or what it is instead of a file.
    ///
    /// `on PATH` is the honest answer for `command: sed`: nothing was resolved,
    /// the shell will look it up, and printing a path this made up would be a
    /// worse lie than saying so.
    private static func bodyPath(_ transform: Config.Transform) -> String {
        if let found = transform.resolvedSource { return shortened(found.path) }
        if case .command(let command) = transform.body {
            return "\(command.split(separator: " ").first ?? "") — on PATH"
        }
        return "inline"
    }

    /// `$HOME` written as `~`. The paths are long, the home half is the same on
    /// every line, and the part that differs is the part being read.
    private static func shortened(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// Digs the real cause out of the wrappers. Yams reports both its own parse
    /// failures and our validation errors as `DecodingError.dataCorrupted`, and
    /// the default `localizedDescription` for either is useless ("Yams.YamlError
    /// error 2"). `YamlError`'s own description carries the line and column.
    static func describe(_ error: Error) -> String {
        switch error {
        case let configError as ConfigError:
            return configError.localizedDescription

        case let yamlError as YamlError:
            return String(describing: yamlError)
                .trimmingCharacters(in: .whitespacesAndNewlines)

        case let decodingError as DecodingError:
            switch decodingError {
            case .dataCorrupted(let context):
                if let underlying = context.underlyingError {
                    return describe(underlying)
                }
                return context.debugDescription
            case .typeMismatch(_, let context), .valueNotFound(_, let context):
                let path = context.codingPath.map(\.stringValue).joined(separator: ".")
                return "\(path.isEmpty ? "" : path + ": ")\(context.debugDescription)"
            case .keyNotFound(let key, _):
                return "missing key \"\(key.stringValue)\""
            @unknown default:
                return decodingError.localizedDescription
            }

        default:
            return error.localizedDescription
        }
    }
}
