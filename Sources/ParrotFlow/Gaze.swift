import AppKit

/// Where the speaker is looking, according to whatever is tracking them.
///
/// The tracker is another app — GazeOverlay, today. It writes one line,
/// `x y ms`, to a file this reads: position in screen coordinates (top-left
/// origin, the same ones the accessibility API uses), and the Unix time in
/// milliseconds it was written.
///
/// A file rather than a socket because it is a position, not a stream. The
/// reader wants the latest value and nothing else, the writer never blocks,
/// and either side can be restarted without the other noticing.
enum Gaze {

    /// Where a point came from, for the trace. A dictation that acted on the
    /// wrong thing is first explained by this.
    enum Source: String {
        case tracker
        /// The file is missing, unreadable, or older than `maxAge`.
        case mouse
    }

    struct Point {
        let location: CGPoint
        let source: Source
        /// How old the tracker's reading was. Nil for the mouse.
        let age: TimeInterval?
    }

    /// Older than this and the tracker is not tracking — no face in front of
    /// the camera, the engine restarting, the Mac asleep. It writes nothing
    /// rather than writing a stale position, so age is the only test.
    ///
    /// 1.5 s is the prototype's rule (`tools/act.py`), kept so both sides
    /// refuse the same readings.
    static let maxAge: TimeInterval = 1.5

    /// The current gaze, or the mouse when there isn't one.
    ///
    /// Never fails: a point is always returned, and `source` says whether it
    /// means anything. The mouse is a reasonable stand-in — it is where you
    /// last pointed — and it keeps the whole feature usable with no tracker
    /// running at all.
    static func now(file path: String?) -> Point {
        if let path, let read = read(file: path) {
            return read
        }
        return Point(location: mouse(), source: .mouse, age: nil)
    }

    /// The mouse, in accessibility coordinates.
    ///
    /// `NSEvent.mouseLocation` is bottom-left of the primary screen; the
    /// accessibility API is top-left of it. Flipping against
    /// `NSScreen.screens[0]` — the primary one, not `NSScreen.main`, which is
    /// whichever screen has focus — is the conversion every AX caller makes.
    static func mouse() -> CGPoint {
        let m = NSEvent.mouseLocation
        let primary = NSScreen.screens.first?.frame ?? .zero
        return CGPoint(x: m.x, y: primary.maxY - m.y)
    }

    private static func read(file path: String) -> Point? {
        let expanded = (path as NSString).expandingTildeInPath
        guard let text = try? String(contentsOfFile: expanded, encoding: .utf8) else { return nil }
        let parts = text.split(whereSeparator: { $0 == " " || $0 == "\n" })
        guard parts.count >= 3,
              let x = Double(parts[0]), let y = Double(parts[1]), let ms = Double(parts[2])
        else { return nil }
        let age = Date().timeIntervalSince1970 - ms / 1000
        guard age <= maxAge, age > -maxAge else { return nil }
        return Point(location: CGPoint(x: x, y: y), source: .tracker, age: age)
    }
}
