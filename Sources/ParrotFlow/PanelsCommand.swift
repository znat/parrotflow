import AppKit
import SwiftUI

/// Puts one floating surface on screen and leaves it there, so it can be looked
/// at — or screenshotted — without dictating anything.
///
/// The panels only ever appear in the middle of doing something else: a hotkey
/// held down, a model that has just answered. Checking that a border or a
/// button still looks right otherwise meant staging a whole correction, which
/// is slow enough that the surfaces drifted apart from each other unnoticed.
enum PanelsCommand {

    /// What the offer is drawn with here: Correct and one offered transform,
    /// which is what the shipped config puts on the pill. A row of chips is the
    /// shape worth looking at, not one chip on its own.
    private static let offerChips = [
        OfferedCommand(title: "Correct", key: "C"),
        OfferedCommand(title: "grammar", key: "G")
    ]

    /// Draws every surface into one PNG, light beside dark.
    ///
    /// The panels are the one part of the app with no test: they are looked at,
    /// not asserted on. A sheet of all of them at once is the closest thing to
    /// a regression test there is — drift between two of them is obvious side
    /// by side and invisible when they are minutes apart on a real screen.
    ///
    /// The translucency does not survive being drawn outside a window server
    /// composite, so the material comes out as flat grey here. Everything else
    /// — colour, type, spacing, the rim — is what you will see.
    static func sheet(to path: String) -> Int32 {
        // One model per state, because they are one surface now: the sheet is
        // the only place all of them are visible at once, which is where drift
        // between them shows.
        func pill(_ state: PillState, icon: NSImage? = nil, level: Float = 0) -> PillModel {
            let model = PillModel()
            model.state = state
            model.appIcon = icon
            model.level = level
            return model
        }

        let notice = pill(.notice("Grammar applied", .done))
        let caution = pill(.notice("Grammar copied — this app won't let me edit it", .caution))
        let thinking = pill(.working("Thinking…"))
        let offer = pill(.offer(offerChips))

        let overlay = pill(.recording, icon: sampleIcon(), level: 0.75)

        // The pill has two states now and the difference is the whole point of
        // the slot: with somewhere to type it holds that app's icon, with
        // nowhere it holds nothing and is simply narrower — which is how you
        // are told the words are going to the clipboard instead. Both are on
        // the sheet because "it looks wrong with no icon" is the kind of thing
        // that is obvious side by side and invisible a week apart.
        let overlayBlind = pill(.recording, level: 0.75)

        let correction = CorrectionModel()
        correction.load(selection: "Tasmin and Mick")
        correction.tokens[0].replacement = "Tasmeen"

        let rule = CorrectionModel()
        rule.loadRules([(heard: "Tasmin", corrected: "Tasmeen"),
                        (heard: "Mick", corrected: "Mik")])

        let preview = PreviewModel()
        preview.load(
            prompt: "Grammar",
            before: "i think we should of asked them first, their going to be annoyed",
            after: "I think we should have asked them first — they're going to be annoyed."
        )

        // The third element is the appearance to draw in. Every floating
        // surface is dark whatever the system is set to — that is decided in
        // `adoptParrotAppearance` and is not a preference. The permissions
        // window is the exception and the reason this is a column at all: it is
        // an ordinary titled window, it follows the system, and it has to be
        // legible both ways. So it appears twice, once each.
        let surfaces: [(view: AnyView, size: NSSize, scheme: ColorScheme, drawn: Bool)] = [
            (AnyView(PillView().environmentObject(overlay)),
             pillSize(overlay), .dark, true),
            (AnyView(PillView().environmentObject(overlayBlind)),
             pillSize(overlayBlind), .dark, true),
            // The one real window the app has, and the first thing anyone sees.
            // On the sheet for the same reason as the rest: it is looked at,
            // not asserted on, and two screens that drift apart are obvious
            // side by side and invisible a week apart.
            //
            // One of each context, because the second button is the difference
            // between them and it is the part worth being able to see: setting
            // up says "Cancel installation", revisiting says "Not now".
            (AnyView(PermissionsView()
                .environmentObject(PermissionsModel.showing(.microphone))),
             NSSize(width: PermissionMetrics.width, height: PermissionMetrics.height), .light, false),
            (AnyView(PermissionsView()
                .environmentObject(PermissionsModel.showing(
                    .accessibility, asked: true, context: .revisiting))),
             NSSize(width: PermissionMetrics.width, height: PermissionMetrics.height), .dark, false),
            (AnyView(PillView().environmentObject(notice)),
             pillSize(notice), .dark, true),
            (AnyView(PillView().environmentObject(thinking)),
             pillSize(thinking), .dark, true),
            (AnyView(PillView().environmentObject(caution)),
             pillSize(caution), .dark, true),
            // The state the pill ends on, which is the only one that offers
            // rather than reports. Next to the notices because that is the
            // comparison that matters: it has to not look like one.
            (AnyView(PillView().environmentObject(offer)),
             pillSize(offer), .dark, true),
            (AnyView(CorrectionView().environmentObject(correction)),
             NSSize(width: CorrectionMetrics.width, height: CorrectionMetrics.height(forRows: 2)), .dark, false),
            (AnyView(CorrectionView().environmentObject(rule)),
             NSSize(width: CorrectionMetrics.width, height: CorrectionMetrics.height(forRows: 1)), .dark, false),
            // The dictation panel is deliberately not here. Its field is an
            // `NSTextField` and its background is real Liquid Glass, and this
            // sheet can draw neither — it came out as a white block inside an
            // untinted rectangle, which is worse than an omission. Look at it
            // with `--panels dictation`, on a screen, where both are real.
            (AnyView(PreviewView().environmentObject(preview)),
             NSSize(width: PreviewMetrics.sampleWidth + PreviewMetrics.bleed * 2,
                    height: PreviewMetrics.height(for: preview.after, singleLine: false)), .dark, true),
        ]

        let margin: CGFloat = 36
        let gap: CGFloat = 24
        let column = surfaces.map(\.size.width).max()! + margin * 2
        let tall = surfaces.map(\.size.height).reduce(0, +) + gap * CGFloat(surfaces.count - 1) + margin * 2
        let size = NSSize(width: column * 2, height: tall)

        guard let canvas = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return 1 }
        canvas.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)

        // The surfaces are dark either way; the columns are the two kinds of app
        // they land on top of.
        for index in 0..<2 {
            let left = CGFloat(index) * column
            (index == 0 ? NSColor.white : NSColor(white: 0.13, alpha: 1)).setFill()
            NSRect(x: left, y: 0, width: column, height: size.height).fill()

            var top = size.height - margin
            for (view, natural, scheme, drawn) in surfaces {
                let box = NSRect(
                    x: left + (column - natural.width) / 2,
                    y: top - natural.height,
                    width: natural.width,
                    height: natural.height
                )

                // Two ways to snapshot, and each is wrong for the other half.
                //
                // `ImageRenderer` draws the SwiftUI view itself, which is the
                // only way to keep the pill's glow: the glow is a blur, a blur
                // makes SwiftUI rasterize the layer, and `cacheDisplay` hands
                // that back opaque — every pill came out in a black rectangle.
                //
                // But `ImageRenderer` cannot draw an AppKit-backed control, so
                // the correction and preview panels come out with every text
                // field empty. Those keep `cacheDisplay`, which has no blur to
                // lose.
                if drawn {
                    // `assumeIsolated` because `ImageRenderer` is main-actor
                    // bound and this is a plain synchronous function — called
                    // from `main.swift` on the main thread and nowhere else.
                    let rendered = MainActor.assumeIsolated { () -> NSImage? in
                        let renderer = ImageRenderer(
                            content: view
                                .environment(\.colorScheme, scheme)
                                .frame(width: natural.width, height: natural.height)
                        )
                        renderer.scale = 2
                        renderer.isOpaque = false
                        return renderer.nsImage
                    }
                    rendered?.draw(in: box)
                } else {
                    let hosting = NSHostingView(rootView: view)
                    hosting.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                    hosting.frame = NSRect(origin: .zero, size: natural)
                    hosting.layoutSubtreeIfNeeded()
                    if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                        hosting.cacheDisplay(in: hosting.bounds, to: rep)
                        rep.draw(in: box)
                    }
                }
                top -= natural.height + gap
            }
        }

        NSGraphicsContext.restoreGraphicsState()

        guard let png = canvas.representation(using: .png, properties: [:]) else { return 1 }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
            return 0
        } catch {
            print("✗ \(error.localizedDescription)")
            return 1
        }
    }

    /// The window's size, not the capsule's — the glow needs the bleed around
    /// it or the sheet cuts the halo off square.
    private static func pillSize(_ model: PillModel) -> NSSize {
        PillMetrics.panelSize(for: model.state, hasIcon: model.appIcon != nil)
    }

    /// Something recognisable to sit in the pill's slot. Mail because that is
    /// the window the `email` transform was written for, and any Mac has it.
    private static func sampleIcon() -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.mail"
        ) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    static func run(surface: String, seconds: Double) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        // Held for the lifetime of the process: these own their NSPanels, and a
        // panel whose owner has been collected goes with it.
        let pill = PillHUD()
        let correction = CorrectionPanel()
        let preview = PreviewPanel()
        var ticker: Timer?

        switch surface {
        case "notice":
            pill.notice("Grammar applied", tone: .done, duration: nil)
        case "caution":
            pill.notice("Grammar copied — this app won't let me edit it", tone: .caution, duration: nil)
        case "failure":
            pill.notice("Ollama is not running on localhost:11434", tone: .failure, duration: nil)
        case "thinking":
            pill.working("Thinking…")
        case "offer":
            // No duration: it is here to be looked at, not timed out.
            pill.set(.offer(offerChips))
            // The one state that takes the mouse, so the one worth being able
            // to hover. Nothing runs — this is the surface, not the app — but
            // the highlight has to come and go the way it does there.
            pill.model.onHover = { inside in
                if !inside { pill.model.selected = nil }
            }
            pill.model.onPick = { index in
                print("offer: chip \(index) — \(offerChips[index].title)")
            }
        case "vocabulary":
            correction.show(selection: "Tasmin and Mick")
        case "rule":
            correction.show(rules: [(heard: "Tasmin", corrected: "Tasmeen"),
                                    (heard: "Mick", corrected: "Mik")])
        // The panel the pill's offer opens: one line, editable, over what was
        // just dictated. A different shape from the transform preview below —
        // short enough for a field rather than an area — and the one that is
        // seen most, so it is worth being able to look at on its own.
        case "dictation":
            preview.show(transcript: "Let's ship the vocabulary harness on Tuesday.")
        case "preview":
            preview.show(
                prompt: "Grammar",
                before: "i think we should of asked them first, their going to be annoyed",
                after: "I think we should have asked them first — they're going to be annoyed."
            )
        case "pill":
            pill.recording(icon: sampleIcon())
            // A meter frozen at zero says nothing about how the meter looks.
            var phase = 0.0
            ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                phase += 0.05
                pill.model.level = Float(0.5 + 0.45 * sin(phase * 2))
            }

        // The one surface whose point is the motion between its states, so it
        // is the one that cannot be checked from a still. Runs the whole
        // dictation — hot mic, decoding, applied, the offer, gone — on a loop,
        // which is the only way to see whether the pill morphs or jumps.
        case "sequence":
            var phase = 0.0
            let meter = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                phase += 0.05
                pill.model.level = Float(0.5 + 0.45 * sin(phase * 2))
            }
            ticker = meter

            let script: [(TimeInterval, () -> Void)] = [
                (0.0, { pill.recording(icon: sampleIcon()) }),
                (2.6, { pill.working("Transcribing…") }),
                (4.0, { pill.working("Grammar…") }),
                (5.4, { pill.notice("Grammar applied", tone: .done, duration: nil) }),
                (7.4, { pill.offer(offerChips, for: 3) }),
                (11.4, { pill.recording(icon: nil) }),
                (14.0, { pill.working("Transcribing…") }),
                (15.4, { pill.notice("Nowhere to type — the transcription is on your clipboard",
                                     tone: .caution, duration: 3) }),
            ]
            let loop = script.last!.0 + 5
            for turn in stride(from: 0.0, to: seconds, by: loop) {
                for (at, step) in script {
                    DispatchQueue.main.asyncAfter(deadline: .now() + turn + at, execute: step)
                }
            }
        default:
            print("usage: ParrotFlow --panels <notice|caution|failure|thinking|offer|vocabulary|rule|dictation|preview|pill|sequence> [seconds]")
            return 2
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            ticker?.invalidate()
            exit(0)
        }
        app.run()
        return 0
    }
}
