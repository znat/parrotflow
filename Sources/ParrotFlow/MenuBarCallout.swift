import AppKit
import SwiftUI

/// The one thing said after the setup window closes: where the app went.
///
/// A window that disappears takes the app with it as far as anybody watching is
/// concerned. There is no dock icon and no window left — only a bird in the
/// menu bar that was not there an hour ago — so this points at it once, names
/// it, and says the key to hold.
///
/// Once per install, and never again: `shown` is a default, like the eSpeak
/// answer. It is not a tour and not a step; there is nothing to press and it
/// goes on its own.
final class MenuBarCallout {

    private var panel: NSPanel?
    private var timer: Timer?

    /// How long it stays. Long enough to read twice, which is what a sentence
    /// about a key you have not pressed yet needs.
    private static let stays: TimeInterval = 9

    private static let shownKey = "Setup.menuBarCalloutShown"

    static var shown: Bool {
        get { UserDefaults.standard.bool(forKey: shownKey) }
        set { UserDefaults.standard.set(newValue, forKey: shownKey) }
    }

    /// Puts it under `button`, once. `hotkey` is the key that actually bound,
    /// or nil — and then the line about holding it is left out rather than
    /// naming a key that does nothing, the same rule the last screen follows.
    func showOnce(under button: NSStatusBarButton?, hotkey: String?) {
        guard !MenuBarCallout.shown else { return }
        guard let button, let host = button.window else { return }
        MenuBarCallout.shown = true
        show(
            pointingAt: host.convertToScreen(button.convert(button.bounds, to: nil)),
            hotkey: hotkey
        )
    }

    /// The same, at a rect somebody else measured, and without the once-only
    /// rule. `--panels callout` has no status item to hang off.
    func show(pointingAt icon: NSRect, hotkey: String?) {
        build(hotkey: hotkey, pointingAt: icon)
        panel?.riseIntoView(makeKey: false)

        timer = Timer.scheduledTimer(
            withTimeInterval: MenuBarCallout.stays, repeats: false
        ) { [weak self] _ in
            self?.dismiss()
        }
    }

    func dismiss() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func build(hotkey: String?, pointingAt icon: NSRect) {
        // Where the arrow has to be, in the panel's own width: under the middle
        // of the icon. The panel is clamped to the screen, so on an icon near
        // the right edge the arrow moves rather than the panel hanging off.
        let screen = NSScreen.screens.first { $0.frame.intersects(icon) } ?? NSScreen.main
        let limit = screen?.visibleFrame ?? .zero
        let width = CalloutMetrics.width
        let wanted = icon.midX - width / 2
        let x = min(max(limit.minX + 8, wanted), limit.maxX - width - 8)
        let point = min(max(CalloutMetrics.radius + CalloutMetrics.arrow,
                            icon.midX - x),
                        width - CalloutMetrics.radius - CalloutMetrics.arrow)

        let view = CalloutView(hotkey: hotkey, pointingAt: point) { [weak self] in
            self?.dismiss()
        }
        // Measured, not declared. It is two or three lines depending on whether
        // a key bound, and a height written here leaves a band of nothing under
        // the last of them.
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        let size = hosting.frame.size
        hosting.autoresizingMask = [.width, .height]

        let panel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isFloatingPanel = true
        // Over the menu bar's own level is not wanted: the menu has to be able
        // to open on top of this, because the first thing some people do with a
        // new icon is click it.
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.adoptParrotAppearance()
        panel.setFrameOrigin(NSPoint(x: x, y: icon.minY - size.height - 2))
        self.panel = panel
    }
}

enum CalloutMetrics {
    static let width: CGFloat = 288

    /// The ground. ParrotFlow's own blue, taken down until white sits on it at
    /// about 6:1 — the sky colour itself is 3.7:1 against white, which is under
    /// what a sentence needs.
    static let ground = Color(red: 0.235, green: 0.373, blue: 0.510)
    static let radius: CGFloat = 12
    /// Half the arrow's width, which is also how far its tip can get from a
    /// corner before the corner has to give way to it.
    static let arrow: CGFloat = 9
}

/// A rounded rectangle with the arrow on its top edge.
///
/// One shape and not a triangle laid over a box: two shapes meet in a seam, and
/// a seam across a rim is what you see rather than the arrow.
private struct CalloutShape: Shape {
    /// Where the tip is, from the left edge.
    let point: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = CalloutMetrics.radius
        let arrow = CalloutMetrics.arrow
        let top = rect.minY + arrow
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + radius, y: top))
        path.addLine(to: CGPoint(x: point - arrow, y: top))
        path.addLine(to: CGPoint(x: point, y: rect.minY))
        path.addLine(to: CGPoint(x: point + arrow, y: top))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: top))
        path.addArc(
            center: CGPoint(x: rect.maxX - radius, y: top + radius),
            radius: radius, startAngle: .degrees(-90), endAngle: .degrees(0),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addArc(
            center: CGPoint(x: rect.maxX - radius, y: rect.maxY - radius),
            radius: radius, startAngle: .degrees(0), endAngle: .degrees(90),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addArc(
            center: CGPoint(x: rect.minX + radius, y: rect.maxY - radius),
            radius: radius, startAngle: .degrees(90), endAngle: .degrees(180),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX, y: top + radius))
        path.addArc(
            center: CGPoint(x: rect.minX + radius, y: top + radius),
            radius: radius, startAngle: .degrees(180), endAngle: .degrees(270),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

private struct CalloutView: View {
    let hotkey: String?
    let pointingAt: CGFloat
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                // The drawing, not the menu bar bird: that one is a single
                // colour and would be an orange shape on blue. `PlumageBird`
                // is cut from `parrot.svg` and wears the plumage.
                PlumageBird(size: 17)
                Text("\(AppVariant.displayName) lives here")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
            if let hotkey {
                HStack(spacing: 5) {
                    Text("Hold")
                    key(hotkey)
                    Text("and start talking.")
                }
                .font(.system(size: 12))
                .foregroundStyle(.white)
            }
            Text("Its menu is under the bird.")
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.72))
        }
        .padding(.horizontal, 15)
        .padding(.top, CalloutMetrics.arrow + 13)
        .padding(.bottom, 14)
        .frame(width: CalloutMetrics.width, alignment: .topLeading)
        .background {
            // Drawn rather than glass: the glass helper is a rounded
            // rectangle and the arrow is the whole point of this surface. Blue
            // and not the near-black the other floating surfaces take — this
            // one is the app introducing itself, and it is the only surface
            // that is.
            let shape = CalloutShape(point: pointingAt)
            shape
                .fill(CalloutMetrics.ground)
                .overlay { shape.stroke(Color.white.opacity(0.22), lineWidth: 1) }
                .shadow(color: .black.opacity(0.45), radius: 12, y: 4)
        }
        .environment(\.colorScheme, .dark)
        // Anywhere on it. There is nothing to press, so the whole surface is
        // the way out.
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
    }

    private func key(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Color.white.opacity(0.16),
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.55), lineWidth: 1)
            }
    }
}
