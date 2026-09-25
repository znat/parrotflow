import AppKit

/// Draws what the decider is about to be shown: every offered target, outlined
/// and numbered, with the aim on top when there is one.
///
/// The list is the whole answer to "why did it pick that". A target that is not
/// in it could never have been chosen. That is invisible in the log, which
/// prints three of forty-odd lines, and `--look` prints twelve. On screen it is
/// one glance.
///
/// It draws nothing the accessibility walk can see. The panel ignores mouse
/// events and never activates, so a snapshot taken while this is up still
/// reads the app's window underneath.
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
        offers: [ScreenTargets.Item], aim: CGPoint?, in snapshot: ScreenTargets.Snapshot,
        chosen: ScreenTargets.Item? = nil, seconds: Double = 2.5
    ) -> CGRect {
        dismiss()

        var area = CGRect(
            x: Double(snapshot.frame.x), y: Double(snapshot.frame.y),
            width: Double(snapshot.frame.w), height: Double(snapshot.frame.h)
        )
        if let aim {
            area = area.union(CGRect(x: aim.x - 60, y: aim.y - 60, width: 120, height: 120))
        }
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

    /// An item's rectangle. `x` and `y` are its centre.
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
    var aim: CGPoint?

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
            // Teal for the places words can go.
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
        guard let aim else { return }
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
