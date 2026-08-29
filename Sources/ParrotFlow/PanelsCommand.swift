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
        OfferedCommand(title: "Vocabulary", key: "V"),
        OfferedCommand(title: "grammar", key: "G")
    ]

    /// Enough transforms to wrap, which two are not.
    ///
    /// The wrap is counted in `PillMetrics.chipRows` before it is drawn, and a
    /// row count off by one hangs the last chip over the end of the panel. Two
    /// chips can never show that; six can, and six is an ordinary config.
    private static let offerManyChips = offerChips + [
        OfferedCommand(title: "slack handles", key: "S"),
        OfferedCommand(title: "punctuation", key: "P"),
        OfferedCommand(title: "repetitions", key: "R"),
        OfferedCommand(title: "bullets", key: "B")
    ]

    /// A Bluetooth headset with a long name, because the notice puts the name
    /// in its first sentence and a short one would not say whether it fits.
    private static let sampleMicName = "Tasmin's AirPods Pro Max"

    /// A release body longer than the panel is tall — a heading, two sections,
    /// and two links on every line. Longer on purpose: the pane only scrolls
    /// when the notes outgrow it, so a sample that fits proves nothing.
    private static let sampleRelease = Updates.Release(
        version: "0.7.0",
        publishedAt: Date(timeIntervalSince1970: 1_755_561_600),
        notes: """
            ## [0.7.0](https://github.com/znat/parrotflow/compare/v0.6.0...v0.7.0) (2026-08-19)

            ### Features

            * a spelling lesson keeps the word it is teaching ([#143](https://github.com/znat/parrotflow/issues/143)) ([7e19a7e](https://github.com/znat/parrotflow/commit/7e19a7e74d6e56c153912b3f53890b2501854d49))
            * a table says what it wrote, and `join` fits a clip to the box ([#148](https://github.com/znat/parrotflow/issues/148)) ([461ea43](https://github.com/znat/parrotflow/commit/461ea4332725a905f294cfb358b0657b8268fed8))
            * **code_identifiers** publishes the identifiers it wrote ([#146](https://github.com/znat/parrotflow/issues/146)) ([649b08c](https://github.com/znat/parrotflow/commit/649b08c7962f405f72aeaec25c9bf96e514cb8d6))
            * name the word lists once, and let dotted hear dash and slash ([#149](https://github.com/znat/parrotflow/issues/149)) ([aadf036](https://github.com/znat/parrotflow/commit/aadf036a1bc8451132159a9566313caabc391f64))
            * punctuation gains brackets, semicolon, ellipsis and French ([#150](https://github.com/znat/parrotflow/issues/150)) ([dbf028c](https://github.com/znat/parrotflow/commit/dbf028c951d88f914f4cd910af668848b7526e6b))
            * read the input box, tag the words, and hand a transform the whole run ([#147](https://github.com/znat/parrotflow/issues/147)) ([f079683](https://github.com/znat/parrotflow/commit/f0796833ac8569b2d31350a4fc9bf4db28e3bafb))
            * the offer says when the words may not be your words ([#151](https://github.com/znat/parrotflow/issues/151)) ([e9c8578](https://github.com/znat/parrotflow/commit/e9c857869ef38665f7479cec27a6233f18d080ae))

            ### Fixes

            * a repeat holding "I" is no longer kept as a spelled letter ([#145](https://github.com/znat/parrotflow/issues/145)) ([0dc8153](https://github.com/znat/parrotflow/commit/0dc81535c04b2e55856ac5dfff51259b6db36e1b))
            * get past the version-manager shim, and stop trimming what a stage added ([#144](https://github.com/znat/parrotflow/issues/144)) ([a0c5d17](https://github.com/znat/parrotflow/commit/a0c5d17e66056d90dc32a76a841bef7ec9239dda))
            * the pill no longer keeps the icon of an app that has quit ([#141](https://github.com/znat/parrotflow/issues/141)) ([b31c0a2](https://github.com/znat/parrotflow/commit/b31c0a2f5d1e4c8a9b7e6f3d2c1a0b9e8d7c6f5a))
            * a dictation that lands nowhere says so before it copies ([#140](https://github.com/znat/parrotflow/issues/140)) ([c42d1b3](https://github.com/znat/parrotflow/commit/c42d1b3a6e2f5d9c8b7a6e5f4d3c2b1a0f9e8d7c))
            * the vocabulary judge stops asking Ollama about an empty match ([#138](https://github.com/znat/parrotflow/issues/138)) ([d53e2c4](https://github.com/znat/parrotflow/commit/d53e2c4b7f3a6e0d9c8b7a6f5e4d3c2b1a0f9e8d))
            * two builds no longer fight over the same recording directory ([#137](https://github.com/znat/parrotflow/issues/137)) ([e64f3d5](https://github.com/znat/parrotflow/commit/e64f3d5c8a4b7f1e0d9c8b7a6f5e4d3c2b1a0f9e))
            * a hotkey held through a screen lock releases on the way back ([#136](https://github.com/znat/parrotflow/issues/136)) ([f75a4e6](https://github.com/znat/parrotflow/commit/f75a4e6d9b5c8a2f1e0d9c8b7a6f5e4d3c2b1a0f))
            * the log stops growing without bound on a machine left running ([#135](https://github.com/znat/parrotflow/issues/135)) ([a86b5f7](https://github.com/znat/parrotflow/commit/a86b5f7e0c6d9b3a2f1e0d9c8b7a6f5e4d3c2b1a))
            * a spelled word ending in a full stop keeps the full stop ([#134](https://github.com/znat/parrotflow/issues/134)) ([b97c6a8](https://github.com/znat/parrotflow/commit/b97c6a8f1d7e0c4b3a2f1e0d9c8b7a6f5e4d3c2b))
            * the preview panel stops reopening on the screen you left ([#133](https://github.com/znat/parrotflow/issues/133)) ([ca8d7b9](https://github.com/znat/parrotflow/commit/ca8d7b9a2e8f1d5c4b3a2f1e0d9c8b7a6f5e4d3c))
            * numbers said as digits survive the grammar stage ([#132](https://github.com/znat/parrotflow/issues/132)) ([db9e8ca](https://github.com/znat/parrotflow/commit/db9e8ca3f9a2e6d5c4b3a2f1e0d9c8b7a6f5e4d3))
            * a transform that writes nothing no longer clears the line ([#131](https://github.com/znat/parrotflow/issues/131)) ([ecaf9db](https://github.com/znat/parrotflow/commit/ecaf9db4a0b3f7e6d5c4b3a2f1e0d9c8b7a6f5e4))
            * the menu bar icon returns after a display is unplugged ([#130](https://github.com/znat/parrotflow/issues/130)) ([fdb0aec](https://github.com/znat/parrotflow/commit/fdb0aec5b1c4a8f7e6d5c4b3a2f1e0d9c8b7a6f5))
            * a second hotkey press during the release tail is ignored ([#129](https://github.com/znat/parrotflow/issues/129)) ([aec1bfd](https://github.com/znat/parrotflow/commit/aec1bfd6c2d5b9a8f7e6d5c4b3a2f1e0d9c8b7a6))
            """,
        zip: URL(string: "https://example.invalid/ParrotFlow.zip")!,
        checksum: URL(string: "https://example.invalid/ParrotFlow.zip.sha256")!
    )

    /// What `feedback.confidence` draws. The scores walk the whole ramp — sure,
    /// p25, p10, p1, and a word with no reading at all — because the question
    /// this surface answers is whether the colours are told apart, and a
    /// sentence the decoder was sure of would show one of them.
    private static let sampleSentence = [
        Confidence.Word(text: "We", score: 1.0),
        Confidence.Word(text: "deployed", score: 0.97),
        Confidence.Word(text: "Redcrawl", score: 0.74),
        Confidence.Word(text: "on", score: 0.99),
        Confidence.Word(text: "Vercel", score: 0.52),
        Confidence.Word(text: "with", score: 0.91),
        Confidence.Word(text: "Tasmin", score: 0.28),
        Confidence.Word(text: "yesterday", score: nil)
    ]

    /// The warning the same dictation raises. It names the word rather than a
    /// number: the number is for the person tuning the thresholds, and this
    /// line is for the person who has just dictated.
    private static let sampleWarning = "This may not be what you said · Vercel"

    /// The words and the warning together.
    private static let sampleReading = Confidence.Reading(
        words: sampleSentence, warning: sampleWarning
    )

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
        func pill(
            _ state: PillState, icon: NSImage? = nil, level: Float = 0,
            docked: Dock? = nil
        ) -> PillModel {
            let model = PillModel()
            model.state = state
            model.appIcon = icon
            model.level = level
            // Every offer is drawn hanging, because that is the only way it is
            // ever seen: square along the edge that meets the line, rounded
            // below, no rim. A lozenge here would be a picture of a state the
            // app does not have.
            model.docked = docked
            // No hotkey is registered behind the sheet, so the selection offer
            // is drawn against the shipped default — which is the one a reader
            // should be checking that row against, and is not this machine's.
            model.hotkey = "Right ⌘"
            return model
        }

        let notice = pill(.notice("Grammar applied", .done), docked: .below)
        let caution = pill(.notice("Grammar copied — this app won't let me edit it", .caution), docked: .below)
        let thinking = pill(.working("Thinking…"))
        // The offer before it is asked for: the bird and the key, and nothing
        // else. First because it is what every dictation now ends as — the ones
        // below are what it becomes when you rest on it.
        let tab = pill(.offer(offerChips, nil, Confidence.Reading(), open: false), docked: .below)
        // And the tab with something to warn about, which never appears in the
        // app — a doubtful decode opens by itself. On the sheet because the
        // amber pip has to be findable at 46pt, and that is only checkable
        // beside the plain one.
        let tabWarned = pill(.offer(
            offerChips, nil, Confidence.Reading(warning: sampleWarning), open: false
        ), docked: .below)
        let offer = pill(.offer(offerChips, nil, Confidence.Reading(), open: true), docked: .below)
        // The offer over a selection: three rows, and the words themselves
        // rather than a word for them. On the sheet because the difference from
        // the plain one is the whole design — a pill that says which words is a
        // different surface from one that says there are some, and a row that
        // is only sometimes there gets looked at nowhere else.
        let offerSelection = pill(.offer(
            offerChips, .selection("things that turned out not to matter"),
            Confidence.Reading(), open: true
        ), docked: .below)
        // Beside the plain one: the two endings must not look the same.
        let offerCopied = pill(.offer(
            offerChips, .landing("Nowhere to type · ⌘V"), Confidence.Reading(),
            open: true
        ), docked: .below)
        // The warning on its own, which is what most people will ever see of
        // this: `feedback.confidence` is off by default and the thresholds are
        // not, so a shaky dictation raises one line and nothing else.
        let offerWarned = pill(.offer(
            offerChips, nil, Confidence.Reading(warning: sampleWarning), open: true
        ), docked: .below)
        // And the same pill after it has taken a Return: one step further
        // along the same ramp, which is the thing to check side by side —
        // amber and scarlet have to read as an escalation, not as two moods.
        let offerStopped = pill(.offer(
            offerChips, nil,
            Confidence.Reading(warning: Confidence.stopped, stopped: true), open: true
        ), docked: .below)
        // The same offer with `feedback.confidence` on.
        let offerHeard = pill(.offer(offerChips, nil, sampleReading, open: true), docked: .below)
        // Six transforms, which is one row too many for a panel pinned to a
        // character. See `PillMetrics.chipsWidth`.
        let offerWrapped = pill(
            .offer(offerManyChips, nil, Confidence.Reading(), open: true), docked: .below
        )
        // And a dictation long enough to wrap. On the sheet because the wrap is
        // the one thing here that is counted before it is drawn — a line count
        // off by one clips the words rather than costing a few points of pill.
        let offerHeardLong = pill(.offer(
            offerChips, nil,
            Confidence.Reading(
                words: sampleSentence + sampleSentence, warning: sampleWarning
            ),
            open: true
        ), docked: .below)

        // The dictation, hanging off a line: the bird half full, then standing
        // while it thinks. On the sheet because the whole recording state is
        // one mark now, and whether it reads at 20pt is the question.
        let listening = pill(.recording(nil), icon: sampleIcon(), level: 0.55, docked: .below)
        let listeningQuiet = pill(.recording(nil), icon: sampleIcon(), level: 0.06, docked: .below)
        let listeningBlind = pill(.recording(nil), level: 0.55, docked: .below)
        let thinkingDocked = pill(.working("Thinking…"), docked: .below)

        let overlay = pill(.recording(nil), icon: sampleIcon(), level: 0.75)

        // The pill has two states now and the difference is the whole point of
        // the slot: with somewhere to type it holds that app's icon, with
        // nowhere it holds nothing and is simply narrower — which is how you
        // are told the words are going to the clipboard instead. Both are on
        // the sheet because "it looks wrong with no icon" is the kind of thing
        // that is obvious side by side and invisible a week apart.
        let overlayBlind = pill(.recording(nil), level: 0.75)

        // And the third, which is not dictation at all: tap-then-hold, where
        // what you say is routed instead of written down. The label is the only
        // thing that says so, which is exactly why it belongs on this sheet.
        let overlayCommand = pill(
            .recording("editing the selection"), icon: sampleIcon(), level: 0.75
        )

        // A row the spell check proposed, half filled in, and a row typed by
        // hand — the two shapes the panel exists for, side by side.
        let correction = CorrectionModel()
        correction.load(sentence: "I work with Tasmin and Mick")
        correction.rows[0].corrected = "Tasmeen"

        // A name the decoder split in two. It arrives as no row at all — both
        // halves are ordinary words — so the left field is typed over. This is
        // the case the table has to be able to hold.
        let rule = CorrectionModel()
        rule.load(sentence: "we deployed on Ver Sal")
        rule.rows = [CorrectionRow(heard: "Ver Sal", corrected: "Vercel",
                                   kind: .organization)]
        // The rows were replaced wholesale, so the focus `load` left points at
        // a row that no longer exists.
        rule.focus = CorrectionModel.Cell(row: rule.rows[0].id, column: .corrected)

        // Two rows, so the picker is drawn twice against different words. The
        // sheet cannot show a focus ring on any of them: it renders offscreen,
        // in no key window, and SwiftUI grants focus to neither.
        let several = CorrectionModel()
        several.load(sentence: "Olama runs polyma for Tasmine")

        // Both states of the microphone notice, because the disclosure is the
        // shape of it: collapsed is what you read, open is the argument. A
        // device name long enough to outgrow the box shows here and nowhere
        // else — see `MicNoticeMetrics`.
        let micNotice = MicNoticeModel()
        micNotice.mic = sampleMicName
        let micNoticeOpen = MicNoticeModel()
        micNoticeOpen.mic = sampleMicName
        micNoticeOpen.expanded = true

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
            (AnyView(PillView().environmentObject(overlayCommand)),
             pillSize(overlayCommand), .dark, true),
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
            // The screen after both are granted, in the three shapes it comes
            // in: the speech model already there, still on its way, and there
            // but the hotkey never bound — the states DonePane's invitation
            // sentence chooses between.
            (AnyView(PermissionsView().environmentObject(PermissionsModel.done())),
             NSSize(width: PermissionMetrics.width, height: PermissionMetrics.height), .dark, false),
            (AnyView(PermissionsView()
                .environmentObject(PermissionsModel.done(speechModel: .preparing(percent: 43)))),
             NSSize(width: PermissionMetrics.width, height: PermissionMetrics.height), .dark, false),
            (AnyView(PermissionsView()
                .environmentObject(PermissionsModel.done(hotkeyRegistered: false))),
             NSSize(width: PermissionMetrics.width, height: PermissionMetrics.height), .dark, false),
            (AnyView(PillView().environmentObject(notice)),
             pillSize(notice), .dark, true),
            (AnyView(PillView().environmentObject(thinking)),
             pillSize(thinking), .dark, true),
            (AnyView(PillView().environmentObject(caution)),
             pillSize(caution), .dark, true),
            // What every dictation now ends as, and what the rest of this
            // block is that surface opened. Next to the notices because that is
            // the comparison that matters: it has to not look like one, and at
            // 46pt it has to be findable at all.
            (AnyView(PillView().environmentObject(listeningQuiet)),
             pillSize(listeningQuiet), .dark, true),
            (AnyView(PillView().environmentObject(listening)),
             pillSize(listening), .dark, true),
            (AnyView(PillView().environmentObject(listeningBlind)),
             pillSize(listeningBlind), .dark, true),
            (AnyView(PillView().environmentObject(thinkingDocked)),
             pillSize(thinkingDocked), .dark, true),
            (AnyView(PillView().environmentObject(tab)),
             pillSize(tab), .dark, true),
            (AnyView(PillView().environmentObject(tabWarned)),
             pillSize(tabWarned), .dark, true),
            (AnyView(PillView().environmentObject(offer)),
             pillSize(offer), .dark, true),
            (AnyView(PillView().environmentObject(offerSelection)),
             pillSize(offerSelection), .dark, true),
            (AnyView(PillView().environmentObject(offerCopied)),
             pillSize(offerCopied), .dark, true),
            // The same offer with `feedback.confidence` on: two rows instead of
            // one, and the only pill on the sheet that is not a lozenge.
            (AnyView(PillView().environmentObject(offerWarned)),
             pillSize(offerWarned), .dark, true),
            (AnyView(PillView().environmentObject(offerStopped)),
             pillSize(offerStopped), .dark, true),
            (AnyView(PillView().environmentObject(offerHeard)),
             pillSize(offerHeard), .dark, true),
            (AnyView(PillView().environmentObject(offerWrapped)),
             pillSize(offerWrapped), .dark, true),
            (AnyView(PillView().environmentObject(offerHeardLong)),
             pillSize(offerHeardLong), .dark, true),
            // Not a pill state at all, and the only surface here that is
            // about the hardware rather than about the words. Next to the pill
            // because that is what it appears beside.
            (AnyView(MicNoticeView().environmentObject(micNotice)),
             NSSize(width: MicNoticeMetrics.width,
                    height: MicNoticeMetrics.height(expanded: false)), .dark, true),
            (AnyView(MicNoticeView().environmentObject(micNoticeOpen)),
             NSSize(width: MicNoticeMetrics.width,
                    height: MicNoticeMetrics.height(expanded: true)), .dark, true),
            (AnyView(CorrectionView().environmentObject(correction)),
             NSSize(width: CorrectionMetrics.width, height: CorrectionMetrics.height(forRows: correction.rows.count)), .dark, false),
            (AnyView(CorrectionView().environmentObject(rule)),
             NSSize(width: CorrectionMetrics.width, height: CorrectionMetrics.height(forRows: rule.rows.count)), .dark, false),
            (AnyView(CorrectionView().environmentObject(several)),
             NSSize(width: CorrectionMetrics.width, height: CorrectionMetrics.height(forRows: several.rows.count)), .dark, false),
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
        PillMetrics.panelSize(
            for: model.state, hasIcon: model.appIcon != nil, hotkey: model.hotkey,
            docked: model.docked != nil
        )
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
        let micNotice = MicNotice()
        let updatePanel = UpdatePanel()
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
            // The real call rather than a bare `set`. The offer is the one
            // state that holds and then thins out, so a preview that only held
            // would be a picture of a pill that never leaves. It gets the
            // duration the app gives it.
            pill.offer(offerChips, for: AppDelegate.offerSeconds)
            // The one state that takes the mouse, so the one worth being able
            // to hover. Nothing runs — this is the surface, not the app — but
            // the highlight and the hold behave the way they do there: park the
            // pointer on the pill and it stops fading, which is also how you
            // keep it on screen for as long as you want to look at it.
            pill.model.onHover = { inside in
                if !inside { pill.model.selected = nil }
                pill.hovering(inside)
            }
            pill.model.onPick = { index in
                print("offer: chip \(index) — \(offerChips[index].title)")
            }
        // The same offer with `feedback.confidence` on — the only pill that is
        // two rows, and the only one that is not a lozenge.
        case "confidence":
            pill.offer(offerChips, reading: sampleReading, for: AppDelegate.offerSeconds)
            pill.model.onHover = { inside in
                if !inside { pill.model.selected = nil }
                pill.hovering(inside)
            }
        case "vocabulary":
            correction.show(selection: "I work with Tasmin and Mick on Versal")
        // A sentence where the spell check finds nothing, so the panel opens
        // with one blank row. That is 33 of the 56 sentences measured.
        case "punctuation":
            correction.show(selection: "Trois, quatre, cinq.")
        // One of the two rules heard two words. No proposal can produce that
        // row, so it is what the editable left field is for.
        case "rule":
            correction.show(rules: [(heard: "Ver Sal", corrected: "Vercel"),
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
        // The one surface that has to be clicked to be seen whole: it opens
        // where it opens in the app, and the disclosure and "Got it" both work
        // here. `show(mic:)` rather than `showIfNeeded`, so it appears on a
        // machine whose microphone is wired.
        case "microphone":
            micNotice.show(mic: sampleMicName)
        // The one surface that is a window rather than a floating panel over
        // the words. Sized from the notes it is given, so a long release is
        // what shows whether it scrolls.
        case "update":
            updatePanel.show(
                release: sampleRelease,
                current: "0.6.0",
                blocker: UpdateInstaller.blocker,
                answers: UpdatePanel.Answers(
                    install: UpdateInstaller.blocker == nil ? { print("update: install") } : nil,
                    copyCommand: { print("update: copy the command") },
                    skip: { print("update: skip") },
                    later: { print("update: later") }
                )
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
            print("usage: ParrotFlow --panels <notice|caution|failure|thinking|offer"
                + "|vocabulary|punctuation|rule|dictation|preview|microphone|pill"
                + "|update|sequence> [seconds]")
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
