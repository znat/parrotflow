import AppKit
import ApplicationServices

/// What is on screen around the field you are dictating into.
///
/// The `context` pipeline stage is the only caller. It publishes what this
/// returns as `context.*`, so a later stage — a `command:` script, a prompt —
/// can read the conversation the transcript is about to join.
///
/// ## Terminals only, for now
///
/// A terminal is the one surface where this is nearly free. Its accessibility
/// value *is* the visible screen — `Surface.Kind.screen` exists for exactly that
/// reason — so the whole context is one AX call, the same call the app already
/// makes to edit a line in place.
///
/// Everywhere else it is not one call. A Slack composer publishes its own
/// contents and nothing above it, so the messages would have to come from
/// walking the window's children: hundreds of IPC round trips, per app, for a
/// flat run of text nodes with no author attached. That may still be worth
/// building. It is not the same feature, and shipping it behind the same name
/// would make one stage mean "cheap" in one app and "expensive" in the next.
///
/// So a non-terminal app is declined, out loud, rather than half-served.
enum Context {

    /// One read of the screen.
    struct Capture {
        /// What was on screen, minus the input box, tail-trimmed to a size a
        /// later stage can afford to put in a prompt.
        let text: String
        /// Whether `maxChars` cut anything off the front.
        let truncated: Bool

        var chars: Int { text.count }
        var lines: Int { text.isEmpty ? 0 : text.components(separatedBy: "\n").count }
    }

    /// Why a read did not happen. Logged, and published as `context.declined`,
    /// because a stage that quietly returns nothing is indistinguishable from a
    /// screen that was genuinely empty — and only one of those is answerable.
    enum Declined: String, Error {
        case noPermission = "accessibility is not granted"
        case noApp = "the pipeline was not told which app this is for"
        case notATerminal = "not a terminal; reading other apps needs a tree walk that does not exist yet"
        case appChanged = "the frontmost app is no longer the one dictated into"
        case nothingFocused = "nothing is focused"
        case unreadable = "the focused element publishes no value"
        case empty = "the screen has nothing on it above the input box"
        case noPress = "nothing was captured when the hotkey went down"
    }

    // MARK: - The capture, which happens when the hotkey goes down

    /// What was on screen when the hotkey went down, and which pane it was.
    ///
    /// The press is the only moment where the pane is *known*. Everything after
    /// it is observation: by the time the pipeline runs there has been a
    /// transcription and possibly a model call, and focus may be somewhere else
    /// entirely. Reading then answers "what is on screen now", which is a
    /// different question from "what were you looking at when you decided to
    /// say this".
    ///
    /// `element` is kept so a later guard can ask whether the transcript is
    /// still going where it was aimed. Nothing asks yet — see the note on
    /// `capture` about the clipboard fallback that would.
    struct Press {
        let element: AXUIElement
        /// The whole result, not just the capture. A press that declined has a
        /// reason, and the stage publishes that reason — collapsing it to nil
        /// here would turn six different answers into "nothing happened".
        let outcome: Result<Capture, Declined>
        /// Wall-clock cost of the read, so the press path's bill is on record
        /// rather than assumed. Measured at ~1ms on a small pane and 36–39ms on
        /// a long scrollback, which is why this runs off the main thread.
        let ms: Double
    }

    private static let pressLock = NSLock()
    nonisolated(unsafe) private static var press: Press?

    static var pressCapture: Press? {
        pressLock.lock()
        defer { pressLock.unlock() }
        return press
    }

    /// Whether any pipeline in this config names the stage.
    ///
    /// The gate on the whole thing. A screen read on every hotkey press is not
    /// a cost to impose on people who never asked for context, and `context` is
    /// not in any default, so most configs answer false here and pay nothing.
    static func isConfigured(in config: Config) -> Bool {
        config.transcription.pipelines.values.contains { $0.stages.contains(.context) }
    }

    /// Read the screen at press. Call **after** recording has started, off the
    /// main thread.
    ///
    /// The element comes from the caller because it was resolved on the main
    /// thread at press, alongside the selection snapshot. Re-resolving it here
    /// would ask the same question a few milliseconds later and lose the one
    /// property this capture exists for.
    ///
    /// Any previous press is cleared first, so a stale capture from the last
    /// dictation can never be published as if it were this one.
    static func capturePress(app: Pipeline.App?, element: AXUIElement?) {
        pressLock.lock(); press = nil; pressLock.unlock()
        guard let element else { return }

        let started = CFAbsoluteTimeGetCurrent()
        let outcome = read(app: app, from: element)
        let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000

        pressLock.lock()
        press = Press(element: element, outcome: outcome, ms: ms)
        pressLock.unlock()
        switch outcome {
        case .success(let capture):
            Log.write(String(
                format: "context: captured %d chars at press in %.0fms", capture.chars, ms
            ))
        case .failure(let why):
            Log.write(String(
                format: "context: nothing captured at press (%@) in %.0fms", why.rawValue, ms
            ))
        }
    }

    /// How much of the screen a later stage is allowed to see.
    ///
    /// The tail, not the head: the rows nearest the input box are the ones the
    /// sentence is answering. 2000 is `Surface.maxScreenContent`, reused rather
    /// than picked again — that number is already the app's judgement about how
    /// much terminal text is worth carrying around, and two constants for one
    /// idea drift apart.
    static let maxChars = 2000

    /// Read whatever is focused right now, or say why not.
    ///
    /// **Not what the stage publishes.** The stage takes `pressCapture`. This is
    /// the door for `--peek`, where there is no press to take a capture from and
    /// the question really is "what would you read off this screen".
    ///
    /// `app` is the one captured when the hotkey went down, and a mismatch
    /// against what is in front *now* declines. `Pipeline.App` documents why the
    /// window in front is not reliably the window that was dictated into, and
    /// reading the wrong window is worse than reading none — it would hand a
    /// prompt somebody else's screen.
    static func read(app: Pipeline.App?) -> Result<Capture, Declined> {
        guard Permissions.accessibility == .granted else { return .failure(.noPermission) }
        guard let app else { return .failure(.noApp) }
        guard Destination.terminalName(of: app) != nil else { return .failure(.notATerminal) }

        let front = NSWorkspace.shared.frontmostApplication
        let frontID = front?.bundleIdentifier ?? ""
        guard frontID == app.bundleID else { return .failure(.appChanged) }

        guard let element = SelectionReader.focusedElement(),
              !SelectionReader.isOurs(element) else { return .failure(.nothingFocused) }
        return read(app: app, from: element)
    }

    /// The same read, of an element the caller already has.
    ///
    /// The press capture takes this door, and it must not re-resolve focus: the
    /// element was settled on the main thread at press, and that pane *is* the
    /// answer this capture exists to preserve.
    ///
    /// No frontmost-app check here either. At press the app in front is the app
    /// the caller was handed, so re-checking would compare it against itself or
    /// against whatever won a race.
    ///
    /// ## Why the pane is not checked again later
    ///
    /// It could be. `Press.element` is kept for exactly that. But the check
    /// belongs at the paste, not here: if focus has moved on, the honest
    /// response is to stop pasting and put the transcript on the clipboard —
    /// where it goes wrong today is the *text* landing in a pane you left, not
    /// the context. That guard is worth building and is not this stage's job.
    ///
    /// Until it exists, a capture from the pane you dictated into is still the
    /// right one to publish. It is the pane you meant, whatever the paste does.
    static func read(
        app: Pipeline.App?, from element: AXUIElement
    ) -> Result<Capture, Declined> {
        guard Permissions.accessibility == .granted else { return .failure(.noPermission) }
        guard let app else { return .failure(.noApp) }
        guard Destination.terminalName(of: app) != nil else { return .failure(.notATerminal) }
        guard !SelectionReader.isOurs(element) else { return .failure(.nothingFocused) }
        guard let value = SelectionReader.visibleText(of: element) else {
            return .failure(.unreadable)
        }

        let above = aboveInputBox(in: value)
        guard !above.isEmpty else { return .failure(.empty) }

        let (text, truncated) = tail(of: above, limit: maxChars)
        return .success(Capture(text: text, truncated: truncated))
    }

    // MARK: - Cutting the screen up

    /// Everything above the input box.
    ///
    /// The box is between the last two rules the TUI draws — the same reading
    /// `SelectionReader.joinedInputBox` uses, and deliberately the same one: if
    /// the two disagreed about where the box starts, the context would either
    /// repeat the half-typed line or eat the last line of output.
    ///
    /// The box itself is left out on purpose. It holds the transcript that is
    /// being dictated right now, which the pipeline already has as `text` — and
    /// a stage that saw the same sentence twice, once as its input and once as
    /// "context", would have every reason to think it was being asked about a
    /// quotation.
    ///
    /// With no rules drawn — a bare shell rather than a TUI — the last non-empty
    /// row is the prompt line and is dropped for the same reason.
    static func aboveInputBox(in screen: String) -> String {
        var rows = screen.components(separatedBy: "\n")
        let rules = rows.indices.filter { SelectionReader.isBorder(rows[$0]) }

        if rules.count >= 2 {
            rows = Array(rows[..<rules[rules.count - 2]])
        } else if let last = rows.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            rows = Array(rows[..<last])
        }

        // Trailing blank rows are padding the TUI drew, not silence anyone
        // meant. Leading ones are trimmed by the same pass so the count in
        // `context.lines` is rows of content.
        while let last = rows.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            rows.removeLast()
        }
        while let first = rows.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            rows.removeFirst()
        }
        return rows.joined(separator: "\n")
    }

    /// The last `limit` characters, cut at a row boundary.
    ///
    /// Mid-row would be worse than useless: a truncated first line reads as a
    /// sentence somebody said rather than as a fragment, and there is nothing in
    /// the string to say which. Cutting on a newline makes the loss visible.
    static func tail(of text: String, limit: Int) -> (text: String, truncated: Bool) {
        guard text.count > limit else { return (text, false) }
        let rows = text.components(separatedBy: "\n")
        var kept: [String] = []
        var size = 0
        for row in rows.reversed() {
            // +1 for the newline that rejoins it.
            let cost = row.count + 1
            if size + cost > limit, !kept.isEmpty { break }
            kept.append(row)
            size += cost
        }
        return (kept.reversed().joined(separator: "\n"), true)
    }
}
