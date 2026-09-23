import AppKit

/// Draws what the decider is about to be shown: every offered target, outlined
/// and numbered, with the aim on top.
///
/// The list is the whole answer to "why did it pick that". A target that is not
/// in it could never have been chosen, and a target that is in it at 12 cm is
/// competing with one at 2 cm. Both facts are invisible: the log prints three
/// of forty-odd lines, and `--look` prints twelve. On screen they are one
/// glance.
///
/// It draws nothing the accessibility walk can see. The panel ignores mouse
/// events, and `ScreenTargets.skip` drops our own pid before anything else —
/// so a snapshot taken while this is up still reads the window underneath.
/// Drawn after the walk regardless, never before.
enum ActionSpotlight {

    /// The panel currently up, if any. One at a time: a second flash replaces
    /// the first rather than stacking over it.
    private static var panel: NSPanel?
    private static var hide: DispatchWorkItem?

    /// Outline `offers` over the window they came from, for `seconds`.
    ///
    /// `chosen` is drawn differently, for showing an answer rather than a
    /// question. Returns the panel's frame in screen coordinates, for the log.
    @discardableResult
    static func flash(
        offers: [ScreenTargets.Item], aim: CGPoint, in snapshot: ScreenTargets.Snapshot,
        chosen: ScreenTargets.Item? = nil, seconds: Double = 2.5
    ) -> CGRect {
        dismiss()

        // The window, plus room for an aim that is outside it — a gaze 4 cm
        // off lands in the next window along often enough to matter, and an
        // aim clipped out of the picture is the one thing worth seeing.
        var area = CGRect(
            x: Double(snapshot.frame.x), y: Double(snapshot.frame.y),
            width: Double(snapshot.frame.w), height: Double(snapshot.frame.h)
        )
        area = area.union(CGRect(x: aim.x - 60, y: aim.y - 60, width: 120, height: 120))
        for item in offers { area = area.union(rect(of: item)) }
        area = area.insetBy(dx: -2, dy: -2)

        let view = SpotlightView(frame: CGRect(origin: .zero, size: area.size))
        view.area = area
        view.offers = offers
        view.chosen = chosen
        view.aim = aim

        let window = NSPanel(
            contentRect: flipped(area), styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        window.contentView = view
        window.isFloatingPanel = true
        window.level = .statusBar
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        // Never a target, never in the way of a click the loop is about to
        // post: the panel sits over precisely where the next click lands.
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.orderFrontRegardless()
        panel = window

        let work = DispatchWorkItem { dismiss() }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        return flipped(area)
    }

    /// Take it down from wherever, without waiting. For a `defer` in an async
    /// function, which cannot await.
    static func dismissSoon() {
        DispatchQueue.main.async { dismiss() }
    }

    static func dismiss() {
        hide?.cancel()
        hide = nil
        panel?.orderOut(nil)
        panel = nil
    }

    /// An item's rectangle. `x` and `y` are its centre, which is what the
    /// model is given distances from.
    static func rect(of item: ScreenTargets.Item) -> CGRect {
        CGRect(
            x: Double(item.x) - Double(item.w) / 2, y: Double(item.y) - Double(item.h) / 2,
            width: Double(item.w), height: Double(item.h)
        )
    }

    /// Accessibility coordinates to window coordinates.
    ///
    /// AX counts down from the top-left of the primary screen; AppKit counts
    /// up from its bottom-left. `NSScreen.screens[0]` is the primary one —
    /// `NSScreen.main` is whichever has focus, which is a different screen as
    /// soon as there are two.
    private static func flipped(_ rect: CGRect) -> CGRect {
        let primary = NSScreen.screens.first?.frame ?? .zero
        return CGRect(
            x: rect.minX, y: primary.maxY - rect.maxY,
            width: rect.width, height: rect.height
        )
    }
}

/// The drawing. Plain Core Graphics: forty outlines and forty numbers is a
/// `drawRect`, not a view tree.
private final class SpotlightView: NSView {
    /// The area covered, in accessibility coordinates. Everything is drawn
    /// relative to it, and flipped once here.
    var area: CGRect = .zero
    var offers: [ScreenTargets.Item] = []
    var chosen: ScreenTargets.Item?
    var aim: CGPoint = .zero

    override var isFlipped: Bool { true }

    private func local(_ rect: CGRect) -> CGRect {
        rect.offsetBy(dx: -area.minX, dy: -area.minY)
    }

    override func draw(_ dirty: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setLineWidth(1.5)

        for (index, item) in offers.enumerated() {
            let box = local(ActionSpotlight.rect(of: item)).insetBy(dx: 0.5, dy: 0.5)
            guard box.width > 2, box.height > 2 else { continue }
            let mine = item == chosen
            // Teal for the places words can go. They are in the list whatever
            // their distance, so they are the ones whose presence is not
            // explained by where the aim is.
            let colour: NSColor = mine
                ? .systemGreen
                : (item.kind == ScreenTargets.Kind.text ? .systemTeal : .systemOrange)
            let path = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
            path.lineWidth = mine ? 3 : 1.5
            colour.withAlphaComponent(mine ? 1 : 0.85).setStroke()
            path.stroke()
            colour.withAlphaComponent(mine ? 0.18 : 0.07).setFill()
            path.fill()
            chip("t\(index)", at: CGPoint(x: box.minX, y: box.minY), colour: colour)
        }

        // The aim last, over everything: it is the one mark that has to be
        // findable in a window with forty boxes in it.
        let point = CGPoint(x: aim.x - area.minX, y: aim.y - area.minY)
        for (radius, alpha) in [(22.0, 0.25), (11.0, 0.5)] {
            let circle = NSBezierPath(ovalIn: CGRect(
                x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2
            ))
            NSColor.systemPink.withAlphaComponent(alpha).setFill()
            circle.fill()
        }
        NSColor.white.setStroke()
        let dot = NSBezierPath(ovalIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6))
        NSColor.systemPink.setFill()
        dot.fill()
        dot.lineWidth = 1
        dot.stroke()
    }

    /// The number, on a filled tab above the corner of its box — legible over
    /// a dark sidebar and a white message list alike.
    private func chip(_ text: String, at corner: CGPoint, colour: NSColor) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold)
        let label = NSAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: NSColor.white]
        )
        let size = label.size()
        let box = CGRect(
            x: corner.x, y: max(0, corner.y - size.height - 1),
            width: size.width + 6, height: size.height + 1
        )
        colour.withAlphaComponent(0.95).setFill()
        NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
        label.draw(at: CGPoint(x: box.minX + 3, y: box.minY))
    }
}

/// A dot that follows the gaze, drawn by ParrotFlow itself.
///
/// The tracker draws its own dot, but that is the tracker's business and it
/// tells you nothing about what this app read. This one is the number in
/// `gaze.pos` as ParrotFlow sees it, staleness rule included: pink while the
/// tracker is answering, grey the moment it stops and the mouse takes over.
/// So the dot is also the answer to "is it tracking right now".
enum GazeDot {
    private static var panel: NSPanel?
    private static var timer: Timer?

    static func show(file: String) {
        let size: CGFloat = 64
        let view = DotView(frame: CGRect(x: 0, y: 0, width: size, height: size))
        let window = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: size, height: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        window.contentView = view
        window.isFloatingPanel = true
        window.level = .screenSaver
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.orderFrontRegardless()
        panel = window

        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
            let point = Gaze.now(file: file)
            view.tracking = point.source == .tracker
            view.needsDisplay = true
            let primary = NSScreen.screens.first?.frame ?? .zero
            window.setFrameOrigin(CGPoint(
                x: point.location.x - size / 2,
                y: primary.maxY - point.location.y - size / 2
            ))
        }
    }

    static func hide() {
        timer?.invalidate(); timer = nil
        panel?.orderOut(nil); panel = nil
    }
}

private final class DotView: NSView {
    var tracking = false

    override func draw(_ dirty: NSRect) {
        let colour: NSColor = tracking ? .systemPink : .systemGray
        let middle = CGPoint(x: bounds.midX, y: bounds.midY)
        for (radius, alpha) in [(26.0, 0.22), (13.0, 0.45)] {
            colour.withAlphaComponent(alpha).setFill()
            NSBezierPath(ovalIn: CGRect(
                x: middle.x - radius, y: middle.y - radius, width: radius * 2, height: radius * 2
            )).fill()
        }
        colour.setFill()
        let dot = NSBezierPath(ovalIn: CGRect(x: middle.x - 4, y: middle.y - 4, width: 8, height: 8))
        dot.fill()
        NSColor.white.setStroke()
        dot.lineWidth = 1.5
        dot.stroke()
    }
}
