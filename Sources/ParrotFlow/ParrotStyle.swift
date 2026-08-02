import SwiftUI

/// The one place the floating surfaces agree on how they look.
///
/// Exists because the pill, the notice and the two dialogs grew one at a time,
/// each borrowing roughly what the last one did — same idea, four slightly
/// different corner radii, borders and footers. They appear over other people's
/// apps, one at a time, seconds apart, so any drift between them reads as three
/// unrelated things happening rather than one app talking.
enum Parrot {

    // MARK: Plumage

    // A scarlet macaw, in the order the feathers run. Every gradient in the app
    // walks this wheel in this order, so the surfaces share a direction of
    // travel and not just a set of colours.
    //
    // Saturated on purpose. Muted versions of these read as the system's own
    // red/yellow/green/blue — the colours of a traffic light and of every other
    // Mac alert — and the point of them is that this app is a parrot.
    static let scarlet = Color(red: 1.00, green: 0.16, blue: 0.15)
    static let amber = Color(red: 1.00, green: 0.75, blue: 0.00)
    static let leaf = Color(red: 0.00, green: 0.85, blue: 0.42)
    static let sky = Color(red: 0.00, green: 0.60, blue: 1.00)

    /// Closes on scarlet so an angular gradient has no seam.
    static let wheel: [Color] = [scarlet, amber, leaf, sky, scarlet]

    /// The colour of anything you can act on: focus rings, the primary button,
    /// the header of a panel. Deliberately not `.accentColor` — a surface that
    /// changes colour with the system tint cannot also be the app's own.
    static let action = sky

    // MARK: Metrics

    static let panelRadius: CGFloat = 18
    static let panelPadding: CGFloat = 16
    static let fieldRadius: CGFloat = 7
}

// MARK: - Surface

extension View {

    /// Dark glass and the plumage rim: the family look.
    ///
    /// The colour lives on the edge and nowhere else. A surface washed in a
    /// feather is a surface you have to read text off, and these appear over
    /// documents, terminals and dark editors without knowing which — dark glass
    /// is the one background that stays legible over all of them, and the rim
    /// carries the identity without asking anything of the text.
    ///
    /// `alive` is for work of unknown length. The rim turns and brightens, which
    /// is the only motion any of these surfaces make — it means the app is busy,
    /// so nothing else may borrow it for decoration.
    func parrotSurface<S: InsettableShape>(_ shape: S, alive: Bool = false) -> some View {
        background {
            shape.fill(.regularMaterial)
            // The material alone takes the shade of whatever is behind it, which
            // over a white page is a white panel. The scrim holds it dark.
            shape.fill(Color.black.opacity(0.34))
        }
        .overlay { PlumageRim(shape: shape, alive: alive) }
    }
}

/// The signature: a hairline of the four feathers, wrapped around an edge.
struct PlumageRim<S: InsettableShape>: View {
    let shape: S
    var alive: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var angle: Double = -90

    var body: some View {
        shape
            .strokeBorder(
                AngularGradient(colors: Parrot.wheel, center: .center, angle: .degrees(angle)),
                lineWidth: alive ? 2 : 1.4
            )
            .opacity(alive ? 1 : 0.9)
            // A white hairline just inside keeps the edge glassy in light mode,
            // where saturated colour alone reads as a sticker.
            .overlay {
                shape.inset(by: 1.4).strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            }
            .animation(.easeInOut(duration: 0.35), value: alive)
            .onChange(of: alive) { _, _ in spin() }
            .onAppear { spin() }
    }

    private func spin() {
        guard alive, !reduceMotion else {
            withAnimation(.default) { angle = -90 }
            return
        }
        withAnimation(.linear(duration: 3.2).repeatForever(autoreverses: false)) {
            angle = 270
        }
    }
}

// MARK: - Chrome

/// Four feathers, ascending. The app's mark at the size a label is set in.
///
/// The same four bars as the recording pill's meter with the sound taken out —
/// which is what a dialog is: the pill, after it has heard you.
struct PlumageMark: View {
    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(Array(Parrot.wheel.prefix(4).enumerated()), id: \.offset) { index, colour in
                Capsule()
                    .fill(colour)
                    .frame(width: 2, height: 5 + CGFloat(index) * 2)
            }
        }
        .frame(height: 11, alignment: .bottom)
    }
}

/// The small capitalised line at the top of a panel: the mark, what this panel
/// is, and what state it is in. Both dialogs open with one, in the same place.
struct PanelHeader: View {
    let title: String
    var note: String?
    var accent: Color = Parrot.action

    var body: some View {
        HStack(spacing: 8) {
            PlumageMark()
            Text(title.uppercased())
                .foregroundStyle(accent)
            if let note {
                Text(note.uppercased())
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .font(.system(size: 9, weight: .semibold, design: .rounded))
        .kerning(0.9)
        .padding(.bottom, 10)
    }
}

/// A key on a keyboard, drawn small.
struct KeyCap: View {
    let symbol: String
    /// Set on a filled button, where the surrounding colour is doing the work.
    var onFill = false

    var body: some View {
        Text(symbol)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(onFill ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                (onFill ? Color.white.opacity(0.22) : Color.primary.opacity(0.09)),
                in: RoundedRectangle(cornerRadius: 4, style: .continuous)
            )
    }
}

// MARK: - Actions

/// The footer every dialog ends with.
///
/// One component rather than two similar HStacks: the two panels used to
/// disagree about which key confirmed — one took plain return, the other ⌘↩ —
/// which is the kind of difference you only discover by losing a rewrite to it.
/// ⌘↩ confirms and escape cancels, in both, always, whatever has focus.
struct PanelActions: View {
    let status: String
    let cancelTitle: String
    let confirmTitle: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.5)

            HStack(spacing: 10) {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                Spacer(minLength: 12)

                ActionButton(title: cancelTitle, key: "esc", filled: false, action: onCancel)
                    .keyboardShortcut(.cancelAction)

                ActionButton(title: confirmTitle, key: "⌘↩", filled: true, action: onConfirm)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.top, 12)
        }
        .padding(.top, 12)
    }
}

/// Label first, then the key that does it — so the eye lands on the verb and
/// the shortcut is the answer to "how", not something to decode first.
struct ActionButton: View {
    let title: String
    let key: String
    let filled: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(filled ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                KeyCap(symbol: key, onFill: filled)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background {
                if filled {
                    Capsule().fill(
                        LinearGradient(
                            colors: [Parrot.action, Parrot.action.opacity(0.86)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .shadow(color: Parrot.action.opacity(0.45), radius: hovering ? 10 : 6, y: 2)
                } else {
                    Capsule().fill(Color.primary.opacity(hovering ? 0.10 : 0.06))
                    Capsule().strokeBorder(.primary.opacity(0.10))
                }
            }
            .brightness(hovering && filled ? 0.05 : 0)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Fields

extension View {

    /// The one text field look: a quiet well that takes a sky ring when focused.
    func parrotField(focused: Bool) -> some View {
        padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                Color.primary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: Parrot.fieldRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Parrot.fieldRadius, style: .continuous)
                    .strokeBorder(Parrot.action.opacity(focused ? 0.9 : 0), lineWidth: 1.5)
            }
            .animation(.easeOut(duration: 0.12), value: focused)
    }
}

// MARK: - Panels

extension NSPanel {

    /// These surfaces are dark whatever the system is set to.
    ///
    /// Not a preference: they are read for a second or two on top of an app
    /// that is already lit however it is lit, and a panel that changes shade
    /// with the system is a panel you have to find twice. Dark also keeps the
    /// plumage rim the brightest thing on it, which is the point of the rim.
    func adoptParrotAppearance() {
        appearance = NSAppearance(named: .darkAqua)
    }

    /// Brings a floating surface up with a short rise and fade.
    ///
    /// These panels appear without any gesture of the user's — a hotkey they
    /// pressed a second ago, or a model that has just finished — so an instant
    /// cut reads as a glitch on top of whatever they were reading. 160ms is
    /// enough to say "this arrived".
    func riseIntoView(makeKey: Bool) {
        let destination = frame.origin
        guard !isVisible else {
            if makeKey { makeKeyAndOrderFront(nil) } else { orderFrontRegardless() }
            return
        }

        alphaValue = 0
        setFrameOrigin(NSPoint(x: destination.x, y: destination.y - 8))
        if makeKey { makeKeyAndOrderFront(nil) } else { orderFrontRegardless() }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
            animator().setFrameOrigin(destination)
        }
    }
}
