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
        let notice = NoticeModel()
        notice.message = "Grammar applied"
        notice.tone = .done

        let caution = NoticeModel()
        caution.message = "Grammar copied — this app won't let me edit it"
        caution.tone = .caution

        let thinking = NoticeModel()
        thinking.message = "Thinking…"
        thinking.tone = .thinking

        let overlay = OverlayModel()
        overlay.level = 0.75
        overlay.appIcon = sampleIcon()

        // The pill has two states now and the difference is the whole point of
        // the slot: with somewhere to type it holds that app's icon, with
        // nowhere it holds nothing and is simply narrower — which is how you
        // are told the words are going to the clipboard instead. Both are on
        // the sheet because "it looks wrong with no icon" is the kind of thing
        // that is obvious side by side and invisible a week apart.
        let overlayBlind = OverlayModel()
        overlayBlind.level = 0.75

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

        let surfaces: [(NSView, NSSize)] = [
            (NSHostingView(rootView: RecordingPill().environmentObject(overlay)),
             NSSize(width: RecordingMetrics.width(hasIcon: overlay.appIcon != nil),
                    height: RecordingMetrics.height)),
            (NSHostingView(rootView: RecordingPill().environmentObject(overlayBlind)),
             NSSize(width: RecordingMetrics.width(hasIcon: false),
                    height: RecordingMetrics.height)),
            (NSHostingView(rootView: NoticeView().environmentObject(notice)),
             NSSize(width: NoticeMetrics.width(for: notice.message), height: NoticeMetrics.height)),
            (NSHostingView(rootView: NoticeView().environmentObject(thinking)),
             NSSize(width: NoticeMetrics.width(for: thinking.message), height: NoticeMetrics.height)),
            (NSHostingView(rootView: NoticeView().environmentObject(caution)),
             NSSize(width: NoticeMetrics.width(for: caution.message), height: NoticeMetrics.height)),
            (NSHostingView(rootView: CorrectionView().environmentObject(correction)),
             NSSize(width: CorrectionMetrics.width, height: CorrectionMetrics.height(forRows: 2))),
            (NSHostingView(rootView: CorrectionView().environmentObject(rule)),
             NSSize(width: CorrectionMetrics.width, height: CorrectionMetrics.height(forRows: 1))),
            (NSHostingView(rootView: PreviewView().environmentObject(preview)),
             NSSize(width: PreviewMetrics.width, height: PreviewMetrics.height(forCharacters: 70))),
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
            for (view, natural) in surfaces {
                view.appearance = NSAppearance(named: .darkAqua)
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
        let notice = NoticeHUD()
        let correction = CorrectionPanel()
        let preview = PreviewPanel()
        let overlay = RecordingOverlay()
        var ticker: Timer?

        switch surface {
        case "notice":
            notice.show("Grammar applied", tone: .done, duration: nil)
        case "caution":
            notice.show("Grammar copied — this app won't let me edit it", tone: .caution, duration: nil)
        case "failure":
            notice.show("Ollama is not running on localhost:11434", tone: .failure, duration: nil)
        case "thinking":
            notice.show("Thinking…", tone: .thinking, duration: nil)
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
            overlay.model.appIcon = sampleIcon()
            overlay.show()
            // A meter frozen at zero says nothing about how the meter looks.
            var phase = 0.0
            ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                phase += 0.05
                overlay.model.level = Float(0.5 + 0.45 * sin(phase * 2))
            }
        default:
            print("usage: ParrotFlow --panels <notice|caution|failure|thinking|vocabulary|rule|preview|pill> [seconds]")
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
