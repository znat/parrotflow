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
        let offer = pill(.offer("Right ⌘"))

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
        let surfaces: [(NSView, NSSize, NSAppearance.Name)] = [
            (NSHostingView(rootView: PillView().environmentObject(overlay)),
             pillSize(overlay), .darkAqua),
            (NSHostingView(rootView: PillView().environmentObject(overlayBlind)),
             pillSize(overlayBlind), .darkAqua),
            // The one real window the app has, and the first thing anyone sees.
            // On the sheet for the same reason as the rest: it is looked at,
            // not asserted on, and two screens that drift apart are obvious
            // side by side and invisible a week apart.
            //
            // One of each context, because the second button is the difference
            // between them and it is the part worth being able to see: setting
            // up says "Cancel installation", revisiting says "Not now".
            (NSHostingView(rootView: PermissionsView()
                .environmentObject(PermissionsModel.showing(.microphone))),
             NSSize(width: PermissionMetrics.width, height: PermissionMetrics.height), .aqua),
            (NSHostingView(rootView: PermissionsView()
                .environmentObject(PermissionsModel.showing(
                    .accessibility, asked: true, context: .revisiting))),
             NSSize(width: PermissionMetrics.width, height: PermissionMetrics.height), .darkAqua),
            (NSHostingView(rootView: PillView().environmentObject(notice)),
             pillSize(notice), .darkAqua),
            (NSHostingView(rootView: PillView().environmentObject(thinking)),
             pillSize(thinking), .darkAqua),
            (NSHostingView(rootView: PillView().environmentObject(caution)),
             pillSize(caution), .darkAqua),
            // The state the pill ends on, which is the only one that offers
            // rather than reports. Next to the notices because that is the
            // comparison that matters: it has to not look like one.
            (NSHostingView(rootView: PillView().environmentObject(offer)),
             pillSize(offer), .darkAqua),
            (NSHostingView(rootView: CorrectionView().environmentObject(correction)),
             NSSize(width: CorrectionMetrics.width, height: CorrectionMetrics.height(forRows: 2)), .darkAqua),
            (NSHostingView(rootView: CorrectionView().environmentObject(rule)),
             NSSize(width: CorrectionMetrics.width, height: CorrectionMetrics.height(forRows: 1)), .darkAqua),
            (NSHostingView(rootView: PreviewView().environmentObject(preview)),
             NSSize(width: PreviewMetrics.width, height: PreviewMetrics.height(forCharacters: 70)), .darkAqua),
        ]

        let margin: CGFloat = 36
        let gap: CGFloat = 24
        let column = surfaces.map(\.1.width).max()! + margin * 2
        let tall = surfaces.map(\.1.height).reduce(0, +) + gap * CGFloat(surfaces.count - 1) + margin * 2
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
            for (view, natural, appearance) in surfaces {
                view.appearance = NSAppearance(named: appearance)
                view.frame = NSRect(origin: .zero, size: natural)
                view.layoutSubtreeIfNeeded()
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                rep.draw(in: NSRect(
                    x: left + (column - natural.width) / 2,
                    y: top - natural.height,
                    width: natural.width,
                    height: natural.height
                ))
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

    private static func pillSize(_ model: PillModel) -> NSSize {
        NSSize(width: PillMetrics.width(for: model.state, hasIcon: model.appIcon != nil),
               height: PillMetrics.height)
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
            pill.set(.offer("Right ⌘"))
        case "vocabulary":
            correction.show(selection: "Tasmin and Mick")
        case "rule":
            correction.show(rules: [(heard: "Tasmin", corrected: "Tasmeen"),
                                    (heard: "Mick", corrected: "Mik")])
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
            ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                phase += 0.05
                pill.model.level = Float(0.5 + 0.45 * sin(phase * 2))
            }

            let script: [(TimeInterval, () -> Void)] = [
                (0.0, { pill.recording(icon: sampleIcon()) }),
                (2.6, { pill.working("Transcribing…") }),
                (4.0, { pill.working("Grammar…") }),
                (5.4, { pill.notice("Grammar applied", tone: .done, duration: nil) }),
                (7.4, { pill.offer("Right ⌘", for: 3) }),
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
            print("usage: ParrotFlow --panels <notice|caution|failure|thinking|offer|vocabulary|rule|preview|pill|sequence> [seconds]")
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
