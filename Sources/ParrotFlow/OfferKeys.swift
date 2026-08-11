import AppKit
import Carbon.HIToolbox

/// Takes the offer's letters and Escape while the offer is on screen, and gives
/// them back the moment it is not.
///
/// ## Why this is a tap and not a monitor
///
/// The pill is a `nonactivatingPanel` and never takes keyboard focus — that is
/// deliberate, because it appears while you are typing into somebody else's
/// window. `NSEvent.addGlobalMonitorForEvents` can hear a key in that state but
/// cannot swallow one, so a letter on a chip would also be typed into your
/// document: press `C` to correct and you get the correction panel and a stray
/// `c` in the sentence it is about to correct.
///
/// A `CGEvent` tap is the only way to consume a key without holding focus. It
/// needs Accessibility, which the app already requires.
///
/// ## What keeps it safe
///
/// Swallowing keys system-wide is a thing to be nervous about, so it is fenced
/// three ways. It only exists while the offer is up — created on the way in and
/// destroyed on the way out. It only ever consumes Escape and the letters the
/// offer has claimed, and it passes everything else through untouched. And it
/// carries its own expiry: if the object that owns it somehow never calls
/// `stop`, the next key past the deadline tears the tap down and goes through.
/// The failure mode is a key that works, not a keyboard that stops.
final class OfferKeys {

    enum Key: Equatable {
        /// Escape, or Return. Both end the offer; only Escape is consumed.
        case dismiss
        /// Run the command this letter belongs to.
        case letter(String)
    }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var handler: ((Key) -> Void)?
    private var expiry = Date.distantPast
    /// The letters the offer has claimed, uppercased. Empty is allowed — then
    /// only Escape and Return are watched.
    private var letters: Set<String> = []

    var isRunning: Bool { tap != nil }

    /// Move the deadline, after something said the offer is not over yet.
    ///
    /// The tap itself is left exactly as it is — the same letters, the same
    /// handler. Only the backstop moves, and it has to move with the offer: a
    /// tap still holding `C` for a pill the pointer is holding open, with an
    /// expiry from before it was held, would give the letter back to the app
    /// while the chip that claims it is still on screen.
    ///
    /// Does nothing when no tap is running. The offer can be up without one —
    /// the keys wait for a dictation that is still going — and there is no
    /// deadline to move until `start` gives it one.
    func extend(until: Date) {
        guard tap != nil else { return }
        expiry = until
    }

    /// Begin taking the keys, until `until` at the latest.
    ///
    /// `letters` must already be uppercased, which is the shape `Config` stores
    /// a `key:` in: the comparison below uppercases what was typed, so a
    /// lowercase entry here would claim a letter and then never match it.
    func start(until: Date, letters: Set<String>, onKey: @escaping (Key) -> Void) {
        stop()
        self.letters = letters
        guard AXIsProcessTrusted() else {
            Log.write("offer keys: accessibility is not granted; the keys are not taken")
            return
        }
        handler = onKey
        expiry = until

        // The two "the system switched your tap off" events are subscribed to
        // as well as the keys. They arrive through the tap itself, so a tap
        // that does not ask for them cannot be told it is dead.
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.tapDisabledByTimeout.rawValue)
            | (1 << CGEventType.tapDisabledByUserInput.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let keys = Unmanaged<OfferKeys>.fromOpaque(refcon).takeUnretainedValue()
                return keys.handle(type, event)
            },
            // Unretained, and safe because the tap is torn down in `stop`,
            // which `deinit` also calls: the callback cannot outlive the object
            // it points at.
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.write("offer keys: could not create the tap; the keys are not taken")
            handler = nil
            return
        }

        // On the main run loop, so `handle` runs on the main thread and can
        // touch the same state `start` and `stop` do.
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        Log.write("offer keys: taking \(letters.sorted().joined()) and escape")
    }

    /// Give the keyboard back. Safe to call when nothing is running, and safe
    /// to call twice — every path that ends the offer calls it.
    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        source = nil
        handler = nil
        letters = []
        expiry = .distantPast
    }

    deinit { stop() }

    private func handle(
        _ type: CGEventType, _ event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        // The system switches a tap off if it ever takes too long, and says so
        // through the tap itself. Left unhandled, the tap is silently dead and
        // the offer's keys stop working with nothing in the log.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Log.write("offer keys: the tap was switched off; re-enabling it")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        // The backstop. Nothing should reach here after the offer has gone, and
        // if it does the key goes through and the tap goes away.
        guard Date() < expiry else {
            DispatchQueue.main.async { [weak self] in self?.stop() }
            return Unmanaged.passUnretained(event)
        }

        // A modified key is somebody else's shortcut — ⌘C copies, ⇧F types a
        // capital F, ⌃C interrupts. Only the bare key belongs to the offer, and
        // checking first means a letter with a modifier on it is never even
        // considered.
        let claimed: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        guard event.flags.isDisjoint(with: claimed) else {
            return Unmanaged.passUnretained(event)
        }

        // Letters and Escape are taken. Return is only watched.
        //
        // The arrows and space were here and are gone. Selecting with one key
        // and confirming with another is a menu, and this is two buttons: the
        // letter on each says how to press it, and the mouse says the same
        // thing again. Every key taken from the system has to earn it, and a
        // selection nobody needed did not.
        let key: Key
        var take = true
        switch Int(event.getIntegerValueField(.keyboardEventKeycode)) {
        case kVK_Escape:
            key = .dismiss
        case kVK_Return, kVK_ANSI_KeypadEnter:
            // Return means you are sending what was dictated, which is the end
            // of the whole errand — so the offer goes at once rather than
            // sitting over your shoulder while you read the reply. Passed
            // through, never taken: this is the key the dictation was for.
            key = .dismiss
            take = false
        default:
            guard !letters.isEmpty,
                  let typed = NSEvent(cgEvent: event)?.charactersIgnoringModifiers?.uppercased(),
                  letters.contains(typed)
            else { return Unmanaged.passUnretained(event) }
            key = .letter(typed)
        }

        // Handed to the next turn of the main loop rather than run here. What
        // the handler does opens panels and calls models, and a tap that takes
        // too long inside its own callback is the tap macOS switches off.
        let handler = self.handler
        DispatchQueue.main.async { handler?(key) }
        return take ? nil : Unmanaged.passUnretained(event)
    }
}
