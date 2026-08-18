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
    }

    // MARK: - The capture, which happens when the hotkey goes down

    /// Read at the press for the same reason `Context` is: by the time the
    /// pipeline runs, focus may be somewhere else, and "what was in the box you
    /// were typing in" is not answerable from there.
    struct Press {
        let outcome: Result<Capture, Declined>
        let ms: Double
    }

    private static let pressLock = NSLock()
    nonisolated(unsafe) private static var press: Press?

    /// Which press the stored capture belongs to. Two reads can be in flight at
    /// once and nothing makes them finish in order — see `Context.pressGeneration`,
    /// which this mirrors deliberately rather than sharing, so one stage being
    /// configured never starts the other one's read.
    nonisolated(unsafe) private static var pressGeneration = 0

    static var pressCapture: Press? {
        pressLock.lock()
        defer { pressLock.unlock() }
        return press
    }

    static func isConfigured(in config: Config) -> Bool {
        config.transcription.pipelines.values.contains { $0.stages.contains(.input) }
    }

    /// Call **after** recording has started, off the main thread. The element
    /// was resolved on the main thread at press and must not be re-resolved.
    static func capturePress(app: Pipeline.App?, element: AXUIElement?) {
        pressLock.lock()
        pressGeneration += 1
        let mine = pressGeneration
        press = nil
        pressLock.unlock()
        guard let element else { return }

        let started = CFAbsoluteTimeGetCurrent()
        let outcome = read(app: app, from: element)
        let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000

        pressLock.lock()
        let newest = mine == pressGeneration
        if newest { press = Press(outcome: outcome, ms: ms) }
        pressLock.unlock()

        guard newest else {
            Log.write(String(
                format: "input: a %.0fms read was overtaken by a newer press; dropped", ms))
            return
        }
        switch outcome {
        case .success(let capture):
            Log.write(String(
                format: "input: captured %d of %d chars at press in %.0fms, %@",
                capture.chars, capture.total, ms,
                capture.before == nil ? "caret unknown"
                    : (capture.appending == true ? "appending" : "inserting")))
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
