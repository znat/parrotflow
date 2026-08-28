import AppKit
import ApplicationServices

/// Notices when you select words ParrotFlow just wrote, so the offer can come
/// back without being asked for.
///
/// ## Why this is events and not an observer
///
/// The obvious build is an `AXObserver` on the field, listening for
/// `kAXSelectedTextChangedNotification`. It is also the only thing in this app
/// that would need one — observer lifetimes, per-app registration, teardown on
/// a window that closed while nobody was looking.
///
/// None of that is necessary, because a selection cannot appear on its own. It
/// is made by dragging the mouse, by holding shift and pressing an arrow, or by
/// ⌘A — and every one of those is an event `NSEvent` already hands out. So the
/// question is asked at the three moments the answer can have changed, and
/// never in between. An idle app is watching nothing.
///
/// ## Why the read is cheap
///
/// `kAXSelectedTextAttribute` returns the selected substring and nothing else.
/// The expensive read in this app is `AXValue` — Outlook's message pane
/// measured 395,489 characters, and `CaretAnchor` is careful about it for that
/// reason. This is not that read. What comes back is what you highlighted.
///
/// ## What it refuses
///
/// It fires for one thing: a selection that is part of what ParrotFlow last
/// wrote. Anything else is somebody selecting text to copy it, delete it, drag
/// it or type over it, which is most of what selecting is for — and a surface
/// that appeared every time would be wrong far more often than right.
///
/// It also never fires twice for the same words. Dismiss the offer and the
/// selection is usually still sitting there, so the next arrow key would put it
/// straight back up. `offered` is what stops that: the pill returns when you
/// select something, not while you have something selected.
final class SelectionWatch {

    /// A selection worth offering on: the words, and the field they are in.
    var onSelection: ((SelectionReader.Selection) -> Void)?

    /// What the selection has to be part of. Nil stops the watch answering —
    /// it is set from `lastTranscript`, which is empty until something is said.
    private var haystack: String?
    /// The field the last dictation landed in.
    ///
    /// This is what makes a short selection safe. "know" is four characters and
    /// is inside half the sentences anybody dictates, but "know" *in the box
    /// those words were written into* is the word you just said — so the
    /// question is asked about the field rather than about the length.
    private var field: AXUIElement?
    private var monitors: [Any] = []
    /// The last selection handed out, so it is not handed out again.
    private var offered: String?
    /// A drag ends in one event; shift-arrow makes one per keypress. Reading on
    /// every one is cheap but pointless, and the second read of a growing
    /// selection is a different string, so `offered` would not stop it.
    private var lastLook = Date.distantPast

    var isRunning: Bool { !monitors.isEmpty }

    /// Watch for selections inside `text`.
    ///
    /// Called again with the new transcript every time one is written — a
    /// rewrite changes what the words are, and the offer has to follow them.
    func start(over text: String, in element: AXUIElement?) {
        haystack = text
        field = element
        offered = nil
        guard monitors.isEmpty else { return }
        guard Permissions.accessibility == .granted else {
            Log.write("reselect: accessibility is not granted; selections cannot be seen")
            return
        }

        // Mouse up rather than down: the drag is over and the selection is
        // final. Key up for the same reason, and it covers shift-arrow, ⌘A and
        // shift-click's keyboard half in one mask.
        let mask: NSEvent.EventTypeMask = [.leftMouseUp, .keyUp]
        let look: (NSEvent) -> Void = { [weak self] _ in self?.look() }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: look) {
            monitors.append(global)
        }
        // The local one is not for our own windows — it is for the moment our
        // panel has focus and the selection behind it is still the one being
        // talked about. Passing the event straight back leaves it untouched.
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            look(event)
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        haystack = nil
        field = nil
        offered = nil
    }

    deinit { stop() }

    /// The whole of the work, at the three moments a selection can have changed.
    private func look() {
        guard let haystack else { return }
        // 40ms, which is under the fastest key repeat and over the cost of one
        // small accessibility read. Held down, an arrow key would otherwise ask
        // this on every repeat while the selection is still growing.
        guard Date().timeIntervalSince(lastLook) > 0.04 else { return }
        lastLook = Date()

        // `offered` survives exactly as long as the selection it was about. Let
        // go of those words — click away, select something else — and the same
        // words chosen again are a new request, not the old one still standing.
        //
        // It was cleared only when the watch restarted, which meant selecting a
        // term, clicking off it, and selecting it again did nothing at all. The
        // rule it was written for is narrower than that: the pill must not come
        // back while a selection it has already answered is still sitting there.
        guard let selection = SelectionReader.snapshot(),
              let field, let element = selection.element, CFEqual(field, element)
        else {
            offered = nil
            return
        }
        // In the field the words were written into. Everything else this could
        // check — how long the selection is, how unusual — is a proxy for this
        // one question, and a bad one: a floor high enough to rule out "the"
        // ruled out "know", which is a word somebody selects precisely because
        // they want it fixed.
        let text = selection.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= Self.floor, haystack.contains(text) else {
            offered = nil
            return
        }
        guard text != offered else { return }

        offered = text
        Log.write("reselect: \"\(text.prefix(60))\" is part of the last dictation")
        onSelection?(selection)
    }

    /// One letter is somebody part-way through a selection, or fixing a typo
    /// by hand. Two is a word. Nothing above this is ruled out by length —
    /// `field` is what does the ruling out.
    static let floor = 2
}

extension String {
    /// Nothing but whitespace, which every path that offers over text has to
    /// rule out before it asks a model or raises a surface about it.
    var isBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
