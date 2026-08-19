import AppKit
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
    // Still well clear of the system's own red/yellow/green/blue — the colours
    // of a traffic light and of every other Mac alert. The point of them is
    // that this app is a parrot.
    //
    // One step down in chroma from the values these started at. On glass the
    // hues sat over a lit, shifting ground and needed the saturation to hold.
    // The surfaces are near-black now, so the hues carry much further and the
    // old values read as neon.
    static let scarlet = Color(red: 0.761, green: 0.373, blue: 0.349)  // #c25f59
    static let amber = Color(red: 0.761, green: 0.604, blue: 0.361)  // #c29a5c
    static let leaf = Color(red: 0.373, green: 0.639, blue: 0.514)  // #5fa383
    static let sky = Color(red: 0.353, green: 0.537, blue: 0.710)  // #5a89b5

    /// Closes on scarlet so an angular gradient has no seam.
    static let wheel: [Color] = [scarlet, amber, leaf, sky, scarlet]

    /// The wheel with the cool half taken out, for a surface that is a warning.
    /// Still two colours and still turning, so it reads as the same rim in a
    /// different mood rather than as a different app.
    static let warned: [Color] = [amber, scarlet, amber, scarlet, amber]

    /// And with the amber nearly gone, for the surface that has just taken a
    /// keystroke. One step further along the same ramp, so the two states read
    /// as an escalation rather than as two unrelated colours.
    static let stopped: [Color] = [scarlet, scarlet, amber, scarlet, scarlet]

    /// One plumage colour blended into the next, for a ramp rather than a step.
    ///
    /// Through sRGB components rather than through a SwiftUI gradient: this
    /// colours a run of text, and `Text` takes a colour, not a shape style it
    /// can fill with.
    static func mix(_ from: Color, _ to: Color, _ amount: Double) -> Color {
        let t = min(max(amount, 0), 1)
        guard let a = NSColor(from).usingColorSpace(.sRGB),
              let b = NSColor(to).usingColorSpace(.sRGB) else { return to }
        return Color(
            red: a.redComponent + (b.redComponent - a.redComponent) * t,
            green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
            blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t
        )
    }

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

    /// A dark ground and the plumage rim: the family look.
    ///
    /// The colour lives on the edge and nowhere else. A surface washed in a
    /// feather is a surface you have to read text off, and these appear over
    /// documents, terminals and dark editors without knowing which — a dark
    /// ground is the one background that stays legible over all of them, and
    /// the rim carries the identity without asking anything of the text.
    ///
    /// `alive` is for work of unknown length. The rim turns fast and brightens,
    /// and the glow drifts with it. That combination means the app is busy, and
    /// nothing else may borrow it.
    ///
    /// `turning` is the rim alone, at a third of the speed and at its resting
    /// weight. The offer uses it: a surface asking to be answered before it
    /// goes should be the one thing on screen that moves. It is not the busy
    /// signal, because the weight, the brightness and the drifting glow are
    /// what make that one — see `PlumageRim.spin`.
    ///
    /// `glass` gives the surface a thickness: a lighter scrim, a sheen down the
    /// face, and the rim's inner hairline weighted to the top so the edge reads
    /// as lit. It is what tells you something is a lens over the desktop rather
    /// than a card sitting on it. It needs an `NSVisualEffectView` behind the
    /// window to have anything to be thick over — see `ParrotGlass`.
    ///
    /// `scrim` is how much of the desktop it keeps out, and only means anything
    /// under glass. Default is thin, for the pill, which is glanced at. Pass
    /// more for anything holding a sentence you have to read and select.
    ///
    /// `solid` is the near-black ground, and it is the opposite bet from
    /// `glass`. Glass gives a surface thickness by letting the desktop through;
    /// this holds the desktop out, so a sentence is read off a known ground
    /// rather than off whatever happened to be behind the window. 95% rather
    /// than 100% because the last 5% is not transparency so much as a hairline
    /// of what is underneath — enough that the surface reads as sitting *over*
    /// something rather than cut out of the screen. Below about 90% the text
    /// starts fighting the backdrop, which is the thing glass never solved.
    ///
    /// Every surface passes `solid` now, so `glass` and `scrim` are on no call
    /// site. Kept rather than deleted because one surface in the design — the
    /// launch panel — is not drawn yet, and the reasons written on this path
    /// would go with it. See "Not done" in
    /// `docs/proposals/hud-placement-and-offer.md`.
    ///
    /// `wash` is a colour laid over the ground, for a surface that has to be
    /// read as a warning before it is read at all. Over the solid ground only:
    /// the translucent ones already take their colour from what is behind
    /// them, and a wash on top of that is paint on a window.
    func parrotSurface<S: InsettableShape>(
        _ shape: S, alive: Bool = false, turning: Bool = false, glass: Bool = false,
        solid: Bool = false, scrim: Double? = nil, wash: Color? = nil,
        wheel: [Color] = Parrot.wheel
    ) -> some View {
        background {
            if solid {
                shape.fill(Color(red: 0.035, green: 0.035, blue: 0.043).opacity(0.95))
                if let wash { shape.fill(wash) }
            }
            // No `.regularMaterial` under glass. That blurs what is inside the
            // window, and on a panel with a clear background there is nothing
            // inside it to blur — it comes out flat grey, and a scrim over flat
            // grey is a black-to-grey gradient rather than glass. The material
            // for those surfaces sits behind the whole window; see `ParrotGlass`.
            if !glass, !solid {
                shape.fill(.regularMaterial)
            }
            // The material alone takes the shade of whatever is behind it, which
            // over a white page is a white panel. The scrim holds it dark.
            //
            // Much lighter under glass, because there the thing behind it is the
            // desktop and the whole point is to see it. Not nothing: these carry
            // white text over whatever happens to be there, and a bright page
            // behind them would take the words with it.
            //
            // This is the transparency dial, and the only one — turning the
            // backdrop's alpha down instead would let the desktop through
            // unblurred. A surface you only glance at can afford to be thin; one
            // you read a sentence off and select words in cannot, which is why
            // the dialogs pass a heavier `scrim` than the pill's default.
            //
            // Nothing at all where the system has real Liquid Glass: it does
            // its own tinting, through `tintColor` on the view behind, and a
            // scrim painted on top of it is paint over glass.
            if !glass, !solid {
                shape.fill(Color.black.opacity(0.34))
            } else if glass, !ParrotGlass.isPlatform {
                shape.fill(Color.black.opacity(scrim ?? 0.08))
            }

            if glass, !ParrotGlass.isPlatform {
                // Light falling on the face, strongest at the top and gone by
                // halfway down. Stops short of the bottom on purpose — a sheen
                // that reaches both edges reads as a gradient fill rather than
                // as a lit surface.
                shape.fill(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.14), location: 0),
                            .init(color: .white.opacity(0.04), location: 0.42),
                            .init(color: .clear, location: 0.72)
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            }
        }
        // The lit edge is the rim's own inner hairline, weighted to the top —
        // not a line of its own. See `PlumageRim`.
        .overlay {
            PlumageRim(shape: shape, alive: alive, turning: turning, glass: glass, wheel: wheel)
        }
    }
}

/// The signature: a hairline of the four feathers, wrapped around an edge.
struct PlumageRim<S: InsettableShape>: View {
    let shape: S
    var alive: Bool = false
    /// Turn without saying the app is busy. See `spin`.
    var turning: Bool = false
    /// Weight the inner hairline toward the top, so it reads as light on the
    /// edge. See the hairline below.
    var glass: Bool = false
    /// The colours it runs through. A wheel of two makes a rim that means one
    /// thing, which is what a warning needs.
    var wheel: [Color] = Parrot.wheel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var angle: Double = -90

    var body: some View {
        shape
            .strokeBorder(
                AngularGradient(colors: wheel, center: .center, angle: .degrees(angle)),
                lineWidth: alive ? 2 : 1.4
            )
            .opacity(alive ? 1 : 0.9)
            // A white hairline just inside keeps the edge glassy in light mode,
            // where saturated colour alone reads as a sticker.
            //
            // Under `glass` this same line is also the specular — bright along
            // the top, gone by the sides. It is one line either way, and that
            // is the point: a second hairline drawn a fraction inside this one
            // does not read as light on a rounded edge, it reads as a second
            // border with a dark gap between them, which is what it looks like.
            .overlay {
                shape.inset(by: 1.4).strokeBorder(hairline, lineWidth: glass ? 0.75 : 0.5)
            }
            .animation(.easeInOut(duration: 0.35), value: alive)
            .onChange(of: alive) { _, _ in spin() }
            .onChange(of: turning) { _, _ in spin() }
            .onAppear { spin() }
    }

    private var hairline: AnyShapeStyle {
        guard glass else { return AnyShapeStyle(Color.white.opacity(0.12)) }
        return AnyShapeStyle(
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0.40), location: 0),
                    .init(color: .white.opacity(0.10), location: 0.35),
                    .init(color: .white.opacity(0.05), location: 1)
                ],
                startPoint: .top, endPoint: .bottom
            )
        )
    }

    /// One turn of the feathers, at the speed the surface asked for.
    ///
    /// Busy is 1.8s. `turning` is `slowTurn`, which is slow enough that you
    /// see the colours move rather than a rim spinning — and the bloom behind
    /// it stays still either way, which is the other half of why the two do
    /// not read alike. That stillness is also what keeps this affordable: a
    /// drifting bloom is four Gaussian blurs re-rendered every frame, measured
    /// at 40% of a core. See `PlumageBloom.spin`.
    ///
    /// The rim alone measured at about 11% of a core on the offer pill, for
    /// the five seconds the offer is up. The pill standing still is 0-3%.
    private func spin() {
        guard alive || turning, !reduceMotion else {
            withAnimation(.default) { angle = -90 }
            return
        }
        withAnimation(
            .linear(duration: alive ? 1.8 : Self.slowTurn).repeatForever(autoreverses: false)
        ) {
            angle = 270
        }
    }

    /// One trip round a rim that is not saying anything is happening.
    /// Computed rather than stored: this type is generic over its shape.
    static var slowTurn: TimeInterval { 6 }
}

// MARK: - Fields

/// A one-line field with the caret already at the end of the sentence.
///
/// SwiftUI's `TextField` selects everything when it takes focus. That is right
/// for a field you are replacing and wrong for one you are correcting: the
/// first key you press throws the sentence away, and the sentence is the thing
/// you opened the panel to keep. There is no way to say otherwise from SwiftUI
/// before macOS 15, and the field editor is an AppKit object either way.
///
/// So the field is an `NSTextField` and the selection is set by hand, once,
/// when it becomes first responder — collapsed to the end, which is where you
/// carry on typing from.
struct EndCaretField: NSViewRepresentable {
    typealias NSViewType = NSTextField
    // Spelled out rather than as `Context`: this module has a `Context` of its
    // own — the screen-capture stage — and it shadows the protocol's typealias,
    // so the two methods below silently stop matching the requirement.
    typealias Ctx = NSViewRepresentableContext<EndCaretField>

    @Binding var text: String
    var fontSize: CGFloat
    var onSubmit: () -> Void

    func makeNSView(context: Ctx) -> NSTextField {
        let field = NSTextField(string: text)
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: fontSize)
        field.lineBreakMode = .byClipping
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        // Focus, then the caret. Both after the view is in a window: a field
        // with no window has no field editor to put a selection in.
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            if let editor = field.currentEditor() {
                // `NSString.length`, not `String.count`. AppKit selections are
                // UTF-16 offsets and `count` is grapheme clusters, so one emoji
                // or composed character in the sentence puts the caret short of
                // the end — or inside a surrogate pair.
                editor.selectedRange = NSRange(
                    location: (field.stringValue as NSString).length, length: 0
                )
            }
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Ctx) {
        if field.stringValue != text { field.stringValue = text }
        if field.font?.pointSize != fontSize { field.font = .systemFont(ofSize: fontSize) }
    }

    func makeCoordinator() -> FieldCoordinator { FieldCoordinator(self) }

    final class FieldCoordinator: NSObject, NSTextFieldDelegate {
        private let parent: EndCaretField
        init(_ parent: EndCaretField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            // Return commits, and the panel says so: a one-line field shows ↩
            // on its confirm button, not ⌘↩. There is no newline to insert in
            // a field that holds one line, so Return meaning "done" is what
            // every other one-line field on the system does — and advertising
            // a modifier the field does not need is the part that was wrong.
            // ⌘↩ still works, through the button's own shortcut.
            //
            // Escape is left alone so the panel's own `cancelOperation` still
            // answers it.
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            parent.onSubmit()
            return true
        }
    }
}

// MARK: - Glass

/// The backdrop that actually samples the desktop.
///
/// SwiftUI's `.regularMaterial` blurs what is inside its own *window*. These
/// panels are borderless with a clear background, so there is nothing inside to
/// blur and the material comes out flat grey — a scrim over flat grey is a
/// black-to-grey gradient, which is what "glass" looked like before this.
/// `NSVisualEffectView` with `.behindWindow` blending is the only thing on
/// macOS that samples what is behind the window, and only AppKit has one.
///
/// It goes *under* the hosting view, masked to the same shape SwiftUI draws, so
/// the frost stops where the surface does. Unmasked it fills the window, and on
/// the pill that would frost the transparent margin the glow lives in.
enum ParrotGlass {

    /// Whether the system has real Liquid Glass, or we are drawing our own.
    ///
    /// Read by `parrotSurface` as well: with the platform material behind it,
    /// the scrim and sheen it draws for the fallback would be paint over glass.
    static var isPlatform: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// Panel, backdrop and content, stacked in that order.
    ///
    /// `inset` is the transparent margin around the surface — the glow spills
    /// into it. `tint` is how much of the desktop the surface keeps out; a
    /// sentence you read word by word wants more of it than a pill you glance
    /// at.
    static func container(
        _ content: NSView, radius: CGFloat, inset: CGFloat = 0, tint: NSColor? = nil
    ) -> NSView {
        let container = NSView(frame: content.frame)
        container.autoresizesSubviews = true
        container.addSubview(backdrop(
            radius: radius, in: content.frame.size, inset: inset, tint: tint
        ))
        container.addSubview(content)
        return container
    }

    /// The backdrop, behind the content rather than around it.
    ///
    /// `NSGlassEffectView` is documented as embedding a `contentView` in glass,
    /// and that is the usual way to hold it. Not here: the SwiftUI view spans
    /// the whole window because the glow has to spill into the margin, and a
    /// content view inside the glass would be clipped to the glass's own
    /// bounds. So it is used as a backdrop with an empty content view, and the
    /// SwiftUI surface is drawn over it — the same shape, the same corner
    /// radius, and the rim on top of both.
    static func backdrop(
        radius: CGFloat, in size: NSSize, inset: CGFloat = 0,
        overlap: CGFloat = 2, tint: NSColor? = nil
    ) -> NSView {
        let edge = max(0, inset - overlap)
        let frame = NSRect(
            x: edge, y: edge,
            width: size.width - edge * 2, height: size.height - edge * 2
        )

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: frame)
            glass.cornerRadius = radius + overlap
            glass.style = .regular
            glass.tintColor = tint
            // It wants one, and an empty view is the honest answer: the content
            // is drawn over the glass, not inside it. See above.
            glass.contentView = NSView(frame: glass.bounds)
            glass.autoresizingMask = [.width, .height]
            return glass
        }

        // Before macOS 26 there is no Liquid Glass, so it is assembled by hand:
        // a blur that samples behind the window, and the scrim and sheen
        // `parrotSurface` draws over it.
        //
        // The frost is drawn `overlap` points *outside* the surface rather than
        // exactly under it. Two geometries have to agree — an AppKit mask image
        // with circular corners, and a SwiftUI `.continuous` rounded rectangle
        // — and where they disagree by a point the desktop shows through
        // between the frost and the rim, which reads as the border floating off
        // its own background.
        let view = NSVisualEffectView(frame: frame)
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.maskImage = mask(radius: radius + overlap)
        // Full strength, always. Lowering `alphaValue` does not make the frost
        // more transparent — it lets that fraction of the *raw* desktop through
        // beside it, sharp and unblurred, which reads as a dirty window rather
        // than a glass one.
        view.alphaValue = 1
        view.autoresizingMask = [.width, .height]
        return view
    }

    /// A rounded rectangle to cut the frost to, stretchable along its middle.
    ///
    /// The cap insets are what let one small image stretch to any size without
    /// the corners distorting, which is what makes this survive the pill's
    /// width changing on every state. Only the pre-26 path needs it —
    /// `NSGlassEffectView` has a `cornerRadius` of its own.
    static func mask(radius: CGFloat) -> NSImage {
        let size = NSSize(width: radius * 2 + 1, height: radius * 2 + 1)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// The light a surface throws onto whatever is behind it.
///
/// The rim is a 1.4pt hairline of the four feathers. This is the same hairline
/// again, thick and blurred, drawn behind the glass so the colour spills past
/// the edge instead of stopping at it — the surface lighting the desktop rather
/// than sitting on it.
///
/// Whatever draws one has to leave a transparent margin around itself for the
/// blur to land in, or the tail is cut off square at the window edge and the
/// glow reads as a second border. See `PillMetrics.bleed`.
///
/// **While the app is busy the two turn opposite ways, at speeds that do not
/// divide.** An even halo reads as a sticker with a drop shadow. At 2.6s and
/// 4.1s the bright parts pass each other on a cycle far longer than either, so
/// the bloom is brighter on one side, then another, and never repeats within
/// the seconds anyone watches it. That irregularity is the whole effect; the
/// spill on its own is just a glow.
///
/// It brightens while `alive`, which is the same signal the rim uses — the app
/// is busy. Nothing else may borrow it.
///
/// Four layers. That is the budget: each is a full-size Gaussian blur, and this
/// sits on screen for the whole of every dictation.
struct PlumageBloom<S: InsettableShape>: View {
    let shape: S
    var alive: Bool = false
    /// The colours the glow is made of. See `PlumageRim.wheel`.
    var wheel: [Color] = Parrot.wheel
    /// How much of it there is. The same absolute spill reads as far less
    /// around a 900pt panel than around a 46pt pill — the glow is a proportion
    /// of the edge it comes off, and the edge here is twenty times longer.
    var intensity: Double = 1

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var outer: Double = -90
    @State private var inner: Double = 90

    var body: some View {
        ZStack {
            // One stroke, blurred three ways. Same width and same angle on all
            // three, so their colours land on top of each other and sum into a
            // single falloff — brightest at the edge, gone by the margin.
            //
            // Three *different* widths banded: a wide stroke and a narrow one
            // put their colour at different distances from the edge, so scarlet
            // sat inside teal in a visible stripe. Diffusion is one source
            // spread further, not several sources.
            //
            // Chained `.shadow` was tried instead, to dodge the opaque backing
            // a blur forces — see `build()`. It cannot diffuse. Each shadow
            // casts the stroke *plus every shadow before it*, so a thin sharp
            // source comes out as nested soft-edged copies of itself: four
            // coloured borders drawn on top of each other, which is exactly
            // what it looked like. A blur spreads one source; a shadow repeats
            // it.
            bloom(width: 9, blur: 24, opacity: (alive ? 0.22 : 0.13) * intensity, angle: outer)
            bloom(width: 9, blur: 13, opacity: (alive ? 0.28 : 0.18) * intensity, angle: outer)
            bloom(width: 9, blur: 5, opacity: (alive ? 0.42 : 0.28) * intensity, angle: outer)

            // The unevenness, and the only layer that disagrees about where the
            // colours are. Wide and heavily blurred so it has no edge of its
            // own: it brightens one side of the halo and then another, which is
            // what keeps the glow from reading as a decal.
            bloom(width: 22, blur: 22, opacity: (alive ? 0.19 : 0.10) * intensity, angle: inner)
        }
        .animation(.easeInOut(duration: 0.4), value: alive)
        .onChange(of: alive) { _, _ in spin() }
        .onAppear { spin() }
    }

    private func bloom(width: CGFloat, blur: CGFloat, opacity: Double, angle: Double) -> some View {
        shape
            .strokeBorder(
                AngularGradient(colors: wheel, center: .center, angle: .degrees(angle)),
                lineWidth: width
            )
            .blur(radius: blur)
            .opacity(opacity)
    }

    /// The drift, and only while the app is busy.
    ///
    /// It turned all the time at first, which cost 40% of a core for as long as
    /// the pill was on screen — four Gaussian blurs re-rendered every frame,
    /// measured against 0% for the same pill standing still. A decoration that
    /// expensive is not a decoration, it is a fan.
    ///
    /// Still, the reason to stop it is the rule that was already written on
    /// `PlumageRim`: a glow that drifts while nothing is happening says
    /// something is happening. At rest the bloom is simply there — lit,
    /// uneven, and still. The offer turns its rim slowly and the bloom stays
    /// out of it, which is what keeps "busy" a signal of its own.
    private func spin() {
        guard alive, !reduceMotion else {
            withAnimation(.easeInOut(duration: 0.4)) { outer = -90; inner = 90 }
            return
        }
        // Opposite directions, and the two periods share no small factor, so
        // the bright parts pass each other on a cycle far longer than either.
        withAnimation(.linear(duration: 2.6).repeatForever(autoreverses: false)) {
            outer = 270
        }
        withAnimation(.linear(duration: 4.1).repeatForever(autoreverses: false)) {
            inner = -270
        }
    }
}

// MARK: - Chrome

/// The bird, at the size a label is set in.
///
/// The same parrot as the menu bar, built by `scripts/make-icons.py` from
/// `Resources/parrot.svg`. It was four ascending feathers before — a mark
/// derived from the pill's meter — which read as a signal-strength glyph next
/// to a word in capitals rather than as this app. The bird is the thing people
/// look for in the menu bar; the panels should be wearing it too.
///
/// Falls back to the feathers when the image is missing, which happens exactly
/// once: running the binary outside its bundle.
struct PlumageMark: View {
    var size: CGFloat = 13

    var body: some View {
        if let parrot = NSImage(named: "MenuBarParrotRecording") {
            Image(nsImage: parrot)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
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
    /// What the confirm button advertises. ⌘↩ where Return would insert a
    /// newline, ↩ where the field is one line and Return commits it.
    var confirmKey: String = "⌘↩"
    /// Sit closer to what is above. For a panel holding one line, the standing
    /// 24pt of air over the buttons is most of a dead band across the bottom.
    var compact: Bool = false
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                // Empty when the panel says what it is somewhere better. The
                // dictation panel puts its instruction above the field, at a
                // size you can read, rather than in grey under the buttons.
                if !status.isEmpty {
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                ActionButton(title: cancelTitle, key: "esc", filled: false, quiet: true,
                             action: onCancel)
                    .keyboardShortcut(.cancelAction)

                ActionButton(title: confirmTitle, key: confirmKey, filled: true, action: onConfirm)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.top, compact ? 4 : 12)
        }
        .padding(.top, compact ? 6 : 12)
    }
}

/// Label first, then the key that does it — so the eye lands on the verb and
/// the shortcut is the answer to "how", not something to decode first.
struct ActionButton: View {
    let title: String
    /// Drawn instead of `title` when part of the label needs its own weight or
    /// colour. The correction panel names the words it will teach and sets
    /// those words brighter than the sentence around them.
    var styled: Text?
    let key: String
    let filled: Bool
    /// A translucent capsule in this colour, with a border of it and no glow,
    /// instead of the standing filled gradient. For a button whose colour is
    /// part of what it says.
    var glass: Color?
    /// Off: nothing to do, so nothing happens, and the keyboard shortcut on it
    /// goes quiet too.
    var enabled: Bool = true
    /// No capsule, no border — the label and its key and nothing else.
    ///
    /// For the button you are not expected to press. Two bordered buttons side
    /// by side make a choice out of what is really an action and a way out, and
    /// on a panel this small that is a lot of furniture for "never mind".
    var quiet: Bool = false
    let action: () -> Void

    @State private var hovering = false

    /// The text on a glass button. Not white — a green button wants a label
    /// that has been near the green.
    static let glassText = Color(red: 0.875, green: 0.941, blue: 0.906)  // #dff0e7

    private var lit: Bool { hovering && enabled }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                (styled ?? Text(title))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(labelColour)
                // Empty for a button whose key is not worth advertising — the
                // correction panel's Discard, where escape is the way out of
                // every panel in the app and does not need saying a third time.
                if !key.isEmpty { KeyCap(symbol: key, onFill: filled) }
            }
            .padding(.horizontal, quiet ? 4 : 11)
            .padding(.vertical, 6)
            .background {
                if quiet {
                    Capsule().fill(Color.primary.opacity(lit ? 0.08 : 0))
                } else if let glass {
                    Capsule().fill(glass.opacity(lit ? 0.30 : 0.22))
                    Capsule().strokeBorder(glass.opacity(0.5))
                } else if filled {
                    Capsule().fill(
                        LinearGradient(
                            colors: [Parrot.action, Parrot.action.opacity(0.86)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .shadow(color: Parrot.action.opacity(0.45), radius: lit ? 10 : 6, y: 2)
                } else {
                    Capsule().fill(Color.primary.opacity(lit ? 0.10 : 0.06))
                    Capsule().strokeBorder(.primary.opacity(0.10))
                }
            }
            .brightness(lit && filled && glass == nil ? 0.05 : 0)
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var labelColour: AnyShapeStyle {
        if glass != nil { return AnyShapeStyle(Self.glassText) }
        return filled ? AnyShapeStyle(.white) : AnyShapeStyle(.primary)
    }
}

// MARK: - Fields

extension View {

    /// The one text field look: a quiet well that takes a sky ring when focused.
    /// A hairline under a field, instead of a box around it.
    ///
    /// Everything this panel needs to say about the field's bounds, said with
    /// one line: where the text sits and how far it runs. A filled, bordered
    /// box on top of glass is a rectangle inside a rectangle, and the glass is
    /// already doing the job of separating the surface from the desktop.
    func underlined() -> some View {
        overlay(alignment: .bottom) {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [Parrot.action.opacity(0.55), Parrot.action.opacity(0.2)],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .frame(height: 1)
        }
    }

    /// `snug` trims the padding for a field whose text is already large. The
    /// default was set around 13pt type; at 30 the same margins put a band of
    /// empty either side of the sentence and make the box the subject.
    func parrotField(focused: Bool, snug: Bool = false) -> some View {
        padding(.horizontal, snug ? 12 : 9)
            .padding(.vertical, snug ? 5 : 6)
            .background(
                Color.primary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: Parrot.fieldRadius, style: .continuous)
            )
            .overlay {
                // A hint that this is where the caret is, not a highlight. At
                // 0.9 and 1.5pt the ring was the loudest thing on the panel and
                // it framed the one thing you are supposed to be reading.
                RoundedRectangle(cornerRadius: Parrot.fieldRadius, style: .continuous)
                    .strokeBorder(Parrot.action.opacity(focused ? 0.38 : 0), lineWidth: 1)
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
