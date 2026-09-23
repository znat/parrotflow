import AppKit

/// Looking past the top or bottom of a list scrolls it — a little, once.
///
/// When the gaze crosses into the edge of a scrollable area, or just past it,
/// the area moves a few lines that way. Then nothing, until the gaze has gone
/// back to the middle: one nudge per crossing, never a continuous scroll. You
/// read to the bottom of what is visible, the next few lines come up, you
/// read those.
///
/// Three guards, each for a measured or known problem:
///
/// - **The tracker only.** A stale gaze falls back to the mouse everywhere
///   else in the app; here that would scroll wherever the pointer rests.
/// - **A short dwell and a cooldown.** The eyes jitter across an edge — 2.8 cm
///   a frame was measured for the raw gaze — and a single crossing would
///   otherwise fire two or three times.
/// - **Not while the hand is on the mouse.** Chromium routes a wheel by where
///   the cursor is, so a scroll puts the cursor there for a moment and back.
///   That is invisible when nobody is holding the mouse and infuriating when
///   somebody is.
@MainActor
final class GazeScroll {
    /// Stamped on the scrolls this posts, so the hotkey can tell them from yours.
    static let mark: Int64 = 0x5046_4753
    static let shared = GazeScroll()

    private enum Edge { case top, bottom }

    private var timer: Timer?
    private var file = ""
    private var lines = 4

    private var area: CGRect?
    private var edge: Edge?
    private var edgeSince = Date.distantPast
    private var armed = true
    private var lastNudge = Date.distantPast
    private var lastMouse = CGPoint.zero
    private var mouseMoved = Date.distantPast

    func start(file: String, lines: Int) {
        stop()
        guard lines > 0, !file.isEmpty else { return }
        self.file = file
        self.lines = lines
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        Log.write("gaze scroll: on — \(lines) lines when the gaze crosses the top or bottom of a list")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        area = nil
        edge = nil
        armed = true
    }

    private func tick() {
        // A held modifier is a dictation or an action being spoken. Seen 09-22:
        // a scroll then made the hotkey read the press as a shortcut and drop it.
        let held = CGEventSource.flagsState(.combinedSessionState)
            .intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift])
        guard held.isEmpty else { return }
        let now = Date()
        let mouse = Gaze.mouse()
        if hypot(mouse.x - lastMouse.x, mouse.y - lastMouse.y) > 3 {
            lastMouse = mouse
            mouseMoved = now
        }
        guard now.timeIntervalSince(mouseMoved) > 1.0 else { return }

        let gaze = Gaze.now(file: file)
        guard gaze.source == .tracker else {
            edge = nil
            return
        }
        let at = gaze.location

        // The area is kept while the gaze is over it or just past its top or
        // bottom — "just past" is the whole point — and looked up again once
        // the gaze has clearly gone somewhere else.
        let reach: CGFloat = 120
        if let known = area,
           at.x >= known.minX, at.x <= known.maxX,
           at.y >= known.minY - reach, at.y <= known.maxY + reach {
        } else {
            area = ScreenTargets.scrollArea(at: at)?.frame
            edge = nil
        }
        guard let box = area else { return }

        let band = min(max(box.height * 0.10, 40), 90)
        let crossing: Edge?
        if at.y < box.minY + band { crossing = .top }
        else if at.y > box.maxY - band { crossing = .bottom }
        else { crossing = nil }

        guard let crossing else {
            // Back in the middle: the next crossing may scroll again.
            armed = true
            edge = nil
            return
        }
        if crossing != edge {
            edge = crossing
            edgeSince = now
            return
        }
        guard armed,
              now.timeIntervalSince(edgeSince) >= 0.2,
              now.timeIntervalSince(lastNudge) >= 0.6 else { return }

        nudge(at: CGPoint(x: at.x, y: min(max(at.y, box.minY + 20), box.maxY - 20)),
              down: crossing == .bottom)
        armed = false
        lastNudge = now
        Log.write("gaze scroll: \(crossing == .bottom ? "down" : "up") \(lines) lines"
                  + " at \(Int(at.x)),\(Int(at.y))")
    }

    /// A few lines, where the eyes are. The pointer goes there for the scroll
    /// and straight back, as `ScreenAction.wheel` does.
    private func nudge(at point: CGPoint, down: Bool) {
        let wasAt = Gaze.mouse()
        CGWarpMouseCursorPosition(point)
        usleep(30_000)
        let source = CGEventSource(stateID: .combinedSessionState)
        if let event = CGEvent(
            scrollWheelEvent2Source: source, units: .line, wheelCount: 1,
            wheel1: Int32(down ? -lines : lines), wheel2: 0, wheel3: 0
        ) {
            event.location = point
            event.setIntegerValueField(.eventSourceUserData, value: GazeScroll.mark)
            event.post(tap: .cghidEventTap)
        }
        usleep(30_000)
        CGWarpMouseCursorPosition(wasAt)
        lastMouse = wasAt
    }
}
