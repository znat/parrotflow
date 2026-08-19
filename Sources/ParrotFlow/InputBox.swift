import AppKit
import ApplicationServices

/// What is already in the field you are dictating into, and where the caret is.
///
/// The `input` pipeline stage is the only caller. It publishes what this
/// returns as `input.*`, so a later stage can tell appending from inserting —
/// a transcript joining the end of a paragraph wants different punctuation
/// from one dropped into the middle of a sentence.
///
/// ## Why this is not part of `context`
///
/// `Context` reads the screen *around* the box and is terminals-only, because
/// everywhere else that means walking a window's children. This reads the box
/// itself, which is the focused element, which is one call in every surface
/// `Surface` already handles — a native field, a browser, an Electron
/// composer. The two stages cover opposite halves of the same window and cost
/// completely different things.
///
/// They are also different disclosures. Naming `context` says "read my
/// terminal". It must not also mean "read what I have typed in every app I
/// dictate into", so this is a stage of its own and you turn it on by name.
enum InputBox {

    /// One read of the field, cut where the caret is.
    ///
    /// Three blocks rather than a string and an offset. An offset has to be
    /// applied by whoever reads it, and applying it wrong is silent — a caret
    /// off by the size of the window still points at a real character and the
    /// text still reads fine. Two strings cannot be misapplied.
    ///
    /// `selection` is the third block because dictating over a selection
    /// replaces it, and what is about to be replaced is worth seeing.
    struct Capture {
        /// What precedes the caret, or the start of the selection. Nil where
        /// the surface publishes no caret — see `text`.
        let before: String?
        /// What is selected, empty for a plain caret. Nil with `before`.
        let selection: String?
        /// What follows the caret, or the end of the selection. Nil with
        /// `before`.
        let after: String?
        /// The whole box, for a surface whose caret could not be located. A
        /// terminal publishes the screen as its value, so the box is dug out
        /// from between the rules the TUI draws and the offset does not survive
        /// that. Never set at the same time as `before`: two shapes, and which
        /// one you got says what the surface could answer.
        let text: String?
        /// The caret is at the very end with nothing selected. Computed before
        /// windowing, so a truncated capture still answers it correctly.
        let appending: Bool?
        /// The whole field, before `maxChars` cut anything out of it.
        let total: Int
        let truncated: Bool

        var chars: Int {
            (before?.count ?? 0) + (selection?.count ?? 0)
                + (after?.count ?? 0) + (text?.count ?? 0)
        }

        /// The caret and the text either side of it, as one short escaped
        /// string — nil on a surface that publishes no caret.
        ///
        /// This is what `join` decides from, and it was the one input to that
        /// decision the log did not record. A leading space it added could be
        /// traced to the rule that added it, but not to the neighbourhood the
        /// rule read, so the two states that pick different rules — a stop
        /// behind the caret, a newline behind it — looked identical in the log.
        /// Twenty characters a side covers a sentence end, a newline, a bracket
        /// and a hyphen, which is everything the rules look at.
        ///
        /// Both edges in one string with the caret marked, rather than two
        /// fields. The decision is about what sits either side of one point.
        var neighbourhood: String? {
            guard let before, let after else { return nil }
            let edge = 20
            let middle: String
            if let selection, !selection.isEmpty {
                middle = "\u{27E6}" + escaped(String(selection.prefix(edge)))
                    + (selection.count > edge ? "\u{2026}" : "") + "\u{27E7}"
            } else {
                middle = "\u{2038}"
            }
            return (before.count > edge ? "\u{2026}" : "")
                + escaped(String(before.suffix(edge)))
                + middle
                + escaped(String(after.prefix(edge)))
                + (after.count > edge ? "\u{2026}" : "")
        }

        /// Whitespace as its escape, so the neighbourhood stays on one log
        /// line. A newline is the difference between two of `join`'s rules, so
        /// it has to be visible rather than acted on. U+2028 and U+2029 are
        /// escaped too: both render as a line break and neither is caught by
        /// `\n`/`\r`.
        private func escaped(_ part: String) -> String {
            part.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\t", with: "\\t")
                .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
                .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        }
    }

    /// Why a read did not happen. Published as `input.declined`, because a box
    /// that was empty and a box nobody was allowed to look at are different
    /// answers and a condition should be able to tell them apart.
    enum Declined: String, Error {
        case noPermission = "accessibility is not granted"
        case noApp = "the pipeline was not told which app this is for"
        case nothingFocused = "nothing is focused"
        case unreadable = "the focused element publishes no value"
        case noInputBox = "no input box found between the rules this terminal draws"
        case noPress = "nothing was captured when the hotkey went down"
        case reading = "the field was still being read when this stage was reached"
    }

    // MARK: - The capture, which happens when the hotkey goes down

    /// Read at the press for the same reason `Context` is: by the time the
    /// pipeline runs, focus may be somewhere else, and "what was in the box you
    /// were typing in" is not answerable from there.
    struct Press {
        let outcome: Result<Capture, Declined>
        let ms: Double
    }

    /// One capture per press, by press run.
    ///
    /// Not one slot. Dictations overlap — a second press while the first is
    /// still being transcribed is an ordinary thing to do, and the app already
    /// keys `screenAtPress`, `pressesInFlight` and `cancelledPresses` the same
    /// way. With one slot the second press cleared what the first dictation had
    /// not read yet, so the first got `noPress` and then, once the second read
    /// finished, the second field.
    ///
    /// **A run is only ever in here between `beginPress` and `forget`.** The
    /// entry is reserved on the main thread at the press and removed by
    /// `dictationEnded`, so a read that finishes after its dictation is over —
    /// the accessibility value has been observed at 237k characters — finds no
    /// entry to write into and is dropped. That is what keeps this from
    /// growing, and it is the same invariant `pressesInFlight` already rests
    /// on: every way a dictation ends goes through `dictationEnded`.
    ///
    /// No cap, deliberately. A cap has to evict something, and the only thing
    /// it could evict is the oldest run — which in an overlap is a dictation
    /// still in flight. A bound that corrupts live state is worse than no
    /// bound.
    private static let pressLock = NSLock()
    nonisolated(unsafe) private static var presses: [Int: Press] = [:]

    static func capture(for run: Int) -> Press? {
        pressLock.lock()
        defer { pressLock.unlock() }
        return presses[run]
    }

    /// Reserve this run's slot. **Main thread, at the press**, before the read
    /// is dispatched: it is what says the run is live, so a read that comes
    /// back late has something to check itself against.
    static func beginPress(_ run: Int) {
        pressLock.lock()
        presses[run] = Press(outcome: .failure(.reading), ms: 0)
        pressLock.unlock()
    }

    /// This dictation is over, however it ended.
    static func forget(_ run: Int) {
        pressLock.lock()
        presses.removeValue(forKey: run)
        pressLock.unlock()
    }

    static func isConfigured(in config: Config) -> Bool {
        config.transcription.pipelines.values.contains { $0.stages.contains(.input) }
    }

    /// Call **after** recording has started, off the main thread, and after
    /// `beginPress` for the same run. The element was resolved on the main
    /// thread at press and must not be re-resolved.
    static func capturePress(run: Int, app: Pipeline.App?, element: AXUIElement?) {
        guard let element else { return }

        let started = CFAbsoluteTimeGetCurrent()
        let outcome = read(app: app, from: element)
        let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000

        pressLock.lock()
        // Only into a slot that is still reserved. No slot means the dictation
        // ended while this read was running, and writing then would put back an
        // entry nothing will remove again.
        let live = presses[run] != nil
        if live { presses[run] = Press(outcome: outcome, ms: ms) }
        pressLock.unlock()

        guard live else {
            Log.write(String(
                format: "input: a %.0fms read finished after its dictation ended; dropped", ms))
            return
        }

        switch outcome {
        case .success(let capture):
            Log.write(String(
                format: "input: captured %d of %d chars at press in %.0fms, %@",
                capture.chars, capture.total, ms,
                capture.before == nil ? "caret unknown"
                    : (capture.appending == true ? "appending" : "inserting")))
            // Press time and pipeline time are the same snapshot, seconds
            // apart. Anything typed between them is invisible to both, and a
            // pipeline with no `input` stage still leaves the evidence here.
            if let neighbourhood = capture.neighbourhood {
                Log.write("    caret: \(neighbourhood)")
            }
        case .failure(let why):
            Log.write(String(
                format: "input: nothing captured at press (%@) in %.0fms", why.rawValue, ms))
        }
    }

    /// How much of the field a later stage is allowed to see. `Context.maxChars`
    /// reused rather than picked again — one number for "how much of your screen
    /// may leave it".
    static var maxChars: Int { Context.maxChars }

    /// Read whatever is focused right now, or say why not. The door for
    /// `--peek`; the stage takes `pressCapture`.
    static func read(app: Pipeline.App?) -> Result<Capture, Declined> {
        guard Permissions.accessibility == .granted else { return .failure(.noPermission) }
        guard let element = SelectionReader.focusedElement(),
              !SelectionReader.isOurs(element) else { return .failure(.nothingFocused) }
        return read(app: app, from: element)
    }

    /// The same read, of an element the caller already has.
    ///
    /// Two surfaces, and the split is the same one `Surface` makes. A terminal's
    /// accessibility value is the whole screen, so the box has to be dug out of
    /// it between the rules the TUI draws — and what comes back is text with no
    /// caret in it, because the offset the surface publishes is into the screen
    /// and there is no honest way to carry it across that extraction. Everywhere
    /// else the value *is* the box and the selection is a range into it.
    static func read(
        app: Pipeline.App?, from element: AXUIElement
    ) -> Result<Capture, Declined> {
        guard Permissions.accessibility == .granted else { return .failure(.noPermission) }
        guard let app else { return .failure(.noApp) }
        guard !SelectionReader.isOurs(element) else { return .failure(.nothingFocused) }
        guard let value = SelectionReader.visibleText(of: element) else {
            return .failure(.unreadable)
        }

        if AppProfile.of(app).readsPane {
            guard let box = SelectionReader.joinedInputBox(in: value) else {
                return .failure(.noInputBox)
            }
            return .success(Capture(
                before: nil, selection: nil, after: nil,
                text: String(box.suffix(maxChars)), appending: nil,
                total: box.count, truncated: box.count > maxChars))
        }

        let total = value.count
        guard let range = SelectionReader.selectedRange(of: element),
              range.location != NSNotFound, range.location >= 0,
              let span = Range(NSRange(location: range.location,
                                       length: max(0, range.length)), in: value)
        else {
            return .success(Capture(
                before: nil, selection: nil, after: nil,
                text: String(value.suffix(maxChars)), appending: nil,
                total: total, truncated: total > maxChars))
        }

        let cut = split(value, at: span, limit: maxChars)
        return .success(Capture(
            before: cut.before, selection: cut.selection, after: cut.after,
            text: nil, appending: cut.appending,
            total: total, truncated: cut.truncated))
    }

    /// The field cut into three at the selection, each side capped on its own.
    ///
    /// Each side keeps the end nearest the caret and gets half the budget. A
    /// single window centred on the caret would let a long tail crowd out the
    /// text immediately before it, which is the half a dictated sentence is
    /// being joined to.
    static func split(
        _ value: String, at span: Range<String.Index>, limit: Int
    ) -> (before: String, selection: String, after: String,
          appending: Bool, truncated: Bool) {
        let before = String(value[value.startIndex..<span.lowerBound])
        let selection = String(value[span])
        let after = String(value[span.upperBound...])
        let half = limit / 2
        return (String(before.suffix(half)),
                String(selection.prefix(limit)),
                String(after.prefix(half)),
                after.isEmpty && selection.isEmpty,
                before.count > half || after.count > half || selection.count > limit)
    }

}
